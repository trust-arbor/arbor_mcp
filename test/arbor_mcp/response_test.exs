defmodule Arbor.MCP.ResponseTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Response

  describe "from_raw_response/2" do
    test "creates response from raw MCP response" do
      raw = %{
        "content" => [
          %{"type" => "text", "text" => "Hello, World!"},
          %{
            "type" => "text",
            "text" => "Second message",
            "annotations" => %{"priority" => "high"}
          }
        ],
        "meta" => %{"timestamp" => "2024-01-01T00:00:00Z"}
      }

      response = Response.from_raw_response(raw, tool_name: "say_hello", request_id: "123")

      assert response.content == [
               %{type: "text", text: "Hello, World!", data: nil, annotations: nil},
               %{
                 type: "text",
                 text: "Second message",
                 data: nil,
                 annotations: %{"priority" => "high"}
               }
             ]

      assert response.meta == %{"timestamp" => "2024-01-01T00:00:00Z"}
      assert response.tool_name == "say_hello"
      assert response.request_id == "123"
      assert response.is_error == false
    end

    test "handles empty content" do
      raw = %{}
      response = Response.from_raw_response(raw)

      assert response.content == []
      assert response.meta == nil
      assert response.is_error == false
    end

    test "handles error responses" do
      raw = %{
        "content" => [%{"type" => "text", "text" => "Error occurred"}],
        "isError" => true
      }

      response = Response.from_raw_response(raw)

      assert response.is_error == true

      assert response.content == [
               %{type: "text", text: "Error occurred", data: nil, annotations: nil}
             ]
    end

    test "preserves modern result and cache metadata" do
      raw = %{
        "resultType" => "complete",
        "ttlMs" => 30_000,
        "cacheScope" => "private",
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "example"}}
      }

      response = Response.from_raw_response(raw)

      assert response.resultType == "complete"
      assert response.ttlMs == 30_000
      assert response.cacheScope == "private"
      assert response.meta == raw["_meta"]
    end

    test "normalizes legacy content format" do
      raw = %{
        "content" => [
          %{"text" => "Legacy format"},
          %{"data" => %{"result" => 42}}
        ]
      }

      response = Response.from_raw_response(raw)

      assert response.content == [
               %{type: "text", text: "Legacy format", data: nil, annotations: nil},
               %{type: "text", text: nil, data: %{"result" => 42}, annotations: nil}
             ]
    end
  end

  describe "error/3" do
    test "creates error response" do
      response = Response.error("Tool execution failed", "calculate_sum")

      assert response.is_error == true
      assert response.tool_name == "calculate_sum"

      assert response.content == [
               %{type: "text", text: "Error: Tool execution failed", data: nil, annotations: nil}
             ]
    end

    test "creates error response with metadata" do
      response =
        Response.error("Failed", "tool",
          meta: %{"error_code" => "E001"},
          request_id: "req-123"
        )

      assert response.is_error == true
      assert response.meta == %{"error_code" => "E001"}
      assert response.request_id == "req-123"
    end
  end

  describe "text/3" do
    test "creates text response" do
      response = Response.text("Hello, World!", "say_hello")

      assert response.is_error == false
      assert response.tool_name == "say_hello"

      assert response.content == [
               %{type: "text", text: "Hello, World!", data: nil, annotations: nil}
             ]
    end

    test "creates text response with annotations" do
      response = Response.text("Important message", "tool", annotations: %{"priority" => "high"})

      assert response.content == [
               %{
                 type: "text",
                 text: "Important message",
                 data: nil,
                 annotations: %{"priority" => "high"}
               }
             ]
    end
  end

  describe "json/3" do
    test "creates JSON data response" do
      data = %{"result" => 42, "status" => "success"}
      response = Response.json(data, "calculate")

      assert response.is_error == false
      assert response.tool_name == "calculate"

      assert response.content == [
               %{type: "text", text: nil, data: data, annotations: nil}
             ]
    end
  end

  describe "query functions" do
    test "error?/1 detects error responses" do
      error_response = Response.error("Failed")
      success_response = Response.text("Success")

      assert Response.error?(error_response) == true
      assert Response.error?(success_response) == false
    end

    test "text_content/1 extracts first text content" do
      response =
        Response.from_raw_response(%{
          "content" => [
            %{"type" => "text", "text" => "First message"},
            %{"type" => "text", "text" => "Second message"}
          ]
        })

      assert Response.text_content(response) == "First message"
    end

    test "text_content/1 returns nil for no text content" do
      response = Response.json(%{"data" => "value"})

      assert Response.text_content(response) == nil
    end

    test "all_text_content/1 concatenates all text content" do
      response =
        Response.from_raw_response(%{
          "content" => [
            %{"type" => "text", "text" => "First"},
            %{"type" => "text", "text" => "Second"},
            # No text
            %{"type" => "text", "data" => %{}}
          ]
        })

      assert Response.all_text_content(response) == "First\nSecond"
    end

    test "data_content/1 extracts first data content" do
      data = %{"result" => 42}
      response = Response.json(data)

      assert Response.data_content(response) == data
    end

    test "data_content/1 returns nil for no data content" do
      response = Response.text("Just text")

      assert Response.data_content(response) == nil
    end
  end

  describe "to_raw/1" do
    test "converts response back to raw format" do
      response = %Response{
        content: [
          %{type: "text", text: "Hello", data: nil, annotations: nil},
          %{type: "text", text: nil, data: %{"key" => "value"}, annotations: %{"meta" => true}}
        ],
        meta: %{"timestamp" => "2024-01-01"},
        is_error: false
      }

      raw = Response.to_raw(response)

      assert raw == %{
               "content" => [
                 %{"type" => "text", "text" => "Hello"},
                 %{
                   "type" => "text",
                   "data" => %{"key" => "value"},
                   "annotations" => %{"meta" => true}
                 }
               ],
               "_meta" => %{"timestamp" => "2024-01-01"},
               "isError" => false
             }
    end

    test "includes isError when true" do
      response = Response.error("Failed")
      raw = Response.to_raw(response)

      assert raw["isError"] == true
    end

    test "omits absent optional fields and retains explicit false" do
      response = Response.text("Hello")
      raw = Response.to_raw(response)

      refute Map.has_key?(raw, "meta")
      assert raw["isError"] == false
    end
  end
end
