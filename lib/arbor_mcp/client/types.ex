defmodule Arbor.MCP.Client.Types do
  @moduledoc """
  Shared type definitions for Arbor.MCP.Client modules.

  This module provides common type definitions used across the client
  architecture to ensure consistency and type safety.
  """

  @typedoc """
  A client process reference - can be a PID, registered name, or GenServer reference.
  """
  @type client :: GenServer.server()

  @typedoc """
  Options for MCP requests, typically including timeout and format options.
  """
  @type request_option ::
          {:timeout, non_neg_integer()}
          | {:format, :map | :struct}
          | {:retry_policy, keyword() | false}
          | {:http_stream_retry, :at_least_once | :safe_only}
          | {:retry_safe, boolean()}
          | {:cancel_on_caller_exit, boolean() | nil}
          | {:progress_token, String.t() | integer()}
          | {:meta, map()}
          | {:idempotency_key, String.t()}
          | {:idempotency_key_path, String.t() | [String.t()]}
          | {:cursor, String.t()}
          | {:mrtr, :auto | :manual | nil}
          | {:input_responses, %{optional(String.t()) => map()} | nil}
          | {:request_state, String.t() | nil}
          | {:client_capabilities, map() | nil}
          | {:progress_to, pid() | nil}
          | {atom(), term()}
  @type request_opts :: [request_option()]

  @typedoc """
  Standard MCP response format - either success with data or error with reason.
  """
  @type mcp_response :: {:ok, any()} | {:error, any()}

  @typedoc """
  An MRTR round returned to the caller by `mrtr: :manual` (MCP 2026-07-28):
  the server's validated `inputRequests`, keyed by their ids (empty when it
  sent only a request state), its opaque `requestState` and the round's
  `_meta`, both `nil` when it sent none. The caller
  answers the input requests and passes the answers back with
  `input_responses:` and the state with `request_state:` on the next round
  of the same call.
  """
  @type input_required :: %{
          input_requests: %{optional(String.t()) => map()},
          request_state: String.t() | nil,
          meta: map() | nil
        }

  @typedoc """
  The result of an operation that can pause for input (`tools/call`,
  `resources/read`, `prompts/get`): with `mrtr: :manual`, a round can come
  back as `{:input_required, round}` instead of `{:ok, result}`.
  """
  @type mrtr_response :: mcp_response() | {:input_required, input_required()}

  @typedoc """
  MCP method name used in requests.
  """
  @type mcp_method :: String.t()

  @typedoc """
  Parameters map for MCP requests.
  """
  @type mcp_params :: map()

  @typedoc """
  Default timeout value in milliseconds.
  """
  @type default_timeout :: pos_integer()

  @typedoc """
  MCP resource URI - typically a file:// or http:// URI.
  """
  @type uri :: String.t()

  @typedoc """
  MCP tool name.
  """
  @type tool_name :: String.t()

  @typedoc """
  Arguments map for tool calls.
  """
  @type tool_arguments :: map()

  @typedoc """
  Request options or timeout value.
  """
  @type request_opts_or_timeout :: request_opts() | non_neg_integer()
end
