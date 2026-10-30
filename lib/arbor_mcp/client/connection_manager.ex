defmodule Arbor.MCP.Client.ConnectionManager do
  @moduledoc """
  Connection lifecycle management for ArborMCP client.

  This module handles all aspects of connection establishment, transport management,
  health checks, and message receiving for MCP clients.
  """

  require Logger
  # alias Arbor.MCP.TransportManager  # Not using full manager for now
  alias Arbor.MCP.Client.{ConnectionScope, Deadline, EraCache, EraProbe, Lifetime}
  alias Arbor.MCP.Internal.{Protocol, VersionInfo, VersionRegistry}
  alias Arbor.MCP.Reliability.Retry
  alias Arbor.MCP.Testing.MockTransport
  alias Arbor.MCP.Transport

  alias Arbor.MCP.Transport.{HTTP, Local, ReliabilityWrapper, Stdio, Test}
  alias Arbor.MCP.Transport.HTTP.LegacySSE
  alias Arbor.RPC.LogSummary

  @default_handshake_timeout 10_000

  @doc """
  Establishes connection using the provided options and updates client state.

  Takes the current client state and connection options, establishes the connection,
  and returns the updated state with connection information.

  Supports retry policies for connection establishment through the :retry_policy option.

  The whole call, retries included, is bounded by `:establish_timeout`
  (milliseconds or `:infinity`; default `:handshake_timeout` plus
  `:era_probe_timeout`). Each exchange inside it is additionally bounded by
  its own timeout: the `server/discover` probe by `:era_probe_timeout` and the
  `initialize` exchange by `:handshake_timeout`, including a synchronous HTTP
  POST. When the overall deadline is what ran out, the result is
  `{:error, :establish_timeout}`.
  """
  def establish_connection(state, opts) do
    with {:ok, timeout} <- establish_timeout(opts) do
      opts =
        Keyword.put(
          opts,
          :establish_deadline,
          Deadline.earliest(ConnectionScope.establish_deadline(opts), Deadline.after_ms(timeout))
        )

      retry_policy = Keyword.get(opts, :retry_policy, [])

      if retry_policy != [] do
        establish_connection_with_retry(state, opts, retry_policy)
      else
        do_establish_connection(state, opts)
      end
    end
  end

  defp establish_timeout(opts) do
    case Keyword.get(opts, :establish_timeout) do
      nil ->
        {:ok, handshake_timeout(opts) + probe_timeout(opts, spawns_server?(opts))}

      :infinity ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      invalid ->
        {:error, {:invalid_establish_timeout, invalid}}
    end
  end

  @doc """
  Establishes connection with retry logic applied.
  """
  def establish_connection_with_retry(state, opts, retry_policy) do
    connection_operation = fn ->
      do_establish_connection(state, opts)
    end

    retry_opts =
      retry_policy
      |> Retry.mcp_defaults()
      |> never_retry_unconfirmed_cleanup(spawns_server?(opts))

    Retry.with_retry(connection_operation, retry_opts)
  end

  # Each attempt starts a new transport, for stdio a new server process. That
  # never happens while one an earlier attempt opened may still be running,
  # whatever the policy's own :should_retry? says: it could hold the port or
  # lock the new one needs.
  defp never_retry_unconfirmed_cleanup(retry_opts, false = _spawns_server?), do: retry_opts

  defp never_retry_unconfirmed_cleanup(retry_opts, true = _spawns_server?) do
    should_retry? = Keyword.fetch!(retry_opts, :should_retry?)

    Keyword.put(retry_opts, :should_retry?, fn reason ->
      not cleanup_unconfirmed?(reason) and should_retry?.(reason)
    end)
  end

  @doc false
  # Whether a failed establishment left something it opened, a server
  # process above all, not confirmed stopped.
  def cleanup_unconfirmed?({:probed_server_stop_unconfirmed, _details}), do: true
  def cleanup_unconfirmed?({:cleanup_failed, _reason, {:error, _cleanup}}), do: true
  def cleanup_unconfirmed?(_reason), do: false

  @doc false
  # The part of a spawned server's close result that says whether the server
  # itself stopped. A reliability component that would not stop is the
  # wrapper's failure, not the server's.
  def server_stop_result(:ok), do: :ok
  def server_stop_result({:error, {:reliability_cleanup, _reason}}), do: :ok
  def server_stop_result({:error, _reason} = error), do: error
  def server_stop_result(other), do: {:error, other}

  defp do_establish_connection(state, opts) do
    opts = maybe_default_legacy_sse_opts(opts)
    deadline = Keyword.get(opts, :establish_deadline)

    with :ok <- check_deadline(deadline),
         {:ok, transport_manager_opts} <- prepare_transport_config(opts),
         :ok <- Lifetime.opening(),
         :ok <- ConnectionScope.opening(),
         {:ok, {transport_mod, transport_state}} <- connect_transport(transport_manager_opts),
         :ok <- ConnectionScope.transport(transport_mod, transport_state),
         transport_state = Deadline.put_on_transport(transport_mod, transport_state, deadline),
         era_identity = EraCache.identity(transport_mod, transport_state, opts),
         :ok <- maybe_reset_era_cache(era_identity, opts),
         {:ok, result, state_after_protocol} <-
           transport_mod
           |> establish_protocol(transport_state, opts, era_identity)
           |> respawn_for_legacy(transport_mod, transport_manager_opts, opts)
           |> close_on_failure(transport_mod),
         state_after_protocol =
           Deadline.put_on_transport(transport_mod, state_after_protocol, nil),
         state_after_protocol = settle_transport_era(transport_mod, state_after_protocol, result),
         :ok <- ConnectionScope.transport(transport_mod, state_after_protocol),
         {:ok, receiver_result} <-
           start_receiver_task(self(), transport_mod, state_after_protocol) do
      # Push mode returns {:push, updated_transport_state} — extract it
      {receiver_task, final_transport_state} =
        case receiver_result do
          {:push, new_ts} -> {:push, new_ts}
          task -> {task, state_after_protocol}
        end

      new_state =
        state
        |> Map.put(:transport_mod, transport_mod)
        |> Map.put(:transport_state, final_transport_state)
        |> Map.put(:receiver_task, receiver_task)
        |> Map.put(:server_capabilities, result["capabilities"])
        |> Map.put(:protocol_version, result["protocolVersion"])
        |> Map.put(:server_info, result["serverInfo"])
        |> Map.put(:server_instructions, result["instructions"])
        |> forget_unkept_session(transport_mod, transport_state, final_transport_state)

      ConnectionScope.established()
      {:ok, new_state}
    else
      # Unconfirmed cleanup outranks the deadline: callers (a retry, a
      # reconnect) must see it to keep from starting another server.
      {:error, reason} ->
        if Deadline.expired?(deadline) and not cleanup_unconfirmed?(reason),
          do: {:error, :establish_timeout},
          else: {:error, reason}

      error ->
        {:error, "Unexpected error during connection: #{inspect(error)}"}
    end
  end

  defp check_deadline(deadline) do
    if Deadline.expired?(deadline), do: {:error, :establish_timeout}, else: :ok
  end

  # A configured `:session_id` the new legacy connection didn't keep, because
  # the server had ended it (see do_handshake/3), isn't offered again when the
  # client reconnects.
  defp forget_unkept_session(
         %{transport_opts: transport_opts} = state,
         HTTP,
         %HTTP{session_id: configured},
         %HTTP{protocol_era: :legacy, session_id: kept}
       )
       when is_binary(configured) and configured != kept and is_list(transport_opts),
       do: %{state | transport_opts: forget_session_id(transport_opts)}

  defp forget_unkept_session(state, _transport_mod, _opened, _established), do: state

  # A connection attempt that fails after the transport was opened must not
  # leave it behind: a spawned stdio server, or a port and reader linked to
  # the client, would otherwise outlive the attempt (and pile up across
  # connection retries and reconnects). The protocol steps fail with the
  # latest transport state they reached, because a step that succeeded
  # before the failure may have added to it (an HTTP session id, a deferred
  # SSE client) and closing an earlier snapshot would leave that behind.
  defp close_on_failure({:ok, _result, _state} = success, _transport_mod), do: success

  # A failure with no open transport left to close.
  defp close_on_failure({:error, _reason} = failure, _transport_mod), do: failure

  # A spawned server that cannot be confirmed stopped is reported with the
  # failure, as {:cleanup_failed, reason, cleanup}, so no retry starts
  # another beside it.
  defp close_on_failure({:error, reason, latest_state}, transport_mod) do
    ConnectionScope.transport(transport_mod, latest_state)

    cleanup = close_quietly(transport_mod, with_cleanup_deadline(transport_mod, latest_state))

    with true <- spawned_server?(transport_mod, latest_state),
         {:error, _server} = unconfirmed <- server_stop_result(cleanup) do
      {:error, {:cleanup_failed, reason, unconfirmed}}
    else
      _confirmed_or_not_spawned -> {:error, reason}
    end
  end

  # Cleanup gets its own budget, whatever is left of the establishment
  # deadline: it must still happen when the deadline is what failed.
  defp with_cleanup_deadline(transport_mod, transport_state),
    do: Deadline.for_cleanup(transport_mod, transport_state)

  # A legacy handshake that failed can still have left something on the
  # server or in the client before falling back to the modern probe: an HTTP
  # server may hand out a session with an initialize error, and a session
  # starts the deferred SSE client. Only that is ended; the connection itself
  # (a stdio server, say) is what the probe goes on to use.
  defp abandon_legacy_attempt(HTTP, %HTTP{} = snapshot, %HTTP{} = attempt) do
    result = HTTP.abandon_attempt(with_cleanup_deadline(HTTP, attempt), snapshot)
    ConnectionScope.closed(HTTP, attempt, result)

    # Restore the connection snapshot after ending the failed session, but
    # never roll back credentials acquired or rejected during that attempt,
    # nor bring back a configured session the server has ended.
    snapshot
    |> Map.merge(
      Map.take(attempt, [
        :access_token,
        :credential_generation,
        :rejected_generation,
        :auth_completed,
        :auth_provider_state,
        :granted_scopes,
        :headers,
        :configured_session_ended
      ])
    )
    |> without_ended_session()
  end

  defp abandon_legacy_attempt(ReliabilityWrapper, snapshot, attempt) do
    case {ReliabilityWrapper.unwrap(snapshot), ReliabilityWrapper.unwrap(attempt)} do
      {{HTTP, http_snapshot}, {HTTP, http_attempt}} ->
        %{attempt | wrapped_state: abandon_legacy_attempt(HTTP, http_snapshot, http_attempt)}

      _other ->
        attempt
    end
  end

  defp abandon_legacy_attempt(_transport_mod, _snapshot, attempt), do: attempt

  defp close_quietly(transport_mod, transport_state) do
    result = transport_mod.close(transport_state)
    ConnectionScope.closed(transport_mod, transport_state, result)
    result
  rescue
    exception ->
      result = {:error, {:cleanup_exception, exception.__struct__}}
      ConnectionScope.closed(transport_mod, transport_state, result)
      result
  catch
    :exit, reason ->
      result = {:error, {:cleanup_exit, reason}}
      ConnectionScope.closed(transport_mod, transport_state, result)
      result
  end

  defp establish_protocol(transport_mod, transport_state, opts, era_identity) do
    mode = Keyword.get(opts, :protocol_mode) || VersionRegistry.protocol_mode()

    case mode do
      :legacy_only ->
        establish_legacy_protocol(transport_mod, transport_state, opts, era_identity)

      :modern_only ->
        establish_modern_protocol(transport_mod, transport_state, opts, era_identity, false)

      :prefer_modern ->
        establish_prefer_modern(transport_mod, transport_state, opts, era_identity)

      :prefer_legacy ->
        establish_prefer_legacy(transport_mod, transport_state, opts, era_identity)

      invalid ->
        {:error, {:invalid_protocol_mode, invalid}, transport_state}
    end
  end

  # The establish_* steps below succeed with {:ok, result, transport_state}
  # and fail with {:error, reason, latest_transport_state}.
  defp establish_legacy_protocol(transport_mod, transport_state, opts, era_identity) do
    # The transport adopts the server's selected version before anything else
    # is sent, so notifications/initialized already carries it: a strict
    # server rejects a protocol-version header that disagrees with the one it
    # negotiated. Only the version: the handshake stays in the legacy era (and
    # keeps the session initialize minted) until establishment settles it.
    with {:ok, result, state_after_handshake} <-
           do_handshake(transport_mod, transport_state, opts) do
      settled_state = adopt_negotiated_version(transport_mod, state_after_handshake, result)

      case send_initialized(transport_mod, settled_state, result) do
        {:ok, state_after_initialized} ->
          emit_settled_era(:legacy, result["protocolVersion"])
          observe_era(era_identity, :legacy, result["protocolVersion"], opts)
          {:ok, result, state_after_initialized}

        {:error, reason} ->
          {:error, reason, settled_state}

        {:error, reason, latest_state} ->
          {:error, reason, latest_state}
      end
    end
  end

  defp establish_modern_protocol(transport_mod, transport_state, opts, era_identity, pinned?) do
    case probe_era(transport_mod, transport_state, opts) do
      {:ok, discovery, updated_state} ->
        emit_settled_era(:modern, discovery.protocol_version)
        observe_era(era_identity, :modern, discovery.protocol_version, opts)
        {:ok, discovery_as_connection_result(discovery), updated_state}

      {:error, reason, updated_state} ->
        if pinned? do
          {:error,
           {:pinned_modern_era_probe_failed,
            %{probe: reason, action: :clear_era_observation_or_change_configuration}},
           updated_state}
        else
          {:error, {:era_probe_failed, reason}, updated_state}
        end
    end
  end

  defp establish_prefer_modern(transport_mod, transport_state, opts, era_identity) do
    case cached_era(era_identity) do
      :modern ->
        establish_modern_protocol(transport_mod, transport_state, opts, era_identity, true)

      {:legacy, version} ->
        establish_legacy_protocol(
          transport_mod,
          transport_state,
          cached_legacy_opts(opts, version),
          era_identity
        )

      :miss ->
        probe_then_maybe_legacy(transport_mod, transport_state, opts, era_identity)
    end
  end

  defp probe_then_maybe_legacy(transport_mod, transport_state, opts, era_identity) do
    case probe_era(transport_mod, transport_state, opts) do
      {:ok, discovery, updated_state} ->
        emit_settled_era(:modern, discovery.protocol_version)
        observe_era(era_identity, :modern, discovery.protocol_version, opts)
        {:ok, discovery_as_connection_result(discovery), updated_state}

      {:error, probe_error, updated_state} ->
        with {:ok, legacy_opts} <- legacy_fallback(probe_error, opts),
             true <- transport_alive?(transport_mod, updated_state) do
          case establish_legacy_protocol(
                 transport_mod,
                 updated_state,
                 legacy_opts,
                 era_identity
               ) do
            {:ok, _result, _state} = success ->
              :telemetry.execute(
                [:arbor_mcp, :client, :era, :fallback],
                %{},
                %{from: :modern, to: :legacy, reason: probe_failure_class(probe_error)}
              )

              success

            {:error, initialize_error, latest_state} ->
              {:error,
               {:era_probe_and_initialize_failed,
                %{probe: probe_error, initialize: initialize_error}}, latest_state}
          end
        else
          _no_legacy_evidence ->
            without_legacy_evidence(transport_mod, updated_state, probe_error)
        end
    end
  end

  # A stdio server that predates server/discover may exit on the probe
  # (Python's `mcp` 1.8 and earlier do) or never answer it. That is no
  # evidence on the probed pipe, which a late reply could still reach, so
  # do_establish_connection/2 reaps that child and initializes a new one.
  defp without_legacy_evidence(transport_mod, transport_state, probe_error) do
    if respawn_for_legacy?(transport_mod, transport_state, probe_error),
      do: {:respawn_for_legacy, probe_error, transport_state},
      else: {:error, {:era_probe_failed, probe_error}, transport_state}
  end

  defp respawn_for_legacy?(transport_mod, transport_state, {:transport_error, reason}) do
    spawned_server?(transport_mod, transport_state) and probe_unanswered?(reason)
  end

  defp respawn_for_legacy?(_transport_mod, _transport_state, _probe_error), do: false

  # The only two triggers: the probe timed out, or the child exited with no
  # answer at all. Malformed, partial or oversized output and any other
  # framing error are answers of a sort, and fail the connection.
  defp probe_unanswered?(:handshake_timeout), do: true
  defp probe_unanswered?({:connection_error, {:process_exited, _status}}), do: true
  defp probe_unanswered?(_reason), do: false

  # Under :prefer_modern only, once per attempt: the probed child is closed
  # (EOF, then TERM and KILL) before a fresh one is started from the same
  # options for the legacy handshake, all within the establishment deadline.
  # A child that cannot be confirmed stopped may still hold what the fresh
  # one needs (a port, a lock), so then no second one is started.
  defp respawn_for_legacy(
         {:respawn_for_legacy, probe_error, probed_state},
         transport_mod,
         transport_manager_opts,
         opts
       ) do
    ConnectionScope.transport(transport_mod, probed_state)
    deadline = Keyword.get(opts, :establish_deadline)

    closed = close_quietly(transport_mod, with_cleanup_deadline(transport_mod, probed_state))

    if closed != :ok and server_stop_result(closed) == :ok,
      do:
        Logger.warning("Respawning although part of the cleanup failed",
          reason: LogSummary.describe(closed)
        )

    with {:closed, :ok} <- {:closed, server_stop_result(closed)},
         :ok <- check_deadline(deadline),
         :ok <- Lifetime.opening(),
         :ok <- ConnectionScope.opening(),
         {:ok, {_transport_mod, respawned}} <- connect_transport(transport_manager_opts) do
      initialize_respawned(transport_mod, respawned, probe_error, opts, deadline)
    else
      {:closed, cleanup} ->
        {:error, {:probed_server_stop_unconfirmed, %{probe: probe_error, cleanup: cleanup}}}

      {:error, reason} ->
        {:error, {:era_probe_and_respawn_failed, %{probe: probe_error, respawn: reason}}}
    end
  end

  defp respawn_for_legacy(result, _transport_mod, _transport_manager_opts, _opts), do: result

  # Fails with the respawned transport, which close_on_failure/2 then closes.
  defp initialize_respawned(transport_mod, respawned, probe_error, opts, deadline) do
    with :ok <- ConnectionScope.transport(transport_mod, respawned),
         respawned = Deadline.put_on_transport(transport_mod, respawned, deadline),
         era_identity = EraCache.identity(transport_mod, respawned, opts),
         {:ok, _result, _state} = success <-
           establish_legacy_protocol(transport_mod, respawned, opts, era_identity) do
      :telemetry.execute(
        [:arbor_mcp, :client, :era, :fallback],
        %{},
        %{from: :modern, to: :legacy, reason: probe_failure_class(probe_error), respawned: true}
      )

      success
    else
      {:error, initialize_error, latest_state} ->
        {:error,
         {:era_probe_and_initialize_failed,
          %{probe: probe_error, initialize: initialize_error, respawned: true}}, latest_state}

      {:error, reason} ->
        {:error, {:era_probe_and_respawn_failed, %{probe: probe_error, respawn: reason}},
         respawned}
    end
  end

  defp establish_prefer_legacy(transport_mod, transport_state, opts, era_identity) do
    case cached_era(era_identity) do
      :modern ->
        establish_modern_protocol(transport_mod, transport_state, opts, era_identity, true)

      {:legacy, version} ->
        establish_legacy_protocol(
          transport_mod,
          transport_state,
          cached_legacy_opts(opts, version),
          era_identity
        )

      :miss ->
        initialize_then_maybe_modern(transport_mod, transport_state, opts, era_identity)
    end
  end

  defp initialize_then_maybe_modern(transport_mod, transport_state, opts, era_identity) do
    case establish_legacy_protocol(transport_mod, transport_state, opts, era_identity) do
      {:ok, _result, _state} = success ->
        success

      {:error, initialize_error, latest_state} ->
        if legacy_protocol_failure?(initialize_error) and
             transport_alive?(transport_mod, transport_state) do
          probe_state = abandon_legacy_attempt(transport_mod, transport_state, latest_state)

          case probe_era(transport_mod, probe_state, opts) do
            {:ok, discovery, updated_state} ->
              emit_settled_era(:modern, discovery.protocol_version)
              observe_era(era_identity, :modern, discovery.protocol_version, opts)
              {:ok, discovery_as_connection_result(discovery), updated_state}

            {:error, probe_error, updated_state} ->
              retry_legacy_after_probe(
                transport_mod,
                updated_state,
                opts,
                era_identity,
                %{initialize: initialize_error, probe: probe_error}
              )
          end
        else
          {:error, initialize_error, latest_state}
        end
    end
  end

  # The probe after a failed initialize can name the legacy revisions the
  # server does support. When the initialize offered another one, it is tried
  # once more with the client's preferred revision among them; otherwise the
  # initialize failure stands.
  defp retry_legacy_after_probe(transport_mod, transport_state, opts, era_identity, failures) do
    with version when is_binary(version) <- offered_legacy_version(failures.probe, opts),
         true <- version != initialize_version(opts),
         true <- transport_alive?(transport_mod, transport_state) do
      case establish_legacy_protocol(
             transport_mod,
             transport_state,
             Keyword.put(opts, :protocol_version, version),
             era_identity
           ) do
        {:ok, _result, _state} = success ->
          success

        {:error, initialize_error, latest_state} ->
          {:error, {:initialize_and_era_probe_failed, %{failures | initialize: initialize_error}},
           latest_state}
      end
    else
      _no_other_version -> {:error, {:initialize_and_era_probe_failed, failures}, transport_state}
    end
  end

  defp discovery_as_connection_result(discovery) do
    %{
      "protocolVersion" => discovery.protocol_version,
      "capabilities" => discovery.server_capabilities,
      "serverInfo" => discovery.server_info,
      "instructions" => Map.get(discovery, :instructions)
    }
  end

  # Over stdio the probe is the first message a newly spawned server reads, so
  # waiting for its answer also waits for the server to start: a BEAM under
  # `mix run`, or `npx` or `uvx` on a cold cache, can take seconds, and that
  # says nothing about its era. Unless `:era_probe_timeout` is given, the probe
  # there gets `:handshake_timeout`, the time a legacy `initialize` gets for
  # the same first answer. The establishment deadline still caps it.
  defp probe_era(transport_mod, transport_state, opts) do
    timeout = probe_timeout(opts, spawned_server?(transport_mod, transport_state))
    EraProbe.probe(transport_mod, transport_state, Keyword.put(opts, :era_probe_timeout, timeout))
  end

  defp probe_timeout(opts, true = _spawned_server?),
    do: Keyword.get_lazy(opts, :era_probe_timeout, fn -> handshake_timeout(opts) end)

  defp probe_timeout(opts, false = _spawned_server?), do: EraProbe.timeout(opts)

  @doc false
  # Whether `opts` connect to a stdio server, before it is spawned.
  def spawns_server?(opts) do
    case prepare_transport_config(opts) do
      {:ok, config} -> match?([{Stdio, _transport_opts} | _], Keyword.get(config, :transports))
      _error -> false
    end
  end

  @doc false
  # Whether this transport runs its own server process (stdio, directly or
  # inside the reliability wrapper).
  def spawned_server?(Stdio, _transport_state), do: true

  def spawned_server?(ReliabilityWrapper, %ReliabilityWrapper{} = transport_state) do
    {wrapped_module, _wrapped_state} = ReliabilityWrapper.unwrap(transport_state)
    wrapped_module == Stdio
  end

  def spawned_server?(_transport_mod, _transport_state), do: false

  defp handshake_timeout(opts),
    do: Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)

  # The options for the initialize that follows a failed probe, when the
  # failure is evidence of a legacy server.
  defp legacy_fallback(probe_error, opts) do
    case offered_legacy_version(probe_error, opts) do
      nil -> if legacy_fallback_evidence?(probe_error), do: {:ok, opts}, else: :none
      version -> {:ok, Keyword.put(opts, :protocol_version, version)}
    end
  end

  # MCP says to retry with a version the server's UnsupportedProtocolVersionError
  # lists. When it lists only legacy revisions (an Arbor server running
  # `protocol_mode: :legacy_only` does), the server is legacy and that retry is
  # an initialize offering the client's preferred revision among them. A list
  # that also names a modern or an unknown revision is no such evidence: the
  # server may be modern. A DiscoverResult is never taken as legacy evidence;
  # its version mismatch arrives wrapped as :invalid_discover_result.
  defp offered_legacy_version(
         {:no_mutually_supported_modern_version, %{server: [_ | _] = server_versions}},
         opts
       ) do
    if Enum.all?(server_versions, &(VersionRegistry.era_for(&1) == :legacy)) do
      Enum.find(
        [Keyword.get(opts, :protocol_version), VersionRegistry.preferred_version()] ++
          VersionRegistry.supported_versions(),
        &(&1 in server_versions)
      )
    end
  end

  defp offered_legacy_version(_probe_error, _opts), do: nil

  # The revision an initialize built from `opts` offers.
  defp initialize_version(opts),
    do: Keyword.get(opts, :protocol_version) || VersionRegistry.preferred_version()

  defp legacy_fallback_evidence?({:json_rpc_error, error}) do
    not modern_specific_error?(error)
  end

  # MCP counts an unanswered probe as a legacy server. Here that is a probe
  # the transport reports timed out, such as an HTTP POST cut short by the
  # probe's bound. A stdio probe that runs out of time fails instead as
  # {:transport_error, :handshake_timeout}, which is deliberately not
  # evidence on that pipe: the server may only be slow to start, and its late
  # answer to the probe would share the pipe with an initialize sent after it.
  # :prefer_modern initializes a fresh process instead (see
  # without_legacy_evidence/3).
  defp legacy_fallback_evidence?({:probe_timeout, _reason}), do: true
  defp legacy_fallback_evidence?({:http_probe_rejected, _response}), do: true
  defp legacy_fallback_evidence?(_reason), do: false

  defp modern_specific_error?(%{"code" => -32022, "data" => data}) when is_map(data) do
    is_list(data["supported"]) and is_binary(data["requested"])
  end

  defp modern_specific_error?(_error), do: false

  defp legacy_protocol_failure?(:invalid_request), do: true
  defp legacy_protocol_failure?({:method_not_found, _message}), do: true
  defp legacy_protocol_failure?({:initialize_rejected, _error}), do: true
  defp legacy_protocol_failure?(_reason), do: false

  defp transport_alive?(transport_mod, transport_state) do
    if function_exported?(transport_mod, :connected?, 1) do
      transport_mod.connected?(transport_state)
    else
      true
    end
  rescue
    _error -> false
  end

  defp emit_settled_era(era, version) do
    :telemetry.execute(
      [:arbor_mcp, :client, :era, :settled],
      %{},
      %{era: era, protocol_version: version}
    )
  end

  defp probe_failure_class({kind, _detail}), do: kind

  defp cached_era(identity) do
    case EraCache.lookup(identity) do
      {:ok, %{era: era, protocol_version: version}} ->
        :telemetry.execute(
          [:arbor_mcp, :client, :era, :cache_hit],
          %{},
          %{era: era, protocol_version: version}
        )

        if era == :legacy, do: {:legacy, version}, else: era

      :miss ->
        :miss
    end
  end

  # A legacy observation keeps the revision the server negotiated, which may
  # be an older one the fallback picked from its list; offering it again lets
  # a server that accepts only that revision be reached on the next connection
  # too, until the observation expires.
  defp cached_legacy_opts(opts, version) do
    if VersionRegistry.era_for(version) == :legacy,
      do: Keyword.put(opts, :protocol_version, version),
      else: opts
  end

  defp maybe_reset_era_cache(identity, opts) do
    if Keyword.get(opts, :reset_era_cache, false), do: EraCache.clear(identity), else: :ok
  end

  defp observe_era(identity, era, version, opts) when is_binary(version) do
    EraCache.observe(identity, era, version, opts)
  end

  defp observe_era(_identity, _era, _version, _opts), do: :ok

  defp settle_transport_era(HTTP, transport_state, result) do
    version = result["protocolVersion"]
    HTTP.settle_protocol_era(transport_state, VersionRegistry.era_for(version), version)
  end

  defp settle_transport_era(ReliabilityWrapper, transport_state, result) do
    case ReliabilityWrapper.unwrap(transport_state) do
      {HTTP, http_state} ->
        version = result["protocolVersion"]
        settled = HTTP.settle_protocol_era(http_state, VersionRegistry.era_for(version), version)
        %{transport_state | wrapped_state: settled}

      _other ->
        transport_state
    end
  end

  defp settle_transport_era(_transport_mod, transport_state, _result), do: transport_state

  defp adopt_negotiated_version(transport_mod, transport_state, %{"protocolVersion" => version})
       when is_binary(version) do
    case {transport_mod, transport_state} do
      {HTTP, %HTTP{} = http_state} ->
        HTTP.settle_protocol_era(http_state, :legacy, version)

      {ReliabilityWrapper, %ReliabilityWrapper{} = wrapper} ->
        case ReliabilityWrapper.unwrap(wrapper) do
          {HTTP, http_state} ->
            %{wrapper | wrapped_state: HTTP.settle_protocol_era(http_state, :legacy, version)}

          _other ->
            wrapper
        end

      _other ->
        transport_state
    end
  end

  defp adopt_negotiated_version(_transport_mod, transport_state, _result), do: transport_state

  @doc """
  The message receiving loop.

  This function is intended to be run in a separate process (e.g., a Task).
  It continuously receives messages from the transport and forwards them to the parent process.
  """
  def receive_loop(parent, transport_mod, transport_state) do
    case transport_mod.receive_message(transport_state) do
      {:ok, message, new_state} ->
        :telemetry.execute(
          [:arbor_mcp, :client, :receiver, :message],
          %{},
          %{}
        )

        Lifetime.deliver(parent, {:transport_message, message})
        receive_loop(parent, transport_mod, new_state)

      {:error, :closed} ->
        Lifetime.deliver(parent, {:transport_closed, :normal})
        :ok

      {:error, :waiting_for_session} ->
        # SSE not started yet — retry (SSE will start when server provides session ID)
        receive_loop(parent, transport_mod, transport_state)

      {:error, :stream_withdrawn} ->
        # The server stopped offering the stream this loop reads, such as a
        # legacy GET stream reopened with 405, while requests and their
        # responses still work. The connection goes on without a receiver.
        Lifetime.deliver(parent, {:transport_receiver_stopped, self()})
        :ok

      {:error, :not_supported_in_sync_mode} ->
        # Non-SSE HTTP mode — responses come from send_message directly.
        # Keep the loop alive but sleep to avoid busy-waiting.
        Process.sleep(100)
        receive_loop(parent, transport_mod, transport_state)

      {:error, {:session_expired, _detail} = reason} ->
        # The server ended the legacy HTTP session this stream belongs to.
        # That is no transport fault: the client starts a new session.
        Lifetime.deliver(parent, {:transport_closed, reason})
        :ok

      {:error, reason} ->
        Logger.error("Transport error in receive loop", reason: LogSummary.describe(reason))
        Lifetime.deliver(parent, {:transport_closed, reason})
        :ok
    end
  end

  # Private Functions

  defp connect_transport(transport_manager_opts) do
    reliability_opts = Keyword.get(transport_manager_opts, :reliability, [])

    # For now, just connect to the first transport directly
    case Keyword.get(transport_manager_opts, :transports) do
      [{transport_mod, transport_opts} | _] ->
        connect_with_reliability(transport_mod, transport_opts, reliability_opts)

      [] ->
        {:error, "No transports configured"}

      _missing ->
        {:error, "No transport specified"}
    end
  end

  defp connect_with_reliability(transport_mod, transport_opts, reliability_opts) do
    case transport_mod.connect(transport_opts) do
      {:ok, transport_state} ->
        cond do
          reliability_opts == [] ->
            {:ok, {transport_mod, transport_state}}

          # HTTP keeps the wrapper's components itself, so the client still
          # sees an HTTP transport and sends each request from its own task
          # (see HTTP.attach_reliability/2).
          transport_mod == HTTP ->
            {:ok, wrapper} = ReliabilityWrapper.wrap(HTTP, transport_state, reliability_opts)
            {:ok, {HTTP, HTTP.attach_reliability(transport_state, wrapper)}}

          true ->
            {:ok, wrapped_state} =
              ReliabilityWrapper.wrap(transport_mod, transport_state, reliability_opts)

            {:ok, {ReliabilityWrapper, wrapped_state}}
        end

      error ->
        error
    end
  end

  @doc false
  # The client options without the `:session_id` a legacy HTTP connection
  # resumes, wherever a transport spec carries it, for a server that has
  # ended that session: a new connection must start a session of its own.
  @spec forget_session_id(keyword()) :: keyword()
  def forget_session_id(opts) when is_list(opts) do
    opts
    |> Keyword.delete(:session_id)
    |> update_present(:transport, &forget_spec_session_id/1)
    |> update_present(:transports, fn
      specs when is_list(specs) -> Enum.map(specs, &forget_spec_session_id/1)
      other -> other
    end)
  end

  defp update_present(opts, key, fun) do
    if Keyword.has_key?(opts, key), do: Keyword.update!(opts, key, fun), else: opts
  end

  defp forget_spec_session_id({transport, spec_opts}) when is_list(spec_opts),
    do: {transport, Keyword.delete(spec_opts, :session_id)}

  defp forget_spec_session_id(spec) when is_list(spec), do: Keyword.delete(spec, :session_id)
  defp forget_spec_session_id(spec), do: spec

  def prepare_transport_config(opts) do
    cond do
      Keyword.has_key?(opts, :transports) ->
        # Multiple transports specified
        transport_manager_opts =
          Keyword.take(opts, [
            :transports,
            :fallback_strategy,
            :max_retries,
            :retry_interval,
            :reliability
          ])

        normalized_transports =
          Enum.map(transport_manager_opts[:transports], &normalize_transport_spec(&1, opts))

        # Check for any errors in normalization
        case Enum.find(normalized_transports, &match?({:error, _}, &1)) do
          {:error, reason} -> {:error, reason}
          nil -> {:ok, Keyword.put(transport_manager_opts, :transports, normalized_transports)}
        end

      Keyword.has_key?(opts, :transport) ->
        # Single transport specified
        transport_spec = Keyword.get(opts, :transport)

        case normalize_transport_spec(transport_spec, opts) do
          {:error, reason} ->
            {:error, reason}

          normalized_spec ->
            result = [transports: [normalized_spec]]

            result =
              if Keyword.has_key?(opts, :reliability),
                do: Keyword.put(result, :reliability, opts[:reliability]),
                else: result

            {:ok, result}
        end

      true ->
        {:error, "No transport specified. Please provide :transport or :transports option."}
    end
  end

  defp normalize_transport_spec(transport, opts) when is_atom(transport) do
    case transport do
      :native ->
        {:error, "Unsupported transport :native. Use :beam for local BEAM MCP transport."}

      :sse ->
        {LegacySSE, opts}

      :beam ->
        {Local, opts}

      :stdio ->
        {Stdio, opts}

      :http ->
        {HTTP, opts}

      :test ->
        {Test, opts}

      :mock ->
        {MockTransport, opts}

      mod when is_atom(mod) ->
        {mod, opts}
    end
  end

  defp normalize_transport_spec({transport, transport_opts}, _opts) do
    normalize_transport_spec(transport, transport_opts)
  end

  defp normalize_transport_spec(transport_spec, opts) when is_list(transport_spec) do
    # Handle keyword list format: [type: :mock, server_pid: pid, ...]
    case Keyword.get(transport_spec, :type) do
      nil ->
        # If no :type key, try to infer from the presence of known keys
        cond do
          Keyword.has_key?(transport_spec, :server_pid) ->
            # Convert :server_pid to :server for Test transport
            server_pid = Keyword.get(transport_spec, :server_pid)

            test_opts =
              transport_spec |> Keyword.delete(:server_pid) |> Keyword.put(:server, server_pid)

            {Test, test_opts}

          Keyword.has_key?(transport_spec, :command) ->
            {Stdio, transport_spec}

          Keyword.has_key?(transport_spec, :url) ->
            {HTTP, transport_spec}

          true ->
            {:error, "Cannot determine transport type from #{inspect(transport_spec)}"}
        end

      transport_type ->
        # Use the :type key to determine the transport module
        transport_spec_without_type = Keyword.delete(transport_spec, :type)

        # Only the runtime-backed Test transport uses :server. MockTransport
        # retains its own :server_pid option and synchronous mock protocol.
        transport_spec_normalized =
          if transport_type == :test and
               Keyword.has_key?(transport_spec_without_type, :server_pid) do
            server_pid = Keyword.get(transport_spec_without_type, :server_pid)

            transport_spec_without_type
            |> Keyword.delete(:server_pid)
            |> Keyword.put(:server, server_pid)
          else
            transport_spec_without_type
          end

        normalize_transport_spec(transport_type, Keyword.merge(transport_spec_normalized, opts))
    end
  end

  # Handle invalid transport types gracefully
  defp normalize_transport_spec(invalid_transport, _opts) do
    {:error, "Invalid transport specification: #{inspect(invalid_transport)}"}
  end

  defp maybe_default_legacy_sse_opts(opts) do
    if legacy_sse_transport?(opts) do
      opts
      |> Keyword.put_new(:protocol_mode, :legacy_only)
      |> Keyword.put_new(:protocol_version, "2024-11-05")
    else
      opts
    end
  end

  defp legacy_sse_transport?(opts) do
    case Keyword.get(opts, :transport) do
      :sse ->
        true

      {:sse, _transport_opts} ->
        true

      LegacySSE ->
        true

      {LegacySSE, _transport_opts} ->
        true

      spec when is_list(spec) ->
        Keyword.get(spec, :type) in [:sse, LegacySSE]

      _other ->
        false
    end
  end

  # `:handshake_timeout` bounds the whole initialize exchange: the send
  # (a synchronous HTTP POST included) and the wait for the response. The
  # connection's overall deadline caps it further.
  defp do_handshake(transport_mod, transport_state, opts) do
    protocol_version = Keyword.get(opts, :protocol_version)
    handshake_timeout = handshake_timeout(opts)
    establish_deadline = Deadline.on_transport(transport_mod, transport_state)

    # The same capabilities a modern client sends with every request.
    capabilities = Keyword.get(opts, :capabilities, %{})

    exchange = fn state ->
      exchange_deadline =
        Deadline.earliest(
          Deadline.after_ms(handshake_timeout),
          Keyword.get(opts, :establish_deadline)
        )

      state = Deadline.put_on_transport(transport_mod, state, exchange_deadline)
      exchange_initialize(transport_mod, state, protocol_version, capabilities, exchange_deadline)
    end

    transport_state
    |> without_ended_session()
    |> exchange.()
    |> start_new_session(exchange)
    |> restore_deadline(transport_mod, establish_deadline)
  end

  # An initialize that carried a configured `:session_id` the server has
  # ended gets 404, and the client must then start a new session with an
  # initialize that carries no session id (Session Management, 2025-03-26 and
  # later). It sends that one at once, within the connection's deadline, and
  # reports its failure as it is. The connection remembers that the session
  # ended, so no later initialize in the same attempt (a version retry after
  # the modern probe, say) offers it again, and this happens at most once per
  # attempt.
  defp start_new_session({:error, {:session_expired, _detail}, %HTTP{} = latest}, exchange),
    do: exchange.(%{latest | session_id: nil, configured_session_ended: true})

  defp start_new_session(result, _exchange), do: result

  defp without_ended_session(%HTTP{configured_session_ended: true} = state),
    do: %{state | session_id: nil}

  defp without_ended_session(state), do: state

  defp exchange_initialize(
         transport_mod,
         transport_state,
         protocol_version,
         capabilities,
         deadline
       ) do
    request =
      Protocol.encode_initialize(VersionInfo.client_info(), capabilities, protocol_version)

    case send_initialize_request(transport_mod, transport_state, request) do
      {:ok, state_after_send, response_data} ->
        # Non-SSE HTTP mode - response came back immediately
        response_data
        |> parse_handshake_response(state_after_send)
        |> with_state(state_after_send)

      {:ok, state_after_send} ->
        # SSE mode or other transports - need to receive separately
        case await_handshake_message(
               transport_mod,
               state_after_send,
               deadline
             ) do
          {:ok, response_data, state_after_receive} ->
            response_data
            |> parse_handshake_response(state_after_receive)
            |> with_state(state_after_receive)

          {:error, _reason, _latest_state} = error ->
            error
        end

      # An HTTP server rejects initialize with a 400 carrying the JSON-RPC
      # error (a modern-only one does), which the other transports deliver
      # as the response itself: read it the same way. Only an error for this
      # initialize counts. A null id means the server could not read the
      # request's id, which a well-formed initialize never causes, and any
      # other id is someone else's answer (a stale proxy's, say): both stay
      # the transport error they were.
      {:error, {:http_error, 400, body}} = error ->
        initialize_response_error(error, body, request, transport_state, deadline)

      {:error, {:http_error, 400, body} = reason, latest_state} ->
        initialize_response_error({:error, reason}, body, request, latest_state, deadline)

      {:error, reason, latest_state} ->
        {:error, initialize_send_error({:error, reason}, deadline), latest_state}

      {:error, _reason} = error ->
        {:error, initialize_send_error(error, deadline), transport_state}
    end
  end

  defp initialize_response_error(error, body, request, transport_state, deadline) do
    initialize_id = request["id"]

    case Protocol.parse_message(body) do
      {:error, details, ^initialize_id} when is_map(details) ->
        body |> parse_handshake_response(transport_state) |> with_state(transport_state)

      _other ->
        {:error, initialize_send_error(error, deadline), transport_state}
    end
  end

  defp initialize_send_error({:error, reason}, deadline),
    do: if(Deadline.expired?(deadline), do: :handshake_timeout, else: reason)

  defp with_state({:ok, _result, _state} = success, _transport_state), do: success
  defp with_state({:error, reason}, transport_state), do: {:error, reason, transport_state}

  defp restore_deadline({:ok, result, transport_state}, transport_mod, deadline),
    do: {:ok, result, Deadline.put_on_transport(transport_mod, transport_state, deadline)}

  defp restore_deadline({:error, reason, transport_state}, transport_mod, deadline),
    do: {:error, reason, Deadline.put_on_transport(transport_mod, transport_state, deadline)}

  defp send_initialize_request(transport_mod, transport_state, request) do
    with {:ok, outbound_request} <- encode_for_transport(transport_mod, request) do
      case Transport.send_message_with_state(transport_mod, outbound_request, transport_state) do
        {:ok, new_state, response_data} ->
          # Non-SSE HTTP mode returns response immediately
          {:ok, new_state, response_data}

        {:ok, new_state} ->
          # SSE mode or other transports
          {:ok, new_state}

        error ->
          error
      end
    end
  end

  defp encode_for_transport(Local, message), do: {:ok, message}
  defp encode_for_transport(_transport_mod, message), do: Protocol.encode_to_string(message)

  # Receives the initialize response with a bounded wait so a silent server
  # cannot hang client start_link forever. Transports that export
  # receive_message/2 (e.g. the Test transport, which reads the caller's
  # mailbox) are called in-process with the timeout; transports with only the
  # blocking receive_message/1 are wrapped in a task that is shut down on
  # expiry. On timeout the connection attempt fails with :handshake_timeout.
  # A server may send notifications, such as a log message or a list
  # change, before it answers. They aren't the answer and say nothing about
  # the protocol era, so keep waiting for one until the deadline.
  defp await_handshake_message(transport_mod, transport_state, deadline) do
    case receive_handshake_message(transport_mod, transport_state, Deadline.remaining(deadline)) do
      {:ok, message, new_state} ->
        if match?({:notification, _method, _params}, Protocol.parse_message(message)),
          do: await_handshake_message(transport_mod, new_state, deadline),
          else: {:ok, message, new_state}

      error ->
        error
    end
  end

  defp receive_handshake_message(transport_mod, transport_state, timeout) do
    result =
      if function_exported?(transport_mod, :receive_message, 2) do
        transport_mod.receive_message(transport_state, timeout)
      else
        receive_handshake_via_task(transport_mod, transport_state, timeout)
      end

    case result do
      {:ok, message, new_state} ->
        {:ok, message, new_state}

      {:error, :handshake_timeout} ->
        {:error, :handshake_timeout, transport_state}

      {:error, {:timeout_error, _reason}} ->
        {:error, :handshake_timeout, transport_state}

      {:error, reason} ->
        {:error, "Failed to receive handshake response: #{inspect(reason)}", transport_state}
    end
  end

  defp receive_handshake_via_task(transport_mod, transport_state, timeout) do
    task = ConnectionScope.async(fn -> transport_mod.receive_message(transport_state) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:handshake_receive_failed, reason}}
      nil -> {:error, :handshake_timeout}
    end
  end

  defp parse_handshake_response(response_data, transport_state) do
    case Protocol.parse_message(response_data) do
      {:result, result, _id} ->
        {:ok, result, transport_state}

      {:error, error_details, _id} ->
        Logger.debug("Handshake failed", reason: LogSummary.describe(error_details))

        # Extract error code for cleaner error reporting
        error_code = error_details["code"]
        error_message = error_details["message"] || "Unknown error"

        case error_code do
          -32600 -> {:error, :invalid_request}
          -32601 -> {:error, {:method_not_found, error_message}}
          _ -> {:error, {:initialize_rejected, error_details}}
        end

      {:error, :invalid_message} ->
        {:error, "Failed to parse handshake response: invalid message format"}

      other ->
        {:error, "Unexpected handshake response: #{inspect(other)}"}
    end
  end

  defp send_initialized(transport_mod, transport_state, _result) do
    notification = Protocol.encode_initialized()

    with {:ok, outbound_notification} <- encode_for_transport(transport_mod, notification) do
      case Transport.send_message_with_state(
             transport_mod,
             outbound_notification,
             transport_state
           ) do
        {:ok, new_state, _response_data} ->
          # Non-SSE HTTP mode may return response (ignore it for notifications)
          {:ok, new_state}

        {:ok, new_state} ->
          # SSE mode or other transports
          {:ok, new_state}

        error ->
          error
      end
    end
  end

  defp start_receiver_task(parent, transport_mod, transport_state) do
    cond do
      # HTTP non-SSE: no receiver needed (responses come from send_message)
      transport_mod == Arbor.MCP.Transport.HTTP and not transport_state.use_sse ->
        {:ok, nil}

      # MockServer replies in the sending caller. No polling process or
      # response mailbox is needed for this synchronous testing transport.
      transport_mod == MockTransport ->
        {:ok, nil}

      # Push mode: subscribe instead of polling
      Arbor.MCP.Transport.supports_push?(transport_mod) ->
        case transport_mod.subscribe(parent, transport_state) do
          {:ok, new_state} ->
            :telemetry.execute(
              [:arbor_mcp, :client, :receiver, :started],
              %{},
              %{mode: :push}
            )

            # Return :push atom as receiver_task to signal push mode is active.
            # The updated transport_state with subscriber must be stored by caller.
            {:ok, {:push, new_state}}

          {:error, _reason} ->
            # Fall back to polling
            :telemetry.execute(
              [:arbor_mcp, :client, :receiver, :started],
              %{},
              %{mode: :pull}
            )

            task =
              ConnectionScope.async(fn ->
                __MODULE__.receive_loop(parent, transport_mod, transport_state)
              end)

            {:ok, task}
        end

      # Legacy polling mode
      true ->
        :telemetry.execute(
          [:arbor_mcp, :client, :receiver, :started],
          %{},
          %{mode: :pull}
        )

        task =
          ConnectionScope.async(fn ->
            __MODULE__.receive_loop(parent, transport_mod, transport_state)
          end)

        {:ok, task}
    end
  end
end
