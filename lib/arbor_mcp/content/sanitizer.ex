defmodule Arbor.MCP.Content.Sanitizer do
  @moduledoc """
  Content sanitization utilities for MCP content.

  > #### Experimental {: .warning}
  >
  > Not part of the core stable Handler/DSL surface. Best-effort text sanitization
  > only — not a full security sandbox.

  ### Implemented

  - `:html_escape` / `html_escape/1`
  - `:strip_scripts` / `strip_scripts/1`
  - `:normalize_unicode` / `normalize_unicode/1` (Unicode NFC)
  - `:limit_size` (text truncation; binary content marked on overflow)
  - `sanitize_path/1`, `strip_sql_injection/1`

  Media sanitization belongs to the application. The v2 pipeline rejects
  removed metadata/media operations before running any step. Clearing an
  application metadata map does not remove EXIF from media bytes.
  """

  alias Arbor.MCP.Content.Protocol

  @typedoc "Sanitization operation"
  @type sanitization_op ::
          :html_escape
          | :strip_scripts
          | :normalize_unicode
          | :limit_size
          | {:custom, function()}
          | atom()

  @doc """
  Sanitizes content by applying a list of sanitization operations.

  Removed metadata/media operations raise `ArgumentError` before any operation
  runs, including custom operations.

  ## Examples

      safe_content = Sanitizer.sanitize(content, [
        :html_escape,
        :strip_scripts,
        {:limit_size, 1_000_000}
      ])
  """
  @spec sanitize(Protocol.content(), [sanitization_op()]) :: Protocol.content()
  def sanitize(content, operations) when is_list(operations) do
    validate_operations!(operations)
    Enum.reduce(operations, content, &apply_sanitization/2)
  end

  @doc """
  Sanitizes text content specifically.
  """
  @spec sanitize_text(String.t(), [sanitization_op()]) :: String.t()
  def sanitize_text(text, operations) when is_binary(text) and is_list(operations) do
    validate_operations!(operations)
    Enum.reduce(operations, text, &apply_text_sanitization/2)
  end

  @doc """
  Escapes HTML entities in text content.
  """
  @spec html_escape(String.t()) :: String.t()
  def html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc """
  Removes script tags and JavaScript from HTML content.
  """
  @spec strip_scripts(String.t()) :: String.t()
  def strip_scripts(text) when is_binary(text) do
    text
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    # Remove standalone script tags
    |> String.replace(~r/<script[^>]*>/i, "")
    # Remove orphaned closing script tags
    |> String.replace(~r/<\/script>/i, "")
    |> String.replace(~r/on\w+\s*=\s*["'][^"']*["']/i, "")
    |> String.replace(~r/javascript:/i, "")
  end

  @doc """
  Normalizes Unicode text to NFC form.

  Uses `:unicode.characters_to_nfc_binary/1`. This reduces some homograph
  confusion but is not a complete security control by itself.
  """
  @spec normalize_unicode(String.t()) :: String.t()
  def normalize_unicode(text) when is_binary(text) do
    case :unicode.characters_to_nfc_binary(text) do
      result when is_binary(result) -> result
      _ -> text
    end
  end

  @doc """
  Sanitizes file paths to prevent directory traversal.
  """
  @spec sanitize_path(String.t()) :: String.t()
  def sanitize_path(path) when is_binary(path) do
    path
    |> String.replace("..", "")
    |> String.replace("~", "")
    |> String.replace(~r/[^\w\-\.\/]/, "")
    |> String.trim("/")
  end

  @doc """
  Removes SQL injection attempts from text.
  """
  @spec strip_sql_injection(String.t()) :: String.t()
  def strip_sql_injection(text) when is_binary(text) do
    sql_keywords = ~w[
      SELECT INSERT UPDATE DELETE DROP CREATE ALTER EXEC EXECUTE
      UNION DECLARE CAST CONVERT SCRIPT JAVASCRIPT
    ]

    Enum.reduce(sql_keywords, text, fn keyword, acc ->
      String.replace(acc, ~r/\b#{keyword}\b/i, "")
    end)
  end

  # Private helper functions

  @removed_operations [:remove_metadata, :compress_media]

  defp validate_operations!(operations) do
    if Enum.any?(operations, &removed_operation?/1),
      do: raise(ArgumentError, "Metadata and media sanitization operations were removed")
  end

  defp removed_operation?(operation) when is_tuple(operation) and tuple_size(operation) > 0,
    do: elem(operation, 0) in @removed_operations

  defp removed_operation?(operation), do: operation in @removed_operations

  defp apply_sanitization(:html_escape, %{type: :text, text: text} = content) do
    %{content | text: html_escape(text)}
  end

  defp apply_sanitization(:strip_scripts, %{type: :text, text: text} = content) do
    %{content | text: strip_scripts(text)}
  end

  defp apply_sanitization(:normalize_unicode, %{type: :text, text: text} = content) do
    %{content | text: normalize_unicode(text)}
  end

  defp apply_sanitization({:limit_size, max_size}, content) do
    limit_content_size(content, max_size)
  end

  defp apply_sanitization({:custom, fun}, content) when is_function(fun, 1) do
    fun.(content)
  end

  defp apply_sanitization(_, content), do: content

  defp apply_text_sanitization(:html_escape, text), do: html_escape(text)
  defp apply_text_sanitization(:strip_scripts, text), do: strip_scripts(text)
  defp apply_text_sanitization(:normalize_unicode, text), do: normalize_unicode(text)
  defp apply_text_sanitization(:strip_sql_injection, text), do: strip_sql_injection(text)
  defp apply_text_sanitization({:custom, fun}, text) when is_function(fun, 1), do: fun.(text)
  defp apply_text_sanitization(_, text), do: text

  defp limit_content_size(%{type: :text, text: text} = content, max_size) do
    if byte_size(text) > max_size do
      truncated = binary_part(text, 0, max_size)
      %{content | text: truncated}
    else
      content
    end
  end

  defp limit_content_size(%{type: type, data: data} = content, max_size)
       when type in [:image, :audio] do
    if byte_size(data) > max_size do
      # For binary data, we can't just truncate - mark for removal
      Map.put(content, :error, "Content exceeds size limit")
    else
      content
    end
  end

  defp limit_content_size(content, _), do: content
end
