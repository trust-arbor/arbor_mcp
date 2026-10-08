defmodule Arbor.MCP.Content.Protocol do
  @moduledoc """
  Content protocol for ArborMCP - type-safe content handling system.

  This module defines the core protocol and types for handling different
  content types in MCP messages, providing a unified interface for text,
  images, audio, and embedded resources.

  ## Content Types

  - **Text**: Plain text, markdown, code, etc.
  - **Image**: Base64-encoded images with metadata
  - **Audio**: Base64-encoded audio with metadata
  - **Resource**: Embedded resource references
  - **Annotation**: Metadata annotations for content

  ## Design Principles

  1. **Type Safety**: All content has compile-time type checking
  2. **Extensibility**: Easy to add new content types
  3. **Validation**: Built-in validation for content structure
  4. **Performance**: Efficient serialization/deserialization
  5. **Developer Experience**: Intuitive constructors and builders
  """

  @typedoc "Base content protocol for all content types"
  @type content :: text() | image() | audio() | resource() | annotation()

  @typedoc "Text content with optional formatting"
  @type text :: %{
          type: :text,
          text: String.t(),
          format: :plain | :markdown | :code | :html,
          language: String.t() | nil,
          metadata: map()
        }

  @typedoc "Image content with base64 data and metadata"
  @type image :: %{
          type: :image,
          data: String.t(),
          mime_type: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          alt_text: String.t() | nil,
          metadata: map()
        }

  @typedoc "Audio content with base64 data and metadata"
  @type audio :: %{
          type: :audio,
          data: String.t(),
          mime_type: String.t(),
          duration: float() | nil,
          transcript: String.t() | nil,
          metadata: map()
        }

  @typedoc "Resource reference content"
  @type resource :: %{
          type: :resource,
          resource: %{
            uri: String.t(),
            text: String.t() | nil,
            mime_type: String.t() | nil
          },
          metadata: map()
        }

  @typedoc "Annotation content for metadata"
  @type annotation :: %{
          type: :annotation,
          annotation: %{
            type: String.t(),
            confidence: float() | nil,
            text: String.t() | nil
          },
          metadata: map()
        }

  @typedoc "Content validation result"
  @type validation_result :: :ok | {:error, String.t()}

  @typedoc "Content serialization options"
  @type serialize_opts :: [
          format: :mcp | :json | :compact,
          validate: boolean(),
          include_metadata: boolean()
        ]

  @doc """
  Creates new text content.

  ## Examples

      iex> Arbor.MCP.Content.Protocol.text("Hello, world!")
      %{type: :text, text: "Hello, world!", format: :plain, language: nil, metadata: %{}}

      iex> Arbor.MCP.Content.Protocol.text("# Header", format: :markdown)
      %{type: :text, text: "# Header", format: :markdown, language: nil, metadata: %{}}

      iex> Arbor.MCP.Content.Protocol.text("console.log('hi')", format: :code, language: "javascript")
      %{type: :text, text: "console.log('hi')", format: :code, language: "javascript", metadata: %{}}
  """
  @spec text(String.t(), keyword()) :: text()
  def text(content, opts \\ []) when is_binary(content) do
    %{
      type: :text,
      text: content,
      format: Keyword.get(opts, :format, :plain),
      language: Keyword.get(opts, :language),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates new image content from base64 data.

  ## Examples

      iex> data = Base.encode64("fake image data")
      iex> Arbor.MCP.Content.Protocol.image(data, "image/png")
      %{type: :image, data: data, mime_type: "image/png", width: nil, height: nil, alt_text: nil, metadata: %{}}
  """
  @spec image(String.t(), String.t(), keyword()) :: image()
  def image(base64_data, mime_type, opts \\ [])
      when is_binary(base64_data) and is_binary(mime_type) do
    %{
      type: :image,
      data: base64_data,
      mime_type: mime_type,
      width: Keyword.get(opts, :width),
      height: Keyword.get(opts, :height),
      alt_text: Keyword.get(opts, :alt_text),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates new audio content from base64 data.

  ## Examples

      iex> data = Base.encode64("fake audio data")
      iex> Arbor.MCP.Content.Protocol.audio(data, "audio/wav")
      %{type: :audio, data: data, mime_type: "audio/wav", duration: nil, transcript: nil, metadata: %{}}
  """
  @spec audio(String.t(), String.t(), keyword()) :: audio()
  def audio(base64_data, mime_type, opts \\ [])
      when is_binary(base64_data) and is_binary(mime_type) do
    %{
      type: :audio,
      data: base64_data,
      mime_type: mime_type,
      duration: Keyword.get(opts, :duration),
      transcript: Keyword.get(opts, :transcript),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates new resource reference content.

  ## Examples

      iex> Arbor.MCP.Content.Protocol.resource("file://data.txt")
      %{type: :resource, resource: %{uri: "file://data.txt", text: nil, mime_type: nil}, metadata: %{}}

      iex> Arbor.MCP.Content.Protocol.resource("file://doc.pdf", text: "Important document", mime_type: "application/pdf")
      %{type: :resource, resource: %{uri: "file://doc.pdf", text: "Important document", mime_type: "application/pdf"}, metadata: %{}}
  """
  @spec resource(String.t(), keyword()) :: resource()
  def resource(uri, opts \\ []) when is_binary(uri) do
    %{
      type: :resource,
      resource: %{
        uri: uri,
        text: Keyword.get(opts, :text),
        mime_type: Keyword.get(opts, :mime_type)
      },
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates new annotation content.

  ## Examples

      iex> Arbor.MCP.Content.Protocol.annotation("sentiment", confidence: 0.95, text: "positive")
      %{type: :annotation, annotation: %{type: "sentiment", confidence: 0.95, text: "positive"}, metadata: %{}}
  """
  @spec annotation(String.t(), keyword()) :: annotation()
  def annotation(annotation_type, opts \\ []) when is_binary(annotation_type) do
    %{
      type: :annotation,
      annotation: %{
        type: annotation_type,
        confidence: Keyword.get(opts, :confidence),
        text: Keyword.get(opts, :text)
      },
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Validates content structure and data integrity.

  ## Examples

      iex> content = Arbor.MCP.Content.Protocol.text("Hello")
      iex> Arbor.MCP.Content.Protocol.validate(content)
      :ok

      iex> invalid = %{type: :text, text: nil}
      iex> Arbor.MCP.Content.Protocol.validate(invalid)
      {:error, "Text content must have non-nil text field"}
  """
  @spec validate(content()) :: validation_result()
  def validate(%{type: :text, text: text} = content) when is_binary(text) do
    with :ok <- validate_format(content.format),
         :ok <- validate_language(content.language) do
      validate_metadata(content.metadata)
    end
  end

  def validate(%{type: :text}) do
    {:error, "Text content must have non-nil text field"}
  end

  def validate(%{type: :image, data: data, mime_type: mime_type} = content)
      when is_binary(data) and is_binary(mime_type) do
    with :ok <- validate_base64(data),
         :ok <- validate_image_mime_type(mime_type),
         :ok <- validate_image_dimensions(content) do
      validate_metadata(content.metadata)
    end
  end

  def validate(%{type: :image}) do
    {:error, "Image content must have data and mime_type fields"}
  end

  def validate(%{type: :audio, data: data, mime_type: mime_type} = content)
      when is_binary(data) and is_binary(mime_type) do
    with :ok <- validate_base64(data),
         :ok <- validate_audio_mime_type(mime_type),
         :ok <- validate_audio_duration(content.duration) do
      validate_metadata(content.metadata)
    end
  end

  def validate(%{type: :audio}) do
    {:error, "Audio content must have data and mime_type fields"}
  end

  def validate(%{type: :resource, resource: %{uri: uri}} = content) when is_binary(uri) do
    with :ok <- validate_uri(uri) do
      validate_metadata(content.metadata)
    end
  end

  def validate(%{type: :resource}) do
    {:error, "Resource content must have uri field"}
  end

  def validate(%{type: :annotation, annotation: %{type: annotation_type}} = content)
      when is_binary(annotation_type) do
    with :ok <- validate_annotation_confidence(content.annotation.confidence) do
      validate_metadata(content.metadata)
    end
  end

  def validate(%{type: :annotation}) do
    {:error, "Annotation content must have type field"}
  end

  def validate(_) do
    {:error, "Unknown content type or invalid structure"}
  end

  @doc """
  Serializes content to MCP protocol format.

  ## Examples

      iex> content = Arbor.MCP.Content.Protocol.text("Hello")
      iex> Arbor.MCP.Content.Protocol.serialize(content)
      %{"type" => "text", "text" => "Hello"}

      iex> content2 = Arbor.MCP.Content.Protocol.text("Hello")
      iex> Arbor.MCP.Content.Protocol.serialize(content2, format: :compact)
      %{"type" => "text", "text" => "Hello"}
  """
  @spec serialize(content(), serialize_opts()) :: map()
  def serialize(content, opts \\ [])

  def serialize(%{type: :text} = content, opts) do
    base = %{"type" => "text", "text" => content.text}

    base
    |> maybe_add_format_field(content.format)
    |> maybe_add_field("language", content.language, nil)
    |> maybe_add_metadata(content.metadata, opts)
  end

  def serialize(%{type: :image} = content, opts) do
    base = %{
      "type" => "image",
      "data" => content.data,
      "mimeType" => content.mime_type
    }

    base
    |> maybe_add_field("width", content.width, nil)
    |> maybe_add_field("height", content.height, nil)
    |> maybe_add_field("altText", content.alt_text, nil)
    |> maybe_add_metadata(content.metadata, opts)
  end

  def serialize(%{type: :audio} = content, opts) do
    base = %{
      "type" => "audio",
      "data" => content.data,
      "mimeType" => content.mime_type
    }

    base
    |> maybe_add_field("duration", content.duration, nil)
    |> maybe_add_field("transcript", content.transcript, nil)
    |> maybe_add_metadata(content.metadata, opts)
  end

  def serialize(%{type: :resource} = content, opts) do
    base = %{"type" => "resource", "resource" => serialize_resource_ref(content.resource)}
    maybe_add_metadata(base, content.metadata, opts)
  end

  def serialize(%{type: :annotation} = content, opts) do
    base = %{"type" => "annotation", "annotation" => serialize_annotation_ref(content.annotation)}
    maybe_add_metadata(base, content.metadata, opts)
  end

  @doc """
  Deserializes content from MCP protocol format.

  ## Examples

      iex> data = %{"type" => "text", "text" => "Hello"}
      iex> Arbor.MCP.Content.Protocol.deserialize(data)
      {:ok, %{type: :text, text: "Hello", format: :plain, language: nil, metadata: %{}}}
  """
  @spec deserialize(map()) :: {:ok, content()} | {:error, String.t()}
  def deserialize(%{"type" => "text", "text" => text} = data) when is_binary(text) do
    content = %{
      type: :text,
      text: text,
      format: parse_format(data["format"]),
      language: data["language"],
      metadata: Map.get(data, "metadata", %{})
    }

    case validate(content) do
      :ok -> {:ok, content}
      error -> error
    end
  end

  def deserialize(%{"type" => "image", "data" => data, "mimeType" => mime_type} = map)
      when is_binary(data) and is_binary(mime_type) do
    content = %{
      type: :image,
      data: data,
      mime_type: mime_type,
      width: map["width"],
      height: map["height"],
      alt_text: map["altText"],
      metadata: Map.get(map, "metadata", %{})
    }

    case validate(content) do
      :ok -> {:ok, content}
      error -> error
    end
  end

  def deserialize(%{"type" => "audio", "data" => data, "mimeType" => mime_type} = map)
      when is_binary(data) and is_binary(mime_type) do
    content = %{
      type: :audio,
      data: data,
      mime_type: mime_type,
      duration: map["duration"],
      transcript: map["transcript"],
      metadata: Map.get(map, "metadata", %{})
    }

    case validate(content) do
      :ok -> {:ok, content}
      error -> error
    end
  end

  def deserialize(%{"type" => "resource", "resource" => resource_data} = map)
      when is_map(resource_data) do
    case resource_data do
      %{"uri" => uri} when is_binary(uri) ->
        content = %{
          type: :resource,
          resource: %{
            uri: uri,
            text: resource_data["text"],
            mime_type: resource_data["mimeType"]
          },
          metadata: Map.get(map, "metadata", %{})
        }

        case validate(content) do
          :ok -> {:ok, content}
          error -> error
        end

      _ ->
        {:error, "Resource must have uri field"}
    end
  end

  def deserialize(%{"type" => "annotation", "annotation" => annotation_data} = map)
      when is_map(annotation_data) do
    case annotation_data do
      %{"type" => annotation_type} when is_binary(annotation_type) ->
        content = %{
          type: :annotation,
          annotation: %{
            type: annotation_type,
            confidence: annotation_data["confidence"],
            text: annotation_data["text"]
          },
          metadata: Map.get(map, "metadata", %{})
        }

        case validate(content) do
          :ok -> {:ok, content}
          error -> error
        end

      _ ->
        {:error, "Annotation must have type field"}
    end
  end

  def deserialize(%{"type" => type}) do
    {:error, "Unknown content type: #{type}"}
  end

  def deserialize(_) do
    {:error, "Invalid content structure - missing type field"}
  end

  @doc """
  Gets the content type for given content.

  ## Examples

      iex> content = Arbor.MCP.Content.Protocol.text("Hello")
      iex> Arbor.MCP.Content.Protocol.content_type(content)
      :text
  """
  @spec content_type(content()) :: atom()
  def content_type(%{type: type}), do: type

  @doc """
  Checks if content is of a specific type.

  ## Examples

      iex> content = Arbor.MCP.Content.Protocol.text("Hello")
      iex> Arbor.MCP.Content.Protocol.content_type?(content, :text)
      true
      iex> Arbor.MCP.Content.Protocol.content_type?(content, :image)
      false
  """
  @spec content_type?(content(), atom()) :: boolean()
  def content_type?(content, type), do: content_type(content) == type

  # Private helper functions

  defp validate_format(format) when format in [:plain, :markdown, :code, :html], do: :ok
  defp validate_format(nil), do: :ok
  defp validate_format(_), do: {:error, "Invalid text format"}

  defp validate_language(language) when is_binary(language) or is_nil(language), do: :ok
  defp validate_language(_), do: {:error, "Language must be string or nil"}

  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(_), do: {:error, "Metadata must be a map"}

  defp validate_base64(data) do
    case Base.decode64(data) do
      {:ok, _} -> :ok
      :error -> {:error, "Invalid base64 data"}
    end
  end

  defp validate_image_mime_type("image/" <> _), do: :ok
  defp validate_image_mime_type(_), do: {:error, "Invalid image MIME type"}

  defp validate_audio_mime_type("audio/" <> _), do: :ok
  defp validate_audio_mime_type(_), do: {:error, "Invalid audio MIME type"}

  defp validate_image_dimensions(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: :ok

  defp validate_image_dimensions(%{width: nil, height: nil}), do: :ok
  defp validate_image_dimensions(_), do: {:error, "Invalid image dimensions"}

  defp validate_audio_duration(duration) when is_float(duration) and duration > 0, do: :ok
  defp validate_audio_duration(nil), do: :ok
  defp validate_audio_duration(_), do: {:error, "Invalid audio duration"}

  defp validate_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when is_binary(scheme) -> :ok
      _ -> {:error, "Invalid URI format"}
    end
  end

  defp validate_annotation_confidence(confidence)
       when is_float(confidence) and confidence >= 0.0 and confidence <= 1.0,
       do: :ok

  defp validate_annotation_confidence(nil), do: :ok

  defp validate_annotation_confidence(_),
    do: {:error, "Confidence must be float between 0.0 and 1.0"}

  defp maybe_add_field(map, _key, default_value, default_value), do: map
  defp maybe_add_field(map, key, value, _default), do: Map.put(map, key, value)

  # Don't include default format
  defp maybe_add_format_field(map, :plain), do: map
  defp maybe_add_format_field(map, format), do: Map.put(map, "format", Atom.to_string(format))

  defp maybe_add_metadata(map, metadata, opts) do
    if Keyword.get(opts, :include_metadata, true) and map_size(metadata) > 0 do
      Map.put(map, "metadata", metadata)
    else
      map
    end
  end

  defp serialize_resource_ref(%{uri: uri} = resource) do
    base = %{"uri" => uri}

    base
    |> maybe_add_field("text", resource.text, nil)
    |> maybe_add_field("mimeType", resource.mime_type, nil)
  end

  defp serialize_annotation_ref(%{type: type} = annotation) do
    base = %{"type" => type}

    base
    |> maybe_add_field("confidence", annotation.confidence, nil)
    |> maybe_add_field("text", annotation.text, nil)
  end

  defp parse_format("plain"), do: :plain
  defp parse_format("markdown"), do: :markdown
  defp parse_format("code"), do: :code
  defp parse_format("html"), do: :html
  defp parse_format(nil), do: :plain
  defp parse_format(_), do: :plain
end
