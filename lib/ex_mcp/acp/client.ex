defmodule ExMCP.ACP.Client do
  @moduledoc """
  GenServer client for the Agent Client Protocol (ACP).

  Manages connections to ACP-compatible coding agents over stdio, handling
  the initialize handshake, session lifecycle, and bidirectional communication
  (streaming updates from agent, permission/file requests from agent).

  ## Usage

      {:ok, client} = ExMCP.ACP.Client.start_link(
        command: ["gemini", "--acp"],
        handler: MyApp.ACPHandler
      )

      {:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/path/to/project")
      {:ok, %{"stopReason" => _}} = ExMCP.ACP.Client.prompt(client, sid, "Fix the bug in auth.ex")

  ## Options

  - `:command` — command list for the agent subprocess (required)
  - `:handler` — module implementing `ExMCP.ACP.Client.Handler` (default: `DefaultHandler`)
  - `:handler_opts` — options passed to `handler.init/1` (default: `[]`)
  - `:event_listener` — PID to receive `{:acp_session_update, session_id, update}` messages
  - `:client_info` — `%{"name" => ..., "version" => ...}` (default: `%{"name" => "ex_mcp", "version" => "0.1.0"}`)
  - `:capabilities` — client capabilities map
  - `:protocol_version` — integer (default: 1)
  - `:initialize_timeout` — total initialize-handshake timeout in milliseconds
    (default: 30_000)
  - `:max_frame_bytes` — maximum inbound or outbound JSON-RPC frame size
    (default: 1 MiB)
  - `:max_pending_requests` — maximum concurrent requests in either direction
    (default: 1,024)
  - `:max_prompt_text_bytes` — maximum streamed prompt text retained per session
    (default: 1 MiB)
  - `:pending_request_timeout` — server-side lifetime for outbound requests
    (default: 30_000 ms)
  - `:handler_request_timeout` — lifetime for inbound client-handler callbacks
    (default: 30_000 ms)
  - `:max_update_queue` — mailbox cutoff for handler/listener session updates;
    excess updates are dropped (default: 32)
  - `:notify_update_drops` — opt in to coalesced event-listener messages
    `{:acp_session_updates_dropped, session_id, count}` once mailbox room is
    available (default: false). Notices obey the same queue bounds; a notice
    too large for the byte limit is telemetry-only.
  - `:max_update_queue_bytes` — aggregate encoded size cutoff for queued
    handler/listener session updates (default: 8 MiB)
  - `:name` — GenServer name registration
  """

  use GenServer

  require Logger

  alias ExMCP.ACP.{Capabilities, LifecycleParams, Maps, PendingRequests, RequestValidation}
  alias ExMCP.ACP.Client.DefaultHandler
  alias ExMCP.ACP.Client.HandlerRunner
  alias ExMCP.ACP.Internal.UpdateQueue
  alias ExMCP.ACP.Protocol
  alias ExMCP.Internal.{LogSummary, Options, WorkspacePath}
  alias ExMCP.Transport.Stdio

  @default_initialize_timeout 30_000
  @maximum_initialize_timeout 4_294_967_295
  @default_max_frame_bytes 1_048_576
  @default_max_pending_requests 1_024
  @default_max_prompt_text_bytes 1_048_576
  @default_pending_request_timeout 30_000
  @default_handler_request_timeout 30_000
  @default_max_update_queue 32
  @default_max_update_queue_bytes 8_388_608
  @supported_protocol_versions [1]

  defstruct [
    :transport_mod,
    :transport_state,
    :receiver_pid,
    :agent_info,
    :agent_capabilities,
    :client_capabilities,
    :auth_methods,
    :handler_mod,
    :handler_pid,
    :event_listener,
    :protocol_version,
    max_frame_bytes: @default_max_frame_bytes,
    max_pending_requests: @default_max_pending_requests,
    max_prompt_text_bytes: @default_max_prompt_text_bytes,
    pending_request_timeout: @default_pending_request_timeout,
    handler_request_timeout: @default_handler_request_timeout,
    max_update_queue: @default_max_update_queue,
    max_update_queue_bytes: @default_max_update_queue_bytes,
    notify_update_drops: false,
    update_drops: %{},
    update_drop_timer: nil,
    pending_requests: %{},
    pending_caller_monitors: %{},
    pending_agent_requests: %{},
    sessions: %{},
    # Accumulates streamed agent_message_chunk text per session so a synchronous
    # prompt/3 can return it — agents that stream the answer via session/update
    # otherwise leave the prompt result with no text.
    prompt_text: %{},
    status: :connecting
  ]

  # Public API

  @doc "Starts the ACP client and connects to the agent."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, client_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, client_opts, gen_opts)
  end

  @doc """
  Authenticates with the agent.

  Pass either a method ID advertised in the initialize response's
  `"authMethods"` list or a full params map for adapter compatibility.
  """
  @spec authenticate(GenServer.server(), String.t() | map(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def authenticate(client, method_id_or_params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, {:authenticate, method_id_or_params}, timeout)
  end

  @doc "Logs out of the current authenticated state if the agent supports `auth.logout`."
  @spec logout(GenServer.server(), keyword()) :: {:ok, map() | nil} | {:error, any()}
  def logout(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, :logout, timeout)
  end

  @doc """
  Creates a new agent session.

  `cwd` is required per ACP spec
  (https://agentclientprotocol.com/protocol/session-setup).
  """
  @spec new_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def new_session(client, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, {:new_session, cwd, LifecycleParams.client_opts(opts)}, timeout)
  end

  @doc """
  Loads an existing session and replays previous messages when the agent supports it.

  `cwd` is required per ACP spec.
  """
  @spec load_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def load_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    GenServer.call(
      client,
      {:load_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Resumes an existing session without replaying previous messages.

  `cwd` is required per ACP spec.
  """
  @spec resume_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def resume_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    GenServer.call(
      client,
      {:resume_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Forks an existing session into a new independent session.

  `session/fork` is currently unstable in ACP and requires the agent to
  advertise `sessionCapabilities.fork`.
  """
  @spec fork_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def fork_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    GenServer.call(
      client,
      {:fork_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Sends a prompt to the agent and blocks until the response arrives.

  Streaming `session/update` notifications are delivered to the handler and
  event listener as they arrive. The caller is unblocked when the agent sends
  the JSON-RPC result for the prompt request.
  """
  @spec prompt(GenServer.server(), String.t(), String.t() | [map()], keyword()) ::
          {:ok, map()} | {:error, any()}
  def prompt(client, session_id, content, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenServer.call(client, {:prompt, session_id, content}, timeout)
  end

  @doc "Lists available sessions from the agent. Stabilized in ACP spec March 9, 2026."
  @spec list_sessions(GenServer.server(), keyword()) :: {:ok, map()} | {:error, any()}
  def list_sessions(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, {:list_sessions, opts}, timeout)
  end

  @doc "Cancels the current prompt in a session (fire-and-forget)."
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(client, session_id) do
    GenServer.cast(client, {:cancel, session_id})
  end

  @doc "Sends a `$/cancel_request` notification for a specific JSON-RPC request."
  @spec cancel_request(GenServer.server(), integer() | String.t() | nil) :: :ok
  def cancel_request(client, request_id) do
    GenServer.cast(client, {:cancel_request, request_id})
  end

  @doc "Closes an active session and frees agent-side resources."
  @spec close_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def close_session(client, session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, {:close_session, session_id}, timeout)
  end

  @doc "Deletes a session from the agent's session history."
  @spec delete_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def delete_session(client, session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(client, {:delete_session, session_id}, timeout)
  end

  @doc "Sets the agent mode for a session."
  @spec set_mode(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def set_mode(client, session_id, mode_id) do
    GenServer.call(client, {:set_mode, session_id, mode_id})
  end

  @doc "Sets the model for a session."
  @spec set_model(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def set_model(client, session_id, model_id) do
    GenServer.call(client, {:set_model, session_id, model_id})
  end

  @doc "Sets a config option for a session."
  @spec set_config_option(GenServer.server(), String.t(), String.t(), any()) ::
          {:ok, map()} | {:error, any()}
  def set_config_option(client, session_id, config_id, value) do
    GenServer.call(client, {:set_config_option, session_id, config_id, value})
  end

  @doc "Returns the agent's capabilities from the initialize handshake."
  @spec agent_capabilities(GenServer.server()) :: {:ok, map() | nil}
  def agent_capabilities(client) do
    GenServer.call(client, :agent_capabilities)
  end

  @doc "Returns the agent's authentication methods from the initialize handshake."
  @spec auth_methods(GenServer.server()) :: {:ok, [map()]}
  def auth_methods(client) do
    GenServer.call(client, :auth_methods)
  end

  @doc "Returns the client connection status."
  @spec status(GenServer.server()) :: atom()
  def status(client) do
    GenServer.call(client, :status)
  end

  @doc """
  Ends a session.

  Uses `session/close` when advertised by the agent, otherwise preserves the
  historical local telemetry-only behavior.
  """
  @spec end_session(GenServer.server(), String.t()) ::
          :ok | {:ok, map() | nil} | {:error, any()}
  def end_session(client, session_id) do
    GenServer.call(client, {:end_session, session_id})
  end

  @doc "Disconnects from the agent."
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(client) do
    GenServer.call(client, :disconnect)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    handler_mod = Keyword.get(opts, :handler, DefaultHandler)
    handler_opts = Keyword.get(opts, :handler_opts, [])

    case HandlerRunner.start_link(handler_mod, handler_opts, self()) do
      {:ok, handler_pid} ->
        state = %__MODULE__{
          transport_mod: Keyword.get(opts, :transport_mod, Stdio),
          handler_mod: handler_mod,
          handler_pid: handler_pid,
          event_listener: Keyword.get(opts, :event_listener),
          notify_update_drops: Keyword.get(opts, :notify_update_drops, false) == true,
          protocol_version: Keyword.get(opts, :protocol_version, 1),
          max_frame_bytes:
            Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes),
          max_pending_requests:
            Options.positive_integer(opts, :max_pending_requests, @default_max_pending_requests),
          max_prompt_text_bytes:
            Options.positive_integer(opts, :max_prompt_text_bytes, @default_max_prompt_text_bytes),
          pending_request_timeout:
            Options.positive_integer(
              opts,
              :pending_request_timeout,
              @default_pending_request_timeout
            ),
          handler_request_timeout:
            Options.positive_integer(
              opts,
              :handler_request_timeout,
              @default_handler_request_timeout
            ),
          max_update_queue:
            Options.positive_integer(opts, :max_update_queue, @default_max_update_queue),
          max_update_queue_bytes:
            Options.positive_integer(
              opts,
              :max_update_queue_bytes,
              @default_max_update_queue_bytes
            )
        }

        # Allow skipping connection for tests
        if Keyword.get(opts, :_skip_connect) do
          {:ok, %{state | status: :ready}}
        else
          case connect_and_initialize(opts, state) do
            {:ok, state} -> {:ok, state}
            {:error, reason} -> {:stop, reason}
          end
        end

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:new_session, cwd, lifecycle_opts}, from, %{status: :ready} = state) do
    with :ok <- LifecycleParams.validate_cwd(cwd),
         :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
      msg = Protocol.encode_session_new(cwd, lifecycle_opts)
      send_request(msg, from, state, {:new_session, session_roots(cwd, lifecycle_opts)})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:authenticate, method_id_or_params}, from, %{status: :ready} = state) do
    msg = Protocol.encode_authenticate(method_id_or_params)
    send_request(msg, from, state)
  end

  def handle_call(:logout, from, %{status: :ready} = state) do
    case ensure_capability(state, :logout) do
      :ok ->
        msg = Protocol.encode_logout()
        send_request(msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_sessions, opts}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_list) do
      :ok ->
        msg = Protocol.encode_session_list(opts)
        send_request(msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:load_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :load_session) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          msg = Protocol.encode_session_load(session_id, cwd, lifecycle_opts)

          send_request(
            msg,
            from,
            state,
            {:load_session, session_id, session_roots(cwd, lifecycle_opts)}
          )
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resume_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :session_resume) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          msg = Protocol.encode_session_resume(session_id, cwd, lifecycle_opts)

          send_request(
            msg,
            from,
            state,
            {:resume_session, session_id, session_roots(cwd, lifecycle_opts)}
          )
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:fork_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :session_fork) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          msg = Protocol.encode_session_fork(session_id, cwd, lifecycle_opts)
          send_request(msg, from, state, {:fork_session, session_roots(cwd, lifecycle_opts)})
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prompt, session_id, content}, from, %{status: :ready} = state) do
    with {:ok, blocks} <- prompt_blocks(content),
         :ok <- validate_prompt_blocks(state, blocks) do
      :telemetry.execute(
        [:ex_mcp, :acp, :prompt, :sent],
        %{system_time: System.system_time()},
        %{session_id_hash: session_id_hash(session_id)}
      )

      msg = Protocol.encode_session_prompt(session_id, blocks)
      state = %{state | prompt_text: Map.delete(state.prompt_text, session_id)}
      send_request(msg, from, state, {:prompt, session_id})
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_mode, session_id, mode_id}, from, %{status: :ready} = state) do
    msg = Protocol.encode_session_set_mode(session_id, mode_id)
    send_request(msg, from, state)
  end

  def handle_call({:set_model, session_id, model_id}, from, %{status: :ready} = state) do
    msg = Protocol.encode_session_set_model(session_id, model_id)
    send_request(msg, from, state)
  end

  def handle_call(
        {:set_config_option, session_id, config_id, value},
        from,
        %{status: :ready} = state
      ) do
    msg = Protocol.encode_session_set_config_option(session_id, config_id, value)
    send_request(msg, from, state)
  end

  def handle_call(:agent_capabilities, _from, state) do
    {:reply, {:ok, state.agent_capabilities}, state}
  end

  def handle_call(:auth_methods, _from, state) do
    {:reply, {:ok, state.auth_methods || []}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:close_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_close) do
      :ok ->
        msg = Protocol.encode_session_close(session_id)
        send_request(msg, from, state, {:close_session, session_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_delete) do
      :ok ->
        msg = Protocol.encode_session_delete(session_id)
        send_request(msg, from, state, {:delete_session, session_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:end_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_close) do
      :ok ->
        msg = Protocol.encode_session_close(session_id)
        send_request(msg, from, state, {:close_session, session_id})

      {:error, {:unsupported_capability, :session_close}} ->
        emit_session_ended(session_id)
        state = forget_update_drops(state, session_id)
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
    end
  end

  def handle_call(:disconnect, _from, state) do
    state = do_disconnect(state)
    {:reply, :ok, state}
  end

  def handle_call({:handler_worker_admit, ref, pid}, _from, state) do
    case Map.get(state.pending_agent_requests, ref) do
      request when is_map(request) and state.status == :ready ->
        if agent_request_current?(ref, request, state) do
          pending = Map.put(state.pending_agent_requests, ref, Map.put(request, :worker, pid))

          {:reply, {:ok, Map.get(request, :deadline, :infinity)},
           %{state | pending_agent_requests: pending}}
        else
          {:reply, false, state}
        end

      _cancelled ->
        {:reply, false, state}
    end
  end

  # Not ready
  def handle_call(_request, _from, %{status: status} = state) when status != :ready do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  @impl true
  def handle_cast({:cancel, session_id}, state) do
    state = cancel_pending_interactions(session_id, state)
    msg = Protocol.encode_session_cancel(session_id)
    send_to_transport(msg, state)
    {:noreply, state}
  end

  def handle_cast({:cancel_request, request_id}, state) do
    msg = Protocol.encode_cancel_request(request_id)
    send_to_transport(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:transport_message, receiver, raw_message}, state) when is_pid(receiver) do
    result = handle_info({:transport_message, raw_message}, state)
    send(receiver, {:transport_message_ack, self()})
    result
  end

  def handle_info({:transport_message, raw_message}, state)
      when is_binary(raw_message) and byte_size(raw_message) > state.max_frame_bytes do
    Logger.warning("ACP client closed an oversized inbound frame",
      size: byte_size(raw_message),
      limit: state.max_frame_bytes
    )

    state = do_disconnect(state)
    {:noreply, state}
  end

  def handle_info({:transport_message, raw_message}, state) do
    state =
      case Protocol.parse_message_with_context(raw_message) do
        {:ok, parsed, message} -> handle_parsed_message(parsed, state, message)
        error -> handle_parsed_message(error, state)
      end

    {:noreply, state}
  end

  def handle_info({:flush_update_drop_notices, token}, state) do
    case state.update_drop_timer do
      {^token, _timer} ->
        state = %{state | update_drop_timer: nil}
        {:noreply, flush_update_drop_notices(state)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:acp_handler_result, ref, result}, state) do
    state = handle_handler_result(ref, result, state)
    {:noreply, state}
  end

  def handle_info({:pending_request_timeout, request_id}, state) do
    case PendingRequests.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, telemetry_tag, monitor_ref, _timer_ref} = request, pending} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.reply(from, {:error, :request_timeout})

        state = %{
          state
          | pending_requests: pending,
            pending_caller_monitors: Map.delete(state.pending_caller_monitors, monitor_ref)
        }

        state = clear_abandoned_prompt_text(request, state)
        emit_resolve_telemetry(telemetry_tag, {:error, :request_timeout})

        if state.status == :ready do
          send_to_transport(Protocol.encode_cancel_request(request_id), state)
        end

        {:noreply, state}
    end
  end

  def handle_info({:agent_handler_timeout, ref}, state) do
    case PendingRequests.pop(state.pending_agent_requests, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        cancel_timer(request.timer_ref)
        stop_handler_worker(request)
        response = Protocol.encode_error(-32603, "Client handler timed out", nil, request.id)
        send_to_transport(response, state)
        {:noreply, %{state | pending_agent_requests: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.pending_caller_monitors, ref) do
      :error ->
        {:noreply, state}

      {:ok, request_id} ->
        monitors = Map.delete(state.pending_caller_monitors, ref)
        {pending, requests} = PendingRequests.pop(state.pending_requests, request_id)
        cancel_pending_timer(pending)
        state = %{state | pending_requests: requests, pending_caller_monitors: monitors}
        state = clear_abandoned_prompt_text(pending, state)

        if state.status == :ready do
          send_to_transport(Protocol.encode_cancel_request(request_id), state)
        end

        {:noreply, state}
    end
  end

  def handle_info({:transport_closed, _reason}, state) do
    Logger.info("ACP transport closed")
    state = reply_all_pending({:error, :transport_closed}, state)
    {:noreply, %{state | status: :disconnected}}
  end

  def handle_info({:transport_error, reason}, state) do
    Logger.warning("ACP transport error",
      reason_shape: LogSummary.describe(reason)
    )

    state = reply_all_pending({:error, {:transport_error, reason}}, state)
    {:noreply, %{state | status: :disconnected}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.receiver_pid ->
        if reason != :normal do
          Logger.warning("ACP receiver exited",
            reason_shape: LogSummary.describe(reason)
          )
        end

        state = reply_all_pending({:error, :receiver_exited}, state)
        {:noreply, %{state | status: :disconnected, receiver_pid: nil}}

      pid == state.handler_pid ->
        Logger.warning("ACP handler runner exited",
          reason_shape: LogSummary.describe(reason)
        )

        state = fail_pending_agent_requests("Handler unavailable", state)
        {:noreply, %{state | handler_pid: nil}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_parsed_message({:notification, "session/update", params}, state, message) do
    case RequestValidation.validate_session_update(params) do
      :ok ->
        if authorized_session_id?(params["sessionId"], state) do
          handle_session_update(params, state, message)
        else
          Logger.warning("ACP client ignored an update for an unknown session")
          state
        end

      {:error, :invalid_params} ->
        Logger.warning("ACP client ignored an invalid session update")
        state
    end
  end

  defp handle_parsed_message({:request, method, params, id}, state, message),
    do: validate_and_handle_agent_request(method, params, id, state, message)

  defp handle_parsed_message(parsed, state, _message), do: handle_parsed_message(parsed, state)

  defp handle_parsed_message({:result, result, id}, state),
    do: resolve_pending(id, {:ok, result}, state)

  defp handle_parsed_message({:error, error, id}, state),
    do: resolve_pending(id, {:error, error}, state)

  defp handle_parsed_message({:notification, "$/cancel_request", params}, state),
    do: handle_cancel_request_notification(params, state)

  defp handle_parsed_message(
         {:notification, "elicitation/complete", %{"elicitationId" => elicitation_id}},
         state
       )
       when is_binary(elicitation_id) and elicitation_id != "" do
    if is_map(state.client_capabilities |> Maps.get("elicitation") |> Maps.get("url")) &&
         state.handler_pid &&
         function_exported?(state.handler_mod, :handle_elicitation_complete, 2) do
      HandlerRunner.elicitation_complete(state.handler_pid, elicitation_id)
    end

    state
  end

  defp handle_parsed_message(other, state) do
    Logger.debug("ACP client received unexpected message",
      message_shape: LogSummary.describe(other)
    )

    state
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # Private helpers

  defp connect_and_initialize(opts, state) do
    transport_opts = build_transport_opts(opts)

    with {:ok, initialize_timeout} <- initialize_timeout(opts),
         {:ok, transport_state} <- state.transport_mod.connect(transport_opts) do
      state = start_initialization_receiver(state, transport_state)

      case initialize_connection(opts, state, initialize_timeout) do
        {:ok, initialized_state} ->
          {:ok, initialized_state}

        {:error, _reason} = error ->
          cleanup_failed_initialization(state)
          error
      end
    end
  end

  defp start_initialization_receiver(state, transport_state) do
    receiver_pid = start_receiver(self(), state.transport_mod, transport_state)
    %{state | transport_state: transport_state, receiver_pid: receiver_pid}
  end

  defp initialize_connection(opts, state, initialize_timeout) do
    client_info =
      Keyword.get(opts, :client_info, %{"name" => "ex_mcp", "version" => "0.1.0"})

    # Per ACP spec: "capabilities omitted in initialize MUST be treated
    # as UNSUPPORTED." Auto-advertise fs/terminal capabilities based on
    # whether the handler module exports the corresponding callbacks —
    # otherwise the agent will never call them even if the handler can
    # answer. Explicit :capabilities opt takes precedence.
    auto_capabilities = auto_advertise_capabilities(state.handler_mod)
    explicit_capabilities = Keyword.get(opts, :capabilities)
    capabilities = Capabilities.merge(auto_capabilities, explicit_capabilities)

    init_msg = Protocol.encode_initialize(client_info, capabilities, state.protocol_version)

    with {:ok, _} <- do_send(init_msg, state),
         {:ok, result} when is_map(result) <-
           receive_init_response(init_msg["id"], initialize_timeout, state.max_frame_bytes),
         protocol_version <- Map.get(result, "protocolVersion"),
         :ok <-
           RequestValidation.validate_protocol_version(
             protocol_version,
             @supported_protocol_versions
           ) do
      {:ok,
       %{
         state
         | agent_info: result["agentInfo"],
           agent_capabilities: result["agentCapabilities"],
           client_capabilities: capabilities,
           auth_methods: result["authMethods"] || [],
           protocol_version: protocol_version,
           status: :ready
       }}
    else
      {:ok, _invalid_result} -> {:error, :invalid_initialize_response}
      {:error, :invalid_protocol_version} -> {:error, :invalid_initialize_protocol_version}
      {:error, _reason} = error -> error
    end
  end

  defp initialize_timeout(opts) do
    case Keyword.get(opts, :initialize_timeout, @default_initialize_timeout) do
      timeout
      when is_integer(timeout) and timeout > 0 and timeout <= @maximum_initialize_timeout ->
        {:ok, timeout}

      _invalid ->
        {:error, :invalid_initialize_timeout}
    end
  end

  defp cleanup_failed_initialization(state) do
    do_disconnect(state)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @client_keys [
    :name,
    :handler,
    :handler_opts,
    :event_listener,
    :client_info,
    :capabilities,
    :protocol_version,
    :initialize_timeout,
    :max_pending_requests,
    :max_prompt_text_bytes,
    :pending_request_timeout,
    :handler_request_timeout,
    :notify_update_drops,
    :max_update_queue,
    :max_update_queue_bytes,
    :transport_mod,
    :_skip_connect
  ]

  defp build_transport_opts(opts) do
    # Pass all non-client keys to the transport (command, cd, env, plus any test keys)
    Keyword.drop(opts, @client_keys)
  end

  defp start_receiver(parent, transport_mod, transport_state) do
    spawn_link(fn -> receiver_loop(parent, transport_mod, transport_state) end)
  end

  defp receiver_loop(parent, transport_mod, transport_state) do
    case transport_mod.receive_message(transport_state) do
      {:ok, message, new_state} ->
        send(parent, {:transport_message, self(), message})

        receive do
          {:transport_message_ack, ^parent} ->
            receiver_loop(parent, transport_mod, new_state)
        end

      {:error, :closed} ->
        send(parent, {:transport_closed, :normal})

      {:error, reason} ->
        send(parent, {:transport_error, reason})
    end
  end

  defp receive_init_response(request_id, timeout, max_frame_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_init_response(request_id, deadline, max_frame_bytes)
  end

  defp do_receive_init_response(request_id, deadline, max_frame_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :init_timeout}
    else
      receive do
        {:transport_message, receiver, raw} when is_pid(receiver) ->
          send(receiver, {:transport_message_ack, self()})
          handle_init_frame(raw, request_id, deadline, max_frame_bytes)

        {:transport_message, raw} ->
          handle_init_frame(raw, request_id, deadline, max_frame_bytes)
      after
        remaining ->
          {:error, :init_timeout}
      end
    end
  end

  defp handle_init_frame(raw, request_id, deadline, max_frame_bytes) do
    if is_binary(raw) and byte_size(raw) > max_frame_bytes do
      {:error, :frame_too_large}
    else
      case Protocol.parse_message(raw) do
        {:result, result, ^request_id} ->
          {:ok, result}

        {:error, error, ^request_id} ->
          {:error, {:agent_error, error}}

        _other ->
          # Skip non-matching messages during init without resetting the deadline.
          do_receive_init_response(request_id, deadline, max_frame_bytes)
      end
    end
  end

  defp send_request(msg, from, state, telemetry_tag \\ nil) do
    id = msg["id"]

    cond do
      Map.has_key?(state.pending_requests, id) ->
        {:reply, {:error, :duplicate_request_id}, state}

      map_size(state.pending_requests) >= state.max_pending_requests ->
        {:reply, {:error, :too_many_pending_requests}, state}

      true ->
        case do_send(msg, state) do
          {:ok, new_state} ->
            monitor_ref = Process.monitor(elem(from, 0))

            timer_ref =
              Process.send_after(
                self(),
                {:pending_request_timeout, id},
                state.pending_request_timeout
              )

            pending =
              PendingRequests.put(
                state.pending_requests,
                id,
                {from, telemetry_tag, monitor_ref, timer_ref}
              )

            monitors = Map.put(state.pending_caller_monitors, monitor_ref, id)

            {:noreply,
             %{
               new_state
               | pending_requests: pending,
                 pending_caller_monitors: monitors
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp send_to_transport(msg, state) do
    case do_send(msg, state) do
      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Logger.warning("ACP send failed",
          reason_shape: LogSummary.describe(reason)
        )
    end
  end

  defp do_send(msg, state) do
    encoded = Jason.encode!(msg)

    if byte_size(encoded) > state.max_frame_bytes do
      {:error, :frame_too_large}
    else
      case state.transport_mod.send_message(encoded, state.transport_state) do
        {:ok, new_transport_state} ->
          {:ok, %{state | transport_state: new_transport_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_pending(id, reply, state) do
    case PendingRequests.pop(state.pending_requests, id) do
      {nil, _pending} ->
        Logger.debug("ACP received response for unknown request",
          request_id_hash: LogSummary.fingerprint(id)
        )

        state

      {{from, telemetry_tag, monitor_ref, timer_ref}, pending} ->
        cancel_timer(timer_ref)
        Process.demonitor(monitor_ref, [:flush])
        {reply, state} = maybe_merge_prompt_text(telemetry_tag, reply, state)
        state = %{state | pending_requests: pending}
        state = apply_session_resolution(telemetry_tag, reply, state)
        emit_resolve_telemetry(telemetry_tag, reply)
        GenServer.reply(from, reply)

        %{
          state
          | pending_requests: pending,
            pending_caller_monitors: Map.delete(state.pending_caller_monitors, monitor_ref)
        }

      {{from, telemetry_tag}, pending} ->
        {reply, state} = maybe_merge_prompt_text(telemetry_tag, reply, state)
        emit_resolve_telemetry(telemetry_tag, reply)
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {from, pending} ->
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}
    end
  end

  # Fold any streamed agent_message_chunk text into the prompt result and clear the
  # buffer. Agents that return text inline keep theirs; others get the streamed text.
  defp maybe_merge_prompt_text({:prompt, session_id}, {:ok, result}, state) when is_map(result) do
    {buffered, prompt_text} = Map.pop(state.prompt_text, session_id)
    meta_text = get_in(result, ["_meta", "ex_mcp", "text"])

    result =
      case buffered do
        text when is_binary(text) and text != "" ->
          case result["text"] do
            existing when is_binary(existing) and existing != "" -> result
            _ -> Map.put(result, "text", text)
          end

        _ ->
          if is_binary(meta_text) and meta_text != "" do
            Map.put_new(result, "text", meta_text)
          else
            result
          end
      end

    {{:ok, result}, %{state | prompt_text: prompt_text}}
  end

  defp maybe_merge_prompt_text({:prompt, session_id}, reply, state) do
    {_, prompt_text} = Map.pop(state.prompt_text, session_id)
    {reply, %{state | prompt_text: prompt_text}}
  end

  defp maybe_merge_prompt_text(_tag, reply, state), do: {reply, state}

  defp emit_resolve_telemetry({:new_session, _roots}, {:ok, result}) do
    session_id = result["sessionId"]

    :telemetry.execute(
      [:ex_mcp, :acp, :session, :started],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id)}
    )
  end

  defp emit_resolve_telemetry({:prompt, session_id}, {:ok, result}) do
    stop_reason = result["stopReason"]

    :telemetry.execute(
      [:ex_mcp, :acp, :prompt, :completed],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id), stop_reason: stop_reason}
    )
  end

  defp emit_resolve_telemetry({:close_session, session_id}, {:ok, _result}) do
    emit_session_ended(session_id)
  end

  defp emit_resolve_telemetry(_, _), do: :ok

  defp apply_session_resolution(
         {:new_session, roots},
         {:ok, %{"sessionId" => session_id}},
         state
       )
       when is_binary(session_id) and session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution({kind, session_id, roots}, {:ok, _result}, state)
       when kind in [:load_session, :resume_session] and is_binary(session_id) and
              session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution(
         {:fork_session, roots},
         {:ok, %{"sessionId" => session_id}},
         state
       )
       when is_binary(session_id) and session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution({kind, session_id}, {:ok, _result}, state)
       when kind in [:close_session, :delete_session] do
    %{state | sessions: Map.delete(state.sessions, session_id)}
    |> forget_update_drops(session_id)
  end

  defp apply_session_resolution({kind, session_id, _roots}, {:error, _}, state)
       when kind in [:load_session, :resume_session] do
    if authorized_session_id?(session_id, state),
      do: state,
      else: forget_update_drops(state, session_id)
  end

  defp apply_session_resolution(_tag, _reply, state), do: state

  # Build a clientCapabilities map reflecting which optional ACP callbacks
  # the handler module actually exports. Per spec, capabilities omitted in
  # initialize MUST be treated as unsupported — so a missing advertisement
  # means the agent will never invoke that capability.
  defp auto_advertise_capabilities(nil), do: nil

  defp auto_advertise_capabilities(handler_mod) when is_atom(handler_mod) do
    Code.ensure_loaded(handler_mod)

    fs =
      %{}
      |> maybe_put_cap("readTextFile", function_exported?(handler_mod, :handle_file_read, 4))
      |> maybe_put_cap("writeTextFile", function_exported?(handler_mod, :handle_file_write, 4))

    caps = %{}
    caps = if map_size(fs) > 0, do: Map.put(caps, "fs", fs), else: caps

    elicitation =
      %{}
      |> maybe_put_cap("form", function_exported?(handler_mod, :handle_form_elicitation, 2), %{})
      |> maybe_put_cap("url", function_exported?(handler_mod, :handle_url_elicitation, 2), %{})

    caps =
      if map_size(elicitation) > 0,
        do: Map.put(caps, "elicitation", elicitation),
        else: caps

    caps =
      if function_exported?(handler_mod, :handle_terminal_request, 4) do
        Map.put(caps, "terminal", true)
      else
        caps
      end

    if map_size(caps) > 0, do: caps, else: nil
  end

  defp maybe_put_cap(map, _key, false), do: map
  defp maybe_put_cap(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_cap(map, _key, false, _value), do: map
  defp maybe_put_cap(map, key, true, value), do: Map.put(map, key, value)

  # Explicit :capabilities opt fully replaces auto-detected. Auto only
  # fills in when no explicit caps are passed. This preserves the
  # contract that `capabilities: %{}` means "advertise nothing" —
  # otherwise auto-fill from handler exports would override a caller's
  # explicit suppression.
  defp emit_session_ended(session_id) do
    :telemetry.execute(
      [:ex_mcp, :acp, :session, :ended],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id)}
    )
  end

  defp session_id_hash(session_id), do: LogSummary.fingerprint({:acp_session, session_id})

  defp ensure_capability(state, capability) do
    Capabilities.ensure(state.agent_capabilities || %{}, capability)
  end

  defp prompt_blocks(text) when is_binary(text), do: {:ok, [%{"type" => "text", "text" => text}]}
  defp prompt_blocks(blocks) when is_list(blocks), do: {:ok, blocks}
  defp prompt_blocks(_content), do: {:error, {:invalid_params, :prompt_must_be_a_list}}

  defp validate_prompt_blocks(state, blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      case validate_prompt_block(state.agent_capabilities || %{}, block) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_prompt_block(_caps, %{"type" => type}) when type in ["text", "resource_link"],
    do: :ok

  defp validate_prompt_block(caps, %{"type" => "image"}) do
    validate_prompt_capability(caps, "image", :image)
  end

  defp validate_prompt_block(caps, %{"type" => "audio"}) do
    validate_prompt_capability(caps, "audio", :audio)
  end

  defp validate_prompt_block(caps, %{"type" => "resource"}) do
    validate_prompt_capability(caps, "embeddedContext", :embedded_context)
  end

  defp validate_prompt_block(_caps, %{"type" => type}) do
    {:error, {:unsupported_prompt_content, type}}
  end

  defp validate_prompt_block(_caps, _block), do: {:error, {:invalid_params, :prompt_block}}

  defp validate_prompt_capability(caps, key, capability) do
    if caps |> Maps.get("promptCapabilities") |> Maps.get(key) |> Maps.truthy?() do
      :ok
    else
      {:error, {:unsupported_capability, {:prompt, capability}}}
    end
  end

  defp reply_all_pending(error, state) do
    if state.update_drop_timer, do: cancel_timer(elem(state.update_drop_timer, 1))

    for pending <- PendingRequests.values(state.pending_requests) do
      case pending do
        {from, _tag, monitor_ref, timer_ref} ->
          cancel_timer(timer_ref)
          Process.demonitor(monitor_ref, [:flush])
          GenServer.reply(from, error)

        {from, _tag, monitor_ref} ->
          Process.demonitor(monitor_ref, [:flush])
          GenServer.reply(from, error)

        {from, _tag} ->
          GenServer.reply(from, error)

        from ->
          GenServer.reply(from, error)
      end
    end

    Enum.each(state.pending_agent_requests, fn {_ref, request} ->
      cancel_timer(Map.get(request, :timer_ref))
      stop_handler_worker(request)
    end)

    %{
      state
      | pending_requests: PendingRequests.empty(),
        pending_caller_monitors: %{},
        pending_agent_requests: %{},
        update_drops: %{},
        update_drop_timer: nil,
        prompt_text: %{},
        sessions: %{}
    }
  end

  defp handle_session_update(params, state, message) do
    session_id = params["sessionId"]
    update = params["update"]
    update_bytes = :erlang.external_size(update)
    state = state |> accumulate_prompt_text(session_id, update) |> flush_update_drop_notices()

    state =
      if is_pid(state.event_listener) do
        case UpdateQueue.check(
               state.event_listener,
               state.max_update_queue,
               state.max_update_queue_bytes,
               update_bytes,
               :listener
             ) do
          :ok ->
            send(state.event_listener, {:acp_session_update, session_id, update})
            state

          {:error, reason} ->
            note_update_drop(state, session_id, :event_listener, update_bytes, reason)
        end
      else
        state
      end

    handler_message = handler_message(state, :handle_session_update, 4, message)
    bytes = :erlang.external_size(handler_message || update)

    case HandlerRunner.session_update_status(
           state.handler_pid,
           session_id,
           update,
           state.max_update_queue,
           state.max_update_queue_bytes,
           handler_message
         ) do
      :ok -> state
      {:dropped, reason} -> note_update_drop(state, session_id, :handler, bytes, reason)
    end
  end

  defp note_update_drop(state, session_id, target, bytes, reason) do
    :telemetry.execute([:ex_mcp, :acp, :session, :update_dropped], %{count: 1, bytes: bytes}, %{
      session_id: session_id,
      target: target,
      limit: reason,
      max_queue: state.max_update_queue,
      max_bytes: state.max_update_queue_bytes
    })

    {pid, kind, enabled?} = drop_destination(state, target)
    key = {target, session_id}
    count = Map.get(state.update_drops, key, 0) + 1
    notice_bytes = drop_notice_size(kind, session_id, count)

    if enabled? and is_pid(pid) and reason != :unavailable and
         notice_bytes <= state.max_update_queue_bytes do
      %{state | update_drops: Map.put(state.update_drops, key, count)} |> schedule_drop_notices()
    else
      state
    end
  end

  defp drop_destination(state, :event_listener),
    do: {state.event_listener, :listener, state.notify_update_drops}

  defp drop_destination(state, :handler),
    do:
      {state.handler_pid, :handler,
       function_exported?(state.handler_mod, :handle_session_updates_dropped, 3)}

  defp drop_notice_size(:listener, session_id, count),
    do: :erlang.external_size({:acp_session_updates_dropped, session_id, count})

  defp drop_notice_size(:handler, session_id, count),
    do: :erlang.external_size({:"$gen_cast", {:session_updates_dropped, session_id, count}})

  defp flush_update_drop_notices(%{status: status} = state) when status != :ready,
    do: %{state | update_drops: %{}}

  defp flush_update_drop_notices(state) do
    pending =
      Enum.reduce(state.update_drops, %{}, fn {{target, session_id} = key, count}, pending ->
        {pid, kind, enabled?} = drop_destination(state, target)
        bytes = drop_notice_size(kind, session_id, count)

        if enabled? and authorized_session_id?(session_id, state) and
             bytes <= state.max_update_queue_bytes do
          case UpdateQueue.check(
                 pid,
                 state.max_update_queue,
                 state.max_update_queue_bytes,
                 bytes,
                 kind
               ) do
            :ok ->
              if target == :event_listener,
                do: send(pid, {:acp_session_updates_dropped, session_id, count}),
                else: HandlerRunner.session_updates_dropped(pid, session_id, count)

              pending

            {:error, :unavailable} ->
              pending

            {:error, _full} ->
              Map.put(pending, key, count)
          end
        else
          pending
        end
      end)

    %{state | update_drops: pending} |> schedule_drop_notices()
  end

  defp forget_update_drops(state, session_id) do
    pending = Map.reject(state.update_drops, fn {{_target, id}, _count} -> id == session_id end)

    timer =
      if map_size(pending) == 0 do
        if state.update_drop_timer, do: cancel_timer(elem(state.update_drop_timer, 1))
        nil
      else
        state.update_drop_timer
      end

    %{state | update_drops: pending, update_drop_timer: timer}
  end

  defp schedule_drop_notices(%{update_drop_timer: nil, update_drops: pending} = state)
       when map_size(pending) > 0 do
    token = make_ref()
    timer = Process.send_after(self(), {:flush_update_drop_notices, token}, 100)
    %{state | update_drop_timer: {token, timer}}
  end

  defp schedule_drop_notices(state), do: state

  # Append agent_message_chunk text to the per-session buffer. Only the assistant's
  # message text is buffered — thought chunks and other update types are ignored.
  defp accumulate_prompt_text(
         state,
         session_id,
         %{"sessionUpdate" => "agent_message_chunk"} = update
       )
       when is_binary(session_id) do
    if prompt_pending?(state, session_id) do
      case get_in(update, ["content", "text"]) do
        text when is_binary(text) and text != "" ->
          buffered = Map.get(state.prompt_text, session_id, "")
          remaining = max(state.max_prompt_text_bytes - byte_size(buffered), 0)
          text = valid_utf8_prefix(text, remaining)

          if text == "" do
            state
          else
            %{state | prompt_text: Map.put(state.prompt_text, session_id, buffered <> text)}
          end

        _ ->
          state
      end
    else
      state
    end
  end

  defp accumulate_prompt_text(state, _session_id, _update), do: state

  defp prompt_pending?(state, session_id) do
    Enum.any?(state.pending_requests, fn
      {_id, {_from, {:prompt, ^session_id}, _monitor_ref}} -> true
      {_id, {_from, {:prompt, ^session_id}, _monitor_ref, _timer_ref}} -> true
      {_id, {_from, {:prompt, ^session_id}}} -> true
      _ -> false
    end)
  end

  defp clear_abandoned_prompt_text({_from, {:prompt, session_id}, _monitor_ref}, state),
    do: %{state | prompt_text: Map.delete(state.prompt_text, session_id)}

  defp clear_abandoned_prompt_text(
         {_from, {:prompt, session_id}, _monitor_ref, _timer_ref},
         state
       ),
       do: %{state | prompt_text: Map.delete(state.prompt_text, session_id)}

  defp clear_abandoned_prompt_text(
         {_from, {kind, session_id, _roots}, _monitor, _timer},
         state
       )
       when kind in [:load_session, :resume_session] do
    if authorized_session_id?(session_id, state),
      do: state,
      else: forget_update_drops(state, session_id)
  end

  defp clear_abandoned_prompt_text(_pending, state), do: state

  defp validate_and_handle_agent_request(method, params, id, state, message) do
    with :ok <- ensure_agent_request_id_available(id, state),
         :ok <- ensure_advertised_client_capability(method, params, state),
         :ok <- RequestValidation.validate_agent_request(method, params),
         :ok <- ensure_agent_session_authority(method, params, state),
         :ok <- ensure_agent_request_capacity(state) do
      handle_agent_request(method, params, id, state, message)
    else
      {:error, :duplicate_request_id} ->
        send_agent_request_error(state, id, -32_600, "Request id is already in use")

      {:error, :unsupported_client_capability} ->
        send_agent_request_error(state, id, -32_601, "Method not supported")

      {:error, :method_not_found} ->
        send_agent_request_error(state, id, -32_601, "Method not found")

      {:error, :invalid_params} ->
        send_agent_request_error(state, id, -32_602, "Invalid request parameters")

      {:error, :unknown_session} ->
        send_agent_request_error(state, id, -32_602, "Unknown session")

      {:error, :path_not_authorized} ->
        send_agent_request_error(state, id, -32_602, "Path is outside the session workspace")

      {:error, :too_many_pending_requests} ->
        send_agent_request_error(state, id, -32_000, "Too many pending requests")
    end
  end

  defp ensure_agent_request_id_available(id, state) do
    if Enum.any?(state.pending_agent_requests, fn {_ref, request} -> request.id == id end) do
      {:error, :duplicate_request_id}
    else
      :ok
    end
  end

  defp ensure_advertised_client_capability("fs/read_text_file", _params, state) do
    if state.client_capabilities |> Maps.get("fs") |> Maps.get("readTextFile") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("fs/write_text_file", _params, state) do
    if state.client_capabilities |> Maps.get("fs") |> Maps.get("writeTextFile") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("terminal/" <> _method, _params, state) do
    if Maps.get(state.client_capabilities, "terminal") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("elicitation/create", %{"mode" => mode}, state) do
    if is_map(state.client_capabilities |> Maps.get("elicitation") |> Maps.get(mode)),
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability(_method, _params, _state), do: :ok

  defp ensure_agent_session_authority("session/request_permission", params, state) do
    ensure_known_session(params["sessionId"], state)
  end

  defp ensure_agent_session_authority("elicitation/create", %{"sessionId" => session_id}, state) do
    ensure_known_session(session_id, state)
  end

  defp ensure_agent_session_authority("elicitation/create", %{"requestId" => request_id}, state) do
    if Map.has_key?(state.pending_requests, request_id),
      do: :ok,
      else: {:error, :unknown_session}
  end

  defp ensure_agent_session_authority(method, params, state)
       when method in ["fs/read_text_file", "fs/write_text_file"] do
    with {:ok, roots} <- session_roots_for(params["sessionId"], state),
         true <- path_within_roots?(params["path"], roots) do
      :ok
    else
      {:error, :unknown_session} -> {:error, :unknown_session}
      false -> {:error, :path_not_authorized}
    end
  end

  defp ensure_agent_session_authority("terminal/create", params, state) do
    with {:ok, roots} <- session_roots_for(params["sessionId"], state) do
      case params["cwd"] do
        nil -> :ok
        cwd -> if path_within_roots?(cwd, roots), do: :ok, else: {:error, :path_not_authorized}
      end
    end
  end

  defp ensure_agent_session_authority("terminal/" <> _method, params, state) do
    ensure_known_session(params["sessionId"], state)
  end

  defp ensure_agent_session_authority(_method, _params, _state), do: :ok

  defp authorized_session_id?(session_id, state)
       when is_binary(session_id) and session_id != "" do
    Map.has_key?(state.sessions, session_id) or pending_session_open?(session_id, state)
  end

  defp authorized_session_id?(_session_id, _state), do: false

  defp ensure_known_session(session_id, state) do
    if authorized_session_id?(session_id, state), do: :ok, else: {:error, :unknown_session}
  end

  defp session_roots_for(session_id, state) do
    case Map.get(state.sessions, session_id) do
      %{roots: roots} when is_list(roots) -> {:ok, roots}
      _missing -> pending_session_roots(session_id, state)
    end
  end

  defp pending_session_open?(session_id, state) do
    match?({:ok, _roots}, pending_session_roots(session_id, state))
  end

  defp pending_session_roots(session_id, state) do
    Enum.any?(state.pending_requests, fn
      {_id, {_from, {kind, ^session_id, _roots}, _monitor_ref, _timer_ref}}
      when kind in [:load_session, :resume_session] ->
        true

      _pending ->
        false
    end)
    |> case do
      false ->
        {:error, :unknown_session}

      true ->
        {_id, {_from, {_kind, ^session_id, roots}, _monitor_ref, _timer_ref}} =
          Enum.find(state.pending_requests, fn
            {_id, {_from, {kind, candidate, _roots}, _monitor_ref, _timer_ref}} ->
              kind in [:load_session, :resume_session] and candidate == session_id

            _pending ->
              false
          end)

        {:ok, roots}
    end
  end

  defp ensure_agent_request_capacity(state) do
    if map_size(state.pending_agent_requests) < state.max_pending_requests,
      do: :ok,
      else: {:error, :too_many_pending_requests}
  end

  defp send_agent_request_error(state, id, code, message) do
    response = Protocol.encode_error(code, message, nil, id)
    send_to_transport(response, state)
    state
  end

  defp handle_agent_request("session/request_permission", params, id, state, message) do
    session_id = params["sessionId"]
    tool_call = params["toolCall"]
    options = params["options"] || []

    if state.handler_pid do
      ref = HandlerRunner.new_request_ref()

      HandlerRunner.permission_request(
        state.handler_pid,
        ref,
        session_id,
        tool_call,
        options,
        handler_message(state, :handle_permission_request, 5, message)
      )

      track_agent_request(state, ref, :permission, id, session_id)
    else
      response = Protocol.encode_error(-32603, "Handler unavailable", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request(method, params, id, state, _message),
    do: handle_agent_request(method, params, id, state)

  defp handler_message(state, callback, arity, message) do
    if function_exported?(state.handler_mod, callback, arity), do: message
  end

  defp handle_agent_request("elicitation/create", params, id, state) do
    mode = params["mode"]
    callback = if mode == "form", do: :handle_form_elicitation, else: :handle_url_elicitation

    if state.handler_pid && function_exported?(state.handler_mod, callback, 2) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.elicitation_request(state.handler_pid, ref, mode, params)
      track_agent_request(state, ref, :elicitation, id, params["sessionId"], %{mode: mode})
    else
      response = Protocol.encode_error(-32_601, "Elicitation mode not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request("fs/read_text_file", params, id, state) do
    session_id = params["sessionId"]
    path = params["path"]
    opts = Map.drop(params, ["sessionId", "path"])

    if state.handler_pid && function_exported?(state.handler_mod, :handle_file_read, 4) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.file_read(state.handler_pid, ref, session_id, path, opts)
      track_agent_request(state, ref, :file_read, id, session_id)
    else
      response = Protocol.encode_error(-32601, "File read not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request("fs/write_text_file", params, id, state) do
    session_id = params["sessionId"]
    path = params["path"]
    content = params["content"]

    if state.handler_pid && function_exported?(state.handler_mod, :handle_file_write, 4) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.file_write(state.handler_pid, ref, session_id, path, content)
      track_agent_request(state, ref, :file_write, id, session_id)
    else
      response = Protocol.encode_error(-32601, "File write not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  # Terminal operations — spec-defined but delegated to handler
  defp handle_agent_request("terminal/" <> _ = method, params, id, state) do
    if state.handler_pid && function_exported?(state.handler_mod, :handle_terminal_request, 4) do
      params = terminal_params_with_workspace_default(method, params, state)
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.terminal_request(state.handler_pid, ref, method, params, id)
      track_agent_request(state, ref, :terminal, id, params["sessionId"], %{method: method})
    else
      response = Protocol.encode_error(-32601, "Terminal operations not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request(method, _params, id, state) do
    Logger.debug("ACP client received unknown agent request",
      method_hash: LogSummary.fingerprint(method)
    )

    response = Protocol.encode_error(-32601, "Method not found: #{method}", nil, id)
    send_to_transport(response, state)
    state
  end

  defp terminal_params_with_workspace_default("terminal/create", params, state) do
    if is_nil(params["cwd"]) do
      case session_roots_for(params["sessionId"], state) do
        {:ok, [cwd | _roots]} -> Map.put(params, "cwd", cwd)
        _missing -> params
      end
    else
      params
    end
  end

  defp terminal_params_with_workspace_default(_method, params, _state), do: params

  defp handle_handler_result(ref, result, state) do
    case PendingRequests.pop(state.pending_agent_requests, ref) do
      {nil, _pending} ->
        state

      {request, pending} ->
        cancel_timer(request.timer_ref)
        stop_handler_worker(request)
        state = %{state | pending_agent_requests: pending}
        response = encode_handler_response(request, result)
        send_to_transport(response, state)
        state
    end
  end

  defp encode_handler_response(%{kind: :permission, id: id}, {:permission, {:ok, outcome}}) do
    Protocol.encode_permission_response(id, outcome)
  end

  defp encode_handler_response(%{kind: :elicitation, id: id}, {:elicitation, {:ok, response}}) do
    response = Maps.stringify_keys(response)

    case RequestValidation.validate_elicitation_response(response) do
      :ok ->
        Protocol.encode_elicitation_response(id, response)

      {:error, :invalid_params} ->
        Protocol.encode_error(-32_603, "Invalid elicitation response", nil, id)
    end
  end

  defp encode_handler_response(%{kind: :file_read, id: id}, {:file_read, {:ok, content}}) do
    Protocol.encode_file_read_response(id, content)
  end

  defp encode_handler_response(%{kind: :file_write, id: id}, {:file_write, :ok}) do
    Protocol.encode_file_write_response(id)
  end

  defp encode_handler_response(
         %{kind: :terminal, id: id, method: "terminal/output"},
         {:terminal, {:ok, result}}
       )
       when is_map(result) do
    Protocol.encode_response(Map.put_new(result, "truncated", false), id)
  end

  defp encode_handler_response(%{kind: :terminal, id: id}, {:terminal, {:ok, result}}) do
    Protocol.encode_response(result, id)
  end

  defp encode_handler_response(%{id: id}, {_kind, {:error, reason}}) do
    Logger.warning("ACP client handler failed", reason: safe_error_class(reason))
    Protocol.encode_error(-32603, "Client handler failed", nil, id)
  end

  defp encode_handler_response(%{id: id}, _unexpected) do
    Protocol.encode_error(-32603, "Client handler returned an invalid result", nil, id)
  end

  defp agent_request_current?(ref, request, state) do
    cond do
      state.status != :ready or not is_map(request) ->
        false

      Map.get(request, :deadline, :infinity) == :infinity ->
        true

      request.deadline > System.monotonic_time(:millisecond) ->
        true

      true ->
        if gate = Map.get(request, :handler_gate), do: :atomics.put(gate, 1, 0)
        send(self(), {:agent_handler_timeout, ref})
        false
    end
  end

  defp track_agent_request(state, ref, kind, id, session_id, extra \\ %{}) do
    deadline = System.monotonic_time(:millisecond) + state.handler_request_timeout

    timer_ref =
      Process.send_after(self(), {:agent_handler_timeout, ref}, state.handler_request_timeout)

    request =
      Map.merge(
        %{
          kind: kind,
          id: id,
          session_id: session_id,
          timer_ref: timer_ref,
          deadline: deadline,
          handler_gate: HandlerRunner.request_gate(ref)
        },
        extra
      )

    %{
      state
      | pending_agent_requests: PendingRequests.put(state.pending_agent_requests, ref, request)
    }
  end

  defp fail_pending_agent_requests(reason, state) do
    Enum.each(state.pending_agent_requests, fn {_ref, request} ->
      cancel_timer(request.timer_ref)
      stop_handler_worker(request)
      response = Protocol.encode_error(-32603, reason, nil, request.id)
      send_to_transport(response, state)
    end)

    %{state | pending_agent_requests: %{}}
  end

  defp cancel_pending_interactions(session_id, state) do
    {to_cancel, keep} =
      Enum.split_with(state.pending_agent_requests, fn {_ref, request} ->
        request.kind in [:permission, :elicitation] and request.session_id == session_id
      end)

    Enum.each(to_cancel, fn {_ref, request} ->
      cancel_timer(request.timer_ref)
      stop_handler_worker(request)

      response =
        case request.kind do
          :permission ->
            Protocol.encode_permission_response(request.id, %{"outcome" => "cancelled"})

          :elicitation ->
            Protocol.encode_elicitation_response(request.id, %{"action" => "cancel"})
        end

      send_to_transport(response, state)
    end)

    %{state | pending_agent_requests: Map.new(keep)}
  end

  defp handle_cancel_request_notification(%{"requestId" => request_id}, state) do
    {to_cancel, keep} =
      Enum.split_with(state.pending_agent_requests, fn {_ref, request} ->
        request.id == request_id
      end)

    Enum.each(to_cancel, fn {_ref, request} ->
      cancel_timer(request.timer_ref)
      stop_handler_worker(request)
      response = Protocol.encode_request_cancelled_error(request.id)
      send_to_transport(response, state)
    end)

    %{state | pending_agent_requests: Map.new(keep)}
  end

  defp handle_cancel_request_notification(_params, state), do: state

  defp stop_handler_worker(request) do
    if gate = Map.get(request, :handler_gate), do: :atomics.put(gate, 1, 0)
    if is_pid(Map.get(request, :worker)), do: Process.exit(request.worker, :kill)
    :ok
  end

  defp safe_error_class({kind, reason, _stack}) when kind in [:error, :exit, :throw],
    do: "#{kind}:#{inspect(error_module(reason))}"

  defp safe_error_class(reason), do: inspect(error_module(reason))

  defp error_module(%{__struct__: module}) when is_atom(module), do: module
  defp error_module(_reason), do: :error

  defp cancel_pending_timer({_from, _tag, _monitor_ref, timer_ref}), do: cancel_timer(timer_ref)
  defp cancel_pending_timer(_pending), do: :ok

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref, async: true, info: false)

  defp valid_utf8_prefix(_text, 0), do: ""

  defp valid_utf8_prefix(text, limit) when byte_size(text) <= limit, do: text

  defp valid_utf8_prefix(text, limit) do
    prefix = binary_part(text, 0, limit)
    trim_invalid_utf8_suffix(prefix)
  end

  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      trim_invalid_utf8_suffix(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp session_roots(cwd, lifecycle_opts) do
    [cwd | LifecycleParams.additional_directories(lifecycle_opts) || []]
    |> Enum.map(&WorkspacePath.canonical/1)
    |> Enum.uniq()
  end

  defp path_within_roots?(path, roots) when is_binary(path) and is_list(roots) do
    Enum.any?(roots, &WorkspacePath.within?(path, &1))
  end

  defp path_within_roots?(_path, _roots), do: false

  defp do_disconnect(state) do
    if state.receiver_pid && Process.alive?(state.receiver_pid) do
      Process.exit(state.receiver_pid, :shutdown)
    end

    if state.transport_state do
      state.transport_mod.close(state.transport_state)
    end

    reply_all_pending({:error, :disconnected}, state)
    |> Map.merge(%{status: :disconnected, receiver_pid: nil, transport_state: nil})
  end
end
