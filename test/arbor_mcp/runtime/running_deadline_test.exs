defmodule Arbor.MCP.Server.RuntimeRunningDeadlineTest do
  # This exact 20 ms running-deadline proof runs after asynchronous cases.
  # Competing cases must not consume the whole admission budget before entry.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.CallbackContext

  defmodule Handler do
    def init(parent), do: {:ok, %{parent: parent, counter: 0}}

    def dispatch(%{"id" => id, "method" => "hold"}, _handler, state, _opts) do
      send(
        state.parent,
        {:held, self(), System.monotonic_time(:millisecond), CallbackContext.current().deadline}
      )

      receive do
        :release -> response(id, state)
        :mutate -> response(id, %{state | counter: 900})
      end
    end

    def dispatch(%{"id" => id, "method" => "inc"}, _handler, state, _opts),
      do: response(id, %{state | counter: state.counter + 1})

    defp response(id, state),
      do: {:response, %{"jsonrpc" => "2.0", "id" => id, "result" => state.counter}, state}
  end

  test "running deadline reaps blocked work before another stateful callback starts" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: self(),
         request_timeout_ms: 100,
         cancel_grace_ms: 30}
      )

    {:ok, runtime} = Runtime.ref(root)
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "hold"}
    assert {:ok, token} = Runtime.submit(runtime, request, timeout: 20)
    assert_receive {:held, worker, entered, original_deadline}, 1_000
    assert entered < original_deadline
    monitor = Process.monitor(worker)

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
             Runtime.await(token, 1_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000

    assert {:ok, %{"result" => 1}} =
             Runtime.request(runtime, %{"jsonrpc" => "2.0", "id" => 2, "method" => "inc"})

    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end
end
