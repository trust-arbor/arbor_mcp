defmodule Arbor.MCP.Server.Runtime.OutputIntegrationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Runtime}

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Config,
    OutputCodec,
    OutputController,
    OutputLedger,
    Ref
  }

  alias Arbor.MCP.Transport.{Local, Test}

  defmodule OpaqueReply do
    defstruct [:value]
  end

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    defoverridable handle_call: 3
    def init(opts), do: {:ok, %{test_pid: opts[:test_pid], count: 0}}

    def handle_initialize(_, state),
      do:
        {:ok,
         %{
           protocolVersion: "2025-03-26",
           serverInfo: %{name: "output", version: "2"},
           capabilities: %{tools: %{}}
         }, state}

    def handle_call(:read, _from, state), do: {:reply, state.count, state}

    def handle_call(:identity, {caller, tag}, state),
      do: {:reply, {caller, tag, %OpaqueReply{value: <<255>>}}, state}

    def handle_call({:value, value}, _from, state),
      do: {:reply, value, %{state | count: state.count + 1}}

    def handle_call(:hold, _from, state) do
      send(state.test_pid, {:holding_custom, self()})

      receive do
        :release -> {:reply, state.count + 1, %{state | count: state.count + 1}}
      end
    end

    def handle_call_tool("inc", _args, state),
      do: result(state.count + 1, %{state | count: state.count + 1})

    def handle_call_tool("read", _args, state), do: result(state.count, state)

    def handle_call_tool("opaque", _args, state),
      do:
        {:ok, %{content: [], structuredContent: %{child: self()}},
         %{state | count: state.count + 1}}

    def handle_call_tool("authored_error", _args, state),
      do:
        {:ok, %{content: [Arbor.MCP.Content.text("Rejected")], isError: true},
         %{state | count: state.count + 1}}

    def handle_call_tool("collision", %{"kind" => kind}, state) do
      value =
        case kind do
          "top" -> %{"structuredContent" => %{}, content: [], structuredContent: %{}}
          "content" -> %{"content" => [], content: []}
          "nested" -> %{content: [], structuredContent: %{"isError" => false, is_error: true}}
        end

      {:ok, value, %{state | count: state.count + 1}}
    end

    def handle_call_tool("large", args, state),
      do:
        {:ok, %{content: [Arbor.MCP.Content.text(String.duplicate("x", args["size"]))]},
         %{state | count: state.count + 1}}

    def handle_call_tool("hold", _args, state) do
      send(state.test_pid, {:holding_tool, self()})

      receive do
        :release -> result(state.count + 1, %{state | count: state.count + 1})
      end
    end

    defp result(value, state),
      do: {:ok, %{content: [], structuredContent: %{count: value}}, state}
  end

  defmodule MalformedDSLHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL
    defoverridable handle_call: 3
    def init(_opts), do: {:ok, %{count: 0}}
    def handle_call(:read, _from, state), do: {:reply, state.count, state}

    tool "malformed", "Returns an unsupported complete result" do
      run(fn _args, state -> {:ok, self(), %{state | count: state.count + 1}} end)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end

  defp pair(opts \\ []) do
    root =
      start_supervised!(
        {HandlerServer,
         Keyword.merge(
           [handler: Handler, handler_args: [test_pid: self()], transport: :test],
           opts
         )}
      )

    module = if opts[:transport] == :beam, do: Local, else: Test
    {:ok, transport} = module.connect(server: root)
    {root, module, transport}
  end

  defp tool(id, name, args \\ %{}),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

  defp table(root) do
    {:ok, ref} = Runtime.ref(root)
    Ref.table(ref)
  end

  test "custom reply terms retain PID, alias tag, struct and non-UTF8 bytes" do
    {root, _, _} = pair()
    caller = self()
    assert {^caller, [_ | reference], %OpaqueReply{value: <<255>>}} = Server.call(root, :identity)
    assert is_reference(reference)
    value = {self(), make_ref(), [1 | 2], {:map_iterator, :literal}, fn -> :ok end}
    assert ^value = Server.call(root, {:value, value})
    assert Server.call(root, :read) == 1
    eventually(fn -> OutputController.stats(table(root)).scopes == 0 end)
  end

  test "oversized custom reply rejects before state commit and retires direct-call scope" do
    {root, _, _} = pair(max_output_term_bytes: 128)

    assert {:error, :output_term_too_large} =
             Server.call(root, {:value, String.duplicate("a", 1_000)})

    assert Server.call(root, :read) == 0
    eventually(fn -> OutputController.stats(table(root)).jobs == 0 end)
  end

  test "direct Runtime RPC keeps its result wrapper instead of exposing a ticket" do
    {root, _, _} = pair()

    assert {:ok, %{"result" => %{"structuredContent" => %{"count" => 1}}}} =
             Runtime.request(root, tool(1, "inc"))

    assert Server.call(root, :read) == 1
  end

  test "nested opaque protocol values reject before commit while authored tool errors commit" do
    {root, module, transport} = pair()
    assert {:ok, _} = module.send_message(tool(1, "opaque"), transport)
    assert_receive {:transport_error, _reason}, 1_000
    refute_receive {:transport_message, _invalid}, 20
    assert Server.call(root, :read) == 0
    assert {:ok, next} = module.connect(server: root)
    assert {:ok, _} = module.send_message(tool(2, "authored_error"), next)
    assert_receive {:transport_message, wire}, 1_000
    assert %{"result" => %{"isError" => true}} = Jason.decode!(wire)
    assert Server.call(root, :read) == 1
  end

  test "universal normalization rejects colliding wire keys before callback state commit" do
    {root, module, transport} = pair()

    for kind <- ["top", "content", "nested"] do
      assert {:ok, _} = module.send_message(tool(kind, "collision", %{"kind" => kind}), transport)
      assert_receive {:transport_message, wire}, 1_000
      assert %{"error" => %{"data" => %{"type" => "handler_crash"}}} = Jason.decode!(wire)
      assert Server.call(root, :read) == 0
    end
  end

  test "malformed complete DSL result gives a safe handler failure without state commit" do
    {root, module, transport} = pair(handler: MalformedDSLHandler)
    assert {:ok, _} = module.send_message(tool(1, "malformed"), transport)
    assert_receive {:transport_message, wire}, 1_000
    assert %{"error" => %{"data" => %{"type" => "handler_crash"}}} = Jason.decode!(wire)
    refute wire =~ "#PID"
    assert Server.call(root, :read) == 0
  end

  test "expired queued batch has one whole-envelope failure and releases all credit" do
    {root, module, transport} = pair(request_timeout_ms: 50)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert {:ok, _} = module.send_message([tool(1, "inc"), tool(2, "inc")], transport)
    Process.sleep(75)
    :sys.resume(edge)
    assert_receive {:transport_error, :handler_timeout}, 1_000
    refute_receive {:transport_message, _partial}, 20
    assert Server.call(root, :read) == 0

    eventually(fn ->
      Runtime.stats(root).reserved == 0 and OutputController.stats(table(root)).frames == 0
    end)
  end

  test "prepared producer handoff survives task death without making output visible" do
    ledger = start_supervised!({OutputLedger, owner: self()})
    {:ok, ref} = OutputLedger.ref(ledger)
    :ok = OutputLedger.open_scope(ref, :handoff)
    :ok = OutputLedger.subscribe(ref, :handoff, self())
    owner = self()

    {producer, monitor} =
      spawn_monitor(fn ->
        {:ok, ticket} =
          OutputLedger.prepare(ref, %{"ready" => true},
            scope: :handoff,
            owner: owner,
            deadline: now() + 2_000
          )

        assert :ok = OutputLedger.handoff(ticket)
        send(owner, {:handed, ticket})
      end)

    assert_receive {:handed, ticket}
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    Process.sleep(30)
    assert :empty = OutputLedger.checkout(ref, :handoff)
    assert %{frames: 1, prepared: 1} = OutputLedger.stats(ref)
    assert :ok = OutputLedger.publish(ticket)
    assert {:ok, ^ticket, %{"ready" => true}, _} = OutputLedger.checkout(ref, :handoff)
    assert :ok = OutputLedger.ack(ticket)
  end

  test "registration interrupted between scope open and subscribe cannot orphan an empty scope" do
    {root, _, _} = pair(output_timeout_ms: 120, request_timeout_ms: 500)
    [{:output_controller, controller}] = :ets.lookup(table(root), :output_controller)
    ledger = :sys.get_state(controller).ledger

    on_exit(fn ->
      for pid <- [controller, ledger.pid], Process.alive?(pid) do
        try do
          :erlang.resume_process(pid)
        catch
          :error, :badarg -> :ok
        end
      end
    end)

    :erlang.suspend_process(ledger.pid)
    assert {:ok, token} = Runtime.submit(root, %{"payload" => :read}, kind: :call)

    eventually(fn ->
      {:messages, messages} = Process.info(ledger.pid, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:operation, _}}, &1))
    end)

    :erlang.suspend_process(controller)
    :erlang.resume_process(ledger.pid)
    eventually(fn -> OutputLedger.stats(ledger).scopes == 1 end)
    :erlang.suspend_process(ledger.pid)
    :erlang.resume_process(controller)
    assert {:error, _registration_failure} = Runtime.await(token)
    assert OutputController.stats(table(root)).jobs == 0
    :erlang.resume_process(ledger.pid)

    # The subscription never completed, so no Controller job tracks the empty
    # scope. Its immutable Ledger deadline still reaps the row independently.
    eventually(fn -> OutputLedger.stats(ledger).scopes == 0 end, 150)
    assert Server.call(root, :read) == 0
  end

  test "a managed empty scope deadline cannot be renewed by registration retry" do
    ledger = start_supervised!({OutputLedger, owner: self()})
    {:ok, ref} = OutputLedger.ref(ledger)
    assert :ok = OutputLedger.open_scope(ref, :empty, now() + 50)
    assert :ok = OutputLedger.open_scope(ref, :empty, now() + 2_000)
    eventually(fn -> OutputLedger.stats(ref).scopes == 0 end)
  end

  test "batch prospective aggregate rejects the second member before its state commit" do
    {root, module, transport} = pair(max_output_frame_bytes: 200)

    assert {:ok, _} =
             module.send_message([tool(1, "inc"), tool(2, "large", %{"size" => 150})], transport)

    assert_receive {:transport_error, _reason}, 1_000
    refute_receive {:transport_message, _partial}, 30
    assert Server.call(root, :read) == 1
    assert Process.alive?(self())
    eventually(fn -> OutputController.stats(table(root)).frames == 0 end)
  end

  test "Test batch publishes one array and releases input and grouped output credit" do
    {root, module, transport} = pair()
    assert {:ok, _} = module.send_message([tool(1, "inc"), tool(2, "inc")], transport)
    assert_receive {:transport_message, wire}, 1_000

    assert [
             %{"id" => 1, "result" => %{"structuredContent" => %{"count" => 1}}},
             %{"id" => 2, "result" => %{"structuredContent" => %{"count" => 2}}}
           ] = Jason.decode!(wire)

    refute_receive {:transport_message, _second}, 20

    eventually(fn ->
      OutputController.stats(table(root)).frames == 0 and Runtime.stats(root).reserved == 0
    end)
  end

  test "BEAM batch retains decoded values and has one terminal mailbox handoff" do
    {root, module, transport} = pair(transport: :beam)
    assert {:ok, _} = module.send_message([tool(1, "inc"), tool(2, "inc")], transport)
    assert_receive {:transport_message, [first, second]}, 1_000
    assert first["result"]["structuredContent"]["count"] == 1
    assert second["result"]["structuredContent"]["count"] == 2
    assert Server.call(root, :read) == 2
  end

  test "held members charge prospective decoded and wire aggregate before consolidation" do
    ledger = start_supervised!({OutputLedger, owner: self()})
    {:ok, ref} = OutputLedger.ref(ledger)
    :ok = OutputLedger.open_scope(ref, :group)
    :ok = OutputLedger.subscribe(ref, :group, self())

    for n <- 1..2 do
      {:ok, ticket} =
        OutputLedger.prepare(ref, %{"n" => n},
          scope: :group,
          deadline: now() + 2_000,
          group: true
        )

      :ok = OutputLedger.hold(ticket)
    end

    before = OutputLedger.stats(ref)
    assert before.frames == 2

    assert before.bytes >
             :erlang.external_size([%{"n" => 1}, %{"n" => 2}]) +
               byte_size(~S([{"n":1},{"n":2}])) + 1

    assert {:ok, ticket} = OutputLedger.finish_group(ref, :group)
    assert %{frames: 1, queued: 1, bytes: bytes} = OutputLedger.stats(ref)
    assert bytes > 0 and bytes <= before.bytes

    assert {:ok, ^ticket, [%{"n" => 1}, %{"n" => 2}], ~S([{"n":1},{"n":2}])} =
             OutputLedger.checkout(ref, :group)

    :ok = OutputLedger.ack(ticket)
    assert %{frames: 0, bytes: 0} = OutputLedger.stats(ref)
  end

  test "stateful work waits for output handoff independently of callback worker DOWN" do
    {root, module, transport} = pair()
    {:ok, edge} = Runtime.edge(root)
    assert {:ok, _} = module.send_message(tool(1, "hold"), transport)
    assert_receive {:holding_tool, worker}
    :sys.suspend(edge)
    send(worker, :release)
    eventually(fn -> OutputController.stats(table(root)).in_flight == 1 end)
    eventually(fn -> not Process.alive?(worker) end)
    call = Task.async(fn -> Runtime.request(root, %{"payload" => :read}, kind: :call) end)
    refute Task.yield(call, 20)
    :sys.resume(edge)
    assert_receive {:transport_message, _wire}, 1_000
    assert {:ok, 1} = Task.await(call)
  end

  test "committed direct reply expiring before writer checkout produces a terminal failure" do
    {root, _, _} = pair(request_timeout_ms: 500)
    assert {:ok, token} = Runtime.submit(root, %{"payload" => :hold}, kind: :call)
    assert_receive {:holding_custom, worker}
    controller = suspend_writer(root)
    send(worker, :release)
    await_committed(root)
    Process.sleep(550)
    :erlang.resume_process(controller)
    assert Runtime.await(token, 1_000) == {:error, :output_expired}
    assert Server.call(root, :read) == 1
    eventually(fn -> Runtime.stats(root).reserved == 0 end)
    assert :ets.match_object(table(root), {{:output_commit, :_}, :_}) == []
  end

  test "committed Test reply expiring before checkout releases retained envelope input" do
    {root, module, transport} = pair(request_timeout_ms: 500)
    assert {:ok, _} = module.send_message(tool(1, "hold"), transport)
    assert_receive {:holding_tool, worker}
    controller = suspend_writer(root)
    send(worker, :release)
    await_committed(root)
    Process.sleep(550)
    :erlang.resume_process(controller)
    assert_receive {:transport_error, _explicit_failure}, 1_000
    refute_receive {:transport_message, _late_success}, 20
    assert Server.call(root, :read) == 1

    eventually(fn ->
      Runtime.stats(root).reserved == 0 and OutputController.stats(table(root)).frames == 0
    end)
  end

  defp suspend_writer(root) do
    [{:output_controller, controller}] = :ets.lookup(table(root), :output_controller)
    :erlang.suspend_process(controller)

    on_exit(fn ->
      if Process.alive?(controller) do
        try do
          :erlang.resume_process(controller)
        catch
          :error, :badarg -> :ok
        end
      end
    end)

    controller
  end

  defp await_committed(root) do
    {:ok, route} = Admission.route(table(root))
    eventually(fn -> :sys.get_state(route.scheduler).handler_state.count == 1 end)
  end

  test "term preflight is bounded and does not interpret literal walker marker tuples" do
    value = {:map_iterator, :literal, {:tuple_iterator, :literal, 99}}
    assert {:ok, %{term: ^value, wire: nil}} = OutputCodec.prepare(value, codec: :term)
    assert {:error, :output_expired} = OutputCodec.prepare(:ok, codec: :term, deadline: now() - 1)

    assert {:error, :output_term_too_large} =
             OutputCodec.prepare(List.duplicate(:ok, 10_000), codec: :term, max_term_bytes: 100)
  end

  test "cancellation before a queued transferred proposal releases hidden credit exactly once" do
    {root, _, _} = pair()

    assert {:ok, token} =
             Runtime.submit(root, %{"id" => 77, "payload" => :hold}, kind: :call, scope: :race)

    assert_receive {:holding_custom, worker}
    {:ok, route} = Admission.route(table(root))
    :sys.suspend(route.scheduler)
    cancellation = Task.async(fn -> Runtime.cancel(root, :race, 77) end)

    eventually(fn ->
      {:messages, messages} = Process.info(route.scheduler, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:cancel, _, _}}, &1))
    end)

    send(worker, :release)
    eventually(fn -> OutputController.stats(table(root)).prepared == 1 end)
    eventually(fn -> not Process.alive?(worker) end)
    :sys.resume(route.scheduler)
    assert Task.await(cancellation) == :ok
    assert Runtime.await(token) == {:error, :request_cancelled}
    eventually(fn -> OutputController.stats(table(root)).frames == 0 end)
    assert Server.call(root, :read) == 0
    refute_receive {:arbor_mcp_runtime, ^token, _duplicate}, 20
  end

  test "all runtime timer configuration is finite uint32 before any child starts" do
    for key <- [
          :request_timeout_ms,
          :init_timeout_ms,
          :shutdown_timeout_ms,
          :cancel_grace_ms,
          :output_timeout_ms
        ] do
      assert {:error, {:invalid_limit, ^key}} =
               Runtime.start_link([{key, 4_294_967_296}, handler: Handler])

      assert {:ok, _config} = Config.new([{key, 4_294_967_295}, handler: Handler])
    end

    assert {:ok, %{cancel_grace_ms: 0}} = Config.new(handler: Handler, cancel_grace_ms: 0)

    assert {:error, {:invalid_limit, :output_timeout_ms}} =
             Config.new(handler: Handler, output_timeout_ms: 0)

    assert {:ok, _config} = Config.new(handler: Handler, max_pending_bytes: 4_294_967_296)
  end
end
