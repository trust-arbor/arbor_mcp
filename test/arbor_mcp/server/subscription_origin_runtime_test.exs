defmodule Arbor.MCP.Server.SubscriptionOriginRuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{Runtime, StdioServer, Subscriptions}
  alias Arbor.MCP.Server.Runtime.{Admission, Ref}
  alias Arbor.MCP.Server.Subscriptions.Mailbox
  alias Arbor.MCP.Test.StdioRuntimeFixture.Device

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.Runtime.CallbackContext

    def init(opts), do: {:ok, %{owner: opts[:test_pid], count: 0}}

    def handle_call_tool("notify_hold", _args, state) do
      :ok = Server.notify_tools_changed(self())
      send(state.owner, {:source_holding, self()})

      receive do
        :release ->
          result(state)

        {:arbor_mcp_cancelled, _, _} ->
          send(state.owner, {:source_cancelled, self()})

          receive do
            :release -> result(state)
          end
      end
    end

    def handle_call_tool("notify_finish", _args, state) do
      :ok = Server.notify_tools_changed(self())
      send(state.owner, {:source_finished, self()})
      result(state)
    end

    def handle_call_tool("publish_finish", _args, state) do
      %{runtime: runtime} = CallbackContext.current()
      :ok = Subscriptions.publish_async("notifications/tools/list_changed", %{}, runtime: runtime)
      send(state.owner, {:source_finished, self()})
      result(state)
    end

    def handle_call_tool("notify_two", _args, state) do
      :ok = Server.notify_tools_changed(self())
      :ok = Server.notify_prompts_changed(self())
      send(state.owner, {:source_finished, self()})
      result(state)
    end

    def handle_request("notifications/change", _params, state) do
      :ok = Server.notify_tools_changed(self())
      send(state.owner, {:source_finished, self()})
      {:noreply, %{state | count: state.count + 1}}
    end

    defp result(state), do: {:ok, %{content: []}, %{state | count: state.count + 1}}
  end

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientInfo" => %{"name" => "origin-proof", "version" => "2"},
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  test "active cancellation drops a queued publication and keeps the healthy subscription" do
    {root, runtime, input, output, listener, ack} = pair()
    input(input, request(1, "notify_hold"))
    assert_receive {:source_holding, worker}
    eventually(fn -> queued(listener) == 1 end)
    input(input, cancellation(1))
    assert_receive {:source_cancelled, ^worker}
    send(worker, :release)
    release(output, ack)
    assert_receive {:write_attempt, _, terminal}
    assert %{"id" => 1, "error" => _} = decode(terminal)
    release(output, terminal)
    refute_receive {:write_attempt, _, _}, 30
    assert Process.alive?(root)
    assert Process.alive?(listener)
    assert scheduler_state(runtime).count == 0
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
  end

  test "successful completion preserves its queued effect until actual IO ACK" do
    {_root, runtime, input, output, listener, ack} = pair()
    input(input, request(2, "notify_finish"))
    assert_receive {:source_finished, _}
    eventually(fn -> queued(listener) == 1 and scheduler_state(runtime).count == 1 end)
    release(output, ack)
    assert_receive {:write_attempt, _, result}
    assert %{"id" => 2, "result" => _} = decode(result)
    release(output, result)
    assert_receive {:write_attempt, _, notification}
    assert %{"method" => "notifications/tools/list_changed"} = decode(notification)
    assert Mailbox.stats(delivery(listener).mailbox).count == 1
    release(output, notification)
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
    assert Process.alive?(listener)
  end

  test "direct callback publication captures the same authoritative origin" do
    {_root, runtime, input, output, listener, ack} = pair()
    input(input, request(3, "publish_finish"))
    assert_receive {:source_finished, _}
    eventually(fn -> queued(listener) == 1 and scheduler_state(runtime).count == 1 end)
    release(output, ack)
    assert_receive {:write_attempt, _, result}
    assert decode(result)["id"] == 3
    release(output, result)
    assert_receive {:write_attempt, _, notification}
    assert decode(notification)["method"] == "notifications/tools/list_changed"
    release(output, notification)
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
  end

  test "a completed source cannot refresh its original cutoff while queued" do
    {_root, runtime, input, output, listener, ack} = pair(request_timeout_ms: 180)

    input(input, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/change",
      "params" => %{"_meta" => @meta}
    })

    assert_receive {:source_finished, _}
    eventually(fn -> queued(listener) == 1 and scheduler_state(runtime).count == 1 end)
    Process.sleep(220)
    release(output, ack)
    refute_receive {:write_attempt, _, _}, 30
    assert Process.alive?(listener)
    assert scheduler_state(runtime).count == 1
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
  end

  test "old subscription ACK APIs cannot release a checked-out runtime loan" do
    {_root, _runtime, _input, output, listener, ack} = pair()
    assert Mailbox.stats(delivery(listener).mailbox).count == 1
    Subscriptions.delivered(listener)
    Arbor.MCP.Server.SubscriptionListener.delivered(listener, make_ref())
    _ = :sys.get_state(listener)
    assert Mailbox.stats(delivery(listener).mailbox).count == 1
    release(output, ack)
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
  end

  test "runtime queue pressure drops pending data and retains the bounded completion loan" do
    opts = [
      services: [subscriptions: [options: [max_lifetime_ms: 5_000, max_queue: 1]]],
      subscription_filter: %{"toolsListChanged" => true, "promptsListChanged" => true}
    ]

    {_root, runtime, input, output, listener, ack} = pair(opts)
    input(input, request(5, "notify_two"))
    assert_receive {:source_finished, _}
    eventually(fn -> delivery(listener).closing? end)
    assert queued(listener) == 1
    assert Mailbox.stats(delivery(listener).mailbox).count == 2
    release(output, ack)
    assert_receive {:write_attempt, _, result}
    assert decode(result)["id"] == 5
    release(output, result)
    assert_receive {:write_attempt, _, complete}
    assert %{"id" => 71, "result" => %{"resultType" => "complete"}} = decode(complete)
    assert Mailbox.stats(delivery(listener).mailbox).count == 1
    monitor = Process.monitor(listener)
    release(output, complete)
    assert_receive {:DOWN, ^monitor, :process, ^listener, :normal}
    assert scheduler_state(runtime).count == 1
    refute_receive {:write_attempt, _, _}, 30
  end

  test "a later canceled source cannot coalesce away an earlier completed source's effect" do
    {_root, runtime, input, output, listener, ack} = pair()

    input(input, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/change",
      "params" => %{"_meta" => @meta}
    })

    assert_receive {:source_finished, _}
    eventually(fn -> queued(listener) == 1 and scheduler_state(runtime).count == 1 end)
    input(input, request(6, "notify_hold"))
    assert_receive {:source_holding, worker}
    eventually(fn -> queued(listener) == 2 end)
    input(input, cancellation(6))
    assert_receive {:source_cancelled, ^worker}
    send(worker, :release)
    release(output, ack)
    assert_receive {:write_attempt, _, terminal}
    assert %{"id" => 6, "error" => _} = decode(terminal)
    release(output, terminal)
    assert_receive {:write_attempt, _, earlier_effect}
    assert decode(earlier_effect)["method"] == "notifications/tools/list_changed"
    release(output, earlier_effect)
    refute_receive {:write_attempt, _, _}, 30
    assert Process.alive?(listener)
    assert scheduler_state(runtime).count == 1
    eventually(fn -> Mailbox.stats(delivery(listener).mailbox).count == 0 end)
  end

  defp pair(opts \\ []) do
    input = start_supervised!({Device, [owner: self()]}, id: make_ref())
    output = start_supervised!({Device, [owner: self(), hold: true]}, id: make_ref())

    defaults = [
      module: Handler,
      handler_args: [test_pid: self()],
      protocol_mode: :modern_only,
      services: [subscriptions: [options: [max_lifetime_ms: 5_000]]],
      authorize_subscription_filter: fn requested, _ -> {:ok, requested} end,
      authorize_subscription_publication: fn _, _, _ -> true end,
      stdio_input: input,
      stdio_output: output,
      stdio_startup_delay: 0,
      request_timeout_ms: 2_000,
      output_timeout_ms: 1_000,
      stdio_eof_timeout_ms: 3_000,
      shutdown_timeout_ms: 100
    ]

    filter = Keyword.get(opts, :subscription_filter, %{"toolsListChanged" => true})

    {:ok, root} =
      StdioServer.start_link(Keyword.merge(defaults, Keyword.delete(opts, :subscription_filter)))

    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:ok, runtime} = Runtime.ref(root)

    input(input, %{
      "jsonrpc" => "2.0",
      "id" => 71,
      "method" => "subscriptions/listen",
      "params" => %{"notifications" => filter, "_meta" => @meta}
    })

    assert_receive {:write_attempt, _, ack}
    assert decode(ack)["method"] == "notifications/subscriptions/acknowledged"
    {:ok, edge} = Runtime.edge(runtime)
    listener = :sys.get_state(edge).subscriptions[71]
    assert is_pid(listener)
    {root, runtime, input, output, listener, ack}
  end

  defp request(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}, "_meta" => @meta}
    }

  defp cancellation(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp input(device, message),
    do: GenServer.call(device, {:input, Jason.encode!(message) <> "\n", false})

  defp decode(bytes), do: Jason.decode!(String.trim(bytes))
  defp delivery(listener), do: :sys.get_state(listener).runtime_delivery
  defp queued(listener), do: length(delivery(listener).queue)

  defp release(output, bytes) do
    assert :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^bytes}
  end

  defp scheduler_state(runtime) do
    {:ok, %{scheduler: scheduler}} = Admission.route(Ref.table(runtime))
    :sys.get_state(scheduler).handler_state
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
