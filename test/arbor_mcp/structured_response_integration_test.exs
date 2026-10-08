defmodule Arbor.MCP.StructuredResponseIntegrationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.{Error, Response}

  describe "Response integration" do
    test "from_raw_response creates structured response" do
      raw = %{
        "content" => [
          %{"type" => "text", "text" => "Hello World!"}
        ],
        "meta" => %{"timestamp" => "2024-01-01"}
      }

      response = Response.from_raw_response(raw, tool_name: "test_tool")

      assert %Response{} = response
      assert response.tool_name == "test_tool"
      assert response.is_error == false
      assert Response.text_content(response) == "Hello World!"
    end

    test "to_raw converts response back to raw format" do
      response = Response.text("Test message", "test_tool")
      raw = Response.to_raw(response)

      assert raw["content"] == [%{"type" => "text", "text" => "Test message"}]
      assert raw["isError"] == false
    end

    test "error responses are properly structured" do
      response = Response.error("Something failed", "test_tool")

      assert Response.error?(response) == true
      assert response.tool_name == "test_tool"
      assert Response.text_content(response) == "Error: Something failed"
    end
  end

  describe "Error integration" do
    test "from_json_rpc_error creates structured error" do
      json_error = %{
        "code" => -32601,
        "message" => "Method not found",
        "data" => %{"method" => "unknown"}
      }

      error = Error.from_json_rpc_error(json_error, request_id: "123")

      assert %Error{} = error
      assert error.code == -32601
      assert error.message == "Method not found"
    end

    test "to_json_rpc converts error to JSON-RPC format" do
      error = Error.tool_error("test_tool", "Execution failed")
      json = Error.to_json_rpc(error)

      assert json["code"] == -32000
      assert json["message"] == "Tool execution error"
    end

    test "different error types have correct codes" do
      tool_error = Error.tool_error("tool", "Failed")
      protocol_error = Error.protocol_error(-32601, "Method not found")
      conn_error = Error.connection_error("Timeout")

      tool_json = Error.to_json_rpc(tool_error)
      protocol_json = Error.to_json_rpc(protocol_error)
      conn_json = Error.to_json_rpc(conn_error)

      assert tool_json["code"] == -32000
      assert protocol_json["code"] == -32601
      assert conn_json["code"] == -32003
    end
  end
end
