defmodule Arbor.MCP.MessageProcessorValidationTest do
  @moduledoc """
  Validation framework for testing message processor routing behavior.

  This test demonstrates the fundamental flaw in the message processor where
  handler-based servers fail because the processor calls DSL-style functions
  that don't exist on handler modules.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server.{HandlerServer, ResultNormalizer}

  # Minimal handler-based server
  defmodule MinimalHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{name: "minimal-handler"}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "minimal-handler", version: "1.0.0"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "test_tool",
          description: "A test tool",
          input_schema: %{},
          output_schema: %{type: "object"}
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, args, state) do
      {:ok, %{content: [%{type: "text", text: "Called #{name} with #{inspect(args)}"}]}, state}
    end

    # Required callbacks for handler behavior
    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_get_prompt(_name, _args, state), do: {:error, "Not implemented", state}

    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_read_resource(_uri, state), do: {:error, "Not implemented", state}

    # Bridge clauses are now provided by `use Arbor.MCP.Server.Handler` inline.
    # No manual handle_call/3 needed.
  end

  # Minimal DSL-based server
  defmodule MinimalDslServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "minimal-dsl", version: "1.0.0"

    tool "test_tool", "A test tool for DSL server" do
      title("Test Tool")

      input_schema(%{
        type: "object",
        properties: %{}
      })

      run(fn args, state ->
        {:ok, %{content: [%{type: "text", text: "DSL called with #{inspect(args)}"}]}, state}
      end)
    end
  end

  describe "message processor routing validation" do
    test "raw Handler protocol fields use their MCP wire names" do
      assert ResultNormalizer.stringify_keys(%{
               mime_type: "text/plain",
               uri_template: "file:///{path}",
               list_pattern: "*.txt"
             }) == %{
               "mimeType" => "text/plain",
               "uriTemplate" => "file:///{path}",
               "listPattern" => "*.txt"
             }
    end

    test "handler server works correctly with new routing" do
      # Start the handler server first
      {:ok, server} =
        HandlerServer.start_link(
          transport: :test,
          handler: MinimalHandler,
          handler_args: []
        )

      # Create a tools/list request
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{},
        "id" => 1
      }

      # Create connection with handler server
      conn = MessageProcessor.new(request, transport: :test)
      opts = %{server: server}

      # This should now work with the fixed routing
      result = MessageProcessor.process(conn, opts)

      # Verify we got a successful response
      assert result.response["jsonrpc"] == "2.0"
      assert result.response["id"] == 1
      assert is_map(result.response["result"])
      assert is_list(result.response["result"]["tools"])

      # Verify the tool from our handler
      tools = result.response["result"]["tools"]
      assert length(tools) == 1

      # Check the actual structure returned
      tool = hd(tools)
      assert tool["name"] == "test_tool"
      assert tool["inputSchema"] == %{}
      assert tool["outputSchema"] == %{"type" => "object"}
      refute Map.has_key?(tool, "input_schema")
      refute Map.has_key?(tool, "output_schema")

      # Cleanup
      GenServer.stop(server)
    end

    test "DSL server works correctly through message processor" do
      # Create a tools/list request
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{},
        "id" => 1
      }

      # Create connection with DSL server
      conn = MessageProcessor.new(request, transport: :test)
      opts = %{handler: MinimalDslServer}

      # This should work because DSL servers have the expected functions
      result = MessageProcessor.process(conn, opts)

      # DSL server returns the tool with metadata
      tools = result.response["result"]["tools"]
      assert length(tools) == 1

      tool = hd(tools)
      assert tool["name"] == "test_tool"
      assert tool["description"] == "A test tool for DSL server"
      assert tool["title"] == "Test Tool"
    end

    test "new DSL servers expose handler callbacks and generated start_link" do
      assert function_exported?(MinimalDslServer, :start_link, 1)
      assert function_exported?(MinimalDslServer, :handle_list_tools, 2)
      assert function_exported?(MinimalDslServer, :handle_call_tool, 3)
    end

    test "handler server has correct callbacks without old getter functions" do
      # Handler has the correct MCP protocol callbacks
      assert function_exported?(MinimalHandler, :handle_list_tools, 2)
      assert function_exported?(MinimalHandler, :handle_call_tool, 3)

      refute function_exported?(MinimalHandler, :get_tools, 0)
      refute function_exported?(MinimalHandler, :get_prompts, 0)
      refute function_exported?(MinimalHandler, :get_resources, 0)
    end

    test "handler routing works for multiple MCP methods" do
      # Start the handler server first
      {:ok, server} =
        HandlerServer.start_link(
          transport: :test,
          handler: MinimalHandler,
          handler_args: []
        )

      # Test prompts/list
      request = %{
        "jsonrpc" => "2.0",
        "method" => "prompts/list",
        "params" => %{},
        "id" => 2
      }

      conn = MessageProcessor.new(request, transport: :test)
      opts = %{server: server}

      # This should now work
      result = MessageProcessor.process(conn, opts)
      assert result.response["result"]["prompts"] == []

      # Test resources/list
      request2 = %{
        "jsonrpc" => "2.0",
        "method" => "resources/list",
        "params" => %{},
        "id" => 3
      }

      conn2 = MessageProcessor.new(request2, transport: :test)
      result2 = MessageProcessor.process(conn2, opts)
      assert result2.response["result"]["resources"] == []

      # Cleanup
      GenServer.stop(server)
    end
  end

  describe "proper handler routing demonstration" do
    test "show how handler should be called via GenServer" do
      # Start handler as a GenServer
      {:ok, pid} = GenServer.start_link(MinimalHandler, [])

      # This is how the message processor SHOULD call handlers. The bridge
      # replies with the canonical shape and no longer leaks handler state
      # into the reply (audit M13).
      result = GenServer.call(pid, {:list_tools, nil})

      assert {:ok, tools, _cursor} = result
      assert length(tools) == 1
      assert hd(tools).name == "test_tool"

      GenServer.stop(pid)
    end

    test "demonstrate handler initialization via GenServer" do
      {:ok, pid} = GenServer.start_link(MinimalHandler, [])

      # Handler should be initialized and callable
      result = GenServer.call(pid, {:initialize, %{}})

      assert {:ok, init_result} = result
      assert init_result.protocolVersion == "2025-03-26"
      assert init_result.serverInfo.name == "minimal-handler"

      GenServer.stop(pid)
    end
  end

  describe "routing behavior" do
    test "message processor routes handler modules through GenServer callbacks" do
      request = %{"jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}, "id" => 10}

      result =
        request
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: MinimalHandler})

      assert [%{"name" => "test_tool"}] = result.response["result"]["tools"]
    end
  end
end
