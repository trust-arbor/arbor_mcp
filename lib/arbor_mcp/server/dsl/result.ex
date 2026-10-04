defmodule Arbor.MCP.Server.DSL.Result do
  @moduledoc """
  Compatibility forwarding path for `Arbor.MCP.Server.Result`.

  Handler and DSL callbacks now use one complete-result implementation.
  Existing direct calls through this module retain their constructor and
  normalization signatures. New code uses `Arbor.MCP.Server.Result`; DSL
  modules receive that module as `ToolResult` automatically.
  """

  alias Arbor.MCP.Server.Result

  defdelegate text(text), to: Result
  defdelegate error(reason), to: Result
  defdelegate error(reason, opts), to: Result
  defdelegate content(entries), to: Result
  defdelegate image(data, mime_type), to: Result
  defdelegate audio(data, mime_type), to: Result
  defdelegate resource(contents), to: Result
  defdelegate structured(text, data), to: Result
  defdelegate structured(text, data, opts), to: Result
  defdelegate input_required(input_requests), to: Result
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
