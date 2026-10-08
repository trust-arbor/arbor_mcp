defmodule Arbor.MCP.Content.Builders do
  @moduledoc """
  Smart constructors and builder patterns for ArborMCP content creation.

  This module provides an intuitive, chainable API for building complex content
  structures with validation, type safety, and helpful defaults.

  ## Features

  - **Chainable API**: Fluent interface for building content
  - **Type Safety**: Compile-time type checking and validation
  - **Smart Defaults**: Sensible defaults for common use cases
  - **File Integration**: Direct file loading with automatic type detection
  - **Batch Operations**: Efficient creation of multiple content items
  - **Template System**: Reusable content templates

  ## Usage

      use Arbor.MCP.Content.Builders

      # Simple text content
      content = text("Hello, world!")

      # Chainable building
      content = text("# Header")
      |> as_markdown()
      |> with_metadata(%{author: "user"})

      # File-based content
      content = from_file("image.png")
      |> with_alt_text("Product screenshot")

      # Batch creation
      contents = batch([
        text("First message"),
        image_from_file("diagram.png"),
        text("Summary", format: :markdown)
      ])
  """

  alias Arbor.MCP.Content.Protocol

  @typedoc "Content builder state"
  @type builder :: %{
          content: Protocol.content() | nil,
          errors: [String.t()],
          metadata: map()
        }

  @typedoc "File processing options"
  @type file_opts :: [
          max_size: pos_integer(),
          mime_types: [String.t()]
        ]

  defmacro __using__(_opts) do
    quote do
      import Arbor.MCP.Content.Builders
      alias Arbor.MCP.Content.{Builders, Protocol}
    end
  end

  # Builder Creation Functions

  @doc """
  Creates a new text content builder.

  ## Examples

      iex> text("Hello")
      %{type: :text, text: "Hello", format: :plain, language: nil, metadata: %{}}

      iex> text("console.log('hi')", format: :code, language: "javascript")
      %{type: :text, text: "console.log('hi')", format: :code, language: "javascript", metadata: %{}}
  """
  @spec text(String.t(), keyword()) :: Protocol.text()
  def text(content, opts \\ []) do
    Protocol.text(content, opts)
  end

  @doc """
  Creates a new image content builder from base64 data.

  ## Examples

      iex> image("iVBORw0K...", "image/png")
      %{type: :image, data: "iVBORw0K...", mime_type: "image/png", ...}
  """
  @spec image(String.t(), String.t(), keyword()) :: Protocol.image()
  def image(base64_data, mime_type, opts \\ []) do
    Protocol.image(base64_data, mime_type, opts)
  end

  @doc """
  Creates a new audio content builder from base64 data.
  """
  @spec audio(String.t(), String.t(), keyword()) :: Protocol.audio()
  def audio(base64_data, mime_type, opts \\ []) do
    Protocol.audio(base64_data, mime_type, opts)
  end

  @doc """
  Creates a new resource reference builder.
  """
  @spec resource(String.t(), keyword()) :: Protocol.resource()
  def resource(uri, opts \\ []) do
    Protocol.resource(uri, opts)
  end

  @doc """
  Creates a new annotation builder.
  """
  @spec annotation(String.t(), keyword()) :: Protocol.annotation()
  def annotation(annotation_type, opts \\ []) do
    Protocol.annotation(annotation_type, opts)
  end

  # File-Based Builders

  @doc """
  Creates content from a file with automatic type detection.

  `:max_size` and `:mime_types` constrain loading. Removed `:auto_resize` and
  `:quality` options return an error before reading the file; process media in
  the application before loading it.

  ## Examples

      # Image file
      content = from_file("screenshot.png")

      # Text file
      content = from_file("README.md")

      # With options
      content = from_file("large_image.jpg", max_size: 1_000_000)
  """
  @spec from_file(String.t(), file_opts()) :: Protocol.content() | {:error, String.t()}
  def from_file(file_path, opts \\ []) do
    with :ok <- validate_file_options(opts),
         {:ok, data} <- File.read(file_path),
         {:ok, mime_type} <- detect_mime_type(file_path, data),
         :ok <- validate_file_mime(mime_type, opts),
         :ok <- validate_file_size(data, opts),
         {:ok, content} <- create_content_from_file(data, mime_type, file_path, opts) do
      content
    else
      {:error, :enoent} -> {:error, "File not found: #{file_path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates image content from a file.

  ## Examples

      content = image_from_file("photo.jpg")
      content = image_from_file("diagram.png", alt_text: "System architecture")
  """
  @spec image_from_file(String.t(), keyword()) :: Protocol.image() | {:error, String.t()}
  def image_from_file(file_path, opts \\ []) do
    case from_file(file_path, opts) do
      %{type: :image} = content -> content
      {:error, reason} -> {:error, reason}
      _ -> {:error, "File is not an image: #{file_path}"}
    end
  end

  @doc """
  Creates audio content from a file.
  """
  @spec audio_from_file(String.t(), keyword()) :: Protocol.audio() | {:error, String.t()}
  def audio_from_file(file_path, opts \\ []) do
    case from_file(file_path, opts) do
      %{type: :audio} = content -> content
      {:error, reason} -> {:error, reason}
      _ -> {:error, "File is not audio: #{file_path}"}
    end
  end

  @doc """
  Creates text content from a file with format detection.

  ## Examples

      content = text_from_file("README.md")  # Auto-detects markdown
      content = text_from_file("script.js")  # Auto-detects code with language
  """
  @spec text_from_file(String.t(), keyword()) :: Protocol.text() | {:error, String.t()}
  def text_from_file(file_path, opts \\ []) do
    with :ok <- validate_file_options(opts),
         {:ok, data} <- File.read(file_path),
         format <- detect_text_format(file_path),
         language <- detect_language(file_path) do
      base_opts = [format: format, language: language] ++ opts
      text(data, base_opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Chainable Modifiers

  @doc """
  Sets content as markdown format.

  ## Examples

      content = text("# Header") |> as_markdown()
  """
  @spec as_markdown(Protocol.text()) :: Protocol.text()
  def as_markdown(%{type: :text} = content) do
    %{content | format: :markdown}
  end

  @doc """
  Sets content as code format with optional language.

  ## Examples

      content = text("console.log()") |> as_code("javascript")
      content = text("SELECT * FROM users") |> as_code("sql")
  """
  @spec as_code(Protocol.text(), String.t() | nil) :: Protocol.text()
  def as_code(%{type: :text} = content, language \\ nil) do
    %{content | format: :code, language: language}
  end

  @doc """
  Sets content as HTML format.
  """
  @spec as_html(Protocol.text()) :: Protocol.text()
  def as_html(%{type: :text} = content) do
    %{content | format: :html}
  end

  @doc """
  Adds metadata to any content type.

  ## Examples

      content = text("Hello") |> with_metadata(%{author: "user", timestamp: DateTime.utc_now()})
  """
  @spec with_metadata(Protocol.content(), map()) :: Protocol.content()
  def with_metadata(content, metadata) when is_map(metadata) do
    %{content | metadata: Map.merge(content.metadata, metadata)}
  end

  @doc """
  Adds alt text to image content.

  ## Examples

      content = image(data, "image/png") |> with_alt_text("Product screenshot")
  """
  @spec with_alt_text(Protocol.image(), String.t()) :: Protocol.image()
  def with_alt_text(%{type: :image} = content, alt_text) when is_binary(alt_text) do
    %{content | alt_text: alt_text}
  end

  @doc """
  Sets dimensions for image content.

  ## Examples

      content = image(data, "image/png") |> with_dimensions(800, 600)
  """
  @spec with_dimensions(Protocol.image(), pos_integer(), pos_integer()) :: Protocol.image()
  def with_dimensions(%{type: :image} = content, width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    %{content | width: width, height: height}
  end

  @doc """
  Adds transcript to audio content.

  ## Examples

      content = audio(data, "audio/wav") |> with_transcript("Hello, this is a recording")
  """
  @spec with_transcript(Protocol.audio(), String.t()) :: Protocol.audio()
  def with_transcript(%{type: :audio} = content, transcript) when is_binary(transcript) do
    %{content | transcript: transcript}
  end

  @doc """
  Sets duration for audio content.

  ## Examples

      content = audio(data, "audio/wav") |> with_duration(45.5)
  """
  @spec with_duration(Protocol.audio(), float()) :: Protocol.audio()
  def with_duration(%{type: :audio} = content, duration)
      when is_float(duration) and duration > 0 do
    %{content | duration: duration}
  end

  @doc """
  Adds confidence to annotation content.

  ## Examples

      content = annotation("sentiment") |> with_confidence(0.95)
  """
  @spec with_confidence(Protocol.annotation(), float()) :: Protocol.annotation()
  def with_confidence(%{type: :annotation} = content, confidence)
      when is_float(confidence) and confidence >= 0.0 and confidence <= 1.0 do
    put_in(content, [:annotation, :confidence], confidence)
  end

  # Batch Operations

  @doc """
  Creates multiple content items efficiently.

  ## Examples

      contents = batch([
        text("First message"),
        image_from_file("chart.png"),
        text("Summary", format: :markdown)
      ])
  """
  @spec batch([(-> Protocol.content()) | Protocol.content()]) :: [Protocol.content()]
  def batch(content_specs) when is_list(content_specs) do
    content_specs
    |> Enum.map(&evaluate_content_spec/1)
    |> Enum.reject(&match?({:error, _}, &1))
  end

  @doc """
  Creates content from a template with substitutions.

  ## Examples

      template = text("Hello, {{name}}! Your score is {{score}}")
      content = from_template(template, %{name: "Alice", score: 95})
      # Results in: text("Hello, Alice! Your score is 95")
  """
  @spec from_template(Protocol.text(), map()) :: Protocol.text()
  def from_template(%{type: :text} = template, substitutions) when is_map(substitutions) do
    new_text = substitute_variables(template.text, substitutions)
    %{template | text: new_text}
  end

  @doc """
  Creates a content collection with shared metadata.

  ## Examples

      contents = collection([
        text("Message 1"),
        text("Message 2")
      ], %{conversation_id: "abc123", timestamp: DateTime.utc_now()})
  """
  @spec collection([Protocol.content()], map()) :: [Protocol.content()]
  def collection(contents, shared_metadata) when is_list(contents) and is_map(shared_metadata) do
    Enum.map(contents, &with_metadata(&1, shared_metadata))
  end

  # Validation and Transformation

  @doc """
  Validates a list of content items.

  ## Examples

      contents = [text("Hello"), image(data, "image/png")]
      case validate_all(contents) do
        :ok -> contents
        {:error, errors} -> handle_errors(errors)
      end
  """
  @spec validate_all([Protocol.content()]) :: :ok | {:error, [String.t()]}
  def validate_all(contents) when is_list(contents) do
    errors =
      contents
      |> Enum.with_index()
      |> Enum.reduce([], fn {content, index}, acc ->
        case Protocol.validate(content) do
          :ok -> acc
          {:error, reason} -> ["Item #{index}: #{reason}" | acc]
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Transforms content with a function, handling errors gracefully.

  ## Examples

      result = transform(content, fn c -> with_metadata(c, %{processed: true}) end)
  """
  @spec transform(Protocol.content(), (Protocol.content() ->
                                         Protocol.content() | {:error, String.t()})) ::
          Protocol.content() | {:error, String.t()}
  def transform(content, transformer) when is_function(transformer, 1) do
    case transformer.(content) do
      %{type: _} = new_content -> {:ok, new_content}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Transformer must return content or error tuple"}
    end
  rescue
    error -> {:error, "Transform failed: #{inspect(error)}"}
  end

  @doc """
  Filters content by type.

  ## Examples

      text_only = filter_by_type(contents, :text)
      media_content = filter_by_type(contents, [:image, :audio])
  """
  @spec filter_by_type([Protocol.content()], atom() | [atom()]) :: [Protocol.content()]
  def filter_by_type(contents, type) when is_atom(type) do
    Enum.filter(contents, &Protocol.content_type?(&1, type))
  end

  def filter_by_type(contents, types) when is_list(types) do
    Enum.filter(contents, fn content ->
      Protocol.content_type(content) in types
    end)
  end

  # Utility Functions

  @doc """
  Extracts text content from various content types.

  ## Examples

      text_content = extract_text(image_content)  # Uses alt_text
      text_content = extract_text(audio_content)  # Uses transcript
  """
  @spec extract_text(Protocol.content()) :: String.t() | nil
  def extract_text(%{type: :text, text: text}), do: text
  def extract_text(%{type: :image, alt_text: alt_text}), do: alt_text
  def extract_text(%{type: :audio, transcript: transcript}), do: transcript
  def extract_text(%{type: :resource, resource: %{text: text}}), do: text
  def extract_text(%{type: :annotation, annotation: %{text: text}}), do: text
  def extract_text(_), do: nil

  # Private Implementation

  defp evaluate_content_spec(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error -> {:error, "Content creation failed: #{inspect(error)}"}
  end

  defp evaluate_content_spec(content), do: content

  defp detect_mime_type(file_path, data) do
    # Simple MIME type detection based on file extension and magic bytes
    extension = Path.extname(file_path) |> String.downcase()

    mime_map = %{
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif" => "image/gif",
      ".webp" => "image/webp",
      ".wav" => "audio/wav",
      ".mp3" => "audio/mpeg",
      ".ogg" => "audio/ogg",
      ".txt" => "text/plain",
      ".md" => "text/markdown",
      ".html" => "text/html",
      ".json" => "application/json"
    }

    case Map.get(mime_map, extension) do
      nil -> detect_mime_from_content(data)
      mime_type -> {:ok, mime_type}
    end
  end

  defp detect_mime_from_content(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: {:ok, "image/png"}
  defp detect_mime_from_content(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp detect_mime_from_content(<<0x47, 0x49, 0x46, _::binary>>), do: {:ok, "image/gif"}

  defp detect_mime_from_content(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>),
    do: {:ok, "audio/wav"}

  defp detect_mime_from_content(_), do: {:ok, "application/octet-stream"}

  defp detect_text_format(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".md" ->
        :markdown

      ".html" ->
        :html

      ".htm" ->
        :html

      ext when ext in [".js", ".py", ".ex", ".exs", ".rb", ".go", ".rs", ".c", ".cpp", ".java"] ->
        :code

      _ ->
        :plain
    end
  end

  defp detect_language(file_path) do
    extension = Path.extname(file_path) |> String.downcase()

    language_map = %{
      ".js" => "javascript",
      ".py" => "python",
      ".ex" => "elixir",
      ".exs" => "elixir",
      ".rb" => "ruby",
      ".go" => "go",
      ".rs" => "rust",
      ".c" => "c",
      ".cpp" => "cpp",
      ".java" => "java",
      ".sql" => "sql",
      ".sh" => "bash"
    }

    Map.get(language_map, extension)
  end

  defp validate_file_options(opts) do
    if Keyword.has_key?(opts, :auto_resize) or Keyword.has_key?(opts, :quality),
      do: {:error, "Media processing file options were removed; process media before loading"},
      else: :ok
  end

  defp validate_file_mime(mime_type, opts) do
    case Keyword.get(opts, :mime_types) do
      nil ->
        :ok

      allowed when is_list(allowed) ->
        if mime_type in allowed, do: :ok, else: {:error, "File MIME type is not allowed"}

      _ ->
        {:error, "Invalid file MIME types option"}
    end
  end

  defp validate_file_size(data, opts) do
    # 10MB default
    max_size = Keyword.get(opts, :max_size, 10_000_000)

    if byte_size(data) <= max_size do
      :ok
    else
      {:error, "File size exceeds maximum of #{max_size} bytes"}
    end
  end

  defp create_content_from_file(data, "image/" <> _ = mime_type, file_path, opts) do
    base64_data = Base.encode64(data)

    image_opts =
      opts
      |> Keyword.take([:width, :height, :alt_text, :metadata])
      |> Keyword.put_new(:alt_text, Path.basename(file_path))

    content = image(base64_data, mime_type, image_opts)
    {:ok, content}
  end

  defp create_content_from_file(data, "audio/" <> _ = mime_type, _file_path, opts) do
    base64_data = Base.encode64(data)
    audio_opts = Keyword.take(opts, [:duration, :transcript, :metadata])

    content = audio(base64_data, mime_type, audio_opts)
    {:ok, content}
  end

  defp create_content_from_file(data, "text/" <> _, file_path, opts) do
    format = detect_text_format(file_path)
    language = detect_language(file_path)

    text_opts =
      opts
      |> Keyword.take([:metadata])
      |> Keyword.put(:format, format)
      |> Keyword.put(:language, language)

    content = text(data, text_opts)
    {:ok, content}
  end

  defp create_content_from_file(_data, mime_type, file_path, opts) do
    # Fallback: create as resource reference
    resource_opts =
      opts
      |> Keyword.take([:metadata])
      |> Keyword.put(:mime_type, mime_type)
      |> Keyword.put(:text, "File: #{Path.basename(file_path)}")

    uri = "file://" <> Path.absname(file_path)
    content = resource(uri, resource_opts)
    {:ok, content}
  end

  defp substitute_variables(text, substitutions) do
    Enum.reduce(substitutions, text, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end
