defmodule Arbor.MCP.Server.Runtime.HTTPGatewayAsyncControllerTest do
  # One HTTP gateway serves every request of a runtime. While it waits for the
  # output controller about one request, it must still serve the others: a
  # notification's 202 needs no controller at all, so it has to be published
  # within its own deadline even while the controller is stalled.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Ref
  }

  defmodule Handler do
    def init(opts), do: {:ok, %{test: opts[:test]}}

    def dispatch(%{"id" => id} = request, _module, state, _opts) do
      send(state.test, {:entered, id, self()})
      if request["method"] == "hold", do: receive(do: (:finish -> :ok))
      {:response, %{"jsonrpc" => "2.0", "id" => id, "result" => id}, state}
    end

    def dispatch(_notification, _module, state, _opts), do: {:notification, state}
  end

  setup do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 10_000,
         execution: :stateful,
         max_queue: 8}
      )

    {:ok, runtime} = Runtime.ref(root)
    [{:output_controller, controller}] = :ets.lookup(Ref.table(runtime), :output_controller)
    trace_mailbox(controller)
    on_exit(fn -> if Process.alive?(controller), do: :sys.resume(controller) end)
    %{runtime: runtime, controller: controller}
  end

  test "a result's delivery waiting on the controller does not hold up another request's 202",
       %{runtime: runtime, controller: controller} do
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    {:ok, token} = HTTPGateway.submit(runtime, binding, request(1, "hold"))
    assert_receive {:entered, 1, worker}, 1_000

    suspend_controller_after_result(runtime, controller, token, worker)

    assert_receive {:trace, ^controller, :receive, {:"$gen_call", _from, {:deliver, ^token, _}}},
                   5_000

    assert_notification_accepted(runtime)
    :ok = :sys.resume(controller)

    assert_receive {:mcp_http_output_wake, ^domain, nonce}, 5_000
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, effect, wire} = HTTPWriterRegistry.checkout(binding)
    assert %{"id" => 1, "result" => 1} = Jason.decode!(wire)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
  end

  test "a batch's finish waiting on the controller does not hold up another request's 202",
       %{runtime: runtime, controller: controller} do
    {:ok, route} = Admission.route(Ref.table(runtime))
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    {:ok, token} = HTTPGateway.submit(runtime, binding, [request(1, "hold")])
    assert_receive {:entered, 1, worker}, 1_000

    suspend_controller_after_result(runtime, controller, token, worker)

    # Stand in for the controller's answer to the member delivery: it stages
    # the member and settles it with the scheduler. Only the batch's finish
    # is then left waiting on the suspended controller.
    assert_receive {:trace, ^controller, :receive,
                    {:"$gen_call", member, {:deliver, ^token, _ticket}}},
                   5_000

    GenServer.reply(member, :ok)
    send(route.scheduler, {:runtime_output_settled, token, :ok})

    assert_receive {:trace, ^controller, :receive, {:"$gen_call", _from, {:finish, ^token}}},
                   5_000

    assert_notification_accepted(runtime)
    :ok = :sys.resume(controller)

    assert_receive {:mcp_http_output_wake, ^domain, nonce}, 5_000
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, effect, wire} = HTTPWriterRegistry.checkout(binding)
    assert [%{"id" => 1, "result" => 1}] = Jason.decode!(wire)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
  end

  test "an error the gateway authors waiting on the controller does not hold up another 202",
       %{runtime: runtime, controller: controller} do
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    :ok = :sys.suspend(controller)
    {:ok, token} = HTTPGateway.submit(runtime, binding, [17])

    # The gateway answers the invalid member itself, through the controller.
    assert_receive {:trace, ^controller, :receive, {:"$gen_call", _from, request}}
                   when elem(request, 0) in [:register, :edge_result] and
                          elem(request, 1) == token,
                   5_000

    assert_notification_accepted(runtime)
    :ok = :sys.resume(controller)

    assert_receive {:mcp_http_output_wake, ^domain, nonce}, 5_000
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, effect, wire} = HTTPWriterRegistry.checkout(binding)
    assert [%{"id" => nil, "error" => %{"code" => -32600}}] = Jason.decode!(wire)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
  end

  defp request(id, method), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  # The controller hands a finished result to the gateway from inside its
  # Admission.terminal/3 call. Holding Admission keeps the controller in that
  # call while a :sys.suspend is queued behind it, so the controller is
  # suspended exactly after handing over the result and before the gateway's
  # request about it arrives.
  defp suspend_controller_after_result(runtime, controller, token, worker) do
    [{:admission, admission}] = :ets.lookup(Ref.table(runtime), :admission)
    trace_mailbox(admission)
    :ok = :sys.suspend(admission)
    on_exit(fn -> if Process.alive?(admission), do: :sys.resume(admission) end)
    send(worker, :finish)

    assert_receive {:trace, ^admission, :receive,
                    {:"$gen_call", {^controller, _tag}, {:terminal, ^token, {:ok, _result}}}},
                   5_000

    spawn(fn -> :sys.suspend(controller, :infinity) end)
    assert_receive {:trace, ^controller, :receive, {:system, _from, :suspend}}, 5_000
    :ok = :sys.resume(admission)
  end

  # A notification on its own binding, with a 1 s cutoff, must get its 202
  # while the controller is suspended.
  defp assert_notification_accepted(runtime) do
    parent = self()

    socket =
      spawn(fn ->
        {:ok, notice} = HTTPWriterProxy.capture(runtime, timeout: 1_000)
        {:ok, %{deadline: deadline}} = HTTPWriterBinding.validate(notice, runtime)
        {:ok, {domain, _}} = HTTPWriterBinding.address(notice)
        {:ok, _} = HTTPGateway.submit(runtime, notice, %{"jsonrpc" => "2.0", "method" => "note"})

        accepted =
          receive do
            {:mcp_http_output_wake, ^domain, nonce} ->
              :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)

              with {:ok, effect, ""} <- HTTPWriterRegistry.checkout(notice),
                   :ok <- HTTPWriterRegistry.complete(effect, :ok),
                   do: Deadline.now() < deadline
          after
            Deadline.remaining(deadline) -> :expired
          end

        send(parent, {:accepted, self(), accepted})
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)
    assert_receive {:accepted, ^socket, accepted}, 5_000

    assert accepted == true,
           "the notification's 202 was not published in time: #{inspect(accepted)}"
  end

  # Receive traces report each message as it is queued, even while the
  # controller is suspended.
  defp trace_mailbox(controller) do
    on_exit(fn ->
      if Process.alive?(controller), do: :erlang.trace(controller, false, [:receive])
    end)

    assert 1 == :erlang.trace(controller, true, [:receive])
  end
end
