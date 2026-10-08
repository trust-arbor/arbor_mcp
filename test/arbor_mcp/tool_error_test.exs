defmodule Arbor.MCP.ToolErrorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestErrorHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(params, state) do
      # Negotiate protocol version
      client_version = params["protocolVersion"]

      negotiated_version =
        case client_version do
          "2025-03-26" -> "2025-03-26"
          "2025-06-18" -> "2025-06-18"
          _ -> "2025-03-26"
        end

      result = %{
        protocolVersion: negotiated_version,
        serverInfo: %{
          name: "test-error-server",
          version: "1.0.0"
        },
        capabilities: %{
          tools: %{}
        }
      }

      {:ok, result, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "divide",
          description: "Divides two numbers",
          inputSchema: %{
            type: "object",
            properties: %{
              dividend: %{type: "number"},
              divisor: %{type: "number"}
            },
            required: ["dividend", "divisor"]
          }
        },
        %{
          name: "fetch_data",
          description: "Fetches data from external API",
          inputSchema: %{
            type: "object",
            properties: %{
              endpoint: %{type: "string"}
            },
            required: ["endpoint"]
          }
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("divide", %{"dividend" => dividend, "divisor" => 0}, state) do
      # Return execution error using isError flag
      result = %{
        content: [
          %{
            type: "text",
            text: "Division by zero error: Cannot divide #{dividend} by 0"
          }
        ],
        is_error: true
      }

      {:ok, result, state}
    end

    def handle_call_tool("divide", %{"dividend" => dividend, "divisor" => divisor}, state) do
      # Successful division
      result = dividend / divisor

      {:ok, %{content: [%{type: "text", text: "Result: #{result}"}]}, state}
    end

    def handle_call_tool("fetch_data", %{"endpoint" => "unavailable"}, state) do
      # Simulate API failure with isError
      result = %{
        content: [
          %{
            type: "text",
            text: "Failed to fetch data: API rate limit exceeded"
          }
        ],
        is_error: true
      }

      {:ok, result, state}
    end

    def handle_call_tool("fetch_data", %{"endpoint" => endpoint}, state) do
      # Simulate successful fetch
      {:ok, %{content: [%{type: "text", text: "Data from #{endpoint}: {\"status\": \"ok\"}"}]},
       state}
    end

    def handle_call_tool(name, _args, state) do
      # Protocol error - unknown tool
      {:error, Arbor.MCP.Error.protocol_error(-32602, "Unknown tool: #{name}"), state}
    end

    # Required callbacks
    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, "Resource not found", state}
    end

    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_get_prompt(_name, _arguments, state) do
      {:error, "Prompt not found", state}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:ok, %{completion: []}, state}
    end

    @impl true
    def handle_list_resource_templates(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_subscribe_resource(_uri, state), do: {:ok, %{}, state}

    @impl true
    def handle_unsubscribe_resource(_uri, state), do: {:ok, %{}, state}

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Create message not supported", state}
    end

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
  end

  describe "tool execution errors with isError flag" do
    setup do
      {:ok, server} =
        Server.start_link(
          handler: TestErrorHandler,
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      # Wait for initialization
      Process.sleep(100)

      {:ok, server: server, client: client}
    end

    test "successful tool call returns result without isError", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "divide", %{"dividend" => 10, "divisor" => 2}, format: :map)

      assert result == %{
               "content" => [%{"type" => "text", "text" => "Result: 5.0"}]
             }

      # Verify no isError field is present in any content item
      refute Enum.any?(result["content"], &Map.has_key?(&1, "isError"))
    end

    test "division by zero returns isError: true", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "divide", %{"dividend" => 10, "divisor" => 0}, format: :map)

      assert result == %{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Division by zero error: Cannot divide 10 by 0"
                 }
               ],
               "isError" => true
             }
    end

    test "API failure returns isError: true", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "fetch_data", %{"endpoint" => "unavailable"}, format: :map)

      assert result == %{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Failed to fetch data: API rate limit exceeded"
                 }
               ],
               "isError" => true
             }
    end

    test "successful API call returns result without isError", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "fetch_data", %{"endpoint" => "/api/status"}, format: :map)

      assert result == %{
               "content" => [
                 %{"type" => "text", "text" => "Data from /api/status: {\"status\": \"ok\"}"}
               ]
             }

      refute Map.has_key?(result, "isError")
    end

    test "unknown tool returns protocol error, not isError", %{client: client} do
      # This should return a protocol error, not a successful response with isError
      {:error, error} = Client.call_tool(client, "unknown_tool", %{})

      # The error should be a protocol-level error with struct access
      assert error.code == -32602
      assert error.message =~ "Unknown tool: unknown_tool"
    end
  end
end
