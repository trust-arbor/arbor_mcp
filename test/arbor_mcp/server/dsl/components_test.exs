defmodule Arbor.MCP.Server.DSL.ComponentsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, Runtime}
  alias Arbor.MCP.Server.Runtime.CallbackContext
  alias Arbor.MCP.Transport.{Local, Test}

  defmodule Formatting do
    def label(value), do: "private:#{value}"
  end

  defmodule Leaf do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "leaf", version: "99"

    alias Arbor.MCP.Server.DSL.ComponentsTest.Formatting, as: LocalFormatting

    @impl true
    def init(_opts), do: raise("component initialization must never run")

    tool "shared", "Shared stateful tool" do
      title("Shared Tool")
      annotations(readOnlyHint: false)
      param(:count, :integer, default: 1, minimum: 1, maximum: 5)
      param(:label, :string, default: "ok", min_length: 2)
      param(:tags, {:array, :string}, default: [])
      param(:enabled, :boolean, default: false)
      param(:nullable, :object, schema: %{type: ["object", "null"]}, default: nil)

      output_schema(%{
        type: "object",
        properties: %{count: %{type: "integer"}, label: %{type: "string"}},
        required: ["count", "label"]
      })

      run(fn args, state -> run_shared(args, state) end)
    end

    tool "bad_output" do
      output_schema(%{type: "object", properties: %{count: %{type: "integer"}}})

      run(fn _args, state ->
        {:ok, ToolResult.structured("invalid", %{count: "bad"}),
         %{state | count: state.count + 1}}
      end)
    end

    tool "authored_error" do
      run(fn _args, state -> {:ok, ToolResult.error("authored failure"), state} end)
    end

    tool "scoped" do
      run(fn _args, state ->
        send(
          state.test_pid,
          {:component_context, self(), Context.current(), CallbackContext.current()}
        )

        result =
          Server.notify_progress(CallbackContext.current().runtime, "component-progress", 1)

        send(state.test_pid, {:component_progress, result})

        receive do
          :finish_component -> :ok
        end

        {:ok, ToolResult.structured("scoped", %{count: state.count + 1}),
         %{state | count: state.count + 1}}
      end)
    end

    tool "hold" do
      run(fn _args, state ->
        send(state.test_pid, {:component_holding, self(), Context.scope()})

        receive do
          {:arbor_mcp_cancelled, _token, _reason} ->
            send(state.test_pid, {:component_cancelled, Context.cancelled?()})
            {:ok, ToolResult.structured("late", %{count: 900}), %{state | count: 900}}
        end
      end)
    end

    resource "component://fixed", "Shared static resource" do
      title("Shared Resource")
      mime_type("text/plain")
      read(fn %{uri: uri}, state -> {:ok, private_label(uri), Map.put(state, :last_uri, uri)} end)
    end

    resource_template "component://row/{id}", "Shared row" do
      title("Shared Template")
      mime_type("text/plain")
      param(:id, :string)
      read(fn %{id: id}, state -> {:ok, private_label(id), Map.put(state, :last_id, id)} end)
    end

    prompt "shared_prompt", "Shared prompt" do
      title("Shared Prompt")
      arg(:label, required: true)

      render(fn %{label: label}, state ->
        {:ok,
         %{messages: [%{role: "user", content: %{type: "text", text: private_label(label)}}]},
         Map.put(state, :last_prompt, label)}
      end)
    end

    defp run_shared(args, state) do
      if state[:test_pid], do: send(state.test_pid, {:component_invoked, self(), args})
      count = state.count + args.count

      result =
        ToolResult.structured("accepted", %{count: count, label: private_label(args.label)})

      {:ok, result, %{state | count: count}}
    end

    defp private_label(value), do: LocalFormatting.label(value)
  end

  defmodule Group do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, components: [Leaf], name: "group", version: "88"

    tool "group_local" do
      run(fn _args, state -> {:ok, "group", state} end)
    end
  end

  defmodule Host do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, components: [Group], name: "host", version: "2"
    defoverridable handle_call: 3

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:host_initialized, self()})
      {:ok, %{count: 0, test_pid: opts[:test_pid], cancelled_requests: MapSet.new()}}
    end

    @impl true
    def handle_call(:count, _from, state), do: {:reply, state.count, state}
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}

    tool "host_local" do
      run(fn _args, state -> {:ok, "host", state} end)
    end
  end

  test "nested descriptors flatten once in declaration order and retain declaring modules" do
    info = Host.__mcp_dsl_component__()
    assert info.version == 1

    assert Enum.map(info.tools, & &1.id) ==
             [
               "shared",
               "bad_output",
               "authored_error",
               "scoped",
               "hold",
               "group_local",
               "host_local"
             ]

    assert Enum.map(info.tools, & &1.module) == [Leaf, Leaf, Leaf, Leaf, Leaf, Group, Host]
    assert [%{id: "component://fixed", module: Leaf, source: source}] = info.resources
    assert source.file == __ENV__.file
    assert source.line > 0
    assert [%{id: "component://row/{id}", module: Leaf}] = info.resource_templates
    assert [%{id: "shared_prompt", module: Leaf}] = info.prompts
    refute Map.has_key?(info, :init)
    refute Map.has_key?(info, :server_info)
    assert {:ok, tools, nil, state} = Host.handle_list_tools(nil, %{count: 0})
    assert state == %{count: 0}
    assert Enum.map(tools, & &1.name) == Enum.map(info.tools, & &1.id)

    assert {:ok, %{content: [%{text: "group"}]}, _} =
             Host.handle_call_tool("group_local", %{}, state)

    assert {:ok, %{content: [%{text: "host"}]}, _} =
             Host.handle_call_tool("host_local", %{}, state)
  end

  test "components retain schema metadata, private helpers, lexical aliases and exact defaults" do
    assert {:ok, tools, nil, _} = Host.handle_list_tools(nil, %{count: 0})
    shared = Enum.find(tools, &(&1.name == "shared"))
    assert shared.title == "Shared Tool"
    assert shared.annotations == %{readOnlyHint: false}
    assert shared.inputSchema.properties.count.maximum == 5
    assert shared.inputSchema.properties.enabled.default == false
    assert Map.fetch(shared.inputSchema.properties.nullable, :default) == {:ok, nil}
    assert shared.outputSchema.required == ["count", "label"]

    state = %{count: 10, test_pid: self()}

    assert {:ok, %{structuredContent: %{count: 11, label: "private:ok"}}, next} =
             Host.handle_call_tool("shared", %{}, state)

    assert next.count == 11
    assert_receive {:component_invoked, _, %{count: 1, tags: [], enabled: false, nullable: nil}}
    refute_receive {:component_invoked, _, _}, 10
  end

  test "input rejection runs before the inherited callback and preserves host state" do
    state = %{count: 3, test_pid: self()}

    for args <- [%{"count" => 0}, %{"count" => "2"}, %{"label" => "a"}] do
      assert {:error, %Arbor.MCP.Error.ProtocolError{code: -32602}, ^state} =
               Host.handle_call_tool("shared", args, state)
    end

    refute_receive {:component_invoked, _, _}, 10
  end

  test "authored errors and output validation preserve constituent result semantics" do
    assert {:ok, %{isError: true, content: [%{text: "authored failure"}]}, %{count: 0}} =
             Host.handle_call_tool("authored_error", %{}, %{count: 0})

    assert {:ok, %{isError: true, content: [%{text: message}]}, %{count: 1}} =
             Host.handle_call_tool("bad_output", %{}, %{count: 0})

    assert message =~ "Output validation failed"
  end

  test "all inherited resource and prompt primitives preserve metadata, helpers and shared state" do
    state = %{count: 0}

    assert {:ok, [%{title: "Shared Resource", mimeType: "text/plain"}], nil, ^state} =
             Host.handle_list_resources(nil, state)

    assert {:ok, content, next} = Host.handle_read_resource("component://fixed", state)

    assert content == %{
             uri: "component://fixed",
             text: "private:component://fixed",
             mimeType: "text/plain"
           }

    assert next.last_uri == "component://fixed"

    assert {:ok, [%{uriTemplate: "component://row/{id}", title: "Shared Template"}], nil, ^next} =
             Host.handle_list_resource_templates(nil, next)

    assert {:ok, %{uri: "component://row/42", text: "private:42"}, next} =
             Host.handle_read_resource("component://row/42", next)

    assert next.last_id == "42"

    assert {:ok, [%{name: "shared_prompt", title: "Shared Prompt"}], nil, ^next} =
             Host.handle_list_prompts(nil, next)

    assert {:ok, %{messages: [%{content: %{text: "private:hello"}}]}, next} =
             Host.handle_get_prompt("shared_prompt", %{"label" => "hello"}, next)

    assert next.last_prompt == "hello"
    assert next.count == 0
  end

  test "host initialization info and capabilities do not inherit component server options" do
    assert Host.__server_info__() == %{"name" => "host", "version" => "2"}

    assert Host.__server_capabilities__() == %{
             "tools" => %{},
             "resources" => %{},
             "prompts" => %{}
           }

    assert {:ok, result, state} = Host.handle_initialize(%{}, %{count: 0})
    assert result["serverInfo"] == %{"name" => "host", "version" => "2"}
    assert result["capabilities"] == %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}
    assert state.count == 0
  end

  test "component lists resolve lexical aliases at the use declaration" do
    module = unique_module("AliasHost")

    source = """
    defmodule #{inspect(module)} do
      use Arbor.MCP.Server.Handler
      alias #{inspect(Leaf)}, as: Shared
      use Arbor.MCP.Server.DSL, components: [Shared]
      alias #{inspect(Group)}, as: Shared
      def alias_after_use, do: Shared
    end
    """

    Code.compile_string(source, "component_alias_fixture.ex")
    assert module.alias_after_use() == Group
    assert Enum.map(module.__mcp_dsl_component__().tools, & &1.module) == List.duplicate(Leaf, 5)
  end

  test "one file can declare a reusable component followed by its host" do
    leaf = unique_module("OneFileLeaf")
    host = unique_module("OneFileHost")

    source = """
    defmodule #{inspect(leaf)} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL
      defp prefix, do: "local"
      tool "one_file" do
        run fn _args, state -> {:ok, prefix(), Map.put(state, :called, true)} end
      end
    end
    defmodule #{inspect(host)} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, components: [#{inspect(leaf)}]
    end
    """

    Code.compile_string(source, "component_one_file.ex")

    assert {:ok, %{content: [%{text: "local"}]}, %{called: true}} =
             host.handle_call_tool("one_file", %{}, %{})
  end

  test "every primitive rejects duplicates against local declarations with source locations" do
    for {label, declaration} <- [
          {"tool", ~s(tool "shared" do\nrun fn _args, state -> {:ok, "x", state} end\nend)},
          {"resource",
           ~s(resource "component://fixed" do\nread fn _args, state -> {:ok, "x", state} end\nend)},
          {"resource_template",
           ~s(resource_template "component://row/{id}" do\nread fn _args, state -> {:ok, "x", state} end\nend)},
          {"prompt",
           ~s(prompt "shared_prompt" do\nrender fn _args, state -> {:ok, %{messages: []}, state} end\nend)}
        ] do
      source = """
      defmodule #{inspect(unique_module("Duplicate"))} do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL, components: [#{inspect(Leaf)}]
        #{declaration}
      end
      """

      error =
        assert_raise CompileError, fn -> Code.compile_string(source, "component_duplicate.ex") end

      assert error.file == "component_duplicate.ex"
      assert error.line == 4
      assert error.description =~ "Duplicate #{label}"
      assert error.description =~ "component_duplicate.ex:4"
      assert error.description =~ __ENV__.file
    end
  end

  test "nested repeated components fail at the use declaration instead of silently deduplicating" do
    source = """
    defmodule #{inspect(unique_module("NestedDuplicate"))} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, components: [#{inspect(Group)}, #{inspect(Leaf)}]
    end
    """

    error =
      assert_raise CompileError, fn -> Code.compile_string(source, "nested_duplicate.ex") end

    assert error.line == 3
    assert error.description =~ "Duplicate tool"
    assert error.description =~ __ENV__.file
  end

  test "invalid component declarations fail clearly at the use declaration" do
    for option <- ["nil", "[nil]", "[String]", "[MissingComponentModule]"] do
      source = """
      defmodule #{inspect(unique_module("Invalid"))} do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL, components: #{option}
      end
      """

      error =
        assert_raise CompileError, fn -> Code.compile_string(source, "invalid_component.ex") end

      assert error.file == "invalid_component.ex"
      assert error.line == 3
      assert error.description =~ "component"
    end
  end

  test "self inclusion is rejected without waiting for compilation" do
    module = unique_module("SelfComponent")

    source = """
    defmodule #{inspect(module)} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, components: [#{inspect(module)}]
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, "self_component.ex") end
    assert error.line == 3
    assert error.description =~ "cannot include itself"
  end

  test "Test runtime initializes only host and inherited tools share one scheduler state" do
    {root, transport} = start_host(:test)
    assert_receive {:host_initialized, owner}
    assert {:ok, runtime} = Runtime.ref(root)
    assert {:ok, transport} = Test.send_message(tool(1, "shared"), transport)
    assert_receive {:component_invoked, worker, _args}
    refute worker == owner
    assert_receive {:transport_message, encoded}
    assert response(encoded)["result"]["structuredContent"]["count"] == 1
    refute_receive {:component_invoked, _, _}, 10
    assert Server.call(runtime, :count) == 1
    assert {:ok, _transport} = Test.send_message(tool(2, "shared", %{"count" => 2}), transport)
    assert_receive {:component_invoked, _, _args}
    assert_receive {:transport_message, encoded}
    assert response(encoded)["result"]["structuredContent"]["count"] == 3
    assert Server.call(runtime, :count) == 3
    refute_receive {:host_initialized, _}, 10
  end

  test "BEAM batch inheritance preserves sequential effects and callback control context" do
    {root, transport} = start_host(:beam)

    assert {:ok, transport} =
             Local.send_message([tool(1, "shared"), tool(2, "shared")], transport)

    assert_receive {:component_invoked, _, _}
    assert_receive {:component_invoked, _, _}
    assert_receive {:transport_message, encoded}
    assert Enum.map(response(encoded), & &1["result"]["structuredContent"]["count"]) == [1, 2]
    assert {:ok, _transport} = Local.send_message(tool(3, "scoped"), transport)
    assert_receive {:component_context, worker, %{request_id: 3}, callback}
    assert callback.scope == {:connection, transport.connection}
    assert callback.runtime != nil
    assert_receive {:component_progress, :ok}
    assert_receive {:transport_message, progress}
    assert response(progress)["method"] == "notifications/progress", inspect(response(progress))
    send(worker, :finish_component)
    assert_receive {:transport_message, result}
    assert response(result)["result"]["structuredContent"]["count"] == 3
    assert Server.call(root, :count) == 3
  end

  test "resource and prompt dispatch through the root retain the same host state" do
    {root, transport} = start_host(:test)

    for {id, method, params} <- [
          {1, "resources/read", %{"uri" => "component://fixed"}},
          {2, "resources/read", %{"uri" => "component://row/42"}},
          {3, "prompts/get", %{"name" => "shared_prompt", "arguments" => %{"label" => "hello"}}}
        ] do
      request = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      assert {:ok, _transport} = Test.send_message(request, transport)
      assert_receive {:transport_message, encoded}, 1_000
      result = response(encoded)
      assert result["id"] == id
      refute Map.has_key?(result, "error")
    end

    state = Server.call(root, :snapshot)
    assert state.count == 0
    assert state.last_uri == "component://fixed"
    assert state.last_id == "42"
    assert state.last_prompt == "hello"
  end

  test "unsupported descriptor versions and malformed entries fail during host compilation" do
    for descriptor <- [
          "%{version: 2}",
          "%{version: 1, tools: [%{}], resources: [], resource_templates: [], prompts: []}"
        ] do
      component = unique_module("BadDescriptor")
      host = unique_module("BadDescriptorHost")

      source = """
      defmodule #{inspect(component)} do
        def __mcp_dsl_component__, do: #{descriptor}
      end
      defmodule #{inspect(host)} do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL, components: [#{inspect(component)}]
      end
      """

      error =
        assert_raise CompileError, fn ->
          Code.compile_string(source, "component_descriptor.ex")
        end

      assert error.line == 6
      assert error.description =~ "not a compatible compiled Server.DSL component"
    end
  end

  test "inherited callback cancellation keeps host state unchanged" do
    {root, transport} = start_host(:test)
    assert {:ok, transport} = Test.send_message(tool("held", "hold"), transport)
    assert_receive {:component_holding, _worker, scope}
    assert scope == {:connection, transport.connection}
    assert {:ok, _transport} = Test.send_message(cancel("held"), transport)
    assert_receive {:component_cancelled, true}
    assert_receive {:transport_message, encoded}
    assert response(encoded)["error"]["code"] == -32001
    assert Server.call(root, :count) == 0
  end

  defp start_host(transport) do
    root = start_supervised!({Host, transport: transport, handler_args: [test_pid: self()]})
    module = if transport == :beam, do: Local, else: Test
    {:ok, connection} = module.connect(server: root)
    {root, connection}
  end

  defp unique_module(name),
    do: Module.concat(__MODULE__, "#{name}#{System.unique_integer([:positive])}")

  defp tool(id, name, arguments \\ %{}),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp response(value) when is_binary(value), do: Jason.decode!(value)
  defp response(value), do: value
end
