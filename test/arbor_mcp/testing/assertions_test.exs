defmodule Arbor.MCP.Testing.AssertionsTest do
  use ExUnit.Case, async: true

  import Arbor.MCP.Testing.Assertions
  alias Arbor.MCP.Content.Protocol
  alias Arbor.MCP.Testing.Builders

  describe "assert_success" do
    test "passes for {:ok, result} tuples" do
      result = assert_success({:ok, "test_result"})
      assert result == "test_result"
    end

    test "passes for maps without error field" do
      result = assert_success(%{"status" => "ok", "data" => "test"})
      assert result == %{"status" => "ok", "data" => "test"}
    end

    test "fails for {:error, reason} tuples" do
      assert_raise ExUnit.AssertionError, ~r/Expected success, got error/, fn ->
        assert_success({:error, "something went wrong"})
      end
    end

    test "fails for maps with error field" do
      assert_raise ExUnit.AssertionError, ~r/Expected success, got error/, fn ->
        assert_success(%{"error" => %{"code" => -1, "message" => "Failed"}})
      end
    end

    test "supports custom error message" do
      assert_raise ExUnit.AssertionError, ~r/Tool call should succeed/, fn ->
        assert_success({:error, "failed"}, "Tool call should succeed")
      end
    end
  end

  describe "assert_error" do
    test "passes for {:error, reason} tuples" do
      error = assert_error({:error, "test_error"})
      assert error == "test_error"
    end

    test "passes for maps with error field" do
      error_map = %{"code" => -1, "message" => "Test error"}
      error = assert_error(%{"error" => error_map})
      assert error == error_map
    end

    test "fails for {:ok, result} tuples" do
      assert_raise ExUnit.AssertionError, ~r/Expected error, got success/, fn ->
        assert_error({:ok, "success"})
      end
    end

    test "supports validator function" do
      assert_error({:error, %{code: -32601}}, fn error ->
        assert error.code == -32601
      end)
    end

    test "validator function is called with error" do
      validated_error =
        assert_error({:error, "test"}, fn error ->
          assert error == "test"
          error
        end)

      assert validated_error == "test"
    end
  end

  describe "assert_mcp_message" do
    test "validates request messages" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "list_tools",
        "id" => 1
      }

      result = assert_mcp_message(request, :request)
      assert result == request
    end

    test "validates request with specific id" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "list_tools",
        "id" => 123
      }

      assert_mcp_message(request, :request, id: 123)
    end

    test "validates request with specific method" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "call_tool",
        "id" => 1
      }

      assert_mcp_message(request, :request, method: "call_tool")
    end

    test "validates response messages" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"tools" => []}
      }

      result = assert_mcp_message(response, :response)
      assert result == response
    end

    test "validates error response messages" do
      error_response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{
          "code" => -32601,
          "message" => "Method not found"
        }
      }

      result = assert_mcp_message(error_response, :error)
      assert result == error_response
    end

    test "validates notification messages" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "info", "text" => "Hello"}
      }

      result = assert_mcp_message(notification, :notification)
      assert result == notification
    end

    test "fails for invalid request structure" do
      # Missing jsonrpc and id
      invalid_request = %{"method" => "test"}

      assert_raise ExUnit.AssertionError, ~r/MCP request must have jsonrpc field/, fn ->
        assert_mcp_message(invalid_request, :request)
      end
    end

    test "fails for response with both result and error" do
      invalid_response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{},
        "error" => %{"code" => -1, "message" => "Error"}
      }

      assert_raise ExUnit.AssertionError, ~r/cannot have both result and error/, fn ->
        assert_mcp_message(invalid_response, :response)
      end
    end
  end

  describe "assert_valid_content" do
    test "passes for valid text content" do
      content = Protocol.text("Hello world")
      result = assert_valid_content(content)
      assert result == content
    end

    test "passes for valid image content" do
      data = Base.encode64("fake image data")
      content = Protocol.image(data, "image/png")
      result = assert_valid_content(content)
      assert result == content
    end

    test "fails for invalid content" do
      invalid_content = %{type: :text, text: nil}

      assert_raise ExUnit.AssertionError, ~r/Content validation failed/, fn ->
        assert_valid_content(invalid_content)
      end
    end
  end

  describe "assert_valid_tool_result" do
    test "passes for valid tool result" do
      tool_result = %{
        "content" => [
          %{"type" => "text", "text" => "Hello"}
        ]
      }

      result = assert_valid_tool_result(tool_result)
      assert result == tool_result
    end

    test "fails for tool result without content field" do
      invalid_result = %{"status" => "ok"}

      assert_raise ExUnit.AssertionError, ~r/Tool result must have content field/, fn ->
        assert_valid_tool_result(invalid_result)
      end
    end

    test "fails for tool result with empty content list" do
      invalid_result = %{"content" => []}

      assert_raise ExUnit.AssertionError,
                   ~r/Tool result must have at least one content item/,
                   fn ->
                     assert_valid_tool_result(invalid_result)
                   end
    end

    test "fails for tool result with invalid content" do
      invalid_result = %{
        "content" => [
          %{"type" => "unknown", "data" => "test"}
        ]
      }

      assert_raise ExUnit.AssertionError, ~r/Invalid content in tool result/, fn ->
        assert_valid_tool_result(invalid_result)
      end
    end
  end

  describe "assert_content_type" do
    test "passes for matching content type" do
      content = Protocol.text("Hello")
      assert_content_type(content, :text)
    end

    test "passes for serialized content" do
      content = %{"type" => "text", "text" => "Hello"}
      assert_content_type(content, :text)
    end

    test "passes for tool result content" do
      tool_result = %{
        "content" => [
          %{"type" => "text", "text" => "Hello"}
        ]
      }

      assert_content_type(tool_result, :text)
    end

    test "fails for wrong content type" do
      content = Protocol.text("Hello")

      assert_raise ExUnit.AssertionError, ~r/Expected content type image, got text/, fn ->
        assert_content_type(content, :image)
      end
    end
  end

  describe "assert_content_contains" do
    test "passes when text content contains expected string" do
      content = Protocol.text("Hello world")
      assert_content_contains(content, "world")
    end

    test "passes for serialized text content" do
      content = %{"type" => "text", "text" => "Hello world"}
      assert_content_contains(content, "Hello")
    end

    test "passes for tool result with matching content" do
      tool_result = %{
        "content" => [
          %{"type" => "text", "text" => "Hello world"},
          %{"type" => "text", "text" => "Goodbye"}
        ]
      }

      assert_content_contains(tool_result, "world")
    end

    test "fails when content doesn't contain expected string" do
      content = Protocol.text("Hello world")

      assert_raise ExUnit.AssertionError, ~r/Expected text to contain 'missing'/, fn ->
        assert_content_contains(content, "missing")
      end
    end
  end

  describe "assert_content_matches" do
    test "passes when text content matches regex" do
      content = Protocol.text("Hello 123")
      assert_content_matches(content, ~r/\d+/)
    end

    test "passes for tool result with matching content" do
      tool_result = %{
        "content" => [
          %{"type" => "text", "text" => "Email: test@example.com"}
        ]
      }

      assert_content_matches(tool_result, ~r/\w+@\w+\.\w+/)
    end

    test "fails when content doesn't match regex" do
      content = Protocol.text("Hello world")

      assert_raise ExUnit.AssertionError, ~r/Expected text to match/, fn ->
        assert_content_matches(content, ~r/\d+/)
      end
    end
  end

  describe "assert_valid_tool" do
    test "passes for valid tool definition" do
      tool = Builders.tool("test_tool")
      result = assert_valid_tool(tool)
      assert result == tool
    end

    test "fails for tool without required fields" do
      invalid_tool = %{"name" => "test"}

      assert_raise ExUnit.AssertionError, ~r/Tool must have description field/, fn ->
        assert_valid_tool(invalid_tool)
      end
    end

    test "fails for tool with invalid schema" do
      invalid_tool = %{
        "name" => "test",
        "description" => "Test tool",
        "inputSchema" => %{"type" => "invalid"}
      }

      assert_raise ExUnit.AssertionError, ~r/Tool inputSchema type must be valid/, fn ->
        assert_valid_tool(invalid_tool)
      end
    end
  end

  describe "assert_valid_resource" do
    test "passes for valid resource definition" do
      resource = Builders.resource("file://test.txt", "Test Resource")
      result = assert_valid_resource(resource)
      assert result == resource
    end

    test "fails for resource without required fields" do
      invalid_resource = %{"uri" => "file://test.txt"}

      assert_raise ExUnit.AssertionError, ~r/Resource must have name field/, fn ->
        assert_valid_resource(invalid_resource)
      end
    end

    test "fails for resource with invalid URI" do
      invalid_resource = %{
        "uri" => "not a uri",
        "name" => "Test"
      }

      assert_raise ExUnit.AssertionError, ~r/Resource uri must be a valid URI/, fn ->
        assert_valid_resource(invalid_resource)
      end
    end
  end

  describe "assert_performance" do
    test "passes when operation completes within time limit" do
      # This exercises the helper's success path, not the host's scheduling latency.
      result =
        assert_performance(
          fn ->
            :completed
          end,
          max_time: 5_000
        )

      assert result == :completed
    end

    test "fails when operation takes too long" do
      assert_raise ExUnit.AssertionError, ~r/Operation took too long/, fn ->
        assert_performance(
          fn ->
            Process.sleep(100)
            :completed
          end,
          max_time: 50
        )
      end
    end

    test "supports custom error message" do
      assert_raise ExUnit.AssertionError, ~r/Tool call should be fast/, fn ->
        assert_performance(
          fn ->
            Process.sleep(100)
          end,
          max_time: 50,
          message: "Tool call should be fast"
        )
      end
    end
  end

  describe "assert_has_tool" do
    test "passes when tool is found in list" do
      tools = [
        %{"name" => "tool1"},
        %{"name" => "tool2"}
      ]

      found_tool = assert_has_tool(tools, "tool1")
      assert found_tool == %{"name" => "tool1"}
    end

    test "fails when tool is not found" do
      tools = [%{"name" => "tool1"}]

      assert_raise ExUnit.AssertionError, ~r/Expected to find tool 'missing'/, fn ->
        assert_has_tool(tools, "missing")
      end
    end
  end

  describe "assert_eventually" do
    test "passes when condition becomes true" do
      agent = Agent.start_link(fn -> false end)
      {:ok, pid} = agent

      # Set condition to true after short delay
      Task.start(fn ->
        Process.sleep(20)
        Agent.update(pid, fn _ -> true end)
      end)

      result =
        assert_eventually(
          fn ->
            Agent.get(pid, & &1)
          end,
          timeout: 100
        )

      assert result == :ok
      Agent.stop(pid)
    end

    test "fails when condition never becomes true" do
      assert_raise ExUnit.AssertionError, ~r/Condition never became true/, fn ->
        assert_eventually(fn -> false end, timeout: 50)
      end
    end

    test "supports custom error message" do
      assert_raise ExUnit.AssertionError, ~r/Server should start/, fn ->
        assert_eventually(fn -> false end,
          timeout: 50,
          message: "Server should start"
        )
      end
    end
  end
end
