defmodule Arbor.MCP.Server.DSL.Result do
  @moduledoc """
  Compatibility forwarding path for `Arbor.MCP.Server.Result`.

  Handler and DSL callbacks now use one complete-result implementation.
  Existing direct calls through this module retain their constructor and
  normalization signatures. New code uses `Arbor.MCP.Server.Result`; DSL
  modules receive that module as `ToolResult` automatically.
  """

  alias Arbor.MCP.Server.Result

  @doc """
  Creates a complete tool result containing text.

  Compatibility delegation to `Arbor.MCP.Server.Result.text/1`.
  """
  defdelegate text(text), to: Result

  @doc """
  Creates an explicit tool-error result.

  Compatibility delegation to `Arbor.MCP.Server.Result.error/1`, with the same
  safe error-message validation and return shape.
  """
  defdelegate error(reason), to: Result
  defdelegate error(reason, opts), to: Result
  defdelegate content(entries), to: Result
  defdelegate image(data, mime_type), to: Result
  defdelegate audio(data, mime_type), to: Result
  defdelegate resource(contents), to: Result

  @doc """
  Creates a complete tool result with text and structured content.

  Compatibility delegation to `Arbor.MCP.Server.Result.structured/2`.
  Protocol dispatch applies the selected revision's structured-content rules.
  """
  defdelegate structured(text, data), to: Result
  defdelegate structured(text, data, opts), to: Result

  @doc """
  Creates an MRTR input-required result without explicit request state.

  Compatibility delegation to `Arbor.MCP.Server.Result.input_required/1`.
  """
  defdelegate input_required(input_requests), to: Result

  @doc """
  Creates an MRTR input-required result carrying request state.

  Compatibility delegation to `Arbor.MCP.Server.Result.input_required/2`.
  """
  defdelegate input_required(input_requests, request_state), to: Result

  @doc false
  defdelegate normalize_tool(result, state), to: Result
  @doc false
  defdelegate normalize_tool_result(result), to: Result
  @doc false
  defdelegate normalize_resource(result, uri, mime_type, state), to: Result
  @doc false
  defdelegate normalize_prompt(result, state), to: Result
end
