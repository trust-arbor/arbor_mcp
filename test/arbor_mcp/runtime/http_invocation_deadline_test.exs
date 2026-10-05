defmodule Arbor.MCP.Server.Runtime.HTTPInvocationDeadlineTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, CallbackContext, Deadline, Ref}

  defmodule Handler do
    def init(opts), do: {:ok, %{test: opts[:test], count: 0}}

    def dispatch(request, _handler, state, _opts) do
      send(state.test, {:http_callback, request["id"], self()})

      send(
        state.test,
        {:http_callback_entry, request["id"], System.monotonic_time(:millisecond),
         CallbackContext.current().deadline}
      )

      if request["method"] == "hold", do: receive(do: (:finish -> :ok))

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state.count},
       %{state | count: state.count + 1}}
    end
  end

  test "invalid, duplicate and expired invocation cutoffs reject before count or bytes" do
    runtime = runtime()

    for value <- [:infinity, nil, 1.5, Bitwise.bsl(1, 65_536), -9_223_372_036_854_775_809] do
      assert {:error, :invalid_invocation_deadline} =
               Runtime.submit(runtime, message(1), invocation_deadline: value)
    end

    assert {:error, :invalid_invocation_deadline} =
             Admission.reserve(runtime, message(1),
               invocation_deadline: Deadline.now() + 1000,
               invocation_deadline: Deadline.now() + 2000
             )

    assert {:error, :invalid_invocation_deadline} =
             Admission.reserve(runtime, message(1), [:invalid])

    assert {:error, :handler_timeout} =
             Runtime.submit(runtime, message(1), invocation_deadline: Deadline.now() - 1)

    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
    assert :ets.match_object(Ref.table(runtime), {{:cleanup, :_}, :_}) == []
    refute_receive {:http_callback, _, _}, 10
  end

  test "work cutoff shortens but cannot extend configured work lifetime and is charged" do
    runtime = runtime()

    {:ok, _, reservation} =
      Runtime.reserve_ingress(runtime, message(1), invocation_deadline: Deadline.now() + 20_000)

    assert reservation.deadline <= Deadline.now() + 2_000
    :ok = Runtime.discard_ingress(runtime, reservation.token)
    {:ok, _, ordinary} = Runtime.reserve_ingress(runtime, message(1), [])
    :ok = Runtime.discard_ingress(runtime, ordinary.token)
    cutoff = Deadline.now() + 500

    {:ok, _, shortened} =
      Runtime.reserve_ingress(runtime, message(1), invocation_deadline: cutoff)

    assert shortened.deadline == cutoff
    assert shortened.admission_deadline == :infinity
    assert shortened.bytes == ordinary.bytes + :erlang.external_size(cutoff)
    :ok = Runtime.discard_ingress(runtime, shortened.token)
  end

  test "suspended confirmation cannot refresh the request-entry cutoff" do
    runtime = runtime()
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.admission)
    on_exit(fn -> if Process.alive?(route.admission), do: :sys.resume(route.admission) end)
    parent = self()

    caller =
      spawn(fn ->
        result = Runtime.request(runtime, message(1), invocation_deadline: Deadline.now() + 30)
        send(parent, {:invocation_return, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    wait(fn -> :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, :_}) != [] end)
    assert_receive {:invocation_return, ^caller, {:error, :handler_timeout}}, 250

    assert [{{:slot, _index}, _token, ^caller}] =
             :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, :_})

    :sys.resume(route.admission)
    wait(fn -> match?(%{reserved: 0, pending_bytes: 0}, Runtime.stats(runtime)) end)
    refute_receive {:http_callback, 1, _}, 10
  end

  test "queued work expires at the captured invocation cutoff without state or output effects" do
    runtime = runtime()
    {:ok, hold} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:http_callback, 1, worker}
    assert_receive {:http_callback_entry, 1, entered, cutoff}
    assert entered < cutoff
    {:ok, queued} = Runtime.submit(runtime, message(2), invocation_deadline: Deadline.now() + 30)

    assert_receive {:arbor_mcp_runtime, ^queued,
                    {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}}},
                   250

    refute_receive {:http_callback, 2, _}, 10
    send(worker, :finish)
    assert_receive {:arbor_mcp_runtime, ^hold, {:ok, %{"result" => 0}}}
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(3))
  end

  defp runtime do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 2000,
         max_queue: 2}
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp message(id, method \\ "read"), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}
  defp wait(fun, remaining \\ 100)
  defp wait(_fun, 0), do: flunk("HTTP deadline state not reached")

  defp wait(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, remaining - 1)
        )
  end
end
