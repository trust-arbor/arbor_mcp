defmodule ExMCP.Server.DSL.Result do
  require Logger
  alias ExMCP.Internal.LogSummary

  @moduledoc """
  Response helpers for the modern server DSL.

  When a module uses `ExMCP.Server.DSL`, this module is aliased as `ToolResult`.
  Outside DSL modules, call the functions via `ExMCP.Server.DSL.Result`.

  ## Building results

      ToolResult.text("hello")
      ToolResult.error("something went wrong")
      ToolResult.structured("done", %{count: 1})

  ## Normalization

  Handlers may also return plain values; the DSL normalizes them:

  * binaries and `%{text: ...}` → text content
  * `%{content: ...}` maps → used as tool results
  * `{:ok, result}` / `{:ok, result, state}` / `{:error, reason}` tuples
  """

  alias ExMCP.Server.ResultNormalizer

  @doc """
  Builds a text tool result.
  """
  @spec text(String.t()) :: map()
  def text(text) when is_binary(text), do: %{content: [%{type: "text", text: text}]}

  @doc """
  Builds an error tool result.

  A binary reason is sent to the client verbatim. Other reasons never reach the
  client through `inspect/1`: an atom or an authored binary `message` field
  (`%{message: ...}` or `%{"message" => ...}`) is reported as
  `"Tool execution failed: <detail>"`, and any other term is logged and
  replaced by the fixed text `"Tool execution failed"`, so internal structs,
  pids, or file paths cannot leak.
  """
  @spec error(any()) :: map()
  def error(reason) when is_binary(reason),
    do: %{content: [%{type: "text", text: reason}], isError: true}

  def error(reason), do: error(ResultNormalizer.error_message("Tool execution failed", reason))

  @doc """
  Builds a tool result with both text and structured content.
  """
  @spec structured(String.t(), map()) :: map()
  def structured(text, data) when is_binary(text) and is_map(data) do
    %{content: [%{type: "text", text: text}], structuredContent: data}
  end

  @doc """
  Suspends a modern tool, resource, or prompt result for MRTR input.

  The optional application state must be JSON encodable. ExMCP seals it into
  an opaque `requestState`; handlers can read it on the retry through
  `ExMCP.Server.Context.request_state/0`.
  """
  @spec input_required(map(), term()) :: ExMCP.Server.MRTR.InputRequired.t()
  def input_required(input_requests, request_state \\ nil) when is_map(input_requests) do
    %ExMCP.Server.MRTR.InputRequired{
      input_requests: input_requests,
      request_state: request_state
    }
  end

  @doc false
  def normalize_tool({:ok, result}, state), do: {:ok, normalize_tool_result(result), state}

  def normalize_tool({:ok, result, new_state}, _state),
    do: {:ok, normalize_tool_result(result), new_state}

  def normalize_tool({:error, reason}, state), do: {:ok, error(reason), state}
  def normalize_tool({:error, reason, new_state}, _state), do: {:ok, error(reason), new_state}

  @doc false
  def normalize_tool_result(result) when is_binary(result), do: text(result)
  def normalize_tool_result(%ExMCP.Server.MRTR.InputRequired{} = result), do: result
  def normalize_tool_result(text: value) when is_binary(value), do: text(value)
  def normalize_tool_result(%{text: value}) when is_binary(value), do: text(value)
  def normalize_tool_result(%{content: _} = result), do: normalize_structured_key(result)

  def normalize_tool_result(%{structuredContent: _} = result),
    do: Map.put_new(result, :content, [])

  def normalize_tool_result(%{structuredOutput: _} = result), do: normalize_structured_key(result)
  # Anything else is not a tool result the protocol can carry. It used to be
  # `inspect/1`ed into the reply, which sent arbitrary handler terms (structs,
  # credentials, process state) to the client. Reject it and keep the detail
  # in the server log.
  def normalize_tool_result(result) do
    Logger.warning("Tool handler returned an unsupported result",
      reason_shape: LogSummary.describe(result)
    )

    error("Tool returned an unsupported result; see the server log")
  end

  @doc false
  def normalize_resource({:ok, result}, uri, mime_type, state) do
    {:ok, normalize_resource_result(result, uri, mime_type), state}
  end

  def normalize_resource({:ok, result, new_state}, uri, mime_type, _state) do
    {:ok, normalize_resource_result(result, uri, mime_type), new_state}
  end

  def normalize_resource({:error, reason}, _uri, _mime_type, state), do: {:error, reason, state}

  def normalize_resource({:error, reason, new_state}, _uri, _mime_type, _state),
    do: {:error, reason, new_state}

  @doc false
  def normalize_prompt({:ok, result}, state), do: {:ok, normalize_prompt_result(result), state}

  def normalize_prompt({:ok, result, new_state}, _state),
    do: {:ok, normalize_prompt_result(result), new_state}

  def normalize_prompt({:error, reason}, state), do: {:error, reason, state}
  def normalize_prompt({:error, reason, new_state}, _state), do: {:error, reason, new_state}

  defp normalize_structured_key(%{structuredOutput: structured_output} = result) do
    result
    |> Map.put(:structuredContent, structured_output)
    |> Map.delete(:structuredOutput)
    |> Map.put_new(:content, [])
  end

  defp normalize_structured_key(result), do: result

  defp normalize_resource_result(result, uri, mime_type) when is_binary(result) do
    %{uri: uri, text: result}
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(%ExMCP.Server.MRTR.InputRequired{} = result, _uri, _mime_type),
    do: result

  defp normalize_resource_result(%{text: _} = result, uri, mime_type) do
    result
    |> Map.put_new(:uri, uri)
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(%{blob: _} = result, uri, mime_type) do
    result
    |> Map.put_new(:uri, uri)
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(result, _uri, _mime_type), do: result

  defp normalize_prompt_result(%{messages: _} = result), do: result
  defp normalize_prompt_result(%ExMCP.Server.MRTR.InputRequired{} = result), do: result
  defp normalize_prompt_result(text: text) when is_binary(text), do: normalize_prompt_result(text)
  defp normalize_prompt_result(messages) when is_list(messages), do: %{messages: messages}

  defp normalize_prompt_result(text) when is_binary(text) do
    %{messages: [%{role: "user", content: %{type: "text", text: text}}]}
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
