defmodule Arbor.MCP.Server.Runtime.HTTPFailureDeliveryTest do
  # A request that times out over HTTP must still reach its client as a
  # JSON-RPC error, even when the output controller is slow to answer the
  # gateway. The gateway used to give the controller 50 ms; on a timeout it
  # retired the binding, so the failure frame the controller queued afterwards
  # was discarded and the client never got the error.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    CallbackContext,
    Deadline,
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Ref
  }

  defmodule Handler do
    def init(opts), do: {:ok, %{test: opts[:test]}}

    def dispatch(%{"id" => id}, _module, state, _opts) do
      send(state.test, {:entered, id, CallbackContext.current().deadline})
      receive do: (:finish -> :ok)
      {:response, %{"jsonrpc" => "2.0", "id" => id, "result" => true}, state}
    end

    def dispatch(_notification, _module, state, _opts), do: {:notification, state}
  end

  test "a timeout error reaches the client although the output controller answers late" do
    %{runtime: _runtime, controller: controller, binding: binding, domain: domain} =
      failure_waiting_on_controller()

    # Longer than the 50 ms the gateway used to wait for that answer.
    Process.sleep(200)
    :ok = :sys.resume(controller)

    assert_receive {:mcp_http_output_wake, ^domain, nonce}, 5_000
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, effect, wire} = HTTPWriterRegistry.checkout(binding)

    assert %{"id" => 7, "error" => %{"code" => -32603, "message" => "Request timeout"}} =
             Jason.decode!(wire)

    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
  end

  test "a request waiting on the output controller does not hold up another request's 202" do
    %{runtime: runtime, controller: controller} = failure_waiting_on_controller()
    parent = self()

    # A notification needs no Controller to be accepted: only the gateway
    # must publish its 202, which it cannot do while it waits for request 7.
    socket =
      spawn(fn ->
        {:ok, notice} = HTTPWriterProxy.capture(runtime, timeout: 1_000)
        {:ok, %{deadline: deadline}} = HTTPWriterBinding.validate(notice, runtime)
        {:ok, {domain, _}} = HTTPWriterBinding.address(notice)

        {:ok, _token} =
          HTTPGateway.submit(runtime, notice, %{"jsonrpc" => "2.0", "method" => "note"})

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

    :ok = :sys.resume(controller)
  end

  # Request 7 times out at its cutoff while the Controller is suspended. The
  # test answers the scheduler's {:failed, ...} call as the Controller would,
  # so the gateway goes on to ask the still-suspended Controller for the
  # failure frame. Returns once that request is in the Controller's mailbox.
  defp failure_waiting_on_controller do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 2_000,
         execution: :stateful}
      )

    {:ok, runtime} = Runtime.ref(root)
    [{:output_controller, controller}] = :ets.lookup(Ref.table(runtime), :output_controller)
    trace_mailbox(controller)

    # Fast step: capture, submit and entry land inside the cutoff. The held
    # call never returns, so the request times out at that cutoff.
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 250)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "hold"}
    {:ok, token} = HTTPGateway.submit(runtime, binding, request)
    assert_receive {:entered, 7, cutoff}, 1_000

    :ok = :sys.suspend(controller)
    on_exit(fn -> if Process.alive?(controller), do: :sys.resume(controller) end)

    assert_receive {:trace, ^controller, :receive,
                    {:"$gen_call", scheduler, {:failed, ^token, :handler_timeout}}},
                   5_000

    GenServer.reply(scheduler, :ok)

    assert_receive {:trace, ^controller, :receive,
                    {:"$gen_call", _gateway, {:http_failure, ^token, ^binding, _format}}},
                   5_000

    assert Deadline.now() >= cutoff
    %{runtime: runtime, controller: controller, binding: binding, domain: domain}
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
