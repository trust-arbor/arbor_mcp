defmodule Arbor.MCP.Protocol.ResponseBuilderTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Protocol.ResponseBuilder

  describe "build_success_response/2" do
    test "builds a valid success response" do
      result = %{"tools" => ["tool1", "tool2"]}
      response = ResponseBuilder.build_success_response(result, 123)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 123,
               "result" => %{"tools" => ["tool1", "tool2"]}
             }
    end

    test "handles nil id" do
      response = ResponseBuilder.build_success_response(%{}, nil)
      assert response["id"] == nil
    end

    test "handles string id" do
      response = ResponseBuilder.build_success_response(%{}, "req-123")
      assert response["id"] == "req-123"
    end
  end

  describe "build_error_response/4" do
    test "builds error response without data" do
      response = ResponseBuilder.build_error_response(-32601, "Method not found", nil, 123)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 123,
               "error" => %{
                 "code" => -32601,
                 "message" => "Method not found"
               }
             }

      refute Map.has_key?(response["error"], "data")
    end

    test "builds error response with data" do
      error_data = %{"expected" => "string", "got" => "number"}
      response = ResponseBuilder.build_error_response(-32602, "Invalid params", error_data, 123)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 123,
               "error" => %{
                 "code" => -32602,
                 "message" => "Invalid params",
                 "data" => %{"expected" => "string", "got" => "number"}
               }
             }
    end

    test "handles nil id for error response" do
      response = ResponseBuilder.build_error_response(-32600, "Invalid request", nil, nil)
      assert response["id"] == nil
    end
  end

  describe "build_notification/2" do
    test "builds a valid notification" do
      notification =
        ResponseBuilder.build_notification("resources/list_changed", %{"uri" => "test"})

      assert notification == %{
               "jsonrpc" => "2.0",
               "method" => "resources/list_changed",
               "params" => %{"uri" => "test"}
             }

      refute Map.has_key?(notification, "id")
    end

    test "handles empty params" do
      notification = ResponseBuilder.build_notification("tools/list_changed", %{})
      assert notification["params"] == %{}
    end
  end

  describe "build_request/3" do
    test "builds a valid request" do
      request = ResponseBuilder.build_request("tools/call", %{"name" => "test_tool"}, "req-456")

      assert request == %{
               "jsonrpc" => "2.0",
               "id" => "req-456",
               "method" => "tools/call",
               "params" => %{"name" => "test_tool"}
             }
    end

    test "handles numeric id" do
      request = ResponseBuilder.build_request("prompts/get", %{}, 789)
      assert request["id"] == 789
    end
  end

  describe "build_mcp_error/4" do
    test "builds error from atom without custom message" do
      response = ResponseBuilder.build_mcp_error(:method_not_found, 123)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 123,
               "error" => %{
                 "code" => ErrorCodes.method_not_found(),
                 "message" => "Method not found"
               }
             }
    end

    test "builds error from atom with custom message" do
      response = ResponseBuilder.build_mcp_error(:invalid_params, 123, "Missing 'name' field")

      assert response["error"]["code"] == ErrorCodes.invalid_params()
      assert response["error"]["message"] == "Missing 'name' field"
    end

    test "builds error with data" do
      error_data = %{"required" => ["name", "type"]}
      response = ResponseBuilder.build_mcp_error(:invalid_params, 123, nil, error_data)

      assert response["error"]["data"] == error_data
    end
  end

  describe "build_tool_error/3" do
    test "builds tool error response" do
      response = ResponseBuilder.build_tool_error("Database connection failed", true, 123)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 123,
               "result" => %{
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "Database connection failed"
                   }
                 ],
                 "isError" => true
               }
             }
    end

    test "builds tool error with isError false" do
      response = ResponseBuilder.build_tool_error("Warning: Low memory", false, 123)
      assert response["result"]["isError"] == false
    end
  end

  describe "build_batch_error/1" do
    test "builds batch error for protocol 2025-06-18" do
      response = ResponseBuilder.build_batch_error("2025-06-18")

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{
                 "code" => ErrorCodes.invalid_request(),
                 "message" => "Batch requests are not supported in protocol version 2025-06-18"
               }
             }
    end

    test "builds batch error for other protocol versions" do
      response = ResponseBuilder.build_batch_error("2025-11-05")

      assert response["error"]["message"] == "Batch requests are not supported"
    end

    test "uses default protocol version" do
      response = ResponseBuilder.build_batch_error()

      assert response["error"]["message"] ==
               "Batch requests are not supported in protocol version 2025-06-18"
    end
  end

  describe "error_response?/1" do
    test "returns true for error responses" do
      error_response = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601}}
      assert ResponseBuilder.error_response?(error_response)
    end

    test "returns false for success responses" do
      success_response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      refute ResponseBuilder.error_response?(success_response)
    end

    test "returns false for notifications" do
      notification = %{"jsonrpc" => "2.0", "method" => "test", "params" => %{}}
      refute ResponseBuilder.error_response?(notification)
    end
  end

  describe "notification?/1" do
    test "returns true for notifications" do
      notification = %{"jsonrpc" => "2.0", "method" => "test/notify", "params" => %{}}
      assert ResponseBuilder.notification?(notification)
    end

    test "returns false for requests with id" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "test", "params" => %{}}
      refute ResponseBuilder.notification?(request)
    end

    test "returns false for responses" do
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      refute ResponseBuilder.notification?(response)
    end
  end
end
