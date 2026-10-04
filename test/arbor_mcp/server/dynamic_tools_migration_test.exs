Arbor.MCP.Test.DynamicToolsExample.ensure_loaded()

defmodule Arbor.MCP.Server.DynamicToolsMigrationTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Examples.DynamicTools
  alias Arbor.MCP.Examples.DynamicTools.Actions
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Transport.Test

  defmodule BlockingRegistration do
    use Arbor.MCP.Server.Handler
    defoverridable handle_call: 3
    defdelegate init(opts), to: DynamicTools
    defdelegate handle_initialize(params, state), to: DynamicTools
    defdelegate handle_list_tools(cursor, state), to: DynamicTools
    defdelegate handle_call_tool(name, args, state), to: DynamicTools

    def handle_call({:register, _entries, _policy} = request, from, state) do
      send(state.test_pid, {:registration_blocked, self()})

      receive do
        :register_now -> DynamicTools.handle_call(request, from, state)
      end
    end

    def handle_call(request, from, state), do: DynamicTools.handle_call(request, from, state)
  end

  test "application state owns register, get, list, call and removal without global names" do
    {root, transport} = start_catalog()
    descriptor = definition("echo")
    assert {:ok, :ok} = register(root, descriptor)
    assert {:ok, ^descriptor} = Server.call(root, {:get, "echo"})
    assert [^descriptor] = Server.call(root, :list)
    assert_receive {:transport_message, changed}
    assert decoded(changed)["method"] == "notifications/tools/list_changed"
    assert {:ok, _} = Test.send_message(tool(1, "echo", %{"count" => 2}), transport)
    assert_receive {:dynamic_invoked, _worker, %{"count" => 2}}
    assert_receive {:transport_message, response}
    assert decoded(response)["result"]["structuredContent"]["count"] == 2
    assert %{count: 1, tools: 1} = Server.call(root, :stats)
    assert {:ok, :ok} = Server.call(root, {:remove, "echo"})
    assert :error = Server.call(root, {:get, "echo"})
    assert [] = Server.call(root, :list)
    assert {:error, :not_found} = Server.call(root, {:remove, "echo"})
  end

  test "explicit defaults preserve null false and lists without implicit coercion" do
    {root, transport} = start_catalog()
    defaults = %{"count" => 1, "enabled" => false, "nullable" => nil, "tags" => []}
    assert {:ok, :ok} = register(root, definition("defaults"), defaults)
    drain_changed()
    assert {:ok, _} = Test.send_message(tool(1, "defaults", %{}), transport)
    assert_receive {:dynamic_invoked, _, ^defaults}
    assert_receive {:transport_message, response}
    assert decoded(response)["result"]["structuredContent"] == defaults
    assert {:ok, _} = Test.send_message(tool(2, "defaults", %{"count" => "2"}), transport)
    assert_receive {:transport_message, response}
    assert decoded(response)["error"]["code"] == -32602
    refute_receive {:dynamic_invoked, _, _}, 10
    assert %{count: 1} = Server.call(root, :stats)
  end

  test "JSON Schema default annotations do not create application defaults" do
    {root, transport} = start_catalog()
    assert {:ok, :ok} = register(root, definition("annotations"))
    drain_changed()
    assert {:ok, _} = Test.send_message(tool(1, "annotations", %{}), transport)
    assert_receive {:transport_message, response}
    assert decoded(response)["error"]["code"] == -32602
    refute_receive {:dynamic_invoked, _, _}, 10
    assert %{count: 0} = Server.call(root, :stats)
  end

  test "duplicates reject by default and explicit replacement retires previous validators" do
    {root, transport} = start_catalog()
    old = Map.put(definition("same"), "outputSchema", %{"not" => %{}})
    assert {:ok, :ok} = register(root, old)
    assert {:error, :duplicate_tool} = register(root, definition("same"))
    drain_changed()
    assert {:ok, _} = Test.send_message(tool(1, "same", %{"count" => 1}), transport)
    assert_receive {:dynamic_invoked, _, _}
    assert_receive {:transport_message, rejected}
    assert decoded(rejected)["result"]["isError"] == true
    assert %{count: 1} = Server.call(root, :stats)
    replacement = definition("same")
    assert {:ok, :ok} = register(root, replacement, %{}, :replace)
    assert {:ok, ^replacement} = Server.call(root, {:get, "same"})
    drain_changed()
    assert {:ok, _} = Test.send_message(tool(2, "same", %{"count" => 1}), transport)
    assert_receive {:dynamic_invoked, _, _}
    assert_receive {:transport_message, response}
    refute decoded(response)["result"]["isError"]
    assert %{compile_count: 3, count: 2, tools: 1} = Server.call(root, :stats)
  end

  test "bulk registrations commit atomically and duplicate entries never silently replace" do
    {root, _transport} = start_catalog()
    good = entry(definition("good"))

    bad =
      entry(
        Map.put(definition("bad"), "inputSchema", %{
          "type" => "object",
          "$ref" => "file:///private"
        })
      )

    assert {:error, :network_ref_forbidden} = Server.call(root, {:register, [good, bad], :reject})
    assert [] = Server.call(root, :list)
    assert %{compile_count: 0} = Server.call(root, :stats)
    assert {:error, :duplicate_tool} = Server.call(root, {:register, [good, good], :replace})

    assert {:ok, :ok} =
             Server.call(root, {:register, [good, entry(definition("another"))], :reject})

    assert Enum.map(Server.call(root, :list), & &1["name"]) == ["another", "good"]
  end

  test "invalid schemas, dispatch and opaque descriptor/default terms reject before mutation" do
    {root, _transport} = start_catalog()

    for bad <- [
          {%{"name" => "missing"}, {Actions, :echo}, %{}},
          {definition("no_function"), {Actions, :missing}, %{}},
          {definition("closure"), fn args, state -> {:ok, args, state} end, %{}},
          {Map.put(definition("opaque"), "metadata", self()), {Actions, :echo}, %{}},
          {definition("opaque_default"), {Actions, :echo}, %{"value" => make_ref()}},
          {definition("reserved_default"), {Actions, :echo}, %{"_request_id" => 123}},
          {Map.put(definition("false_input"), "inputSchema", false), {Actions, :echo}, %{}},
          {Map.put(definition("array_input"), "inputSchema", %{"type" => "array"}),
           {Actions, :echo}, %{}},
          {Map.put(definition("false_output"), "outputSchema", false), {Actions, :echo}, %{}},
          {Map.put(definition("null_output"), "outputSchema", nil), {Actions, :echo}, %{}}
        ] do
      assert {:error, _} = Server.call(root, {:register, [bad], :reject})
    end

    assert [] = Server.call(root, :list)
    assert %{compile_count: 0} = Server.call(root, :stats)
  end

  test "catalog and descriptor limits reject without changing committed definitions" do
    {root, _transport} = start_catalog()
    entries = for id <- 1..32, do: entry(definition("bounded-#{id}"))
    assert {:ok, :ok} = Server.call(root, {:register, entries, :reject})
    assert {:error, :catalog_full} = register(root, definition("overflow"))
    oversized = Map.put(definition("bounded-1"), "description", String.duplicate("x", 16_384))
    assert {:error, :invalid_definition} = register(root, oversized, %{}, :replace)
    assert {:ok, :ok} = register(root, definition("bounded-1"), %{}, :replace)
    assert %{tools: 32, compile_count: 33} = Server.call(root, :stats)
    assert length(Server.call(root, :list)) == 32
  end

  test "always-rejecting object schemas remain validators rather than absent schemas" do
    {root, transport} = start_catalog()
    descriptor = %{"name" => "never", "inputSchema" => %{"type" => "object", "not" => %{}}}
    assert {:ok, :ok} = register(root, descriptor)
    drain_changed()
    assert {:ok, _} = Test.send_message(tool(1, "never", %{}), transport)
    assert_receive {:transport_message, response}
    assert decoded(response)["error"]["code"] == -32602
    refute_receive {:dynamic_invoked, _, _}, 10
  end

  test "modern opaque output schema caches support single and bulk catalog registration" do
    {root, transport} = start_catalog()
    output = %{"type" => "array", "prefixItems" => [%{"type" => "integer"}], "items" => false}

    descriptor = %{
      "name" => "single",
      "inputSchema" => %{"type" => "object"},
      "outputSchema" => output
    }

    assert {:ok, :ok} = register(root, descriptor, %{}, :reject, :value)

    assert {:ok, :ok} =
             Server.call(
               root,
               {:register, [entry(%{descriptor | "name" => "bulk"}, %{}, :value)], :reject}
             )

    drain_changed()

    for {name, id} <- [{"single", 1}, {"bulk", 2}] do
      assert {:ok, _} = Test.send_message(modern(tool(id, name, %{"value" => [7]})), transport)
      assert_receive {:transport_message, response}
      assert decoded(response)["result"]["structuredContent"] == [7]

      assert {:ok, _} =
               Test.send_message(modern(tool(id + 10, name, %{"value" => [7, 8]})), transport)

      assert_receive {:transport_message, response}
      assert decoded(response)["result"]["isError"] == true
    end
  end

  test "descriptor validators compile only during registration rather than list get or call" do
    {root, transport} = start_catalog()
    descriptor = Map.put(definition("cached"), "outputSchema", %{"type" => "object"})
    :erlang.trace_pattern({SchemaPolicy, :compile, 2}, true, [:local])
    :erlang.trace(:new, true, [:call])

    try do
      assert {:ok, :ok} = register(root, descriptor)
      assert trace_compiles() == 2
      drain_changed()

      for id <- 1..3 do
        assert [_definition] = Server.call(root, :list)
        assert {:ok, _definition} = Server.call(root, {:get, "cached"})
        assert {:ok, _} = Test.send_message(tool(id, "cached", %{"count" => id}), transport)
        assert_receive {:dynamic_invoked, _, _}
        assert_receive {:transport_message, _response}
      end

      assert trace_compiles() == 0
      assert %{compile_count: 2, count: 3} = Server.call(root, :stats)
    after
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({SchemaPolicy, :compile, 2}, false, [:local])
    end
  end

  test "two runtimes own independent catalogs even when tool names are reused" do
    {one, _transport} = start_catalog()
    {two, _transport} = start_catalog()
    descriptor = definition("reused")
    assert {:ok, :ok} = register(one, descriptor)
    assert [] = Server.call(two, :list)
    assert {:ok, :ok} = register(two, %{descriptor | "description" => "second"})
    assert {:ok, ^descriptor} = Server.call(one, {:get, "reused"})
    assert {:ok, %{"description" => "second"}} = Server.call(two, {:get, "reused"})
    assert {:ok, :ok} = Server.call(one, {:remove, "reused"})
    assert [_] = Server.call(two, :list)
  end

  test "catalog mutation waits for active stateful tools and cancellation prevents late business-state commit" do
    {root, transport} = start_catalog(cancel_grace_ms: 200)

    assert {:ok, :ok} =
             register(
               root,
               %{"name" => "hold", "inputSchema" => %{"type" => "object"}},
               %{},
               :reject,
               :hold
             )

    drain_changed()
    assert {:ok, transport} = Test.send_message(tool(1, "hold", %{}), transport)
    assert_receive {:dynamic_holding, _worker, scope}
    assert scope == {:connection, transport.connection}
    mutation = Task.async(fn -> register(root, definition("after")) end)
    wait_for(fn -> Runtime.stats(root).queued == 1 end)
    assert {:ok, _} = Test.send_message(cancel(1), transport)
    assert_receive {:dynamic_cancelled, true}
    assert_receive {:transport_message, response}
    assert decoded(response)["error"]["code"] == -32001
    assert Task.await(mutation) == {:ok, :ok}
    assert %{count: 0, tools: 2} = Server.call(root, :stats)
  end

  test "notification pressure is explicit while successful catalog state still commits once" do
    {root, _transport} = start_catalog(handler: BlockingRegistration, max_control_queue: 1)
    task = Task.async(fn -> register(root, definition("pressure")) end)
    assert_receive {:registration_blocked, worker}
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    assert :ok = Server.notify_tools_changed(root)
    send(worker, :register_now)
    assert Task.await(task) == {:ok, {:error, :server_busy}}
    :sys.resume(edge)
    assert %{tools: 1, compile_count: 1} = Server.call(root, :stats)
  end

  defp start_catalog(opts \\ []) do
    options =
      Keyword.merge(
        [handler: DynamicTools, transport: :test, handler_args: [test_pid: self()]],
        opts
      )

    root = start_supervised!(Supervisor.child_spec({HandlerServer, options}, id: make_ref()))
    {:ok, transport} = Test.connect(server: root)
    {root, transport}
  end

  defp definition(name),
    do: %{
      "name" => name,
      "description" => "Application-owned descriptor",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "count" => %{"type" => "integer", "minimum" => 1, "default" => 9},
          "nullable" => %{"type" => ["object", "null"]},
          "enabled" => %{"type" => "boolean"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["count"]
      }
    }

  defp entry(definition, defaults \\ %{}, action \\ :echo),
    do: {definition, {Actions, action}, defaults}

  defp register(root, descriptor, defaults \\ %{}, policy \\ :reject, action \\ :echo),
    do: Server.call(root, {:register, [entry(descriptor, defaults, action)], policy})

  defp tool(id, name, arguments),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

  defp modern(request),
    do:
      put_in(request, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "dynamic-example", "version" => "2"}
      })

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp decoded(value) when is_binary(value), do: Jason.decode!(value)
  defp decoded(value), do: value

  defp drain_changed do
    receive do
      {:transport_message, _changed} -> drain_changed()
    after
      0 -> :ok
    end
  end

  defp trace_compiles do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
    collect_compiles(0)
  end

  defp collect_compiles(count) do
    receive do
      {:trace, _pid, :call, {SchemaPolicy, :compile, _args}} -> collect_compiles(count + 1)
    after
      0 -> count
    end
  end

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
