defmodule Arbor.MCP.ErrorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Error

  describe "from_json_rpc_error/2" do
    test "creates error from JSON-RPC error response" do
      json_error = %{
        "code" => -32601,
        "message" => "Method not found",
        "data" => %{"method" => "unknown_method"}
      }

      error = Error.from_json_rpc_error(json_error, request_id: "123")

      assert error.code == -32601
      assert error.message == "Method not found"
      assert error.data == %{"method" => "unknown_method"}
      assert error.request_id == "123"
    end

    test "handles minimal error response" do
      json_error = %{"code" => -32603}

      error = Error.from_json_rpc_error(json_error)

      assert error.code == -32603
      assert error.message == "Unknown error"
      assert error.data == nil
      assert error.request_id == nil
    end
  end

  describe "JSON-RPC standard errors" do
    test "parse_error/2" do
      error = Error.parse_error("Invalid JSON")

      assert error.code == -32700
      assert error.message == "Parse error: Invalid JSON"
    end

    test "invalid_request/2" do
      error = Error.invalid_request("Missing jsonrpc field")

      assert error.code == -32600
      assert error.message == "Invalid request: Missing jsonrpc field"
    end

    test "method_not_found/2" do
      error = Error.method_not_found("unknown_method")

      assert error.code == -32601
      assert error.message == "Method not found: unknown_method"
    end

    test "invalid_params/2" do
      error = Error.invalid_params("Required parameter missing")

      assert error.code == -32602
      assert error.message == "Invalid params: Required parameter missing"
    end

    test "internal_error/2" do
      error = Error.internal_error("Database connection failed")

      assert error.code == -32603
      assert error.message == "Internal error: Database connection failed"
    end
  end

  describe "MCP-specific errors" do
    test "tool_error/3" do
      error = Error.tool_error("Execution failed", "calculate_sum")

      assert error.code == -32000
      assert error.message == "Tool error in 'calculate_sum': Execution failed"
      assert error.data == %{tool_name: "calculate_sum"}
    end

    test "tool_error/3 without tool name" do
      error = Error.tool_error("Generic tool error")

      assert error.message == "Tool error: Generic tool error"
    end

    test "resource_error/3" do
      error = Error.resource_error("File not found", "file://config.json")

      assert error.code == -32001
      assert error.message == "Resource error for 'file://config.json': File not found"
      assert error.data == %{resource_uri: "file://config.json"}
    end

    test "missing_required_client_capability/1" do
      required = %{"sampling" => %{"tools" => %{}}}
      error = Error.missing_required_client_capability(required)

      assert error.code == -32021
      assert error.message == "Missing required client capability"
      assert error.data == %{"requiredCapabilities" => required}
      assert Error.to_json_rpc(error)["data"] == %{"requiredCapabilities" => required}
    end

    test "prompt_error/3" do
      error = Error.prompt_error("Invalid arguments", "code_review")

      assert error.code == -31003
      assert error.message == "Prompt error in 'code_review': Invalid arguments"
      assert error.data == %{prompt_name: "code_review"}
      assert Error.application_error?(error)
      refute Error.mcp_error?(error)
    end

    test "transport_error/2" do
      error = Error.transport_error("Connection timeout")

      assert error.code == -32003
      assert error.message == "Transport error: Connection timeout"
    end

    test "authentication_error/2" do
      error = Error.authentication_error("Invalid token")

      assert error.code == -32004
      assert error.message == "Authentication error: Invalid token"
    end

    test "authorization_error/2" do
      error = Error.authorization_error("Insufficient permissions")

      assert error.code == -32005
      assert error.message == "Authorization error: Insufficient permissions"
    end
  end

  describe "connection_error/2" do
    test "creates connection error" do
      error = Error.connection_error("Connection refused")

      assert error.code == :connection_error
      assert error.message == "Connection error: Connection refused"
    end
  end

  describe "to_json_rpc/1" do
    test "converts error to JSON-RPC format" do
      error = Error.method_not_found("test_method")
      json = Error.to_json_rpc(error)

      assert json == %{
               "code" => -32601,
               "message" => "Method not found: test_method"
             }
    end

    test "includes data when present" do
      error = Error.tool_error("Failed", "tool", data: %{"extra" => "info"})
      json = Error.to_json_rpc(error)

      assert json["data"] == %{"extra" => "info"}
    end

    test "excludes data when nil" do
      error = Error.parse_error()
      json = Error.to_json_rpc(error)

      refute Map.has_key?(json, "data")
    end
  end

  describe "error classification" do
    test "json_rpc_error?/1" do
      assert Error.json_rpc_error?(Error.parse_error()) == true
      assert Error.json_rpc_error?(Error.method_not_found("test")) == true
      assert Error.json_rpc_error?(Error.connection_error("failed")) == false
    end

    test "mcp_error?/1" do
      assert Error.mcp_error?(Error.tool_error("failed", "tool")) == true
      assert Error.mcp_error?(Error.resource_error("failed", "uri")) == true
      assert Error.mcp_error?(Error.parse_error()) == false
      assert Error.mcp_error?(Error.connection_error("failed")) == false
    end

    test "category/1" do
      assert Error.category(Error.parse_error()) == "Parse Error"
      assert Error.category(Error.tool_error("failed", "tool")) == "Tool Error"
      assert Error.category(Error.resource_error("failed", "uri")) == "Resource Error"
      assert Error.category(Error.connection_error("failed")) == "Connection Error"
    end
  end

  describe "Exception behavior" do
    test "implements Exception.message/1" do
      error = Error.tool_error("Test error", "test_tool")

      assert Exception.message(error) == "Tool error in 'test_tool': Test error"
    end

    test "can be raised as exception" do
      assert_raise Error, "Tool error in 'test': Failed", fn ->
        raise Error.tool_error("Failed", "test")
      end
    end
  end

  describe "error creation with options" do
    test "includes request_id in all error types" do
      request_id = "req-123"

      errors = [
        Error.parse_error("test", request_id: request_id),
        Error.tool_error("test", "tool", request_id: request_id),
        Error.connection_error("test", request_id: request_id)
      ]

      Enum.each(errors, fn error ->
        assert error.request_id == request_id
      end)
    end

    test "includes custom data in relevant error types" do
      custom_data = %{"extra" => "information"}

      error = Error.tool_error("test", "tool", data: custom_data)
      assert error.data == custom_data
    end
  end
end
