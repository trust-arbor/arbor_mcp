defmodule Arbor.MCP.Content.BuildersTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.{Builders, Protocol}

  describe "basic builders" do
    test "text builder creates valid content" do
      content = Builders.text("Hello")

      assert content.type == :text
      assert content.text == "Hello"
      assert content.format == :plain
    end

    test "image builder creates valid content" do
      data = Base.encode64("fake image data")
      content = Builders.image(data, "image/png")

      assert content.type == :image
      assert content.data == data
      assert content.mime_type == "image/png"
    end

    test "audio builder creates valid content" do
      data = Base.encode64("fake audio data")
      content = Builders.audio(data, "audio/wav")

      assert content.type == :audio
      assert content.data == data
      assert content.mime_type == "audio/wav"
    end

    test "resource builder creates valid content" do
      content = Builders.resource("file://test.txt")

      assert content.type == :resource
      assert content.resource.uri == "file://test.txt"
    end

    test "annotation builder creates valid content" do
      content = Builders.annotation("sentiment")

      assert content.type == :annotation
      assert content.annotation.type == "sentiment"
    end
  end

  describe "file-based builders" do
    setup do
      # Create temporary test files
      test_dir = System.tmp_dir!() |> Path.join("content_test")
      File.mkdir_p!(test_dir)

      text_file = Path.join(test_dir, "test.txt")
      File.write!(text_file, "Hello, world!")

      md_file = Path.join(test_dir, "test.md")
      File.write!(md_file, "# Hello Markdown")

      js_file = Path.join(test_dir, "test.js")
      File.write!(js_file, "console.log('hello');")

      # Create a small PNG image (1x1 pixel)
      png_data =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        )

      png_file = Path.join(test_dir, "test.png")
      File.write!(png_file, png_data)

      on_exit(fn -> File.rm_rf!(test_dir) end)

      %{
        test_dir: test_dir,
        text_file: text_file,
        md_file: md_file,
        js_file: js_file,
        png_file: png_file
      }
    end

    test "text_from_file detects format and creates content", %{
      text_file: text_file,
      md_file: md_file,
      js_file: js_file
    } do
      # Plain text file
      text_content = Builders.text_from_file(text_file)
      assert text_content.type == :text
      assert text_content.text == "Hello, world!"
      assert text_content.format == :plain

      # Markdown file
      md_content = Builders.text_from_file(md_file)
      assert md_content.format == :markdown
      assert md_content.text == "# Hello Markdown"

      # JavaScript file
      js_content = Builders.text_from_file(js_file)
      assert js_content.format == :code
      assert js_content.language == "javascript"
      assert js_content.text == "console.log('hello');"
    end

    test "from_file auto-detects content type", %{text_file: text_file, png_file: png_file} do
      # Text file
      text_content = Builders.from_file(text_file)
      assert text_content.type == :text
      assert text_content.text == "Hello, world!"

      # Image file
      image_content = Builders.from_file(png_file)
      assert image_content.type == :image
      assert image_content.mime_type == "image/png"
      assert is_binary(image_content.data)
    end

    test "image_from_file creates image content", %{png_file: png_file} do
      image_content = Builders.image_from_file(png_file)

      assert image_content.type == :image
      assert image_content.mime_type == "image/png"
      assert is_binary(image_content.data)
    end

    test "handles non-existent files" do
      result = Builders.from_file("/nonexistent/file.txt")
      assert {:error, _} = result
    end

    test "handles file size limits" do
      large_file = System.tmp_dir!() |> Path.join("large.txt")
      File.write!(large_file, String.duplicate("a", 1000))

      # Should succeed with default limit
      content = Builders.text_from_file(large_file)
      assert content.type == :text

      # Should fail with small limit
      result = Builders.from_file(large_file, max_size: 10)
      assert {:error, _} = result

      File.rm!(large_file)
    end
  end

  describe "chainable modifiers" do
    test "as_markdown modifier" do
      content = Builders.text("# Header") |> Builders.as_markdown()

      assert content.format == :markdown
      assert content.text == "# Header"
    end

    test "as_code modifier" do
      content = Builders.text("console.log()") |> Builders.as_code("javascript")

      assert content.format == :code
      assert content.language == "javascript"
    end

    test "as_html modifier" do
      content = Builders.text("<p>Hello</p>") |> Builders.as_html()

      assert content.format == :html
    end

    test "with_metadata modifier" do
      content =
        Builders.text("Hello")
        |> Builders.with_metadata(%{author: "test", version: 1})

      assert content.metadata == %{author: "test", version: 1}
    end

    test "with_alt_text modifier for images" do
      data = Base.encode64("fake image")

      content =
        Builders.image(data, "image/png")
        |> Builders.with_alt_text("Test image")

      assert content.alt_text == "Test image"
    end

    test "with_dimensions modifier for images" do
      data = Base.encode64("fake image")

      content =
        Builders.image(data, "image/png")
        |> Builders.with_dimensions(800, 600)

      assert content.width == 800
      assert content.height == 600
    end

    test "with_transcript modifier for audio" do
      data = Base.encode64("fake audio")

      content =
        Builders.audio(data, "audio/wav")
        |> Builders.with_transcript("Hello world")

      assert content.transcript == "Hello world"
    end

    test "with_duration modifier for audio" do
      data = Base.encode64("fake audio")

      content =
        Builders.audio(data, "audio/wav")
        |> Builders.with_duration(10.5)

      assert content.duration == 10.5
    end

    test "with_confidence modifier for annotations" do
      content =
        Builders.annotation("sentiment")
        |> Builders.with_confidence(0.95)

      assert content.annotation.confidence == 0.95
    end

    test "chaining multiple modifiers" do
      content =
        Builders.text("# Hello World")
        |> Builders.as_markdown()
        |> Builders.with_metadata(%{author: "test", lang: "en"})

      assert content.format == :markdown
      assert content.metadata.author == "test"
      assert content.metadata.lang == "en"
    end
  end

  describe "batch operations" do
    test "batch creates multiple content items" do
      contents =
        Builders.batch([
          Builders.text("First"),
          Builders.text("Second"),
          fn -> Builders.text("Third") end
        ])

      assert length(contents) == 3
      assert Enum.at(contents, 0).text == "First"
      assert Enum.at(contents, 1).text == "Second"
      assert Enum.at(contents, 2).text == "Third"
    end

    test "batch filters out errors" do
      contents =
        Builders.batch([
          Builders.text("Valid"),
          {:error, "Invalid"},
          Builders.text("Also valid")
        ])

      assert length(contents) == 2
      assert Enum.at(contents, 0).text == "Valid"
      assert Enum.at(contents, 1).text == "Also valid"
    end

    test "batch handles function errors gracefully" do
      contents =
        Builders.batch([
          Builders.text("Valid"),
          fn -> raise "Error" end,
          Builders.text("Also valid")
        ])

      assert length(contents) == 2
      assert Enum.at(contents, 0).text == "Valid"
      assert Enum.at(contents, 1).text == "Also valid"
    end
  end

  describe "template system" do
    test "from_template substitutes variables" do
      template = Builders.text("Hello, {{name}}! Your score is {{score}}.")
      content = Builders.from_template(template, %{name: "Alice", score: 95})

      assert content.text == "Hello, Alice! Your score is 95."
      assert content.format == template.format
    end

    test "from_template handles missing variables" do
      template = Builders.text("Hello, {{name}}! Missing: {{missing}}")
      content = Builders.from_template(template, %{name: "Bob"})

      assert content.text == "Hello, Bob! Missing: {{missing}}"
    end

    test "from_template preserves other properties" do
      template =
        Builders.text("{{greeting}}",
          format: :markdown,
          metadata: %{template: true}
        )

      content = Builders.from_template(template, %{greeting: "# Hello"})

      assert content.text == "# Hello"
      assert content.format == :markdown
      assert content.metadata == %{template: true}
    end
  end

  describe "collection operations" do
    test "collection adds shared metadata" do
      contents = [
        Builders.text("First"),
        Builders.text("Second")
      ]

      collection =
        Builders.collection(contents, %{
          conversation_id: "abc123",
          timestamp: "2024-01-01"
        })

      assert length(collection) == 2

      Enum.each(collection, fn content ->
        assert content.metadata.conversation_id == "abc123"
        assert content.metadata.timestamp == "2024-01-01"
      end)
    end

    test "collection merges with existing metadata" do
      content_with_meta = Builders.text("Hello", metadata: %{author: "user"})

      collection = Builders.collection([content_with_meta], %{session: "xyz"})

      result = Enum.at(collection, 0)
      assert result.metadata.author == "user"
      assert result.metadata.session == "xyz"
    end
  end

  describe "validation and transformation" do
    test "validate_all checks multiple content items" do
      valid_contents = [
        Builders.text("Hello"),
        Builders.image(Base.encode64("data"), "image/png")
      ]

      assert Builders.validate_all(valid_contents) == :ok

      invalid_contents = [
        Builders.text("Hello"),
        # Invalid content
        %{type: :text, text: nil}
      ]

      assert {:error, errors} = Builders.validate_all(invalid_contents)
      assert length(errors) == 1
    end

    test "transform applies function to content" do
      content = Builders.text("Hello")

      {:ok, transformed} =
        Builders.transform(content, fn c ->
          Builders.with_metadata(c, %{transformed: true})
        end)

      assert transformed.metadata.transformed == true
    end

    test "transform handles errors gracefully" do
      content = Builders.text("Hello")

      result =
        Builders.transform(content, fn _c ->
          raise "Transform error"
        end)

      assert {:error, _} = result
    end

    test "filter_by_type filters content by type" do
      contents = [
        Builders.text("Hello"),
        Builders.image(Base.encode64("data"), "image/png"),
        Builders.text("World"),
        Builders.annotation("test")
      ]

      text_only = Builders.filter_by_type(contents, :text)
      assert length(text_only) == 2
      assert Enum.all?(text_only, &(&1.type == :text))

      media_content = Builders.filter_by_type(contents, [:image, :audio])
      assert length(media_content) == 1
      assert Enum.at(media_content, 0).type == :image
    end
  end

  describe "utility functions" do
    test "extract_text extracts text from various content types" do
      text_content = Builders.text("Hello world")
      assert Builders.extract_text(text_content) == "Hello world"

      image_content = Builders.image("data", "image/png", alt_text: "Image alt text")
      assert Builders.extract_text(image_content) == "Image alt text"

      audio_content = Builders.audio("data", "audio/wav", transcript: "Audio transcript")
      assert Builders.extract_text(audio_content) == "Audio transcript"

      resource_content = Builders.resource("file://test.txt", text: "Resource text")
      assert Builders.extract_text(resource_content) == "Resource text"

      annotation_content = Builders.annotation("test", text: "Annotation text")
      assert Builders.extract_text(annotation_content) == "Annotation text"
    end

    test "extract_text handles missing text" do
      image_without_alt = Builders.image("data", "image/png")
      assert Builders.extract_text(image_without_alt) == nil

      audio_without_transcript = Builders.audio("data", "audio/wav")
      assert Builders.extract_text(audio_without_transcript) == nil
    end
  end

  describe "edge cases" do
    test "handles empty strings" do
      content = Builders.text("")
      assert content.text == ""
      assert Protocol.validate(content) == :ok
    end

    test "handles large content" do
      large_text = String.duplicate("a", 10_000)
      content = Builders.text(large_text)
      assert content.text == large_text
      assert Protocol.validate(content) == :ok
    end

    test "handles unicode content" do
      unicode_text = "Hello 🌍 世界 👋"
      content = Builders.text(unicode_text)
      assert content.text == unicode_text
      assert Protocol.validate(content) == :ok
    end

    test "metadata merging preserves existing values" do
      content = Builders.text("Hello", metadata: %{a: 1, b: 2})
      updated = Builders.with_metadata(content, %{b: 3, c: 4})

      assert updated.metadata == %{a: 1, b: 3, c: 4}
    end
  end
end
