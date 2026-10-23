defmodule ExMCP.Server.Tools.ResponseNormalizer do
  require Logger
  alias ExMCP.Internal.LogSummary

  @moduledoc """
  Normalizes tool responses to comply with MCP specification.

  > #### Deprecated {: .warning}
  >
  > Part of the deprecated `ExMCP.Server.Tools` API. **Planned for removal in 2.0.0.**
  > Prefer `ExMCP.Server.DSL.Result` normalization used by `ExMCP.Server.DSL`.

  This module extracts the response normalization logic from the original
  Server.Tools module into a focused, testable unit.
  """

  @doc """
  Normalizes various response formats into MCP-compliant structure.

  ## Examples

      # String response
      normalize("Hello") 
      # => %{content: [%{type: "text", text: "Hello"}]}
      
      # Map with text key
      normalize(%{text: "Hello"})
      # => %{content: [%{type: "text", text: "Hello"}]}
      
      # Already normalized
      normalize(%{content: [%{type: "text", text: "Hello"}]})
      # => %{content: [%{type: "text", text: "Hello"}]}
  """
  @spec normalize(any()) :: map()
  def normalize(response) when is_binary(response) do
    %{content: [%{type: "text", text: response}]}
  end

  def normalize(%{text: text}) when is_binary(text) do
    %{content: [%{type: "text", text: text}]}
  end

  def normalize(text: text) when is_binary(text) do
    # Handle keyword list response
    %{content: [%{type: "text", text: text}]}
  end

  def normalize(%{} = response) do
    response
    |> ensure_content_field()
    |> preserve_structured_output()
    |> preserve_other_fields()
  end

  def normalize(other) do
    # Never `inspect/1` arbitrary handler terms into a client-visible result.
    Logger.warning("Tool handler returned an unsupported result",
      reason_shape: LogSummary.describe(other)
    )

    %{
      content: [%{type: "text", text: "Tool returned an unsupported result; see the server log"}],
      isError: true
    }
  end

  @doc """
  Normalizes error responses.
  """
  @spec normalize_error(any()) :: map()
  def normalize_error(reason) when is_binary(reason) do
    %{content: [%{type: "text", text: reason}], isError: true}
  end

  # Atoms carry no payload, so their inspected form (`:badarg`) is safe to send.
  def normalize_error(reason) when is_atom(reason),
    do: %{content: [%{type: "text", text: inspect(reason)}], isError: true}

  def normalize_error(%{message: message}) when is_binary(message),
    do: %{content: [%{type: "text", text: message}], isError: true}

  def normalize_error(reason) do
    # Other terms (tuples, structs, exceptions without a message) may carry
    # internal detail; log the shape and send a fixed message.
    Logger.warning("Tool handler returned an unsupported error",
      reason_shape: LogSummary.describe(reason)
    )

    %{
      content: [%{type: "text", text: "Tool execution failed; see the server log"}],
      isError: true
    }
  end

  # Private helpers

  defp ensure_content_field(%{content: _} = response), do: response

  defp ensure_content_field(%{structuredOutput: _} = response) do
    # If only structuredOutput is present, add empty content array
    Map.put_new(response, :content, [])
  end

  defp ensure_content_field(response) do
    # If neither content nor structuredOutput, add empty content array
    Map.put_new(response, :content, [])
  end

  defp preserve_structured_output(%{structuredOutput: _} = response), do: response

  defp preserve_structured_output(%{structuredContent: structured_content} = response) do
    # Support legacy structuredContent field by mapping to structuredOutput
    response
    |> Map.put(:structuredOutput, structured_content)
    |> Map.delete(:structuredContent)
  end

  defp preserve_structured_output(response), do: response

  defp preserve_other_fields(response) do
    # Preserve all other fields like isError, resourceLinks, metadata, etc.
    response
    |> ensure_resource_links_format()
  end

  defp ensure_resource_links_format(%{resourceLinks: links} = response) when is_list(links) do
    # Ensure resource links are properly formatted for spec
    response
  end

  defp ensure_resource_links_format(response) do
    # No resource links or not a list, leave as is
    response
  end
end
