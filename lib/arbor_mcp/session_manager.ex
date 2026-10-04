defmodule Arbor.MCP.SessionManager do
  @moduledoc """
  Legacy session management for Streamable HTTP connections.

  This module supports the initialize-based MCP 2025-03-26 through
  2025-11-25 transport lifecycle. MCP 2026-07-28 HTTP is stateless and does
  not use this manager, `Mcp-Session-Id`, `Last-Event-ID`, GET streams, or
  DELETE termination.

  For legacy connections, this module provides session management for MCP
  servers using Streamable HTTP and Server-Sent Events (SSE).
  It handles session lifecycle, event buffering, and session resumption
  through Last-Event-ID support.

  ## Features

  - Session lifecycle management (create, update, terminate)
  - Event buffering and replay for connection resumption
  - Last-Event-ID support for seamless reconnection
  - Session expiration and cleanup
  - Memory-efficient event storage with configurable limits
  - Session health monitoring and metrics

  ## Session Lifecycle

  1. **Session Creation**: Legacy Streamable HTTP creates a server-issued ID
     only for `initialize`; deprecated HTTP+SSE retains its endpoint handshake.
  2. **Initialization**: Exactly one monitored request may initialize a session;
     success immutably binds the negotiated version and failure terminates it.
  3. **Event Storage**: Events are buffered with unique IDs for potential replay.
  4. **Session Resumption**: Initialized clients reconnect using the issued ID
     and may resume events with `Last-Event-ID`.
  5. **Session Termination**: Sessions terminate on explicit DELETE, abandoned
     initialization, or timeout.

  ## Configuration

  - `:max_events_per_session` - Maximum events to buffer per session (default: 1000)
  - `:max_sessions` - Maximum active/retained sessions (default: 10,000)
  - `:max_request_ids` - Maximum claimed JSON-RPC request IDs per session
    (default: 10,000)
  - `:max_event_bytes` - Maximum JSON-encoded bytes for one replay event
    (default: 1 MiB)
  - `:max_replay_bytes_per_session` - Maximum JSON-encoded replay bytes retained
    per session (default: 8 MiB)
  - `:session_ttl_seconds` - Session TTL in seconds (default: 3600).
    Wall-clock idle expiry: `created_at` and `last_activity` are absolute
    `System.system_time(:microsecond)` timestamps. Cleanup expires a session
    when that wall clock is more than TTL seconds after `last_activity`.
    This is intentional and is not monotonic elapsed time; changing it would
    change the meaning of the public timestamps and of `:session_ttl_seconds`.
    If the wall clock moves backwards, elapsed time is negative and the
    session is not treated as expired — the correct absolute-expiry outcome.
  - `:cleanup_interval_ms` - Cleanup interval in milliseconds (default: 60000)
  - `:storage_backend` - Storage backend (`:ets`, `:persistent_term`, or
    `:dets`, default: `:ets`). ETS remains the default. `:persistent_term`
    is accepted for 1.x compatibility and still uses ETS (no-op durability).
    `:dets` is an opt-in durable backend and requires `:storage_path` (or
    `:dets_path`): a directory owned by one SessionManager. Restarting that
    process with the same path retains sessions and events. Two runtimes
    must not share the same files.

  ## Usage

      # Start the session manager
      {:ok, _pid} = Arbor.MCP.SessionManager.start_link([])

      # Create a new session
      session_id = Arbor.MCP.SessionManager.create_session(%{
        transport: :sse,
        client_info: %{user_agent: "my-client/1.0"}
      })

      # Store an event
      Arbor.MCP.SessionManager.store_event(session_id, %{
        id: "event-123",
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      })

      # Replay events after a specific event ID
      events = Arbor.MCP.SessionManager.replay_events_after(session_id, "event-122")

      # Terminate session
      Arbor.MCP.SessionManager.terminate_session(session_id)
  """

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  require Logger

  alias Arbor.MCP.Internal.SessionStore
  alias Arbor.MCP.Server.Runtime.ServiceRef
  alias Arbor.MCP.SessionManager.Addressed
  alias Arbor.RPC.LogSummary

  # Default configuration
  @default_max_events 1000
  @default_max_event_bytes 1_048_576
  @default_max_replay_bytes_per_session 8_388_608
  @default_max_sessions 10_000
  @default_max_request_ids 10_000
  @default_session_ttl 3600
  @default_cleanup_interval 60_000
  @default_storage_backend :ets
  @identity_keys [:principal_id, :tenant_id, :issuer, :audience]
  @lifecycle_keys [:initialized, :initialization_claimed]

  defstruct [
    :sessions_table,
    :events_table,
    :request_ids_table,
    :store,
    :config,
    :cleanup_timer,
    initialization_claims: %{},
    event_clock: 0
  ]

  @type session_id :: String.t()
  @type event_id :: String.t()
  @type session_data :: %{
          id: session_id(),
          transport: atom(),
          client_info: map(),
          created_at: integer(),
          last_activity: integer(),
          event_count: non_neg_integer(),
          replay_bytes: non_neg_integer(),
          request_id_count: non_neg_integer(),
          status: :active | :terminated,
          initialized: boolean(),
          initialization_claimed: boolean(),
          protocol_version: String.t() | nil,
          principal_id: String.t() | nil,
          tenant_id: String.t() | nil,
          issuer: String.t() | nil,
          audience: String.t() | [String.t()] | nil
        }
  @type event_data :: %{
          id: event_id(),
          session_id: session_id(),
          type: String.t(),
          data: term(),
          timestamp: integer()
        }
  @type config :: %{
          max_sessions: pos_integer(),
          max_request_ids: pos_integer(),
          max_events_per_session: pos_integer(),
          max_event_bytes: pos_integer(),
          max_replay_bytes_per_session: pos_integer(),
          session_ttl_seconds: pos_integer(),
          cleanup_interval_ms: pos_integer(),
          storage_backend: :ets | :persistent_term | :dets,
          storage_path: String.t() | nil
        }

  ## Public API

  @doc """
  Starts the session manager with optional configuration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Creates a new session with the given metadata.

  Returns a unique session ID that can be used for subsequent operations.
  """
  @spec create_session(map()) :: session_id() | {:error, :session_limit_exceeded}
  def create_session(metadata \\ %{}) do
    GenServer.call(__MODULE__, {:create_session, metadata})
  end

  @doc """
  Verifies that a server-issued session ID exists, is active, and is bound to
  the same authorization identity, then refreshes its activity.

  Legacy Streamable HTTP issues the ID on POST before the client opens its SSE
  channel. Retaining that exact ID associates later subscriptions and
  notifications with one client across both channels.
  """
  @spec ensure_session(session_id(), map()) ::
          :ok | {:error, :session_not_found | :session_identity_mismatch}
  def ensure_session(session_id, metadata \\ %{}) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:ensure_session, session_id, metadata})
  end

  @doc """
  Atomically verifies that a session is active, identity-bound to the caller,
  and has completed initialization, then refreshes its activity.
  """
  @spec ensure_initialized_session(session_id(), map()) ::
          :ok
          | {:error, :session_not_found | :session_identity_mismatch | :session_not_initialized}
  def ensure_initialized_session(session_id, metadata \\ %{}) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:ensure_initialized_session, session_id, metadata})
  end

  @doc """
  Atomically claims a JSON-RPC request ID for an active session.

  IDs remain claimed for the session lifetime. The configured
  `:max_request_ids` bound fails closed once reached.
  """
  @spec claim_request_id(session_id(), String.t() | integer()) ::
          :ok
          | {:error, :session_not_found | :duplicate_request_id | :request_id_limit_exceeded}
  def claim_request_id(session_id, request_id)
      when is_binary(session_id) and (is_binary(request_id) or is_integer(request_id)) do
    GenServer.call(__MODULE__, {:claim_request_id, session_id, request_id})
  end

  @doc """
  Atomically claims the one initialization attempt allowed for an active
  legacy session. This prevents concurrent or repeated `initialize` requests
  from racing into application handlers.
  """
  @spec claim_initialization(session_id()) ::
          :ok
          | {:error,
             :session_not_found | :session_already_initialized | :initialization_in_progress}
  def claim_initialization(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:claim_initialization, session_id})
  end

  @doc """
  Completes a previously claimed initialization and immutably binds its
  negotiated protocol version to the session.
  """
  @spec complete_initialization(session_id(), String.t()) ::
          :ok
          | {:error,
             :session_not_found
             | :initialization_not_claimed
             | :initialization_owner_mismatch
             | :session_protocol_version_mismatch}
  def complete_initialization(session_id, protocol_version)
      when is_binary(session_id) and is_binary(protocol_version) do
    GenServer.call(__MODULE__, {:complete_initialization, session_id, protocol_version})
  end

  @doc """
  Stores an event for the given session.

  Events are stored with their ID, type, data, and timestamp for potential
  replay during session resumption.
  """
  @spec store_event(session_id(), event_data()) ::
          :ok | {:error, :session_not_found | :event_too_large | :event_not_json_encodable}
  def store_event(session_id, event_data) do
    GenServer.call(__MODULE__, {:store_event, session_id, event_data})
  end

  @doc """
  Atomically appends an event using a store-owned, monotonically increasing ID.

  Legacy SSE delivery uses this function before writing to the connection so
  events remain replayable when the write races a disconnect. The returned
  event is the public representation retained by the session manager.
  """
  @spec append_event(session_id(), String.t(), term()) ::
          {:ok, event_data()}
          | {:error, :session_not_found | :event_too_large | :event_not_json_encodable}
  def append_event(session_id, type, data) when is_binary(session_id) and is_binary(type) do
    GenServer.call(__MODULE__, {:append_event, session_id, type, data})
  end

  @doc """
  Replays events for a session after the given event ID.

  This is used when legacy clients reconnect with a Last-Event-ID header
  to resume from where they left off.
  """
  @spec replay_events_after(session_id(), event_id() | nil) ::
          [event_data()] | {:error, :session_not_found}
  def replay_events_after(session_id, last_event_id \\ nil) do
    GenServer.call(__MODULE__, {:replay_events_after, session_id, last_event_id})
  end

  @doc """
  Replays events for a session after the given event ID and sends them to the handler.

  This is the callback function referenced in SSEHandler for session replay.
  """
  @spec replay_events_after(session_id(), event_id() | nil, pid()) ::
          :ok | {:error, :session_not_found}
  def replay_events_after(session_id, last_event_id, handler_pid) do
    case replay_events_after(session_id, last_event_id) do
      {:error, reason} ->
        {:error, reason}

      events when is_list(events) ->
        # Send events to the SSE handler
        Enum.each(events, fn event ->
          if Process.alive?(handler_pid) do
            # Use GenServer.cast to send the event to the SSE handler
            GenServer.cast(
              handler_pid,
              {:send_event, event.type, event.data, [event_id: event.id, persist: false]}
            )
          end
        end)

        :ok
    end
  end

  @doc """
  Updates session metadata or activity timestamp.
  """
  @spec update_session(session_id(), map()) ::
          :ok
          | {:error,
             :session_not_found
             | :session_identity_mismatch
             | :session_protocol_version_mismatch}
  def update_session(session_id, updates) do
    GenServer.call(__MODULE__, {:update_session, session_id, updates})
  end

  @doc """
  Terminates a session and cleans up its events.

  This should be called when a session is explicitly deleted or permanently
  abandoned. A transient SSE disconnect alone does not terminate the session,
  because its events must remain available for Last-Event-ID replay.
  """
  @spec terminate_session(session_id()) :: :ok
  def terminate_session(session_id) do
    GenServer.call(__MODULE__, {:terminate_session, session_id})
  end

  @doc """
  Gets session information.
  """
  @spec get_session(session_id()) :: {:ok, session_data()} | {:error, :session_not_found}
  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @doc """
  Lists all active sessions.
  """
  @spec list_sessions() :: [session_data()]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @doc """
  Gets session statistics.
  """
  @spec get_stats() :: %{
          total_sessions: non_neg_integer(),
          active_sessions: non_neg_integer(),
          total_events: non_neg_integer(),
          memory_usage: non_neg_integer()
        }
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc "Creates an addressed runtime session and returns an opaque lease. Standalone create_session/1 retains its legacy result."
  @spec create_session(ServiceRef.t(), map(), keyword()) ::
          {:ok, Arbor.MCP.SessionManager.SessionLease.t()} | {:error, term()}
  def create_session(service, metadata, opts),
    do: Addressed.create(service, metadata, opts)

  @doc "Validates an addressed session's identity and returns its current lease."
  @spec ensure_session(ServiceRef.t(), binary(), map(), keyword()) ::
          {:ok, Arbor.MCP.SessionManager.SessionLease.t()} | {:error, term()}
  def ensure_session(service, id, metadata, opts),
    do: Addressed.ensure(service, id, metadata, false, opts)

  @doc "Validates addressed identity and completed initialization."
  @spec ensure_initialized_session(ServiceRef.t(), binary(), map(), keyword()) ::
          {:ok, Arbor.MCP.SessionManager.SessionLease.t()} | {:error, term()}
  def ensure_initialized_session(service, id, metadata, opts),
    do: Addressed.ensure(service, id, metadata, true, opts)

  @doc "Claims a typed wire request ID for an addressed session epoch."
  @spec claim_request_id(
          ServiceRef.t(),
          Arbor.MCP.SessionManager.SessionLease.t(),
          binary() | integer(),
          keyword()
        ) :: :ok | {:error, term()}
  def claim_request_id(service, lease, id, opts),
    do: Addressed.leased(service, lease, :claim_id, [id], opts)

  @doc """
  Claims addressed initialization with an immutable invocation cutoff.

  Runtime callbacks retain their actual request owner and original deadline.
  An explicit `:owner` must match that owner; `:deadline` may shorten the original
  cutoff. `:timeout` limits the service RPC wait and does not renew the claim.
  Outside callbacks the explicit live owner defaults to the caller and the claim
  uses the finite service-operation cutoff. Unauthenticated future deadline
  integers cannot create a longer request lifetime.
  """
  @spec claim_initialization(ServiceRef.t(), Arbor.MCP.SessionManager.SessionLease.t(), keyword()) ::
          {:ok, Arbor.MCP.SessionManager.InitializationClaim.t()} | {:error, term()}
  def claim_initialization(service, lease, opts),
    do: Addressed.claim_initialization(service, lease, opts)

  @doc """
  Completes an addressed claim while its original owner and invocation are active.

  A different worker can complete it. Each completion attempt has a separate
  finite store wait, bounded by the unchanged claim cutoff and any shorter caller
  deadline. Retrying a timed-out call does not refresh the claim's lifetime.
  """
  def complete_initialization(%ServiceRef{} = service, claim, version, opts),
    do: Addressed.complete_initialization(service, claim, version, opts)

  @doc "Appends a bounded replay event before any downstream delivery."
  def append_event(%ServiceRef{} = service, lease, type, data, opts),
    do: Addressed.leased(service, lease, :append, [type, data], opts)

  @doc "Reads a bounded replay page with tagged evicted, foreign and unknown cursor outcomes."
  def replay_page(%ServiceRef{} = service, lease, cursor, opts),
    do:
      Addressed.leased(
        service,
        lease,
        :replay,
        [cursor, Keyword.get(opts, :max_events, 32), Keyword.get(opts, :max_bytes, 65_536)],
        opts
      )

  @doc "Closes one addressed session epoch; stale leases cannot close its replacement."
  def terminate_session(%ServiceRef{} = service, lease, opts),
    do: Addressed.leased(service, lease, :terminate, [], opts)

  @doc "Reads an active addressed session."
  def get_session(%ServiceRef{} = service, lease, opts),
    do: Addressed.leased(service, lease, :get, [], opts)

  @doc "Reads aggregate addressed session service accounting."
  def get_stats(%ServiceRef{} = service, opts),
    do: Addressed.call(service, :stats, [], opts)

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)
    max_request_ids = Keyword.get(opts, :max_request_ids, @default_max_request_ids)

    max_events_per_session =
      Keyword.get(opts, :max_events_per_session, @default_max_events)

    max_event_bytes = Keyword.get(opts, :max_event_bytes, @default_max_event_bytes)

    max_replay_bytes_per_session =
      Keyword.get(
        opts,
        :max_replay_bytes_per_session,
        @default_max_replay_bytes_per_session
      )

    validate_positive_limit!(:max_sessions, max_sessions)
    validate_positive_limit!(:max_request_ids, max_request_ids)
    validate_positive_limit!(:max_events_per_session, max_events_per_session)
    validate_positive_limit!(:max_event_bytes, max_event_bytes)
    validate_positive_limit!(:max_replay_bytes_per_session, max_replay_bytes_per_session)

    # Build configuration
    config = %{
      max_sessions: max_sessions,
      max_request_ids: max_request_ids,
      max_events_per_session: max_events_per_session,
      max_event_bytes: max_event_bytes,
      max_replay_bytes_per_session: max_replay_bytes_per_session,
      session_ttl_seconds: Keyword.get(opts, :session_ttl_seconds, @default_session_ttl),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval),
      storage_backend: Keyword.get(opts, :storage_backend, @default_storage_backend),
      storage_path: Keyword.get(opts, :storage_path) || Keyword.get(opts, :dets_path)
    }

    if config.storage_backend == :persistent_term do
      Logger.warning(
        "storage_backend: :persistent_term is accepted for 1.x compatibility and currently uses ETS (no-op durability)"
      )
    end

    store = open_store!(config)

    # Start cleanup timer
    cleanup_timer =
      Process.send_after(self(), :cleanup_expired_sessions, config.cleanup_interval_ms)

    state = %__MODULE__{
      sessions_table: store.sessions,
      events_table: store.events,
      request_ids_table: store.request_ids,
      store: store,
      config: config,
      cleanup_timer: cleanup_timer,
      initialization_claims: %{},
      event_clock: SessionStore.event_clock(store)
    }

    # Debug, not info: a library must not write to stdout during application
    # boot, and a stdio server's protocol stream is stdout. The default Elixir
    # logger writes there, and the application boots before the stdio
    # transport can suppress logging.
    Logger.debug("SessionManager started",
      storage_backend: config.storage_backend,
      storage_path: config.storage_path,
      max_sessions: config.max_sessions,
      max_request_ids: config.max_request_ids,
      session_ttl_seconds: config.session_ttl_seconds,
      max_events_per_session: config.max_events_per_session,
      max_event_bytes: config.max_event_bytes,
      max_replay_bytes_per_session: config.max_replay_bytes_per_session,
      cleanup_interval_ms: config.cleanup_interval_ms
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, metadata}, _from, state) do
    prune_terminated_sessions(state)

    if SessionStore.info(state.store, :sessions, :size) >= state.config.max_sessions do
      {:reply, {:error, :session_limit_exceeded}, state}
    else
      create_session(metadata, state)
    end
  end

  @impl true
  def handle_call({:ensure_session, session_id, metadata}, _from, state) do
    now = System.system_time(:microsecond)

    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        if session_identity_matches?(session, metadata) do
          session_data =
            session
            |> Map.merge(Map.take(metadata, [:transport, :client_info]))
            |> Map.put(:last_activity, now)

          SessionStore.insert(state.store, :sessions, {session_id, session_data})
          {:reply, :ok, state}
        else
          {:reply, {:error, :session_identity_mismatch}, state}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:ensure_initialized_session, session_id, metadata}, _from, state) do
    now = System.system_time(:microsecond)

    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        cond do
          not session_identity_matches?(session, metadata) ->
            {:reply, {:error, :session_identity_mismatch}, state}

          not session.initialized ->
            {:reply, {:error, :session_not_initialized}, state}

          true ->
            updated =
              session
              |> Map.merge(Map.take(metadata, [:transport, :client_info]))
              |> Map.put(:last_activity, now)

            SessionStore.insert(state.store, :sessions, {session_id, updated})
            {:reply, :ok, state}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:claim_request_id, session_id, request_id}, _from, state) do
    key = {session_id, request_id}

    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        cond do
          SessionStore.member(state.store, :request_ids, key) ->
            {:reply, {:error, :duplicate_request_id}, state}

          session.request_id_count >= state.config.max_request_ids ->
            {:reply, {:error, :request_id_limit_exceeded}, state}

          true ->
            true = SessionStore.insert_new(state.store, :request_ids, {key})

            updated_session = %{
              session
              | request_id_count: session.request_id_count + 1,
                last_activity: System.system_time(:microsecond)
            }

            SessionStore.insert(state.store, :sessions, {session_id, updated_session})
            {:reply, :ok, state}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:claim_initialization, session_id}, {owner, _tag}, state) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        cond do
          session.initialized ->
            {:reply, {:error, :session_already_initialized}, state}

          session.initialization_claimed ->
            {:reply, {:error, :initialization_in_progress}, state}

          true ->
            monitor = Process.monitor(owner)

            updated = %{
              session
              | initialization_claimed: true,
                last_activity: System.system_time(:microsecond)
            }

            SessionStore.insert(state.store, :sessions, {session_id, updated})

            claim = %{owner: owner, monitor: monitor}

            next_state = %{
              state
              | initialization_claims: Map.put(state.initialization_claims, session_id, claim)
            }

            {:reply, :ok, next_state}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:complete_initialization, session_id, version}, {owner, _tag}, state) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        cond do
          not session.initialization_claimed ->
            {:reply, {:error, :initialization_not_claimed}, state}

          not initialization_owned_by?(state, session_id, owner) ->
            {:reply, {:error, :initialization_owner_mismatch}, state}

          not initialization_protocol_version_allowed?(session, version) ->
            {:reply, {:error, :session_protocol_version_mismatch}, state}

          true ->
            updated = %{
              session
              | initialized: true,
                initialization_claimed: false,
                protocol_version: version,
                last_activity: System.system_time(:microsecond)
            }

            SessionStore.insert(state.store, :sessions, {session_id, updated})
            {:reply, :ok, release_initialization_claim(state, session_id)}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:append_event, session_id, type, data}, _from, state) do
    sequence = state.event_clock + 1

    event = %{
      id: "#{sequence}-0",
      session_id: session_id,
      type: type,
      data: data,
      timestamp: System.system_time(:microsecond)
    }

    case store_event(state, session_id, event, true) do
      {:ok, state} -> {:reply, {:ok, event}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:store_event, session_id, event_data}, _from, state) do
    case store_event(state, session_id, event_data) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:replay_events_after, session_id, last_event_id}, _from, state) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, _session}] ->
        events = get_events_after(state, session_id, last_event_id)
        {:reply, events, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_session, session_id, updates}, _from, state) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active} = session}] ->
        cond do
          not identity_update_allowed?(session, updates) ->
            {:reply, {:error, :session_identity_mismatch}, state}

          not protocol_version_update_allowed?(session, updates) ->
            {:reply, {:error, :session_protocol_version_mismatch}, state}

          true ->
            # Authorization identity and a negotiated protocol version are
            # immutable for the lifetime of a session.
            updated_session =
              session
              |> Map.merge(
                Map.drop(updates, @identity_keys ++ @lifecycle_keys ++ [:protocol_version])
              )
              |> Map.put(:last_activity, System.system_time(:microsecond))

            SessionStore.insert(state.store, :sessions, {session_id, updated_session})
            {:reply, :ok, state}
        end

      _missing_or_terminated ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:terminate_session, session_id}, _from, state) do
    # Mark session as terminated
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, session}] ->
        terminated_session = %{
          session
          | status: :terminated,
            event_count: 0,
            replay_bytes: 0
        }

        SessionStore.insert(state.store, :sessions, {session_id, terminated_session})

        # Clean up events for this session
        cleanup_session_events(state, session_id)
        cleanup_session_request_ids(state, session_id)
        Arbor.MCP.SubscriptionRegistry.remove_session(session_id)

        Logger.debug("Terminated session", session_id_hash: LogSummary.fingerprint(session_id))

      [] ->
        :ok
    end

    {:reply, :ok, release_initialization_claim(state, session_id)}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, session}] ->
        {:reply, {:ok, session}, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions =
      SessionStore.all(state.store, :sessions)
      |> Enum.map(fn {_id, session} -> session end)
      |> Enum.filter(&(&1.status == :active))

    {:reply, sessions, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    sessions = SessionStore.all(state.store, :sessions)
    active_sessions = Enum.count(sessions, fn {_id, session} -> session.status == :active end)
    total_events = SessionStore.info(state.store, :events, :size)

    memory_usage =
      SessionStore.info(state.store, :sessions, :memory) +
        SessionStore.info(state.store, :events, :memory) +
        SessionStore.info(state.store, :request_ids, :memory)

    stats = %{
      total_sessions: length(sessions),
      active_sessions: active_sessions,
      total_events: total_events,
      memory_usage: memory_usage
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_expired_sessions, state) do
    state = cleanup_expired_sessions(state)

    # Schedule next cleanup
    cleanup_timer =
      Process.send_after(self(), :cleanup_expired_sessions, state.config.cleanup_interval_ms)

    {:noreply, %{state | cleanup_timer: cleanup_timer}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case initialization_claim_for_monitor(state, monitor, owner) do
      {session_id, _claim} ->
        terminate_abandoned_initialization(state, session_id)
        {:noreply, release_initialization_claim(state, session_id, false)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("SessionManager received unexpected message",
      message_shape: LogSummary.describe(msg)
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cleanup_timer do
      Process.cancel_timer(state.cleanup_timer)
    end

    SessionStore.close(state.store)

    :ok
  end

  ## Private Functions

  defp create_session(metadata, state) do
    session_id = generate_session_id()
    now = System.system_time(:microsecond)

    session_data = %{
      id: session_id,
      transport: Map.get(metadata, :transport, :http),
      client_info: Map.get(metadata, :client_info, %{}),
      created_at: now,
      last_activity: now,
      event_count: 0,
      replay_bytes: 0,
      request_id_count: 0,
      status: :active,
      initialized: false,
      initialization_claimed: false,
      protocol_version: nil,
      principal_id: Map.get(metadata, :principal_id),
      tenant_id: Map.get(metadata, :tenant_id),
      issuer: Map.get(metadata, :issuer),
      audience: Map.get(metadata, :audience)
    }

    SessionStore.insert(state.store, :sessions, {session_id, session_data})

    Logger.debug("Created session",
      session_id_hash: LogSummary.fingerprint(session_id),
      transport: session_data.transport
    )

    {:reply, session_id, state}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # Once any identity component is bound, session reuse must present it. This
  # prevents an internal caller from accidentally bypassing the binding by
  # omitting identity metadata on a later transport operation.
  defp session_identity_matches?(session, metadata) do
    Enum.all?(@identity_keys, fn key ->
      case Map.get(session, key) do
        nil -> not Map.has_key?(metadata, key) or is_nil(Map.get(metadata, key))
        bound -> Map.has_key?(metadata, key) and Map.get(metadata, key) == bound
      end
    end)
  end

  defp identity_update_allowed?(session, metadata) do
    Enum.all?(@identity_keys, fn key ->
      not Map.has_key?(metadata, key) or Map.get(session, key) == Map.get(metadata, key)
    end)
  end

  defp protocol_version_update_allowed?(session, updates) do
    case Map.fetch(updates, :protocol_version) do
      :error ->
        true

      {:ok, version} when is_binary(version) ->
        is_binary(session.protocol_version) and session.protocol_version == version

      {:ok, nil} ->
        is_nil(session.protocol_version)

      {:ok, _invalid} ->
        false
    end
  end

  defp initialization_protocol_version_allowed?(session, version) when is_binary(version) do
    is_nil(session.protocol_version) or session.protocol_version == version
  end

  defp initialization_protocol_version_allowed?(_session, _version), do: false

  defp initialization_owned_by?(state, session_id, owner) do
    case Map.get(state.initialization_claims, session_id) do
      %{owner: ^owner} -> true
      _missing_or_other_owner -> false
    end
  end

  defp initialization_claim_for_monitor(state, monitor, owner) do
    Enum.find(state.initialization_claims, fn
      {_session_id, %{monitor: ^monitor, owner: ^owner}} -> true
      _other -> false
    end)
  end

  defp release_initialization_claim(state, session_id, flush? \\ true) do
    case Map.pop(state.initialization_claims, session_id) do
      {nil, _claims} ->
        state

      {%{monitor: monitor}, claims} ->
        if flush?, do: Process.demonitor(monitor, [:flush])
        %{state | initialization_claims: claims}
    end
  end

  defp terminate_abandoned_initialization(state, session_id) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, %{status: :active, initialized: false} = session}] ->
        terminated = %{
          session
          | status: :terminated,
            initialization_claimed: false,
            event_count: 0,
            replay_bytes: 0
        }

        SessionStore.insert(state.store, :sessions, {session_id, terminated})
        cleanup_session_events(state, session_id)
        cleanup_session_request_ids(state, session_id)
        Arbor.MCP.SubscriptionRegistry.remove_session(session_id)

        Logger.debug("Terminated abandoned initialization",
          session_id_hash: LogSummary.fingerprint(session_id)
        )

      _missing_terminated_or_completed ->
        :ok
    end
  end

  defp prune_terminated_sessions(state) do
    state.store
    |> SessionStore.all(:sessions)
    |> Enum.each(fn
      {session_id, %{status: :terminated}} ->
        cleanup_session_events(state, session_id)
        cleanup_session_request_ids(state, session_id)
        SessionStore.delete(state.store, :sessions, session_id)

      _active ->
        :ok
    end)
  end

  defp get_events_after(state, session_id, nil) do
    events_for_session(state, session_id)
    |> Enum.map(&strip_event_sequence/1)
  end

  defp get_events_after(state, session_id, last_event_id) do
    events = events_for_session(state, session_id)

    replay_events =
      case Enum.find_index(events, &(&1.id == last_event_id)) do
        nil ->
          # Compatibility for callers that supply an ID no longer retained by
          # the bounded buffer, or custom IDs written through store_event/2.
          Enum.filter(events, &(compare_event_ids(&1.id, last_event_id) == :gt))

        index ->
          Enum.drop(events, index + 1)
      end

    Enum.map(replay_events, &strip_event_sequence/1)
  end

  defp events_for_session(state, session_id) do
    pattern = {{session_id, :"$1"}, :"$2"}

    events =
      SessionStore.match(state.store, :events, pattern)
      |> Enum.map(fn [_event_id, event_data] -> event_data end)

    if Enum.all?(events, &Map.get(&1, :__ex_mcp_managed__, false)) do
      Enum.sort_by(events, &Map.fetch!(&1, :__ex_mcp_sequence__))
    else
      # Preserve the existing timestamp ordering for callers of store_event/2.
      # Managed SSE-only sessions use the store sequence above, which remains
      # ordered even if the system wall clock is adjusted.
      Enum.sort_by(events, fn event ->
        {Map.get(event, :timestamp), Map.get(event, :__ex_mcp_sequence__, 0), event.id}
      end)
    end
  end

  defp strip_event_sequence(event_data) do
    event_data
    |> Map.delete(:__ex_mcp_sequence__)
    |> Map.delete(:__ex_mcp_managed__)
    |> Map.delete(:__ex_mcp_encoded_bytes__)
  end

  defp compare_event_ids(event_id1, event_id2) do
    # Parse event IDs to compare them properly
    # Assumes format like "timestamp-counter" from SSEHandler
    case {parse_event_id(event_id1), parse_event_id(event_id2)} do
      {{ts1, counter1}, {ts2, counter2}} ->
        cond do
          ts1 > ts2 -> :gt
          ts1 < ts2 -> :lt
          counter1 > counter2 -> :gt
          counter1 < counter2 -> :lt
          true -> :eq
        end

      _ ->
        # Fallback to string comparison
        cond do
          event_id1 > event_id2 -> :gt
          event_id1 < event_id2 -> :lt
          true -> :eq
        end
    end
  end

  defp parse_event_id(event_id) do
    case String.split(event_id, "-", parts: 2) do
      [timestamp_str, counter_str] ->
        with {timestamp, ""} <- Integer.parse(timestamp_str),
             {counter, ""} <- Integer.parse(counter_str) do
          {timestamp, counter}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp store_event(state, session_id, event_data) do
    store_event(state, session_id, event_data, false)
  end

  defp store_event(state, session_id, event_data, managed?) do
    case SessionStore.lookup(state.store, :sessions, session_id) do
      [{^session_id, session}] when session.status == :active ->
        event_data = sanitize_event_metadata(event_data, managed?)

        with {:ok, encoded_bytes} <- encoded_event_size(event_data),
             :ok <-
               enforce_event_size(
                 encoded_bytes,
                 min(state.config.max_event_bytes, state.config.max_replay_bytes_per_session)
               ) do
          event_key = {session_id, event_data.id}

          {event_data, state, _new_event?} =
            normalize_event_sequence(state, event_key, event_data)

          event_data = Map.put(event_data, :__ex_mcp_encoded_bytes__, encoded_bytes)
          SessionStore.insert(state.store, :events, {event_key, event_data})

          {retained_count, replay_bytes} = trim_events_to_limits(state, session_id)

          updated_session = %{
            session
            | last_activity: System.system_time(:microsecond),
              event_count: retained_count,
              replay_bytes: replay_bytes
          }

          SessionStore.insert(state.store, :sessions, {session_id, updated_session})
          {:ok, state}
        else
          {:error, reason} -> {:error, reason, state}
        end

      _ ->
        {:error, :session_not_found, state}
    end
  end

  defp sanitize_event_metadata(event_data, managed?) do
    event_data =
      Map.drop(event_data, [
        :__ex_mcp_sequence__,
        :__ex_mcp_managed__,
        :__ex_mcp_encoded_bytes__
      ])

    if managed?, do: Map.put(event_data, :__ex_mcp_managed__, true), else: event_data
  end

  defp encoded_event_size(event_data) do
    event_data
    |> strip_event_sequence()
    |> Jason.encode_to_iodata()
    |> case do
      {:ok, encoded} -> {:ok, IO.iodata_length(encoded)}
      {:error, _reason} -> {:error, :event_not_json_encodable}
    end
  rescue
    _error -> {:error, :event_not_json_encodable}
  end

  defp enforce_event_size(size, maximum) when size <= maximum, do: :ok
  defp enforce_event_size(_size, _maximum), do: {:error, :event_too_large}

  defp normalize_event_sequence(state, event_key, event_data) do
    case SessionStore.lookup(state.store, :events, event_key) do
      [{^event_key, existing}] ->
        sequence = Map.get(existing, :__ex_mcp_sequence__, state.event_clock)
        {Map.put(event_data, :__ex_mcp_sequence__, sequence), state, false}

      [] ->
        sequence = state.event_clock + 1
        event_data = Map.put(event_data, :__ex_mcp_sequence__, sequence)
        next = persist_event_clock(%{state | event_clock: max(state.event_clock, sequence)})
        {event_data, next, true}
    end
  end

  defp trim_events_to_limits(state, session_id) do
    events = events_for_session(state, session_id)

    {event_sizes, invalid_events} =
      Enum.reduce(events, {[], []}, fn event, {valid, invalid} ->
        case stored_event_size(event) do
          {:ok, size} -> {[{event, size} | valid], invalid}
          :error -> {valid, [event | invalid]}
        end
      end)

    Enum.each(invalid_events, fn event ->
      SessionStore.delete(state.store, :events, {session_id, event.id})
    end)

    event_sizes = Enum.reverse(event_sizes)
    event_count = length(event_sizes)
    replay_bytes = Enum.reduce(event_sizes, 0, fn {_event, size}, total -> size + total end)

    {discarded, retained_count, retained_bytes} =
      Enum.reduce_while(event_sizes, {[], event_count, replay_bytes}, fn {event, event_bytes},
                                                                         {discarded, count, bytes} ->
        if count > state.config.max_events_per_session or
             bytes > state.config.max_replay_bytes_per_session do
          {:cont, {[event | discarded], count - 1, bytes - event_bytes}}
        else
          {:halt, {discarded, count, bytes}}
        end
      end)

    Enum.each(discarded, fn event ->
      SessionStore.delete(state.store, :events, {session_id, event.id})
    end)

    {retained_count, retained_bytes}
  end

  defp stored_event_size(event) do
    case Map.fetch(event, :__ex_mcp_encoded_bytes__) do
      {:ok, size} when is_integer(size) and size >= 0 ->
        {:ok, size}

      _missing_or_invalid ->
        case encoded_event_size(event) do
          {:ok, size} -> {:ok, size}
          {:error, _reason} -> :error
        end
    end
  rescue
    _error -> :error
  end

  defp cleanup_session_events(state, session_id) do
    # Delete all events for the session
    pattern = {{session_id, :"$1"}, :_}

    SessionStore.match(state.store, :events, pattern)
    |> Enum.each(fn [event_id] ->
      SessionStore.delete(state.store, :events, {session_id, event_id})
    end)
  end

  defp cleanup_session_request_ids(state, session_id) do
    SessionStore.match_delete(state.store, :request_ids, {{session_id, :_}})
  end

  # Session TTL is wall-clock idle expiry by design. last_activity is an
  # absolute System.system_time(:microsecond) timestamp on the public
  # session record, so expiry compares civil time rather than monotonic
  # elapsed duration. A backwards wall clock yields a negative difference
  # and does not expire the session — the correct absolute-expiry result.
  # Do not switch this to System.monotonic_time/1; that would change the
  # meaning of :session_ttl_seconds and of created_at/last_activity.
  defp cleanup_expired_sessions(state) do
    now = System.system_time(:microsecond)
    ttl_microseconds = state.config.session_ttl_seconds * 1_000_000

    expired_sessions =
      SessionStore.all(state.store, :sessions)
      |> Enum.filter(fn {_id, session} ->
        session.status == :active and now - session.last_activity > ttl_microseconds
      end)

    state =
      Enum.reduce(expired_sessions, state, fn {session_id, session}, acc ->
        Logger.debug("Cleaning up expired session",
          session_id_hash: LogSummary.fingerprint(session_id)
        )

        # Mark as terminated and clean up events
        terminated_session = %{
          session
          | status: :terminated,
            initialization_claimed: false,
            event_count: 0,
            replay_bytes: 0
        }

        SessionStore.insert(acc.store, :sessions, {session_id, terminated_session})
        cleanup_session_events(acc, session_id)
        cleanup_session_request_ids(acc, session_id)
        Arbor.MCP.SubscriptionRegistry.remove_session(session_id)
        release_initialization_claim(acc, session_id)
      end)

    if length(expired_sessions) > 0 do
      Logger.debug("Cleaned up #{length(expired_sessions)} expired sessions")
    end

    state
  end

  defp validate_positive_limit!(name, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError, "#{inspect(name)} must be a positive integer"
    end
  end

  defp persist_event_clock(state) do
    %{state | store: SessionStore.put_event_clock(state.store, state.event_clock)}
  end

  defp open_store!(config) do
    case SessionStore.Factory.open(config) do
      {:ok, store} ->
        store

      {:error, :storage_path_required} ->
        raise ArgumentError, "storage_backend: :dets requires :storage_path (or :dets_path)"

      {:error, :storage_in_use} ->
        raise ArgumentError,
              "storage_backend: :dets path is already open by another SessionManager"

      {:error, reason} ->
        raise ArgumentError, "failed to open session store: #{inspect(reason)}"
    end
  end
end
