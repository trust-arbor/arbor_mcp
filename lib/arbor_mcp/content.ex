defmodule Arbor.MCP.Content do
  @moduledoc """
  Content handling utilities for MCP messages.

  Builds and validates **protocol content blocks** used in tool results, prompts,
  sampling, and resources:

  - **text** — plain text
  - **image** — base64 payload + MIME type (MCP content type, not image processing)
  - **audio** — base64 payload + MIME type
  - **resource** — embedded resource reference
  - **tool_use** / **tool_result** — sampling content (2025-11-25)

  MCP and ACP specify how to *carry* images (and icons with URLs). They do **not**
  require compress/resize/thumbnail APIs. Those stubs live under experimental
  modules (`Arbor.MCP.Content.Transformer`, `Builders`) and are deprecated for 2.0.0.
  """

  alias Arbor.MCP.Types

  @doc """
  Creates a text content object.

  ## Examples

      iex> Arbor.MCP.Content.text("Hello, world!")
      %{type: :text, text: "Hello, world!"}

  """
  @spec text(String.t(), map() | nil) :: Types.text_content()
  def text(text, annotations \\ nil) do
    content = %{type: :text, text: text}
    if annotations, do: Map.put(content, :annotations, annotations), else: content
  end

  @doc """
  Creates an image content object.

  ## Parameters
    - data: Base64-encoded image data
    - mime_type: MIME type of the image (e.g., "image/png", "image/jpeg")
    - annotations: Optional annotations

  ## Examples

      iex> Arbor.MCP.Content.image(base64_data, "image/png")
      %{type: :image, data: base64_data, mimeType: "image/png"}

  """
  @spec image(String.t(), String.t(), map() | nil) :: Types.image_content()
  def image(data, mime_type, annotations \\ nil) do
    content = %{type: :image, data: data, mimeType: mime_type}
    if annotations, do: Map.put(content, :annotations, annotations), else: content
  end

  @doc """
  Creates an audio content object.

  ## Parameters
    - data: Base64-encoded audio data
    - mime_type: MIME type of the audio (e.g., "audio/mp3", "audio/wav", "audio/ogg")
    - annotations: Optional annotations

  ## Examples

      iex> Arbor.MCP.Content.audio(base64_data, "audio/mp3")
      %{type: :audio, data: base64_data, mimeType: "audio/mp3"}

  """
  @spec audio(String.t(), String.t(), map() | nil) :: Types.audio_content()
  def audio(data, mime_type, annotations \\ nil) do
    content = %{type: :audio, data: data, mimeType: mime_type}
    if annotations, do: Map.put(content, :annotations, annotations), else: content
  end

  @doc """
  Creates a resource content object.

  ## Parameters
    - resource: Resource object with uri, name, description, etc.
    - annotations: Optional annotations

  ## Examples

      iex> resource = %{uri: "file:///example.txt", name: "Example"}
      iex> Arbor.MCP.Content.resource(resource)
      %{type: :resource, resource: %{uri: "file:///example.txt", name: "Example"}}

  """
  @spec resource(map(), map() | nil) :: Types.embedded_resource()
  def resource(resource, annotations \\ nil) do
    content = %{type: :resource, resource: resource}
    if annotations, do: Map.put(content, :annotations, annotations), else: content
  end

  @doc """
  Creates a tool use content object (new in 2025-11-25).

  Used in sampling/createMessage responses when the model wants to call a tool.

  ## Parameters
    - id: Unique identifier for this tool use
    - name: Name of the tool to call
    - input: Arguments to pass to the tool
  """
  @spec tool_use(String.t(), String.t(), map()) :: Types.tool_use_content()
  def tool_use(id, name, input) when is_binary(id) and is_binary(name) and is_map(input) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  @doc """
  Creates a tool result content object (new in 2025-11-25).

  Used in sampling/createMessage to provide the result of a tool call.

  ## Parameters
    - tool_use_id: The ID of the tool_use this is a result for
    - content: List of content items (the tool's output)
    - opts: Optional keyword list with `:is_error` boolean
  """
  @spec tool_result(String.t(), [map()], keyword()) :: Types.tool_result_content()
  def tool_result(tool_use_id, content, opts \\ []) do
    result = %{type: "tool_result", tool_use_id: tool_use_id, content: content}

    if Keyword.get(opts, :is_error, false) do
      Map.put(result, :isError, true)
    else
      result
    end
  end

  @doc """
  Validates content object structure.

  Returns {:ok, content} if valid, {:error, reason} otherwise.
  """
  @spec validate(map()) :: {:ok, Types.content()} | {:error, String.t()}
  def validate(%{type: :text, text: text} = content) when is_binary(text) do
    {:ok, content}
  end

  def validate(%{type: :image, data: data, mimeType: mime_type} = content)
      when is_binary(data) and is_binary(mime_type) do
    if valid_image_mime?(mime_type) do
      {:ok, content}
    else
      {:error, "Invalid image MIME type: #{mime_type}"}
    end
  end

  def validate(%{type: :audio, data: data, mimeType: mime_type} = content)
      when is_binary(data) and is_binary(mime_type) do
    if valid_audio_mime?(mime_type) do
      {:ok, content}
    else
      {:error, "Invalid audio MIME type: #{mime_type}"}
    end
  end

  def validate(%{type: :resource, resource: %{uri: uri}} = content) when is_binary(uri) do
    {:ok, content}
  end

  # Tool use content (new in 2025-11-25)
  def validate(%{type: "tool_use", id: id, name: name, input: input} = content)
      when is_binary(id) and is_binary(name) and is_map(input) do
    {:ok, content}
  end

  # Tool result content (new in 2025-11-25)
  def validate(%{type: "tool_result", tool_use_id: id, content: items} = content)
      when is_binary(id) and is_list(items) do
    {:ok, content}
  end

  def validate(_), do: {:error, "Invalid content structure"}

  @doc """
  Extracts the type of a content object.
  """
  @spec get_type(Types.content()) :: Types.content_type()
  def get_type(%{type: type}), do: type

  @doc """
  Checks if content is of a specific type.
  """
  @spec type?(Types.content(), Types.content_type()) :: boolean()
  def type?(%{type: type}, expected_type), do: type == expected_type

  # Private helpers

  defp valid_image_mime?(mime_type) do
    mime_type in [
      "image/png",
      "image/jpeg",
      "image/jpg",
      "image/gif",
      "image/webp",
      "image/svg+xml"
    ]
  end

  defp valid_audio_mime?(mime_type) do
    mime_type in [
      "audio/mpeg",
      "audio/mp3",
      "audio/wav",
      "audio/wave",
      "audio/ogg",
      "audio/opus",
      "audio/flac",
      "audio/aac",
      "audio/m4a",
      "audio/webm"
    ]
  end
end
