defmodule Arbor.MCP.Client.RequestHandler do
  @moduledoc """
  Request/response processing for Arbor.MCP client.

  This module handles all request processing, batch operations, message parsing,
  and response handling for MCP clients.
  """

  require Logger
  alias Arbor.MCP.Client.{ConnectionScope, Lifetime}
  alias Arbor.MCP.Client.{Deadline, InputDispatcher, MRTR, NotificationListener}
  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.{Maps, Protocol, RequestParams, VersionRegistry}
  alias Arbor.RPC.{JSONRPC, LogSummary}
  alias Arbor.MCP.Protocol.{ErrorCodes, ResponseBuilder, ResultEnvelope}
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.ToolHeaders

  # Extra time allowed past a caller-enforced timeout before the client
  # cleans up its own pending-request bookkeeping.
  @caller_timeout_grace 1_000

  @doc """
  Handles individual MCP requests.

  Processes a single MCP request and returns the appropriate GenServer response.

  The optional `meta` map controls request timeout enforcement:

  - `%{timeout: nil}` - the caller did not specify a timeout, so the client
    process enforces its own `default_timeout` by scheduling a
    `{:request_timeout, id}` message for pending requests
  - `%{timeout: integer}` - the caller enforces the timeout on its side
    (via the `GenServer.call/3` timeout), so no timer is scheduled
  - `%{timeout: :caller_enforced}` - legacy `{:request, method, params}`
    calls; no timer is scheduled

  An explicit timeout comes with `deadline:`, the caller's absolute
  monotonic-millisecond deadline. A request is sent only while its caller
  still waits: one whose deadline passed while it sat in the client's
  mailbox, or whose caller has exited, is answered with a `:not_sent`
  transport error instead (see `not_sent_error/2`), and a synchronous HTTP
  send is itself capped at the deadline.
  """
  def handle_request(method, params, from, state, meta \\ %{timeout: :caller_enforced}) do
    case undeliverable(from, meta) do
      nil ->
        id = Protocol.generate_id()
        send_built_request(method, params, id, from, state, meta)

      cause ->
        {:reply, {:error, not_sent_error(cause, state)}, state}
    end
  end

  # Liveness and monotonic time are only comparable on the caller's own node.
  defp undeliverable({caller, _tag}, meta) when is_pid(caller) and node(caller) == node() do
    cond do
      not Process.alive?(caller) -> :caller_gone
      Deadline.expired?(request_deadline(meta)) -> :deadline_expired
      true -> nil
    end
  end

  defp undeliverable(_from, _meta), do: nil

  defp request_deadline(%{deadline: deadline}) when is_integer(deadline), do: deadline
  defp request_deadline(_meta), do: nil

  @doc """
  The error for a request Arbor.MCP did not send: `cause` is `:deadline_expired`
  (the caller's deadline passed before it could go out) or `:caller_gone`.
  `Arbor.MCP.Client.delivery_outcome/1` reads it as `:not_sent`.
  """
  @spec not_sent_error(atom(), map()) :: Error.TransportError.t()
  def not_sent_error(cause, state) do
    Error.transport_error(transport_name(Map.get(state, :transport_mod)), :not_sent, %{
      cause: cause,
      message: "The request was not sent (#{cause})."
    })
  end

  @doc false
  @spec transport_name(module() | nil) :: atom()
  def transport_name(HTTP), do: :http
  def transport_name(Arbor.MCP.Transport.HTTP.LegacySSE), do: :sse
  def transport_name(Arbor.MCP.Transport.Stdio), do: :stdio
  def transport_name(Arbor.MCP.Transport.Local), do: :beam
  def transport_name(Arbor.MCP.Transport.Test), do: :test
  def transport_name(transport_mod), do: transport_mod

  @doc false
  def open_subscription(subscription_pid, filter, state)
      when is_pid(subscription_pid) and is_map(filter) do
    if VersionRegistry.modern?(state.protocol_version) do
      id = Protocol.generate_id()

      case build_request("subscriptions/listen", %{"notifications" => filter}, id, state) do
        {:ok, request} ->
          case send_subscription_request(request, state) do
            {:ok, updated_state} ->
              subscriptions = Map.put(updated_state.subscriptions || %{}, id, subscription_pid)
              monitors = ensure_subscription_monitor(subscription_pid, updated_state)

              {:reply, {:ok, id},
               %{updated_state | subscriptions: subscriptions, subscription_monitors: monitors}}

            {:ok, updated_state, _response_data} ->
              {:reply, {:error, :subscription_requires_streaming_transport}, updated_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :subscriptions_require_mcp_2026_07_28}, state}
    end
  end

  @doc false
  def close_subscription(subscription_pid, request_id, reason, state) do
    case Map.get(state.subscriptions || %{}, request_id) do
      ^subscription_pid ->
        state = close_subscription_transport(request_id, reason, state)
        {:noreply, %{state | subscriptions: Map.delete(state.subscriptions, request_id)}}

      _other ->
        {:noreply, state}
    end
  end

  @doc false
  def close_subscriptions_for_pid(subscription_pid, state) do
    request_ids =
      for {request_id, ^subscription_pid} <- state.subscriptions || %{}, do: request_id

    Enum.reduce(request_ids, state, fn request_id, acc ->
      {:noreply, updated} =
        close_subscription(
          subscription_pid,
          request_id,
          "subscription process exited",
          acc
        )

      updated
    end)
  end

  @doc false
  def handle_subscription_stream_closed(request_id, reason, state) do
    case Map.pop(state.subscriptions || %{}, request_id) do
      {subscription_pid, subscriptions} when is_pid(subscription_pid) ->
        if retryable_subscription_stream_close?(reason) do
          send(subscription_pid, {:client_subscription_disconnected, reason})
        else
          send(
            subscription_pid,
            {:client_subscription_error, request_id, {:stream_error, reason}}
          )
        end

        {:noreply, %{state | subscriptions: subscriptions}}

      {nil, _subscriptions} ->
        {:noreply, state}
    end
  end

  defp retryable_subscription_stream_close?({:http_error, status}) when status >= 400,
    do: false

  defp retryable_subscription_stream_close?(:invalid_sse_json), do: false
  defp retryable_subscription_stream_close?(:invalid_stream_message), do: false
  defp retryable_subscription_stream_close?(:response_id_mismatch), do: false
  defp retryable_subscription_stream_close?(:final_response_required), do: false
  defp retryable_subscription_stream_close?(_reason), do: true

  defp send_built_request(method, params, id, from, state, timeout_meta) do
    case build_request(method, params, id, state) do
      {:ok, request} ->
        send_request(request, method, id, from, state, timeout_meta)

      {:error, reason} ->
        {:reply,
         {:error,
          %{
            type: :invalid_request_meta,
            message: "Invalid MCP request metadata: #{format_meta_error(reason)}"
          }}, state}
    end
  end

  defp send_subscription_request(
         request,
         %{
           transport_mod: HTTP,
           transport_state: %HTTP{protocol_era: :modern} = transport_state
         } = state
       ) do
    with {:ok, encoded} <- encode_for_transport(HTTP, request),
         {:ok, transport_state} <-
           HTTP.open_stream(encoded, transport_state, self(), stream_kind: :subscription) do
      {:ok, %{state | transport_state: transport_state}}
    end
  end

  defp send_subscription_request(request, state), do: send_message(request, state)

  defp close_subscription_transport(
         request_id,
         _reason,
         %{
           transport_mod: HTTP,
           transport_state: %HTTP{protocol_era: :modern} = transport_state
         } = state
       ) do
    %{state | transport_state: HTTP.close_stream(transport_state, request_id)}
  end

  defp close_subscription_transport(request_id, reason, state) do
    params = %{"requestId" => request_id}
    params = if is_binary(reason), do: Map.put(params, "reason", reason), else: params
    {:noreply, state} = handle_cast_notification("notifications/cancelled", params, state)
    state
  end

  defp send_request(request, method, id, from, state, meta) do
    deadline = request_deadline(meta)

    case send_by_deadline(request, state, deadline) do
      {:ok, updated_state, response_data} ->
        # Non-SSE HTTP returns response immediately
        case Protocol.parse_message(response_data) do
          {:result, result, _id} ->
            :telemetry.execute(
              [:arbor_mcp, :client, :request, :completed],
              %{},
              %{method: method, request_id: id}
            )

            {:reply, validate_result(result, updated_state, method), updated_state}

          {:error, error_data, _id} ->
            :telemetry.execute(
              [:arbor_mcp, :client, :request, :completed],
              %{},
              %{method: method, request_id: id}
            )

            {:reply, {:error, error_data}, updated_state}

          _ ->
            {:reply, {:error, :invalid_response}, updated_state}
        end

      {:ok, updated_state} ->
        # SSE and streaming transports - track pending request
        maybe_schedule_request_timeout(id, meta, updated_state)
        pending_requests = Map.put(updated_state.pending_requests, id, {from, :single, method})
        new_state = %{updated_state | pending_requests: pending_requests}
        {:noreply, new_state}

      {:error, :not_connected} ->
        {:reply, {:error, :not_connected}, state}

      {:error, :deadline_expired} ->
        # Refused before anything was sent (see BoundedClient).
        {:reply, {:error, not_sent_error(:deadline_expired, state)}, state}

      {:error, reason} ->
        if Deadline.expired?(deadline) do
          # The caller's own timeout: it may already have reported one.
          {:reply, {:error, :timeout}, state}
        else
          {:reply, {:error, send_failure(reason, state)}, state}
        end
    end
  end

  # The transport's reason is kept as a term, so a caller can tell a request
  # that never left (see Arbor.MCP.Client.delivery_outcome/1) from one that may
  # have; `message` is kept for callers that read the text.
  defp send_failure(reason, state) do
    %{
      type: :transport_error,
      transport: transport_name(state.transport_mod),
      reason: reason,
      message: "Failed to send request: #{inspect(reason)}"
    }
  end

  # A synchronous send (HTTP without a stream) runs in the client process;
  # capping it at the caller's deadline frees the client when the caller has
  # given up, instead of holding it for the transport's own request timeout.
  defp send_by_deadline(request, state, nil), do: send_request_message(request, state)

  defp send_by_deadline(request, state, deadline) do
    previous = Deadline.on_transport(state.transport_mod, state.transport_state)

    request
    |> send_request_message(put_transport_deadline(state, deadline))
    |> case do
      {:ok, updated_state, response_data} ->
        {:ok, put_transport_deadline(updated_state, previous), response_data}

      {:ok, updated_state} ->
        {:ok, put_transport_deadline(updated_state, previous)}

      error ->
        error
    end
  end

  defp put_transport_deadline(state, deadline) do
    %{
      state
      | transport_state:
          Deadline.put_on_transport(state.transport_mod, state.transport_state, deadline)
    }
  end

  defp send_request_message(
         %{"params" => %{"_meta" => meta}} = request,
         %{
           transport_mod: HTTP,
           transport_state: %HTTP{protocol_era: :modern} = transport_state
         } = state
       )
       when is_map(meta) do
    stream_requested? =
      Map.has_key?(meta, "progressToken") or
        Map.has_key?(meta, "io.modelcontextprotocol/logLevel")

    if stream_requested? do
      open_request_stream(request, state, transport_state)
    else
      send_message(request, state)
    end
  end

  defp send_request_message(request, state), do: send_message(request, state)

  defp open_request_stream(request, state, transport_state) do
    with {:ok, encoded} <- encode_for_transport(HTTP, request),
         {:ok, transport_state} <-
           HTTP.open_stream(encoded, transport_state, self(), stream_kind: :request) do
      {:ok, %{state | transport_state: transport_state}}
    end
  end

  # When the caller did not provide an explicit timeout, the client process
  # enforces its configured default (resolved from its own state — no extra
  # GenServer round-trips). Stale timers for completed requests are ignored
  # by the {:request_timeout, id} handler.
  defp maybe_schedule_request_timeout(id, %{timeout: nil}, state) do
    timeout = state.default_timeout || 5_000
    Process.send_after(self(), {:request_timeout, id}, timeout)
    :ok
  end

  # An explicit timeout is enforced by the caller's own `GenServer.call/3`,
  # but the client still has to drop its bookkeeping for a request the caller
  # abandoned: a leaked pending entry keeps the client looking permanently
  # busy and suppresses idle health checks. The grace period keeps the
  # caller-side timeout authoritative.
  defp maybe_schedule_request_timeout(id, %{timeout: caller_timeout}, _state)
       when is_integer(caller_timeout) do
    Process.send_after(self(), {:request_timeout, id}, caller_timeout + @caller_timeout_grace)
    :ok
  end

  defp maybe_schedule_request_timeout(_id, _meta, _state), do: :ok

  @doc """
  Handles batch MCP requests.

  Processes multiple MCP requests in a single batch operation.
  """
  def handle_batch_request(requests, from, state) do
    if VersionRegistry.modern?(state.protocol_version) do
      {:reply,
       {:error,
        %{
          type: :unsupported_operation,
          message: "Batch requests are not available in MCP #{state.protocol_version}"
        }}, state}
    else
      do_handle_batch_request(requests, from, state)
    end
  end

  defp do_handle_batch_request(requests, from, state) do
    requests_with_ids =
      Enum.map(requests, fn request ->
        case request do
          # Handle {method, params} tuple format
          {method, params} ->
            id = Protocol.generate_id()
            {id, build_request(method, params, id)}

          # Handle pre-formatted JSON-RPC request map
          %{"method" => _method, "params" => _params, "id" => id} ->
            {id, request}

          # Handle pre-formatted request without ID
          %{"method" => _method, "params" => _params} ->
            id = Protocol.generate_id()
            request_with_id = Map.put(request, "id", id)
            {id, request_with_id}

          # Handle pre-formatted request without params
          %{"method" => _method} = req_map ->
            id = Map.get(req_map, "id", Protocol.generate_id())
            params = Map.get(req_map, "params", %{})
            request_with_id = req_map |> Map.put("id", id) |> Map.put("params", params)
            {id, request_with_id}
        end
      end)

    ordered_ids = Enum.map(requests_with_ids, &elem(&1, 0))
    protocol_requests = Enum.map(requests_with_ids, &elem(&1, 1))

    case send_message(protocol_requests, state) do
      {:ok, updated_state} ->
        batch_id = Protocol.generate_id()
        batch_info = {from, :batch, ordered_ids, %{}}

        new_pending_requests =
          Enum.reduce(ordered_ids, updated_state.pending_requests, fn req_id, acc ->
            Map.put(acc, req_id, batch_id)
          end)
          |> Map.put(batch_id, batch_info)

        new_state = %{updated_state | pending_requests: new_pending_requests}
        {:noreply, new_state}

      {:error, reason} ->
        response =
          {:error,
           %{
             type: :transport_error,
             message: "Failed to send batch request: #{inspect(reason)}"
           }}

        {:reply, response, state}
    end
  end

  @doc """
  Sends the era-appropriate liveness request for the client's idle health
  check: legacy `ping`, or an uncached modern `server/discover`.

  The ping is deliberately kept out of `pending_requests`: it has no caller to
  reply to and must not show up in `Arbor.MCP.Client.get_pending_requests/1`.

  Returns:

  - `{:ok, request_id, state}` - ping sent, the pong will arrive asynchronously
  - `{:ok, nil, state}` - a synchronous transport answered inline, so the
    connection is already proven alive
  - `{:error, reason}` - the ping could not be sent
  """
  @spec send_ping(map()) :: {:ok, term() | nil, map()} | {:error, any()}
  def send_ping(state) do
    id = Protocol.generate_id()

    method =
      if VersionRegistry.modern?(state.protocol_version), do: "server/discover", else: "ping"

    with {:ok, request} <- build_request(method, %{}, id, state) do
      case send_message(request, state) do
        {:ok, updated_state, _response_data} -> {:ok, nil, updated_state}
        {:ok, updated_state} -> {:ok, id, updated_state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Parses a message from the transport.

  This function is intended to be called from the client's `handle_info/2` callback.
  It decodes the message and delegates to the appropriate response handler.
  """
  def parse_transport_message(message, state) do
    case Protocol.parse_message(message) do
      {:result, result, id} ->
        handle_single_response({:result, result, id}, state)

      {:error, error, id} ->
        handle_single_response({:error, error, id}, state)

      {:notification, "notifications/subscriptions/acknowledged", params} ->
        route_subscription_acknowledgment(params, state)

      {:notification, method, params}
      when method in [
             "notifications/tools/list_changed",
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/resources/updated"
           ] ->
        route_change_notification(method, params, state)

      {:notification, "notifications/tasks" = method, params} ->
        route_task_subscription_event(method, params, state)

      {:notification, "notifications/cancelled", params} ->
        Logger.info("Received notification: notifications/cancelled")
        handle_cancellation_notification(params, state)

      {:notification, method, _params} ->
        Logger.info("Received unsupported notification",
          method_hash: LogSummary.fingerprint(method)
        )

        {:noreply, state}

      {:request, method, params, id} ->
        handle_server_request(method, params, id, state)

      {:batch, responses} ->
        # NOTE: Batch support is deprecated in protocol version 2025-06-18
        # but maintained for backward compatibility with older versions
        parsed_responses = Protocol.parse_batch_response(responses)
        handle_batch_response(parsed_responses, state)

      {:error, reason} ->
        Logger.error("Failed to parse transport message",
          reason_shape: LogSummary.describe(reason)
        )

        {:noreply, state}
    end
  end

  @doc false
  def handle_request_stream_message(
        request_id,
        %{"method" => "notifications/progress", "params" => params},
        state
      )
      when is_map(params) do
    dispatch_request_notification(:handle_progress, request_id, params, state)
  end

  def handle_request_stream_message(
        request_id,
        %{"method" => "notifications/message", "params" => params},
        state
      )
      when is_map(params) do
    dispatch_request_notification(:handle_log_message, request_id, params, state)
  end

  def handle_request_stream_message(_request_id, message, state) do
    parse_transport_message(message, state)
  end

  @doc false
  def handle_modern_stream_closed(request_id, reason, state) do
    case Map.get(state.subscriptions || %{}, request_id) do
      subscription_pid when is_pid(subscription_pid) ->
        handle_subscription_stream_closed(request_id, reason, state)

      _other ->
        case Map.get(state.pending_requests, request_id) do
          {from, :single, _method} ->
            error = request_stream_error(reason)

            GenServer.reply(from, {:error, error})

            {:noreply,
             %{state | pending_requests: Map.delete(state.pending_requests, request_id)}}

          {from, :single} ->
            error = request_stream_error(reason)

            GenServer.reply(from, {:error, error})

            {:noreply,
             %{state | pending_requests: Map.delete(state.pending_requests, request_id)}}

          _not_pending ->
            {:noreply, state}
        end
    end
  end

  @doc false
  def close_request_stream(
        request_id,
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{protocol_era: :modern} = transport_state
        } = state
      ) do
    %{state | transport_state: HTTP.close_stream(transport_state, request_id)}
  end

  def close_request_stream(_request_id, state), do: state

  defp request_stream_error(reason) do
    if ambiguous_stream_break?(reason) do
      %Error.TransportError{
        transport: :http,
        reason: :response_stream_broken,
        details: %{cause: reason, delivery: :ambiguous}
      }
    else
      %Error.TransportError{
        transport: :http,
        reason: :response_stream_invalid,
        details: %{cause: reason, delivery: :not_retryable}
      }
    end
  end

  defp ambiguous_stream_break?({:http_error, _status}), do: false

  defp ambiguous_stream_break?(reason)
       when reason in [
              :invalid_sse_json,
              :invalid_stream_message,
              :response_id_mismatch,
              :final_response_required
            ],
       do: false

  defp ambiguous_stream_break?(_reason), do: true

  @doc """
  Handles a batch of responses from the transport.
  """
  def handle_batch_response(responses, state) do
    Enum.reduce(responses, {:noreply, state}, fn response, {:noreply, current_state} ->
      handle_single_response(response, current_state)
    end)
  end

  @doc """
  Handles a single response from the transport.
  """
  def handle_single_response({:result, result, response_id}, state) do
    method = pending_request_method(state.pending_requests, response_id)
    handle_response_by_id(response_id, validate_result(result, state, method), state)
  end

  def handle_single_response({:error, error, response_id}, state) do
    # Keep raw error data - let format handling in make_request decide how to format it
    handle_response_by_id(response_id, {:error, error}, state)
  end

  def handle_single_response(other, state) do
    Logger.warning("Received unexpected response format: #{LogSummary.describe(other)}")

    {:noreply, state}
  end

  # Reply to the client's own health-check ping. Any answer — result or
  # error — proves the connection is alive, so the outstanding ping is simply
  # cleared. These ids are never in pending_requests.
  defp handle_response_by_id(response_id, _response_data, %{health_check_id: ping_id} = state)
       when not is_nil(ping_id) and response_id == ping_id do
    {:noreply, %{state | health_check_id: nil, last_activity: System.system_time(:second)}}
  end

  defp handle_response_by_id(response_id, response_data, state) do
    if is_nil(response_id) do
      # Check if this is a batch validation error - if we have any pending batch requests,
      # route the error to the first one (batch errors apply to the entire batch)
      case find_pending_batch_request(state.pending_requests) do
        {batch_id, {from, :batch, ordered_ids, _received_responses}} ->
          GenServer.reply(from, response_data)
          # Clean up all individual request IDs and the batch ID
          new_pending_requests =
            Enum.reduce(ordered_ids, state.pending_requests, &Map.delete(&2, &1))
            |> Map.delete(batch_id)

          new_state = %{state | pending_requests: new_pending_requests}
          {:noreply, new_state}

        nil ->
          Logger.warning("Received response without an ID: #{LogSummary.describe(response_data)}")

          {:noreply, state}
      end
    else
      case Map.pop(state.subscriptions || %{}, response_id) do
        {subscription_pid, subscriptions} when is_pid(subscription_pid) ->
          route_subscription_response(subscription_pid, response_id, response_data)
          {:noreply, %{state | subscriptions: subscriptions}}

        {nil, _subscriptions} ->
          handle_pending_response(response_id, response_data, state)
      end
    end
  end

  defp handle_pending_response(response_id, response_data, state) do
    pending_requests = state.pending_requests

    new_state =
      case get_request_info(pending_requests, response_id) do
        {:ok, {from, :single, method}} ->
          :telemetry.execute(
            [:arbor_mcp, :client, :request, :completed],
            %{},
            %{method: method, request_id: response_id}
          )

          GenServer.reply(from, response_data)
          new_pending_requests = Map.delete(pending_requests, response_id)
          %{state | pending_requests: new_pending_requests}

        {:ok, {from, :single}} ->
          :telemetry.execute(
            [:arbor_mcp, :client, :request, :completed],
            %{},
            %{method: nil, request_id: response_id}
          )

          GenServer.reply(from, response_data)
          new_pending_requests = Map.delete(pending_requests, response_id)
          %{state | pending_requests: new_pending_requests}

        {:ok, {:batch, batch_id}} ->
          handle_batch_response_item(response_data, response_id, batch_id, state)

        :error ->
          Logger.warning("Received response for unknown request ID",
            request_id_hash: LogSummary.fingerprint(response_id)
          )

          state
      end

    {:noreply, new_state}
  end

  defp dispatch_request_notification(callback, request_id, params, state) do
    :telemetry.execute(
      [:arbor_mcp, :client, :request, :notification],
      %{count: 1},
      %{request_id: request_id, method: callback}
    )

    {handler, handler_state, state} = ensure_client_handler(state)

    if handler != :none and function_exported?(handler, callback, 3) do
      case apply(handler, callback, [request_id, params, handler_state]) do
        {:ok, new_handler_state} ->
          {:noreply, update_handler_state(state, new_handler_state)}

        {:error, reason, new_handler_state} ->
          Logger.warning("Client request notification handler failed",
            reason_shape: LogSummary.describe(reason)
          )

          {:noreply, update_handler_state(state, new_handler_state)}

        other ->
          Logger.warning("Invalid client request notification handler reply",
            reply_shape: LogSummary.describe(other)
          )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  rescue
    error ->
      Logger.warning("Client request notification handler raised",
        error_class: LogSummary.describe(error)
      )

      {:noreply, state}
  end

  defp get_request_info(pending_requests, response_id) do
    case Map.get(pending_requests, response_id) do
      nil ->
        :error

      {_from, :single} = single_request_info ->
        {:ok, single_request_info}

      {_from, :single, _method} = single_request_info ->
        {:ok, single_request_info}

      batch_id ->
        {:ok, {:batch, batch_id}}
    end
  end

  defp handle_batch_response_item(response_data, response_id, batch_id, state) do
    pending_requests = state.pending_requests

    case Map.get(pending_requests, batch_id) do
      {from, :batch, ordered_ids, received_responses} ->
        # response_data is already parsed: {:ok, result} or {:error, error}
        new_received = Map.put(received_responses, response_id, response_data)

        if map_size(new_received) == length(ordered_ids) do
          # Batch complete
          final_responses = Enum.map(ordered_ids, &new_received[&1])
          GenServer.reply(from, {:ok, final_responses})

          # Clean up
          new_pending_requests =
            Enum.reduce(ordered_ids, pending_requests, &Map.delete(&2, &1))
            |> Map.delete(batch_id)

          %{state | pending_requests: new_pending_requests}
        else
          # Batch not yet complete
          new_batch_info = {from, :batch, ordered_ids, new_received}
          new_pending_requests = Map.put(pending_requests, batch_id, new_batch_info)
          %{state | pending_requests: new_pending_requests}
        end

      _ ->
        Logger.error("Inconsistent batch response state",
          batch_id_hash: LogSummary.fingerprint(batch_id),
          request_id_hash: LogSummary.fingerprint(response_id)
        )

        state
    end
  end

  @doc """
  Handles a notification to be sent to the server.
  """
  def handle_cast_notification(method, params, state) do
    # Use the connection metadata policy while omitting the notification id.
    result =
      with {:ok, notification} <- build_request(method, params, nil, state) do
        send_message(notification, state)
      end

    case result do
      {:ok, updated_state, _response_data} ->
        # Non-SSE HTTP returns response but we ignore it for notifications
        {:noreply, updated_state}

      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, :not_connected} ->
        # This is expected in tests when clients are disconnected
        Logger.debug("Cannot send notification: client not connected")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to send notification",
          reason_shape: LogSummary.describe(reason)
        )

        {:noreply, state}
    end
  end

  @doc """
  Encodes and sends a message via the transport.
  """
  def send_message(message, state) do
    %{transport_mod: transport_mod, transport_state: transport_state} = state

    # Check if transport is available
    if transport_mod == nil or transport_state == nil do
      {:error, :not_connected}
    else
      with {:ok, outbound_message} <- encode_for_transport(transport_mod, message) do
        case transport_mod.send_message(outbound_message, transport_state) do
          {:ok, new_transport_state, response_data} ->
            # Non-SSE HTTP returns response immediately
            {:ok, %{state | transport_state: new_transport_state}, response_data}

          {:ok, new_transport_state} ->
            # SSE and other streaming transports return 2-tuple
            {:ok, %{state | transport_state: new_transport_state}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp encode_for_transport(Arbor.MCP.Transport.Local, message), do: {:ok, message}
  defp encode_for_transport(_transport_mod, message), do: Protocol.encode_to_string(message)

  defp find_pending_batch_request(pending_requests) do
    Enum.find(pending_requests, fn
      {_id, {_from, :batch, _ordered_ids, _received_responses}} -> true
      _ -> false
    end)
  end

  defp build_request(method, params, id) do
    method
    |> JSONRPC.request(params || %{})
    |> Maps.put_present("id", id)
  end

  defp build_request(method, params, id, state) do
    with {:ok, params} <- RequestParams.for_request(params || %{}, state) do
      {:ok, build_request(method, params, id)}
    end
  end

  defp ensure_subscription_monitor(subscription_pid, state) do
    monitors = state.subscription_monitors || %{}

    if Enum.any?(monitors, fn {_ref, pid} -> pid == subscription_pid end) do
      monitors
    else
      Map.put(monitors, Process.monitor(subscription_pid), subscription_pid)
    end
  end

  defp route_subscription_acknowledgment(params, state) do
    request_id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    case Map.get(state.subscriptions || %{}, request_id) do
      subscription_pid when is_pid(subscription_pid) ->
        send(subscription_pid, {:client_subscription_acknowledged, request_id, params})
        {:noreply, state}

      _other ->
        Logger.warning("Received acknowledgment for unknown subscription")
        {:noreply, state}
    end
  end

  # Modern peers correlate every list-change and resource-update event with a
  # subscription id, and that path is unchanged. Legacy peers deliver the same
  # methods on the connection with no correlation, so those go to the locally
  # registered notification listeners instead.
  defp route_change_notification(method, params, state) do
    cond do
      subscription_event?(params) ->
        route_subscription_event(method, params, state)

      VersionRegistry.modern?(Map.get(state, :protocol_version)) ->
        route_subscription_event(method, params, state)

      true ->
        route_legacy_notification(method, params, state)
    end
  end

  defp subscription_event?(params) do
    is_map(params) and
      get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"]) != nil
  end

  defp route_legacy_notification(method, params, state) do
    params = if is_map(params), do: params, else: %{}
    listeners = Map.get(state, :notification_listeners) || %{}

    if NotificationListener.dispatch(listeners, method, params) == 0 do
      Logger.debug("Legacy notification had no matching listener", method: method)
    end

    {:noreply, state}
  end

  defp route_subscription_event(method, params, state) do
    request_id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    case Map.get(state.subscriptions || %{}, request_id) do
      subscription_pid when is_pid(subscription_pid) ->
        send(subscription_pid, {:client_subscription_event, request_id, method, params})
        {:noreply, state}

      _other ->
        Logger.warning("Received event for unknown subscription")
        {:noreply, state}
    end
  end

  defp route_task_subscription_event(method, params, state) do
    client_capabilities =
      state
      |> Map.get(:transport_opts, [])
      |> Keyword.get(:capabilities, %{})

    with true <- TasksExtension.declared?(client_capabilities),
         :ok <- TasksExtension.validate_task_result(params, :detailed) do
      route_subscription_event(method, params, state)
    else
      _invalid ->
        Logger.warning("Received an invalid or undeclared task subscription notification")
        {:noreply, state}
    end
  end

  defp route_subscription_response(subscription_pid, request_id, {:ok, result}) do
    send(subscription_pid, {:client_subscription_complete, request_id, result})
  end

  defp route_subscription_response(subscription_pid, request_id, {:error, error}) do
    send(subscription_pid, {:client_subscription_error, request_id, error})
  end

  defp format_meta_error({:invalid_meta_key, key}),
    do: "metadata key #{inspect(key)} does not follow the MCP key grammar"

  defp format_meta_error({:missing_meta_field, key}), do: "required field #{key} is missing"
  defp format_meta_error({:invalid_meta_field, key}), do: "field #{key} has an invalid value"
  defp format_meta_error({:invalid_meta, :not_an_object}), do: "_meta must be an object"

  defp pending_request_method(pending_requests, response_id) do
    case Map.get(pending_requests, response_id) do
      {_from, :single, method} when is_binary(method) -> method
      _other -> nil
    end
  end

  defp validate_result(result, state, method) do
    transport_opts = Map.get(state, :transport_opts) || []
    client_capabilities = Keyword.get(transport_opts, :capabilities, %{})
    modern? = VersionRegistry.modern?(Map.get(state, :protocol_version))
    tasks_declared? = TasksExtension.declared?(client_capabilities)

    allowed_result_types =
      transport_opts
      |> Keyword.get(:allowed_result_types, [])
      |> List.wrap()
      |> Enum.reject(&(&1 == TasksExtension.result_type()))
      |> Kernel.++(TasksExtension.allowed_result_types(client_capabilities))
      |> Enum.uniq()

    result
    |> ResultEnvelope.validate(Map.get(state, :protocol_version),
      allowed_result_types: allowed_result_types,
      method: method
    )
    |> validate_result_envelope(method, modern?, tasks_declared?)
  end

  defp validate_result_envelope(
         {:ok, :complete, result},
         "tasks/get",
         true,
         true
       ),
       do: validate_task_result(result, :detailed)

  defp validate_result_envelope({:ok, :complete, _result}, "tasks/get", true, false) do
    {:error,
     %{
       type: :protocol_error,
       reason: :undeclared_tasks_extension,
       message: "MCP tasks/get requires the configured Tasks extension"
     }}
  end

  defp validate_result_envelope({:ok, {:extension, "task"}, result}, method, _modern?, _tasks?)
       when method != "tasks/get",
       do: validate_task_result(result, :create)

  defp validate_result_envelope(
         {:ok, {:extension, "task"}, _result},
         "tasks/get",
         _modern?,
         _tasks?
       ) do
    {:error,
     %{
       type: :protocol_error,
       reason: {:invalid_result_type, "task"},
       message: "MCP tasks/get resultType must be complete"
     }}
  end

  defp validate_result_envelope({:ok, :complete, result}, "tools/list", true, _tasks?) do
    {:ok,
     Map.update(result, "tools", [], fn tools ->
       if is_list(tools), do: ToolHeaders.filter_valid_tools(tools), else: tools
     end)}
  end

  defp validate_result_envelope({:ok, _kind, result}, _method, _modern?, _tasks?),
    do: {:ok, result}

  defp validate_result_envelope({:error, reason}, _method, _modern?, _tasks?) do
    {:error,
     %{
       type: :protocol_error,
       reason: reason,
       message: result_error_message(reason)
     }}
  end

  defp validate_task_result(result, mode) do
    case TasksExtension.validate_task_result(result, mode) do
      :ok ->
        {:ok, result}

      {:error, reason} ->
        {:error,
         %{
           type: :protocol_error,
           reason: reason,
           message: "MCP task result has an invalid wire shape"
         }}
    end
  end

  defp result_error_message(:result_must_be_object), do: "MCP result must be an object"

  defp result_error_message(:missing_result_type),
    do: "MCP result is missing required resultType"

  defp result_error_message({:invalid_result_type, _value}),
    do: "MCP resultType must be a string"

  defp result_error_message({:unknown_result_type, type}),
    do: "MCP resultType #{inspect(type)} was not negotiated"

  defp result_error_message(:missing_ttl_ms),
    do: "MCP cacheable result is missing required ttlMs"

  defp result_error_message({:invalid_ttl_ms, _value}),
    do: "MCP cacheable result ttlMs must be a non-negative integer"

  defp result_error_message(:missing_cache_scope),
    do: "MCP cacheable result is missing required cacheScope"

  defp result_error_message({:invalid_cache_scope, _value}),
    do: ~s(MCP cacheable result cacheScope must be "public" or "private")

  defp result_error_message(:cache_hints_not_allowed),
    do: "MCP non-complete result must not include cache hints"

  @doc """
  Routes a legacy server-to-client request to the appropriate handler callback.

  Modern MCP 2026-07-28 supplies client input through MRTR result envelopes;
  it does not deliver these as independent JSON-RPC requests on the stream.
  """
  def handle_server_request(method, params, request_id, state) do
    case method do
      "ping" ->
        handle_ping_request(params, request_id, state)

      "roots/list" ->
        handle_roots_list_request(params, request_id, state)

      "sampling/createMessage" ->
        handle_create_message_request(params, request_id, state)

      "elicitation/create" ->
        if Map.get(params, "mode") == "url" do
          handle_url_elicitation_request(params, request_id, state)
        else
          handle_elicitation_create_request(params, request_id, state)
        end

      _ ->
        # Try generic handler, then fall back to method not found
        handle_generic_server_request(method, params, request_id, state)
    end
  end

  defp handle_ping_request(_params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)

    if handler != :none && function_exported?(handler, :handle_ping, 1) do
      case handler.handle_ping(handler_state) do
        {:ok, result, new_handler_state} ->
          state = update_handler_state(state, new_handler_state)
          send_response(build_success_response(result, request_id), state)

        {:error, error, new_handler_state} ->
          state = update_handler_state(state, new_handler_state)
          send_response(handler_error_response(error, request_id), state)
      end
    else
      # Ping is a protocol-level operation - always respond with success
      # regardless of whether a client handler exists
      response = build_success_response(%{}, request_id)
      send_response(response, state)
    end
  end

  defp handle_roots_list_request(_params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)
    capabilities = Keyword.get(state.transport_opts, :capabilities, %{})

    dispatch_input_sync(
      "roots/list",
      %{},
      handler,
      handler_state,
      capabilities,
      request_id,
      state
    )
  end

  defp handle_create_message_request(params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)
    capabilities = Keyword.get(state.transport_opts, :capabilities, %{})

    if client_callback?(handler, :handle_create_message, 2) do
      run_handler_async(
        :input_request,
        fn ->
          InputDispatcher.dispatch(
            "sampling/createMessage",
            params,
            handler,
            handler_state,
            capabilities
          )
        end,
        request_id,
        state
      )
    else
      dispatch_input_sync(
        "sampling/createMessage",
        params,
        handler,
        handler_state,
        capabilities,
        request_id,
        state
      )
    end
  end

  defp handle_elicitation_create_request(params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)
    capabilities = Keyword.get(state.transport_opts, :capabilities, %{})

    if client_callback?(handler, :handle_elicitation_create, 3) or
         elicitation_capability?(capabilities) do
      run_handler_async(
        :input_request,
        fn ->
          InputDispatcher.dispatch(
            "elicitation/create",
            params,
            handler,
            handler_state,
            capabilities
          )
        end,
        request_id,
        state
      )
    else
      dispatch_input_sync(
        "elicitation/create",
        params,
        handler,
        handler_state,
        capabilities,
        request_id,
        state
      )
    end
  end

  defp handle_url_elicitation_request(params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)
    capabilities = Keyword.get(state.transport_opts, :capabilities, %{})

    if client_callback?(handler, :handle_url_elicitation, 3) or
         client_callback?(handler, :handle_elicitation_create, 3) or
         elicitation_capability?(capabilities) do
      run_handler_async(
        :input_request,
        fn ->
          InputDispatcher.dispatch(
            "elicitation/create",
            params,
            handler,
            handler_state,
            capabilities
          )
        end,
        request_id,
        state
      )
    else
      dispatch_input_sync(
        "elicitation/create",
        params,
        handler,
        handler_state,
        capabilities,
        request_id,
        state
      )
    end
  end

  defp dispatch_input_sync(
         method,
         params,
         handler,
         handler_state,
         capabilities,
         request_id,
         state
       ) do
    callback_return =
      InputDispatcher.dispatch(method, params, handler, handler_state, capabilities)

    {response, state} = map_callback_return(:input_request, callback_return, request_id, state)
    send_response(response, state)
  end

  defp client_callback?(:none, _fun, _arity), do: false

  defp client_callback?(handler, fun, arity) do
    function_exported?(handler, fun, arity) or
      (Code.ensure_loaded?(handler) and function_exported?(handler, fun, arity))
  end

  defp elicitation_capability?(capabilities) when is_map(capabilities) do
    Map.has_key?(capabilities, "elicitation") or Map.has_key?(capabilities, :elicitation)
  end

  defp elicitation_capability?(_capabilities), do: false

  # Extract module and handler args from the handler option.
  # The handler can be specified as just a module or as {module, args}.
  defp extract_handler_info(state) do
    raw_handler = Keyword.get(state.transport_opts, :handler)
    default_handler_state = Keyword.get(state.transport_opts, :handler_state, [])

    case raw_handler do
      {module, args} when is_atom(module) and is_list(args) ->
        Code.ensure_loaded(module)
        {module, args}

      module when is_atom(module) and not is_nil(module) ->
        Code.ensure_loaded(module)
        {module, default_handler_state}

      _ ->
        {nil, default_handler_state}
    end
  end

  defp handle_cancellation_notification(params, state) do
    request_id = Map.get(params, "requestId")

    if request_id do
      # Mark request as cancelled
      updated_state = %{
        state
        | cancelled_requests: MapSet.put(state.cancelled_requests, request_id)
      }

      # Check if this request is still pending and complete it with :cancelled error
      case Map.get(state.pending_requests, request_id) do
        nil ->
          # Request already completed or doesn't exist
          {:noreply, updated_state}

        {from, :single, _method} ->
          # Reply with cancelled error and remove from pending
          GenServer.reply(from, {:error, :cancelled})
          new_pending = Map.delete(state.pending_requests, request_id)
          {:noreply, %{updated_state | pending_requests: new_pending}}

        {from, :single} ->
          # Reply with cancelled error and remove from pending
          GenServer.reply(from, {:error, :cancelled})
          new_pending = Map.delete(state.pending_requests, request_id)
          {:noreply, %{updated_state | pending_requests: new_pending}}

        _ ->
          # Other types of requests (batch, etc.)
          {:noreply, updated_state}
      end
    else
      Logger.warning("Received cancellation notification without requestId")
      {:noreply, state}
    end
  end

  defp build_success_response(result, request_id) do
    ResponseBuilder.build_success_response(result, request_id)
  end

  defp build_error_response(code, message, request_id) do
    ResponseBuilder.build_error_response(code, message, nil, request_id)
  end

  defp handle_generic_server_request(method, params, request_id, state) do
    {handler, handler_state, state} = ensure_client_handler(state)

    if handler != :none &&
         function_exported?(handler, :handle_server_request, 3) do
      run_handler_async(
        :generic,
        fn -> handler.handle_server_request(method, params, handler_state) end,
        request_id,
        state
      )
    else
      error_response = build_error_response(-32601, "Method not found", request_id)
      send_response(error_response, state)
    end
  end

  # -- Client handler lifecycle -------------------------------------------

  # Initializes the configured client handler once and memoizes it in the
  # client state; subsequent callbacks reuse (and update) the same handler
  # state, so stateful client handlers work.
  defp ensure_client_handler(%{client_handler: {module, handler_state}} = state) do
    {module, handler_state, state}
  end

  defp ensure_client_handler(%{client_handler: :none} = state) do
    {:none, %{}, state}
  end

  defp ensure_client_handler(state) do
    case extract_handler_info(state) do
      {nil, _opts} ->
        {:none, %{}, %{state | client_handler: :none}}

      {module, opts} ->
        handler_state =
          case module.init(opts) do
            {:ok, initial_state} -> initial_state
            _ -> %{}
          end

        {module, handler_state, %{state | client_handler: {module, handler_state}}}
    end
  end

  defp update_handler_state(%{client_handler: {module, _old}} = state, new_handler_state) do
    %{state | client_handler: {module, new_handler_state}}
  end

  defp update_handler_state(state, _new_handler_state), do: state

  @doc false
  def handle_mrtr_fulfillment(input_requests, opts, scope_ref, from, state) do
    if VersionRegistry.modern?(state.protocol_version) do
      {handler, handler_state, state} = ensure_client_handler(state)
      capabilities = Keyword.get(state.transport_opts, :capabilities, %{})
      parent = self()

      {pid, ref} =
        ConnectionScope.spawn_monitor(fn ->
          outcome =
            try do
              MRTR.fulfill(input_requests, handler, handler_state, capabilities, opts)
            rescue
              error -> {:error, {:client_handler_raised, error, __STACKTRACE__}, handler_state}
            catch
              kind, value -> {:error, {:client_handler_caught, {kind, value}}, handler_state}
            end

          Lifetime.deliver(parent, {:mrtr_fulfillment_result, self(), outcome})
        end)

      tasks = Map.put(state.mrtr_tasks || %{}, pid, {ref, from, scope_ref})
      {:noreply, %{state | mrtr_tasks: tasks}}
    else
      {:reply,
       {:error,
        Error.protocol_error(
          ErrorCodes.invalid_params(),
          "MRTR requires MCP 2026-07-28"
        )}, state}
    end
  end

  @doc false
  def handle_mrtr_fulfillment_completion(task_pid, outcome, state) do
    case Map.pop(state.mrtr_tasks || %{}, task_pid) do
      {nil, _tasks} ->
        {:noreply, state}

      {{ref, from, _scope_ref}, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | mrtr_tasks: tasks}

        case outcome do
          {:ok, responses, new_handler_state} ->
            GenServer.reply(from, {:ok, responses})
            {:noreply, update_handler_state(state, new_handler_state)}

          {:error, reason, new_handler_state} ->
            GenServer.reply(from, {:error, normalize_mrtr_error(reason)})
            {:noreply, update_handler_state(state, new_handler_state)}
        end
    end
  end

  @doc false
  def handle_mrtr_fulfillment_down(task_pid, reason, state) do
    case Map.pop(state.mrtr_tasks || %{}, task_pid) do
      {nil, _tasks} ->
        {:noreply, state}

      {{_ref, from, _scope_ref}, tasks} ->
        Logger.error("MRTR input handler task exited",
          reason_shape: LogSummary.describe(reason)
        )

        GenServer.reply(
          from,
          {:error,
           Error.protocol_error(
             ErrorCodes.internal_error(),
             "MRTR input handler failed"
           )}
        )

        {:noreply, %{state | mrtr_tasks: tasks}}
    end
  end

  @doc false
  def cancel_mrtr_scope(scope_ref, state) do
    {cancelled, remaining} =
      Enum.split_with(state.mrtr_tasks || %{}, fn {_pid, {_ref, _from, task_scope}} ->
        task_scope == scope_ref
      end)

    Enum.each(cancelled, fn {pid, {ref, _from, _task_scope}} ->
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
    end)

    {:noreply, %{state | mrtr_tasks: Map.new(remaining)}}
  end

  defp normalize_mrtr_error(%Error.ProtocolError{} = error), do: error

  defp normalize_mrtr_error(reason) do
    Logger.error("MRTR input handler failed",
      reason_shape: LogSummary.describe(reason)
    )

    Error.protocol_error(
      ErrorCodes.internal_error(),
      "MRTR input handler failed"
    )
  end

  # Runs a potentially slow client handler callback (LLM sampling, user
  # elicitation, custom methods) in an unlinked monitored process so it
  # cannot head-of-line-block the client loop. The result is delivered via
  # `handle_server_request_completion/3`; crashes via
  # `handle_server_request_down/3`.
  defp run_handler_async(kind, fun, request_id, state) do
    parent = self()

    {pid, ref} =
      ConnectionScope.spawn_monitor(fn ->
        outcome =
          try do
            {:ok, fun.()}
          rescue
            error -> {:handler_raised, error, __STACKTRACE__}
          catch
            thrown_kind, value -> {:handler_caught, {thrown_kind, value}}
          end

        Lifetime.deliver(parent, {:server_request_result, self(), outcome})
      end)

    tasks = Map.put(state.server_request_tasks || %{}, pid, {ref, request_id, kind})
    {:noreply, %{state | server_request_tasks: tasks}}
  end

  @doc false
  # Completion of an async server-request handler task.
  def handle_server_request_completion(task_pid, outcome, state) do
    case Map.pop(state.server_request_tasks || %{}, task_pid) do
      {nil, _tasks} ->
        {:noreply, state}

      {{ref, request_id, kind}, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | server_request_tasks: tasks}

        case outcome do
          {:ok, callback_return} ->
            {response, state} = map_callback_return(kind, callback_return, request_id, state)
            send_response(response, state)

          {:handler_raised, error, _stacktrace} ->
            Logger.error("Client handler raised",
              handler_kind: kind,
              error_class: LogSummary.describe(error)
            )

            send_response(internal_handler_error(request_id), state)

          {:handler_caught, detail} ->
            Logger.error("Client handler exited",
              handler_kind: kind,
              detail_shape: LogSummary.describe(detail)
            )

            send_response(internal_handler_error(request_id), state)
        end
    end
  end

  @doc false
  # An async handler task died without delivering a result.
  def handle_server_request_down(task_pid, reason, state) do
    case Map.pop(state.server_request_tasks || %{}, task_pid) do
      {nil, _tasks} ->
        {:noreply, state}

      {{_ref, request_id, kind}, tasks} ->
        state = %{state | server_request_tasks: tasks}

        Logger.error("Client handler task exited",
          handler_kind: kind,
          reason_shape: LogSummary.describe(reason)
        )

        send_response(internal_handler_error(request_id), state)
    end
  end

  defp map_callback_return(kind, callback_return, request_id, state) do
    case callback_return do
      {:ok, result, new_handler_state} ->
        state = update_handler_state(state, new_handler_state)
        {build_success_response(wrap_result(kind, result), request_id), state}

      {:error, error, new_handler_state} ->
        state = update_handler_state(state, new_handler_state)
        {kind_error_response(kind, error, request_id), state}

      other ->
        Logger.error("Client handler returned unexpected value",
          handler_kind: kind,
          reply_shape: LogSummary.describe(other)
        )

        {internal_handler_error(request_id), state}
    end
  end

  defp wrap_result(:roots, roots), do: %{"roots" => roots}
  defp wrap_result(_kind, result), do: result

  defp kind_error_response(:create_message, error, request_id) do
    # Sampling errors may carry an explicit JSON-RPC code/message.
    case error do
      %{"code" => code, "message" => message} when is_integer(code) and is_binary(message) ->
        build_error_response(code, message, request_id)

      _ ->
        handler_error_response(error, request_id)
    end
  end

  defp kind_error_response(:input_request, %Error.ProtocolError{} = error, request_id) do
    message =
      if error.code == ErrorCodes.method_not_found(),
        do: "Method not found",
        else: error.message

    build_error_response(error.code, message, request_id)
  end

  # Existing sampling and elicitation handlers may deliberately return a
  # JSON-RPC error map. Preserve that explicit public message while continuing
  # to replace arbitrary terms with the generic internal-handler error below.
  defp kind_error_response(
         :input_request,
         %{"code" => code, "message" => message},
         request_id
       )
       when is_integer(code) and is_binary(message) do
    build_error_response(code, message, request_id)
  end

  defp kind_error_response(_kind, error, request_id) do
    handler_error_response(error, request_id)
  end

  # Builds a -32603 response from a handler-provided error without leaking
  # arbitrary internal terms to the server: binaries pass through, anything
  # else is logged and replaced with a generic message.
  defp handler_error_response(error, request_id) when is_binary(error) do
    build_error_response(-32603, error, request_id)
  end

  defp handler_error_response(error, request_id) do
    Logger.error("Client handler error",
      error_shape: LogSummary.describe(error)
    )

    internal_handler_error(request_id)
  end

  defp internal_handler_error(request_id) do
    build_error_response(-32603, "Internal error in client handler", request_id)
  end

  defp send_response(response, state) do
    case send_message(response, state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:ok, updated_state, response_data} ->
        # Synchronous transports (non-SSE HTTP) may return a body inline even
        # for replies to server-initiated requests. Any payload is delivered
        # through the normal parse path instead of crashing on the 3-tuple.
        case response_data do
          data when data in [nil, ""] ->
            {:noreply, updated_state}

          data ->
            parse_transport_message(data, updated_state)
        end

      {:error, reason} ->
        Logger.error("Failed to send response to server",
          reason_shape: LogSummary.describe(reason)
        )

        {:noreply, state}
    end
  end
end
