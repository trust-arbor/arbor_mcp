defmodule Arbor.MCP.Server.HandleGetToolTest do
  @moduledoc """
  A modern `tools/call` over Streamable HTTP is checked against the tool's
  `x-mcp-header` annotations. A handler that defines `handle_get_tool/2`
  supplies that one definition, so the check doesn't walk `tools/list`; `nil`
  falls back to the walk, and errors and timeouts fail closed as the walk's
  do (#184).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, ResultNormalizer}
  alias Arbor.MCP.Test.RuntimeHTTPFixture
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  @routed %{
    "name" => "routed",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
    }
  }

  @filler %{"name" => "filler", "inputSchema" => %{"type" => "object"}}

  # Its tools/list has two pages, the routed tool on the second; `:list`
  # makes it fail instead. Every callback reports itself to the test.
  defmodule WalkHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    @impl true
    def init(args), do: {:ok, Map.new(args)}

    @impl true
    def handle_list_tools(cursor, state) do
      send(state.test_pid, {:listed, cursor, Fixture.method()})
      Fixture.page(cursor, state)
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      send(state.test_pid, {:called, name, arguments})
      {:ok, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]}, state}
    end
  end

  # The same list, plus handle_get_tool/2 answering as `:lookup` says.
  defmodule LookupHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    @impl true
    def init(args), do: {:ok, Map.new(args)}

    @impl true
    def handle_list_tools(cursor, state) do
      send(state.test_pid, {:listed, cursor, Fixture.method()})
      Fixture.page(cursor, state)
    end

    @impl true
    def handle_get_tool(name, state) do
      send(state.test_pid, {:got_tool, name, Fixture.method()})
      Fixture.lookup(name, state)
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      send(state.test_pid, {:called, name, arguments})
      {:ok, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]}, state}
    end
  end

  # A DSL server paged one tool at a time, the routed tool last.
  defmodule DSLServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl", version: "1.0.0", page_size: 1

    tool "first", "First filler" do
      run(fn _args, state -> {:ok, "first", state} end)
    end

    tool "second", "Second filler" do
      run(fn _args, state -> {:ok, "second", state} end)
    end

    tool "routed", "Routed by region" do
      input_schema(%{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      })

      run(fn args, state -> {:ok, "routed #{inspect(args)}", state} end)
    end
  end

  # The same DSL tools, with the module's own handle_get_tool/2.
  defmodule DSLOwnLookupServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl-own", version: "1.0.0", page_size: 1

    tool "first", "First filler" do
      run(fn _args, state -> {:ok, "first", state} end)
    end

    tool "routed", "Routed by region" do
      input_schema(%{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      })

      run(fn args, state -> {:ok, "routed #{inspect(args)}", state} end)
    end

    @impl true
    def handle_get_tool(_name, state), do: {:ok, nil, state}
  end

  # A component whose tool the host imports.
  defmodule SharedTools do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-shared", version: "1.0.0"

    tool "shared", "Imported from a component" do
      input_schema(%{
        type: "object",
        properties: %{tenant: %{type: "string", "x-mcp-header": "Tenant"}}
      })

      run(fn _args, state -> {:ok, "shared", state} end)
    end
  end

  # Several tools over three pages, most with annotations of each kind.
  defmodule DSLManyServer do
    use Arbor.MCP.Server.Handler

    use Arbor.MCP.Server.DSL,
      name: "get-tool-many",
      version: "1.0.0",
      page_size: 2,
      components: [SharedTools]

    tool "plain", "No annotations" do
      param(:message, :string, required: true)
      run(fn _args, state -> {:ok, "plain", state} end)
    end

    tool "routed", "A string annotation" do
      input_schema(%{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      })

      run(fn _args, state -> {:ok, "routed", state} end)
    end

    tool "nested", "An annotation on a nested property" do
      input_schema(%{
        type: "object",
        properties: %{
          target: %{
            type: "object",
            properties: %{zone: %{type: "string", "x-mcp-header": "Zone"}}
          }
        }
      })

      run(fn _args, state -> {:ok, "nested", state} end)
    end

    tool "limited", "Integer and boolean annotations" do
      input_schema(%{
        type: "object",
        properties: %{
          limit: %{type: "integer", "x-mcp-header": "Limit"},
          dry_run: %{type: "boolean", "x-mcp-header": "Dry-Run"}
        }
      })

      run(fn _args, state -> {:ok, "limited", state} end)
    end
  end

  # Codex's case: the declared region has no annotation, and the module's
  # own list advertises one.
  defmodule DSLListOverride do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-list-override", version: "1.0.0"

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    tool "routed", "Declared without an annotation" do
      input_schema(%{type: "object", properties: %{region: %{type: "string"}}})
      run(fn _args, state -> {:ok, "routed", state} end)
    end

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [Fixture.routed()], nil, state}
  end

  # The same, with the annotation added to the declared list through super.
  defmodule DSLSuperOverride do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-super-override", version: "1.0.0"

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    tool "routed", "Declared without an annotation" do
      input_schema(%{type: "object", properties: %{region: %{type: "string"}}})
      run(fn _args, state -> {:ok, "routed", state} end)
    end

    @impl true
    def handle_list_tools(cursor, state) do
      {:ok, tools, next, state} = super(cursor, state)
      {:ok, Enum.map(tools, &Fixture.annotate_region/1), next, state}
    end
  end

  # Both overridden, consistently.
  defmodule DSLBothOverride do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-both-override", version: "1.0.0"

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    tool "routed", "Declared without an annotation" do
      input_schema(%{type: "object", properties: %{region: %{type: "string"}}})
      run(fn _args, state -> {:ok, "routed", state} end)
    end

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [Fixture.routed()], nil, state}

    @impl true
    def handle_get_tool(name, state),
      do: {:ok, Map.get(%{"routed" => Fixture.routed()}, name), state}
  end

  defmodule DSLWithoutTools do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl-empty", version: "1.0.0"

    prompt "hello", "Says hello" do
      render(fn _args, state -> {:ok, %{messages: []}, state} end)
    end
  end

  @doc false
  def routed, do: @routed

  @doc false
  def annotate_region(%{name: "routed"} = tool),
    do: put_in(tool, [:inputSchema, :properties, :region, :"x-mcp-header"], "Region")

  def annotate_region(tool), do: tool

  @doc false
  def method do
    case Context.current() do
      %{method: method} -> method
      nil -> nil
    end
  end

  @doc false
  def page(cursor, state) do
    pause(state, :page_ms)

    case {Map.get(state, :list, :paged), cursor} do
      {:paged, nil} -> {:ok, [@filler], "p2", state}
      {:paged, "p2"} -> {:ok, [@routed], nil, state}
      {:endless, _cursor} -> {:ok, [@filler], "more", state}
      {:error, _cursor} -> {:error, :upstream_down, state}
      {:raise, _cursor} -> raise "upstream listing failed"
      {:block, _cursor} -> block()
    end
  end

  @doc false
  def lookup(name, state) do
    pause(state, :lookup_ms)

    case state.lookup do
      :found -> {:ok, Map.get(%{"routed" => @routed}, name), state}
      :atom_keys -> {:ok, atom_keyed(), state}
      :short_found -> {:ok, @routed}
      :short_nil -> {:ok, nil}
      nil -> {:ok, nil, state}
      :other_name -> {:ok, Map.put(@routed, "name", "other"), state}
      :error -> {:error, :upstream_down, state}
      :invalid -> :bogus
      :raise -> raise "upstream lookup failed"
      :block -> block()
    end
  end

  # A handler that is slow on purpose: what is measured is the time.
  defp pause(state, key) do
    case Map.get(state, key, 0) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end
  end

  # Never returns: the server's deadline has to end the request.
  defp block do
    receive do
      :never_sent -> :ok
    end
  end

  defp atom_keyed do
    %{
      name: "routed",
      inputSchema: %{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      }
    }
  end

  defp listed do
    receive do
      {:listed, cursor, method} -> [{cursor, method} | listed()]
    after
      0 -> []
    end
  end

  describe "on a Runtime (every HttpPlug mount)" do
    test "handle_get_tool/2 supplies the definition and tools/list is never called" do
      response = post(LookupHandler, [lookup: :found], [{"mcp-param-region", "eu"}])

      assert response.status == 200, inspect(response.body)
      assert response.body["result"]["content"] == [%{"type" => "text", "text" => "ran routed"}]
      assert_received {:got_tool, "routed", "tools/call"}
      assert_received {:called, "routed", %{"region" => "eu"}}
      assert listed() == []
    end

    test "a header mismatch is still rejected through handle_get_tool/2" do
      for headers <- [[{"mcp-param-region", "us"}], []] do
        response = post(LookupHandler, [lookup: :found], headers)

        assert response.status == 400
        assert response.body["error"]["code"] == -32020
        assert_received {:got_tool, "routed", "tools/call"}
      end

      refute_received {:called, _name, _arguments}
      assert listed() == []
    end

    test "an atom-keyed definition is checked like a string-keyed one" do
      assert %{status: 400} =
               post(LookupHandler, [lookup: :atom_keys], [{"mcp-param-region", "us"}])

      assert %{status: 200} =
               post(LookupHandler, [lookup: :atom_keys], [{"mcp-param-region", "eu"}])

      assert listed() == []
    end

    test "a reply without the state is accepted, as for other callbacks" do
      assert %{status: 400} =
               post(LookupHandler, [lookup: :short_found], [{"mcp-param-region", "us"}])

      assert listed() == []

      assert %{status: 400} =
               post(LookupHandler, [lookup: :short_nil], [{"mcp-param-region", "us"}])

      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
    end

    test "nil falls back to the tools/list walk, which still checks the headers" do
      mismatched = post(LookupHandler, [lookup: nil], [{"mcp-param-region", "us"}])

      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020
      assert_received {:got_tool, "routed", "tools/call"}
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      refute_received {:called, _name, _arguments}

      matching = post(LookupHandler, [lookup: nil], [{"mcp-param-region", "eu"}])

      assert matching.status == 200, inspect(matching.body)
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      assert_received {:called, "routed", %{"region" => "eu"}}
    end

    test "a handler without handle_get_tool/2 walks tools/list as before" do
      refute function_exported?(WalkHandler, :handle_get_tool, 2)

      mismatched = post(WalkHandler, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]

      assert %{status: 200} = post(WalkHandler, [], [{"mcp-param-region", "eu"}])
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      refute_received {:got_tool, _name, _method}
    end

    test "an error, an invalid reply or another tool's definition fails closed, as a failed page does" do
      walk_error = post(WalkHandler, [list: :error], [{"mcp-param-region", "eu"}])

      assert walk_error.status == 400
      assert walk_error.body["error"]["code"] == -32020
      assert walk_error.body["error"]["message"] == "Tool schema unavailable"

      for lookup <- [:error, :invalid, :other_name] do
        response = post(LookupHandler, [lookup: lookup], [{"mcp-param-region", "eu"}])

        assert {lookup, response.status, response.body} ==
                 {lookup, walk_error.status, walk_error.body}
      end

      refute_received {:called, _name, _arguments}
      assert listed() == [{nil, "tools/call"}]
    end

    test "a raise in handle_get_tool/2 answers as a raise in the walk does" do
      {{walk, lookup}, _log} =
        with_log(fn ->
          {post(WalkHandler, [list: :raise], [{"mcp-param-region", "eu"}]),
           post(LookupHandler, [lookup: :raise], [{"mcp-param-region", "eu"}])}
        end)

      assert walk.body["error"]
      assert {lookup.status, lookup.body} == {walk.status, walk.body}
      refute_received {:called, _name, _arguments}
    end

    test "a handle_get_tool/2 that never answers ends at the request deadline, as the walk does" do
      timeout = [request_timeout_ms: 300]

      walk = post(WalkHandler, [list: :block], [{"mcp-param-region", "eu"}], timeout)
      lookup = post(LookupHandler, [lookup: :block], [{"mcp-param-region", "eu"}], timeout)

      assert walk.body["error"]["data"]["type"] == "handler_timeout"
      assert {lookup.status, lookup.body} == {walk.status, walk.body}
      refute_received {:called, _name, _arguments}
    end
  end

  describe "through a MessageProcessor handler process" do
    test "handle_get_tool/2 supplies the definition and tools/list is never called" do
      conn = process(LookupHandler, [lookup: :found], [{"mcp-param-region", "eu"}])

      assert conn.response["result"], inspect(conn.response)
      assert_received {:got_tool, "routed", "tools/call"}
      assert_received {:called, "routed", %{"region" => "eu"}}
      assert listed() == []
    end

    test "a header mismatch is still rejected through handle_get_tool/2" do
      conn = process(LookupHandler, [lookup: :found], [{"mcp-param-region", "us"}])

      assert conn.response["error"]["code"] == -32020
      assert conn.assigns.http_status == 400
      refute_received {:called, _name, _arguments}
      assert listed() == []
    end

    test "a reply without the state is accepted, as on a Runtime" do
      conn = process(LookupHandler, [lookup: :short_found], [{"mcp-param-region", "us"}])
      assert conn.response["error"]["code"] == -32020
      assert listed() == []

      conn = process(LookupHandler, [lookup: :short_nil], [{"mcp-param-region", "us"}])
      assert conn.response["error"]["code"] == -32020
      assert [{nil, _method}, {"p2", _method2}] = listed()
    end

    test "nil falls back to the tools/list walk" do
      conn = process(LookupHandler, [lookup: nil], [{"mcp-param-region", "us"}])

      assert conn.response["error"]["code"] == -32020
      assert_received {:got_tool, "routed", "tools/call"}
      assert [{nil, _method}, {"p2", _method2}] = listed()
    end

    test "an error, an invalid reply or another tool's definition fails closed, as a failed page does" do
      walk = process(WalkHandler, [list: :error], [{"mcp-param-region", "eu"}])
      assert walk.response["error"]["data"]["type"] == "tool_schema_unavailable"

      {responses, _log} =
        with_log(fn ->
          for lookup <- [:error, :invalid, :other_name, :raise] do
            conn = process(LookupHandler, [lookup: lookup], [{"mcp-param-region", "eu"}])
            {lookup, conn.response}
          end
        end)

      for {lookup, response} <- responses,
          do: assert({lookup, response} == {lookup, walk.response})

      refute_received {:called, _name, _arguments}
    end

    @tag timeout: 10_000
    test "a handle_get_tool/2 past the handler_call_timeout fails closed without a walk" do
      started = System.monotonic_time(:millisecond)
      conn = process(LookupHandler, [lookup: :block], [{"mcp-param-region", "eu"}], 300)

      assert conn.response["error"]["data"]["type"] == "tool_schema_unavailable"
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert listed() == []
    end

    test "the lookup and the walk after a nil share one handler_call_timeout" do
      # The lookup takes 200 of the 300 ms. A 200 ms page then has 100 ms
      # left, so at most the first page is asked for; a walk with a
      # timeout of its own would reach the second.
      handler_opts = [lookup: nil, lookup_ms: 200, list: :endless, page_ms: 200]
      conn = process(LookupHandler, handler_opts, [{"mcp-param-region", "eu"}], 300)

      assert conn.response["error"]["data"]["type"] == "tool_schema_unavailable"
      assert length(listed()) <= 1
    end
  end

  describe "DSL servers" do
    setup do
      traced = [DSLServer, DSLOwnLookupServer, DSLManyServer]

      for module <- traced,
          do: :erlang.trace_pattern({module, :handle_list_tools, 2}, true, [:call_count])

      on_exit(fn ->
        for module <- traced,
            do: :erlang.trace_pattern({module, :handle_list_tools, 2}, false, [:call_count])
      end)
    end

    test "get handle_get_tool/2 for their declared tools" do
      assert {:ok, %{name: "routed", inputSchema: schema}, :state} =
               DSLServer.handle_get_tool("routed", :state)

      assert schema.properties.region[:"x-mcp-header"] == "Region"
      assert {:ok, %{name: "first"}, :state} = DSLServer.handle_get_tool("first", :state)
      assert {:ok, nil, :state} = DSLServer.handle_get_tool("unknown", :state)
      refute function_exported?(DSLWithoutTools, :handle_get_tool, 2)
    end

    test "check the headers without paging through tools/list" do
      mismatched = post(DSLServer, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020

      matching = post(DSLServer, [], [{"mcp-param-region", "eu"}])
      assert matching.status == 200, inspect(matching.body)

      assert :erlang.trace_info({DSLServer, :handle_list_tools, 2}, :call_count) ==
               {:call_count, 0}
    end

    test "keep a handle_get_tool/2 the module defines" do
      assert {:ok, nil, :state} = DSLOwnLookupServer.handle_get_tool("routed", :state)

      mismatched = post(DSLOwnLookupServer, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020

      # Its nil walks both pages.
      assert :erlang.trace_info({DSLOwnLookupServer, :handle_list_tools, 2}, :call_count) ==
               {:call_count, 2}
    end

    test "return exactly the definitions their tools/list pages hold" do
      listed = raw_pages(DSLManyServer, nil)

      assert Enum.map(listed, & &1.name) == ["shared", "plain", "routed", "nested", "limited"]

      for definition <- listed do
        assert {:ok, ^definition, :state} = DSLManyServer.handle_get_tool(definition.name, :state)
      end

      # And the entries a client lists over HTTP, page by page.
      runtime = runtime(DSLManyServer)
      wire = wire_tools(runtime, nil)

      assert Enum.sort(Enum.map(wire, & &1["name"])) == Enum.sort(Enum.map(listed, & &1.name))

      for entry <- wire do
        {:ok, definition, :state} = DSLManyServer.handle_get_tool(entry["name"], :state)
        assert ResultNormalizer.stringify_keys(definition) == entry
      end
    end

    test "check every kind of annotation without paging through tools/list" do
      runtime = runtime(DSLManyServer)

      {:call_count, before} =
        :erlang.trace_info({DSLManyServer, :handle_list_tools, 2}, :call_count)

      nested = %{"target" => %{"zone" => "z1"}}
      assert %{status: 400} = call_tool(runtime, "nested", nested, [{"mcp-param-zone", "z2"}])
      assert %{status: 400} = call_tool(runtime, "nested", nested, [])
      assert %{status: 200} = call_tool(runtime, "nested", nested, [{"mcp-param-zone", "z1"}])

      limited = %{"limit" => 5, "dry_run" => true}
      matching = [{"mcp-param-limit", "5"}, {"mcp-param-dry-run", "true"}]
      assert %{status: 200} = call_tool(runtime, "limited", limited, matching)

      assert %{status: 400} =
               call_tool(runtime, "limited", limited, [
                 {"mcp-param-limit", "5"},
                 {"mcp-param-dry-run", "false"}
               ])

      tenant = %{"tenant" => "acme"}

      assert %{status: 400} =
               call_tool(runtime, "shared", tenant, [{"mcp-param-tenant", "other"}])

      assert %{status: 200} = call_tool(runtime, "shared", tenant, [{"mcp-param-tenant", "acme"}])

      assert :erlang.trace_info({DSLManyServer, :handle_list_tools, 2}, :call_count) ==
               {:call_count, before}
    end

    test "leave a tool added with Server.add_tool/3 to its own definition" do
      runtime = runtime(DSLServer)

      zoned = %{
        name: "zoned",
        inputSchema: %{
          type: "object",
          properties: %{zone: %{type: "string", "x-mcp-header": "Zone"}}
        }
      }

      :ok = Server.add_tool(runtime, zoned, fn _arguments -> Server.Result.text("zoned") end)

      assert {:ok, nil, :state} = DSLServer.handle_get_tool("zoned", :state)
      assert "zoned" in Enum.map(wire_tools(runtime, nil), & &1["name"])

      arguments = %{"zone" => "a"}
      assert %{status: 400} = call_tool(runtime, "zoned", arguments, [{"mcp-param-zone", "b"}])
      assert %{status: 400} = call_tool(runtime, "zoned", arguments, [])
      assert %{status: 200} = call_tool(runtime, "zoned", arguments, [{"mcp-param-zone", "a"}])
    end

    test "check a declared name that Server.add_tool/3 replaced against the replacement" do
      runtime = runtime(DSLServer)

      # The declared "routed" takes Mcp-Param-Region; its replacement takes
      # Mcp-Param-Zone for the same argument.
      replacement = %{
        name: "routed",
        inputSchema: %{
          type: "object",
          properties: %{region: %{type: "string", "x-mcp-header": "Zone"}}
        }
      }

      :ok =
        Server.add_tool(runtime, replacement, fn _arguments -> Server.Result.text("replaced") end)

      [listed] = Enum.filter(wire_tools(runtime, nil), &(&1["name"] == "routed"))
      assert listed["inputSchema"]["properties"]["region"]["x-mcp-header"] == "Zone"

      arguments = %{"region" => "eu"}

      assert %{status: 400} =
               call_tool(runtime, "routed", arguments, [{"mcp-param-region", "eu"}])

      assert %{status: 200} = call_tool(runtime, "routed", arguments, [{"mcp-param-zone", "eu"}])
    end
  end

  describe "DSL servers whose tools/list is overridden" do
    setup do
      traced = [DSLListOverride, DSLSuperOverride, DSLBothOverride]

      for module <- traced,
          do: :erlang.trace_pattern({module, :handle_list_tools, 2}, true, [:call_count])

      on_exit(fn ->
        for module <- traced,
            do: :erlang.trace_pattern({module, :handle_list_tools, 2}, false, [:call_count])
      end)
    end

    test "a replaced list leaves out the generated lookup, so the walk checks it" do
      refute function_exported?(DSLListOverride, :handle_get_tool, 2)
      assert_region_checked(DSLListOverride)
      assert {:call_count, count} = list_calls(DSLListOverride)
      assert count > 0
    end

    test "a list extended with super leaves out the generated lookup too" do
      refute function_exported?(DSLSuperOverride, :handle_get_tool, 2)

      assert {:ok, [%{inputSchema: %{properties: %{region: %{"x-mcp-header": "Region"}}}}], nil,
              :state} = DSLSuperOverride.handle_list_tools(nil, :state)

      assert_region_checked(DSLSuperOverride)
    end

    test "a module that overrides both keeps its lookup and lists nothing for the check" do
      assert {:ok, @routed, :state} = DSLBothOverride.handle_get_tool("routed", :state)
      assert_region_checked(DSLBothOverride)
      assert list_calls(DSLBothOverride) == {:call_count, 0}
    end
  end

  # Over a Runtime and through a MessageProcessor handler process, a missing
  # or mismatched Mcp-Param-Region is refused with -32020, and a matching one
  # reaches the tool.
  defp assert_region_checked(handler) do
    for headers <- [[], [{"mcp-param-region", "us"}]] do
      response = post(handler, [], headers)
      assert {headers, response.status, response.body["error"]["code"]} == {headers, 400, -32020}

      conn = process(handler, [], headers)

      assert {headers, conn.assigns[:http_status], conn.response["error"]["code"]} ==
               {headers, 400, -32020}
    end

    assert %{status: 200} = post(handler, [], [{"mcp-param-region", "eu"}])
    assert process(handler, [], [{"mcp-param-region", "eu"}]).response["result"]
  end

  defp list_calls(module), do: :erlang.trace_info({module, :handle_list_tools, 2}, :call_count)

  # A modern tools/call for "routed" with region "eu", through a fresh
  # Runtime-mounted HttpPlug.
  defp post(handler, handler_args, headers, runtime_opts \\ []) do
    handler
    |> runtime(handler_args, runtime_opts)
    |> call_tool("routed", %{"region" => "eu"}, headers)
  end

  defp runtime(handler, handler_args \\ [], runtime_opts \\ []) do
    RuntimeHTTPFixture.start(
      handler,
      Keyword.merge(
        [handler_args: [test_pid: self()] ++ handler_args, request_timeout_ms: 10_000],
        runtime_opts
      )
    )
  end

  defp call_tool(runtime, name, arguments, headers) do
    rpc(runtime, "tools/call", %{"name" => name, "arguments" => arguments}, [
      {"mcp-name", RequestHeaders.encode_value(name)} | headers
    ])
  end

  # Every entry of a modern tools/list over HTTP, following nextCursor.
  defp wire_tools(runtime, cursor) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    %{status: 200, body: %{"result" => result}} = rpc(runtime, "tools/list", params, [])

    case result do
      %{"nextCursor" => next} when is_binary(next) -> result["tools"] ++ wire_tools(runtime, next)
      _last -> result["tools"]
    end
  end

  # Every definition the handler's own tools/list pages hold.
  defp raw_pages(module, cursor) do
    case module.handle_list_tools(cursor, :state) do
      {:ok, tools, nil, :state} -> tools
      {:ok, tools, next, :state} -> tools ++ raw_pages(module, next)
    end
  end

  defp rpc(runtime, method, params, headers) do
    request = modern(method, params)

    conn =
      Enum.reduce(headers, conn(:post, "/", Jason.encode!(request)), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", method)
      |> HttpPlug.call(HttpPlug.init(runtime: runtime, sse_mode: :oneshot))

    %{status: conn.status, body: Jason.decode!(conn.resp_body)}
  end

  defp process(handler, handler_opts, headers, timeout \\ 10_000) do
    tools_call()
    |> MessageProcessor.new(transport: :http)
    |> MessageProcessor.process(%{
      handler: handler,
      handler_opts: [test_pid: self()] ++ handler_opts,
      handler_call_timeout: timeout,
      protocol_mode: :modern_only,
      request_headers: headers,
      endpoint: "/mcp"
    })
  end

  defp tools_call,
    do: modern("tools/call", %{"name" => "routed", "arguments" => %{"region" => "eu"}})

  defp modern(method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 184,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end
end
