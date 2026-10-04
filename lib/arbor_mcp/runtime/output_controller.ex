defmodule Arbor.MCP.Server.Runtime.OutputController do
  @moduledoc false
  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Failure,
    HTTPOutput,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket,
    Initialization,
    OutputLedger,
    OutputTicket,
    Ref
  }

  alias Arbor.MCP.Server.Subscriptions.Origin

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(opts[:table]))

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }

  def register(table, token, output \\ nil, owner \\ self()),
    do: call(table, {:register, token, output, owner})

  def edge_result(table, token, output, value) do
    with {:ok, context} <- register(table, token, output, controller(table)),
         {:ok, ticket} <- prepare(context, value),
         do: call(table, {:edge_prepared, token, ticket})
  end

  def result(table, ticket), do: call(table, {:result, ticket})
  def deliver(table, token, ticket), do: call(table, {:deliver, token, ticket})
  def held(table, token, ticket), do: call(table, {:held, token, ticket})
  def finish(table, token), do: call(table, {:finish, token})
  def retire(table, token, reason), do: call(table, {:retire, token, reason})
  def failed(table, token, reason), do: call(table, {:failed, token, reason})

  def http_failure(table, token, binding, format),
    do: http_control_call(table, {:http_failure, token, binding, format})

  def http_observation(table, token), do: http_control_call(table, {:http_observation, token})

  defp http_control_call(table, request) do
    GenServer.call(controller(table), request, 50)
  catch
    :exit, _reason -> {:error, :output_unavailable}
  end

  def http_notification(table, source, binding, deadline),
    do: call_until(table, {:http_notification, make_ref(), source, binding}, deadline)

  def http_notification_prepared(table, token, ticket, deadline),
    do: call_until(table, {:http_notification_prepared, token, ticket}, deadline)

  defp call_until(table, request, deadline) do
    GenServer.call(controller(table), request, max(1, min(5000, deadline - now())))
  catch
    :exit, _reason -> {:error, :output_expired}
  end

  def connect(table, connection, peer, transport, event_context \\ nil),
    do: call(table, {:connect, connection, peer, transport, event_context})

  def connect_startup(table, context) do
    result =
      GenServer.call(
        controller(table),
        {:connect_startup, context},
        Initialization.remaining(table)
      )

    if Initialization.current?(table, context), do: result, else: {:error, :runtime_init_timeout}
  catch
    :exit, _reason -> {:error, :runtime_init_timeout}
  end

  def stats(table), do: call(table, :stats)
  def pending?(table, token), do: call(table, {:pending, token})
  def write_payload(table, ticket), do: call(table, {:write_payload, ticket})
  def write_complete(table, ticket, result), do: call(table, {:write_complete, ticket, result})

  def emit(table, connection, value, source_token \\ nil) do
    emit_registered(table, {:register_control, make_ref(), connection, source_token}, value)
  end

  def emit_origin(table, connection, value, origin) do
    emit_registered(table, {:register_origin, make_ref(), connection, origin}, value)
  end

  defp emit_registered(table, {kind, token, connection, source}, value) do
    with {:ok, context} <- call(table, {kind, token, connection, source}),
         {:ok, ticket} <- prepare(context, value),
         :ok <- call(table, {:edge_prepared, token, ticket}),
         do: {:ok, token}
  end

  def mark_committed(table, token, ticket) do
    # Fixed-size publication proof is visible even while this Controller is
    # suspended. It carries no response term and never extends the deadline.
    # This call is made by Scheduler after state commit and before publication.
    # It fixes source success independently from later peer delivery or failure.
    Admission.complete_output_phase(table, token)
    :ets.insert(table, {{:output_commit, token}, ticket})
    HTTPOutput.mark_committed(ticket)
  end

  def mark_failure(table, token, reason) do
    with [{_key, reservation}] <- :ets.lookup(table, {:reservation, token}),
         [{:output_failure_timeout, timeout}] <- :ets.lookup(table, :output_failure_timeout) do
      proof = %{
        generation: reservation.generation,
        scope: reservation.scope,
        caller: reservation.caller,
        request_id: reservation.request_id,
        deadline: now() + timeout,
        reason: reason
      }

      :ets.insert_new(table, {{:output_failure, token}, proof})
      :ok
    else
      _ -> {:error, :output_unavailable}
    end
  rescue
    ArgumentError -> {:error, :output_unavailable}
  end

  def prepare(context, value) do
    case OutputLedger.prepare(context.ledger, value,
           scope: context.scope,
           owner: context.owner,
           deadline: context.deadline,
           codec: context.codec,
           group: context.group
         ) do
      {:ok, ticket} -> prepare_effect(context, ticket)
      error -> error
    end
  end

  defp prepare_effect(context, ticket) do
    case HTTPOutput.prepare(context, ticket) do
      {:ok, paired} ->
        with :ok <- HTTPOutput.handoff(paired),
             :ok <- OutputLedger.handoff(paired) do
          {:ok, paired}
        else
          error ->
            HTTPOutput.release_all(paired)
            error
        end

      error ->
        OutputLedger.release(ticket)
        error
    end
  end

  # Edge-authored validation replies have no handler proposal to commit. They
  # still use producer-side preparation and the same reserved aggregate charge.
  def prepare_edge(table, token, output, value) do
    with {:ok, context} <- register(table, token, output),
         context = %{context | owner: controller(table)},
         {:ok, ticket} <- prepare(context, value),
         :ok <- call(table, {:edge_prepared, token, ticket}),
         do: {:ok, ticket}
  end

  defp controller(table) do
    case :ets.lookup(table, :output_controller) do
      [{:output_controller, pid}] -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp call(table, request) do
    case controller(table) do
      pid when is_pid(pid) -> GenServer.call(pid, request, 5_000)
      _ -> {:error, :output_unavailable}
    end
  catch
    :exit, _ -> {:error, :output_unavailable}
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    config = Keyword.fetch!(opts, :config)
    :ok = Initialization.watch(table, self())
    :ets.match_delete(table, {{:output_commit, :_}, :_})

    limits = [
      max_frame_bytes: config.max_output_frame_bytes,
      max_term_bytes: config.max_output_term_bytes,
      max_output_bytes: config.max_output_bytes,
      max_output_frames: config.max_output_frames,
      max_scope_bytes: config.max_output_scope_bytes,
      call_timeout_ms: config.output_timeout_ms
    ]

    with {:ok, ledger} <-
           OutputLedger.start_link(
             [owner: self(), runtime_table: table, timeout: Initialization.remaining(table)] ++
               limits
           ),
         {:ok, ref} <- OutputLedger.ref(ledger) do
      :ok = Initialization.watch(table, ledger)
      :ets.insert(table, {:output_controller, self()})
      :ets.insert(table, {:output_failure_timeout, config.output_timeout_ms})
      Process.send_after(self(), :reap, 20)

      state = %{
        table: table,
        ledger: ref,
        jobs: %{},
        scopes: %{},
        peer: nil,
        monitor: nil,
        writes: :queue.new(),
        writing: nil,
        output_timeout: config.output_timeout_ms
      }

      state =
        case :ets.lookup(table, :output_peer) do
          [{:output_peer, connection, peer, transport, event_context}] ->
            %{
              state
              | peer: peer_context(connection, peer, transport, event_context),
                monitor: Process.monitor(peer)
            }

          [{:output_peer, connection, peer, transport}] ->
            %{
              state
              | peer: %{connection: connection, pid: peer, transport: transport},
                monitor: Process.monitor(peer)
            }

          _ ->
            state
        end

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(request, from, state)
      when is_tuple(request) and
             elem(request, 0) in [:register, :deliver, :edge_prepared, :finish] do
    if Initialization.ready?(state.table),
      do: handle_ready_call(request, from, state),
      else: {:reply, {:error, :output_unavailable}, state}
  end

  def handle_call({:http_notification, token, source, binding}, {caller, _}, state) do
    with true <- Initialization.ready?(state.table),
         {:ok, reservation} <- Admission.current(state.table, source),
         true <-
           not reservation.terminal and reservation.deadline > now() and Process.alive?(caller),
         true <- :ets.member(state.table, {:runtime_owned, caller}),
         true <- HTTPWriterRegistry.source_valid?(binding, source),
         scope = {:http_control, reservation.generation, token},
         :ok <- OutputLedger.open_scope(state.ledger, scope, reservation.deadline),
         :ok <- OutputLedger.subscribe(state.ledger, scope, self()) do
      output = %{
        edge: caller,
        connection: binding,
        batch?: false,
        notification?: true,
        source_token: source,
        http: %{binding: binding, format: :sse}
      }

      context = %{
        ledger: state.ledger,
        scope: scope,
        owner: self(),
        group: false,
        codec: :protocol,
        deadline: reservation.deadline,
        http: %{binding: binding, format: :sse, owner: self(), notification: true}
      }

      job = %{
        scope: scope,
        scheduler: nil,
        output: output,
        deadline: reservation.deadline,
        committed?: true,
        stdio?: false,
        producer: caller,
        http_ticket: nil,
        edge_ticket: nil
      }

      {:reply, {:ok, token, context},
       %{
         state
         | jobs: Map.put(state.jobs, token, job),
           scopes: Map.put(state.scopes, scope, token)
       }}
    else
      _closed -> {:reply, {:error, :output_expired}, state}
    end
  end

  def handle_call({:http_notification_prepared, token, ticket}, {caller, _}, state) do
    case state.jobs[token] do
      %{producer: ^caller, output: %{notification?: true}} = job ->
        with true <- active_peer?(job.output, state),
             :ok <- OutputLedger.publish(ticket) do
          state = put_in(state.jobs[token].edge_ticket, ticket)
          {reply, state} = deliver_peer(ticket, job, state)

          if reply == :pending,
            do: {:reply, :ok, state},
            else: {:reply, reply, remove_scope(job.scope, state)}
        else
          error -> {:reply, error, remove_scope(job.scope, state)}
        end

      _missing ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call({:http_failure, token, binding, format}, {caller, _}, state) do
    with [{:http_gateway, ^caller}] <- :ets.lookup(state.table, :http_gateway),
         [{_, proof}] <- :ets.lookup(state.table, {:output_failure, token}),
         {:ok, deadline} <- HTTPWriterRegistry.failure_deadline(binding, token),
         true <- format in [:json, :sse] do
      prepare_http_failure(
        token,
        binding,
        format,
        caller,
        proof,
        deadline,
        retire_job(token, state)
      )
    else
      _invalid -> {:reply, {:error, :http_failure_expired}, state}
    end
  end

  def handle_call({:http_observation, token}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, http: _}, http_ticket: ticket} when not is_nil(ticket) ->
        observation = HTTPWriteTicket.observation(OutputTicket.http(ticket))
        {:reply, {:ok, observation}, state}

      _missing ->
        {:reply, {:error, :http_output_unavailable}, state}
    end
  end

  def handle_call({:result, ticket}, {caller, _}, state) do
    if authorized_ticket?(ticket, caller, state),
      do: {:reply, OutputLedger.value(ticket), state},
      else: {:reply, {:error, :invalid_output_owner}, state}
  end

  def handle_call({:held, token, ticket}, {caller, _}, state) do
    case state.jobs[token] do
      %{scheduler: ^caller, output: %{batch?: true}} ->
        case OutputLedger.value(ticket) do
          {:ok, value} ->
            Admission.terminal(state.table, token, descriptor(ticket, value))
            {:reply, :ok, state}

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call({:retire, token, reason}, _from, state) do
    case state.jobs[token] do
      nil ->
        :ets.delete(state.table, {:output_commit, token})

        case Admission.current(state.table, token) do
          {:ok, %{scope: {:connection, connection}}} ->
            notify_peer(%{output: %{connection: connection}}, reason, state)

          _ ->
            :ok
        end

        {:reply, :ok, state}

      job ->
        if state.writing && state.writing.token == token && state.writing.started? do
          {:reply, {:error, :output_write_uncertain}, fail_write(:output_write_uncertain, state)}
        else
          notify_peer(job, reason, state)
          OutputLedger.retire_scope(state.ledger, job.scope, reason)
          settle(job.scheduler, token, {:error, reason})
          {:reply, :ok, start_write(remove_scope(job.scope, state))}
        end
    end
  end

  def handle_call({:failed, token, reason}, _from, state) do
    case state.jobs[token] do
      nil ->
        {:reply, :ok, state}

      %{output: %{terminal?: true}} ->
        # A late worker result/DOWN may clean its transferred proposal, but
        # cannot retire the separate server-authored terminal reply lease.
        {:reply, :ok, state}

      %{output: %{batch?: true}} = job ->
        OutputLedger.discard_hidden(state.ledger, job.scope)

        if output_failure?(reason) do
          notify_peer(job, reason, state)
          {:reply, :ok, remove_scope(job.scope, state)}
        else
          {:reply, :ok, state}
        end

      job ->
        {:reply, :ok, remove_scope(job.scope, state)}
    end
  end

  def handle_call({:connect, connection, peer, transport, context}, _from, state) do
    {:reply, :ok, connect_peer(connection, peer, transport, state, context)}
  end

  def handle_call({:connect, connection, peer, transport}, from, state),
    do: handle_call({:connect, connection, peer, transport, nil}, from, state)

  def handle_call({:connect_startup, context}, _from, state) do
    if Initialization.current?(state.table, context) do
      :ets.delete(state.table, :output_peer)
      {:reply, :ok, connect_peer(nil, nil, nil, state)}
    else
      {:reply, {:error, :runtime_init_timeout}, state}
    end
  end

  def handle_call({:pending, token}, _from, state),
    do: {:reply, Map.has_key?(state.jobs, token), state}

  def handle_call({:register_control, token, connection, source_token}, {caller, _}, state) do
    case control_origin(state.table, source_token, caller) do
      {:ok, proof} -> register_control(token, connection, proof, nil, caller, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:register_origin, token, connection, origin}, {caller, _}, state) do
    if Origin.valid_for?(origin, state.table, connection, caller),
      do: register_control(token, connection, Origin.proof(origin), origin, caller, state),
      else: {:reply, {:error, :subscription_origin_retired}, state}
  end

  def handle_call({:write_payload, ticket}, {caller, _}, state) do
    case state do
      %{peer: %{pid: ^caller, transport: :stdio}, writing: %{ticket: ^ticket} = writing} ->
        job = state.jobs[writing.token]

        if writing.deadline > now() and valid_write_origin?(job, state) do
          case OutputLedger.payload(ticket) do
            {:ok, ^ticket, _term, wire} when is_binary(wire) ->
              {:reply, {:ok, wire, writing.deadline},
               %{state | writing: %{writing | started?: true}}}

            error ->
              {:reply, error, reject_write(writing.token, state)}
          end
        else
          # No IO has started: retire only this queued effect. Active-source
          # cancellation is not a writer failure or an undo of committed state.
          {:reply, {:error, :output_expired}, reject_write(writing.token, state)}
        end

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call({:write_complete, ticket, result}, {caller, _}, state) do
    case state do
      %{peer: %{pid: ^caller, transport: :stdio}, writing: %{ticket: ^ticket, token: token}} ->
        job = state.jobs[token]

        result =
          if state.writing.deadline <= now(), do: {:error, :output_write_uncertain}, else: result

        case result do
          :ok ->
            case OutputLedger.ack(ticket) do
              :ok ->
                settle(job.scheduler, token, :ok)
                notify_stdio(job, token, :ok)
                state = remove_scope(job.scope, %{state | writing: nil})
                {:reply, :ok, start_write(state)}

              error ->
                {:reply, error, fail_write(:output_ack_failed, state)}
            end

          {:error, _reason} ->
            {:reply, result, fail_write(:output_write_uncertain, state)}

          _ ->
            {:reply, {:error, :output_write_uncertain},
             fail_write(:output_write_uncertain, state)}
        end

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call(:stats, _from, state),
    do:
      {:reply,
       Map.merge(OutputLedger.stats(state.ledger), %{
         jobs: map_size(state.jobs),
         writes: :queue.len(state.writes),
         writing: not is_nil(state.writing)
       }), state}

  @impl true
  def handle_info(:reap, state) do
    state = state |> settle_http_returns() |> expire_write()
    expired = Enum.filter(state.jobs, fn {_token, job} -> job.deadline <= now() end)

    state =
      Enum.reduce(expired, state, fn {token, job}, state ->
        # Reap output credit independently. An uncommitted worker still has
        # the Scheduler's original request timer and terminal-failure path.
        # Do not originate a second failure from this scope cleanup timer.
        settle_failure(token, job, :output_expired, state)
        notify_stdio(job, token, {:error, :output_expired})
        remove_scope(job.scope, state)
      end)

    Process.send_after(self(), :reap, 20)
    {:noreply, state}
  end

  def handle_info({:arbor_mcp_output, generation, scope, :ready}, state) do
    if Initialization.ready?(state.table) and
         OutputLedger.stats(state.ledger).generation == generation do
      case Map.get(state.scopes, scope) do
        nil -> {:noreply, state}
        token -> {:noreply, deliver_ready(token, state.jobs[token], state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:arbor_mcp_output, _generation, scope, {:closed, reason}}, state) do
    case if(reason == :output_settled, do: nil, else: state.scopes[scope]) do
      nil ->
        {:noreply, state}

      token ->
        job = state.jobs[token]

        if state.writing && state.writing.token == token do
          {:noreply, fail_write(:output_write_uncertain, state)}
        else
          settle_failure(token, job, reason, state)
          notify_stdio(job, token, {:error, reason})
          {:noreply, remove_scope(scope, state)}
        end
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:noreply, %{retire_all(state, :connection_closed) | peer: nil, monitor: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  defp prepare_http_failure(token, binding, format, caller, proof, deadline, state) do
    scope = {:terminal, proof.generation, token}

    with :ok <- OutputLedger.open_scope(state.ledger, scope, deadline),
         :ok <- OutputLedger.subscribe(state.ledger, scope, self()),
         context = %{
           ledger: state.ledger,
           scope: scope,
           owner: self(),
           group: false,
           codec: :protocol,
           deadline: deadline,
           http: %{binding: binding, format: format, owner: self(), terminal: token}
         },
         response = failure_response(proof),
         {:ok, ticket} <- prepare(context, response),
         :ok <- OutputLedger.publish(ticket) do
      output = %{
        edge: caller,
        connection: binding,
        batch?: false,
        terminal?: true,
        http: %{binding: binding, format: format}
      }

      job = %{
        scope: scope,
        scheduler: nil,
        output: output,
        deadline: deadline,
        committed?: true,
        stdio?: false,
        http_ticket: nil,
        edge_ticket: ticket
      }

      state = %{
        state
        | jobs: Map.put(state.jobs, token, job),
          scopes: Map.put(state.scopes, scope, token)
      }

      {reply, state} = deliver_peer(ticket, job, state)

      case reply do
        :pending -> {:reply, :ok, state}
        error -> {:reply, error, remove_scope(scope, state)}
      end
    else
      _invalid ->
        OutputLedger.retire_scope(state.ledger, scope, :terminal_output_failed)
        {:reply, {:error, :http_failure_expired}, state}
    end
  end

  defp retire_job(token, state) do
    case state.jobs[token] do
      nil -> state
      job -> remove_scope(job.scope, state)
    end
  end

  defp connect_peer(connection, peer, transport, state, event_context \\ nil) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    state = retire_all(state, :connection_closed)
    peer = if peer, do: peer_context(connection, peer, transport, event_context), else: nil

    %{state | peer: peer, monitor: if(peer, do: Process.monitor(peer.pid), else: nil)}
  end

  defp peer_context(connection, peer, transport, event_context) do
    %{connection: connection, pid: peer, transport: transport, event_context: event_context}
  end

  defp send_peer(%{pid: peer, event_context: %{owner: peer, epoch: epoch}}, message),
    do: send(peer, {:client_lifetime_event, epoch, {:transport_message, message}})

  defp send_peer(%{pid: peer}, message), do: send(peer, {:transport_message, message})

  defp handle_ready_call({:register, token, output, owner}, {caller, _}, state) do
    with {:ok, route} <- Admission.route(state.table),
         [{_key, reservation}] <- :ets.lookup(state.table, {:reservation, token}),
         true <- reservation.generation == route.generation,
         {:ok, deadline} <- output_deadline(reservation, output, state),
         true <- terminal_output?(output) or not reservation.terminal,
         true <-
           deadline > now() and Process.alive?(reservation.owner) and Process.alive?(caller),
         true <- active_peer?(output, state),
         scope = output_scope(reservation, output),
         :ok <- OutputLedger.open_scope(state.ledger, scope, deadline),
         :ok <- OutputLedger.subscribe(state.ledger, scope, self()) do
      job = %{
        scope: scope,
        scheduler: owner,
        output: output,
        deadline: deadline,
        http_ticket: nil,
        edge_ticket: nil
      }

      job =
        job
        |> Map.put(:committed?, false)
        |> Map.put(
          :stdio?,
          is_nil(http_context(output, self())) and match?(%{transport: :stdio}, state.peer)
        )

      context = %{
        ledger: state.ledger,
        scope: scope,
        owner: owner,
        group: not is_nil(output) and output.batch?,
        codec: if(reservation.kind == :call, do: :term, else: :protocol),
        deadline: deadline
      }

      context =
        case http_context(output, self()) do
          nil -> context
          http -> Map.put(context, :http, http)
        end

      {:reply, {:ok, context},
       %{
         state
         | jobs: Map.put(state.jobs, token, job),
           scopes: Map.put(state.scopes, scope, token)
       }}
    else
      false -> {:reply, {:error, :output_expired}, state}
      [] -> {:reply, {:error, :output_expired}, state}
      error -> {:reply, error, state}
    end
  end

  defp handle_ready_call({:deliver, token, ticket}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, batch?: true}} = job ->
        # A member's ACK means staged handoff into the charged group. It is
        # deliberately distinct from terminal peer-mailbox handoff.
        case OutputLedger.value(ticket) do
          {:ok, _term} ->
            settle(job.scheduler, token, :ok)
            {:reply, :ok, state}

          error ->
            {:reply, error, state}
        end

      %{output: %{edge: ^caller}} = job ->
        {reply, state} = deliver_peer(ticket, job, state)
        complete_delivery(reply, token, job, state, true)

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  defp handle_ready_call({:edge_prepared, token, ticket}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, batch?: true}} ->
        reply =
          with :ok <- commit_edge_http(state.table, token, ticket), do: OutputLedger.hold(ticket)

        {:reply, reply, state}

      %{output: %{edge: ^caller}} = job ->
        state = update_in(state.jobs[token], &Map.put(&1, :edge_ticket, ticket))

        case with :ok <- commit_edge_http(state.table, token, ticket),
                  do: OutputLedger.publish(ticket) do
          :ok ->
            {reply, state} = deliver_peer(ticket, job, state)
            complete_delivery(reply, token, job, state, false)

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  defp handle_ready_call({:finish, token}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, batch?: true}} = job ->
        case OutputLedger.finish_group(state.ledger, job.scope) do
          {:ok, ticket} ->
            case final_http_ticket(job, token, ticket) do
              {:ok, ticket} ->
                {reply, state} = deliver_peer(ticket, job, state)
                complete_delivery(reply, token, job, state, false)

              error ->
                {:reply, error, remove_scope(job.scope, state)}
            end

          error ->
            {:reply, error, remove_scope(job.scope, state)}
        end

      nil ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  defp commit_edge_http(table, token, ticket) do
    if is_nil(OutputTicket.http(ticket)), do: :ok, else: mark_committed(table, token, ticket)
  end

  defp output_deadline(reservation, %{terminal?: true}, state) do
    generation = reservation.generation
    scope = reservation.scope
    caller = reservation.caller

    case :ets.lookup(state.table, {:output_failure, reservation.token}) do
      [{_, %{generation: ^generation, scope: ^scope, caller: ^caller, deadline: deadline}}] ->
        {:ok, deadline}

      _ ->
        {:error, :output_expired}
    end
  end

  defp output_deadline(reservation, _output, _state), do: {:ok, reservation.deadline}
  defp terminal_output?(%{terminal?: true}), do: true
  defp terminal_output?(_output), do: false

  defp active_peer?(
         %{notification?: true, source_token: source, edge: producer, http: %{binding: binding}},
         _state
       ),
       do: Process.alive?(producer) and HTTPWriterRegistry.source_valid?(binding, source)

  defp active_peer?(%{edge: edge, http: %{binding: binding}}, state) do
    root = :ets.info(state.table, :owner)

    match?({:ok, _}, HTTPWriterBinding.validate(binding, Ref.new(root, state.table))) and
      :ets.lookup(state.table, :http_gateway) == [{:http_gateway, edge}] and Process.alive?(edge)
  end

  defp active_peer?(nil, _state), do: true

  defp active_peer?(%{connection: connection, edge: edge}, state) do
    match?(%{connection: ^connection}, state.peer) and
      :ets.lookup(state.table, :edge_connection) == [{:edge_connection, edge, connection}]
  end

  defp http_context(%{http: %{binding: binding, format: format}}, owner),
    do: %{binding: binding, format: format, owner: owner}

  defp http_context(_output, _owner), do: nil

  defp deliver_ready(token, job, state) do
    if Map.has_key?(job, :write_deadline) or not is_nil(Map.get(job, :http_ticket)),
      do: state,
      else: checkout_ready(token, job, state)
  end

  defp checkout_ready(token, job, state) do
    case OutputLedger.checkout(state.ledger, job.scope) do
      {:ok, ticket, term, _wire} ->
        ticket = complete_ticket(token, ticket, job, state)

        if job.output do
          Admission.terminal(state.table, token, descriptor(ticket, term))
          put_in(state.jobs[token].committed?, true)
        else
          Admission.terminal(state.table, token, {:ok, term})
          result = OutputLedger.ack(ticket)
          settle(job.scheduler, token, result)
          remove_scope(job.scope, state)
        end

      error ->
        reason = delivery_failure(error, job)
        settle_failure(token, job, reason, state)
        remove_scope(job.scope, state)
    end
  end

  defp deliver_peer(ticket, %{output: %{http: _}} = job, state) do
    with true <- http_delivery_current?(job, ticket, state),
         true <- job.deadline > now(),
         {:ok, _current, _term, _wire} <- checkout_or_current(ticket, job.scope, state),
         :ok <- HTTPOutput.publish(ticket) do
      token = state.scopes[job.scope]
      {:pending, put_in(state.jobs[token].http_ticket, ticket)}
    else
      false -> {{:error, :output_expired}, state}
      error -> {error, state}
    end
  end

  defp deliver_peer(ticket, job, %{peer: %{transport: :stdio}} = state),
    do: queue_write(ticket, job, state)

  defp deliver_peer(ticket, job, state) do
    with %{connection: connection, pid: peer, transport: transport} <- state.peer,
         true <- connection == job.output.connection and Process.alive?(peer),
         true <- job.deadline > now(),
         {:ok, ^ticket, term, wire} <- checkout_or_current(ticket, job.scope, state) do
      message = if(transport == :beam, do: term, else: wire)
      send_peer(state.peer, message)
      {OutputLedger.ack(ticket), state}
    else
      false -> {{:error, :output_expired}, state}
      nil -> {{:error, :connection_closed}, state}
      error -> {error, state}
    end
  end

  defp http_delivery_current?(%{output: %{terminal?: true}}, ticket, _state),
    do: HTTPOutput.valid?(ticket)

  defp http_delivery_current?(job, _ticket, state), do: active_peer?(job.output, state)

  defp complete_delivery(:pending, _token, _job, state, _settle?), do: {:reply, :ok, state}

  defp complete_delivery(reply, token, job, state, settle?) do
    if settle?, do: settle(job.scheduler, token, reply)
    {:reply, reply, remove_scope(job.scope, state)}
  end

  defp queue_write(ticket, job, state) do
    with true <- active_peer?(job.output, state),
         true <- job.deadline > now(),
         {:ok, ^ticket, _term, wire} when is_binary(wire) <-
           checkout_or_current(ticket, job.scope, state) do
      token = state.scopes[job.scope]
      deadline = min(job.deadline, now() + state.output_timeout)
      job = Map.put(job, :write_deadline, deadline)

      state = %{
        state
        | jobs: Map.put(state.jobs, token, job),
          writes: :queue.in({token, ticket}, state.writes)
      }

      {:pending, start_write(state)}
    else
      false -> {{:error, :output_expired}, state}
      error -> {error, state}
    end
  end

  defp start_write(%{writing: writing} = state) when not is_nil(writing), do: state

  defp start_write(state) do
    case :queue.out(state.writes) do
      {{:value, {token, ticket}}, queue} ->
        state = %{state | writes: queue}

        case state.jobs[token] do
          %{write_deadline: deadline} ->
            if deadline > now() and valid_write_origin?(state.jobs[token], state) do
              send(state.peer.pid, {:stdio_write, ticket})

              %{
                state
                | writing: %{token: token, ticket: ticket, deadline: deadline, started?: false}
              }
            else
              job = state.jobs[token]
              settle_failure(token, job, :output_expired, state)
              notify_stdio(job, token, {:error, :output_expired})
              start_write(remove_scope(job.scope, state))
            end

          _ ->
            start_write(state)
        end

      {:empty, _} ->
        state
    end
  end

  defp register_control(token, connection, proof, origin, caller, state) do
    output = %{edge: caller, connection: connection, batch?: false, control?: true}

    with true <- Admission.output_origin_valid?(state.table, proof),
         true <- not :ets.member(state.table, :stdio_output_sealed),
         true <- active_peer?(output, state),
         deadline = Origin.deadline(origin, control_deadline(proof, state)),
         scope = {:control, connection, token, origin || proof},
         :ok <- OutputLedger.open_scope(state.ledger, scope, deadline),
         :ok <- OutputLedger.subscribe(state.ledger, scope, self()) do
      job = %{
        scope: scope,
        scheduler: caller,
        output: output,
        deadline: deadline,
        committed?: false,
        stdio?: true,
        source_proof: proof,
        source_origin: origin
      }

      context = %{
        ledger: state.ledger,
        scope: scope,
        owner: self(),
        group: false,
        codec: :protocol,
        deadline: deadline
      }

      {:reply, {:ok, context},
       %{
         state
         | jobs: Map.put(state.jobs, token, job),
           scopes: Map.put(state.scopes, scope, token)
       }}
    else
      false -> {:reply, {:error, :connection_closed}, state}
      error -> {:reply, error, state}
    end
  end

  defp control_origin(_table, nil, _caller), do: {:ok, nil}

  defp control_origin(table, token, caller),
    do: Admission.control_output_origin(table, token, caller)

  defp control_deadline(nil, state), do: now() + state.output_timeout
  defp control_deadline(proof, state), do: min(proof.deadline, now() + state.output_timeout)

  defp valid_write_origin?(job, state),
    do:
      active_peer?(job.output, state) and
        Admission.output_origin_valid?(state.table, Map.get(job, :source_proof)) and
        Origin.valid?(Map.get(job, :source_origin))

  defp reject_write(token, state) do
    job = state.jobs[token]
    settle_failure(token, job, :output_expired, state)
    notify_stdio(job, token, {:error, :output_expired})
    start_write(remove_scope(job.scope, %{state | writing: nil}))
  end

  defp expire_write(%{writing: nil} = state), do: state

  defp expire_write(state) do
    if state.writing.deadline <= now(),
      do:
        fail_write(
          if(state.writing.started?, do: :output_write_uncertain, else: :output_expired),
          state
        ),
      else: state
  end

  defp fail_write(reason, state) do
    if state.peer && state.peer.transport == :stdio do
      # The writer is explicitly runtime-owned. Its borrowed device is not.
      Process.exit(state.peer.pid, :kill)
      Admission.seal_input(state.table)

      case :ets.lookup(state.table, :edge) do
        [{:edge, edge}] -> send(edge, {:stdio_write_failed, state.peer.connection, reason})
        _ -> :ok
      end
    end

    state =
      Enum.reduce(Map.keys(state.jobs), state, fn token, state ->
        case state.jobs[token] do
          %{output: output} = job when not is_nil(output) and not is_map_key(output, :http) ->
            settle_failure(token, job, reason, state)
            notify_stdio(job, token, {:error, reason})
            remove_scope(job.scope, state)

          _ ->
            state
        end
      end)

    %{state | writes: :queue.new(), writing: nil}
  end

  defp notify_stdio(%{stdio?: true, output: %{edge: edge}}, token, result),
    do: send(edge, {:stdio_output_settled, token, result})

  defp notify_stdio(_job, _token, _result), do: :ok

  # An edge ticket was already checked out before its token was delivered.
  # Retrieve the immutable prepared wire through the ledger, not re-encoding.
  defp checkout_or_current(ticket, scope, state) do
    case OutputLedger.checkout(state.ledger, scope) do
      {:error, :output_credit_exhausted} -> OutputLedger.payload(ticket)
      result -> result
    end
  end

  defp complete_ticket(token, ticket, job, state) do
    paired =
      case :ets.lookup(state.table, {:output_commit, token}) do
        [{_, paired}] -> paired
        _ -> Map.get(job, :edge_ticket, ticket)
      end

    if OutputTicket.same?(ticket, paired), do: paired, else: ticket
  end

  defp final_http_ticket(%{output: %{http: %{binding: binding}}}, token, ticket) do
    with :ok <- HTTPWriterRegistry.finalize_batch(binding, token, ticket),
         do: HTTPOutput.finish_group(binding, ticket)
  end

  defp final_http_ticket(_job, _token, ticket), do: {:ok, ticket}

  defp settle_http_returns(state) do
    Enum.reduce(state.jobs, state, fn {token, job}, state ->
      case Map.get(job, :http_ticket) do
        nil ->
          state

        ticket ->
          case HTTPWriteTicket.receipt(OutputTicket.http(ticket)) do
            0 ->
              state

            result ->
              reply =
                if result == 1,
                  do: OutputLedger.ack(ticket),
                  else: {:error, :http_write_uncertain}

              settle(job.scheduler, token, reply)
              send(job.output.edge, {:http_output_settled, token, reply})
              remove_scope(job.scope, state)
          end
      end
    end)
  end

  defp descriptor(ticket, %{"error" => _}) do
    {:ok, %{"__runtime_output" => ticket, "error" => nil}}
  end

  defp descriptor(ticket, _term), do: {:ok, %{"__runtime_output" => ticket}}

  defp authorized_ticket?(ticket, caller, state) do
    case OutputTicket.address(ticket) do
      {:ok, _address} ->
        Enum.any?(state.jobs, fn {_token, job} ->
          match?(%{edge: ^caller}, job.output) and
            OutputTicket.validate_scope(ticket, job.scope) == :ok
        end)

      _invalid ->
        false
    end
  end

  defp output_scope(reservation, %{batch?: true}),
    do: {:batch, reservation.generation, reservation.token}

  defp output_scope(reservation, %{terminal?: true}),
    do: {:terminal, reservation.generation, reservation.token}

  defp output_scope(reservation, _output), do: {:work, reservation.generation, reservation.token}

  defp remove_scope(scope, state) do
    for {_token, job} <- state.jobs, job.scope == scope do
      case Map.get(job, :http_ticket) || Map.get(job, :edge_ticket) do
        nil -> :ok
        ticket -> HTTPOutput.release(ticket)
      end
    end

    OutputLedger.retire_scope(state.ledger, scope, :output_settled)

    for {token, job} <- state.jobs,
        job.scope == scope,
        do: :ets.delete(state.table, {:output_commit, token})

    %{
      state
      | scopes: Map.delete(state.scopes, scope),
        writing:
          if(
            state.writing && state.jobs[state.writing.token] &&
              state.jobs[state.writing.token].scope == scope,
            do: nil,
            else: state.writing
          ),
        writes:
          :queue.filter(
            fn {token, _ticket} ->
              case state.jobs[token] do
                %{scope: ^scope} -> false
                _ -> true
              end
            end,
            state.writes
          ),
        jobs: Map.reject(state.jobs, fn {_token, job} -> job.scope == scope end)
    }
  end

  defp retire_all(%{writing: %{started?: true}} = state, _reason),
    do: fail_write(:output_write_uncertain, state)

  defp retire_all(state, reason) do
    Enum.reduce(Map.keys(state.jobs), state, fn token, state ->
      case state.jobs[token] do
        nil ->
          state

        %{output: output} = job when not is_nil(output) and not is_map_key(output, :http) ->
          settle(job.scheduler, token, {:error, reason})
          OutputLedger.retire_scope(state.ledger, job.scope, reason)
          remove_scope(job.scope, state)

        _direct ->
          state
      end
    end)
  end

  defp settle(nil, _token, _result), do: :ok
  defp settle(pid, token, result), do: send(pid, {:runtime_output_settled, token, result})

  defp settle_failure(token, job, reason, state) do
    committed = committed?(token, job, state)

    if committed or match?(%{batch?: true}, job.output),
      do: mark_failure(state.table, token, reason)

    case Admission.current(state.table, token) do
      {:ok, %{terminal: false} = reservation} when committed ->
        Admission.terminal(state.table, token, Failure.result(reservation, reason))

      _ ->
        if committed or match?(%{batch?: true}, job.output),
          do: notify_failure(token, job, reason, state)
    end

    settle(job.scheduler, token, {:error, reason})
  end

  defp committed?(token, job, state) do
    job.committed? or
      case :ets.lookup(state.table, {:output_commit, token}) do
        [{_, ticket}] -> OutputTicket.validate_scope(ticket, job.scope) == :ok
        _ -> false
      end
  end

  defp delivery_failure({:error, reason}, job),
    do: if(job.deadline <= now(), do: :output_expired, else: reason)

  defp delivery_failure(_result, _job), do: :output_released

  defp failure_response(proof) do
    reason =
      if proof.reason in [:request_cancelled, :handler_timeout],
        do: proof.reason,
        else: :output_failed

    code = if reason == :request_cancelled, do: -32001, else: -32603

    message =
      case reason do
        :request_cancelled -> "Request cancelled"
        :handler_timeout -> "Request timeout"
        _failure -> "Internal server error"
      end

    Arbor.RPC.JSONRPC.error(proof.request_id, code, message, %{"type" => Atom.to_string(reason)})
  end

  defp notify_failure(token, %{output: %{http: _http, edge: edge}}, reason, _state),
    do: send(edge, {:arbor_mcp_runtime, token, {:error, reason}})

  defp notify_failure(_token, job, reason, state), do: notify_peer(job, reason, state)

  defp notify_peer(%{output: %{connection: connection}}, reason, %{
         peer: %{connection: connection, pid: peer}
       }),
       do: send(peer, {:transport_error, reason})

  defp notify_peer(_job, _reason, _state), do: :ok

  defp output_failure?(reason),
    do: String.starts_with?(Atom.to_string(reason), "output_") or reason == :invalid_output

  defp now, do: System.monotonic_time(:millisecond)
end
