defmodule Arbor.MCP.Client.ErrorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Error

  describe "format/3 - connection errors" do
    test "formats connection_failed with timeout" do
      result = Error.format(:connection_failed, :timeout, %{server: "localhost:8080"})

      assert result.type == :connection_failed
      assert result.category == :connection
      assert result.severity == :medium
      assert result.message == "Connection attempt timed out"
      assert String.contains?(result.details, "timeout period")
      assert "Verify the server is running and responding" in result.suggestions
      assert result.context == %{server: "localhost:8080"}
      assert result.original_error == :timeout
    end

    test "formats connection_failed with connection_refused" do
      result = Error.format(:connection_failed, :connection_refused, %{})

      assert result.type == :connection_failed
      assert result.category == :connection
      assert result.severity == :high
      assert result.message == "Connection refused by server"
      assert String.contains?(result.details, "actively refused")
      assert "Verify the server is running on the specified port" in result.suggestions
    end

    test "formats connection_failed with network_unreachable" do
      result = Error.format(:connection_failed, :network_unreachable, %{})

      assert result.type == :connection_failed
      assert result.category == :connection
      assert result.severity == :high
      assert result.message == "Network unreachable"
      assert String.contains?(result.details, "network route")
    end

    test "formats connection_failed with unknown reason" do
      result = Error.format(:connection_failed, :unknown_error, %{})

      assert result.type == :connection_failed
      assert result.category == :connection
      assert result.severity == :medium
      assert result.message == "Connection failed: :unknown_error"
      assert result.details == nil
    end

    test "formats transport_connect_failed" do
      result = Error.format(:transport_connect_failed, :connection_refused, %{transport: "http"})

      assert result.type == :transport_connect_failed
      assert result.category == :connection
      assert result.severity == :high
      assert result.message == "Failed to connect to MCP server"
      assert result.details == ":connection_refused"
      assert "Check if the MCP server is running" in result.suggestions
      assert result.context.transport == "http"
    end

    test "formats transport_connect_failed with transport exception" do
      exception = {:transport_exception, {:error, "Socket closed"}}
      result = Error.format(:transport_connect_failed, exception, %{})

      assert result.details == "Transport exception (error): \"Socket closed\""
    end

    test "formats all_transports_failed" do
      result = Error.format(:all_transports_failed, nil, %{transports: ["http", "stdio"]})

      assert result.type == :all_transports_failed
      assert result.category == :connection
      assert result.severity == :critical
      assert result.message == "All configured transports failed to connect"
      assert String.contains?(result.details, "None of the configured")
      assert "Check if the MCP server is running" in result.suggestions
      assert result.context.transports == ["http", "stdio"]
    end
  end

  describe "format/3 - tool errors" do
    test "formats tool_call_failed with timeout" do
      result =
        Error.format(:tool_call_failed, :timeout, %{tool: "calculator", args: %{a: 1, b: 2}})

      assert result.type == :tool_call_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Tool call to 'calculator' failed"
      assert result.details == "Tool execution timed out"
      assert "Increase timeout for tool 'calculator'" in result.suggestions
      assert result.context.tool == "calculator"
    end

    test "formats tool_call_failed with not_connected" do
      result =
        Error.format(:tool_call_failed, {:not_connected, :disconnected}, %{tool: "test_tool"})

      assert result.severity == :high
      assert result.details == "Client not connected (status: disconnected)"
      assert "Check connection status" in result.suggestions
    end

    test "formats tool_call_failed with MCP error message" do
      error = %{"error" => %{"message" => "Tool not found"}}
      result = Error.format(:tool_call_failed, error, %{tool: "missing_tool"})

      assert result.details == "Tool not found"
      assert "Verify tool 'missing_tool' exists on the server" in result.suggestions
    end

    test "formats tool_call_failed with simple message" do
      error = %{"message" => "Invalid arguments"}
      result = Error.format(:tool_call_failed, error, %{tool: "test"})

      assert result.details == "Invalid arguments"
    end

    test "formats tool_call_failed with unknown tool name" do
      result = Error.format(:tool_call_failed, :some_error, %{})

      assert result.message == "Tool call to 'unknown' failed"
    end

    test "formats tool_list_failed" do
      result = Error.format(:tool_list_failed, "Server error", %{server: "test"})

      assert result.type == :tool_list_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Failed to list available tools"
      assert result.details == "Server error"
      assert "Check if the server supports tools" in result.suggestions
    end
  end

  describe "format/3 - resource errors" do
    test "formats resource_read_failed with not_found" do
      result = Error.format(:resource_read_failed, :not_found, %{uri: "file://missing.txt"})

      assert result.type == :resource_read_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Failed to read resource 'file://missing.txt'"
      assert result.details == "Resource 'file://missing.txt' not found"
      assert "Verify the resource URI 'file://missing.txt' is correct" in result.suggestions
    end

    test "formats resource_read_failed with access_denied" do
      result = Error.format(:resource_read_failed, :access_denied, %{uri: "private://data"})

      assert result.details == "Access denied to resource 'private://data'"
      assert "Check permissions for resource 'private://data'" in result.suggestions
    end

    test "formats resource_read_failed with timeout" do
      result = Error.format(:resource_read_failed, :timeout, %{uri: "slow://resource"})

      assert result.details == "Timeout reading resource 'slow://resource'"
    end

    test "formats resource_read_failed with unknown URI" do
      result = Error.format(:resource_read_failed, :some_error, %{})

      assert result.message == "Failed to read resource 'unknown'"
    end

    test "formats resource_list_failed" do
      result = Error.format(:resource_list_failed, :server_error, %{})

      assert result.type == :resource_list_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Failed to list available resources"
      assert "Check if the server supports resources" in result.suggestions
    end
  end

  describe "format/3 - prompt errors" do
    test "formats prompt_get_failed with MCP error" do
      error = %{"error" => %{"message" => "Prompt not found"}}
      result = Error.format(:prompt_get_failed, error, %{prompt: "greeting"})

      assert result.type == :prompt_get_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Failed to get prompt 'greeting'"
      assert result.details == "Prompt not found"
      assert "Verify prompt 'greeting' exists on the server" in result.suggestions
    end

    test "formats prompt_get_failed with unknown prompt" do
      result = Error.format(:prompt_get_failed, :not_found, %{})

      assert result.message == "Failed to get prompt 'unknown'"
    end

    test "formats prompt_list_failed" do
      result = Error.format(:prompt_list_failed, "No prompts", %{})

      assert result.type == :prompt_list_failed
      assert result.category == :resource
      assert result.severity == :medium
      assert result.message == "Failed to list available prompts"
      assert "Check if the server supports prompts" in result.suggestions
    end
  end

  describe "format/3 - protocol errors" do
    test "formats unexpected_response" do
      context = %{"received" => "invalid_data"}
      result = Error.format(:unexpected_response, "valid JSON", context)

      assert result.type == :unexpected_response
      assert result.category == :protocol
      assert result.severity == :medium
      assert result.message == "Received unexpected response format"
      assert String.contains?(result.details, "Expected: valid JSON")
      assert String.contains?(result.details, "Got: %{\"received\" => \"invalid_data\"}")
      assert "Check server protocol version compatibility" in result.suggestions
    end
  end

  describe "format/3 - timeout errors" do
    test "formats timeout error" do
      result = Error.format(:timeout, nil, %{operation: "tool_call", timeout: 5000})

      assert result.type == :timeout
      assert result.category == :timeout
      assert result.severity == :medium
      assert result.message == "Operation timed out"
      assert String.contains?(result.details, "timeout period")
      assert "Increase the timeout value for this operation" in result.suggestions
      assert result.context.operation == "tool_call"
      assert result.original_error == :timeout
    end
  end

  describe "format/3 - generic fallback" do
    test "formats unknown error types" do
      result = Error.format(:custom_error, "Something went wrong", %{custom: "context"})

      assert result.type == :custom_error
      assert result.category == :unknown
      assert result.severity == :medium
      assert result.message == "Operation failed: custom_error"
      assert result.details == "Something went wrong"
      assert "Check the server logs for more information" in result.suggestions
      assert result.context.custom == "context"
      assert result.original_error == "Something went wrong"
    end

    test "formats with atom reason" do
      result = Error.format(:test_error, :atom_reason, %{})

      assert result.details == "atom_reason"
    end

    test "formats with complex reason" do
      complex_reason = %{nested: %{data: "value"}}
      result = Error.format(:test_error, complex_reason, %{})

      assert String.contains?(result.details, "nested")
    end
  end

  describe "summarize/1" do
    test "summarizes error with details" do
      error = %{
        message: "Connection failed",
        details: "Server not responding"
      }

      result = Error.summarize(error)
      assert result == "Connection failed\n\nDetails: Server not responding"
    end

    test "summarizes error without details" do
      error = %{
        message: "Tool call failed",
        details: nil
      }

      result = Error.summarize(error)
      assert result == "Tool call failed"
    end
  end

  describe "get_suggestions/1" do
    test "extracts suggestions from formatted error" do
      error = %{
        suggestions: ["First suggestion", "Second suggestion", "Third suggestion"]
      }

      result = Error.get_suggestions(error)
      assert result == ["First suggestion", "Second suggestion", "Third suggestion"]
    end
  end

  describe "format_suggestions/1" do
    test "formats empty suggestions list" do
      result = Error.format_suggestions([])
      assert result == "No specific suggestions available."
    end

    test "formats single suggestion" do
      result = Error.format_suggestions(["Check server status"])
      assert result == "1. Check server status"
    end

    test "formats multiple suggestions" do
      suggestions = [
        "Check server status",
        "Verify connection parameters",
        "Review server logs"
      ]

      result = Error.format_suggestions(suggestions)
      expected = "1. Check server status\n2. Verify connection parameters\n3. Review server logs"
      assert result == expected
    end

    test "formats suggestions with numbering" do
      suggestions = ["First", "Second", "Third"]
      result = Error.format_suggestions(suggestions)

      assert String.contains?(result, "1. First")
      assert String.contains?(result, "2. Second")
      assert String.contains?(result, "3. Third")
    end
  end

  describe "error severity determination" do
    test "determines connection severity correctly" do
      # Test through public API by checking the formatted results
      timeout_error = Error.format(:connection_failed, :timeout, %{})
      assert timeout_error.severity == :medium

      refused_error = Error.format(:connection_failed, :connection_refused, %{})
      assert refused_error.severity == :high

      unreachable_error = Error.format(:connection_failed, :network_unreachable, %{})
      assert unreachable_error.severity == :high

      other_error = Error.format(:connection_failed, :other_reason, %{})
      assert other_error.severity == :medium
    end

    test "determines tool error severity correctly" do
      timeout_error = Error.format(:tool_call_failed, :timeout, %{tool: "test"})
      assert timeout_error.severity == :medium

      not_connected_error =
        Error.format(:tool_call_failed, {:not_connected, :disconnected}, %{tool: "test"})

      assert not_connected_error.severity == :high

      other_error = Error.format(:tool_call_failed, :other_reason, %{tool: "test"})
      assert other_error.severity == :low
    end
  end

  describe "error message formatting" do
    test "formats different connection messages" do
      timeout_error = Error.format(:connection_failed, :timeout, %{})
      assert timeout_error.message == "Connection attempt timed out"

      refused_error = Error.format(:connection_failed, :connection_refused, %{})
      assert refused_error.message == "Connection refused by server"

      closed_error = Error.format(:connection_failed, :closed, %{})
      assert closed_error.message == "Connection closed unexpectedly"
    end

    test "handles various error data structures" do
      # Test nested error structure
      nested_error = %{"error" => %{"message" => "Nested error message"}}
      result = Error.format(:tool_call_failed, nested_error, %{tool: "test"})
      assert result.details == "Nested error message"

      # Test simple message structure
      simple_error = %{"message" => "Simple error message"}
      result = Error.format(:tool_call_failed, simple_error, %{tool: "test"})
      assert result.details == "Simple error message"

      # Test binary reason
      result = Error.format(:test_error, "String reason", %{})
      assert result.details == "String reason"

      # Test atom reason
      result = Error.format(:test_error, :atom_reason, %{})
      assert result.details == "atom_reason"
    end
  end

  describe "context preservation" do
    test "preserves context in all error types" do
      context = %{
        tool: "calculator",
        args: %{a: 1, b: 2},
        timeout: 5000,
        user_id: "test_user"
      }

      result = Error.format(:tool_call_failed, :timeout, context)
      assert result.context == context
    end

    test "works with empty context" do
      result = Error.format(:connection_failed, :timeout, %{})
      assert result.context == %{}
    end

    test "preserves original error in all cases" do
      original_error = {:complex, [:nested, :error]}
      result = Error.format(:test_error, original_error, %{})
      assert result.original_error == original_error
    end
  end

  describe "edge cases and error handling" do
    test "handles nil context gracefully" do
      # The function signature expects a map with default %{}, but let's test robustness
      result = Error.format(:test_error, :reason)
      assert is_map(result.context)
    end

    test "handles malformed error structures" do
      malformed_errors = [
        # Empty map
        %{},
        # Unexpected structure
        %{"unknown" => "structure"},
        # Error field not a map
        %{"error" => "not_a_map"},
        # Nil message
        %{"message" => nil}
      ]

      for malformed_error <- malformed_errors do
        result = Error.format(:tool_call_failed, malformed_error, %{tool: "test"})
        # details can be binary or nil for malformed errors
        assert is_binary(result.details) or is_nil(result.details)
        assert is_list(result.suggestions)
      end
    end

    test "handles very long error messages" do
      long_message = String.duplicate("x", 10000)
      result = Error.format(:test_error, long_message, %{})

      # Should not crash and should preserve the message
      assert result.details == long_message
    end

    test "handles special characters in context" do
      context = %{
        uri: "file://special chars & symbols!@#$%^&*()",
        tool: "tool-with-dashes_and_underscores.123",
        unicode: "🚀 Unicode text 中文"
      }

      result = Error.format(:resource_read_failed, :not_found, context)
      assert result.context == context
      assert String.contains?(result.message, context.uri)
    end
  end

  describe "comprehensive error coverage" do
    test "all error types produce valid formatted_error structure" do
      error_configs = [
        {:connection_failed, :timeout, %{}},
        {:transport_connect_failed, :connection_refused, %{}},
        {:all_transports_failed, nil, %{}},
        {:tool_call_failed, :timeout, %{tool: "test"}},
        {:tool_list_failed, "error", %{}},
        {:resource_read_failed, :not_found, %{uri: "test://uri"}},
        {:resource_list_failed, :error, %{}},
        {:prompt_get_failed, :not_found, %{prompt: "test"}},
        {:prompt_list_failed, :error, %{}},
        {:unexpected_response, "expected", %{}},
        {:timeout, nil, %{}},
        {:unknown_error, :reason, %{}}
      ]

      for {error_type, reason, context} <- error_configs do
        result = Error.format(error_type, reason, context)

        # Verify the structure matches the formatted_error type
        assert is_atom(result.type)

        assert result.category in [
                 :connection,
                 :protocol,
                 :authentication,
                 :resource,
                 :timeout,
                 :validation,
                 :internal,
                 :unknown
               ]

        assert result.severity in [:low, :medium, :high, :critical]
        assert is_binary(result.message)
        assert is_binary(result.details) or is_nil(result.details)
        assert is_list(result.suggestions)
        assert is_map(result.context)
        # original_error can be any type
      end
    end
  end
end
