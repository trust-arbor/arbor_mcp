defmodule Arbor.MCP.Content.Transformer do
  @moduledoc """
  Content transformation utilities for MCP content.

  > #### Experimental {: .warning}
  >
  > Prefer `Arbor.MCP.Content` for constructing MCP content blocks (`text`, `image`,
  > `audio`, resources). MCP/ACP only require **carrying** image bytes + MIME
  > type — not compressing, resizing, or generating thumbnails.

  ### Implemented

  - `:normalize_whitespace` / `normalize_whitespace/1`
  - `extract_text/1` (plain, simple HTML tag strip)
  - `{:custom, fun/1}`
  - limited text format conversion in `convert_format/2`

  Media processing and encoding conversion belong to the application. The v2
  pipeline rejects removed media/encoding operations before running any step.
  """

  alias Arbor.MCP.Content.Protocol

  @typedoc "Transformation operation"
  @type transformation_op ::
          :normalize_whitespace
          | :extract_text
          | {:custom, function()}
          | atom()

  @doc """
  Transforms content by applying a list of transformation operations.

  Removed media and encoding operations return an error before any operation
  runs. Perform that processing in the application, then construct MCP content.

  ## Examples

      {:ok, transformed} = Transformer.transform(content, [:normalize_whitespace])
  """
  @spec transform(Protocol.content(), [transformation_op()]) ::
          {:ok, Protocol.content()} | {:error, String.t()}
  def transform(content, operations) when is_list(operations) do
    with :ok <- validate_operations(operations) do
      result = Enum.reduce(operations, content, &apply_transformation/2)
      {:ok, result}
    end
  rescue
    e -> {:error, "Transformation failed: #{Exception.message(e)}"}
  end

  @doc """
  Transforms content with validation after each operation.
  """
  @spec transform_with_validation(Protocol.content(), [transformation_op()]) ::
          {:ok, Protocol.content()} | {:error, String.t()}
  def transform_with_validation(content, operations) when is_list(operations) do
    with :ok <- validate_operations(operations) do
      Enum.reduce_while(operations, {:ok, content}, fn operation, {:ok, current_content} ->
        case apply_operation_with_validation(current_content, operation) do
          {:ok, transformed} -> {:cont, {:ok, transformed}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Normalizes whitespace in text content.
  """
  @spec normalize_whitespace(String.t()) :: String.t()
  def normalize_whitespace(text) when is_binary(text) do
    text
    # Normalize line endings
    |> String.replace(~r/\r\n|\r/, "\n")
    # Collapse multiple spaces/tabs, but preserve newlines
    |> String.replace(~r/[ \t]+/, " ")
    # Limit consecutive newlines
    |> String.replace(~r/\n{3,}/, "\n\n")
    # Clean up spaces around newlines
    |> String.replace(~r/ *\n */, "\n")
    |> String.trim()
  end

  @doc """
  Extracts plain text from various content types.
  """
  @spec extract_text(Protocol.content()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_text(%{type: :text, text: text, format: :plain}), do: {:ok, text}

  def extract_text(%{type: :text, text: html, format: :html}) when is_binary(html) do
    # Simple HTML tag removal - in production, use a proper HTML parser
    text = String.replace(html, ~r/<[^>]+>/, " ")
    {:ok, normalize_whitespace(text)}
  end

  def extract_text(%{type: :text, text: text}) when is_binary(text), do: {:ok, text}

  # Handle HTML content type directly
  def extract_text(%{type: :html, text: html}) when is_binary(html) do
    # Simple HTML tag removal - in production, use a proper HTML parser
    text = String.replace(html, ~r/<[^>]+>/, " ")
    {:ok, normalize_whitespace(text)}
  end

  def extract_text(%{type: type}) when type in [:image, :audio, :video] do
    {:error, "Cannot extract text from #{type} content"}
  end

  def extract_text(_), do: {:error, "Unknown content type"}

  @doc """
  Converts content from one format to another.
  """
  @spec convert_format(Protocol.content(), atom()) ::
          {:ok, Protocol.content()} | {:error, String.t()}
  def convert_format(%{type: :text, format: from_format} = content, to_format) do
    case {from_format, to_format} do
      {same, same} -> {:ok, content}
      {:plain, :html} -> convert_text_to_html(content)
      {:html, :plain} -> convert_html_to_text(content)
      {:markdown, :html} -> convert_markdown_to_html(content)
      _ -> {:error, "Unsupported conversion from #{from_format} to #{to_format}"}
    end
  end

  def convert_format(_content, _to_format) do
    {:error, "Content must be text type for format conversion"}
  end

  # Private helper functions

  @removed_operations [:convert_encoding, :compress_images, :resize_images, :generate_thumbnails]

  defp validate_operations(operations) do
    if Enum.any?(operations, &removed_operation?/1),
      do: {:error, "Media and encoding transformation operations were removed"},
      else: :ok
  end

  defp removed_operation?(operation) when is_tuple(operation) and tuple_size(operation) > 0,
    do: elem(operation, 0) in @removed_operations

  defp removed_operation?(operation), do: operation in @removed_operations

  defp apply_transformation(:normalize_whitespace, %{type: :text, text: text} = content) do
    %{content | text: normalize_whitespace(text)}
  end

  defp apply_transformation({:custom, fun}, content) when is_function(fun, 1) do
    fun.(content)
  end

  defp apply_transformation(_, content), do: content

  defp apply_operation_with_validation(content, operation) do
    case apply_transformation(operation, content) do
      %{} = transformed -> {:ok, transformed}
      {:error, _} = error -> error
    end
  end

  defp convert_text_to_html(%{text: text} = content) do
    html =
      text
      |> html_escape()
      |> String.replace("\n", "<br>\n")

    {:ok, %{content | format: :html, text: html}}
  end

  defp convert_html_to_text(%{type: :text, format: :html} = content) do
    case extract_text(content) do
      {:ok, text} -> {:ok, %{content | format: :plain, text: text}}
      error -> error
    end
  end

  defp convert_markdown_to_html(%{text: _markdown} = content) do
    # TODO: Implement markdown to HTML conversion
    # This would use Earmark or similar library
    {:ok, %{content | type: :html}}
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
