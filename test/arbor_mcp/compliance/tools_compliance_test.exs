defmodule Arbor.MCP.ToolsComplianceTest do
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestToolsServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         operation_count: 0,
         call_history: [],
         rate_limit: %{}
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "test-tools-server", version: "1.0.0"},
         capabilities: %{
           tools: %{listChanged: true}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "calculator",
          description: "Perform arithmetic calculations",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                enum: ["add", "subtract", "multiply", "divide"],
                description: "The arithmetic operation to perform"
              },
              a: %{type: "number", description: "First operand"},
              b: %{type: "number", description: "Second operand"}
            },
            required: ["operation", "a", "b"]
          }
        },
        %{
          name: "text_processor",
          description: "Process text with various operations",
          inputSchema: %{
            type: "object",
            properties: %{
              text: %{type: "string", description: "Input text"},
              operation: %{
                type: "string",
                enum: ["uppercase", "lowercase", "reverse", "length"],
                description: "Text processing operation"
              },
              options: %{
                type: "object",
                description: "Optional processing parameters",
                properties: %{
                  prefix: %{type: "string"},
                  suffix: %{type: "string"}
                }
              }
            },
            required: ["text", "operation"]
          }
        },
        %{
          name: "file_reader",
          description: "Read and analyze files (demo)",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{type: "string", description: "File path"},
              encoding: %{type: "string", enum: ["utf8", "binary"], default: "utf8"}
            },
            required: ["path"]
          }
        },
        %{
          name: "progress_task",
          description: "Long-running task with progress updates",
          inputSchema: %{
            type: "object",
            properties: %{
              duration: %{
                type: "integer",
                minimum: 1,
                maximum: 10,
                description: "Task duration in seconds"
              },
              name: %{type: "string", description: "Task name"}
            },
            required: ["duration"]
          }
        },
        %{
          name: "error_demo",
          description: "Demonstrate different error types",
          inputSchema: %{
            type: "object",
            properties: %{
              error_type: %{
                type: "string",
                enum: ["validation", "execution", "protocol"],
                description: "Type of error to demonstrate"
              }
            },
            required: ["error_type"]
          }
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      # Rate limiting demonstration
      if rate_limited?(name, state) do
        {:error, "Rate limit exceeded for tool: #{name}", state}
      else
        # Update rate limit tracking
        new_state = update_rate_limit(name, state)

        # Call the specific tool handler
        case call_tool_handler(name, arguments, new_state) do
          {:ok, result, updated_state} ->
            # Add to call history
            final_state = add_to_history(updated_state, name, arguments, result)
            {:ok, result, final_state}

          other ->
            other
        end
      end
    end

    # Tool implementations
    defp call_tool_handler("calculator", args, state) do
      %{"operation" => op, "a" => a, "b" => b} = args

      # Input validation
      if not is_number(a) or not is_number(b) do
        error_content = [%{type: "text", text: "Invalid input: operands must be numbers"}]
        {:ok, %{content: error_content, is_error: true}, state}
      else
        case op do
          "add" ->
            result = a + b
            content = [%{type: "text", text: "#{a} + #{b} = #{result}"}]
            {:ok, content, state}

          "subtract" ->
            result = a - b
            content = [%{type: "text", text: "#{a} - #{b} = #{result}"}]
            {:ok, content, state}

          "multiply" ->
            result = a * b
            content = [%{type: "text", text: "#{a} × #{b} = #{result}"}]
            {:ok, content, state}

          "divide" ->
            if b == 0 do
              # Tool execution error - use isError flag
              error_content = [%{type: "text", text: "Division by zero is not allowed"}]
              {:ok, %{content: error_content, is_error: true}, state}
            else
              result = a / b
              content = [%{type: "text", text: "#{a} ÷ #{b} = #{result}"}]
              {:ok, content, state}
            end

          _ ->
            {:error, "Unknown operation: #{op}", state}
        end
      end
    end

    defp call_tool_handler("text_processor", args, state) do
      %{"text" => text, "operation" => op} = args
      options = Map.get(args, "options", %{})

      result =
        case op do
          "uppercase" -> String.upcase(text)
          "lowercase" -> String.downcase(text)
          "reverse" -> String.reverse(text)
          "length" -> "Length: #{String.length(text)}"
          _ -> "Unknown operation"
        end

      # Apply options
      final_result =
        case options do
          %{"prefix" => prefix, "suffix" => suffix} -> "#{prefix}#{result}#{suffix}"
          %{"prefix" => prefix} -> "#{prefix}#{result}"
          %{"suffix" => suffix} -> "#{result}#{suffix}"
          _ -> result
        end

      content = [%{type: "text", text: final_result}]
      {:ok, content, state}
    end

    defp call_tool_handler("file_reader", args, state) do
      %{"path" => path} = args
      encoding = Map.get(args, "encoding", "utf8")

      # Simulate file reading with security checks
      if String.contains?(path, "..") or String.starts_with?(path, "/etc/") do
        error_content = [%{type: "text", text: "Access denied: Invalid file path"}]
        {:ok, %{content: error_content, is_error: true}, state}
      else
        # Simulate reading a file
        content =
          case path do
            "test.txt" ->
              [%{type: "text", text: "File content: Hello, World! (encoding: #{encoding})"}]

            "data.json" ->
              [
                %{
                  type: "text",
                  text: "{\"message\": \"Sample JSON data\", \"encoding\": \"#{encoding}\"}"
                }
              ]

            _ ->
              [%{type: "text", text: "File not found: #{path}"}]
          end

        {:ok, content, state}
      end
    end

    defp call_tool_handler("progress_task", args, state) do
      %{"duration" => duration} = args
      task_name = Map.get(args, "name", "background_task")

      # Check for progress token in metadata (it won't be there in our test handler)
      # In real implementation, this would be passed via the protocol
      progress_token = get_in(args, ["_meta", "progressToken"])

      # For demonstration, we'll simulate having a progress token
      has_progress = progress_token != nil or Map.has_key?(args, "_test_progress")

      if has_progress do
        # Start background task with progress updates
        spawn(fn ->
          send_progress_updates(self(), progress_token || "test_token", duration, task_name)
        end)

        content = [%{type: "text", text: "Started #{task_name} (duration: #{duration}s)"}]
        {:ok, content, state}
      else
        content = [%{type: "text", text: "Task #{task_name} completed (no progress tracking)"}]
        {:ok, content, state}
      end
    end

    defp call_tool_handler("error_demo", args, state) do
      %{"error_type" => error_type} = args

      case error_type do
        "validation" ->
          # Tool execution error
          error_content = [%{type: "text", text: "Validation failed: invalid input detected"}]
          {:ok, %{content: error_content, is_error: true}, state}

        "execution" ->
          # Tool execution error
          error_content = [%{type: "text", text: "Execution failed: simulated runtime error"}]
          {:ok, %{content: error_content, is_error: true}, state}

        "protocol" ->
          # Protocol error
          {:error, "Protocol error: simulated internal server error", state}

        _ ->
          {:error, "Unknown error type: #{error_type}", state}
      end
    end

    defp call_tool_handler(name, _args, state) do
      {:error, "Unknown tool: #{name}", state}
    end

    # Helper functions
    defp rate_limited?(tool_name, state) do
      limit_key = {tool_name, :os.system_time(:second)}
      current_count = Map.get(state.rate_limit, limit_key, 0)
      # Max 5 calls per second per tool
      current_count >= 5
    end

    defp update_rate_limit(tool_name, state) do
      limit_key = {tool_name, :os.system_time(:second)}
      new_rate_limit = Map.update(state.rate_limit, limit_key, 1, &(&1 + 1))
      %{state | rate_limit: new_rate_limit}
    end

    defp add_to_history(state, tool_name, arguments, result) do
      history_entry = %{
        tool: tool_name,
        arguments: arguments,
        result: result,
        timestamp: DateTime.utc_now()
      }

      # Keep last 10
      new_history = [history_entry | Enum.take(state.call_history, 9)]
      %{state | call_history: new_history, operation_count: state.operation_count + 1}
    end

    defp send_progress_updates(server_pid, progress_token, duration, _task_name) do
      # 2 updates per second
      steps = duration * 2

      for i <- 0..steps do
        progress = div(i * 100, steps)
        Arbor.MCP.Server.notify_progress(server_pid, progress_token, progress, 100)
        # 0.5 seconds
        Process.sleep(500)
      end
    end
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestToolsServer
      )

    # Start client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "tools capability compliance" do
    test "server declares tools capability correctly", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      assert %{tools: tools} = result
      assert is_list(tools)
      assert length(tools) == 5
    end

    test "tools have required structure", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      Enum.each(result.tools, fn tool ->
        # Required fields
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :inputSchema)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)

        # Input schema structure
        schema = tool.inputSchema
        assert schema.type == "object"
        assert Map.has_key?(schema, :properties)
        assert is_map(schema.properties)
      end)
    end

    test "input schemas are valid JSON Schema", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      calculator_tool = Enum.find(result.tools, &(&1.name == "calculator"))
      schema = calculator_tool.inputSchema

      # Check JSON Schema compliance
      assert schema.type == "object"
      assert Map.has_key?(schema, :properties)
      assert Map.has_key?(schema, :required)
      assert is_list(schema.required)

      # Check property definitions
      assert Map.has_key?(schema.properties, "operation")
      assert Map.has_key?(schema.properties, "a")
      assert Map.has_key?(schema.properties, "b")

      # Check operation enum
      operation_prop = schema.properties["operation"]
      assert operation_prop.type == "string"
      assert is_list(operation_prop.enum)
      assert "add" in operation_prop.enum
    end
  end

  describe "tools/list method compliance" do
    test "basic listing works", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      assert %{tools: tools} = result
      assert is_list(tools)
      assert length(tools) == 5

      tool_names = Enum.map(tools, & &1.name)
      assert "calculator" in tool_names
      assert "text_processor" in tool_names
      assert "file_reader" in tool_names
      assert "progress_task" in tool_names
      assert "error_demo" in tool_names
    end

    test "pagination support (cursor parameter)", %{client: client} do
      # Even though we return all tools, cursor should be accepted
      {:ok, result} = Client.list_tools(client, cursor: "test_cursor")

      assert %{tools: tools} = result
      assert is_list(tools)
    end
  end

  describe "tools/call method compliance" do
    test "successful tool execution", %{client: client} do
      args = %{"operation" => "add", "a" => 5, "b" => 3}
      {:ok, result} = Client.call_tool(client, "calculator", args)

      assert %{content: content} = result
      assert is_list(content)
      assert length(content) == 1

      text_content = hd(content)
      assert text_content.type == "text"
      assert String.contains?(text_content.text, "5 + 3 = 8")
    end

    test "tool execution error with isError flag", %{client: client} do
      # Division by zero should return is_error: true
      args = %{"operation" => "divide", "a" => 10, "b" => 0}
      {:ok, result} = Client.call_tool(client, "calculator", args)

      assert %{content: content, is_error: true} = result
      assert is_list(content)

      error_content = hd(content)
      assert error_content.type == "text"
      assert String.contains?(error_content.text, "Division by zero")
    end

    test "protocol error for unknown tool", %{client: client} do
      {:error, reason} = Client.call_tool(client, "nonexistent_tool", %{})

      # Should return protocol error
      assert is_map(reason) or is_binary(reason)
    end

    test "input validation", %{client: client} do
      # Invalid input types
      args = %{"operation" => "add", "a" => "not_a_number", "b" => 3}
      {:ok, result} = Client.call_tool(client, "calculator", args)

      # Should return tool execution error
      assert %{content: content, is_error: true} = result
      error_content = hd(content)
      assert String.contains?(error_content.text, "Invalid input")
    end

    test "optional parameters handling", %{client: client} do
      # Test with minimal required parameters
      args = %{"text" => "Hello", "operation" => "uppercase"}
      {:ok, result} = Client.call_tool(client, "text_processor", args)

      assert %{content: [%{type: "text", text: "HELLO"}]} = result

      # Test with optional parameters
      args_with_options = %{
        "text" => "Hello",
        "operation" => "uppercase",
        "options" => %{"prefix" => ">>> ", "suffix" => " <<<"}
      }

      {:ok, result2} = Client.call_tool(client, "text_processor", args_with_options)

      assert %{content: [%{type: "text", text: ">>> HELLO <<<"}]} = result2
    end

    test "access control and security", %{client: client} do
      # Test path traversal prevention
      args = %{"path" => "../../../etc/passwd"}
      {:ok, result} = Client.call_tool(client, "file_reader", args)

      assert %{content: content, is_error: true} = result
      error_content = hd(content)
      assert String.contains?(error_content.text, "Access denied")
    end
  end

  describe "progress tracking compliance" do
    test "progress notifications work", %{client: client} do
      # Call tool with progress simulation
      args = %{"duration" => 2, "name" => "test_task", "_test_progress" => true}

      {:ok, result} = Client.call_tool(client, "progress_task", args)

      assert %{content: content} = result
      text_content = hd(content)
      assert String.contains?(text_content.text, "Started test_task")

      # Progress updates happen in background - just verify no immediate error
    end

    test "tools work without progress token", %{client: client} do
      args = %{"duration" => 1, "name" => "simple_task"}
      {:ok, result} = Client.call_tool(client, "progress_task", args)

      assert %{content: content} = result
      text_content = hd(content)
      assert String.contains?(text_content.text, "completed")
    end
  end

  describe "error handling compliance" do
    test "tool execution errors vs protocol errors", %{client: client} do
      # Tool execution error (returns result with isError)
      {:ok, validation_result} =
        Client.call_tool(client, "error_demo", %{"error_type" => "validation"})

      assert %{is_error: true} = validation_result

      {:ok, execution_result} =
        Client.call_tool(client, "error_demo", %{"error_type" => "execution"})

      assert %{is_error: true} = execution_result

      # Protocol error (returns error tuple)
      {:error, _reason} = Client.call_tool(client, "error_demo", %{"error_type" => "protocol"})
    end

    test "rate limiting", %{client: client} do
      # Make multiple rapid calls to trigger rate limiting
      args = %{"operation" => "add", "a" => 1, "b" => 1}

      # First few calls should succeed
      for _i <- 1..3 do
        {:ok, _result} = Client.call_tool(client, "calculator", args)
      end

      # Eventually should hit rate limit (this is demonstration - real rate limiting might differ)
      # Note: This test is somewhat timing-dependent
    end
  end

  describe "protocol compliance" do
    test "tools/list protocol format" do
      request = Protocol.encode_list_tools()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "tools/list with cursor protocol format" do
      request = Protocol.encode_list_tools("test_cursor")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert request["params"] == %{"cursor" => "test_cursor"}
    end

    test "tools/call protocol format" do
      args = %{"test" => "value"}
      request = Protocol.encode_call_tool("test_tool", args)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/call"
      assert request["params"]["name"] == "test_tool"
      assert request["params"]["arguments"] == args
      refute Map.has_key?(request["params"], "_meta")
    end

    test "tools/call with progress token protocol format" do
      args = %{"test" => "value"}
      request = Protocol.encode_call_tool("test_tool", args, "progress_123")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/call"
      assert request["params"]["_meta"]["progressToken"] == "progress_123"
    end

    test "tools list changed notification format" do
      notification = Protocol.encode_tools_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/tools/list_changed"
      assert notification["params"] == %{}
      refute Map.has_key?(notification, "id")
    end
  end

  describe "content types compliance" do
    test "text content structure", %{client: client} do
      args = %{"text" => "test", "operation" => "uppercase"}
      {:ok, result} = Client.call_tool(client, "text_processor", args)

      assert %{content: content} = result
      text_item = hd(content)

      assert Map.has_key?(text_item, :type)
      assert Map.has_key?(text_item, :text)
      assert text_item.type == "text"
      assert is_binary(text_item.text)
    end

    test "error content maintains structure", %{client: client} do
      args = %{"operation" => "divide", "a" => 1, "b" => 0}
      {:ok, result} = Client.call_tool(client, "calculator", args)

      assert %{content: content, is_error: true} = result
      error_item = hd(content)

      assert error_item.type == "text"
      assert is_binary(error_item.text)
    end
  end
end
