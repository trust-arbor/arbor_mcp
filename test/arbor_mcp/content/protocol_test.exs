defmodule Arbor.MCP.Content.ProtocolTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.Protocol

  doctest Arbor.MCP.Content.Protocol

  describe "text content" do
    test "creates basic text content" do
      content = Protocol.text("Hello, world!")

      assert content.type == :text
      assert content.text == "Hello, world!"
      assert content.format == :plain
      assert content.language == nil
      assert content.metadata == %{}
    end

    test "creates text content with options" do
      content =
        Protocol.text("# Header",
          format: :markdown,
          language: "en",
          metadata: %{author: "test"}
        )

      assert content.format == :markdown
      assert content.language == "en"
      assert content.metadata == %{author: "test"}
    end

    test "validates text content" do
      valid_content = Protocol.text("Hello")
      assert Protocol.validate(valid_content) == :ok

      invalid_content = %{type: :text, text: nil}
      assert {:error, _} = Protocol.validate(invalid_content)
    end
  end

  describe "image content" do
    test "creates image content" do
      data =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

      content = Protocol.image(data, "image/png")

      assert content.type == :image
      assert content.data == data
      assert content.mime_type == "image/png"
      assert content.width == nil
      assert content.height == nil
    end

    test "creates image content with dimensions" do
      data =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

      content =
        Protocol.image(data, "image/png",
          width: 100,
          height: 100,
          alt_text: "Test image"
        )

      assert content.width == 100
      assert content.height == 100
      assert content.alt_text == "Test image"
    end

    test "validates image content" do
      valid_data = Base.encode64("fake image data")
      valid_content = Protocol.image(valid_data, "image/png")
      assert Protocol.validate(valid_content) == :ok

      invalid_content = %{type: :image, data: nil}
      assert {:error, _} = Protocol.validate(invalid_content)
    end
  end

  describe "audio content" do
    test "creates audio content" do
      data = Base.encode64("fake audio data")
      content = Protocol.audio(data, "audio/wav")

      assert content.type == :audio
      assert content.data == data
      assert content.mime_type == "audio/wav"
      assert content.duration == nil
      assert content.transcript == nil
    end

    test "creates audio content with metadata" do
      data = Base.encode64("fake audio data")

      content =
        Protocol.audio(data, "audio/wav",
          duration: 10.5,
          transcript: "Hello world"
        )

      assert content.duration == 10.5
      assert content.transcript == "Hello world"
    end
  end

  describe "resource content" do
    test "creates resource content" do
      content = Protocol.resource("file://data.txt")

      assert content.type == :resource
      assert content.resource.uri == "file://data.txt"
      assert content.resource.text == nil
      assert content.resource.mime_type == nil
    end

    test "creates resource content with metadata" do
      content =
        Protocol.resource("file://doc.pdf",
          text: "Important document",
          mime_type: "application/pdf"
        )

      assert content.resource.text == "Important document"
      assert content.resource.mime_type == "application/pdf"
    end
  end

  describe "annotation content" do
    test "creates annotation content" do
      content = Protocol.annotation("sentiment")

      assert content.type == :annotation
      assert content.annotation.type == "sentiment"
      assert content.annotation.confidence == nil
      assert content.annotation.text == nil
    end

    test "creates annotation content with confidence and text" do
      content =
        Protocol.annotation("sentiment",
          confidence: 0.95,
          text: "positive"
        )

      assert content.annotation.confidence == 0.95
      assert content.annotation.text == "positive"
    end
  end

  describe "serialization" do
    test "serializes text content to MCP format" do
      content = Protocol.text("Hello", format: :markdown, language: "en")
      serialized = Protocol.serialize(content)

      expected = %{
        "type" => "text",
        "text" => "Hello",
        "format" => "markdown",
        "language" => "en"
      }

      assert serialized == expected
    end

    test "serializes image content to MCP format" do
      data = "base64data"
      content = Protocol.image(data, "image/png", width: 100, height: 100)
      serialized = Protocol.serialize(content)

      expected = %{
        "type" => "image",
        "data" => data,
        "mimeType" => "image/png",
        "width" => 100,
        "height" => 100
      }

      assert serialized == expected
    end

    test "serializes with metadata when included" do
      content = Protocol.text("Hello", metadata: %{author: "test"})
      serialized = Protocol.serialize(content, include_metadata: true)

      assert serialized["metadata"] == %{author: "test"}
    end

    test "omits metadata when excluded" do
      content = Protocol.text("Hello", metadata: %{author: "test"})
      serialized = Protocol.serialize(content, include_metadata: false)

      refute Map.has_key?(serialized, "metadata")
    end
  end

  describe "deserialization" do
    test "deserializes text content from MCP format" do
      data = %{
        "type" => "text",
        "text" => "Hello",
        "format" => "markdown",
        "language" => "en"
      }

      {:ok, content} = Protocol.deserialize(data)

      assert content.type == :text
      assert content.text == "Hello"
      assert content.format == :markdown
      assert content.language == "en"
    end

    test "deserializes image content from MCP format" do
      base64_data = Base.encode64("fake image data")

      data = %{
        "type" => "image",
        "data" => base64_data,
        "mimeType" => "image/png",
        "width" => 100,
        "height" => 100,
        "altText" => "Test image"
      }

      {:ok, content} = Protocol.deserialize(data)

      assert content.type == :image
      assert content.data == base64_data
      assert content.mime_type == "image/png"
      assert content.width == 100
      assert content.height == 100
      assert content.alt_text == "Test image"
    end

    test "handles invalid deserialization data" do
      invalid_data = %{"type" => "unknown"}
      assert {:error, _} = Protocol.deserialize(invalid_data)

      missing_type = %{"text" => "Hello"}
      assert {:error, _} = Protocol.deserialize(missing_type)
    end
  end

  describe "validation" do
    test "validates content format constraints" do
      valid_formats = [:plain, :markdown, :code, :html]

      Enum.each(valid_formats, fn format ->
        content = Protocol.text("Hello", format: format)
        assert Protocol.validate(content) == :ok
      end)
    end

    test "rejects invalid text format" do
      invalid_content = %{
        type: :text,
        text: "Hello",
        format: :invalid,
        language: nil,
        metadata: %{}
      }

      assert {:error, _} = Protocol.validate(invalid_content)
    end

    test "validates base64 data in image content" do
      valid_data = Base.encode64("test data")
      valid_content = Protocol.image(valid_data, "image/png")
      assert Protocol.validate(valid_content) == :ok

      invalid_data = "not base64!"
      invalid_content = Protocol.image(invalid_data, "image/png")
      assert {:error, _} = Protocol.validate(invalid_content)
    end

    test "validates MIME types" do
      valid_data = Base.encode64("fake image data")
      valid_image = Protocol.image(valid_data, "image/png")
      assert Protocol.validate(valid_image) == :ok

      invalid_image = Protocol.image(valid_data, "text/plain")
      assert {:error, _} = Protocol.validate(invalid_image)
    end

    test "validates URI format in resources" do
      valid_resource = Protocol.resource("file://valid/path")
      assert Protocol.validate(valid_resource) == :ok

      valid_http = Protocol.resource("https://example.com/resource")
      assert Protocol.validate(valid_http) == :ok

      invalid_resource = Protocol.resource("not a uri")
      assert {:error, _} = Protocol.validate(invalid_resource)
    end

    test "validates annotation confidence range" do
      valid_annotation = Protocol.annotation("test", confidence: 0.5)
      assert Protocol.validate(valid_annotation) == :ok

      invalid_high = Protocol.annotation("test", confidence: 1.5)
      assert {:error, _} = Protocol.validate(invalid_high)

      invalid_low = Protocol.annotation("test", confidence: -0.1)
      assert {:error, _} = Protocol.validate(invalid_low)
    end
  end

  describe "content type utilities" do
    test "gets content type" do
      text_content = Protocol.text("Hello")
      assert Protocol.content_type(text_content) == :text

      image_content = Protocol.image("data", "image/png")
      assert Protocol.content_type(image_content) == :image
    end

    test "checks content type" do
      text_content = Protocol.text("Hello")
      assert Protocol.content_type?(text_content, :text) == true
      assert Protocol.content_type?(text_content, :image) == false
    end
  end

  describe "edge cases and error handling" do
    test "handles empty content gracefully" do
      empty_text = Protocol.text("")
      assert Protocol.validate(empty_text) == :ok

      serialized = Protocol.serialize(empty_text)
      assert serialized["text"] == ""
    end

    test "handles large content" do
      large_text = String.duplicate("a", 100_000)
      content = Protocol.text(large_text)
      assert Protocol.validate(content) == :ok
    end

    test "handles unicode content" do
      unicode_text = "Hello 🌍 世界"
      content = Protocol.text(unicode_text)
      assert Protocol.validate(content) == :ok

      serialized = Protocol.serialize(content)
      assert serialized["text"] == unicode_text
    end

    test "roundtrip serialization preserves content" do
      original =
        Protocol.text("Hello",
          format: :markdown,
          language: "en",
          metadata: %{test: true}
        )

      serialized = Protocol.serialize(original)
      {:ok, deserialized} = Protocol.deserialize(serialized)

      assert deserialized.type == original.type
      assert deserialized.text == original.text
      assert deserialized.format == original.format
      assert deserialized.language == original.language
      assert deserialized.metadata == original.metadata
    end
  end
end
