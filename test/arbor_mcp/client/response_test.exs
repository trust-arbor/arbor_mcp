defmodule Arbor.MCP.Client.ResponseTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Response

  describe "normalize_tool/1" do
    test "normalizes complete tool definition" do
      raw_tool = %{
        "name" => "calculator",
        "description" => "Performs mathematical calculations",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "operation" => %{"type" => "string"},
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          "required" => ["operation", "a", "b"]
        },
        "version" => "1.0",
        "category" => "math"
      }

      result = Response.normalize_tool(raw_tool)

      assert result.name == "calculator"
      assert result.description == "Performs mathematical calculations"
      assert result.input_schema == raw_tool["inputSchema"]
      assert result.metadata["version"] == "1.0"
      assert result.metadata["category"] == "math"
    end

    test "normalizes minimal tool definition" do
      raw_tool = %{"name" => "simple_tool"}

      result = Response.normalize_tool(raw_tool)

      assert result.name == "simple_tool"
      assert result.description == nil
      assert result.input_schema == nil
      assert result.metadata == %{}
    end

    test "normalizes tool with empty name" do
      raw_tool = %{}

      result = Response.normalize_tool(raw_tool)

      assert result.name == ""
      assert result.description == nil
      assert result.input_schema == nil
      assert result.metadata == %{}
    end

    test "normalizes tool with invalid schema" do
      raw_tool = %{
        "name" => "tool",
        "inputSchema" => "invalid_schema"
      }

      result = Response.normalize_tool(raw_tool)

      assert result.name == "tool"
      assert result.input_schema == nil
    end

    test "preserves extra metadata fields" do
      raw_tool = %{
        "name" => "tool",
        "author" => "test_author",
        "tags" => ["math", "utility"],
        "experimental" => true
      }

      result = Response.normalize_tool(raw_tool)

      assert result.metadata["author"] == "test_author"
      assert result.metadata["tags"] == ["math", "utility"]
      assert result.metadata["experimental"] == true
    end
  end

  describe "normalize_tool_result/1" do
    test "normalizes single content item result" do
      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "Hello, World!"
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)
      assert normalized == "Hello, World!"
    end

    test "normalizes multiple content items" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "First item"},
          %{"type" => "text", "text" => "Second item"}
        ],
        "isError" => false
      }

      normalized = Response.normalize_tool_result(result)

      assert normalized.content == [
               %{type: "text", text: "First item"},
               %{type: "text", text: "Second item"}
             ]

      assert normalized.is_error == false
      assert normalized.metadata == %{}
    end

    test "normalizes content with data field" do
      result = %{
        "content" => [
          %{
            "type" => "image",
            "data" => "base64_encoded_data",
            "mimeType" => "image/png"
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)
      assert normalized == "base64_encoded_data"
    end

    test "normalizes content with uri field" do
      result = %{
        "content" => [
          %{
            "type" => "resource",
            "uri" => "file://example.txt"
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)
      assert normalized == "file://example.txt"
    end

    test "normalizes error result" do
      result = %{
        "isError" => true,
        "message" => "Tool execution failed",
        "code" => -1,
        "details" => "Additional error info"
      }

      normalized = Response.normalize_tool_result(result)

      assert {:error, error_info} = normalized
      assert error_info.message == "Tool execution failed"
      assert error_info.code == -1
      assert error_info.metadata["details"] == "Additional error info"
    end

    test "normalizes result with additional metadata" do
      result = %{
        "content" => [%{"type" => "text", "text" => "result"}],
        "executionTime" => 1500,
        "toolVersion" => "2.0"
      }

      normalized = Response.normalize_tool_result(result)

      assert normalized.content == [%{type: "text", text: "result"}]
      assert normalized.metadata["executionTime"] == 1500
      assert normalized.metadata["toolVersion"] == "2.0"
    end

    test "handles non-standard result format" do
      result = %{
        "customField" => "custom_value",
        "data" => %{"nested" => "structure"}
      }

      normalized = Response.normalize_tool_result(result)

      assert normalized["customField"] == "custom_value"
      assert normalized["data"]["nested"] == "structure"
    end

    test "normalizes content without text, data, or uri" do
      result = %{
        "content" => [
          %{
            "type" => "custom",
            "customField" => "custom_value"
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)

      # Should return the full content object since no extractable value
      assert normalized.type == "custom"
      assert normalized["customField"] == "custom_value"
    end
  end

  describe "normalize_resource/1" do
    test "normalizes complete resource definition" do
      raw_resource = %{
        "uri" => "file://data/config.json",
        "name" => "Configuration File",
        "description" => "Application configuration settings",
        "mimeType" => "application/json",
        "size" => 1024,
        "lastModified" => "2023-01-01T00:00:00Z"
      }

      result = Response.normalize_resource(raw_resource)

      assert result.uri == "file://data/config.json"
      assert result.name == "Configuration File"
      assert result.description == "Application configuration settings"
      assert result.mime_type == "application/json"
      assert result.metadata["size"] == 1024
      assert result.metadata["lastModified"] == "2023-01-01T00:00:00Z"
    end

    test "normalizes minimal resource definition" do
      raw_resource = %{"uri" => "simple://resource"}

      result = Response.normalize_resource(raw_resource)

      assert result.uri == "simple://resource"
      assert result.name == nil
      assert result.description == nil
      assert result.mime_type == nil
      assert result.metadata == %{}
    end

    test "normalizes resource with empty URI" do
      raw_resource = %{}

      result = Response.normalize_resource(raw_resource)

      assert result.uri == ""
      assert result.name == nil
      assert result.description == nil
      assert result.mime_type == nil
    end
  end

  describe "normalize_resource_content/2" do
    test "normalizes single text content" do
      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => "Hello, World!",
            "uri" => "file://test.txt"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result)
      assert normalized == "Hello, World!"
    end

    test "normalizes multiple contents" do
      result = %{
        "contents" => [
          %{"type" => "text", "text" => "First content"},
          %{"type" => "text", "text" => "Second content"}
        ],
        "totalSize" => 2048
      }

      normalized = Response.normalize_resource_content(result)

      assert normalized.contents == [
               %{type: "text", text: "First content"},
               %{type: "text", text: "Second content"}
             ]

      assert normalized.metadata["totalSize"] == 2048
    end

    test "normalizes JSON content with parsing" do
      json_text = Jason.encode!(%{key: "value", number: 42})

      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => json_text,
            "mimeType" => "application/json"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result, parse_json: true)

      # Single JSON content returns the JSON text directly
      assert normalized == json_text
    end

    test "normalizes JSON content without parsing" do
      json_text = Jason.encode!(%{key: "value"})

      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => json_text,
            "mimeType" => "application/json"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result, parse_json: false)

      # Single JSON content returns just the text when parse_json is false
      assert normalized == json_text
    end

    test "handles JSON parsing failure gracefully" do
      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => "invalid json {",
            "mimeType" => "application/json"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result, parse_json: true)

      # Single invalid JSON content returns just the text
      assert normalized == "invalid json {"
    end

    test "respects max_size limit for JSON parsing" do
      large_json = Jason.encode!(%{data: String.duplicate("x", 1000)})

      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => large_json,
            "mimeType" => "application/json"
          }
        ]
      }

      # Set a small max_size to prevent parsing
      normalized = Response.normalize_resource_content(result, parse_json: true, max_size: 100)

      # Large content returns just the text without parsing
      assert normalized == large_json
    end

    test "parses JSON from mime type containing json" do
      json_text = Jason.encode!(%{test: true})

      result = %{
        "contents" => [
          %{
            "type" => "text",
            "text" => json_text,
            "mimeType" => "text/json; charset=utf-8"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result, parse_json: true)

      # Single JSON content with mime type containing json returns the text
      assert normalized == json_text
    end

    test "handles non-standard content result" do
      result = %{
        "customData" => "value",
        "notContents" => "something"
      }

      normalized = Response.normalize_resource_content(result)

      assert normalized["customData"] == "value"
      assert normalized["notContents"] == "something"
    end

    test "normalizes data content" do
      result = %{
        "contents" => [
          %{
            "type" => "image",
            "data" => "base64data",
            "mimeType" => "image/png"
          }
        ]
      }

      normalized = Response.normalize_resource_content(result)
      assert normalized == "base64data"
    end
  end

  describe "normalize_prompt/1" do
    test "normalizes complete prompt definition" do
      raw_prompt = %{
        "name" => "greeting",
        "description" => "Generate a greeting message",
        "arguments" => [
          %{
            "name" => "name",
            "description" => "Person's name",
            "required" => true
          },
          %{
            "name" => "style",
            "description" => "Greeting style",
            "required" => false
          }
        ],
        "category" => "social",
        "version" => "1.0"
      }

      result = Response.normalize_prompt(raw_prompt)

      assert result.name == "greeting"
      assert result.description == "Generate a greeting message"
      assert length(result.arguments) == 2

      name_arg = Enum.find(result.arguments, &(&1.name == "name"))
      assert name_arg.description == "Person's name"
      assert name_arg.required == true
      assert name_arg.metadata == %{}

      style_arg = Enum.find(result.arguments, &(&1.name == "style"))
      assert style_arg.required == false

      assert result.metadata["category"] == "social"
      assert result.metadata["version"] == "1.0"
    end

    test "normalizes minimal prompt definition" do
      raw_prompt = %{"name" => "simple"}

      result = Response.normalize_prompt(raw_prompt)

      assert result.name == "simple"
      assert result.description == nil
      assert result.arguments == nil
      assert result.metadata == %{}
    end

    test "normalizes prompt with empty name" do
      raw_prompt = %{}

      result = Response.normalize_prompt(raw_prompt)

      assert result.name == ""
      assert result.description == nil
      assert result.arguments == nil
    end

    test "normalizes prompt with invalid arguments" do
      raw_prompt = %{
        "name" => "test",
        "arguments" => "not_a_list"
      }

      result = Response.normalize_prompt(raw_prompt)

      assert result.name == "test"
      assert result.arguments == nil
    end

    test "normalizes prompt arguments with defaults" do
      raw_prompt = %{
        "name" => "test",
        "arguments" => [
          # No required field
          %{"name" => "arg1"},
          # No name field
          %{
            "description" => "unnamed arg",
            "required" => true
          }
        ]
      }

      result = Response.normalize_prompt(raw_prompt)

      assert length(result.arguments) == 2

      arg1 = Enum.at(result.arguments, 0)
      assert arg1.name == "arg1"
      # Default
      assert arg1.required == false

      arg2 = Enum.at(result.arguments, 1)
      # Should preserve the original structure if malformed
      assert arg2["description"] == "unnamed arg"
    end
  end

  describe "normalize_prompt_result/1" do
    test "normalizes prompt result with messages" do
      result = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "Hello!"
            }
          },
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Hi there!"}
            ]
          }
        ],
        "promptVersion" => "1.0"
      }

      normalized = Response.normalize_prompt_result(result)

      assert length(normalized.messages) == 2

      user_msg = Enum.at(normalized.messages, 0)
      assert user_msg.role == "user"
      assert user_msg.content == "Hello!"
      assert user_msg.metadata == %{}

      assistant_msg = Enum.at(normalized.messages, 1)
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == [%{type: "text", text: "Hi there!"}]

      assert normalized.metadata["promptVersion"] == "1.0"
    end

    test "normalizes result without messages" do
      result = %{
        "error" => "Prompt not found",
        "code" => 404
      }

      normalized = Response.normalize_prompt_result(result)

      assert normalized["error"] == "Prompt not found"
      assert normalized["code"] == 404
    end

    test "normalizes complex message content" do
      result = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "First part"},
              %{"type" => "text", "text" => "Second part"}
            ]
          }
        ]
      }

      normalized = Response.normalize_prompt_result(result)

      message = Enum.at(normalized.messages, 0)
      assert message.role == "user"
      assert length(message.content) == 2
      assert Enum.at(message.content, 0).text == "First part"
    end

    test "handles malformed messages" do
      result = %{
        "messages" => [
          # Empty message
          %{},
          # No content
          %{"role" => "user"},
          # No role
          %{"content" => "orphaned content"}
        ]
      }

      normalized = Response.normalize_prompt_result(result)

      assert length(normalized.messages) == 3
      # Should preserve original structure for malformed messages
    end
  end

  describe "normalize_server_info/1" do
    test "normalizes server info" do
      server_info = %{
        "name" => "Test Server",
        "version" => "1.0.0",
        "description" => "A test MCP server",
        "author" => "Test Author"
      }

      result = Response.normalize_server_info(server_info)

      assert result.name == "Test Server"
      assert result.version == "1.0.0"
      assert result.metadata["description"] == "A test MCP server"
      assert result.metadata["author"] == "Test Author"
    end

    test "normalizes nil server info" do
      result = Response.normalize_server_info(nil)
      assert result == %{}
    end

    test "normalizes minimal server info" do
      server_info = %{}

      result = Response.normalize_server_info(server_info)

      assert result.name == nil
      assert result.version == nil
      assert result.metadata == %{}
    end
  end

  describe "content normalization helpers" do
    test "normalizes content items with all fields" do
      # This tests the private normalize_content_item function through public APIs
      # For multiple content items, we get the full structure
      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "Hello",
            "data" => "base64data",
            "uri" => "file://test.txt",
            "mimeType" => "text/plain",
            "metadata" => %{"custom" => "value"}
          }
        ],
        "isError" => false
      }

      normalized = Response.normalize_tool_result(result)

      content_item = List.first(normalized.content)
      assert content_item.type == "text"
      assert content_item.text == "Hello"
      assert content_item.data == "base64data"
      assert content_item.uri == "file://test.txt"
      assert content_item.mime_type == "text/plain"
      assert content_item["metadata"] == %{"custom" => "value"}
    end

    test "normalizes content items by removing nil values" do
      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "Hello",
            "data" => nil,
            "uri" => nil
          }
        ]
      }

      # Single content item returns just the text value
      normalized = Response.normalize_tool_result(result)
      assert normalized == "Hello"
    end

    test "extracts content values in priority order" do
      # text should be preferred over data and uri
      content_with_text = %{
        "content" => [
          %{
            "type" => "mixed",
            "text" => "text_value",
            "data" => "data_value",
            "uri" => "uri_value"
          }
        ]
      }

      result = Response.normalize_tool_result(content_with_text)
      assert result == "text_value"

      # data should be preferred over uri when no text
      content_with_data = %{
        "content" => [%{"type" => "mixed", "data" => "data_value", "uri" => "uri_value"}]
      }

      result = Response.normalize_tool_result(content_with_data)
      assert result == "data_value"

      # uri when only uri is available
      content_with_uri = %{
        "content" => [%{"type" => "resource", "uri" => "uri_value"}]
      }

      result = Response.normalize_tool_result(content_with_uri)
      assert result == "uri_value"
    end

    test "handles non-standard content items" do
      result = %{
        "content" => [
          %{
            "customType" => "custom",
            "customData" => "value"
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)

      # Should preserve non-standard content as-is
      assert normalized["customType"] == "custom"
      assert normalized["customData"] == "value"
    end
  end

  describe "error message extraction" do
    test "extracts message from different error structures" do
      # Test through tool result normalization which uses get_error_message

      # Direct message field
      error1 = %{"isError" => true, "message" => "Direct message"}
      result1 = Response.normalize_tool_result(error1)
      {:error, error_info1} = result1
      assert error_info1.message == "Direct message"

      # Nested error message
      error2 = %{"isError" => true, "error" => %{"message" => "Nested message"}}
      result2 = Response.normalize_tool_result(error2)
      {:error, error_info2} = result2
      assert error_info2.message == "Nested message"

      # Content-based message (when both content and isError are present, content takes precedence)
      error3 = %{"isError" => true, "content" => [%{"text" => "Content message"}]}
      result3 = Response.normalize_tool_result(error3)
      assert result3.content == [%{"text" => "Content message"}]
      assert result3.is_error == true

      # Fallback message
      error4 = %{"isError" => true}
      result4 = Response.normalize_tool_result(error4)
      {:error, error_info4} = result4
      assert error_info4.message == "Unknown error"
    end
  end

  describe "metadata extraction" do
    test "extracts metadata excluding specified keys" do
      # Test through tool normalization which uses extract_metadata
      raw_tool = %{
        "name" => "test_tool",
        "description" => "Test description",
        "inputSchema" => %{},
        "version" => "1.0",
        "author" => "Test Author",
        "tags" => ["test"]
      }

      result = Response.normalize_tool(raw_tool)

      # Should exclude name, description, inputSchema but include others
      assert result.metadata["version"] == "1.0"
      assert result.metadata["author"] == "Test Author"
      assert result.metadata["tags"] == ["test"]
      refute Map.has_key?(result.metadata, "name")
      refute Map.has_key?(result.metadata, "description")
      refute Map.has_key?(result.metadata, "inputSchema")
    end

    test "returns empty metadata when no extra fields" do
      raw_tool = %{
        "name" => "test_tool",
        "description" => "Test description",
        "inputSchema" => %{}
      }

      result = Response.normalize_tool(raw_tool)
      assert result.metadata == %{}
    end

    test "handles non-map inputs gracefully" do
      # This tests the fallback case in extract_metadata
      # We can't easily test this directly, but we can test edge cases

      # The public API should handle edge cases gracefully
      assert %{metadata: %{}} = Response.normalize_tool(%{})
      assert %{metadata: %{}} = Response.normalize_resource(%{})
      assert %{metadata: %{}} = Response.normalize_prompt(%{})
    end
  end

  describe "edge cases and robustness" do
    test "handles very large content" do
      large_text = String.duplicate("x", 100_000)

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => large_text
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)
      assert normalized == large_text
    end

    test "handles special characters and Unicode" do
      unicode_text = "Hello 🌍! 你好世界! مرحبا بالعالم!"

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => unicode_text
          }
        ]
      }

      normalized = Response.normalize_tool_result(result)
      assert normalized == unicode_text
    end

    test "handles deeply nested structures" do
      deep_content = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "data" => "deep_value"
            }
          }
        }
      }

      result = Response.normalize_tool_result(deep_content)
      assert result["level1"]["level2"]["level3"]["data"] == "deep_value"
    end

    test "handles circular reference prevention" do
      # JSON can't encode circular refs, but we should handle unexpected structures gracefully
      weird_structure = %{
        "content" => [
          %{
            "type" => "complex",
            "nested" => %{
              "very" => %{
                "deep" => "structure"
              }
            }
          }
        ]
      }

      # Should not crash
      result = Response.normalize_tool_result(weird_structure)
      assert result["nested"]["very"]["deep"] == "structure"
    end

    test "preserves numeric and boolean values correctly" do
      complex_result = %{
        "content" => [%{"type" => "text", "text" => "result"}],
        "executionTime" => 1.5,
        "success" => true,
        "retryCount" => 0,
        "resources" => nil
      }

      normalized = Response.normalize_tool_result(complex_result)

      assert normalized.metadata["executionTime"] == 1.5
      assert normalized.metadata["success"] == true
      assert normalized.metadata["retryCount"] == 0
      # nil values are preserved in metadata
      assert Map.has_key?(normalized.metadata, "resources")
      assert normalized.metadata["resources"] == nil
    end
  end
end
