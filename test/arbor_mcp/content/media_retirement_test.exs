defmodule Arbor.MCP.Content.MediaRetirementTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.{Builders, Protocol, Sanitizer, Transformer}

  test "removed transformations reject the complete pipeline before custom effects" do
    content = Protocol.text("  retained text  ")

    custom =
      {:custom,
       fn value ->
         send(self(), :retired_pipeline_ran)
         value
       end}

    for operation <- [:convert_encoding, :compress_images, :resize_images, :generate_thumbnails],
        form <- [operation, {operation, "private-value"}] do
      assert {:error, "Media and encoding transformation operations were removed"} =
               Transformer.transform(content, [custom, form])

      assert {:error, "Media and encoding transformation operations were removed"} =
               Transformer.transform_with_validation(content, [custom, form])

      refute_receive :retired_pipeline_ran, 0
    end

    assert {:ok, %{text: "retained text"}} =
             Transformer.transform(content, [:normalize_whitespace])
  end

  test "removed sanitizations reject content and text pipelines before custom effects" do
    content = Protocol.text("<retained>", metadata: %{application: "retained"})

    custom =
      {:custom,
       fn value ->
         send(self(), :retired_pipeline_ran)
         value
       end}

    for operation <- [:remove_metadata, :compress_media],
        form <- [operation, {operation, "private-value"}] do
      assert_raise ArgumentError, "Metadata and media sanitization operations were removed", fn ->
        Sanitizer.sanitize(content, [custom, form])
      end

      assert_raise ArgumentError, "Metadata and media sanitization operations were removed", fn ->
        Sanitizer.sanitize_text("<retained>", [custom, form])
      end

      refute_receive :retired_pipeline_ran, 0
    end

    assert %{text: "&lt;retained&gt;", metadata: %{application: "retained"}} =
             Sanitizer.sanitize(content, [:html_escape])

    assert Sanitizer.sanitize_text("<retained>", [:html_escape]) == "&lt;retained&gt;"
  end

  test "removed file options reject before using the file path" do
    for operation <- [:from_file, :image_from_file, :audio_from_file, :text_from_file],
        option <- [:auto_resize, :quality],
        value <- [nil, false, "private-value"] do
      assert {:error, "Media processing file options were removed; process media before loading"} =
               apply(Builders, operation, [:invalid_file_path, [{option, value}]])
    end
  end

  test "retained file loading preserves bytes, metadata, size and MIME restrictions" do
    directory =
      Path.join(System.tmp_dir!(), "arbor-media-retirement-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "source.png")
    bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
    File.write!(path, bytes)

    assert %{type: :image, data: encoded, mime_type: "image/png", metadata: %{source: "app"}} =
             Builders.from_file(path,
               max_size: byte_size(bytes),
               mime_types: ["image/png"],
               metadata: %{source: "app"}
             )

    assert Base.decode64!(encoded) == bytes

    assert {:error, "File MIME type is not allowed"} =
             Builders.from_file(path, mime_types: ["audio/wav"])

    assert {:error, "File MIME type is not allowed"} = Builders.from_file(path, mime_types: [])

    assert {:error, "Invalid file MIME types option"} =
             Builders.from_file(path, mime_types: :invalid)

    assert {:error, "File size exceeds maximum of 7 bytes"} =
             Builders.from_file(path, max_size: byte_size(bytes) - 1)
  end
end
