defmodule Arbor.MCP.Transport.SSEClient do
  @moduledoc """
  Server-Sent Events client for the Streamable HTTP transport.

  This internal module implements the SSE portion of the Streamable HTTP
  transport as defined in the MCP specification. It provides robust connection
  handling with keep-alive, reconnection, and retry logic.

  Features:
  - Automatic reconnection with exponential backoff
  - Keep-alive/heartbeat mechanism
  - Proper handling of SSE retry suggestions
  - Connection health monitoring

  Note: This is an internal implementation detail of the Streamable HTTP transport.
  """

  use GenServer
  require Logger

  alias Arbor.MCP.Client.ConnectionScope
  alias Arbor.MCP.Internal.{Headers, Redaction, SSE}
  alias Arbor.MCP.Transport.HTTP.BoundedStream
  alias Arbor.RPC.LogSummary

  @initial_retry_delay 1_000
  @max_retry_delay 60_000
  @heartbeat_interval 30_000
  @connection_timeout 30_000
  @httpc_profiles [
    :sse_0,
    :sse_1,
    :sse_2,
    :sse_3,
    :sse_4,
    :sse_5,
    :sse_6,
    :sse_7,
    :sse_8,
    :sse_9,
    :sse_10,
    :sse_11,
    :sse_12,
    :sse_13,
    :sse_14,
    :sse_15
  ]

  # Request headers carry the connection's credentials and TLS options may
  # carry key material: neither is printed, and format_status/1 keeps them
  # out of crash reports too.
  @derive {Inspect, except: [:headers, :ssl_opts]}
  defstruct [
    :url,
    :headers,
    :ssl_opts,
    :parent,
    :ref,
    :buffer,
    :retry_delay,
    :retry_count,
    :heartbeat_ref,
    :last_event_id,
    :reconnect_timer,
    :connect_timeout,
    :handshake_timeout,
    :handshake_ref,
    :idle_timeout,
    :max_response_bytes,
    :max_buffer_bytes,
    :max_retry_delay,
    :consumer_ack_timeout,
    :dns_timeout_ms,
    :dns_resolver,
    :allowed_private_hosts,
    :httpc_profile,
    reconnect: true
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          headers: [{String.t(), String.t()}],
          ssl_opts: keyword(),
          parent: pid(),
          ref: reference() | nil,
          buffer: String.t(),
          retry_delay: non_neg_integer(),
          retry_count: non_neg_integer(),
          heartbeat_ref: reference() | nil,
          last_event_id: String.t() | nil,
          reconnect_timer: reference() | nil,
          connect_timeout: non_neg_integer(),
          handshake_timeout: non_neg_integer(),
          handshake_ref: reference() | nil,
          idle_timeout: non_neg_integer(),
          max_response_bytes: pos_integer(),
          max_buffer_bytes: pos_integer(),
          max_retry_delay: non_neg_integer(),
          consumer_ack_timeout: pos_integer(),
          dns_timeout_ms: pos_integer(),
          dns_resolver: module() | function(),
          allowed_private_hosts: [String.t()],
          httpc_profile: atom() | nil,
          reconnect: boolean()
        }

  # Client API

  @doc """
  Starts an SSE client connected to the given URL.

  Options:
  - `:url` - The SSE endpoint URL (required)
  - `:headers` - Additional HTTP headers
  - `:ssl_opts` - SSL options for HTTPS connections
  - `:parent` - Process to send events to (defaults to caller)
  - `:initial_retry_delay` - Initial reconnection delay in ms (default: #{@initial_retry_delay})
  - `:max_retry_delay` - Maximum reconnection delay in ms (default: #{@max_retry_delay})
  - `:connect_timeout` - Connection timeout in ms (default: #{@connection_timeout})
  - `:handshake_timeout` - Maximum time to receive response headers
  - `:idle_timeout` - Idle/heartbeat timeout in ms (default: #{@heartbeat_interval})
  - `:max_response_bytes` - Maximum non-streaming response size
  - `:max_buffer_bytes` - Maximum bytes retained for an incomplete SSE frame
  - `:consumer_ack_timeout` - Maximum time a downstream event consumer may stall
  - `:dns_timeout_ms` - Maximum time allowed for DNS resolution
  - `:dns_resolver` - Resolver module or function used before pinning the connection
  - `:allowed_private_hosts` - Exact hostnames explicitly permitted to resolve privately
  - `:reconnect` - Automatically reconnect after stream end or error (default: true)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ConnectionScope.start_process(__MODULE__, opts, :linked)
  end

  @doc """
  Stops the SSE client gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(client) do
    GenServer.stop(client)
  end

  @doc false
  @spec handshake_timer_active?(GenServer.server()) :: boolean()
  def handshake_timer_active?(client), do: GenServer.call(client, :handshake_timer_active?)

  # GenServer callbacks

  @impl true
  def init(opts) do
    :ok = ConnectionScope.register_process(Keyword.get(opts, :_connection_scope))
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, [])
    ssl_opts = Keyword.get(opts, :ssl_opts, [])
    parent = Keyword.get(opts, :parent, self())
    # Accept configurable timeouts with fallback to defaults
    connect_timeout = Keyword.get(opts, :connect_timeout, @connection_timeout)
    handshake_timeout = Keyword.get(opts, :handshake_timeout, connect_timeout)
    idle_timeout = Keyword.get(opts, :idle_timeout, @heartbeat_interval)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, 8 * 1_024 * 1_024)
    max_buffer_bytes = Keyword.get(opts, :max_buffer_bytes, 1 * 1_024 * 1_024)
    consumer_ack_timeout = positive_delay(Keyword.get(opts, :consumer_ack_timeout), 5_000)
    dns_timeout_ms = positive_delay(Keyword.get(opts, :dns_timeout_ms), 1_000)
    dns_resolver = Keyword.get(opts, :dns_resolver, Arbor.MCP.Internal.DNSResolver)
    allowed_private_hosts = Keyword.get(opts, :allowed_private_hosts, [])
    reconnect = Keyword.get(opts, :reconnect, true)

    # Use a bounded pool of predeclared httpc profiles to avoid creating
    # unreclaimable atoms per SSE connection.
    profile = httpc_profile()
    ensure_httpc_profile!(profile)

    # Use server-specified retry delay if provided (from POST SSE response)
    max_delay = positive_delay(Keyword.get(opts, :max_retry_delay), @max_retry_delay)

    initial_delay =
      opts
      |> Keyword.get(:initial_retry_delay)
      |> nonnegative_delay(@initial_retry_delay)
      |> min(max_delay)

    state = %__MODULE__{
      url: url,
      headers: headers,
      ssl_opts: ssl_opts,
      parent: parent,
      buffer: "",
      retry_delay: initial_delay,
      retry_count: 0,
      connect_timeout: connect_timeout,
      handshake_timeout: handshake_timeout,
      idle_timeout: idle_timeout,
      max_response_bytes: max_response_bytes,
      max_buffer_bytes: max_buffer_bytes,
      max_retry_delay: max_delay,
      consumer_ack_timeout: consumer_ack_timeout,
      dns_timeout_ms: dns_timeout_ms,
      dns_resolver: dns_resolver,
      allowed_private_hosts: allowed_private_hosts,
      httpc_profile: profile,
      reconnect: reconnect
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_call(:handshake_timer_active?, _from, state) do
    {:reply, is_reference(state.handshake_ref), state}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_sse(state) do
      {:ok, ref} ->
        # Store the reference but don't send connected message yet
        # We'll send it when we receive :stream_start
        # Don't reset retry_delay here - only reset when stream actually starts
        new_state = state |> Map.put(:ref, ref) |> reset_handshake_timer()

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("SSE connection failed",
          reason_shape: LogSummary.describe(reason)
        )

        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info(
        {:bounded_http, ref, {:stream_start, _status, headers}},
        %{ref: ref} = state
      ) do
    state = cancel_handshake_timer(state)
    BoundedStream.ack(ref)

    # Connection is now established, send notification
    :telemetry.execute([:arbor_mcp, :transport, :sse, :connected], %{}, %{
      endpoint_hash: LogSummary.fingerprint(state.url)
    })

    send(state.parent, {:sse_connected, self()})

    # Start heartbeat monitoring using configurable idle timeout
    heartbeat_ref = Process.send_after(self(), :check_heartbeat, state.idle_timeout)

    # Process headers for retry suggestions
    retry_after = get_retry_after(headers)

    # Only override retry_delay if server provides Retry-After header.
    # Preserve current retry_delay (may be set from SSE retry field or initial config).
    new_state =
      if retry_after do
        retry_delay = min(retry_after, div(state.max_retry_delay, 1000)) * 1000
        %{state | retry_delay: retry_delay, heartbeat_ref: heartbeat_ref, retry_count: 0}
      else
        %{state | heartbeat_ref: heartbeat_ref, retry_count: 0}
      end

    {:noreply, new_state}
  end

  def handle_info({:bounded_http, ref, {:stream, chunk}}, %{ref: ref} = state) do
    case append_chunk(state.buffer, chunk, state.max_buffer_bytes) do
      {:ok, buffer} ->
        {events, remaining} = SSE.parse_stream(buffer)

        if events != [] do
          Logger.debug("SSE Client parsed #{length(events)} events from chunk")
        end

        state =
          if events != [] or complete_sse_frame?(buffer),
            do: reset_heartbeat(state),
            else: state

        case process_events(events, %{state | buffer: remaining}) do
          {:ok, new_state} ->
            BoundedStream.ack(ref)
            {:noreply, new_state}

          {:error, reason, new_state} ->
            BoundedStream.cancel(ref)
            send(state.parent, {:sse_error, self(), reason})
            {:stop, :normal, new_state}
        end

      {:error, :stream_buffer_limit_exceeded} ->
        BoundedStream.cancel(state.ref)
        send(state.parent, {:sse_error, self(), :stream_buffer_limit_exceeded})
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:bounded_http, ref, {:stream_end, _headers}},
        %{ref: ref} = state
      ) do
    :telemetry.execute([:arbor_mcp, :transport, :sse, :disconnected], %{}, %{
      endpoint_hash: LogSummary.fingerprint(state.url)
    })

    Logger.info("SSE stream ended, reconnecting...")
    send(state.parent, {:sse_closed, self()})
    schedule_reconnect(state)
  end

  # Non-streaming HTTP response (e.g., 405 Method Not Allowed)
  def handle_info(
        {:bounded_http, ref, {:complete, 405, _headers, _body}},
        %{ref: ref} = state
      ) do
    state = cancel_handshake_timer(state)

    Logger.info("SSE: server returned 405 — SSE not supported, disabling")
    send(state.parent, {:sse_not_supported, self()})
    {:noreply, %{state | ref: nil}}
  end

  def handle_info(
        {:bounded_http, ref, {:complete, status, _headers, _body}},
        %{ref: ref} = state
      )
      when status >= 400 do
    state = cancel_handshake_timer(state)

    Logger.warning("SSE: server returned HTTP #{status}")
    send(state.parent, {:sse_error, self(), {:http_error, status}})
    schedule_reconnect(state)
  end

  def handle_info(
        {:bounded_http, ref, {:complete, status, _headers, _body}},
        %{ref: ref} = state
      ) do
    state = cancel_handshake_timer(state)
    send(state.parent, {:sse_error, self(), {:invalid_sse_response, status}})
    schedule_reconnect(state)
  end

  def handle_info(
        {:bounded_http, ref, {:error, :response_too_large}},
        %{ref: ref} = state
      ) do
    state = cancel_handshake_timer(state)
    send(state.parent, {:sse_error, self(), :response_too_large})
    {:stop, :normal, state}
  end

  def handle_info({:bounded_http, ref, {:error, reason}}, %{ref: ref} = state) do
    state = cancel_handshake_timer(state)

    Logger.error("SSE error",
      reason_shape: LogSummary.describe(reason)
    )

    send(state.parent, {:sse_error, self(), reason})
    schedule_reconnect(state)
  end

  def handle_info(:check_heartbeat, state) do
    # No data received within heartbeat interval, assume connection is dead
    Logger.warning("SSE heartbeat timeout, reconnecting...")

    if state.ref do
      BoundedStream.cancel(state.ref)
    end

    schedule_reconnect(state)
  end

  def handle_info(:handshake_timeout, %{ref: ref, heartbeat_ref: nil} = state)
      when not is_nil(ref) do
    BoundedStream.cancel(ref)
    send(state.parent, {:sse_error, self(), :stream_handshake_timeout})
    schedule_reconnect(%{state | handshake_ref: nil})
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # Force reconnect from parent (e.g., POST SSE response closed without result).
  # Delay briefly to let pending :stream messages drain first so we have
  # the latest last_event_id and retry_delay before reconnecting.
  def handle_info(:force_reconnect, state) do
    Logger.info("SSE forced reconnect requested, draining pending messages")
    Process.send_after(self(), :do_force_reconnect, 100)
    {:noreply, state}
  end

  def handle_info(:do_force_reconnect, state) do
    if state.ref do
      BoundedStream.cancel(state.ref)
    end

    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    schedule_reconnect(%{state | ref: nil, heartbeat_ref: nil})
  end

  # Update retry delay from parent (e.g., from POST SSE retry field)
  def handle_info({:update_retry_delay, delay}, state) when is_integer(delay) and delay >= 0 do
    {:noreply, %{state | retry_delay: min(delay, state.max_retry_delay)}}
  end

  def handle_info({:update_retry_delay, _invalid}, state), do: {:noreply, state}

  # Update last event ID from parent (e.g., from SSE event received before force_reconnect)
  def handle_info({:update_last_event_id, id}, state) when is_binary(id) do
    {:noreply, %{state | last_event_id: id}}
  end

  def handle_info({:change_parent, new_parent}, state) do
    {:noreply, %{state | parent: new_parent}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def format_status(status) do
    Redaction.status(status, fn
      %__MODULE__{} = state ->
        %{
          state
          | headers: Redaction.headers(state.headers),
            ssl_opts: Redaction.secret(state.ssl_opts),
            url: Redaction.url(state.url)
        }

      state ->
        state
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if state.ref do
      BoundedStream.cancel(state.ref)
    end

    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    cancel_handshake_timer(state)

    :ok
  end

  # Private functions

  defp connect_sse(state) do
    headers = build_headers(state)

    BoundedStream.start(
      self(),
      :get,
      state.url,
      headers,
      nil,
      connect_timeout: state.connect_timeout,
      transport_opts: state.ssl_opts,
      max_response_bytes: state.max_response_bytes,
      delivery_timeout: state.consumer_ack_timeout + 1_000,
      dns_timeout_ms: state.dns_timeout_ms,
      dns_resolver: state.dns_resolver,
      allowed_private_hosts: state.allowed_private_hosts
    )
  end

  defp httpc_profile do
    index = rem(:erlang.unique_integer([:positive, :monotonic]), length(@httpc_profiles))
    Enum.at(@httpc_profiles, index)
  end

  defp ensure_httpc_profile!(profile) do
    case :inets.start(:httpc, [{:profile, profile}]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp build_headers(state) do
    base_headers = [
      {"accept", "text/event-stream"},
      {"accept-encoding", "identity"},
      {"cache-control", "no-cache"},
      {"connection", "keep-alive"}
    ]

    # Add Last-Event-ID if we have one (for resumption)
    headers_with_id =
      if state.last_event_id do
        [{"last-event-id", state.last_event_id} | base_headers]
      else
        base_headers
      end

    # Merge with user-provided headers
    state.headers
    |> Headers.delete("accept-encoding")
    |> Kernel.++(headers_with_id)
    |> Enum.uniq_by(fn {k, _} -> String.downcase(to_string(k)) end)
  end

  defp process_event(event, state) do
    # Extract event data
    data = Map.get(event, "data", "")
    event_type = Map.get(event, "event", "message")
    id = Map.get(event, "id")

    Logger.debug("SSE Client processing event",
      event_type: event_type,
      event_id_hash: if(id, do: LogSummary.fingerprint(id)),
      data_size: byte_size(data)
    )

    :telemetry.execute([:arbor_mcp, :transport, :sse, :event], %{size: byte_size(data)}, %{
      event_type: event_type
    })

    # Send to parent
    send(
      state.parent,
      {:sse_event, self(),
       %{
         type: event_type,
         data: data,
         id: id
       }}
    )

    receive do
      {:sse_event_ack, parent} when parent == state.parent -> :ok
    after
      state.consumer_ack_timeout -> {:error, :stream_consumer_timeout}
    end
  end

  defp process_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, acc} ->
      acc = update_retry_delay(event, acc)
      id = Map.get(event, "id")

      # A zero-length `data:` field is a legal SSE priming event. It may carry
      # `retry` and `id`, but it is not an MCP JSON message and must not enter
      # the downstream acknowledgement path. Waiting for a consumer to decode
      # and acknowledge an empty payload blocks this GenServer, preventing the
      # reconnect timer and Last-Event-ID state from being applied.
      if Map.get(event, "data") not in [nil, ""] do
        case process_event(event, acc) do
          :ok -> {:cont, {:ok, maybe_put_last_event_id(acc, id)}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      else
        {:cont, {:ok, maybe_put_last_event_id(acc, id)}}
      end
    end)
  end

  defp maybe_put_last_event_id(state, nil), do: state
  defp maybe_put_last_event_id(state, id), do: %{state | last_event_id: id}

  defp update_retry_delay(event, state) do
    case Map.get(event, "retry") do
      nil ->
        state

      retry_str ->
        case Integer.parse(retry_str) do
          {ms, ""} when ms >= 0 ->
            delay = min(ms, state.max_retry_delay)
            Logger.debug("SSE retry field set to #{delay}ms")
            %{state | retry_delay: delay}

          _invalid ->
            state
        end
    end
  end

  defp reset_heartbeat(state) do
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref, async: false, info: false)
    end

    %{state | heartbeat_ref: Process.send_after(self(), :check_heartbeat, state.idle_timeout)}
  end

  defp reset_handshake_timer(state) do
    state = cancel_handshake_timer(state)

    %{
      state
      | handshake_ref: Process.send_after(self(), :handshake_timeout, state.handshake_timeout)
    }
  end

  defp cancel_handshake_timer(%{handshake_ref: nil} = state), do: state

  defp cancel_handshake_timer(state) do
    Process.cancel_timer(state.handshake_ref, async: false, info: false)
    %{state | handshake_ref: nil}
  end

  @doc false
  @spec append_chunk(binary(), iodata(), pos_integer()) ::
          {:ok, binary()} | {:error, :stream_buffer_limit_exceeded}
  def append_chunk(buffer, chunk, max_bytes)
      when is_binary(buffer) and is_integer(max_bytes) and max_bytes > 0 do
    chunk = IO.iodata_to_binary(chunk)

    if byte_size(buffer) + byte_size(chunk) <= max_bytes,
      do: {:ok, buffer <> chunk},
      else: {:error, :stream_buffer_limit_exceeded}
  end

  defp complete_sse_frame?(buffer) do
    String.contains?(buffer, "\n\n") or String.contains?(buffer, "\r\r") or
      String.contains?(buffer, "\r\n\r\n")
  end

  defp schedule_reconnect(%{reconnect: false} = state) do
    state = cancel_handshake_timer(state)

    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    if state.ref do
      BoundedStream.cancel(state.ref)
    end

    {:stop, :normal, %{state | ref: nil, heartbeat_ref: nil}}
  end

  defp schedule_reconnect(state) do
    state = cancel_handshake_timer(state)

    :telemetry.execute(
      [:arbor_mcp, :transport, :sse, :reconnecting],
      %{delay_ms: state.retry_delay},
      %{retry_count: state.retry_count}
    )

    # Cancel existing timers
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    if state.ref do
      BoundedStream.cancel(state.ref)
    end

    # Use server-specified retry delay, or exponential backoff
    delay = state.retry_delay
    # Only apply backoff if using the initial default (not server-specified)
    new_delay =
      if delay == @initial_retry_delay do
        min(delay * 2, state.max_retry_delay)
      else
        delay
      end

    # Add small buffer to ensure we never reconnect early per spec requirement.
    # The MCP spec says client MUST wait at least the retry time.
    buffered_delay = min(delay + 50, state.max_retry_delay)
    Logger.info("Scheduling SSE reconnection in #{buffered_delay}ms (retry: #{delay}ms)")

    reconnect_timer = Process.send_after(self(), :reconnect, buffered_delay)

    new_state = %{
      state
      | ref: nil,
        heartbeat_ref: nil,
        reconnect_timer: reconnect_timer,
        retry_delay: new_delay,
        retry_count: state.retry_count + 1
    }

    {:noreply, new_state}
  end

  defp get_retry_after(headers) do
    headers
    |> Enum.find(fn {name, _} ->
      String.downcase(to_string(name)) == "retry-after"
    end)
    |> case do
      {_, value} ->
        case Integer.parse(to_string(value)) do
          {seconds, ""} when seconds >= 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp positive_delay(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_delay(_value, default), do: default

  defp nonnegative_delay(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_delay(_value, default), do: default

  @impl true
  def handle_cast({:update_last_id, id}, state) do
    {:noreply, %{state | last_event_id: id}}
  end
end
