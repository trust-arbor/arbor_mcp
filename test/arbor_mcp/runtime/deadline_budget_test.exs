defmodule Arbor.MCP.Server.Runtime.DeadlineBudgetTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, ByteBudget, Deadline, Ref}

  defmodule Handler do
    def init(opts), do: {:ok, %{test_pid: opts[:test_pid], count: 0}}

    def dispatch(request, _handler, state, _opts) do
      send(state.test_pid, {:deadline_callback, request["id"], self()})

      count =
        if request["method"] == "hold" do
          receive do
            :mutate -> 900
          end
        else
          state.count
        end

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => count},
       %{state | count: count}}
    end
  end

  test "suspended confirmation respects the original server deadline and retains uncertain credit" do
    {runtime, route} = start_runtime()
    :sys.suspend(route.admission)
    on_exit(fn -> resume(route.admission) end)
    observe_admission(runtime)
    caller = requester(runtime, timeout: 40)
    candidate = wait_for_candidate(runtime)
    assert candidate.admission_deadline == :infinity

    assert_receive {:deadline_returned, ^caller, {:error, :handler_timeout}}, 500
    assert [{{:slot, _index}, _token, ^caller}] = slots(runtime)
    :sys.resume(route.admission)
    wait_for_empty(runtime)
    refute_receive :expired_request_admitted, 20
    refute_receive {:deadline_callback, 1, _worker}, 20
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
    inspect_caller(caller)
  end

  test "a shorter synchronous wait also bounds confirmation without accepting expired work" do
    {runtime, route} = start_runtime()
    :sys.suspend(route.admission)
    on_exit(fn -> resume(route.admission) end)
    observe_admission(runtime)
    caller = requester(runtime, timeout: 1_000, await_timeout: 40)
    candidate = wait_for_candidate(runtime)
    assert candidate.admission_deadline < candidate.deadline

    assert_receive {:deadline_returned, ^caller, {:error, :await_timeout}}, 500
    assert [{{:slot, _index}, _token, ^caller}] = slots(runtime)
    :sys.resume(route.admission)
    wait_for_empty(runtime)
    refute_receive :expired_request_admitted, 20
    refute_receive {:deadline_callback, 1, _worker}, 20
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
    inspect_caller(caller)
  end

  test "time spent confirming is deducted from waiting while already accepted work can commit" do
    {runtime, route} = start_runtime()
    :sys.suspend(route.admission)
    on_exit(fn -> resume(route.admission) end)
    caller = requester(runtime, timeout: 2_000, await_timeout: 350)
    candidate = wait_for_candidate(runtime)
    Process.sleep(max(0, candidate.admission_deadline - Deadline.now() - 80))
    :sys.resume(route.admission)
    assert_receive {:deadline_callback, 1, worker}, 200
    # A refreshed 350 ms receive timeout would miss this allowance.
    assert_receive {:deadline_returned, ^caller, {:error, :await_timeout}}, 180
    assert %{active: 1, reserved: 1} = Runtime.stats(runtime)
    send(worker, :mutate)
    wait_for_empty(runtime)
    inspect_caller(caller)
    assert {:ok, %{"result" => 900}} = Runtime.request(runtime, message(2, "read"))
  end

  test "zero and invalid waits do not admit new work or invoke callbacks" do
    {runtime, _route} = start_runtime()

    assert {:error, :await_timeout} =
             Runtime.request(runtime, message(1, "read"), await_timeout: 0)

    for wait <- [-1, :invalid, 1.5, 4_294_967_296, Bitwise.bsl(1, 65_536)] do
      assert {:error, :invalid_await_timeout} =
               Runtime.request(runtime, message(1, "read"), await_timeout: wait)
    end

    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
    refute_receive {:deadline_callback, 1, _worker}, 20
  end

  test "a suspended caller cannot consume success after its original wait deadline" do
    {runtime, _route} = start_runtime()
    caller = requester(runtime, timeout: 2_000, await_timeout: 150)
    assert_receive {:deadline_callback, 1, worker}
    :erlang.suspend_process(caller)
    on_exit(fn -> resume_caller(caller) end)
    [{{:slot, _slot}, token, ^caller}] = slots(runtime)
    {:ok, reservation} = Admission.current(Ref.table(runtime), token)
    Process.sleep(max(0, reservation.admission_deadline - Deadline.now() + 10))
    send(worker, :mutate)
    wait_for_empty(runtime)
    :erlang.resume_process(caller)
    assert_receive {:deadline_returned, ^caller, {:error, :await_timeout}}
    inspect_caller(caller)
    assert {:ok, %{"result" => 900}} = Runtime.request(runtime, message(2, "read"))
  end

  test "malformed or expired low-level admission deadlines leave all batch credit available" do
    {runtime, _route} = start_runtime()

    assert {:error, :invalid_admission_deadline} =
             Runtime.submit(runtime, message(1, "read"), admission_deadline: :invalid)

    for invalid <- [Bitwise.bsl(1, 65_536), -9_223_372_036_854_775_809] do
      assert {:error, :invalid_admission_deadline} =
               Runtime.submit(runtime, message(1, "read"), admission_deadline: invalid)
    end

    assert {:error, :await_timeout} =
             RuntimeIngress.reserve_ingress(runtime, [nil, 42],
               owner: self(),
               reply_to: self(),
               admission_deadline: Deadline.now() - 1
             )

    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)

    assert {:ok, _route, held} =
             RuntimeIngress.reserve_ingress(runtime, [nil, 42], [])

    assert %{reserved: 2} = Runtime.stats(runtime)
    assert :ok = RuntimeIngress.discard_ingress(runtime, held.token)
    wait_for_empty(runtime)
  end

  defp start_runtime do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test_pid: self()],
         max_queue: 1,
         request_timeout_ms: 2_000}
      )

    {:ok, runtime} = Runtime.ref(root)
    {:ok, route} = Admission.route(Ref.table(runtime))
    {runtime, route}
  end

  defp requester(runtime, opts) do
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:deadline_returned, self(), Runtime.request(runtime, message(1, "hold"), opts)}
        )

        receive do
          :inspect_mailbox ->
            send(parent, {:deadline_mailbox, self(), Process.info(self(), :messages)})
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    caller
  end

  defp inspect_caller(caller) do
    send(caller, :inspect_mailbox)
    assert_receive {:deadline_mailbox, ^caller, {:messages, []}}
  end

  defp observe_admission(runtime) do
    id = {__MODULE__, make_ref()}
    parent = self()
    root = Ref.supervisor(runtime)

    :ok =
      :telemetry.attach(
        id,
        [:arbor_mcp, :server, :request, :admitted],
        fn _event, _measurements, metadata, _config ->
          if metadata.runtime == root, do: send(parent, :expired_request_admitted)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp wait_for_candidate(runtime) do
    wait_for(fn ->
      case slots(runtime) do
        [{_key, token, _producer}] -> ByteBudget.candidate(Ref.table(runtime), token)
        _ -> nil
      end
    end)
  end

  defp slots(runtime), do: :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, :_})

  defp wait_for_empty(runtime),
    do: wait_for(fn -> match?(%{reserved: 0, pending_bytes: 0}, Runtime.stats(runtime)) end)

  defp wait_for(fun, attempts \\ 100)
  defp wait_for(_fun, 0), do: flunk("deadline test did not reach its expected state")

  defp wait_for(fun, attempts) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        Process.sleep(5)
        wait_for(fun, attempts - 1)
    end
  end

  defp message(id, method), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}
  defp resume(pid), do: if(Process.alive?(pid), do: :sys.resume(pid))

  defp resume_caller(caller) do
    if Process.alive?(caller), do: :erlang.resume_process(caller)
  rescue
    ArgumentError -> :ok
  end
end
