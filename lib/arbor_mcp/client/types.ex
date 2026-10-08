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
          | {:progress_token, String.t() | integer()}
          | {:meta, map()}
          | {:idempotency_key, String.t()}
          | {:idempotency_key_path, String.t() | [String.t()]}
          | {:cursor, String.t()}
          | {atom(), term()}
  @type request_opts :: [request_option()]

  @typedoc """
  Standard MCP response format - either success with data or error with reason.
  """
  @type mcp_response :: {:ok, any()} | {:error, any()}

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
