defmodule Arbor.MCP.Server.Runtime.Scheduler do
  @moduledoc false

  use GenServer
  require Logger

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Failure,
    HTTPCancellation,
    HTTPOutput,
    Initialization,
    Lifecycle,
    OutputController,
    OutputLedger,
    Services,
    ShutdownGuard
  }

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)

    with {:ok, pid} <-
           GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(table)) do
      :ok = Initialization.watch(table, pid)
      {:ok, pid}
    end
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: config.shutdown_timeout_ms
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    table = Keyword.fetch!(opts, :table)
    :ok = Initialization.watch(table, self())

    with {:ok, handler_state} <- initialize_handler(config),
         {:ok, generation} <- Admission.activate(table, self(), config) do
      [{:callback_tasks, task_supervisor}] = :ets.lookup(table, :callback_tasks)

      {:ok,
       %{
         table: table,
         config: config,
         handler_state: handler_state,
         generation: generation,
         task_supervisor: task_supervisor,
         queue: :queue.new(),
         work: %{},
         tasks: %{},
         owners: %{}
       }}
    else
      {:error, reason} -> {:stop, {:handler_init_failed, reason}}
      _invalid -> {:stop, :invalid_handler_init}
    end
  end

  defp initialize_handler(config) do
    case config.handler.init(config.handler_args) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, :callback_error}
      _invalid -> :invalid_handler_init
    end
  rescue
    _exception -> {:error, :callback_error}
  catch
    _kind, _reason -> {:error, :callback_error}
  end

  @impl true
  def handle_info({:http_cancel, generation, token, phase}, state) do
    case HTTPCancellation.take(state.table, token, generation, phase) do
      {:ok, source} when generation == state.generation ->
        state =
          Enum.reduce(state.work, state, fn {target_token, work}, current ->
            if target_token != token and work.request["method"] != "initialize" and
                 HTTPCancellation.target?(state.table, source, work.reservation),
               do: cancel_work(current, target_token, :request_cancelled),
               else: current
          end)

        case Admission.cancel_http_future(state.table, token, generation, phase, source.deadline) do
          :not_queued -> send(self(), {:http_future_cancel_settled, token, generation, phase})
          _queued_or_uncertain -> :ok
        end

        {:noreply, state}

      {:expired, source} when generation == state.generation ->
        send(source.owner, {:http_cancel_settled, token, phase, {:error, :handler_timeout}})
        {:noreply, state}

      _retired ->
        {:noreply, state}
    end
  end

  def handle_info({:http_future_cancel_settled, token, generation, phase}, state) do
    if generation == state.generation do
      case HTTPCancellation.complete(state.table, token, generation, phase) do
        {:ok, source} -> send(source.owner, {:http_cancel_settled, token, phase, :notification})
        _retired -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_info({:submit, generation, token, request, opts}, state) do
    if generation == state.generation do
      case Admission.bind(state.table, token) do
        {:ok, reservation} ->
          owner_ref = Process.monitor(reservation.owner)
          remaining = max(0, reservation.deadline - now())
          deadline_timer = Process.send_after(self(), {:deadline, generation, token}, remaining)

          work = %{
            reservation: reservation,
            request: request,
            opts: opts,
            owner_ref: owner_ref,
            deadline_timer: deadline_timer,
            kill_timer: nil,
            task: nil,
            terminal: false,
            phase: :callback,
            tracker_pending: false,
            output: nil,
            delivery_pending: false,
            worker_down: false
          }

          state = %{
            state
            | work: Map.put(state.work, token, work),
              owners: Map.put(state.owners, owner_ref, token),
              queue: :queue.in(token, state.queue)
          }

          {:noreply, start_available(state)}

        {:error, _reason} ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, proposal}, state) when is_reference(ref) do
    case Map.get(state.tasks, ref) do
      nil -> {:noreply, state}
      token -> {:noreply, complete(state, token, proposal)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.tasks, ref) ->
        token = Map.fetch!(state.tasks, ref)
        state = if state.work[token].terminal, do: state, else: fail(state, token, :handler_crash)

        cleanup_worker_output(state, token)

        state = put_in(state.work[token].worker_down, true)

        state =
          cond do
            state.work[token].delivery_pending -> state
            state.work[token].tracker_pending -> queue_tracker(state, token)
            true -> remove_work(state, token)
          end

        {:noreply, start_available(state)}

      Map.has_key?(state.owners, ref) ->
        token = Map.fetch!(state.owners, ref)

        if state.work[token].phase == :tracker and state.work[token].task do
          Process.exit(state.work[token].task.pid, :kill)
          {:noreply, state}
        else
          {:noreply, cancel_work(state, token, :owner_down)}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:runtime_output_settled, token, _result}, state) do
    case state.work[token] do
      %{delivery_pending: true} = work ->
        state = put_in(state.work[token].delivery_pending, false)
        state = if work.worker_down, do: remove_work(state, token), else: state
        {:noreply, start_available(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:deadline, generation, token}, state) do
    if generation == state.generation do
      case Map.get(state.work, token) do
        %{phase: :tracker, task: %Task{pid: pid}} ->
          Process.exit(pid, :kill)
          {:noreply, state}

        _ ->
          {:noreply, cancel_work(state, token, :handler_timeout)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:kill, generation, token}, state) do
    if generation == state.generation do
      case Map.get(state.work, token) do
        %{task: %Task{pid: pid}, terminal: true} -> Process.exit(pid, :kill)
        _ -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cleanup_worker_output(state, token) do
    work = state.work[token]

    if work.terminal and not work.delivery_pending and work.phase != :tracker and work.output,
      do: OutputController.failed(state.table, token, :handler_crash)
  end

  @impl true
  def handle_call({:cancel, generation, key}, _from, state) do
    if generation == state.generation do
      case Admission.find(state.table, key) do
        %{token: _token} = reservation ->
          {:reply, :ok, cancel_key(state, reservation, key)}

        _ ->
          {:reply, :ok, state}
      end
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       active: map_size(state.tasks),
       queued: :queue.len(state.queue),
       generation: state.generation
     }, state}
  end

  defp cancel_key(state, reservation, key) do
    token = reservation.token

    case Map.get(state.work, token) do
      %{reservation: %{key: ^key}, request: %{"method" => "initialize"}} ->
        state

      %{reservation: %{key: ^key}} ->
        cancel_work(state, token, :request_cancelled)

      _work when reservation.stage != :direct ->
        {_scope, _direction, id} = key
        Admission.cancel_ingress(state.table, token, id)
        state

      _work ->
        Admission.terminal(state.table, token, Failure.result(reservation, :request_cancelled))
        Admission.release(state.table, token)
        state
    end
  end

  @impl true
  def terminate(reason, state) do
    for {token, work} <- state.work do
      :ets.insert(state.table, {{:cancelled, token}, true})
      if work.task, do: Process.exit(work.task.pid, :shutdown)
    end

    Admission.close(
      state.table,
      if(ShutdownGuard.closing?(state.table) or reason == :normal,
        do: :runtime_stopped,
        else: :runtime_restarted
      )
    )

    terminate_handler(reason, state)
  end

  defp terminate_handler(reason, state) do
    if function_exported?(state.config.handler, :terminate, 2),
      do: state.config.handler.terminate(reason, state.handler_state)

    :ok
  rescue
    _exception -> termination_failed()
  catch
    _kind, _reason -> termination_failed()
  end

  defp termination_failed do
    Logger.error("MCP handler termination failed")
    :ok
  end

  defp start_available(state) do
    if map_size(state.tasks) < state.config.max_concurrency do
      case :queue.out(state.queue) do
        {:empty, _queue} ->
          state

        {{:value, token}, queue} ->
          state = %{state | queue: queue}
          work = Map.fetch!(state.work, token)

          case start_failure(state, work) do
            nil ->
              state |> start_task(token, work) |> start_available()

            :request_cancelled ->
              state |> cancel_work(token, :request_cancelled) |> start_available()

            reason ->
              state |> fail(token, reason) |> remove_work(token) |> start_available()
          end
      end
    else
      state
    end
  end

  defp start_task(state, token, work) do
    snapshot = state.handler_state
    config = state.config

    invocation = %{
      table: state.table,
      token: token,
      generation: state.generation,
      deadline: work.reservation.deadline,
      scope: work.reservation.scope,
      output_phase: work.reservation.output_phase,
      runtime: Keyword.fetch!(work.opts, :runtime),
      owner: work.reservation.owner,
      scheduler: self()
    }

    task =
      Task.Supervisor.async_nolink(
        state.task_supervisor,
        fn ->
          output =
            if reply_needed?(work),
              do:
                OutputController.register(
                  state.table,
                  token,
                  Keyword.get(work.opts, :output),
                  invocation.scheduler
                ),
              else: {:ok, nil}

          case output do
            {:ok, output} ->
              proposal = invoke(invocation, work, config, snapshot)
              prepare_proposal(proposal, invocation, work, config, snapshot, output)

            {:error, reason} ->
              {:output_failure, reason}
          end
        end,
        shutdown: config.cancel_grace_ms
      )

    output =
      if reply_needed?(work),
        do: %{group: match?(%{batch?: true}, Keyword.get(work.opts, :output))},
        else: nil

    %{
      state
      | tasks: Map.put(state.tasks, task.ref, token),
        work: Map.put(state.work, token, %{work | task: task, output: output})
    }
  rescue
    _exception -> state |> fail(token, :handler_start_failed) |> remove_work(token)
  catch
    :exit, _reason -> state |> fail(token, :handler_start_failed) |> remove_work(token)
  end

  defp complete(state, token, proposal) do
    work = Map.fetch!(state.work, token)
    {proposal, ticket} = restore_proposal(proposal)

    context = %{
      terminal: if(work.phase == :tracker, do: false, else: work.terminal),
      deadline: work.reservation.deadline,
      request_id: work.reservation.request_id,
      kind: if(work.phase == :tracker, do: :cast, else: work.reservation.kind),
      execution: state.config.execution,
      state: state.handler_state
    }

    decision =
      cond do
        ShutdownGuard.closing?(state.table) -> {:cancel, :runtime_stopped}
        not Process.alive?(work.reservation.owner) -> {:cancel, :owner_down}
        true -> Lifecycle.complete(context, proposal, now())
      end

    apply_completion(state, token, ticket, decision)
  end

  defp apply_completion(state, _token, ticket, :ignore) do
    release_ticket(ticket)
    state
  end

  defp apply_completion(state, token, ticket, {:cancel, reason}) do
    release_ticket(ticket)
    cancel_work(state, token, reason)
  end

  defp apply_completion(state, token, ticket, {:fail, reason}) do
    release_ticket(ticket)
    fail(state, token, reason)
  end

  defp apply_completion(state, token, ticket, {:commit, result, next_state}) do
    state = Map.put(state, :handler_state, next_state)

    cond do
      state.work[token].phase == :tracker -> state
      ticket -> publish_committed(state, token, ticket)
      true -> mark_terminal(state, token, result)
    end
  end

  defp release_ticket(nil), do: :ok
  defp release_ticket(ticket), do: HTTPOutput.release_all(ticket)

  defp publish_committed(state, token, ticket) do
    work = state.work[token]
    state = put_in(state.work[token].terminal, true)
    state = put_in(state.work[token].delivery_pending, true)

    result =
      with :ok <- OutputController.mark_committed(state.table, token, ticket) do
        if work.output.group do
          with :ok <- OutputLedger.hold(ticket),
               do: OutputController.held(state.table, token, ticket)
        else
          OutputLedger.publish(ticket)
        end
      end

    case result do
      :ok ->
        state

      {:error, reason} ->
        OutputController.mark_failure(state.table, token, reason)
        Admission.terminal(state.table, token, Failure.result(work.reservation, reason))
        OutputController.retire(state.table, token, reason)
        put_in(state.work[token].delivery_pending, false)
    end
  end

  defp restore_proposal({:prepared, kind, next_state, ticket}) do
    if HTTPOutput.valid?(ticket) do
      case OutputLedger.value(ticket) do
        {:ok, value} -> {{kind, value, next_state}, ticket}
        {:error, reason} -> {{:output_failure, reason}, ticket}
      end
    else
      {{:output_failure, :http_output_expired}, ticket}
    end
  end

  defp restore_proposal(proposal), do: {proposal, nil}

  defp prepare_proposal(proposal, _invocation, _work, _config, _snapshot, nil), do: proposal

  defp prepare_proposal(proposal, invocation, work, config, snapshot, output) do
    context = %{
      terminal: false,
      deadline: invocation.deadline,
      request_id: work.reservation.request_id,
      kind: work.reservation.kind,
      execution: config.execution,
      state: snapshot
    }

    case Lifecycle.complete(context, proposal, now()) do
      {:commit, {:ok, value}, next_state} ->
        case OutputController.prepare(output, value) do
          {:ok, ticket} -> {:prepared, elem(proposal, 0), next_state, ticket}
          {:error, reason} -> {:output_failure, reason}
        end

      _ ->
        proposal
    end
  end

  defp reply_needed?(%{phase: :tracker}), do: false
  defp reply_needed?(%{reservation: %{kind: :call}}), do: true
  defp reply_needed?(%{reservation: %{kind: :rpc, request_id: id}}), do: not is_nil(id)
  defp reply_needed?(_), do: false

  defp cancel_work(state, token, reason) do
    case Map.get(state.work, token) do
      nil ->
        state

      %{terminal: true} ->
        state

      %{task: nil} ->
        state = fail(state, token, reason)

        state =
          if tracker_needed?(state, reason),
            do: queue_tracker(state, token),
            else: remove_work(state, token)

        start_available(state)

      work ->
        :ets.insert(state.table, {{:cancelled, token}, true})
        send(work.task.pid, {:arbor_mcp_cancelled, token, reason})

        timer =
          Process.send_after(
            self(),
            {:kill, state.generation, token},
            state.config.cancel_grace_ms
          )

        state = put_in(state.work[token].kill_timer, timer)
        state = put_in(state.work[token].tracker_pending, tracker_needed?(state, reason))
        fail(state, token, reason)
    end
  end

  defp fail(state, token, reason) do
    work = Map.fetch!(state.work, token)
    OutputController.mark_failure(state.table, token, reason)
    if work.output, do: OutputController.failed(state.table, token, reason)
    mark_terminal(state, token, Failure.result(work.reservation, reason))
  end

  defp mark_terminal(state, token, result) do
    work = Map.fetch!(state.work, token)
    if work.deadline_timer, do: Process.cancel_timer(work.deadline_timer)
    Admission.terminal(state.table, token, result)
    put_in(state.work[token].terminal, true)
  end

  defp remove_work(state, token) do
    case Map.pop(state.work, token) do
      {nil, _work} ->
        state

      {work, remaining} ->
        Process.demonitor(work.owner_ref, [:flush])
        if work.deadline_timer, do: Process.cancel_timer(work.deadline_timer)
        if work.kill_timer, do: Process.cancel_timer(work.kill_timer)
        if work.task, do: Process.demonitor(work.task.ref, [:flush])

        if Keyword.get(work.opts, :retain_reservation, false) do
          Admission.release_step(state.table, token)
        else
          :ets.delete(state.table, {:output_failure, token})
          :ets.delete(state.table, {:output_commit, token})
          Admission.release(state.table, token)
        end

        tasks = if work.task, do: Map.delete(state.tasks, work.task.ref), else: state.tasks
        queue = :queue.filter(&(&1 != token), state.queue)

        %{
          state
          | work: remaining,
            tasks: tasks,
            owners: Map.delete(state.owners, work.owner_ref),
            queue: queue
        }
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp invoke(invocation, work, config, snapshot) do
    :ok = ShutdownGuard.watch(invocation.table, self())

    CallbackContext.with_context(invocation, fn ->
      dispatch_opts =
        Keyword.merge(config.dispatch_opts, Keyword.get(work.opts, :dispatch_opts, []))

      service_options =
        if work.phase == :callback and work.reservation.kind == :rpc,
          do: Services.dispatch_options(invocation.runtime, dispatch_opts),
          else: {:ok, dispatch_opts}

      case service_options do
        {:ok, dispatch_opts} ->
          dispatcher = config.dispatcher

          case {work.phase, work.reservation.kind} do
            {:tracker, _kind} ->
              {:noreply,
               config.cancellation_tracker.mark_cancelled(work.reservation.request_id, snapshot)}

            {:callback, :call} ->
              if function_exported?(config.handler, :handle_call, 3),
                do: invoke_custom_call(config.handler, work, snapshot),
                else: {:reply, {:error, {:unknown_call, work.request["payload"]}}, snapshot}

            {:callback, :cast} ->
              if function_exported?(config.handler, :handle_cast, 2),
                do: config.handler.handle_cast(work.request["payload"], snapshot),
                else: {:noreply, snapshot}

            {:callback, :rpc} ->
              dispatcher.dispatch(work.request, config.handler, snapshot, dispatch_opts)
          end

        {:error, _reason} ->
          {:runtime_failure, :handler_crash}
      end
    end)
  rescue
    _exception -> {:runtime_failure, :handler_crash}
  catch
    _kind, _reason -> {:runtime_failure, :handler_crash}
  end

  # OTP gen.reply/2 routes alias tags using this intentional improper list.
  # Mirror gen.do_send_request/3's targeted annotation; callback reply payloads
  # and every other function retain normal Dialyzer checks.
  @dialyzer {:no_improper_lists, invoke_custom_call: 3}
  defp invoke_custom_call(handler, work, snapshot) do
    reply_alias = :erlang.alias()
    from = {work.reservation.caller, [:alias | reply_alias]}

    try do
      handler.handle_call(work.request["payload"], from, snapshot)
    after
      # Deferred replies cannot bypass the scheduler's state commit. The tag
      # addresses this callback worker, never the original caller's mailbox.
      :erlang.unalias(reply_alias)
    end
  end

  defp start_failure(state, work) do
    cond do
      ShutdownGuard.closing?(state.table) ->
        :runtime_stopped

      not Process.alive?(work.reservation.owner) ->
        :owner_down

      work.phase != :tracker and cancelled_before_start?(state.table, work) ->
        :request_cancelled

      now() >= work.reservation.deadline ->
        :handler_timeout

      true ->
        nil
    end
  end

  defp cancelled_before_start?(table, work) do
    :ets.member(table, {:cancelled, work.reservation.token}) or
      HTTPCancellation.cancelled_member?(table, work.reservation.token, work.request["id"])
  end

  defp tracker_needed?(state, reason),
    do: reason == :request_cancelled and not is_nil(state.config.cancellation_tracker)

  defp queue_tracker(state, token) do
    work = Map.fetch!(state.work, token)
    if work.task, do: Process.demonitor(work.task.ref, [:flush])
    if work.kill_timer, do: Process.cancel_timer(work.kill_timer)
    tasks = if work.task, do: Map.delete(state.tasks, work.task.ref), else: state.tasks
    deadline = now() + state.config.request_timeout_ms

    timer =
      Process.send_after(
        self(),
        {:deadline, state.generation, token},
        state.config.request_timeout_ms
      )

    work = %{
      work
      | task: nil,
        phase: :tracker,
        tracker_pending: false,
        kill_timer: nil,
        deadline_timer: timer,
        reservation: %{work.reservation | deadline: deadline}
    }

    queue = :queue.filter(&(&1 != token), state.queue) |> then(&:queue.in(token, &1))
    %{state | tasks: tasks, work: Map.put(state.work, token, work), queue: queue}
  end
end
