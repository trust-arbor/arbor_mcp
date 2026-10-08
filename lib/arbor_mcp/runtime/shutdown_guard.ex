defmodule Arbor.MCP.Server.Runtime.ShutdownGuard do
  @moduledoc false

  # This runtime-owned peer intentionally survives its root supervisor. Every
  # PID it may kill is explicitly registered as an owned child/task. It never
  # follows process links, and exits after the root and owned descendants do.
  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, ServiceStartup, ShutdownControl}

  def start(supervisor, table, config) do
    with {:ok, control} <- ShutdownControl.start(supervisor, table, config) do
      constructor = fn -> {supervisor, table, config, control} end

      GenServer.start(__MODULE__, constructor,
        timeout: ShutdownControl.startup_timeout(table, config)
      )
    end
  end

  def watch(table, pid, type \\ :worker) do
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)

    with :ok <- Initialization.track(table, pid),
         :ok <- GenServer.call(guard, {:watch, pid}) do
      watch_children(table, pid, type)
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  def watch(table, pid, type, deadline) do
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)

    with :ok <- Initialization.track(table, pid),
         :ok <- startup_call(guard, {:watch, pid}, deadline),
         :ok <- watch_children(table, pid, type, deadline),
         true <- Deadline.now() < deadline do
      :ok
    else
      false -> {:error, :service_start_timeout}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :service_start_timeout}
  end

  def stop(table, reason),
    do: Arbor.MCP.Server.Runtime.stop(:ets.info(table, :owner), reason)

  # Owned edges publish the same fixed stop record without waiting for their
  # own root. The original cutoff is enforced independently of this mailbox.
  def request_stop(table, reason), do: ShutdownControl.request(table, reason)

  def begin_drain(table, edge, connection, deadline) do
    case :ets.lookup(table, :shutdown_guard) do
      [{:shutdown_guard, guard}] ->
        GenServer.cast(guard, {:begin_drain, edge, connection, deadline})

      _ ->
        {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def closing?(table) do
    :ets.member(table, :closing)
  rescue
    ArgumentError -> true
  end

  def owned_spec(child, table) do
    spec = Supervisor.child_spec(child, [])

    Map.put(
      spec,
      :start,
      {__MODULE__, :start_owned, [spec.start, table, Map.get(spec, :type, :worker)]}
    )
  end

  def start_owned({module, function, args}, table, type) do
    case apply(module, function, args) do
      {:ok, pid} = result ->
        :ok = Initialization.watch(table, pid, type)
        result

      {:ok, pid, _extra} = result ->
        :ok = Initialization.watch(table, pid, type)
        result

      result ->
        result
    end
  end

  @impl true
  def init(constructor) do
    {supervisor, table, config, control} = constructor.()
    :ok = Initialization.track(table, self(), :guard)
    :ok = ShutdownControl.bind_guard(table, self())

    {:ok,
     %{
       root: supervisor,
       root_monitor: Process.monitor(supervisor),
       root_down: false,
       table: table,
       budget: config.shutdown_timeout_ms,
       control_monitor: Process.monitor(ShutdownControl.observer(control)),
       children: %{},
       monitors: %{},
       phase: :running,
       timer: nil,
       timer_deadline: nil,
       stopper: nil
     }}
  end

  @impl true
  def handle_call({:watch, pid}, _from, %{phase: :running} = state) do
    {:reply, :ok, watch_pid(state, pid)}
  end

  def handle_call({:watch, pid}, _from, state) do
    Process.exit(pid, :kill)
    {:reply, {:error, :runtime_stopped}, watch_pid(state, pid)}
  end

  @impl true
  def handle_cast({:begin_drain, edge, connection, deadline}, %{phase: :running} = state) do
    if :ets.lookup(state.table, :edge_connection) == [{:edge_connection, edge, connection}] and
         is_integer(deadline) do
      case Map.get(state, :drain) do
        %{connection: ^connection} ->
          {:noreply, state}

        _ ->
          ref = make_ref()

          Process.send_after(
            self(),
            {:drain_deadline, ref},
            min(4_294_967_295, Deadline.remaining(deadline))
          )

          {:noreply, Map.put(state, :drain, %{id: ref, edge: edge, connection: connection})}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast({:begin_drain, _edge, _connection, _deadline}, state), do: {:noreply, state}

  @impl true
  def handle_info(:shutdown_control, state), do: {:noreply, control_shutdown(state)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{control_monitor: monitor} = state) do
    ShutdownControl.failure(state.table)
    force_children(state)
    {:noreply, %{state | phase: :cleanup}}
  end

  def handle_info({:drain_deadline, ref}, %{phase: :running, drain: %{id: ref} = drain} = state) do
    if :ets.lookup(state.table, :edge_connection) == [
         {:edge_connection, drain.edge, drain.connection}
       ],
       do: {:noreply, request_shutdown(state, {:shutdown, :stdio_eof_timeout})},
       else: {:noreply, Map.put(state, :drain, nil)}
  end

  def handle_info({:drain_deadline, _ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{root_monitor: monitor} = state) do
    state = %{state | root_down: true, phase: :cleanup}
    force_children(state)
    finish_or_wait(state)
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {pid, monitors} ->
        retire_owned(state.table, pid)
        state = %{state | monitors: monitors, children: Map.delete(state.children, pid)}
        finish_or_wait(state)
    end
  end

  def handle_info(:shutdown_deadline, state) do
    if not state.root_down, do: Process.exit(state.root, :kill)
    force_children(state)
    finish_or_wait(%{state | phase: :cleanup})
  end

  defp begin_shutdown(state, deadline) do
    if is_nil(state.timer_deadline) or deadline < state.timer_deadline do
      close_route(state.table)
      if state.timer, do: Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), :shutdown_deadline, Deadline.remaining(deadline))
      %{state | phase: :stopping, timer: timer, timer_deadline: deadline}
    else
      state
    end
  end

  defp request_shutdown(state, reason) do
    ShutdownControl.request(state.table, reason)
    control_shutdown(state)
  end

  defp control_shutdown(state) do
    case ShutdownControl.command(state.table) do
      {:ok, reason, _cutoff, force_at} ->
        state = begin_shutdown(state, force_at)

        if state.stopper do
          state
        else
          case ShutdownControl.stopper(state.table, state.root, reason) do
            {:ok, pid} -> %{watch_pid(state, pid) | stopper: pid}
            _unavailable -> state
          end
        end

      _unavailable ->
        state
    end
  end

  defp watch_children(_table, _pid, :worker), do: :ok

  # Walk child specifications in the registering process, never in the guard:
  # an unresponsive owned supervisor must not delay the overall stop timer.
  # Dynamically created descendants must register themselves through watch/3.
  defp watch_children(table, pid, :supervisor) do
    Enum.reduce_while(Supervisor.which_children(pid), :ok, fn
      {_id, child, type, _modules}, :ok when is_pid(child) ->
        case watch(table, child, type) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _child, :ok ->
        {:cont, :ok}
    end)
  end

  defp watch_children(_table, _pid, :worker, _deadline), do: :ok

  defp watch_children(table, pid, :supervisor, deadline) do
    with {:ok, children} <- startup_children(pid, deadline) do
      Enum.reduce_while(children, :ok, fn
        {_id, child, type, _modules}, :ok when is_pid(child) ->
          case watch(table, child, type, deadline) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        _child, :ok ->
          {:cont, :ok}
      end)
    end
  end

  defp startup_call(server, message, deadline) do
    if Deadline.now() < deadline do
      result = GenServer.call(server, message, min(4_294_967_295, Deadline.remaining(deadline)))
      if Deadline.now() < deadline, do: result, else: {:error, :service_start_timeout}
    else
      {:error, :service_start_timeout}
    end
  end

  defp startup_children(server, deadline) do
    case startup_call(server, :which_children, deadline) do
      children when is_list(children) -> {:ok, children}
      error -> error
    end
  end

  defp watch_pid(state, pid) do
    if Map.has_key?(state.children, pid) do
      state
    else
      monitor = Process.monitor(pid)

      %{
        state
        | children: Map.put(state.children, pid, monitor),
          monitors: Map.put(state.monitors, monitor, pid)
      }
    end
  end

  defp retire_owned(table, pid) do
    case :ets.lookup(table, {:service_cohort_pid, pid}) do
      [{{:service_cohort_pid, ^pid}, generation}] ->
        ServiceStartup.kill_cohort(table, generation)
        :ets.delete(table, {:service_cohort_pid, pid})

      _other ->
        :ok
    end

    :ets.match_delete(table, {{:service_start_owned, :_, pid}, :_})
    :ets.delete(table, {:service_owner, pid})
    :ets.delete(table, {:runtime_owned, pid})
  rescue
    ArgumentError -> :ok
  end

  defp force_children(state) do
    for {pid, _monitor} <- state.children, pid != state.stopper do
      Process.exit(pid, :kill)
    end
  end

  defp finish_or_wait(%{root_down: true, children: children} = state)
       when map_size(children) == 0 do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, state}
  end

  defp finish_or_wait(state), do: {:noreply, state}

  defp close_route(table) do
    :ets.insert(table, [{:closing, System.monotonic_time(:millisecond)}, {:route, :closed}])
  rescue
    ArgumentError -> :ok
  end
end
