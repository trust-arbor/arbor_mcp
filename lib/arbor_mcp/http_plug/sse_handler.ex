defmodule Arbor.MCP.HttpPlug.SSEHandler do
  @moduledoc """
  Server-Sent Events handler with backpressure control.

  This module implements a robust SSE handler that prevents memory leaks
  through demand-based flow control. It ensures that event producers
  cannot overwhelm the SSE connection with unbounded message queues.

  ## Features

  - Demand-based backpressure control
  - Event buffering with size limits
  - Last-Event-ID support for resumption
  - Structured error propagation
  - Connection health monitoring
  - Graceful shutdown

  ## Architecture

  The handler uses a GenServer that manages the SSE connection lifecycle.
  Event producers must request permission before sending events, preventing
  unbounded mailbox growth.
  """

  use GenServer
  require Logger

  alias Arbor.MCP.HttpPlug.SessionRegistry
  alias Arbor.MCP.HttpPlug.SSEConnection
  alias Arbor.RPC.LogSummary

  @max_mailbox_size 10
  @heartbeat_interval 30_000
  @event_id_buffer_size 1000

  defstruct [
    :conn,
    :conn_module,
    :conn_owner,
    :session_id,
    :opts,
    :event_counter,
    :event_buffer,
    :mailbox_monitor,
    :heartbeat_ref,
    :producers,
    :last_event_id
  ]

  @type t :: %__MODULE__{
          conn: Plug.Conn.t() | term(),
          conn_module: module(),
          conn_owner: pid() | nil,
          session_id: String.t(),
          opts: map(),
          event_counter: non_neg_integer(),
          event_buffer: :queue.queue(),
          mailbox_monitor: reference() | nil,
          heartbeat_ref: reference() | nil,
          producers: MapSet.t(pid()),
          last_event_id: String.t() | nil
        }

  @doc """
  Starts an SSE handler for the given connection.

  The calling process is treated as the connection owner: when it exits
  (client disconnect, timeout, crash), the handler shuts down and cleans up
  its session registration.
  """
  @spec start_link(Plug.Conn.t(), String.t(), map()) :: {:ok, pid()} | {:error, any()}
  def start_link(conn, session_id, opts) do
    GenServer.start_link(__MODULE__, {conn, session_id, opts, self()})
  end

  @doc """
  Requests permission to send an event. This implements backpressure.

  The caller will block until the handler is ready to accept more events.
  Returns `:ok` when it's safe to send, or `{:error, reason}` if the
  connection is closed or errored.
  """
  @spec request_send(pid()) :: :ok | {:error, any()}
  def request_send(handler) do
    GenServer.call(handler, :request_send, :infinity)
  end

  @doc """
  Sends an event after permission has been granted.

  This should only be called after `request_send/1` returns `:ok`. When the
  handler was started with a session manager, the event is persisted before
  it is written to the connection. Internal replay callers pass
  `persist: false` to avoid recording the same event twice.
  """
  @spec send_event(pid(), String.t(), any(), keyword()) :: :ok
  def send_event(handler, event_type, data, opts \\ []) do
    GenServer.cast(handler, {:send_event, event_type, data, opts})
  end

  @doc false
  @spec replay(pid()) :: :ok | {:error, term()}
  def replay(handler) do
    GenServer.call(handler, :replay_events, :infinity)
  end

  @doc """
  Sends an error event and closes the connection gracefully.
  """
  @spec send_error(pid(), any()) :: :ok
  def send_error(handler, error) do
    GenServer.cast(handler, {:send_error, error})
  end

  @doc """
  Closes the SSE connection gracefully.
  """
  @spec close(pid()) :: :ok
  def close(handler) do
    GenServer.stop(handler, :normal)
  end

  # GenServer Callbacks

  @impl true
  def init({conn, session_id, opts}) do
    init({conn, session_id, opts, nil})
  end

  def init({conn, session_id, opts, conn_owner}) do
    Process.flag(:trap_exit, true)

    # The connection adapter is resolved once, here, so the write path has no
    # runtime branching on the shape of `conn` (audit L6).
    conn_module = SSEConnection.resolve(opts)

    # Extract Last-Event-ID if provided
    last_event_id = extract_last_event_id(conn_module, conn)

    # Send the configured handshake event. Streamable HTTP's legacy GET stream
    # keeps the historical `connected` event, while the deprecated 2024-11-05
    # HTTP+SSE transport must begin with a raw URI in an `endpoint` event.
    {initial_event_type, initial_event_data} =
      Map.get(opts, :initial_sse_event, {"connected", %{session_id: session_id}})

    event_id = generate_event_id(0)

    case send_sse_event(
           conn_module,
           conn,
           initial_event_type,
           initial_event_data,
           event_id
         ) do
      {:ok, conn} ->
        # Start heartbeat timer
        heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)

        # Initialize state
        state = %__MODULE__{
          conn: conn,
          conn_module: conn_module,
          conn_owner: conn_owner,
          session_id: session_id,
          opts: opts,
          event_counter: 1,
          event_buffer: :queue.new(),
          heartbeat_ref: heartbeat_ref,
          producers: MapSet.new(),
          last_event_id: last_event_id
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:connection_failed, reason}}
    end
  end

  @impl true
  def handle_call(:request_send, from, state) do
    # Check mailbox size
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    cond do
      # Connection is closed or errored
      state.conn == nil ->
        {:reply, {:error, :connection_closed}, state}

      # Mailbox is too full - apply backpressure
      queue_len > @max_mailbox_size ->
        # Don't reply yet - the caller will block
        # We'll reply when the mailbox drains
        state = %{state | producers: MapSet.put(state.producers, from)}
        {:noreply, state}

      # Safe to proceed
      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:replay_events, _from, state) do
    case replay_events(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:send_event, event_type, data, opts}, state) do
    case prepare_event(state, event_type, data, opts) do
      {:ok, event_id} ->
        case deliver_event(state, event_type, data, event_id) do
          {:ok, state} ->
            {:noreply, maybe_unblock_producers(state)}

          {:duplicate, state} ->
            {:noreply, maybe_unblock_producers(state)}

          {:error, _reason, state} ->
            # The event was already persisted, so a reconnect can recover it
            # even though this connection failed during the write.
            {:stop, :normal, %{state | conn: nil}}
        end

      {:error, reason} ->
        # Do not deliver an event with a fabricated ID when persistence is
        # configured but unavailable; that would make Last-Event-ID lie.
        Logger.error("Failed to persist SSE event",
          session_id_hash: LogSummary.fingerprint(state.session_id),
          reason: LogSummary.describe(reason)
        )

        {:noreply, maybe_unblock_producers(state)}
    end
  end

  @impl true
  def handle_cast({:send_error, error}, state) do
    error_data = format_error(error)

    # Send error event
    case send_sse_event(state, "error", error_data, generate_event_id(state.event_counter)) do
      {:ok, conn} ->
        # Send close event
        send_sse_event(
          %{state | conn: conn},
          "close",
          %{reason: "error"},
          generate_event_id(state.event_counter + 1)
        )

      _ ->
        :ok
    end

    {:stop, :normal, %{state | conn: nil}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Send heartbeat
    case send_sse_event(state, "heartbeat", %{timestamp: System.system_time(:second)}, nil) do
      {:ok, conn} ->
        # Schedule next heartbeat
        heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
        {:noreply, %{state | conn: conn, heartbeat_ref: heartbeat_ref}}

      {:error, _reason} ->
        # Connection failed
        {:stop, :normal, %{state | conn: nil}}
    end
  end

  @impl true
  def handle_info(:check_mailbox, state) do
    # Periodic check to unblock producers if mailbox has drained
    state = maybe_unblock_producers(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %__MODULE__{conn_owner: pid} = state) do
    # The request process that owns the SSE socket exited (client disconnect,
    # timeout, crash). The connection is unusable, so stop and let terminate/2
    # clean up the session registration. conn is cleared to avoid writing a
    # close event to a dead socket.
    {:stop, :normal, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Ignore exits from other linked processes
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("SSE handler received unexpected message",
      message_shape: LogSummary.describe(msg)
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel heartbeat timer
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    # Send close event if connection is still open
    if state.conn do
      send_sse_event(
        state,
        "close",
        %{reason: "shutdown"},
        generate_event_id(state.event_counter)
      )
    end

    # Reply to any blocked producers
    Enum.each(state.producers, fn pid ->
      GenServer.reply(pid, {:error, :connection_closed})
    end)

    # Deregister on every exit path so client-first disconnects cannot leak
    # ETS entries. Scoped to this pid so a newer handler that re-registered
    # the same session id is left untouched.
    if state.session_id do
      SessionRegistry.unregister(state.session_id, self())
    end

    :ok
  end

  # Private Functions

  defp extract_last_event_id(conn_module, conn) do
    case conn_module.get_req_header(conn, "last-event-id") do
      [id | _] -> id
      _none -> nil
    end
  end

  defp generate_event_id(counter) do
    "#{System.system_time(:microsecond)}-#{counter}"
  end

  defp send_sse_event(%__MODULE__{} = state, event_type, data, event_id) do
    send_sse_event(state.conn_module, state.conn, event_type, data, event_id)
  end

  defp send_sse_event(conn_module, conn, event_type, data, event_id) do
    formatted_data = format_event_data(data)

    message =
      case event_id do
        nil ->
          "event: #{event_type}\ndata: #{formatted_data}\n\n"

        id ->
          "id: #{id}\nevent: #{event_type}\ndata: #{formatted_data}\n\n"
      end

    case conn_module.chunk(conn, message) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_event_data({:raw, data}) when is_binary(data), do: data
  defp format_event_data(data), do: Jason.encode!(data)

  defp buffer_event(state, event_type, data, event_id) do
    # Add to buffer
    event = {event_id, event_type, data}
    buffer = :queue.in(event, state.event_buffer)

    # Trim buffer if too large
    buffer =
      if :queue.len(buffer) > @event_id_buffer_size do
        {_, buffer} = :queue.out(buffer)
        buffer
      else
        buffer
      end

    %{state | event_buffer: buffer}
  end

  defp maybe_unblock_producers(state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len < @max_mailbox_size and MapSet.size(state.producers) > 0 do
      # Unblock one producer
      case MapSet.to_list(state.producers) do
        [producer | _rest] ->
          GenServer.reply(producer, :ok)
          %{state | producers: MapSet.delete(state.producers, producer)}

        [] ->
          state
      end
    else
      # Schedule a check if we still have blocked producers
      if MapSet.size(state.producers) > 0 do
        Process.send_after(self(), :check_mailbox, 100)
      end

      state
    end
  end

  defp prepare_event(state, event_type, data, opts) do
    requested_id = Keyword.get(opts, :event_id)

    if Keyword.get(opts, :persist, true) do
      persist_event(state, event_type, data, requested_id)
    else
      {:ok, requested_id || generate_event_id(state.event_counter)}
    end
  end

  defp persist_event(state, event_type, data, requested_id) do
    session_manager = Map.get(state.opts, :session_manager)

    cond do
      exports?(session_manager, :append_event, 3) and is_nil(requested_id) ->
        session_manager
        |> safe_apply(:append_event, [state.session_id, event_type, data])
        |> normalize_append_result()

      exports?(session_manager, :store_event, 2) ->
        persist_via_store(session_manager, state, event_type, data, requested_id)

      true ->
        # Direct users without session management and custom 1.x managers that
        # predate persistence retain historical live-delivery behavior.
        {:ok, requested_id || generate_event_id(state.event_counter)}
    end
  end

  defp persist_via_store(session_manager, state, event_type, data, requested_id) do
    event_id = requested_id || generate_event_id(state.event_counter)

    event = %{
      id: event_id,
      session_id: state.session_id,
      type: event_type,
      data: data,
      timestamp: System.system_time(:microsecond)
    }

    case safe_apply(session_manager, :store_event, [state.session_id, event]) do
      :ok -> {:ok, event_id}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_store_reply, other}}
    end
  end

  defp normalize_append_result({:ok, %{id: event_id}}), do: {:ok, event_id}
  defp normalize_append_result({:ok, event_id}) when is_binary(event_id), do: {:ok, event_id}
  defp normalize_append_result({:error, _reason} = error), do: error
  defp normalize_append_result(other), do: {:error, {:unexpected_append_reply, other}}

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp exports?(_module, _function, _arity), do: false

  defp replay_events(%__MODULE__{last_event_id: nil} = state), do: {:ok, state}

  defp replay_events(state) do
    session_manager = Map.get(state.opts, :session_manager)

    cond do
      exports?(session_manager, :replay_events_after, 2) ->
        case safe_apply(session_manager, :replay_events_after, [
               state.session_id,
               state.last_event_id
             ]) do
          events when is_list(events) -> replay_events(events, state)
          {:error, reason} -> {:error, reason, state}
          other -> {:error, {:unexpected_replay_reply, other}, state}
        end

      exports?(session_manager, :replay_events_after, 3) ->
        case safe_apply(session_manager, :replay_events_after, [
               state.session_id,
               state.last_event_id,
               self()
             ]) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
          other -> {:error, {:unexpected_replay_reply, other}, state}
        end

      true ->
        {:error, :event_replay_not_supported, state}
    end
  end

  defp replay_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case deliver_event(state, event.type, event.data, event.id) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:duplicate, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp deliver_event(state, event_type, data, event_id) do
    if buffered_event?(state, event_id) do
      {:duplicate, state}
    else
      case send_sse_event(state, event_type, data, event_id) do
        {:ok, conn} ->
          state = %{state | conn: conn, event_counter: state.event_counter + 1}
          {:ok, buffer_event(state, event_type, data, event_id)}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp buffered_event?(_state, nil), do: false

  defp buffered_event?(state, event_id) do
    state.event_buffer
    |> :queue.to_list()
    |> Enum.any?(fn {buffered_id, _type, _data} -> buffered_id == event_id end)
  end

  defp format_error(error) do
    case error do
      %{__struct__: mod} = e
      when mod in [
             Arbor.MCP.Error.ProtocolError,
             Arbor.MCP.Error.TransportError,
             Arbor.MCP.Error.ToolError,
             Arbor.MCP.Error.ResourceError,
             Arbor.MCP.Error.ValidationError
           ] ->
        Arbor.MCP.Error.to_json_rpc(e)

      {type, _reason} when is_atom(type) ->
        %{
          code: -32000,
          message: "#{type}: internal error",
          data: nil
        }

      _reason ->
        %{
          code: -32000,
          message: "Internal server error",
          data: nil
        }
    end
  end
end
