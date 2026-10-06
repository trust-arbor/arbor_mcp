defmodule Arbor.MCP.Testing.BuildersTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.Protocol
  alias Arbor.MCP.Testing.Builders

  describe "text_content/2" do
    test "creates basic text content" do
      content = Builders.text_content("Hello world")

      assert content.type == :text
      assert content.text == "Hello world"
      assert content.format == :plain
      assert content.language == nil
      assert content.metadata == %{}
    end

    test "creates text content with options" do
      content =
        Builders.text_content("# Header",
          format: :markdown,
          language: "en",
          metadata: %{author: "test"}
        )

      assert content.format == :markdown
      assert content.language == "en"
      assert content.metadata == %{author: "test"}
    end

    test "creates random text content" do
      content = Builders.text_content(nil, random: true, size: 20)

      assert content.type == :text
      assert is_binary(content.text)
      assert String.length(content.text) <= 20
    end

    test "creates default content when no args" do
      content = Builders.text_content()

      assert content.type == :text
      assert content.text == "Sample text content"
    end
  end

  describe "image_content/1" do
    test "creates basic image content" do
      content = Builders.image_content()

      assert content.type == :image
      assert is_binary(content.data)
      assert content.mime_type == "image/png"
      assert content.width == nil
      assert content.height == nil
    end

    test "creates image content with options" do
      content =
        Builders.image_content(
          mime_type: "image/jpeg",
          width: 800,
          height: 600,
          alt_text: "Test image"
        )

      assert content.mime_type == "image/jpeg"
      assert content.width == 800
      assert content.height == 600
      assert content.alt_text == "Test image"
    end

    test "creates random image content" do
      content = Builders.image_content(random: true, size: 100)

      assert content.type == :image
      assert is_binary(content.data)
      # Base64 encoded data should be larger than original size
      assert String.length(content.data) > 100
    end
  end

  describe "audio_content/1" do
    test "creates basic audio content" do
      content = Builders.audio_content()

      assert content.type == :audio
      assert is_binary(content.data)
      assert content.mime_type == "audio/wav"
      assert content.duration == nil
      assert content.transcript == nil
    end

    test "creates audio content with options" do
      content =
        Builders.audio_content(
          duration: 10.5,
          transcript: "Hello world"
        )

      assert content.duration == 10.5
      assert content.transcript == "Hello world"
    end

    test "creates random audio content" do
      content = Builders.audio_content(random: true, size: 200)

      assert content.type == :audio
      assert is_binary(content.data)
    end
  end

  describe "resource_content/2" do
    test "creates basic resource content" do
      content = Builders.resource_content("file://test.txt")

      assert content.type == :resource
      assert content.resource.uri == "file://test.txt"
      assert content.resource.text == nil
      assert content.resource.mime_type == nil
    end

    test "creates resource content with options" do
      content =
        Builders.resource_content("file://doc.pdf",
          text: "Important document",
          mime_type: "application/pdf"
        )

      assert content.resource.text == "Important document"
      assert content.resource.mime_type == "application/pdf"
    end

    test "creates random resource content" do
      content = Builders.resource_content(nil, random: true)

      assert content.type == :resource
      assert is_binary(content.resource.uri)
      assert String.contains?(content.resource.uri, "://")
    end
  end

  describe "annotation_content/2" do
    test "creates basic annotation content" do
      content = Builders.annotation_content("sentiment")

      assert content.type == :annotation
      assert content.annotation.type == "sentiment"
      assert content.annotation.confidence == nil
      assert content.annotation.text == nil
    end

    test "creates annotation content with options" do
      content =
        Builders.annotation_content("classification",
          confidence: 0.95,
          text: "positive"
        )

      assert content.annotation.confidence == 0.95
      assert content.annotation.text == "positive"
    end

    test "creates random annotation content" do
      content = Builders.annotation_content(nil, random: true)

      assert content.type == :annotation
      assert is_binary(content.annotation.type)
    end
  end

  describe "tool/2" do
    test "creates basic tool definition" do
      tool = Builders.tool("test_tool")

      assert tool["name"] == "test_tool"
      assert tool["description"] == "A test tool"
      assert is_map(tool["inputSchema"])
      assert tool["inputSchema"]["type"] == "object"
    end

    test "creates tool with custom options" do
      schema = Builders.object_schema(%{"input" => Builders.string_schema()})

      tool =
        Builders.tool("custom_tool",
          description: "Custom description",
          schema: schema
        )

      assert tool["description"] == "Custom description"
      assert tool["inputSchema"] == schema
    end

    test "creates random tool" do
      tool = Builders.tool(nil, random: true)

      assert is_binary(tool["name"])
      assert String.starts_with?(tool["name"], "tool_")
    end
  end

  describe "tool_result/2" do
    test "creates tool result from string" do
      result = Builders.tool_result("Success")

      assert is_list(result["content"])
      assert length(result["content"]) == 1

      content = hd(result["content"])
      assert content["type"] == "text"
      assert content["text"] == "Success"
    end

    test "creates tool result from content list" do
      content_list = [
        Builders.text_content("Result 1"),
        Builders.text_content("Result 2")
      ]

      result = Builders.tool_result(content_list)

      assert length(result["content"]) == 2
    end

    test "creates error result" do
      result = Builders.tool_result(nil, error: "Something failed")

      assert result["isError"] == true
      assert is_list(result["content"])
    end
  end

  describe "resource/3" do
    test "creates basic resource definition" do
      resource = Builders.resource("file://test.txt", "Test File")

      assert resource["uri"] == "file://test.txt"
      assert resource["name"] == "Test File"
    end

    test "creates resource with metadata" do
      resource =
        Builders.resource("https://api.example.com", "API",
          description: "REST API",
          mime_type: "application/json"
        )

      assert resource["description"] == "REST API"
      assert resource["mimeType"] == "application/json"
    end

    test "creates random resource" do
      resource = Builders.resource(nil, nil, random: true)

      assert is_binary(resource["uri"])
      assert is_binary(resource["name"])
    end
  end

  describe "prompt/3" do
    test "creates basic prompt definition" do
      prompt = Builders.prompt("test_prompt", "Test prompt")

      assert prompt["name"] == "test_prompt"
      assert prompt["description"] == "Test prompt"
      refute Map.has_key?(prompt, "arguments")
    end

    test "creates prompt with arguments" do
      arguments = [
        Builders.prompt_argument("topic", "The topic", required: true)
      ]

      prompt = Builders.prompt("complex_prompt", "Complex prompt", arguments: arguments)

      assert prompt["arguments"] == arguments
    end

    test "creates random prompt" do
      prompt = Builders.prompt(nil, nil, random: true)

      assert String.starts_with?(prompt["name"], "prompt_")
      assert is_binary(prompt["description"])
    end
  end

  describe "prompt_argument/3" do
    test "creates basic prompt argument" do
      arg = Builders.prompt_argument("topic", "The topic to discuss")

      assert arg["name"] == "topic"
      assert arg["description"] == "The topic to discuss"
      refute Map.has_key?(arg, "required")
    end

    test "creates required prompt argument" do
      arg = Builders.prompt_argument("input", "Required input", required: true)

      assert arg["required"] == true
    end
  end

  describe "message builders" do
    test "request/2 creates valid MCP request" do
      request = Builders.request("list_tools", id: 123, params: %{"filter" => "active"})

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "list_tools"
      assert request["id"] == 123
      assert request["params"] == %{"filter" => "active"}
    end

    test "success_response/2 creates valid MCP response" do
      response = Builders.success_response(123, %{"tools" => []})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 123
      assert response["result"] == %{"tools" => []}
    end

    test "error_response/4 creates valid MCP error response" do
      error = Builders.error_response(123, -32601, "Method not found", %{"details" => "info"})

      assert error["jsonrpc"] == "2.0"
      assert error["id"] == 123
      assert error["error"]["code"] == -32601
      assert error["error"]["message"] == "Method not found"
      assert error["error"]["data"] == %{"details" => "info"}
    end

    test "notification/2 creates valid MCP notification" do
      notification = Builders.notification("notifications/message", %{"text" => "Hello"})

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/message"
      assert notification["params"] == %{"text" => "Hello"}
      refute Map.has_key?(notification, "id")
    end
  end

  describe "schema builders" do
    test "object_schema/2 creates valid JSON Schema object" do
      schema = Builders.object_schema()

      assert schema["type"] == "object"
      assert schema["properties"] == %{}
    end

    test "object_schema/2 with properties and required fields" do
      properties = %{
        "name" => Builders.string_schema(),
        "age" => Builders.integer_schema()
      }

      schema = Builders.object_schema(properties, required: ["name"])

      assert schema["properties"] == properties
      assert schema["required"] == ["name"]
    end

    test "string_schema/1 creates valid JSON Schema string" do
      schema = Builders.string_schema()

      assert schema["type"] == "string"
    end

    test "string_schema/1 with constraints" do
      schema =
        Builders.string_schema(
          min_length: 1,
          max_length: 100,
          pattern: "^[a-z]+$",
          format: "email"
        )

      assert schema["minLength"] == 1
      assert schema["maxLength"] == 100
      assert schema["pattern"] == "^[a-z]+$"
      assert schema["format"] == "email"
    end

    test "integer_schema/1 creates valid JSON Schema integer" do
      schema = Builders.integer_schema()

      assert schema["type"] == "integer"
    end

    test "integer_schema/1 with constraints" do
      schema =
        Builders.integer_schema(
          minimum: 0,
          maximum: 100,
          multiple_of: 5
        )

      assert schema["minimum"] == 0
      assert schema["maximum"] == 100
      assert schema["multipleOf"] == 5
    end

    test "array_schema/2 creates valid JSON Schema array" do
      schema = Builders.array_schema()

      assert schema["type"] == "array"
    end

    test "array_schema/2 with item schema and constraints" do
      item_schema = Builders.string_schema()

      schema =
        Builders.array_schema(item_schema,
          min_items: 1,
          max_items: 10,
          unique_items: true
        )

      assert schema["items"] == item_schema
      assert schema["minItems"] == 1
      assert schema["maxItems"] == 10
      assert schema["uniqueItems"] == true
    end
  end

  describe "random generators" do
    test "random_text/1 generates text of specified length" do
      text = Builders.random_text(50)

      assert is_binary(text)
      assert String.length(text) <= 50
      assert String.length(text) > 0
    end

    test "random_string/1 generates string of exact length" do
      string = Builders.random_string(10)

      assert is_binary(string)
      assert String.length(string) == 10
      assert Regex.match?(~r/^[a-z0-9]+$/, string)
    end

    test "random_bytes/1 generates binary of specified size" do
      bytes = Builders.random_bytes(20)

      assert is_binary(bytes)
      assert byte_size(bytes) == 20
    end

    test "random generators advance the process PRNG and reproduce seeded results" do
      seed = {101, 202, 303}
      :rand.seed(:exsss, seed)
      before_text = :rand.export_seed()
      text = Builders.random_text(20)

      assert :rand.export_seed() != before_text
      assert is_binary(text)
      assert String.length(text) > 0 and String.length(text) <= 20
      :rand.seed(:exsss, seed)
      assert Builders.random_text(20) == text

      :rand.seed(:exsss, seed)
      before_string = :rand.export_seed()
      string = Builders.random_string(10)

      assert :rand.export_seed() != before_string
      assert is_binary(string)
      assert String.length(string) == 10
      assert Regex.match?(~r/^[a-z0-9]+$/, string)
      :rand.seed(:exsss, seed)
      assert Builders.random_string(10) == string
    end
  end

  describe "content validation" do
    test "generated content passes protocol validation" do
      # Test all content types
      text_content = Builders.text_content("Test")
      assert Protocol.validate(text_content) == :ok

      image_content = Builders.image_content()
      assert Protocol.validate(image_content) == :ok

      audio_content = Builders.audio_content()
      assert Protocol.validate(audio_content) == :ok

      resource_content = Builders.resource_content("file://test.txt")
      assert Protocol.validate(resource_content) == :ok

      annotation_content = Builders.annotation_content("test")
      assert Protocol.validate(annotation_content) == :ok
    end

    test "generated tool results are valid" do
      tool_result = Builders.tool_result("Success")

      # Should have valid content structure
      assert is_list(tool_result["content"])
      assert length(tool_result["content"]) > 0

      # Each content item should be valid
      Enum.each(tool_result["content"], fn content ->
        {:ok, parsed} = Protocol.deserialize(content)
        assert Protocol.validate(parsed) == :ok
      end)
    end
  end
end
