defmodule Arbor.MCP.Server.Runtime.Scheduler do
  @moduledoc false

  use GenServer

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Failure,
    Lifecycle,
    Services,
    ShutdownGuard
  }

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)

    with {:ok, pid} <- GenServer.start_link(__MODULE__, opts, timeout: config.init_timeout_ms) do
      :ok = ShutdownGuard.watch(Keyword.fetch!(opts, :table), pid)
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
    :ok = ShutdownGuard.watch(table, self())

    with {:ok, handler_state} <- config.handler.init(config.handler_args),
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

  @impl true
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
            tracker_pending: false
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

        state =
          if state.work[token].tracker_pending,
            do: queue_tracker(state, token),
            else: remove_work(state, token)

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

    if function_exported?(state.config.handler, :terminate, 2) do
      state.config.handler.terminate(reason, state.handler_state)
    end

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
      runtime: Keyword.fetch!(work.opts, :runtime),
      owner: work.reservation.owner
    }

    task =
      Task.Supervisor.async_nolink(
        state.task_supervisor,
        fn ->
          invoke(invocation, work, config, snapshot)
        end,
        shutdown: config.cancel_grace_ms
      )

    %{
      state
      | tasks: Map.put(state.tasks, task.ref, token),
        work: Map.put(state.work, token, %{work | task: task})
    }
  rescue
    _exception -> state |> fail(token, :handler_start_failed) |> remove_work(token)
  catch
    :exit, _reason -> state |> fail(token, :handler_start_failed) |> remove_work(token)
  end

  defp complete(state, token, proposal) do
    work = Map.fetch!(state.work, token)

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

    case decision do
      :ignore ->
        state

      {:cancel, reason} ->
        cancel_work(state, token, reason)

      {:fail, reason} ->
        fail(state, token, reason)

      {:commit, result, next_state} ->
        state = Map.put(state, :handler_state, next_state)
        if work.phase == :tracker, do: state, else: mark_terminal(state, token, result)
    end
  end

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

      work.phase != :tracker and :ets.member(state.table, {:cancelled, work.reservation.token}) ->
        :request_cancelled

      now() >= work.reservation.deadline ->
        :handler_timeout

      true ->
        nil
    end
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
