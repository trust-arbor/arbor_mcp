defmodule Arbor.MCP.Content.ProtocolPropertyTest do
  use ExUnit.Case, async: true
  use PropCheck

  alias Arbor.MCP.Content.Protocol

  @moduletag :property

  # Property-based test generators

  def text_format_gen do
    oneof([:plain, :markdown, :code, :html])
  end

  def non_empty_string_gen do
    such_that(s <- utf8(), when: String.length(s) > 0)
  end

  def language_code_gen do
    oneof([
      "en",
      "es",
      "fr",
      "de",
      "ja",
      "zh",
      "ko",
      "pt",
      "ru",
      "ar"
    ])
  end

  def metadata_gen do
    # Generate simple, serializable metadata with non-empty keys
    map(
      oneof([non_empty_string_gen(), atom()]),
      oneof([non_empty_string_gen(), integer(), float(), boolean()])
    )
  end

  def valid_base64_gen do
    let data <- non_empty(binary()) do
      Base.encode64(data)
    end
  end

  def image_mime_type_gen do
    oneof([
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/webp",
      "image/svg+xml",
      "image/bmp",
      "image/tiff"
    ])
  end

  def audio_mime_type_gen do
    oneof([
      "audio/wav",
      "audio/mp3",
      "audio/ogg",
      "audio/flac",
      "audio/m4a",
      "audio/webm",
      "audio/aac"
    ])
  end

  def uri_gen do
    let {scheme, path} <- {oneof(["http", "https", "file", "ftp"]), non_empty_string_gen()} do
      "#{scheme}://example.com/#{path}"
    end
  end

  def positive_float_gen do
    such_that(f <- float(), when: f > 0.0)
  end

  def confidence_gen do
    oneof([
      0.0,
      0.1,
      0.25,
      0.5,
      0.75,
      0.9,
      1.0
    ])
  end

  def text_content_gen do
    let {text, format, language, metadata} <- {
          non_empty_string_gen(),
          text_format_gen(),
          oneof([nil, language_code_gen()]),
          metadata_gen()
        } do
      Protocol.text(text,
        format: format,
        language: language,
        metadata: metadata
      )
    end
  end

  def image_content_gen do
    let {data, mime_type, dimensions, alt_text, metadata} <- {
          valid_base64_gen(),
          image_mime_type_gen(),
          # Either both dimensions or neither (to satisfy validation)
          oneof([
            {nil, nil},
            let {w, h} <- {pos_integer(), pos_integer()} do
              {w, h}
            end
          ]),
          oneof([nil, non_empty_string_gen()]),
          metadata_gen()
        } do
      {width, height} = dimensions

      Protocol.image(data, mime_type,
        width: width,
        height: height,
        alt_text: alt_text,
        metadata: metadata
      )
    end
  end

  def audio_content_gen do
    let {data, mime_type, duration, transcript, metadata} <- {
          valid_base64_gen(),
          audio_mime_type_gen(),
          oneof([nil, positive_float_gen()]),
          oneof([nil, non_empty_string_gen()]),
          metadata_gen()
        } do
      Protocol.audio(data, mime_type,
        duration: duration,
        transcript: transcript,
        metadata: metadata
      )
    end
  end

  def resource_content_gen do
    let {uri, text, mime_type, metadata} <- {
          uri_gen(),
          oneof([nil, non_empty_string_gen()]),
          oneof([nil, non_empty_string_gen()]),
          metadata_gen()
        } do
      Protocol.resource(uri,
        text: text,
        mime_type: mime_type,
        metadata: metadata
      )
    end
  end

  def annotation_content_gen do
    let {type, confidence, text, metadata} <- {
          non_empty_string_gen(),
          oneof([nil, confidence_gen()]),
          oneof([nil, non_empty_string_gen()]),
          metadata_gen()
        } do
      Protocol.annotation(type,
        confidence: confidence,
        text: text,
        metadata: metadata
      )
    end
  end

  def content_gen do
    oneof([
      text_content_gen(),
      image_content_gen(),
      audio_content_gen(),
      resource_content_gen(),
      annotation_content_gen()
    ])
  end

  # Property tests

  property "generated text content is always valid" do
    forall content <- text_content_gen() do
      Protocol.validate(content) == :ok
    end
  end

  property "generated image content is always valid" do
    forall content <- image_content_gen() do
      Protocol.validate(content) == :ok
    end
  end

  property "generated audio content is always valid" do
    forall content <- audio_content_gen() do
      Protocol.validate(content) == :ok
    end
  end

  property "generated resource content is always valid" do
    forall content <- resource_content_gen() do
      Protocol.validate(content) == :ok
    end
  end

  property "generated annotation content is always valid" do
    forall content <- annotation_content_gen() do
      Protocol.validate(content) == :ok
    end
  end

  property "serialization roundtrip preserves content" do
    forall content <- content_gen() do
      serialized = Protocol.serialize(content)
      {:ok, deserialized} = Protocol.deserialize(serialized)

      # Content should be semantically equivalent after roundtrip
      content.type == deserialized.type and
        validate_content_equivalence(content, deserialized)
    end
  end

  property "serialization with metadata inclusion preserves metadata" do
    forall content <- content_gen() do
      # Only test when metadata is non-empty and contains simple values
      if map_size(content.metadata) > 0 and serializable_metadata?(content.metadata) do
        try do
          serialized = Protocol.serialize(content, include_metadata: true)

          case Protocol.deserialize(serialized) do
            {:ok, deserialized} -> content.metadata == deserialized.metadata
            {:error, _} -> false
          end
        rescue
          _ -> false
        end
      else
        true
      end
    end
  end

  property "serialization without metadata excludes metadata" do
    forall content <- content_gen() do
      serialized = Protocol.serialize(content, include_metadata: false)

      not Map.has_key?(serialized, "metadata")
    end
  end

  property "content type detection is consistent" do
    forall content <- content_gen() do
      type = Protocol.content_type(content)
      Protocol.content_type?(content, type) == true
    end
  end

  property "validation is deterministic" do
    forall content <- content_gen() do
      result1 = Protocol.validate(content)
      result2 = Protocol.validate(content)

      result1 == result2
    end
  end

  property "invalid base64 in image content fails validation" do
    forall {invalid_data, mime_type} <- {non_empty_string_gen(), image_mime_type_gen()} do
      # Ensure the string is not valid base64
      case Base.decode64(invalid_data) do
        :error ->
          content = Protocol.image(invalid_data, mime_type)
          match?({:error, _}, Protocol.validate(content))

        {:ok, _} ->
          # If it happens to be valid base64, skip this test case
          true
      end
    end
  end

  property "invalid URI in resource content fails validation" do
    forall invalid_uri <-
             such_that(
               s <- non_empty_string_gen(),
               when:
                 not String.contains?(s, "://") and
                   not match?(%URI{scheme: scheme} when is_binary(scheme), URI.parse(s))
             ) do
      content = Protocol.resource(invalid_uri)
      match?({:error, _}, Protocol.validate(content))
    end
  end

  property "confidence outside valid range fails annotation validation" do
    forall {type, invalid_confidence} <- {
             non_empty_string_gen(),
             # Build out-of-range values directly. Filtering float() with
             # such_that gave up with :cant_generate at small sizes, where
             # float() rarely leaves [-1.0, 1.0].
             oneof([
               let(f <- float(), do: -abs(f) - 1.0e-6),
               let(f <- float(), do: 1.0 + abs(f) + 1.0e-6)
             ])
           } do
      content = Protocol.annotation(type, confidence: invalid_confidence)
      match?({:error, _}, Protocol.validate(content))
    end
  end

  property "serialized content has correct JSON structure" do
    forall content <- content_gen() do
      serialized = Protocol.serialize(content)

      # Should be a map with string keys
      # Type should match the content type
      is_map(serialized) and
        Map.has_key?(serialized, "type") and
        is_binary(serialized["type"]) and
        serialized["type"] == Atom.to_string(content.type)
    end
  end

  property "deserialization of invalid structure returns error" do
    forall invalid_data <-
             oneof([
               # Missing type
               %{},
               # Unknown type
               %{"type" => "unknown"},
               # Missing required fields
               %{"type" => "text"},
               # Invalid data
               %{"type" => "image", "data" => "invalid"}
             ]) do
      match?({:error, _}, Protocol.deserialize(invalid_data))
    end
  end

  # Helper functions for property tests

  defp validate_content_equivalence(%{type: :text} = original, %{type: :text} = deserialized) do
    original.text == deserialized.text and
      original.format == deserialized.format and
      original.language == deserialized.language
  end

  defp validate_content_equivalence(%{type: :image} = original, %{type: :image} = deserialized) do
    original.data == deserialized.data and
      original.mime_type == deserialized.mime_type and
      original.width == deserialized.width and
      original.height == deserialized.height and
      original.alt_text == deserialized.alt_text
  end

  defp validate_content_equivalence(%{type: :audio} = original, %{type: :audio} = deserialized) do
    original.data == deserialized.data and
      original.mime_type == deserialized.mime_type and
      original.duration == deserialized.duration and
      original.transcript == deserialized.transcript
  end

  defp validate_content_equivalence(
         %{type: :resource} = original,
         %{type: :resource} = deserialized
       ) do
    original.resource.uri == deserialized.resource.uri and
      original.resource.text == deserialized.resource.text and
      original.resource.mime_type == deserialized.resource.mime_type
  end

  defp validate_content_equivalence(
         %{type: :annotation} = original,
         %{type: :annotation} = deserialized
       ) do
    original.annotation.type == deserialized.annotation.type and
      original.annotation.confidence == deserialized.annotation.confidence and
      original.annotation.text == deserialized.annotation.text
  end

  defp validate_content_equivalence(_, _), do: false

  # Helper to check if metadata contains only serializable values
  defp serializable_metadata?(metadata) when is_map(metadata) do
    Enum.all?(metadata, fn {key, value} ->
      serializable_key?(key) and serializable_value?(value)
    end)
  end

  defp serializable_key?(key) when is_binary(key) and byte_size(key) > 0, do: true
  defp serializable_key?(key) when is_atom(key), do: true
  defp serializable_key?(_), do: false

  defp serializable_value?(value) when is_binary(value) and byte_size(value) > 0, do: true
  defp serializable_value?(value) when is_integer(value), do: true
  defp serializable_value?(value) when is_float(value), do: true
  defp serializable_value?(value) when is_boolean(value), do: true
  defp serializable_value?(nil), do: true
  defp serializable_value?(_), do: false
end
