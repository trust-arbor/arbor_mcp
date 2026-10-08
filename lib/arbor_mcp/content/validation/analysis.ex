defmodule Arbor.MCP.Content.Validation.Analysis do
  @moduledoc false
  # Content analysis and metadata extraction from Content.Validation.

  alias Arbor.MCP.Content.Validation.Helpers

  def perform(content, analysis_type) do
    case analysis_type do
      :detect_faces -> detect_faces(content)
      :extract_colors -> extract_colors(content)
      :scan_text -> scan_text(content)
      :measure_complexity -> measure_complexity(content)
      _ -> {:error, "Unknown analysis type"}
    end
  end

  def extract_metadata(content) do
    case content.type do
      :image -> extract_image_metadata(content)
      :audio -> extract_audio_metadata(content)
      :text -> extract_text_metadata(content)
      _ -> %{}
    end
  end

  # Face/color "analysis" is not part of MCP/ACP — historical stubs returning empty data.
  defp detect_faces(%{type: :image}),
    do: {:error, "Face detection is not implemented and is not an MCP/ACP feature"}

  defp detect_faces(_), do: {:error, "Face detection only available for images"}

  defp extract_colors(%{type: :image}),
    do: {:error, "Color extraction is not implemented and is not an MCP/ACP feature"}

  defp extract_colors(_), do: {:error, "Color extraction only available for images"}

  defp scan_text(content) do
    text = Helpers.extract_text(content)
    {:ok, %{extracted_text: text, word_count: length(String.split(text))}}
  end

  defp measure_complexity(content) do
    complexity =
      case content.type do
        :text -> min(String.length(content.text) / 1000, 1.0)
        :image -> 0.8
        :audio -> 0.9
        _ -> 0.5
      end

    {:ok, %{complexity_score: complexity}}
  end

  defp extract_image_metadata(%{type: :image} = content) do
    %{
      format: Helpers.detect_image_format(content.data),
      dimensions: {content.width, content.height},
      mime_type: content.mime_type,
      size_bytes: Helpers.calculate_decoded_size(content.data)
    }
  end

  defp extract_audio_metadata(%{type: :audio} = content) do
    %{
      mime_type: content.mime_type,
      duration: content.duration,
      size_bytes: Helpers.calculate_decoded_size(content.data),
      has_transcript: not is_nil(content.transcript)
    }
  end

  defp extract_text_metadata(%{type: :text} = content) do
    %{
      format: content.format,
      language: content.language,
      length: String.length(content.text),
      word_count: length(String.split(content.text)),
      size_bytes: byte_size(content.text)
    }
  end
end
