defmodule Arbor.MCP.Client.RequestHandler do
  @moduledoc """
  Request/response processing for ArborMCP client.

  This module handles all request processing, batch operations, message parsing,
  and response handling for MCP clients.
  """

  require Logger
  alias Arbor.MCP.Client.{ConnectionScope, HTTPAuth, Lifetime}
  alias Arbor.MCP.Client.{Deadline, InputDispatcher, MRTR, NotificationListener, ResponseCache}
  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.{Maps, Protocol, RequestParams, VersionRegistry}
  alias Arbor.MCP.Protocol.{ErrorCodes, ResponseBuilder, ResultEnvelope}
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.LegacySSE
  alias Arbor.MCP.Transport.HTTP.ToolHeaders
  alias Arbor.RPC.{JSONRPC, LogSummary}

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
        case cached_result(method, params, meta, state) do
          {:ok, result} ->
            {:reply, {:ok, result}, state}

          :miss ->
            id = Protocol.generate_id()
            send_built_request(method, params, id, from, state, meta)
        end

      cause ->
        {:reply, {:error, not_sent_error(cause, state)}, state}
    end
  end

  # A result the server said is still fresh is answered without asking it
  # again (see ResponseCache), unless the call asked to refresh or bypass it.
  # Only while connected: a disconnected client says so.
  defp cached_result(method, params, meta, state) do
    with :use <- Map.get(meta, :cache_mode, :use),
         :ready <- Map.get(state, :connection_status),
         %ResponseCache{} = cache <- Map.get(state, :response_cache),
         {:ok, result} <- ResponseCache.lookup(cache, ResponseCache.key(method, params), now()) do
      :telemetry.execute([:arbor_mcp, :client, :cache, :hit], %{}, %{method: method})
      {:ok, result}
    else
      _miss_or_not_used -> :miss
    end
  end

  # Remembers what a cacheable request in flight will answer.
  defp track_cacheable(state, id, request, meta) do
    case {Map.get(meta, :cache_mode, :use), Map.get(state, :response_cache)} do
      {mode, %ResponseCache{} = cache} when mode != :bypass ->
        key = ResponseCache.key(request["method"], request["params"])
        pending? = &Map.has_key?(state.pending_requests, &1)
        %{state | response_cache: ResponseCache.track(cache, id, key, pending?)}

      _bypassed_or_none ->
        state
    end
  end

  defp cache_result(%{response_cache: %ResponseCache{} = cache} = state, id, reply),
    do: %{state | response_cache: ResponseCache.store(cache, id, reply, now())}

  defp cache_result(state, _id, _reply), do: state

  defp now, do: System.monotonic_time(:millisecond)

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
  The error for a request ArborMCP did not send: `cause` is `:deadline_expired`
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

            {:error, reason, updated_state} ->
              error = if HTTPAuth.refused?(reason), do: {:stream_error, reason}, else: reason
              {:reply, {:error, error}, updated_state}
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
  defp retryable_subscription_stream_close?(reason), do: not HTTPAuth.refused?(reason)

  defp send_built_request(method, params, id, from, state, timeout_meta) do
    request_opts = [
      client_capabilities: Map.get(timeout_meta, :client_capabilities),
      modern_options: Map.get(timeout_meta, :modern_options, [])
    ]

    case build_request(method, params, id, state, request_opts) do
      {:ok, request} ->
        send_request(request, method, id, from, state, timeout_meta)

      # Decided here, against the era the connection settled on, so the check
      # and the request it guards see the same state.
      {:error, {:modern_only_option, option}} ->
        {:reply,
         {:error,
          Error.validation_error(
            option,
            nil,
            "requires MCP 2026-07-28, but the connection settled on " <>
              (state.protocol_version || "no protocol revision")
          )}, state}

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
    with {:ok, encoded} <- encode_for_transport(HTTP, request) do
      HTTP.open_stream(encoded, transport_state, self(), stream_kind: :subscription)
      |> transport_result(state)
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
    if progress_token_in_use?(request, state),
      do: {:reply, {:error, not_sent_error(:duplicate_progress_token, state)}, state},
      else: send_unique_request(request, method, id, from, state, meta)
  end

  # Progress names its request only by token, so a token that a pending
  # request already carries would route that request's progress here.
  defp progress_token_in_use?(request, state) do
    case get_in(request, ["params", "_meta", "progressToken"]) do
      nil ->
        false

      token ->
        case Map.get(Map.get(state, :progress_requests) || %{}, token) do
          nil -> false
          owner -> Map.has_key?(state.pending_requests, owner)
        end
    end
  end

  defp send_unique_request(request, method, id, from, state, meta) do
    state = mark_tool_listing(state, method, id, request)
    {deadline, meta} = request_send_context(from, state, meta)

    result =
      case state do
        %{transport_mod: LegacySSE, transport_state: %LegacySSE{}} ->
          send_legacy_request(request, from, state, deadline, request["id"])

        _other ->
          send_by_deadline(request, state, deadline)
      end

    case result do
      {:ok, updated_state, response_data} ->
        # Non-SSE HTTP returns response immediately
        updated_state = track_cacheable(updated_state, id, request, meta)
        inline_request_response(response_data, method, id, updated_state)

      {:ok, updated_state} ->
        # SSE and streaming transports - track pending request
        maybe_schedule_request_timeout(id, meta, updated_state)
        updated_state = track_cacheable(updated_state, id, request, meta)
        updated_state = start_progress_timeout(id, meta, updated_state)
        updated_state = remember_progress_target(updated_state, id, request, from, deadline, meta)
        pending_requests = Map.put(updated_state.pending_requests, id, {from, :single, method})
        new_state = %{updated_state | pending_requests: pending_requests}

        # Watched only now: an HTTP POST task registers itself with a message
        # this process sent itself during the send, so a :DOWN of the caller
        # always comes after it, and the task can be found to close.
        {:noreply,
         request
         |> remember_progress_token(id, new_state)
         |> watch_caller({:request, id}, from, Map.get(meta, :cancel_on_caller_exit))}

      {:error, :not_connected} ->
        {:reply, {:error, :not_connected}, state}

      {:error, :deadline_expired} ->
        # Refused before anything was sent (see BoundedClient).
        {:reply, {:error, not_sent_error(:deadline_expired, state)}, state}

      {:error, :caller_gone} ->
        {:reply, {:error, not_sent_error(:caller_gone, state)}, state}

      {:error, reason} ->
        request_send_error(reason, state, deadline)

      {:error, reason, updated_state} ->
        request_send_error(reason, updated_state, deadline)
    end
  end

  defp request_send_error(reason, state, deadline) do
    if Deadline.expired?(deadline),
      do: {:reply, {:error, :timeout}, state},
      else: {:reply, {:error, send_failure(reason, state)}, state}
  end

  # Every deadline the client compares is on its own monotonic clock (see
  # local_request_deadline/2), so the transport cap, the timeout timer and a
  # failed send's classification all use this node's time.
  defp request_send_context(from, state, meta) do
    deadline =
      case state do
        %{transport_mod: LegacySSE, transport_state: %LegacySSE{}} ->
          legacy_request_cutoff(meta, from, state)

        _other ->
          local_request_deadline(from, meta)
      end

    {deadline, Map.put(meta, :deadline, deadline)}
  end

  # A remote caller's monotonic clock is another node's, and comparing its
  # deadline here would end a fresh request at once, or never. Its relative
  # timeout counts from now instead, a budget captured on this node.
  defp local_request_deadline({caller, _tag}, meta)
       when is_pid(caller) and node(caller) != node(),
       do: remote_relative_deadline(meta)

  defp local_request_deadline(_from, meta), do: request_deadline(meta)

  defp inline_request_response(response_data, method, id, updated_state) do
    case Protocol.parse_message(response_data) do
      {:result, result, _id} ->
        :telemetry.execute(
          [:arbor_mcp, :client, :request, :completed],
          %{},
          %{method: method, request_id: id}
        )

        reply = validate_result(result, updated_state, method)

        updated_state =
          if match?({:ok, _result}, reply),
            do: remember_tool_schemas(updated_state, method, id, reply),
            else: updated_state

        updated_state = cache_result(updated_state, id, reply)

        {:reply, reply, updated_state}

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
  end

  defp legacy_request_cutoff(meta, from, state) do
    transport = state.transport_state

    # Remote monotonic clocks are not cutoff authority. Preserve the actual
    # relative option with a locally captured budget, capped by the transport.
    deadline = local_request_deadline(from, meta)

    deadline =
      if is_nil(deadline) and meta[:timeout] == nil,
        do: Deadline.after_ms(state.default_timeout || 5_000),
        else: deadline

    deadline = Deadline.earliest(deadline, transport.deadline)

    # A request that its progress keeps alive runs to its own deadline.
    if meta[:progress_timeout],
      do: deadline,
      else: Deadline.earliest(deadline, Deadline.after_ms(transport.timeouts.request))
  end

  defp remote_relative_deadline(%{timeout: ms}) when is_integer(ms) and ms >= 0,
    do: Deadline.after_ms(ms)

  defp remote_relative_deadline(_meta), do: nil

  # A retained legacy POST acknowledges only after its final durable SSE event.
  # Keep the native Client loop available to process the reverse GET request
  # needed to produce that final event. Direct transport calls and connection
  # establishment continue to use the synchronous transport API.
  defp send_legacy_request(request, {caller, _tag}, state, deadline, id) do
    transport = state.transport_state
    cutoff = deadline
    control = Deadline.earliest(cutoff, Deadline.after_ms(1_000))
    limit = Keyword.get(state.transport_opts, :max_client_workers, 256)

    with :ok <- legacy_post_admission(state, caller, cutoff, limit),
         {:ok, encoded} <- encode_for_transport(LegacySSE, request),
         :ok <- legacy_post_frame(encoded, transport.max_request_bytes) do
      parent = self()
      nonce = make_ref()
      body = :binary.copy(encoded)
      transport = %{transport | deadline: cutoff}
      generation = Lifetime.current()

      metadata = %{
        kind: :legacy_post,
        request_id: id,
        nonce: nonce,
        generation: generation,
        deadline: cutoff
      }

      {pid, monitor} =
        ConnectionScope.spawn_monitor(
          fn ->
            receive do
              {^nonce, :run} -> :ok
            after
              Deadline.remaining(control) -> exit(:client_generation_retired)
            end

            result =
              with :ok <- Lifetime.watch_caller(caller, cutoff) do
                cond do
                  Deadline.expired?(cutoff) -> {:error, :deadline_expired}
                  not legacy_caller_alive?(caller) -> {:error, :caller_gone}
                  true -> LegacySSE.send_message(body, transport)
                end
              end

            Lifetime.deliver(
              parent,
              {:async_post_result, result, Map.put(metadata, :task_pid, self())}
            )
          end,
          control
        )

      entry =
        metadata
        |> Map.put(:task_pid, pid)
        |> Map.put(:completed?, false)
        |> Map.put(:actual_down?, false)

      updated = %{state | async_post_tasks: Map.put(state.async_post_tasks, monitor, entry)}
      send(pid, {nonce, :run})
      {:ok, updated}
    else
      error -> error
    end
  end

  defp legacy_post_admission(state, caller, cutoff, limit) do
    cond do
      Process.get({Arbor.MCP.Client, :client}) != true ->
        {:error, :client_lifetime_unavailable}

      not is_pid(caller) or not legacy_caller_alive?(caller) ->
        {:error, :caller_gone}

      not is_integer(cutoff) or Deadline.remaining(cutoff) > 4_294_967_295 ->
        {:error, :invalid_request_timeout}

      Deadline.expired?(cutoff) ->
        {:error, :deadline_expired}

      map_size(state.async_post_tasks) >= limit ->
        {:error, :client_worker_limit}

      true ->
        :ok
    end
  end

  defp legacy_caller_alive?(caller) when node(caller) == node(), do: Process.alive?(caller)
  defp legacy_caller_alive?(_remote), do: true

  defp legacy_post_frame(encoded, limit) do
    if byte_size(encoded) <= limit, do: :ok, else: {:error, :request_too_large}
  end

  @doc false
  # The caller's error for a send that failed after it was handed to the
  # transport, including one made from an async HTTP task: the same shape
  # whether the send was synchronous or not.
  def send_error(:deadline_expired, state), do: not_sent_error(:deadline_expired, state)
  def send_error(:caller_gone, state), do: not_sent_error(:caller_gone, state)
  def send_error(reason, state), do: send_failure(reason, state)

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

      {:error, reason, updated_state} ->
        {:error, reason, put_transport_deadline(updated_state, previous)}

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
      send_http_request(request, state)
    end
  end

  defp send_request_message(request, %{transport_mod: HTTP, transport_state: %HTTP{}} = state),
    do: send_http_request(request, state)

  defp send_request_message(request, state), do: send_message(request, state)

  # Each request POSTs from its own task, so one slow request does not hold
  # the client: other requests and server messages proceed meanwhile.
  defp send_http_request(request, state) do
    with {:ok, encoded} <- encode_for_transport(HTTP, request) do
      HTTP.send_async(encoded, state.transport_state) |> transport_result(state)
    end
  end

  defp open_request_stream(request, state, transport_state) do
    with {:ok, encoded} <- encode_for_transport(HTTP, request) do
      HTTP.open_stream(encoded, transport_state, self(), stream_kind: :request)
      |> transport_result(state)
    end
  end

  # When the caller did not provide an explicit timeout, the client process
  # enforces its configured default (resolved from its own state — no extra
  # GenServer round-trips). Stale timers for completed requests are ignored
  # by the {:request_timeout, id} handler.
  defp maybe_schedule_request_timeout(id, %{deadline: deadline}, %{transport_mod: LegacySSE})
       when is_integer(deadline) do
    Process.send_after(self(), {:request_timeout, id}, Deadline.remaining(deadline))
    :ok
  end

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
    # A request without a total limit has the longest timer Erlang allows.
    after_ms = min(caller_timeout + @caller_timeout_grace, 4_294_967_295)
    Process.send_after(self(), {:request_timeout, id}, after_ms)
    :ok
  end

  defp maybe_schedule_request_timeout(_id, _meta, _state), do: :ok

  # With reset_timeout_on_progress, a request also times out once it has
  # gone :progress_timeout ms without progress (see Internal.Request); each
  # progress update starts that again. Its deadline still caps it. The tag
  # tells the current timer from one a reset replaced.
  defp start_progress_timeout(id, %{progress_timeout: ms}, state)
       when is_integer(ms) and ms >= 0 do
    tag = make_ref()
    timer = Process.send_after(self(), {:progress_timeout, id, tag}, ms)

    # Settled requests' timers are dropped here too, so the map never holds
    # more than the pending requests that asked for one.
    {timers, settled} =
      Map.split_with(progress_timeouts(state), fn {request_id, _timer} ->
        Map.has_key?(state.pending_requests, request_id)
      end)

    Enum.each(settled, fn {_request_id, {old_timer, _tag, _ms}} ->
      Process.cancel_timer(old_timer)
    end)

    Map.put(state, :progress_timeouts, Map.put(timers, id, {timer, tag, ms}))
  end

  defp start_progress_timeout(_id, _meta, state), do: state

  defp reset_progress_timeout(request_id, state) do
    with {timer, _tag, ms} <- Map.get(progress_timeouts(state), request_id),
         true <- Map.has_key?(state.pending_requests, request_id) do
      Process.cancel_timer(timer)
      start_progress_timeout(request_id, %{progress_timeout: ms}, state)
    else
      _no_timer_or_settled -> state
    end
  end

  @doc false
  # A settled request's timer is dropped when it runs out, so the map holds
  # only timers still due.
  @spec progress_timed_out(term(), reference(), map()) :: {:timed_out | :stale, map()}
  def progress_timed_out(request_id, tag, state) do
    timers = progress_timeouts(state)

    case Map.get(timers, request_id) do
      {_timer, ^tag, _ms} ->
        {:timed_out, Map.put(state, :progress_timeouts, Map.delete(timers, request_id))}

      _replaced_or_gone ->
        {:stale, state}
    end
  end

  defp progress_timeouts(state), do: Map.get(state, :progress_timeouts) || %{}

  defp cancel_progress_timeout(state, request_id) do
    case Map.pop(progress_timeouts(state), request_id) do
      {{timer, _tag, _ms}, timers} ->
        Process.cancel_timer(timer)
        Map.put(state, :progress_timeouts, timers)

      {nil, _timers} ->
        state
    end
  end

  @doc """
  Handles batch MCP requests.

  Processes multiple MCP requests in a single batch operation.
  """
  def handle_batch_request({requests, meta}, from, state)
      when is_list(requests) and is_map(meta) do
    handle_batch_with_deadline(requests, from, state, meta)
  end

  def handle_batch_request(requests, from, state),
    do: handle_batch_with_deadline(requests, from, state, %{timeout: :caller_enforced})

  defp handle_batch_with_deadline(requests, from, state, meta) do
    if VersionRegistry.modern?(state.protocol_version) do
      {:reply,
       {:error,
        %{
          type: :unsupported_operation,
          message: "Batch requests are not available in MCP #{state.protocol_version}"
        }}, state}
    else
      do_handle_batch_request(requests, from, state, meta)
    end
  end

  defp do_handle_batch_request(requests, from, state, meta) do
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

    batch_id = Protocol.generate_id()
    {result, cutoff} = send_batch(protocol_requests, batch_id, from, state, meta)

    case result do
      {:ok, updated_state} ->
        if is_integer(cutoff),
          do: maybe_schedule_request_timeout(batch_id, %{deadline: cutoff}, updated_state)

        batch_info = {from, :batch, ordered_ids, %{}}

        new_pending_requests =
          Enum.reduce(ordered_ids, updated_state.pending_requests, fn req_id, acc ->
            Map.put(acc, req_id, batch_id)
          end)
          |> Map.put(batch_id, batch_info)

        new_state = %{updated_state | pending_requests: new_pending_requests}
        {:noreply, new_state}

      {:error, reason} ->
        batch_send_error(reason, state)

      {:error, reason, updated_state} ->
        batch_send_error(reason, updated_state)
    end
  end

  defp batch_send_error(reason, state) do
    {:reply,
     {:error,
      %{type: :transport_error, message: "Failed to send batch request: #{inspect(reason)}"}},
     state}
  end

  defp send_batch(requests, batch_id, from, %{transport_mod: LegacySSE} = state, meta) do
    cutoff = legacy_request_cutoff(meta, from, state)
    {send_legacy_request(requests, from, state, cutoff, batch_id), cutoff}
  end

  defp send_batch(requests, _batch_id, _from, state, _meta),
    do: {send_message(requests, state), nil}

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
  @spec send_ping(map()) :: {:ok, term() | nil, map()} | {:error, any()} | {:error, any(), map()}
  def send_ping(state) do
    id = Protocol.generate_id()

    method =
      if VersionRegistry.modern?(state.protocol_version), do: "server/discover", else: "ping"

    with {:ok, request} <- build_request(method, %{}, id, state) do
      case send_health_request(request, state) do
        {:ok, updated_state, _response_data} -> {:ok, nil, updated_state}
        {:ok, updated_state} -> {:ok, id, updated_state}
        {:error, reason} -> {:error, reason}
        {:error, reason, updated_state} -> {:error, reason, updated_state}
      end
    end
  end

  defp send_health_request(request, %{transport_mod: HTTP, transport_state: %HTTP{}} = state),
    do: send_http_request(request, state)

  defp send_health_request(request, state), do: send_message(request, state)

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

      {:notification, method, params} ->
        route_notification(method, params, state)

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
    state = reset_progress_timeout(request_id, state)
    deliver_progress(:stream, request_id, params, state)
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
            {:noreply, drop_pending(state, request_id)}

          {from, :single} ->
            error = request_stream_error(reason)

            GenServer.reply(from, {:error, error})
            {:noreply, drop_pending(state, request_id)}

          _not_pending ->
            {:noreply, state}
        end
    end
  end

  @doc false
  # Settles the circuit-breaker admissions of the POST tasks serving
  # `request_id` (see HTTP.attach_reliability/2) without stopping them, in any
  # era: the outcome the client decided (:failure at its timeout, :release at
  # a cancellation or its caller's exit) wins over whatever a task would
  # settle later, a late response or an auth wait the client woke included.
  @spec settle_posts(map(), term(), :failure | :release) :: map()
  def settle_posts(
        %{transport_mod: HTTP, transport_state: %HTTP{} = transport} = state,
        request_id,
        outcome
      ) do
    for {_monitor, {pid, ^request_id}} <- state.async_post_tasks || %{},
        do: HTTP.settle_post(transport, pid, outcome)

    state
  end

  def settle_posts(state, _request_id, _outcome), do: state

  @doc false
  # `outcome` settles a stopped POST task's circuit-breaker admission (see
  # HTTP.attach_reliability/2): `:failure` when the caller timed out,
  # `:release` when it cancelled.
  def close_request_stream(request_id, state, outcome \\ :release)

  def close_request_stream(
        request_id,
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{protocol_era: :modern} = transport_state
        } = state,
        outcome
      ) do
    # Closing the connection is how modern HTTP cancels a request, whether
    # its response is a stream or a pending POST. The POST task is forgotten
    # first, so neither its exit nor a late result reaches the client.
    {posts, tasks} =
      Map.split_with(state.async_post_tasks || %{}, fn {_monitor, entry} ->
        match?({_pid, ^request_id}, entry)
      end)

    for {monitor, {pid, _id}} <- posts do
      Process.demonitor(monitor, [:flush])
      HTTP.settle_post(transport_state, pid, outcome)
      Process.exit(pid, :kill)
    end

    %{
      state
      | async_post_tasks: tasks,
        transport_state: HTTP.close_stream(transport_state, request_id)
    }
  end

  def close_request_stream(request_id, %{transport_mod: LegacySSE} = state, _outcome) do
    Enum.each(state.async_post_tasks, fn
      {_monitor, %{kind: :legacy_post, task_pid: pid, request_id: ^request_id} = entry} ->
        if entry.generation == Lifetime.current() do
          Lifetime.stop_owned(pid, Deadline.earliest(entry.deadline, Deadline.after_ms(1_000)))
        end

      _other ->
        :ok
    end)

    # Keep the actual worker's monitor/credit until native DOWN.
    state
  end

  def close_request_stream(_request_id, state, _outcome), do: state

  defp request_stream_error({:auth_refused, _reason} = refusal),
    do: send_error(refusal, %{transport_mod: HTTP})

  defp request_stream_error({:oauth_failed, _reason} = reason),
    do: send_error(reason, %{transport_mod: HTTP})

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

  defp ambiguous_stream_break?(reason), do: not HTTPAuth.refused?(reason)

  @doc """
  Handles a batch of responses from the transport.
  """
  def handle_batch_response(responses, state) do
    Enum.reduce(responses, {:noreply, state}, fn response, {:noreply, current_state} ->
      handle_single_response(response, current_state)
    end)
  end

  @doc false
  # An HTTP POST's response answers the request that POST carried, whatever
  # id its body echoes (a server may answer an invalid request with a null
  # id), as when the POST was synchronous, and is dropped once that request
  # has settled (timed out or cancelled), never routed to another one.
  # Anything else, such as a batch, a notification or a server request, or
  # the response to a POST that carried no request, is routed as usual.
  def handle_post_response(response_data, nil, state),
    do: parse_transport_message(response_data, state)

  def handle_post_response(response_data, request_id, state) do
    case Protocol.parse_message(response_data) do
      {kind, payload, _echoed_id} when kind in [:result, :error] ->
        if pending_single?(state.pending_requests, request_id) or
             Map.get(state, :health_check_id) == request_id,
           do: handle_single_response({kind, payload, request_id}, state),
           else: {:noreply, state}

      _other ->
        parse_transport_message(response_data, state)
    end
  end

  defp pending_single?(pending, request_id) do
    match?({_from, :single, _method}, Map.get(pending, request_id)) or
      match?({_from, :single}, Map.get(pending, request_id))
  end

  @doc """
  Handles a single response from the transport.
  """
  def handle_single_response(response, state) do
    {:noreply, updated} = do_handle_single_response(response, state)
    {:noreply, prune_legacy_posts(updated)}
  end

  defp do_handle_single_response({:result, result, response_id}, state) do
    method = pending_request_method(state.pending_requests, response_id)
    handle_response_by_id(response_id, validate_result(result, state, method), state)
  end

  defp do_handle_single_response({:error, error, response_id}, state) do
    # Keep raw error data - let format handling in make_request decide how to format it
    handle_response_by_id(response_id, {:error, error}, state)
  end

  defp do_handle_single_response(other, state) do
    Logger.warning("Received unexpected response format: #{LogSummary.describe(other)}")

    {:noreply, state}
  end

  defp legacy_response_cutoff({_kind, _data, response_id}, %{transport_mod: LegacySSE} = state) do
    request_id = legacy_pending_identity(state.pending_requests, response_id)

    case Enum.find(state.async_post_tasks, fn
           {_ref, %{kind: :legacy_post, request_id: id}} -> id == request_id
           _other -> false
         end) do
      {_ref, entry} ->
        if entry.generation == Lifetime.current() and not Deadline.expired?(entry.deadline),
          do: :current,
          else: {:expired, request_id}

      nil ->
        :current
    end
  end

  defp legacy_response_cutoff(_response, _state), do: :current

  defp legacy_pending_identity(pending_requests, response_id) do
    case Map.get(pending_requests, response_id) do
      {_from, :single, _method} ->
        response_id

      {_from, :single} ->
        response_id

      batch_id when is_integer(batch_id) or is_binary(batch_id) ->
        batch_id

      _other when is_nil(response_id) ->
        case find_pending_batch_request(pending_requests) do
          {batch_id, _batch} -> batch_id
          nil -> nil
        end

      _other ->
        nil
    end
  end

  defp prune_legacy_posts(state) do
    tasks =
      Map.reject(state.async_post_tasks, fn
        {_ref, %{kind: :legacy_post, actual_down?: true, request_id: id}} ->
          not Map.has_key?(state.pending_requests, id)

        _other ->
          false
      end)

    %{state | async_post_tasks: tasks}
  end

  # Reply to the client's own health-check ping. Any answer — result or
  # error — proves the connection is alive, so the outstanding ping is simply
  # cleared. These ids are never in pending_requests.
  defp handle_response_by_id(response_id, _response_data, %{health_check_id: ping_id} = state)
       when not is_nil(ping_id) and response_id == ping_id do
    {:noreply, %{state | health_check_id: nil, last_activity: System.system_time(:second)}}
  end

  defp handle_response_by_id(response_id, response_data, state) do
    case legacy_response_cutoff({:settlement, response_data, response_id}, state) do
      {:expired, request_id} ->
        # Check after result validation, immediately before pending mutation.
        # A queued SSE final cannot renew its admitted POST cutoff.
        Arbor.MCP.Client.handle_info({:request_timeout, request_id}, state)

      :current ->
        do_handle_response_by_id(response_id, response_data, state)
    end
  end

  defp do_handle_response_by_id(response_id, response_data, state) do
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
          |> remember_tool_schemas(method, response_id, response_data)
          |> cache_result(response_id, response_data)
          |> cancel_progress_timeout(response_id)
          |> forget_caller({:request, response_id})
          |> settle_progress(response_id, response_data)

        {:ok, {from, :single}} ->
          :telemetry.execute(
            [:arbor_mcp, :client, :request, :completed],
            %{},
            %{method: nil, request_id: response_id}
          )

          GenServer.reply(from, response_data)
          new_pending_requests = Map.delete(pending_requests, response_id)

          %{state | pending_requests: new_pending_requests}
          |> forget_caller({:request, response_id})
          |> settle_progress(response_id, response_data)

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

  defp route_notification("notifications/subscriptions/acknowledged", params, state),
    do: route_subscription_acknowledgment(params, state)

  defp route_notification(method, params, state)
       when method in [
              "notifications/tools/list_changed",
              "notifications/prompts/list_changed",
              "notifications/resources/list_changed",
              "notifications/resources/updated"
            ],
       do: route_change_notification(method, params, forget_changed(state, method, params))

  defp route_notification("notifications/tasks" = method, params, state),
    do: route_task_subscription_event(method, params, state)

  defp route_notification("notifications/cancelled", params, state) do
    Logger.info("Received notification: notifications/cancelled")
    handle_cancellation_notification(params, state)
  end

  defp route_notification("notifications/progress", params, state) when is_map(params),
    do: route_progress(params, state)

  # A connection-level log message belongs to no request.
  defp route_notification("notifications/message", params, state) when is_map(params),
    do: dispatch_request_notification(:handle_log_message, nil, params, state)

  defp route_notification(method, _params, state) do
    Logger.info("Received unsupported notification",
      method_hash: LogSummary.fingerprint(method)
    )

    {:noreply, state}
  end

  # Over every transport but a modern request stream, progress arrives on the
  # connection and names its request only by the token that request carried.
  defp route_progress(params, state) do
    progress_requests = Map.get(state, :progress_requests) || %{}

    case Map.get(progress_requests, params["progressToken"]) do
      nil ->
        Logger.debug("Progress for an unknown token")
        {:noreply, state}

      request_id ->
        if Map.has_key?(state.pending_requests, request_id) do
          state = reset_progress_timeout(request_id, state)
          deliver_progress(:connection, request_id, params, state)
          dispatch_request_notification(:handle_progress, request_id, params, state)
        else
          {:noreply, forget_progress_token(state, params["progressToken"])}
        end
    end
  end

  defp remember_progress_token(request, id, state) do
    case get_in(request, ["params", "_meta", "progressToken"]) do
      token when is_binary(token) or is_integer(token) ->
        # Settled requests' tokens are dropped here, so the map never holds
        # more than the pending requests that asked for progress.
        live =
          (Map.get(state, :progress_requests) || %{})
          |> Map.filter(fn {_token, id} -> Map.has_key?(state.pending_requests, id) end)

        Map.put(state, :progress_requests, Map.put(live, token, id))

      _none ->
        state
    end
  end

  # Each tools/list page records its tools' output schemas; a tool listed
  # without one has none to check.
  # A first-page listing (no cursor) replaces what earlier listings recorded,
  # so a removed or changed tool isn't checked against an old schema; later
  # pages add to it.
  defp mark_tool_listing(state, "tools/list", id, request) do
    if get_in(request, ["params", "cursor"]),
      do: state,
      else: Map.update(state, :tool_listings, MapSet.new([id]), &MapSet.put(&1, id))
  end

  defp mark_tool_listing(state, _method, _id, _request), do: state

  defp remember_tool_schemas(state, "tools/list", id, response_data) do
    {fresh?, listings} =
      state
      |> Map.get(:tool_listings, MapSet.new())
      |> then(&{MapSet.member?(&1, id), MapSet.delete(&1, id)})

    state = Map.put(state, :tool_listings, listings)
    known = if fresh?, do: %{}, else: Map.get(state, :tool_output_schemas) || %{}

    with %{} = result <- list_result(response_data),
         tools when is_list(tools) <- field(result, "tools", :tools) do
      schemas =
        Enum.reduce(tools, known, fn tool, acc ->
          case {field(tool, "name", :name), field(tool, "outputSchema", :outputSchema)} do
            {name, schema} when is_binary(name) and is_map(schema) -> Map.put(acc, name, schema)
            {name, _none} when is_binary(name) -> Map.delete(acc, name)
            _other -> acc
          end
        end)

      Map.put(state, :tool_output_schemas, schemas)
    else
      _other -> state
    end
  end

  defp remember_tool_schemas(state, _method, _id, _response_data), do: state

  # Both paths hand over the response already parsed and validated.
  defp list_result({:ok, %{} = result}), do: result
  defp list_result(_rejected), do: nil

  # In-process transports deliver maps that may still have atom keys.
  defp field(%{} = map, key, atom), do: Map.get(map, key) || Map.get(map, atom)
  defp field(_other, _key, _atom), do: nil

  defp forget_changed(state, method, params) do
    state = forget_tool_schemas(state, method)

    case Map.get(state, :response_cache) do
      %ResponseCache{} = cache ->
        %{state | response_cache: ResponseCache.invalidate(cache, method, params)}

      nil ->
        state
    end
  end

  # A changed tool list may change a schema; validate again once relisted.
  defp forget_tool_schemas(state, "notifications/tools/list_changed"),
    do: Map.put(state, :tool_output_schemas, %{})

  defp forget_tool_schemas(state, _method), do: state

  defp forget_progress_token(state, token),
    do: Map.update(state, :progress_requests, %{}, &Map.delete(&1, token))

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

  # progress_to: a request's progress also goes to a process the caller
  # chose, alongside the client handler, but only while that request is
  # pending for its caller, and never to another request's target.
  #
  # - `progress_targets` maps each pending request that carries a progress
  #   token to its token, its target (nil when it has none), its caller and
  #   the caller's deadline (on this node's clock, see request_send_context/3),
  #   the monitor on its caller, and its round, {method, name}. The entry is
  #   made once the request is pending, and dropped by settle_progress/3,
  #   through drop_pending/2 or handle_pending_response, when the caller has
  #   its answer (a result, an error, a timeout, a cancellation). A caller
  #   that goes down, on this node or another (a lost node connection is
  #   :noconnection), loses its target at once (progress_caller_down/2).
  # - `progress_tombstones` maps the token of a settled request to when it
  #   stops being held back, the cleanup grace from its settling. Connection-
  #   level progress names its request only by token, and a settled request's
  #   late notification (legacy HTTP can send one on the GET stream after the
  #   POST's response) would otherwise reach a newer request that reuses it.
  # - `progress_reservations` maps the token of an input_required round to
  #   the round's identity (method, name and the requestState it returned,
  #   or its input request ids), its target and its deadline. The round
  #   doesn't settle its call: the continuation carries the same token, and a
  #   continuation that presents that identity, automatic or manual, claims
  #   the reservation and gets the target back unless it names its own. Any
  #   other request with the token is held back like a reuse.
  # - A token is held back while it is tombstoned or reserved, a reservation
  #   until the grace after its deadline. Then connection-level progress
  #   naming it reaches no target. A claim takes only the reservation, never
  #   a tombstone, and a reservation never replaces one. Client-generated
  #   tokens are unique and never meet either.
  defp remember_progress_target(state, id, request, {caller, _tag}, deadline, meta)
       when is_pid(caller) do
    case get_in(request, ["params", "_meta", "progressToken"]) do
      nil ->
        state

      token ->
        state = prune_settled_targets(state)
        limits = Map.take(meta, [:max_mrtr_bytes, :max_input_requests])
        {reserved, state} = claim_reservation(state, token, request, limits)
        pid = Map.get(meta, :progress_to) || reserved
        monitor = if is_pid(pid), do: Process.monitor(caller)

        target = %{
          pid: pid,
          token: token,
          caller: caller,
          deadline: deadline,
          monitor: monitor,
          round: mrtr_round(request),
          limits: limits
        }

        state
        |> Map.put(:progress_targets, Map.put(progress_targets(state), id, target))
        |> put_progress_monitor(monitor, id)
    end
  end

  defp remember_progress_target(state, _id, _request, _from, _deadline, _meta), do: state

  # Settling drops each entry; a request settled on a path that doesn't is
  # dropped here, so the map never outgrows the pending requests.
  defp prune_settled_targets(state) do
    {settled, live} =
      Map.split_with(progress_targets(state), fn {request_id, _target} ->
        not Map.has_key?(state.pending_requests, request_id)
      end)

    Enum.reduce(settled, Map.put(state, :progress_targets, live), fn {_id, target}, acc ->
      forget_progress_monitor(acc, target.monitor)
    end)
  end

  defp mrtr_round(%{"method" => method, "params" => params}) when is_map(params),
    do: {method, params["name"] || params["uri"]}

  defp mrtr_round(%{"method" => method}), do: {method, nil}

  # What a continuation must present: the requestState the round returned,
  # or, when it returned none, the ids of the input requests it answers. Both
  # sides come from outside the client process (the server's round, the
  # caller's continuation), so every shape is handled, nothing larger than
  # the request's own MRTR limits is hashed or listed, and anything else
  # identifies no round.
  defp continuation(%{"requestState" => request_state}, limits),
    do: state_identity(request_state, limits)

  defp continuation(%{"inputResponses" => responses}, limits),
    do: inputs_identity(responses, limits)

  defp continuation(_params, _limits), do: nil

  defp round_continuation(%{"requestState" => request_state}, limits),
    do: state_identity(request_state, limits)

  defp round_continuation(%{"inputRequests" => requests}, limits),
    do: inputs_identity(requests, limits)

  defp round_continuation(_result, _limits), do: nil

  defp state_identity(request_state, limits) when is_binary(request_state) do
    if byte_size(request_state) <= limit(limits, :max_mrtr_bytes, MRTR.max_bytes([])),
      do: {:state, :crypto.hash(:sha256, request_state)}
  end

  defp state_identity(_request_state, _limits), do: nil

  # The ids count only within the request's limits, by number and by total
  # size, and only their digest is kept, as for a requestState.
  defp inputs_identity(ids, limits) when is_map(ids) and not is_struct(ids) do
    count = map_size(ids)
    max_count = limit(limits, :max_input_requests, MRTR.max_input_requests([]))
    max_bytes = limit(limits, :max_mrtr_bytes, MRTR.max_bytes([]))

    with true <- count > 0 and count <= max_count,
         keys = Map.keys(ids),
         true <- Enum.all?(keys, &is_binary/1),
         true <- Enum.reduce(keys, 0, &(byte_size(&1) + &2)) <= max_bytes do
      digest = :crypto.hash(:sha256, Enum.map(Enum.sort(keys), &[<<byte_size(&1)::32>>, &1]))
      {:inputs, digest}
    else
      _unusable -> nil
    end
  end

  defp inputs_identity(_ids, _limits), do: nil

  # The request's own limit, or MRTR's default when it set none or set
  # something this process can't use.
  defp limit(limits, key, default) do
    case Map.get(limits, key) do
      value when is_integer(value) and value >= 0 -> value
      _unset -> default
    end
  end

  defp claim_reservation(state, token, request, limits) do
    reservations = progress_reservations(state)
    identity = {mrtr_round(request), continuation(Map.get(request, "params") || %{}, limits)}

    case Map.get(reservations, token) do
      %{identity: ^identity, pid: pid} = reservation
      when not is_map_key(reservation, :contested) ->
        if elem(identity, 1) != nil and now() < reservation.until,
          do: {pid, Map.put(state, :progress_reservations, Map.delete(reservations, token))},
          else: {nil, state}

      _none_or_another ->
        {nil, state}
    end
  end

  @doc false
  # The caller of request `id` has its answer, `response` if the server sent
  # one: its progress reaches no target from now on. Its token is held back
  # for the grace, or reserved for the continuation if the answer is an
  # input_required round.
  @spec settle_progress(map(), term(), term()) :: map()
  def settle_progress(state, id, response \\ nil) do
    {target, targets} = Map.pop(progress_targets(state), id)

    state =
      state
      |> Map.put(:progress_targets, targets)
      |> forget_progress_monitor(target && target.monitor)

    case {target, (target && target.token) || request_token(state, id)} do
      {_target, nil} -> state
      {%{} = target, token} -> settle_token(state, token, id, target, response)
      {nil, token} -> tombstone_token(state, token, id)
    end
  end

  # Only a round whose continuation can be told apart is reserved; any other
  # input_required answer, malformed or over the request's limits, is held
  # back like a settled request.
  defp settle_token(state, token, id, target, {:ok, result}) do
    with true <- MRTR.input_required?(result),
         continuation when not is_nil(continuation) <-
           round_continuation(result, Map.get(target, :limits, %{})) do
      reserve_token(state, token, id, target, continuation)
    else
      _complete_or_unusable -> tombstone_token(state, token, id)
    end
  end

  defp settle_token(state, token, id, _target, _response), do: tombstone_token(state, token, id)

  # Two rounds that reserve one token at once can't tell their continuations
  # apart: neither may claim it, and both stay held back.
  defp reserve_token(state, token, id, target, continuation) do
    now = now()
    until = target.deadline || now + (state.default_timeout || 5_000)

    reservation = %{
      identity: {target.round, continuation},
      pid: target.pid,
      until: until
    }

    reservations =
      progress_reservations(state)
      |> Map.filter(fn {_token, held} -> held.until + @caller_timeout_grace > now end)

    reservations =
      case Map.get(reservations, token) do
        nil ->
          Map.put(reservations, token, reservation)

        held ->
          contested = %{reservation | until: max(held.until, until)}
          Map.put(reservations, token, Map.put(contested, :contested, true))
      end

    state
    |> Map.put(:progress_reservations, reservations)
    |> forget_progress_request(token, id)
    |> arm_progress_sweep(until + @caller_timeout_grace)
  end

  defp tombstone_token(state, token, id) do
    now = now()

    tombstones =
      (Map.get(state, :progress_tombstones) || %{})
      |> Map.filter(fn {_token, until} -> until > now end)
      |> Map.update(token, now + @caller_timeout_grace, &max(&1, now + @caller_timeout_grace))

    state
    |> Map.put(:progress_tombstones, tombstones)
    |> forget_progress_request(token, id)
    |> arm_progress_sweep(now + @caller_timeout_grace)
  end

  # One timer sweeps expired tombstones and reservations, so a burst that
  # no request follows still leaves nothing behind. It is armed for the
  # earliest expiry, and moved earlier when a new entry expires sooner.
  #
  # Each arming tags its message with a fresh ref, and only the message with
  # the current ref sweeps. A timer whose message was already queued when it
  # was cancelled, or one left from before a reconnect (reset_progress/1
  # clears the ref), can't sweep again or arm a second timer.
  defp arm_progress_sweep(state, at) do
    case Map.get(state, :progress_sweep) do
      {_timer, armed_at, _ref} when armed_at <= at ->
        state

      armed ->
        if armed, do: Process.cancel_timer(elem(armed, 0))
        ref = make_ref()
        timer = Process.send_after(self(), {:progress_sweep, ref}, max(at - now(), 0) + 1)
        Map.put(state, :progress_sweep, {timer, at, ref})
    end
  end

  @doc false
  # A sweep timer fired. Only the current one drops what has expired and
  # arms again for the earliest of what remains; any other is stale.
  @spec sweep_progress(map(), reference()) :: map()
  def sweep_progress(%{progress_sweep: {_timer, _at, ref}} = state, ref),
    do: sweep_progress(state)

  def sweep_progress(state, _stale_ref), do: state

  defp sweep_progress(state) do
    now = now()

    tombstones =
      (Map.get(state, :progress_tombstones) || %{})
      |> Map.filter(fn {_token, until} -> until > now end)

    reservations =
      progress_reservations(state)
      |> Map.filter(fn {_token, held} -> held.until + @caller_timeout_grace > now end)

    next =
      Enum.min(
        Map.values(tombstones) ++
          Enum.map(reservations, fn {_token, held} -> held.until + @caller_timeout_grace end),
        fn -> nil end
      )

    state =
      state
      |> Map.put(:progress_tombstones, tombstones)
      |> Map.put(:progress_reservations, reservations)
      |> Map.put(:progress_sweep, nil)

    if next, do: arm_progress_sweep(state, next), else: state
  end

  defp forget_progress_request(state, token, id) do
    requests =
      case Map.get(state, :progress_requests) || %{} do
        %{^token => ^id} = requests -> Map.delete(requests, token)
        requests -> requests
      end

    Map.put(state, :progress_requests, requests)
  end

  defp request_token(state, id) do
    Enum.find_value(Map.get(state, :progress_requests) || %{}, fn
      {token, ^id} -> token
      _other -> nil
    end)
  end

  # Tombstones first: a claimed reservation doesn't end a tombstone.
  defp held_back?(state, token) do
    now = now()

    case Map.get(Map.get(state, :progress_tombstones) || %{}, token) do
      until when is_integer(until) and until > now ->
        true

      _none ->
        case Map.get(progress_reservations(state), token) do
          %{until: until} -> now < until + @caller_timeout_grace
          nil -> false
        end
    end
  end

  @doc false
  # The caller of a request with a target went down, or its node's
  # connection was lost (:noconnection): the target gets nothing more, while
  # the request itself settles as it would.
  @spec progress_caller_down(reference(), map()) :: map()
  def progress_caller_down(monitor, state) do
    {id, monitors} = Map.pop(progress_monitors(state), monitor)
    state = Map.put(state, :progress_monitors, monitors)

    case Map.get(progress_targets(state), id) do
      %{} = target ->
        targets = Map.put(progress_targets(state), id, %{target | pid: nil, monitor: nil})
        Map.put(state, :progress_targets, targets)

      nil ->
        state
    end
  end

  @doc false
  # The connection went with its requests: no target, reservation or
  # tombstone outlives it.
  @spec reset_progress(map()) :: map()
  def reset_progress(state) do
    state |> progress_monitors() |> Map.keys() |> Enum.each(&Process.demonitor(&1, [:flush]))

    case Map.get(state, :progress_sweep) do
      {timer, _at, _ref} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    state
    |> Map.put(:progress_targets, %{})
    |> Map.put(:progress_tombstones, %{})
    |> Map.put(:progress_reservations, %{})
    |> Map.put(:progress_monitors, %{})
    |> Map.put(:progress_sweep, nil)
  end

  defp put_progress_monitor(state, nil, _id), do: state

  defp put_progress_monitor(state, monitor, id),
    do: Map.put(state, :progress_monitors, Map.put(progress_monitors(state), monitor, id))

  defp forget_progress_monitor(state, nil), do: state

  defp forget_progress_monitor(state, monitor) do
    Process.demonitor(monitor, [:flush])
    Map.put(state, :progress_monitors, Map.delete(progress_monitors(state), monitor))
  end

  # `route` is :stream for a modern request stream, which carries only its
  # own request's messages, or :connection for progress routed by token.
  defp deliver_progress(route, request_id, params, state) do
    token = Map.get(params, "progressToken")

    case Map.get(progress_targets(state), request_id) do
      %{token: ^token, pid: pid} = target when is_pid(pid) ->
        if deliverable?(route, target, request_id, state),
          do: send(pid, {:arbor_mcp_progress, self(), token, params})

      %{token: ^token} ->
        :ok

      %{} ->
        Logger.debug("Request stream progress named another request's token")

      nil ->
        :ok
    end

    :ok
  end

  defp deliverable?(route, target, request_id, state) do
    Map.has_key?(state.pending_requests, request_id) and
      not Deadline.expired?(target.deadline) and
      caller_alive?(target.caller) and
      not (route == :connection and held_back?(state, target.token))
  end

  # A local caller's death is seen at once; a remote one's through the
  # monitor on it (progress_caller_down/2).
  defp caller_alive?(caller) when node(caller) == node(), do: Process.alive?(caller)
  defp caller_alive?(_remote), do: true

  defp progress_reservations(state), do: Map.get(state, :progress_reservations) || %{}
  defp progress_monitors(state), do: Map.get(state, :progress_monitors) || %{}

  defp progress_targets(state), do: Map.get(state, :progress_targets) || %{}

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

  @doc false
  # Sends a notification over HTTP from its own POST task, so a slow server
  # cannot hold the client; other transports send it as usual.
  def send_notification_async(method, params, %{transport_mod: HTTP} = state) do
    with %HTTP{} <- state.transport_state,
         {:ok, notification} <- build_request(method, params, nil, state),
         {:ok, state} <- send_http_request(notification, state) do
      state
    else
      {:error, _reason, updated_state} -> updated_state
      _not_sent -> state
    end
  end

  def send_notification_async(method, params, state) do
    {:noreply, state} = handle_cast_notification(method, params, state)
    state
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
        notification_send_error(reason, state)

      {:error, reason, updated_state} ->
        notification_send_error(reason, updated_state)
    end
  end

  defp notification_send_error(reason, state) do
    Logger.error("Failed to send notification", reason_shape: LogSummary.describe(reason))
    {:noreply, state}
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
        Arbor.MCP.Transport.send_message_with_state(
          transport_mod,
          outbound_message,
          transport_state
        )
        |> transport_result(state)
      end
    end
  end

  defp transport_result({:ok, transport, response}, state),
    do: {:ok, %{state | transport_state: transport}, response}

  defp transport_result({:ok, transport}, state),
    do: {:ok, %{state | transport_state: transport}}

  defp transport_result({:error, reason, transport}, state),
    do: {:error, reason, %{state | transport_state: transport}}

  defp transport_result(result, _state), do: result

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

  defp build_request(method, params, id, state, opts \\ []) do
    with {:ok, params} <- RequestParams.for_request(params || %{}, state, opts) do
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
          {:noreply, drop_pending(updated_state, request_id)}

        {from, :single} ->
          # Reply with cancelled error and remove from pending
          GenServer.reply(from, {:error, :cancelled})
          {:noreply, drop_pending(updated_state, request_id)}

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
      state = %{state | mrtr_tasks: tasks}

      {:noreply,
       watch_caller(state, {:mrtr, pid}, from, Keyword.get(opts, :cancel_on_caller_exit))}
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
        state = forget_caller(%{state | mrtr_tasks: tasks}, {:mrtr, task_pid})

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
        state = forget_caller(state, {:mrtr, task_pid})

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

    state =
      Enum.reduce(cancelled, %{state | mrtr_tasks: Map.new(remaining)}, fn {pid, _task}, acc ->
        forget_caller(acc, {:mrtr, pid})
      end)

    {:noreply, state}
  end

  @doc false
  # The caller of an MRTR round exited while the client handler was still
  # answering its input requests: nobody will send the answers, so the
  # handler is stopped, as at the caller's timeout.
  @spec stop_mrtr_fulfillment(pid(), map()) :: map()
  def stop_mrtr_fulfillment(task_pid, state) do
    case Map.pop(state.mrtr_tasks || %{}, task_pid) do
      {{ref, _from, _scope_ref}, tasks} ->
        Process.exit(task_pid, :kill)
        Process.demonitor(ref, [:flush])
        %{state | mrtr_tasks: tasks}

      {nil, _tasks} ->
        state
    end
  end

  # Cancel on caller exit.
  #
  # A request whose caller exits while it is in flight is cancelled upstream
  # (see Arbor.MCP.Client's :DOWN handling), and so is an MRTR round whose
  # input the client handler is still answering. Each such request or
  # fulfilment holds one monitor on its caller: `caller_watches` maps
  # {:request, id} or {:mrtr, task_pid} to it, and `caller_monitors` maps it
  # back. A watch is dropped, and its monitor with it, as soon as what it
  # watched settles: every path that removes a pending request goes through
  # drop_pending/2, and every end of an MRTR fulfilment calls
  # forget_caller/2. Adding a watch also prunes any left behind, as a
  # backstop only.

  @doc false
  # On for every modern request unless the caller turned it off; on a legacy
  # connection only when the caller asked for it, since there it sends
  # `notifications/cancelled`, which a legacy peer did not get before.
  @spec cancel_on_caller_exit?(boolean() | nil, map()) :: boolean()
  def cancel_on_caller_exit?(nil, state),
    do: VersionRegistry.modern?(Map.get(state, :protocol_version))

  def cancel_on_caller_exit?(option, _state), do: option == true

  defp watch_caller(state, key, {caller, _tag}, option) when is_pid(caller) do
    if cancel_on_caller_exit?(option, state) do
      state = prune_caller_watches(state)
      monitor = Process.monitor(caller)

      state
      |> Map.put(:caller_watches, Map.put(caller_watches(state), key, monitor))
      |> Map.put(:caller_monitors, Map.put(caller_monitors(state), monitor, key))
    else
      state
    end
  end

  defp watch_caller(state, _key, _from, _option), do: state

  @doc false
  # What a caller's monitor watched, {:request, id} or {:mrtr, task_pid}, now
  # that the caller is down, or nil for a monitor that is no longer a watch.
  @spec caller_exited(reference(), map()) :: {term(), map()}
  def caller_exited(monitor, state) do
    case Map.pop(caller_monitors(state), monitor) do
      {nil, _monitors} ->
        {nil, state}

      {key, monitors} ->
        state =
          state
          |> Map.put(:caller_monitors, monitors)
          |> Map.put(:caller_watches, Map.delete(caller_watches(state), key))

        {key, state}
    end
  end

  @doc false
  # Drops a request that settled, whichever way (a response, an error, a
  # timeout, a cancellation, a failed send, its caller's exit), with the watch
  # on its caller, so no monitor outlives what it watched, and its progress
  # target (see settle_progress/2).
  @spec drop_pending(map(), term()) :: map()
  def drop_pending(state, request_id) do
    state = %{state | pending_requests: Map.delete(state.pending_requests, request_id)}

    state
    |> forget_caller({:request, request_id})
    |> settle_progress(request_id)
  end

  @doc false
  @spec forget_caller(map(), term()) :: map()
  def forget_caller(state, key) do
    case Map.pop(caller_watches(state), key) do
      {nil, _watches} ->
        state

      {monitor, watches} ->
        Process.demonitor(monitor, [:flush])

        state
        |> Map.put(:caller_watches, watches)
        |> Map.put(:caller_monitors, Map.delete(caller_monitors(state), monitor))
    end
  end

  @doc false
  # Drops every watch, for a connection that went away with its requests.
  @spec forget_callers(map()) :: map()
  def forget_callers(state) do
    state |> caller_monitors() |> Map.keys() |> Enum.each(&Process.demonitor(&1, [:flush]))
    state |> Map.put(:caller_watches, %{}) |> Map.put(:caller_monitors, %{})
  end

  defp prune_caller_watches(state) do
    Enum.reduce(caller_watches(state), state, fn {key, _monitor}, acc ->
      if still_in_flight?(acc, key), do: acc, else: forget_caller(acc, key)
    end)
  end

  defp still_in_flight?(state, {:request, id}), do: Map.has_key?(state.pending_requests, id)

  defp still_in_flight?(state, {:mrtr, pid}),
    do: Map.has_key?(Map.get(state, :mrtr_tasks) || %{}, pid)

  defp caller_watches(state), do: Map.get(state, :caller_watches) || %{}
  defp caller_monitors(state), do: Map.get(state, :caller_monitors) || %{}

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
        response_send_error(reason, state)

      {:error, reason, updated_state} ->
        response_send_error(reason, updated_state)
    end
  end

  defp response_send_error(reason, state) do
    Logger.error("Failed to send response to server", reason_shape: LogSummary.describe(reason))
    {:noreply, state}
  end
end
