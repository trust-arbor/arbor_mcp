defmodule Arbor.MCP.Content.Validation.Helpers do
  @moduledoc false
  # Shared helper functions for content validation modules.

  def extract_text(content) do
    case content.type do
      :text -> content.text
      :image -> content.alt_text || ""
      :audio -> content.transcript || ""
      :resource -> get_in(content, [:resource, :text]) || ""
      :annotation -> get_in(content, [:annotation, :text]) || ""
    end
  end

  def detect_image_format(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, <<0x89, 0x50, 0x4E, 0x47, _::binary>>} -> "PNG"
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> "JPEG"
      {:ok, <<0x47, 0x49, 0x46, _::binary>>} -> "GIF"
      _ -> "Unknown"
    end
  end

  def calculate_decoded_size(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, decoded} -> byte_size(decoded)
      :error -> 0
    end
  end
end
