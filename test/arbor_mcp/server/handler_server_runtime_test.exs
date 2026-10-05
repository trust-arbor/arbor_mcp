defmodule Arbor.MCP.Server.HandlerServerRuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, HandlerServer, Runtime}
  alias Arbor.MCP.Server.Runtime.{Admission, CallbackContext, Ref}
  alias Arbor.MCP.Transport.{Local, Test}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    defoverridable handle_call: 3

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:handler_initialized, self()})

      {:ok,
       %{
         test_pid: opts[:test_pid],
         count: 0,
         cancelled_requests: MapSet.new(),
         block_initialize: opts[:block_initialize] || false
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      if state.block_initialize do
        send(state.test_pid, {:initialize_blocked, self()})

        receive do
          :release_initialize -> :ok
        end
      end

      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "runtime", version: "2"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_call_tool("hold", _arguments, state) do
      context = Context.current()
      send(state.test_pid, {:holding, context.request_id, self(), state.count})
      send(state.test_pid, {:callback_scope, self(), Context.scope()})
      hold(state)
    end

    def handle_call_tool("inc", _arguments, state) do
      send(state.test_pid, {:incremented, self()})
      result(state.count + 1, %{state | count: state.count + 1})
    end

    def handle_call_tool("read", _arguments, state), do: result(state.count, state)

    def handle_call_tool("scope_status", _arguments, state) do
      scope = Context.scope()
      id = Context.current().request_id

      {:ok,
       %{
         structuredContent: %{cancelled: MapSet.member?(state.cancelled_requests, {scope, id})},
         content: []
       }, state}
    end

    def handle_call_tool("reverse", _arguments, state) do
      %{runtime: runtime} = CallbackContext.current()
      {:ok, roots} = Server.list_roots(runtime)
      {:ok, %{structuredContent: roots, content: []}, state}
    end

    def handle_call_tool("retired_controls", _arguments, state) do
      %{runtime: runtime} = CallbackContext.current()
      send(state.test_pid, {:retired_control_worker, self()})

      receive do
        {:arbor_mcp_cancelled, _token, _reason} ->
          send(state.test_pid, {:retired_control_cancelled, self()})
      end

      receive do
        :issue_controls ->
          roots = Server.list_roots(runtime, 100)
          Server.notify_progress(runtime, "retired", 1)
          Server.send_log_message(runtime, :info, "retired", nil)
          Server.cancel_request(runtime, 1)
          send(state.test_pid, {:retired_controls_done, roots})
      end

      result(900, %{state | count: 900})
    end

    def handle_call_tool("progress_then_finish", _arguments, state) do
      %{runtime: runtime} = CallbackContext.current()
      send(state.test_pid, {:progress_worker, self()})

      receive do
        :issue_progress -> :ok
      end

      accepted = Server.notify_progress(runtime, "done", 1)
      send(state.test_pid, {:progress_accepted, accepted})
      result(state.count + 1, %{state | count: state.count + 1})
    end

    def handle_call_tool("deadline_controls", _arguments, state) do
      %{runtime: runtime} = CallbackContext.current()
      send(state.test_pid, {:deadline_control_worker, self()})

      receive do
        :issue_controls -> :ok
      end

      roots = Server.list_roots(runtime, 100)
      progress = Server.notify_progress(runtime, "expired", 1)
      send(state.test_pid, {:deadline_controls_done, roots, progress})
      result(900, %{state | count: 900})
    end

    @impl true
    def handle_call(:read, _from, state), do: {:reply, state.count, state}
    def handle_call(:cancellations, _from, state), do: {:reply, state.cancelled_requests, state}
    def handle_call(:caller, {caller, _tag}, state), do: {:reply, {caller, self()}, state}
    def handle_call(:reply_proxy, from, state), do: {:reply, from, state}

    def handle_call(:hold_reply_proxy, from, state) do
      GenServer.reply(from, :premature_reply)
      send(state.test_pid, {:reply_proxy_waiting, self(), from})

      receive do
        :release -> {:reply, state.count + 1, %{state | count: state.count + 1}}
      end
    end

    def handle_call({:add, count}, _from, state),
      do: {:reply, state.count + count, %{state | count: state.count + count}}

    @impl true
    def handle_cast({:add, count}, state), do: {:noreply, %{state | count: state.count + count}}

    def terminate(reason, state),
      do: send(state.test_pid, {:handler_terminated, self(), reason, state.count})

    defp hold(state) do
      receive do
        :release ->
          result(state.count + 1, %{state | count: state.count + 1})

        :probe ->
          send(state.test_pid, {:cancel_probe, self(), Context.cancelled?()})
          hold(state)

        {:arbor_mcp_cancelled, _token, _reason} ->
          send(state.test_pid, {:cancel_probe, self(), Context.cancelled?()})
          result(900, %{state | count: 900})
      end
    end

    defp result(count, state),
      do: {:ok, %{structuredContent: %{count: count}, content: []}, state}
  end

  defmodule BlockingTracker do
    @behaviour Arbor.MCP.Server.CancellationTracker
    alias Arbor.MCP.Server.CancellationTracker.Default

    def mark_cancelled(id, state) do
      send(state.test_pid, {:tracker_started, id, self(), state.count})
      send(state.test_pid, {:tracker_scope, id, Context.scope()})

      receive do
        :release_tracker -> :ok
      end

      Default.mark_cancelled(id, state)
    end
  end

  test "MessageProcessor runtime roots share state and cancel only the supplied session" do
    {root, _transport} = start_pair()
    opts = %{server: root}

    request =
      Task.async(fn ->
        tool(17, "hold")
        |> MessageProcessor.new(transport: :http, session_id: "session-one")
        |> MessageProcessor.process(opts)
      end)

    assert_receive {:holding, 17, callback, 0}
    assert_receive {:callback_scope, ^callback, {:message_processor, "session-one"}}
    assert Context.scope() == nil

    cancel(17)
    |> MessageProcessor.new(transport: :http, session_id: "session-two")
    |> MessageProcessor.process(opts)

    send(callback, :probe)
    assert_receive {:cancel_probe, ^callback, false}

    cancelled =
      cancel(17)
      |> MessageProcessor.new(transport: :http, session_id: "session-one")
      |> MessageProcessor.process(opts)

    assert cancelled.response == nil
    assert_receive {:cancel_probe, ^callback, true}
    assert Task.await(request).response["error"]["code"] == -32001
    assert Server.call(root, :read) == 0
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)

    next =
      tool(17, "inc")
      |> MessageProcessor.new(transport: :http, session_id: "session-one")
      |> MessageProcessor.process(opts)

    assert %{"result" => %{"structuredContent" => %{"count" => 1}}} = next.response
    assert Server.call(root, :read) == 1
  end

  test "runtime owns initialization and state while RPC and custom callbacks commit in order" do
    {root, transport} = start_pair()
    assert_receive {:handler_initialized, state_owner}
    {:ok, edge} = Runtime.edge(root)
    refute state_owner in [root, edge]
    assert {:ok, ^transport} = Test.send_message(tool(1, "hold"), transport)
    assert_receive {:holding, 1, callback, 0}
    refute callback in [root, edge, state_owner]
    refute Map.has_key?(:sys.get_state(edge), :handler_state)

    assert :ok = Server.cast(root, {:add, 10})
    call = Task.async(fn -> Server.call(root, {:add, 100}) end)
    wait_for(fn -> Runtime.stats(root).queued == 2 end)
    assert Server.get_pending_requests(root) == [1]
    send(callback, :release)
    assert_receive {:transport_message, response}
    assert response_map(response)["result"]["structuredContent"]["count"] == 1
    assert Task.await(call) == 111
    assert Server.call(root, :read) == 111
  end

  test "scheduled custom callbacks retain the original caller PID through both ingress APIs" do
    {root, _transport} = start_pair()
    caller = self()
    assert {^caller, worker} = Server.call(root, :caller)
    {:ok, edge} = Runtime.edge(root)
    refute worker in [caller, root, edge]
    assert {^caller, other_worker} = GenServer.call(edge, :caller)
    refute other_worker in [caller, root, edge]
  end

  test "a proxy reply cannot settle the original caller before the scheduler commits" do
    {root, _transport} = start_pair()
    call = Task.async(fn -> Server.call(root, :hold_reply_proxy) end)
    caller = call.pid
    assert_receive {:reply_proxy_waiting, worker, {^caller, _tag}}
    assert Task.yield(call, 20) == nil
    assert {:messages, []} = Process.info(caller, :messages)
    send(worker, :release)
    assert Task.await(call) == 1
    assert Server.call(root, :read) == 1
  end

  test "a proxy reply after callback completion does not enter the original caller mailbox" do
    {root, _transport} = start_pair()
    caller = self()
    assert {^caller, proxy_tag} = from = Server.call(root, :reply_proxy)
    assert :ok = GenServer.reply(from, :late_reply)
    refute_receive {^proxy_tag, :late_reply}, 30
  end

  test "supported ingress reserves count before a suspended edge can receive another payload" do
    {root, transport} = start_pair(max_queue: 0, max_control_queue: 1)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert {:ok, transport} = Test.send_message(tool(1, "inc"), transport)

    assert {:error, {:transport_error, :server_busy}} =
             Test.send_message(tool(2, "inc"), transport)

    assert %{reserved: 1} = Runtime.stats(root)
    {:messages, messages} = Process.info(edge, :messages)
    assert [:runtime_ingress_ready] = messages
    :sys.resume(edge)
    assert_receive {:transport_message, response}
    assert response_map(response)["result"]["structuredContent"]["count"] == 1
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 1
  end

  test "supported ingress rejects bytes before payload enqueue and never invokes rejected work" do
    {root, transport} = start_pair(max_pending_bytes: 300)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert {:ok, transport} = Test.send_message(tool(1, "inc"), transport)

    large =
      put_in(tool(2, "inc"), ["params", "arguments"], %{"payload" => String.duplicate("x", 300)})

    assert {:error, {:transport_error, :server_busy}} = Test.send_message(large, transport)
    assert %{reserved: 1, pending_bytes: bytes} = Runtime.stats(root)
    {:messages, messages} = Process.info(edge, :messages)
    assert length(messages) == 1
    assert bytes <= 300
    :sys.resume(edge)
    assert_receive {:transport_message, _response}, 1_000
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 1
  end

  test "cancellation reaches admitted wire IDs before edge promotion without poisoning unknown IDs" do
    {root, transport} = start_pair(max_queue: 1)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert {:ok, transport} = Test.send_message(tool(1, "inc"), transport)
    assert {:ok, transport} = Test.send_message(cancel(1), transport)
    assert {:ok, transport} = Test.send_message(cancel(2), transport)
    assert {:ok, _transport} = Test.send_message(tool(2, "inc"), transport)
    :sys.resume(edge)
    assert_receive {:transport_message, cancelled}
    assert %{"id" => 1, "error" => %{"code" => -32001}} = response_map(cancelled)
    assert_receive {:transport_message, accepted}

    assert %{"id" => 2, "result" => %{"structuredContent" => %{"count" => 1}}} =
             response_map(accepted)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 1
    {:ok, runtime} = Runtime.ref(root)

    refute Enum.any?(:ets.tab2list(Ref.table(runtime)), fn object ->
             match?({{:wire_cancel, _, _}, _}, object)
           end)
  end

  test "public helper controls reserve count and bytes before reaching a suspended edge" do
    {root, _transport} = start_pair(max_control_queue: 1, max_control_bytes: 200)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert :ok = Server.notify_progress(root, "one", 1)
    assert {:error, :server_busy} = Server.notify_progress(root, "two", 2)
    # The stats call fences the asynchronous coalesced wake in admission.
    assert %{reserved: 1, control_bytes: bytes} = Runtime.stats(root)
    {:messages, messages} = Process.info(edge, :messages)
    assert [:runtime_ingress_ready] = messages
    assert bytes <= 200
    :sys.resume(edge)
    assert_receive {:transport_message, progress}
    assert response_map(progress)["params"]["progressToken"] == "one"
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)

    assert {:error, :server_busy} =
             Server.send_log_message(root, :info, String.duplicate("x", 200), nil)

    assert %{pending_bytes: 0, control_bytes: 0} = Runtime.stats(root)
  end

  test "a callback waiting on reverse RPC accepts its response when callback admission is full" do
    {root, transport} = start_pair(max_queue: 0, max_control_queue: 1)
    assert {:ok, transport} = Test.send_message(tool(1, "reverse"), transport)
    assert_receive {:transport_message, encoded_request}
    request = response_map(encoded_request)
    assert request["method"] == "roots/list"
    assert %{reserved: 2, active: 1} = Runtime.stats(root)

    assert {:ok, _transport} =
             Test.send_message(
               %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"roots" => []}},
               transport
             )

    assert_receive {:transport_message, encoded_response}

    assert %{"id" => 1, "result" => %{"structuredContent" => %{"roots" => []}}} =
             response_map(encoded_response)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert %{pending_bytes: 0, control_bytes: 0} = Runtime.stats(root)
  end

  test "two runtimes reuse an ID and cancellation stays scoped even under full admission" do
    {one, transport_one} = start_pair(max_queue: 0, cancel_grace_ms: 200)
    {two, transport_two} = start_pair(max_queue: 0, cancel_grace_ms: 200)
    assert {:ok, transport_one} = Test.send_message(tool("shared", "hold"), transport_one)
    assert_receive {:holding, "shared", worker_one, 0}
    assert {:ok, ^transport_two} = Test.send_message(tool("shared", "hold"), transport_two)
    assert_receive {:holding, "shared", worker_two, 0}

    assert {:ok, _transport} = Test.send_message(cancel("shared"), transport_one)
    assert_receive {:cancel_probe, ^worker_one, true}
    assert_receive {:transport_message, encoded_cancel}
    assert %{"id" => "shared", "error" => %{"code" => -32001}} = response_map(encoded_cancel)
    send(worker_two, :probe)
    assert_receive {:cancel_probe, ^worker_two, false}
    send(worker_two, :release)
    assert_receive {:transport_message, encoded_response}
    assert response_map(encoded_response)["result"]["structuredContent"]["count"] == 1
    wait_for(fn -> Runtime.stats(one).reserved == 0 and Runtime.stats(two).reserved == 0 end)
    assert Server.call(one, :read) == 0
    assert Server.call(two, :read) == 1
  end

  test "BEAM ingress uses the same scheduler and preserves sequential legacy batch results" do
    {root, transport} = start_pair(transport: :beam, max_queue: 2)

    requests = [
      tool(1, "inc"),
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      tool(2, "inc")
    ]

    assert {:ok, _transport} = Local.send_message(requests, transport)
    assert_receive {:transport_message, responses}
    assert Enum.map(responses, & &1["id"]) == [1, 2]
    assert Enum.map(responses, & &1["result"]["structuredContent"]["count"]) == [1, 2]
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 2
  end

  test "modern-only mode rejects batches before dispatching any member" do
    {root, transport} = start_pair(protocol_mode: :modern_only)
    assert_rejected_batch(root, transport, [tool(1, "inc"), tool(2, "inc")])
  end

  test "a connection pinned by modern metadata rejects later legacy-shaped batches" do
    {root, transport} = start_pair()
    assert {:ok, transport} = Test.send_message(modern(tool(1, "read")), transport)
    assert_receive {:transport_message, response}
    assert response_map(response)["result"]["resultType"] == "complete"
    assert_rejected_batch(root, transport, [tool(2, "inc"), tool(3, "inc")])
  end

  test "modern metadata in the first batch envelope rejects the whole array before callbacks" do
    {root, transport} = start_pair()
    assert_rejected_batch(root, transport, [tool(1, "inc"), modern(tool(2, "inc"))])
  end

  test "root death cleans its edge and scheduler while a sibling continues working" do
    {root, transport} = start_pair()
    {sibling, sibling_transport} = start_pair()
    {:ok, edge} = Runtime.edge(root)
    {:ok, runtime} = Runtime.ref(root)
    {:ok, route} = Admission.route(Ref.table(runtime))
    assert {:ok, _transport} = Test.send_message(tool(1, "hold"), transport)
    assert_receive {:holding, 1, callback, 0}
    monitors = for pid <- [edge, route.scheduler, callback], do: {pid, Process.monitor(pid)}
    Process.unlink(root)
    Process.exit(root, :kill)

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 1_000)

    assert {:ok, _transport} = Test.send_message(tool(1, "inc"), sibling_transport)
    assert_receive {:transport_message, response}
    assert response_map(response)["result"]["structuredContent"]["count"] == 1
    assert Process.alive?(sibling)
  end

  test "replacing a peer drops old completions and permits scoped request ID reuse" do
    {root, old_transport} = start_pair(cancel_grace_ms: 200)
    assert {:ok, old_transport} = Test.send_message(tool(1, "hold"), old_transport)
    assert_receive {:holding, 1, old_worker, 0}
    parent = self()

    peer =
      spawn(fn ->
        {:ok, transport} = Test.connect(server: root)
        send(parent, {:peer_connected, self(), transport})
        forward_peer(parent, transport)
      end)

    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)
    assert_receive {:peer_connected, ^peer, new_transport}
    assert_receive {:cancel_probe, ^old_worker, true}

    assert {:error, {:transport_error, :connection_closed}} =
             Test.send_message(tool(2, "inc"), old_transport)

    send(peer, {:send, tool(1, "scope_status")})
    assert_receive {:peer_message, ^peer, encoded_response}

    assert %{"id" => 1, "result" => %{"structuredContent" => %{"cancelled" => false}}} =
             response_map(encoded_response)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)

    assert MapSet.member?(
             Server.call(root, :cancellations),
             {{:connection, old_transport.connection}, 1}
           )

    refute MapSet.member?(
             Server.call(root, :cancellations),
             {{:connection, new_transport.connection}, 1}
           )

    refute_receive {:peer_message, ^peer, _old_terminal}, 30
  end

  test "initialization inside a legacy batch precedes every entry of a later envelope" do
    {root, transport} = start_pair(handler_args: [test_pid: self(), block_initialize: true])

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "2"}
      }
    }

    assert {:ok, transport} = Test.send_message([initialize, tool(1, "inc")], transport)
    assert_receive {:initialize_blocked, callback}
    assert {:ok, _transport} = Test.send_message([tool(2, "inc")], transport)
    send(callback, :release_initialize)
    assert_receive {:transport_message, encoded_first}
    assert [initialize_response, first] = response_map(encoded_first)
    assert initialize_response["id"] == 0
    assert first["id"] == 1
    assert first["result"]["structuredContent"]["count"] == 1
    assert_receive {:transport_message, encoded_second}
    assert [second] = response_map(encoded_second)
    assert second["id"] == 2
    assert second["result"]["structuredContent"]["count"] == 2
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
  end

  test "a held batch stays ahead of later custom state changes and RPC envelopes" do
    {root, transport} = start_pair()
    assert {:ok, transport} = Test.send_message([tool(1, "hold"), tool(2, "inc")], transport)
    assert_receive {:holding, 1, callback, 0}
    assert :ok = Server.cast(root, {:add, 10})
    assert {:ok, _transport} = Test.send_message(tool(3, "inc"), transport)
    send(callback, :release)
    assert_receive {:transport_message, encoded_batch}

    assert Enum.map(response_map(encoded_batch), & &1["result"]["structuredContent"]["count"]) ==
             [1, 2]

    assert_receive {:transport_message, encoded_later}

    assert %{"id" => 3, "result" => %{"structuredContent" => %{"count" => 13}}} =
             response_map(encoded_later)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
  end

  test "cancelling a future batch ID does not cancel its currently running member" do
    {root, transport} = start_pair()
    assert {:ok, transport} = Test.send_message([tool(1, "hold"), tool(2, "inc")], transport)
    assert_receive {:holding, 1, callback, 0}, 1_000
    assert {:ok, _transport} = Test.send_message(cancel(2), transport)
    send(callback, :probe)
    assert_receive {:cancel_probe, ^callback, false}, 1_000
    send(callback, :release)
    assert_receive {:transport_message, encoded_batch}, 1_000
    assert [first, second] = response_map(encoded_batch)
    assert %{"id" => 1, "result" => %{"structuredContent" => %{"count" => 1}}} = first
    assert %{"id" => 2, "error" => %{"code" => -32001}} = second
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 1
  end

  test "future batch cancellation survives the prior member's terminal tracker window" do
    {root, transport} = start_pair(cancellation_tracker: BlockingTracker)
    assert {:ok, transport} = Test.send_message([tool(1, "hold"), tool(2, "inc")], transport)
    assert_receive {:holding, 1, callback, 0}
    assert {:ok, transport} = Test.send_message(cancel(1), transport)
    assert_receive {:cancel_probe, ^callback, true}
    assert_receive {:tracker_started, 1, tracker_one, 0}
    scope = {:connection, transport.connection}
    assert_receive {:tracker_scope, 1, ^scope}
    assert {:ok, _transport} = Test.send_message(cancel(2), transport)
    send(tracker_one, :release_tracker)
    assert_receive {:tracker_started, 2, tracker_two, 0}
    assert_receive {:tracker_scope, 2, ^scope}
    send(tracker_two, :release_tracker)
    assert_receive {:transport_message, encoded_batch}

    assert Enum.map(response_map(encoded_batch), &{&1["id"], &1["error"]["code"]}) == [
             {1, -32001},
             {2, -32001}
           ]

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 0
  end

  test "an accepted progress control survives normal callback completion behind a suspended edge" do
    {root, transport} = start_pair()
    assert {:ok, _transport} = Test.send_message(tool(1, "progress_then_finish"), transport)
    assert_receive {:progress_worker, callback}
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    send(callback, :issue_progress)
    assert_receive {:progress_accepted, :ok}
    # Callback execution has ended, but the stateful slot remains occupied until
    # the edge accepts and hands off its charged output.
    wait_for(fn -> Runtime.stats(root).active == 1 end)
    :sys.resume(edge)
    assert_receive {:transport_message, progress}
    assert response_map(progress)["method"] == "notifications/progress"
    assert_receive {:transport_message, response}
    assert response_map(response)["result"]["structuredContent"]["count"] == 1
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
  end

  test "an expired callback cannot issue controls before its queued deadline is processed" do
    {root, transport} = start_pair(request_timeout_ms: 80)
    assert {:ok, _transport} = Test.send_message(tool(1, "deadline_controls"), transport)
    assert_receive {:deadline_control_worker, callback}
    {:ok, runtime} = Runtime.ref(root)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.scheduler)
    on_exit(fn -> if Process.alive?(route.scheduler), do: :sys.resume(route.scheduler) end)
    Process.sleep(100)
    send(callback, :issue_controls)

    assert_receive {:deadline_controls_done, {:error, :request_cancelled},
                    {:error, :request_cancelled}}

    refute_receive {:transport_message, _expired_control}, 20
    :sys.resume(route.scheduler)
    assert_receive {:transport_message, timeout}

    assert %{"id" => 1, "error" => %{"data" => %{"type" => "handler_timeout"}}} =
             response_map(timeout)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 0
  end

  test "retired callback controls cannot send reverse requests or notifications to a replacement peer" do
    {root, transport} = start_pair(cancel_grace_ms: 500)
    assert {:ok, _transport} = Test.send_message(tool(1, "retired_controls"), transport)
    assert_receive {:retired_control_worker, callback}
    parent = self()

    peer =
      spawn(fn ->
        {:ok, transport} = Test.connect(server: root)
        send(parent, {:peer_connected, self(), transport})
        forward_peer(parent, transport)
      end)

    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)
    assert_receive {:peer_connected, ^peer, _transport}
    assert_receive {:retired_control_cancelled, ^callback}
    send(peer, {:send, tool(1, "inc")})
    assert_receive {:peer_send, ^peer, {:ok, _transport}}
    send(callback, :issue_controls)
    assert_receive {:retired_controls_done, {:error, :request_cancelled}}
    assert_receive {:peer_message, ^peer, encoded_response}

    assert %{"id" => 1, "result" => %{"structuredContent" => %{"count" => 1}}} =
             response_map(encoded_response)

    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    refute_receive {:peer_message, ^peer, _retired_control}, 30
  end

  test "edge restart preserves the root reference and committed state with one handler initialization" do
    {root, transport} = start_pair()
    assert_receive {:handler_initialized, _state_owner}
    {:ok, runtime} = Runtime.ref(root)
    assert {:ok, _transport} = Test.send_message(tool(1, "inc"), transport)
    assert_receive {:transport_message, _response}
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    {:ok, edge} = Runtime.edge(root)
    Process.exit(edge, :kill)

    wait_for(fn ->
      case Runtime.edge(root) do
        {:ok, current} -> current != edge
        _ -> false
      end
    end)

    assert {:ok, ^runtime} = Runtime.ref(root)
    {:ok, _transport} = Test.connect(server: root)
    assert Server.call(runtime, :read) == 1
    refute_receive {:handler_initialized, _new_state_owner}, 30
  end

  defp forward_peer(parent, transport) do
    receive do
      {:send, request} ->
        send(parent, {:peer_send, self(), Test.send_message(request, transport)})
        forward_peer(parent, transport)

      {:transport_message, response} ->
        send(parent, {:peer_message, self(), response})
        forward_peer(parent, transport)
    end
  end

  defp start_pair(opts \\ []) do
    opts =
      Keyword.merge([transport: :test, handler: Handler, handler_args: [test_pid: self()]], opts)

    root =
      start_supervised!(
        Supervisor.child_spec({HandlerServer, opts}, id: make_ref(), restart: :temporary)
      )

    module = if opts[:transport] == :beam, do: Local, else: Test
    {:ok, transport} = module.connect(server: root)
    {root, transport}
  end

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp modern(request) do
    put_in(request, ["params", "_meta"], %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "runtime-test", "version" => "2"}
    })
  end

  defp assert_rejected_batch(root, transport, batch) do
    assert {:ok, _transport} = Test.send_message(batch, transport)
    assert_receive {:transport_message, response}
    assert %{"id" => nil, "error" => %{"code" => -32600}} = response_map(response)
    refute_receive {:incremented, _callback}, 20
    wait_for(fn -> Runtime.stats(root).reserved == 0 end)
    assert Server.call(root, :read) == 0
  end

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp response_map(response) when is_binary(response), do: Jason.decode!(response)
  defp response_map(response), do: response

  defp wait_for(fun, attempts \\ 100)
  defp wait_for(fun, 0), do: assert(fun.())

  defp wait_for(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_for(fun, attempts - 1)
        )
  end
end
