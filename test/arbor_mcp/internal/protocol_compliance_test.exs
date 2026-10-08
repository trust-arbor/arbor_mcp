defmodule Arbor.MCP.Internal.ProtocolComplianceTest do
  @moduledoc """
  Tests for JSON-RPC 2.0 protocol compliance as required by MCP specification.

  These tests validate that the protocol implementation follows the JSON-RPC 2.0
  standard with MCP-specific requirements.

  This is an internal test that directly tests the protocol implementation
  to ensure compliance with the JSON-RPC 2.0 specification.
  """
  use ExUnit.Case

  @moduletag :internal
  @moduletag :compliance

  alias Arbor.MCP.Internal.Protocol

  describe "JSON-RPC 2.0 Message Format Compliance" do
    test "all requests include jsonrpc version 2.0" do
      # Test various request types
      requests = [
        Protocol.encode_initialize(%{name: "test", version: "1.0"}),
        Protocol.encode_list_tools(),
        Protocol.encode_list_resources(),
        Protocol.encode_list_prompts(),
        Protocol.encode_call_tool("test", %{}),
        Protocol.encode_read_resource("test:///resource"),
        Protocol.encode_get_prompt("test", %{})
      ]

      for request <- requests do
        assert request["jsonrpc"] == "2.0",
               "Request must include jsonrpc: '2.0', got: #{inspect(request)}"
      end
    end

    test "notifications do not include id field" do
      notifications = [
        Protocol.encode_initialized(),
        Protocol.encode_progress("token", 50),
        Protocol.encode_resources_changed(),
        Protocol.encode_tools_changed(),
        Protocol.encode_prompts_changed()
      ]

      for notification <- notifications do
        assert notification["jsonrpc"] == "2.0"

        refute Map.has_key?(notification, "id"),
               "Notifications must not have an id field, got: #{inspect(notification)}"
      end
    end

    test "requests include unique integer id" do
      # Generate multiple requests and verify IDs are unique integers
      ids =
        for _ <- 1..100 do
          msg = Protocol.encode_list_tools()
          assert is_integer(msg["id"]), "Request ID must be an integer"
          msg["id"]
        end

      assert length(Enum.uniq(ids)) == length(ids),
             "Request IDs must be unique"
    end

    test "responses include matching id from request" do
      request_id = 12345
      result = %{tools: []}

      response = Protocol.encode_response(result, request_id)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == request_id
      assert response["result"] == result
      refute Map.has_key?(response, "error")
    end

    test "error responses include error object with code and message" do
      request_id = 12345

      error_response = Protocol.encode_error(-32601, "Method not found", request_id)

      assert error_response["jsonrpc"] == "2.0"
      assert error_response["id"] == request_id
      assert error_response["error"]["code"] == -32601
      assert error_response["error"]["message"] == "Method not found"
      refute Map.has_key?(error_response, "result")
    end
  end

  describe "JSON-RPC Error Codes Compliance" do
    test "standard error code constants are correct" do
      # JSON-RPC 2.0 standard error codes
      assert Protocol.parse_error() == -32700
      assert Protocol.invalid_request() == -32600
      assert Protocol.method_not_found() == -32601
      assert Protocol.invalid_params() == -32602
      assert Protocol.internal_error() == -32603
    end

    test "error codes are in valid ranges" do
      # Standard codes: -32768 to -32000 are reserved for JSON-RPC
      standard_codes = [
        Protocol.parse_error(),
        Protocol.invalid_request(),
        Protocol.method_not_found(),
        Protocol.invalid_params(),
        Protocol.internal_error()
      ]

      for code <- standard_codes do
        assert code >= -32768 and code <= -32000,
               "Standard error code #{code} must be in range -32768 to -32000"
      end
    end
  end

  describe "MCP-Specific Protocol Requirements" do
    test "protocol version is correct" do
      msg = Protocol.encode_initialize(%{name: "test", version: "1.0"})

      assert msg["params"]["protocolVersion"] == "2025-11-25",
             "Protocol version must be 2025-11-25"
    end

    test "method names follow MCP convention" do
      # Test that method names follow the expected pattern
      method_examples = [
        {"tools/list", Protocol.encode_list_tools()},
        {"tools/call", Protocol.encode_call_tool("test", %{})},
        {"resources/list", Protocol.encode_list_resources()},
        {"resources/read", Protocol.encode_read_resource("test:///resource")},
        {"prompts/list", Protocol.encode_list_prompts()},
        {"prompts/get", Protocol.encode_get_prompt("test", %{})},
        {"completion/complete", Protocol.encode_complete(%{ref: %{type: "text"}}, %{})},
        {"logging/setLevel", Protocol.encode_set_log_level("info")}
      ]

      for {expected_method, request} <- method_examples do
        assert request["method"] == expected_method,
               "Expected method '#{expected_method}', got '#{request["method"]}'"
      end
    end

    test "notification methods follow MCP convention" do
      notification_examples = [
        {"notifications/initialized", Protocol.encode_initialized()},
        {"notifications/progress", Protocol.encode_progress("token", 50)},
        {"notifications/resources/list_changed", Protocol.encode_resources_changed()},
        {"notifications/tools/list_changed", Protocol.encode_tools_changed()},
        {"notifications/prompts/list_changed", Protocol.encode_prompts_changed()}
      ]

      for {expected_method, notification} <- notification_examples do
        assert notification["method"] == expected_method,
               "Expected method '#{expected_method}', got '#{notification["method"]}'"
      end
    end
  end

  describe "Protocol Message Parsing" do
    test "parses different message types correctly" do
      # Request message
      request_json = ~s({"jsonrpc":"2.0","method":"tools/list","params":{},"id":1})
      assert {:request, "tools/list", %{}, 1} = Protocol.parse_message(request_json)

      # Notification message (no id)
      notification_json = ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})

      assert {:notification, "notifications/initialized", %{}} =
               Protocol.parse_message(notification_json)

      # Response message with result
      response_json = ~s({"jsonrpc":"2.0","result":{"tools":[]},"id":1})
      assert {:result, %{"tools" => []}, 1} = Protocol.parse_message(response_json)

      # Error response
      error_json = ~s({"jsonrpc":"2.0","error":{"code":-32601,"message":"Not found"},"id":2})

      assert {:error, %{"code" => -32601, "message" => "Not found"}, 2} =
               Protocol.parse_message(error_json)

      # Invalid JSON
      invalid_json = ~s(not valid json)
      assert {:error, _} = Protocol.parse_message(invalid_json)
    end
  end
end
