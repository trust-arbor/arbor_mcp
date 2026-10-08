defmodule Arbor.MCP.ToolsTest do
  use ExUnit.Case, async: true
  # Removed unused import

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestToolsHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         call_count: 0,
         last_progress_token: nil
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "test-tools-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      tools = [
        %{
          name: "calculate",
          description: "Perform mathematical calculations",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                enum: ["add", "subtract", "multiply", "divide"]
              },
              a: %{type: "number"},
              b: %{type: "number"}
            },
            required: ["operation", "a", "b"]
          }
        },
        %{
          name: "string_tools",
          description: "String manipulation utilities",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                enum: ["uppercase", "lowercase", "reverse", "length"]
              },
              text: %{type: "string"}
            },
            required: ["operation", "text"]
          }
        },
        %{
          name: "data_fetch",
          description: "Fetch data from various sources",
          inputSchema: %{
            type: "object",
            properties: %{
              source: %{type: "string"},
              query: %{type: "string"},
              format: %{
                type: "string",
                enum: ["json", "csv", "xml"],
                default: "json"
              }
            },
            required: ["source", "query"]
          }
        },
        %{
          name: "image_process",
          description: "Process images",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{type: "string"},
              imageData: %{type: "string", format: "base64"}
            },
            required: ["operation", "imageData"]
          }
        },
        %{
          name: "async_task",
          description: "Long-running task with progress",
          inputSchema: %{
            type: "object",
            properties: %{
              duration: %{type: "integer", minimum: 1, maximum: 10},
              steps: %{type: "integer", minimum: 1, maximum: 5}
            },
            required: ["duration", "steps"]
          }
        }
      ]

      # Simple pagination
      case cursor do
        nil ->
          {:ok, Enum.take(tools, 3), "page2", state}

        "page2" ->
          {:ok, Enum.drop(tools, 3), nil, state}

        _ ->
          {:error, "Invalid cursor", state}
      end
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      # Extract progress token if provided
      progress_token = get_in(arguments, ["_meta", "progressToken"])
      new_state = %{state | call_count: state.call_count + 1, last_progress_token: progress_token}

      case name do
        "calculate" ->
          handle_calculate(arguments, new_state)

        "string_tools" ->
          handle_string_tools(arguments, new_state)

        "data_fetch" ->
          handle_data_fetch(arguments, new_state)

        "image_process" ->
          handle_image_process(arguments, new_state)

        "async_task" ->
          handle_async_task(arguments, progress_token, new_state)

        _ ->
          {:error, "Unknown tool: #{name}", new_state}
      end
    end

    defp handle_calculate(%{"operation" => op, "a" => a, "b" => b}, state) do
      case op do
        "add" ->
          {:ok, [%{type: "text", text: "Result: #{a + b}"}], state}

        "subtract" ->
          {:ok, [%{type: "text", text: "Result: #{a - b}"}], state}

        "multiply" ->
          {:ok, [%{type: "text", text: "Result: #{a * b}"}], state}

        "divide" when b != 0 ->
          {:ok, [%{type: "text", text: "Result: #{a / b}"}], state}

        "divide" ->
          # Return error result with isError flag
          {:ok,
           %{
             content: [
               %{
                 type: "text",
                 text: "Error: Division by zero"
               }
             ],
             is_error: true
           }, state}
      end
    end

    defp handle_string_tools(%{"operation" => op, "text" => text}, state) do
      result =
        case op do
          "uppercase" -> String.upcase(text)
          "lowercase" -> String.downcase(text)
          "reverse" -> String.reverse(text)
          "length" -> "Length: #{String.length(text)}"
        end

      {:ok,
       [
         %{
           type: "text",
           text: result
         }
       ], state}
    end

    defp handle_data_fetch(%{"source" => source, "query" => query} = args, state) do
      format = Map.get(args, "format", "json")

      # Simulate data fetching
      data = %{
        source: source,
        query: query,
        results: [
          %{id: 1, name: "Item 1", value: 100},
          %{id: 2, name: "Item 2", value: 200}
        ]
      }

      formatted =
        case format do
          "json" -> Jason.encode!(data, pretty: true)
          "csv" -> "id,name,value\n1,Item 1,100\n2,Item 2,200"
          "xml" -> "<data><item><id>1</id><name>Item 1</name></item></data>"
        end

      {:ok,
       [
         %{
           type: "text",
           text: formatted
         }
       ], state}
    end

    defp handle_image_process(%{"operation" => _operation, "imageData" => data}, state) do
      # Simulate image processing - return a modified base64 string
      processed = "processed_" <> String.slice(data, 0..10) <> "..."

      {:ok,
       [
         %{
           type: "image",
           data: processed,
           mime_type: "image/png"
         }
       ], state}
    end

    defp handle_async_task(%{"duration" => duration, "steps" => steps}, progress_token, state) do
      # Simulate async work with progress updates
      if progress_token do
        # Send progress updates
        Task.start(fn ->
          for i <- 1..steps do
            Process.sleep(div(duration * 1000, steps))
            progress = div(i * 100, steps)
            Arbor.MCP.Server.notify_progress(self(), progress_token, progress, 100)
          end
        end)
      end

      {:ok,
       [
         %{
           type: "text",
           text: "Task started with #{steps} steps over #{duration} seconds"
         }
       ], state}
    end
  end

  setup do
    # Start test transport server with tools handler
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestToolsHandler
      )

    # Start test transport client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    on_exit(fn ->
      Arbor.MCP.TestHelpers.safe_stop_process(client)
      Arbor.MCP.TestHelpers.safe_stop_process(server)
    end)

    %{server: server, client: client}
  end

  describe "tools functionality" do
    test "client can list tools with pagination", %{client: client} do
      # First page
      {:ok, %{tools: page1, nextCursor: cursor}} = Client.list_tools(client)
      assert length(page1) == 3
      assert cursor == "page2"

      # Verify tool structure
      calculate_tool = Enum.find(page1, &(&1["name"] == "calculate"))
      assert calculate_tool["description"] =~ "mathematical"
      assert calculate_tool["inputSchema"]["type"] == "object"
      assert calculate_tool["inputSchema"]["required"] == ["operation", "a", "b"]

      # Second page
      {:ok, result2} = Client.list_tools(client, cursor: cursor)
      page2 = result2.tools
      assert is_nil(result2[:nextCursor])
      assert length(page2) == 2
    end

    test "client can call calculation tool", %{client: client} do
      # Addition
      {:ok, result} =
        Client.call_tool(client, "calculate", %{
          "operation" => "add",
          "a" => 10,
          "b" => 5
        })

      assert result.content
      assert hd(result.content).type == "text"
      assert hd(result.content).text == "Result: 15"

      # Multiplication
      {:ok, result2} =
        Client.call_tool(client, "calculate", %{
          "operation" => "multiply",
          "a" => 7,
          "b" => 8
        })

      assert hd(result2.content).text == "Result: 56"
    end

    test "tool returns error with isError flag for division by zero", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "calculate", %{
          "operation" => "divide",
          "a" => 10,
          "b" => 0
        })

      # Should still return success but with is_error flag
      assert result.content
      assert result.is_error == true
      assert hd(result.content).text =~ "Division by zero"
    end

    test "client can call string manipulation tool", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "string_tools", %{
          "operation" => "uppercase",
          "text" => "hello world"
        })

      assert hd(result.content).text == "HELLO WORLD"

      {:ok, result2} =
        Client.call_tool(client, "string_tools", %{
          "operation" => "reverse",
          "text" => "MCP"
        })

      assert hd(result2.content).text == "PCM"
    end

    test "tool can return different content types", %{client: client} do
      # Text content (already tested above)

      # Image content
      {:ok, result} =
        Client.call_tool(client, "image_process", %{
          "operation" => "resize",
          "imageData" => "base64encodeddata"
        })

      image_content = hd(result.content)
      assert image_content.type == "image"
      assert image_content.data =~ "processed_"
      # Note: mimeType is not preserved in the normalized content structure
    end

    test "tool handles optional parameters with defaults", %{client: client} do
      # Call without format parameter (should use default "json")
      {:ok, result} =
        Client.call_tool(client, "data_fetch", %{
          "source" => "database",
          "query" => "SELECT * FROM users"
        })

      # Should return JSON formatted data
      assert hd(result.content).text =~ "\"source\""
      assert hd(result.content).text =~ "\"results\""

      # Call with explicit format
      {:ok, result2} =
        Client.call_tool(client, "data_fetch", %{
          "source" => "api",
          "query" => "users",
          "format" => "csv"
        })

      assert hd(result2.content).text =~ "id,name,value"
    end

    test "tool call with progress token", %{client: client} do
      # Call tool with progress token
      progress_token = "test-progress-123"

      {:ok, result} =
        Client.call_tool(
          client,
          "async_task",
          %{
            "duration" => 1,
            "steps" => 2
          },
          progress_token: progress_token
        )

      assert hd(result.content).text =~ "Task started"

      # Note: In a real test, we'd verify progress notifications were sent
      # but that requires more complex setup with notification handlers
    end

    test "unknown tool returns error", %{client: client} do
      {:error, error} = Client.call_tool(client, "unknown_tool", %{})
      assert error.message =~ "Unknown tool"
    end
  end
end
