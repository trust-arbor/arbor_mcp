defmodule Arbor.MCP.Server.Context do
  @moduledoc """
  Access to the validated context of the currently executing server callback.

  This is primarily useful for MRTR-aware handlers that retain their existing
  callback arity. The value is scoped to the callback invocation and must not
  be read later from a spawned process.

  `cancelled?/0` reports whether the current request id has been cancelled.
  `request_id/0`, `session_id/0`, `auth_info/0` and `request_headers/0` describe
  the request, like the `extra` argument of TypeScript SDK handlers.
  """

  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.{AuthInfo, Cancellation, RequestContext}
  alias Arbor.MCP.Server.Runtime.{CallbackContext, HTTPNotificationTarget}

  @key {__MODULE__, :current}
  @log_levels ~w(debug info notice warning error critical alert emergency)

  @doc """
  Returns the validated context of the request the callback is serving, or
  `nil` outside a callback.

  Its `method` is the JSON-RPC method of that request, which is not always
  the one the callback stands for. Before a modern `tools/call` over
  Streamable HTTP, the server may call `handle_list_tools/2` to find the
  tool's `x-mcp-header` annotations, and on a Runtime it does so in the
  `tools/call` context: `method` is `"tools/call"` there and `"tools/list"`
  when a client lists. `c:Arbor.MCP.Server.Handler.handle_get_tool/2` saves
  that walk.

  Like the other functions here, the value is not inherited by a spawned
  process. The `Arbor.MCP.MessageProcessor` handler-process path calls
  `handle_list_tools/2` without a context, so `current/0` is `nil` there.
  """
  @spec current() :: RequestContext.t() | nil
  def current, do: Process.get(@key)

  @doc """
  Returns the opaque connection/session scope of the active runtime callback.

  Custom cancellation trackers can pair this value with a request ID to keep
  handler-owned cancellation state isolated. Treat the scope as an opaque
  identity: its representation belongs to the transport/runtime. Returns `nil`
  outside runtime callback work, including legacy handler-process callbacks.
  Like `current/0`, the value is not inherited by a spawned process.
  """
  @spec scope() :: term()
  def scope do
    case CallbackContext.current() do
      %{scope: scope} -> scope
      nil -> nil
    end
  end

  @doc """
  Returns true if the current request id has been cancelled.

  Safe to call from inside a running handler: cancel is recorded out of
  band when `notifications/cancelled` is accepted, so this does not wait
  for the server GenServer to finish the current callback.

  Returns `false` when there is no active invocation or it has not been
  cancelled. Runtime-backed servers scope this signal to the runtime,
  connection/session, direction and invocation token. Cancellation prevents
  that invocation from committing state and the runtime stops unresponsive
  callback tasks after the configured grace period.

  On cancellation, the Runtime sends the callback process
  `{:arbor_mcp_cancelled, token, reason}`. The token is the opaque invocation
  token; reasons are `:request_cancelled`, `:owner_down`, or `:handler_timeout`.
  The callback has `:cancel_grace_ms` (default 100 ms) to finish cooperative
  cleanup before the Runtime kills the task. Polling this function does not
  extend that grace period, and cancellation cannot undo external effects.

  Handler-process callbacks dispatched by `Arbor.MCP.MessageProcessor` only
  observe a cancellation sent from the same HTTP session, or for a
  sessionless request from the same authenticated principal, tenant and
  endpoint. Anonymous sessionless requests cannot be cancelled this way.
  """
  @spec cancelled?() :: boolean()
  def cancelled? do
    if CallbackContext.current() do
      CallbackContext.cancelled?()
    else
      case current() do
        %RequestContext{request_id: request_id, cancellation_scope: scope} ->
          Cancellation.cancelled?(scope, request_id)

        _other ->
          false
      end
    end
  end

  @spec input_responses() :: map() | nil
  def input_responses do
    case current() do
      %RequestContext{input_responses: responses} -> responses
      nil -> nil
    end
  end

  @spec request_state() :: term()
  def request_state do
    case current() do
      %RequestContext{request_state: state} -> state
      nil -> nil
    end
  end

  @spec progress_token() :: Arbor.MCP.Types.progress_token() | nil
  def progress_token do
    case current() do
      %RequestContext{progress_token: token} -> token
      nil -> nil
    end
  end

  @doc """
  Returns the JSON-RPC id of the request being handled, or `nil` for a
  notification.
  """
  @spec request_id() :: Arbor.MCP.Types.request_id() | nil
  def request_id, do: field(:request_id)

  @doc """
  Returns the `Mcp-Session-Id` of a legacy Streamable HTTP request.

  Modern HTTP is stateless and has no session, and stdio and BEAM connections
  have none either, so this is `nil` for them.
  """
  @spec session_id() :: String.t() | nil
  def session_id, do: field(:session_id)

  @doc """
  Returns the validated access token of an HTTP request, or `nil` when the
  request carried none. See `Arbor.MCP.Server.AuthInfo`.
  """
  @spec auth_info() :: AuthInfo.t() | nil
  def auth_info, do: field(:auth_info)

  @doc """
  Returns the HTTP request headers as `{lowercase_name, value}` pairs, as in
  `Plug.Conn.req_headers`, or `nil` for stdio and BEAM requests.

  They are the headers as received, including `authorization` and `cookie`,
  so don't log them whole. `inspect(Context.current())` leaves them out; use
  `auth_info/0` for the validated token.
  """
  @spec request_headers() :: [{String.t(), String.t()}] | nil
  def request_headers, do: field(:request_headers)

  defp field(key) do
    case current() do
      %RequestContext{} = context -> Map.fetch!(context, key)
      nil -> nil
    end
  end

  @doc """
  Reports progress for the currently executing request callback.

  It works on every transport, as TypeScript and Python handlers' progress
  helpers do. The request must include `_meta.progressToken`. Over BEAM, stdio
  and the test transport the notification is queued on the connection, ahead
  of the callback's result, before this function returns, and refused once the
  request is cancelled; over HTTP the request must own an active SSE response
  or an addressed legacy session stream. A legacy Streamable HTTP request owns
  one when its client accepts `text/event-stream`; otherwise its progress goes
  to its session's GET stream.
  Request-owned SSE acknowledges actual IO before this function returns. Legacy session SSE accepts a durable replay event before
  returning, ordered before the request's final reply; this is not a client-byte
  receipt. A cancelled callback cannot append under a retired phase or lease.
  Legacy replay or operation pressure returns a fixed typed atom error without
  retrying a previously accepted event.

  Returns `{:error, :progress_not_requested}` without a progress token,
  `{:error, :request_not_streaming}` without a notification target, or
  `{:error, :no_request_context}` outside a callback. A closed or retired
  target returns `:stream_closed`; an unacknowledged delivery can return
  `:stream_timeout`. Legacy session delivery also propagates atom errors from
  its session service, including `:replay_capacity_exhausted`,
  `:event_too_large_or_invalid`, `:callback_source_retired`, `:operation_timeout`,
  and `:service_unavailable`. Custom session adapters may return other atom
  errors, so the error type is intentionally open. A delivery error does not
  imply that earlier progress or application effects were rolled back.
  """
  @spec report_progress(number(), number() | nil, String.t() | nil) :: :ok | {:error, atom()}
  def report_progress(progress, total \\ nil, message \\ nil) when is_number(progress) do
    case current() do
      %RequestContext{progress_token: nil} ->
        {:error, :progress_not_requested}

      %RequestContext{notification_target: target, progress_token: token} ->
        if deliverable?(target),
          do: deliver(target, Protocol.encode_progress(token, progress, total, message)),
          else: {:error, :request_not_streaming}

      nil ->
        {:error, :no_request_context}
    end
  end

  @doc """
  Sends a log notification on the currently executing request's HTTP stream.

  Request-scoped log delivery is available only while that request owns an
  active SSE response and explicitly requested log level. It never falls back
  to another session or modern subscription. Legacy session callbacks use
  `Arbor.MCP.Server.send_log_message/4`; legacy metadata does not imply the
  modern request-scoped log-level intent. Request-owned SSE retains actual IO
  acknowledgement. Application-authored legacy log intent retains the addressed
  replay target's fixed typed capacity, operation and source errors; accepting a
  replay event does not acknowledge client bytes or retry an earlier event.

  MCP protocol Logging is deprecated as of 2026-07-28 and available in
  ArborMCP 2.x for pinned legacy protocol revisions. Prefer stderr for stdio diagnostics or OpenTelemetry for new
  structured-observability integrations.
  """
  @spec send_log_message(atom() | String.t(), String.t(), map()) ::
          :ok | {:error, atom()}
  def send_log_message(level, message, data \\ %{}) when is_binary(message) and is_map(data) do
    level = to_string(level)

    case current() do
      %RequestContext{log_level: nil} ->
        {:error, :logging_not_requested}

      %RequestContext{log_level: requested, notification_target: target} ->
        deliver_requested_log(level, requested, target, message, data)

      nil ->
        {:error, :no_request_context}
    end
  end

  defp deliver_requested_log(level, requested, target, message, data) do
    cond do
      level not in @log_levels or requested not in @log_levels ->
        {:error, :invalid_log_level}

      not log_level_enabled?(level, requested) ->
        :ok

      not deliverable?(target) ->
        {:error, :request_not_streaming}

      true ->
        data =
          if map_size(data) == 0,
            do: message,
            else: Map.put_new(data, "message", message)

        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/message",
          "params" => %{
            "level" => level,
            "logger" => "Arbor.MCP.Server",
            "data" => data
          }
        }

        deliver(target, notification)
    end
  end

  defp log_level_enabled?(level, requested) do
    Enum.find_index(@log_levels, &(&1 == level)) >=
      Enum.find_index(@log_levels, &(&1 == requested))
  end

  @doc false
  def with_context(%RequestContext{} = context, fun) when is_function(fun, 0) do
    previous = Process.put(@key, context)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  # A request's own stream (HTTP), or the edge of its connection (BEAM,
  # stdio, test), which takes it only while that request is current.
  defp deliverable?({:arbor_mcp_edge, edge, _token}) when is_pid(edge), do: true
  defp deliverable?(target), do: is_pid(target) or HTTPNotificationTarget.target?(target)

  defp deliver({:arbor_mcp_edge, edge, token}, notification),
    do: deliver_pid(edge, {:ex_mcp_request_notification, self(), :ref, notification, token})

  defp deliver(target, notification) do
    if HTTPNotificationTarget.target?(target),
      do: HTTPNotificationTarget.deliver(target, notification),
      else: deliver_pid(target, {:ex_mcp_request_notification, self(), :ref, notification})
  end

  defp deliver_pid(target, message) do
    ref = make_ref()
    monitor = Process.monitor(target)
    send(target, put_elem(message, 2, ref))

    receive do
      {:ex_mcp_request_notification_ack, ^ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:ex_mcp_request_notification_ack, ^ref, {:error, _reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, :stream_closed}

      {:DOWN, ^monitor, :process, ^target, _reason} ->
        {:error, :stream_closed}
    after
      5_000 ->
        Process.demonitor(monitor, [:flush])
        {:error, :stream_timeout}
    end
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
