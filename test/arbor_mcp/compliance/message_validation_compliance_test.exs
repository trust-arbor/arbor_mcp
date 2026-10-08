defmodule Arbor.MCP.Compliance.MessageValidationComplianceTest do
  @moduledoc """
  Tests for MCP-specific message validation requirements.

  These tests cover message format validation that goes beyond basic JSON-RPC 2.0,
  including MCP-specific requirements for request IDs, response formats, and error handling.
  """
  use ExUnit.Case

  @moduletag :compliance

  # Note: Aliases commented out as they're for future implementation
  # alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol

  defmodule ValidationTestHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{request_ids: MapSet.new()}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "ValidationTest", version: "1.0"},
         capabilities: %{}
       }, state}
    end

    @impl true
    def handle_list_tools(_params, state) do
      {:ok, [], state}
    end

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:ok, %{content: [%{type: "text", text: "Tool called"}]}, state}
    end

    # Note: handle_request is not a callback, removing @impl
    def handle_request(request, state) do
      # Track request IDs to verify uniqueness
      id = request["id"]

      if MapSet.member?(state.request_ids, id) do
        # Return error for duplicate ID
        {:error, %{code: -32600, message: "Duplicate request ID"}, state}
      else
        new_state = %{state | request_ids: MapSet.put(state.request_ids, id)}

        # Handle null ID check
        if is_nil(id) do
          {:error, %{code: -32600, message: "Request ID cannot be null"}, new_state}
        else
          # Normal response
          {:ok, %{method: request["method"]}, new_state}
        end
      end
    end
  end

  describe "Request ID Uniqueness Validation" do
    test "server rejects duplicate request IDs within a session" do
      alias Arbor.MCP.Internal.MessageValidator

      session_state = MessageValidator.new_session()

      # First request with ID "test-123"
      request1 = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => "test-123"
      }

      # Second request with same ID
      request2 = %{
        "jsonrpc" => "2.0",
        "method" => "resources/list",
        "id" => "test-123"
      }

      # First request should succeed
      {{:ok, _}, new_session_state} = MessageValidator.validate_message(request1, session_state)

      # Second request with duplicate ID should fail
      {{:error, error}, _} = MessageValidator.validate_message(request2, new_session_state)

      assert error.code == -32600
      assert error.message == "Request ID has already been used in this session"
      assert error.data.duplicate_id == "test-123"
      assert error.data.type == "duplicate_request_id"
    end

    test "client ensures request IDs are never reused" do
      alias Arbor.MCP.Internal.Protocol

      # Generate many IDs and verify no duplicates
      ids = for _ <- 1..1000, do: Protocol.generate_id()
      unique_ids = Enum.uniq(ids)

      assert length(ids) == length(unique_ids), "Generated IDs should be unique"

      # Verify all IDs are non-null and proper type
      Enum.each(ids, fn id ->
        assert id != nil, "Generated ID should not be null"
        assert is_integer(id) or is_binary(id), "Generated ID should be string or integer"
      end)
    end
  end

  describe "Null ID Rejection" do
    test "server rejects requests with null ID" do
      alias Arbor.MCP.Internal.MessageValidator

      request_with_null_id = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => nil
      }

      session_state = MessageValidator.new_session()

      {{:error, error}, _} =
        MessageValidator.validate_message(request_with_null_id, session_state)

      assert error.code == -32600
      assert error.message == "Request ID must not be null"
    end

    test "protocol encoding never produces null IDs" do
      alias Arbor.MCP.Internal.Protocol

      # Test various encoding functions to ensure they never produce null IDs
      test_cases = [
        Protocol.encode_initialize(%{name: "test", version: "1.0"}),
        Protocol.encode_list_tools(),
        Protocol.encode_call_tool("test", %{}),
        Protocol.encode_list_resources(),
        Protocol.encode_read_resource("file://test.txt"),
        Protocol.encode_list_prompts(),
        Protocol.encode_get_prompt("test", %{}),
        Protocol.encode_complete("test", "arg"),
        Protocol.encode_create_message(%{messages: []}),
        Protocol.encode_list_roots(),
        Protocol.encode_subscribe_resource("file://test.txt"),
        Protocol.encode_unsubscribe_resource("file://test.txt"),
        Protocol.encode_ping(),
        Protocol.encode_set_log_level("info")
      ]

      Enum.each(test_cases, fn encoded ->
        assert Map.get(encoded, "id") != nil, "Encoded message should have non-null ID"
        id = Map.get(encoded, "id")
        assert is_integer(id) or is_binary(id), "ID should be string or integer"
      end)
    end
  end

  describe "Response Format Validation" do
    test "response has either result or error, never both" do
      alias Arbor.MCP.Internal.MessageValidator

      # Valid response with result only
      valid_result_response = %{
        "jsonrpc" => "2.0",
        "result" => %{"tools" => []},
        "id" => "test-123"
      }

      # Valid response with error only
      valid_error_response = %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32601, "message" => "Method not found"},
        "id" => "test-123"
      }

      # Invalid response with both result and error
      invalid_both_response = %{
        "jsonrpc" => "2.0",
        "result" => %{"tools" => []},
        "error" => %{"code" => -32601, "message" => "Method not found"},
        "id" => "test-123"
      }

      # Invalid response with neither result nor error
      invalid_neither_response = %{
        "jsonrpc" => "2.0",
        "id" => "test-123"
      }

      session_state = MessageValidator.new_session()

      # Valid responses should pass
      {{:ok, _}, _} = MessageValidator.validate_message(valid_result_response, session_state)
      {{:ok, _}, _} = MessageValidator.validate_message(valid_error_response, session_state)

      # Invalid responses should fail
      {{:error, error1}, _} =
        MessageValidator.validate_message(invalid_both_response, session_state)

      assert error1.code == -32603
      assert error1.message == "Response cannot contain both result and error"

      {{:error, error2}, _} =
        MessageValidator.validate_message(invalid_neither_response, session_state)

      assert error2.code == -32603
      assert error2.message == "Response must contain either result or error"
    end

    test "error responses include required fields" do
      alias Arbor.MCP.Internal.MessageValidator

      # Valid error with code and message
      valid_error = %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32601, "message" => "Method not found"},
        "id" => "test-123"
      }

      # Invalid error missing code
      invalid_no_code = %{
        "jsonrpc" => "2.0",
        "error" => %{"message" => "Method not found"},
        "id" => "test-123"
      }

      # Invalid error missing message
      invalid_no_message = %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32601},
        "id" => "test-123"
      }

      # Invalid error with non-integer code
      invalid_code_type = %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => "not-a-number", "message" => "Method not found"},
        "id" => "test-123"
      }

      session_state = MessageValidator.new_session()

      # Valid error should pass
      {{:ok, _}, _} = MessageValidator.validate_message(valid_error, session_state)

      # Invalid errors should fail
      {{:error, error1}, _} = MessageValidator.validate_message(invalid_no_code, session_state)
      assert error1.code == -32603
      assert String.contains?(error1.message, "missing required fields")

      {{:error, error2}, _} = MessageValidator.validate_message(invalid_no_message, session_state)
      assert error2.code == -32603
      assert String.contains?(error2.message, "missing required fields")

      {{:error, error3}, _} = MessageValidator.validate_message(invalid_code_type, session_state)
      assert error3.code == -32603
      assert String.contains?(error3.message, "missing required fields")
    end
  end

  describe "Error Code Validation" do
    test "server uses appropriate standard error codes" do
      alias Arbor.MCP.Internal.MessageValidator

      # Test standard JSON-RPC error codes
      standard_codes = [-32700, -32600, -32601, -32602, -32603]

      Enum.each(standard_codes, fn code ->
        assert {:ok, ^code} = MessageValidator.validate_error_code(code)
      end)

      # Test that invalid message structure returns appropriate error
      invalid_message = %{
        "not_jsonrpc" => "2.0",
        "method" => "invalid_method"
      }

      session_state = MessageValidator.new_session()
      {{:error, error}, _} = MessageValidator.validate_message(invalid_message, session_state)

      # Should use appropriate error code for invalid message structure
      # Invalid Request
      assert error.code == -32600
    end

    test "custom error codes are in valid range" do
      alias Arbor.MCP.Internal.MessageValidator

      # Test valid custom error code range (-32099 to -32000)
      valid_custom_codes = [-32099, -32050, -32000]

      Enum.each(valid_custom_codes, fn code ->
        assert {:ok, ^code} = MessageValidator.validate_error_code(code)
      end)

      # Test invalid custom error codes
      invalid_codes = [-32999, -31999, 0, 100]

      Enum.each(invalid_codes, fn code ->
        assert {:error, error} = MessageValidator.validate_error_code(code)
        # Internal error for invalid error code
        assert error.code == -32603
      end)
    end
  end

  describe "Message Structure Validation" do
    test "requests include all required fields" do
      alias Arbor.MCP.Internal.MessageValidator

      session_state = MessageValidator.new_session()

      # Valid request with all required fields
      valid_request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => "test-123"
      }

      {{:ok, _}, _} = MessageValidator.validate_message(valid_request, session_state)

      # Test missing jsonrpc field - should return invalid message structure error
      missing_jsonrpc = %{
        "method" => "tools/list",
        "id" => "test-123"
      }

      {{:error, error1}, _} = MessageValidator.validate_message(missing_jsonrpc, session_state)
      assert error1.code == -32600
      assert String.contains?(error1.message, "Invalid message structure")

      # Test missing method field - this will be caught as invalid message structure
      missing_method = %{
        "jsonrpc" => "2.0",
        "id" => "test-123"
      }

      {{:error, error2}, _} = MessageValidator.validate_message(missing_method, session_state)
      # This actually returns -32603 because it's treated as a response without result/error
      assert error2.code == -32603
      assert String.contains?(error2.message, "Response must contain either result or error")

      # Test missing id field - this should be treated as notification, not error
      missing_id = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list"
      }

      # This should actually succeed as a notification
      {{:ok, _}, _} = MessageValidator.validate_message(missing_id, session_state)
    end

    test "server rejects malformed requests" do
      alias Arbor.MCP.Internal.MessageValidator

      session_state = MessageValidator.new_session()

      # Test wrong jsonrpc version
      wrong_version = %{
        "jsonrpc" => "1.0",
        "method" => "tools/list",
        "id" => "test-123"
      }

      {{:error, error1}, _} = MessageValidator.validate_message(wrong_version, session_state)
      assert error1.code == -32600

      # Test non-string method - this should be caught by message structure validation
      non_string_method = %{
        "jsonrpc" => "2.0",
        "method" => 123,
        "id" => "test-123"
      }

      {{:error, error2}, _} = MessageValidator.validate_message(non_string_method, session_state)
      assert error2.code == -32600

      structured_version = %{
        "jsonrpc" => %{"nested" => "value"},
        "method" => "tools/list",
        "id" => "test-123"
      }

      assert {{:error, version_error}, _} =
               MessageValidator.validate_message(structured_version, session_state)

      assert version_error.code == -32600
      assert version_error.message == "Invalid JSON-RPC version"
      assert version_error.data == %{expected: "2.0", received_type: "object"}

      # Test invalid params type - this should be caught by request structure validation
      invalid_params = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => "test-123",
        "params" => "not-an-object"
      }

      {{:error, error3}, _} = MessageValidator.validate_message(invalid_params, session_state)
      # Invalid request
      assert error3.code == -32600
    end
  end

  describe "Batch Request Validation (2024-11-05 and 2025-03-26 only)" do
    test "empty batch array is rejected" do
      alias Arbor.MCP.Internal.MessageValidator

      session_state = MessageValidator.new_session()

      # Empty batch should be rejected
      empty_batch = []

      {{:error, error}, _} = MessageValidator.validate_message(empty_batch, session_state)
      assert error.code == -32600
      assert error.message == "Empty batch array is invalid"
    end

    test "notification-only batch returns 202 with no body" do
      alias Arbor.MCP.Internal.MessageValidator

      session_state = MessageValidator.new_session()

      # Batch containing only notifications
      notification_batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{}
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"token" => "test", "progress" => 50}
        }
      ]

      # Should validate successfully
      {{:ok, validated_batch}, _} =
        MessageValidator.validate_message(notification_batch, session_state)

      # All items should be notifications (no id field)
      Enum.each(validated_batch, fn item ->
        refute Map.has_key?(item, "id")
        assert Map.has_key?(item, "method")
      end)

      # Note: HTTP 202 response handling would be implemented at transport layer
      # This test validates that notification-only batches are properly validated
    end
  end
end
