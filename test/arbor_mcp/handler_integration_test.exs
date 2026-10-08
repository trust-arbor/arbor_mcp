defmodule Arbor.MCP.HandlerIntegrationTest do
  @moduledoc """
  Integration tests to verify handler-based servers work correctly with the
  message processor after Phase 1 fixes.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  # Handler-based test server
  defmodule TestHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         tools: [
           %{name: "calculator", description: "Basic math operations", inputSchema: %{}}
         ],
         prompts: [
           %{name: "greeting", description: "A greeting prompt", arguments: []}
         ],
         resources: [
           %{uri: "file:///test.txt", name: "Test File", description: "A test resource"}
         ]
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{
           name: "test-handler-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{},
           prompts: %{},
           resources: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, state.tools, nil, state}
    end

    @impl true
    def handle_call_tool("calculator", %{"operation" => "add", "a" => a, "b" => b}, state) do
      result = a + b
      {:ok, %{content: [%{type: "text", text: "Result: #{result}"}]}, state}
    end

    def handle_call_tool(_name, _args, state) do
      {:error, "Unknown tool", state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, state.prompts, nil, state}
    end

    @impl true
    def handle_get_prompt("greeting", %{"name" => name}, state) do
      {:ok, %{messages: [%{role: "user", content: %{type: "text", text: "Hello, #{name}!"}}]},
       state}
    end

    def handle_get_prompt(_name, _args, state) do
      {:error, "Unknown prompt", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, state.resources, nil, state}
    end

    @impl true
    def handle_read_resource("file:///test.txt", state) do
      {:ok, [%{type: "text", text: "Test file content"}], state}
    end

    def handle_read_resource(_uri, state) do
      {:error, "Resource not found", state}
    end

    @impl true
    def handle_complete(ref, argument, state) do
      case ref do
        %{"type" => "ref/prompt", "name" => "greeting"} ->
          case argument do
            %{"name" => "name", "value" => value} ->
              suggestions =
                ["Alice", "Bob", "Charlie"]
                |> Enum.filter(&String.starts_with?(&1, value))

              result = %{
                completion: %{
                  values: suggestions,
                  total: length(suggestions),
                  hasMore: false
                }
              }

              {:ok, result, state}

            _ ->
              {:ok, %{completion: %{values: [], total: 0, hasMore: false}}, state}
          end

        _ ->
          {:ok, %{completion: %{values: [], total: 0, hasMore: false}}, state}
      end
    end
  end

  setup do
    # Start handler server with test transport
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestHandlerServer
      )

    # Start client connecting to the server
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "handler server integration" do
    test "client can communicate with handler server", %{client: client} do
      # Verify client is connected
      state = :sys.get_state(client)
      assert state.connection_status == :ready
    end

    test "list tools from handler server", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      assert is_struct(result, Arbor.MCP.Response)
      assert length(result.tools) == 1
      tool = hd(result.tools)
      assert tool["name"] == "calculator"
      assert tool["description"] == "Basic math operations"
    end

    test "call tool on handler server", %{client: client} do
      # Test tool call functionality works correctly

      # The handler returns the correct response format:
      # {:ok, %{content: [%{type: "text", text: "Result: 8"}]}, state}
      #
      # But the response gets lost somewhere in the protocol/transport layer
      # when using the test transport.

      {:ok, response} =
        Client.call_tool(client, "calculator", %{
          "operation" => "add",
          "a" => 5,
          "b" => 3
        })

      assert is_struct(response, Arbor.MCP.Response)
      assert response.content != []
      assert Arbor.MCP.Response.text_content(response) == "Result: 8"
    end

    # These tests are commented out because the Client API doesn't support these methods
    # with the test transport yet. They would need to be added in Phase 2.
    #
    # test "list prompts from handler server", %{client: client} do
    #   {:ok, result} = Client.list_prompts(client)
    #   assert is_list(result["prompts"])
    # end
    #
    # test "get prompt from handler server", %{client: client} do
    #   {:ok, result} = Client.get_prompt(client, "greeting", %{"name" => "Alice"})
    #   assert is_list(result["messages"])
    # end
    #
    # test "list resources from handler server", %{client: client} do
    #   {:ok, result} = Client.list_resources(client)
    #   assert is_list(result["resources"])
    # end
    #
    # test "read resource from handler server", %{client: client} do
    #   {:ok, result} = Client.read_resource(client, "file:///test.txt")
    #   assert is_list(result["contents"])
    # end

    test "handler server errors are properly handled", %{client: client} do
      result = Client.call_tool(client, "unknown_tool", %{})

      case result do
        {:error, %{"message" => message}} ->
          # Error with string keys
          assert message =~ "Tool call error" || message =~ "Unknown tool"

        {:error, %{message: message}} ->
          # Error with atom keys
          assert message =~ "Tool call error" || message =~ "Unknown tool"

        {:ok, response} ->
          # Some implementations return errors as Response structs with is_error = true
          assert response.is_error == true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end
end
