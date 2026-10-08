defmodule Arbor.MCP.ResponseComprehensiveTest do
  @moduledoc """
  Comprehensive test suite for Arbor.MCP.Response covering all edge cases,
  list responses, pagination, and format conversions.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Response

  describe "list response fields" do
    test "handles tools list response" do
      raw = %{
        "tools" => [
          %{
            "name" => "hello",
            "description" => "Says hello",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          },
          %{
            "name" => "calculate",
            "description" => "Performs calculations",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "expression" => %{"type" => "string"}
              }
            }
          }
        ],
        "nextCursor" => "cursor123"
      }

      response = Response.from_raw_response(raw)

      assert length(response.tools) == 2
      assert response.nextCursor == "cursor123"

      # Verify string keys are preserved
      first_tool = hd(response.tools)
      assert first_tool["name"] == "hello"
      assert first_tool["description"] == "Says hello"
      assert first_tool["inputSchema"]["type"] == "object"
    end

    test "handles resources list response" do
      raw = %{
        "resources" => [
          %{
            "uri" => "file:///test.txt",
            "name" => "Test File",
            "mimeType" => "text/plain"
          }
        ]
      }

      response = Response.from_raw_response(raw)

      assert length(response.resources) == 1
      resource = hd(response.resources)
      assert resource["uri"] == "file:///test.txt"
      assert resource["mimeType"] == "text/plain"
    end

    test "handles prompts list response" do
      raw = %{
        "prompts" => [
          %{
            "name" => "greeting",
            "description" => "Generate a greeting",
            "arguments" => [
              %{"name" => "name", "description" => "Person's name", "required" => true}
            ]
          }
        ],
        "nextCursor" => nil
      }

      response = Response.from_raw_response(raw)

      assert length(response.prompts) == 1
      assert is_nil(response.nextCursor)

      prompt = hd(response.prompts)
      assert prompt["name"] == "greeting"
      assert length(prompt["arguments"]) == 1
    end

    test "handles messages field for sampling responses" do
      raw = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}},
          %{"role" => "assistant", "content" => %{"type" => "text", "text" => "Hi there!"}}
        ]
      }

      response = Response.from_raw_response(raw)

      assert length(response.messages) == 2

      # Messages should have atom keys for struct-like access
      user_msg = hd(response.messages)
      assert user_msg.role == "user"
      assert user_msg.content.type == "text"
      assert user_msg.content.text == "Hello"
    end
  end

  describe "resource read responses" do
    test "handles resource contents field" do
      raw = %{
        "contents" => [
          %{
            "uri" => "file:///test.txt",
            "mimeType" => "text/plain",
            "text" => "File contents here"
          }
        ]
      }

      response = Response.from_raw_response(raw)

      assert length(response.contents) == 1
      assert Response.resource_content(response) == "File contents here"
    end

    test "resource_content/1 returns nil when no contents" do
      response = Response.text("Not a resource response")
      assert is_nil(Response.resource_content(response))
    end
  end

  describe "prompt get responses" do
    test "handles prompt description field" do
      raw = %{
        "description" => "This prompt generates a greeting",
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello {{name}}"}}
        ]
      }

      response = Response.from_raw_response(raw)

      assert response.description == "This prompt generates a greeting"
      assert length(response.messages) == 1
    end
  end

  describe "backward compatibility" do
    test "handles both is_error and isError fields" do
      # Old format with is_error
      raw1 = %{"is_error" => true}
      response1 = Response.from_raw_response(raw1)
      assert response1.is_error == true

      # New format with isError
      raw2 = %{"isError" => true}
      response2 = Response.from_raw_response(raw2)
      assert response2.is_error == true

      # Neither field present defaults to false
      raw3 = %{}
      response3 = Response.from_raw_response(raw3)
      assert response3.is_error == false
    end
  end

  describe "accessor functions" do
    test "tool accessor functions" do
      tool = %{
        "name" => "test_tool",
        "description" => "A test tool",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"input" => %{"type" => "string"}}
        }
      }

      assert Response.tool_name(tool) == "test_tool"
      assert Response.tool_description(tool) == "A test tool"
      assert Response.tool_input_schema(tool)["type"] == "object"

      # Returns nil for missing fields
      assert Response.tool_name(%{}) == nil
      assert Response.tool_description(%{}) == nil
      assert Response.tool_input_schema(%{}) == nil
    end

    test "schema_property/2 helper" do
      schema = %{
        "properties" => %{
          "name" => %{"type" => "string", "description" => "User name"},
          "age" => %{"type" => "integer"}
        }
      }

      assert Response.schema_property(schema, "name") == %{
               "type" => "string",
               "description" => "User name"
             }

      assert Response.schema_property(schema, "age") == %{"type" => "integer"}
      assert Response.schema_property(schema, "missing") == nil
      assert Response.schema_property(%{}, "any") == nil
    end
  end

  describe "structured output fields" do
    test "handles structuredOutput field" do
      raw = %{
        "structuredOutput" => %{"result" => 42, "status" => "complete"}
      }

      response = Response.from_raw_response(raw)
      assert response.structuredOutput == %{"result" => 42, "status" => "complete"}
    end

    test "handles legacy structuredContent field" do
      raw = %{
        "structuredContent" => %{"data" => "legacy"}
      }

      response = Response.from_raw_response(raw)
      assert response.structuredOutput == %{"data" => "legacy"}
    end

    test "handles completion field as structuredOutput" do
      raw = %{
        "completion" => "Generated text",
        "model" => "gpt-4"
      }

      response = Response.from_raw_response(raw)
      assert response.structuredOutput == %{"completion" => "Generated text", "model" => "gpt-4"}
    end
  end

  describe "resource links" do
    test "handles resourceLinks field" do
      raw = %{
        "resourceLinks" => [
          %{"uri" => "file:///linked.txt", "rel" => "related"}
        ]
      }

      response = Response.from_raw_response(raw)
      assert length(response.resourceLinks) == 1
      assert hd(response.resourceLinks)["uri"] == "file:///linked.txt"
    end
  end

  describe "edge cases" do
    test "handles nil and empty values gracefully" do
      raw = %{
        "content" => nil,
        "tools" => [],
        "resources" => nil,
        "prompts" => [],
        "messages" => nil,
        "nextCursor" => nil
      }

      response = Response.from_raw_response(raw)

      assert response.content == []
      assert response.tools == []
      assert response.resources == nil
      assert response.prompts == []
      assert response.messages == nil
      assert response.nextCursor == nil
    end

    test "preserves unknown fields in raw response" do
      raw = %{
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "customField" => "custom value",
        "futureField" => %{"nested" => true}
      }

      response = Response.from_raw_response(raw)

      # Standard fields are processed
      assert length(response.content) == 1

      # Unknown fields are not added to struct
      refute Map.has_key?(response, :customField)
      refute Map.has_key?(response, :futureField)
    end
  end

  describe "response format conversion" do
    test "from_map/1 creates Response from plain map (backward compatibility)" do
      map = %{
        "tools" => [%{"name" => "test"}],
        "nextCursor" => "abc"
      }

      response = Response.from_map(map)
      # The implementation provides both string and atom keys for compatibility
      assert response.tools == [%{:name => "test", "name" => "test"}]
      assert response.nextCursor == "abc"
    end

    test "from_map/1 returns Response struct unchanged" do
      original = Response.text("Hello", "greeting")
      result = Response.from_map(original)

      assert result == original
    end

    test "from_map/1 handles all response types" do
      # Tool response
      tool_map = %{"content" => [%{"type" => "text", "text" => "Result"}]}
      tool_response = Response.from_map(tool_map)
      assert Response.text_content(tool_response) == "Result"

      # List response
      list_map = %{"resources" => [%{"uri" => "file:///test"}], "nextCursor" => "xyz"}
      list_response = Response.from_map(list_map)
      assert length(list_response.resources) == 1
      assert list_response.nextCursor == "xyz"

      # Error response
      error_map = %{
        "isError" => true,
        "content" => [%{"type" => "text", "text" => "Error: Failed"}]
      }

      error_response = Response.from_map(error_map)
      assert Response.error?(error_response)
      assert Response.text_content(error_response) == "Error: Failed"
    end
  end
end
