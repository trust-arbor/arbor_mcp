defmodule Arbor.MCP.Server.Runtime.OutputController do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Admission, Failure, OutputLedger, OutputTicket, ShutdownGuard}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }

  def register(table, token, output \\ nil, owner \\ self()),
    do: call(table, {:register, token, output, owner})

  def result(table, ticket), do: call(table, {:result, ticket})
  def deliver(table, token, ticket), do: call(table, {:deliver, token, ticket})
  def held(table, token, ticket), do: call(table, {:held, token, ticket})
  def finish(table, token), do: call(table, {:finish, token})
  def retire(table, token, reason), do: call(table, {:retire, token, reason})
  def failed(table, token, reason), do: call(table, {:failed, token, reason})

  def connect(table, connection, peer, transport),
    do: call(table, {:connect, connection, peer, transport})

  def stats(table), do: call(table, :stats)

  def mark_committed(table, token, ticket) do
    # Fixed-size publication proof is visible even while this Controller is
    # suspended. It carries no response term and never extends the deadline.
    :ets.insert(table, {{:output_commit, token}, ticket})
    :ok
  end

  def mark_failure(table, token, reason) do
    with [{_key, reservation}] <- :ets.lookup(table, {:reservation, token}),
         [{:output_failure_timeout, timeout}] <- :ets.lookup(table, :output_failure_timeout) do
      proof = %{
        generation: reservation.generation,
        scope: reservation.scope,
        caller: reservation.caller,
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
    with {:ok, ticket} <-
           OutputLedger.prepare(context.ledger, value,
             scope: context.scope,
             owner: context.owner,
             deadline: context.deadline,
             codec: context.codec,
             group: context.group
           ),
         :ok <- OutputLedger.handoff(ticket),
         do: {:ok, ticket}
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
    :ok = ShutdownGuard.watch(table, self())
    :ets.match_delete(table, {{:output_commit, :_}, :_})

    limits = [
      max_frame_bytes: config.max_output_frame_bytes,
      max_term_bytes: config.max_output_term_bytes,
      max_output_bytes: config.max_output_bytes,
      max_output_frames: config.max_output_frames,
      max_scope_bytes: config.max_output_scope_bytes,
      call_timeout_ms: config.output_timeout_ms
    ]

    with {:ok, ledger} <- OutputLedger.start_link([owner: self()] ++ limits),
         {:ok, ref} <- OutputLedger.ref(ledger) do
      :ok = ShutdownGuard.watch(table, ledger)
      :ets.insert(table, {:output_controller, self()})
      :ets.insert(table, {:output_failure_timeout, config.output_timeout_ms})
      Process.send_after(self(), :reap, 20)
      state = %{table: table, ledger: ref, jobs: %{}, scopes: %{}, peer: nil, monitor: nil}

      state =
        case :ets.lookup(table, :output_peer) do
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
  def handle_call({:register, token, output, owner}, {caller, _}, state) do
    with [{_key, reservation}] <- :ets.lookup(state.table, {:reservation, token}),
         {:ok, deadline} <- output_deadline(reservation, output, state),
         true <- terminal_output?(output) or not reservation.terminal,
         true <-
           deadline > now() and Process.alive?(reservation.owner) and Process.alive?(caller),
         true <- active_peer?(output, state),
         scope = output_scope(reservation, output),
         :ok <- OutputLedger.open_scope(state.ledger, scope, deadline),
         :ok <- OutputLedger.subscribe(state.ledger, scope, self()) do
      job = %{scope: scope, scheduler: owner, output: output, deadline: deadline}
      job = Map.put(job, :committed?, false)

      context = %{
        ledger: state.ledger,
        scope: scope,
        owner: owner,
        group: not is_nil(output) and output.batch?,
        codec: if(reservation.kind == :call, do: :term, else: :protocol),
        deadline: deadline
      }

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

  def handle_call({:deliver, token, ticket}, {caller, _}, state) do
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
        settle(job.scheduler, token, reply)
        {:reply, reply, remove_scope(job.scope, state)}

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call({:edge_prepared, token, ticket}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, batch?: true}} ->
        {:reply, OutputLedger.hold(ticket), state}

      %{output: %{edge: ^caller}} = job ->
        case OutputLedger.publish(ticket) do
          :ok ->
            {reply, state} = deliver_peer(ticket, job, state)
            {:reply, reply, remove_scope(job.scope, state)}

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :invalid_output_owner}, state}
    end
  end

  def handle_call({:finish, token}, {caller, _}, state) do
    case state.jobs[token] do
      %{output: %{edge: ^caller, batch?: true}} = job ->
        case OutputLedger.finish_group(state.ledger, job.scope) do
          {:ok, ticket} ->
            {reply, state} = deliver_peer(ticket, job, state)
            {:reply, reply, remove_scope(job.scope, state)}

          error ->
            {:reply, error, remove_scope(job.scope, state)}
        end

      nil ->
        {:reply, :ok, state}

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
        notify_peer(job, reason, state)
        OutputLedger.retire_scope(state.ledger, job.scope, reason)
        settle(job.scheduler, token, {:error, reason})
        {:reply, :ok, remove_scope(job.scope, state)}
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

  def handle_call({:connect, connection, peer, transport}, _from, state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    state = retire_all(state, :connection_closed)
    peer = if peer, do: %{connection: connection, pid: peer, transport: transport}, else: nil

    {:reply, :ok,
     %{state | peer: peer, monitor: if(peer, do: Process.monitor(peer.pid), else: nil)}}
  end

  def handle_call(:stats, _from, state),
    do:
      {:reply, Map.merge(OutputLedger.stats(state.ledger), %{jobs: map_size(state.jobs)}), state}

  @impl true
  def handle_info(:reap, state) do
    expired = Enum.filter(state.jobs, fn {_token, job} -> job.deadline <= now() end)

    state =
      Enum.reduce(expired, state, fn {token, job}, state ->
        # Reap output credit independently. An uncommitted worker still has
        # the Scheduler's original request timer and terminal-failure path.
        # Do not originate a second failure from this scope cleanup timer.
        settle_failure(token, job, :output_expired, state)
        remove_scope(job.scope, state)
      end)

    Process.send_after(self(), :reap, 20)
    {:noreply, state}
  end

  def handle_info({:arbor_mcp_output, generation, scope, :ready}, state) do
    if OutputLedger.stats(state.ledger).generation == generation do
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
        settle_failure(token, job, reason, state)
        {:noreply, remove_scope(scope, state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:noreply, %{retire_all(state, :connection_closed) | peer: nil, monitor: nil}}

  def handle_info(_message, state), do: {:noreply, state}

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
  defp active_peer?(nil, _state), do: true

  defp active_peer?(%{connection: connection, edge: edge}, state) do
    match?(%{connection: ^connection}, state.peer) and
      :ets.lookup(state.table, :edge_connection) == [{:edge_connection, edge, connection}]
  end

  defp deliver_ready(token, job, state) do
    case OutputLedger.checkout(state.ledger, job.scope) do
      {:ok, ticket, term, _wire} ->
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

  defp deliver_peer(ticket, job, state) do
    with %{connection: connection, pid: peer, transport: transport} <- state.peer,
         true <- connection == job.output.connection and Process.alive?(peer),
         true <- job.deadline > now(),
         {:ok, ^ticket, term, wire} <- checkout_or_current(ticket, job.scope, state) do
      message = if(transport == :beam, do: term, else: wire)
      send(peer, {:transport_message, message})
      {OutputLedger.ack(ticket), state}
    else
      false -> {{:error, :output_expired}, state}
      nil -> {{:error, :connection_closed}, state}
      error -> {error, state}
    end
  end

  # An edge ticket was already checked out before its token was delivered.
  # Retrieve the immutable prepared wire through the ledger, not re-encoding.
  defp checkout_or_current(ticket, scope, state) do
    case OutputLedger.checkout(state.ledger, scope) do
      {:error, :output_credit_exhausted} -> OutputLedger.payload(ticket)
      result -> result
    end
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
    OutputLedger.retire_scope(state.ledger, scope, :output_settled)

    for {token, job} <- state.jobs,
        job.scope == scope,
        do: :ets.delete(state.table, {:output_commit, token})

    %{
      state
      | scopes: Map.delete(state.scopes, scope),
        jobs: Map.reject(state.jobs, fn {_token, job} -> job.scope == scope end)
    }
  end

  defp retire_all(state, reason) do
    Enum.reduce(Map.keys(state.jobs), state, fn token, state ->
      case state.jobs[token] do
        nil ->
          state

        %{output: output} = job when not is_nil(output) ->
          settle(job.scheduler, token, {:error, reason})
          OutputLedger.retire_scope(state.ledger, job.scope, reason)
          remove_scope(job.scope, state)

        _direct ->
          state
      end
    end)
  end

  defp settle(pid, token, result), do: send(pid, {:runtime_output_settled, token, result})

  defp settle_failure(token, job, reason, state) do
    committed = committed?(token, job, state)

    case Admission.current(state.table, token) do
      {:ok, %{terminal: false} = reservation} when committed ->
        mark_failure(state.table, token, reason)
        Admission.terminal(state.table, token, Failure.result(reservation, reason))

      _ ->
        if committed or match?(%{batch?: true}, job.output), do: notify_peer(job, reason, state)
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

  defp notify_peer(%{output: %{connection: connection}}, reason, %{
         peer: %{connection: connection, pid: peer}
       }),
       do: send(peer, {:transport_error, reason})

  defp notify_peer(_job, _reason, _state), do: :ok

  defp output_failure?(reason),
    do: String.starts_with?(Atom.to_string(reason), "output_") or reason == :invalid_output

  defp now, do: System.monotonic_time(:millisecond)
end
