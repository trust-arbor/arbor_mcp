defmodule Arbor.MCP.Server.Runtime.ShutdownControl do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Deadline, Diagnostics, Initialization, Ref, RetainedTerm}

  @capacity 16_384
  @reason_bytes 4_096
  @attempts 64
  @tick_ms 10
  @force_margin_ms 25

  @opaque t :: %__MODULE__{
            pid: pid(),
            root: pid(),
            table: :ets.tid(),
            ledger: :ets.tid(),
            cells: :atomics.atomics_ref(),
            budget: pos_integer(),
            identity: reference(),
            managed: boolean()
          }
  defstruct [:pid, :root, :table, :ledger, :cells, :budget, :identity, :managed]

  def start(root, table, config) do
    constructor = fn -> {root, table, config.shutdown_timeout_ms} end

    with {:ok, pid} <-
           GenServer.start(__MODULE__, constructor, timeout: startup_timeout(table, config)),
         [{:shutdown_control, control}] <- :ets.lookup(table, :shutdown_control),
         true <- control.pid == pid,
         :ok <- Initialization.track(table, pid, :shutdown_observer) do
      {:ok, control}
    else
      false -> {:error, :runtime_unavailable}
      error -> error
    end
  end

  def observer(control), do: control.pid

  def startup_timeout(table, config) do
    case Initialization.current(table) do
      {:ok, %{status: :starting}} -> Initialization.remaining(table)
      _standalone -> config.init_timeout_ms
    end
  end

  def reason(reason) do
    if RetainedTerm.bytes(reason, @reason_bytes) <= @reason_bytes,
      do: {:ok, RetainedTerm.materialize(reason)},
      else: {:error, :shutdown_reason_too_large}
  rescue
    ArgumentError -> {:error, :invalid_shutdown_reason}
  end

  def lookup(table) do
    case :ets.lookup(table, :shutdown_control) do
      [{:shutdown_control, %__MODULE__{} = control}] -> {:ok, control}
      _missing -> {:error, :shutdown_control_unavailable}
    end
  rescue
    ArgumentError -> {:error, :shutdown_control_unavailable}
  end

  def available?(table) do
    case lookup(table) do
      {:ok, control} -> live?(control) and :atomics.get(control.cells, 2) == 0
      _missing -> false
    end
  end

  # Called only by the existing owned-registration/native constructor path.
  # No stop caller supplies child PIDs or a new ownership graph.
  def track(table, pid, role)
      when is_pid(pid) and node(pid) == node() and role in [:worker, :guard, :shutdown_observer] do
    case lookup(table) do
      {:ok, %{pid: ^pid}} ->
        :ets.insert(table, {{:runtime_owned, pid}, role})
        :ok

      {:ok, control} ->
        register(control, pid, role)

      {:error, _missing} ->
        if :ets.info(table, :owner) == self() do
          :ets.insert(table, {{:runtime_owned, pid}, role})
          :ok
        else
          {:error, :shutdown_control_unavailable}
        end
    end
  end

  def track(_table, _pid, _role), do: {:error, :invalid_owned_process}

  def bind_guard(table, guard) do
    with {:ok, control} <- lookup(table), true <- live?(control) do
      :ets.insert(control.ledger, {:guard, guard})
      wake(control)
      :ok
    else
      false -> {:error, :shutdown_control_unavailable}
      error -> error
    end
  end

  def prepare(table, reason, started) do
    case lookup(table) do
      {:ok, control} -> prepare_captured(control, reason, started)
      error -> error
    end
  end

  # The authentic handle is captured before asynchronous cleanup can retire its
  # ETS ledger. This continuation retains its immutable completion/cutoff cells.
  defp prepare_captured(control, reason, started) do
    deadline = started + control.budget
    :ok = Deadline.validate(deadline)
    prepare_control(control, reason, started, deadline)
  end

  defp prepare_control(control, reason, started, deadline) do
    if live?(control) do
      :ets.insert_new(control.ledger, {:stop, reason, deadline, started})

      with :ok <- earliest(control.cells, deadline, @attempts) do
        :atomics.compare_exchange(control.cells, 2, 0, 1)
        close_route(control.table, started)
        wake(control)
        guard_wake(control)
        {:ok, control, min(deadline, cutoff(control))}
      end
    else
      completed_preparation(control, deadline)
    end
  rescue
    ArgumentError -> completed_preparation(control, deadline)
  end

  defp completed_preparation(control, deadline) do
    first = cutoff(control)

    if first != 0 and :atomics.get(control.cells, 2) == 3,
      do: {:ok, control, min(deadline, first)},
      else: {:error, :shutdown_control_unavailable}
  end

  def request(table, reason) do
    started = Deadline.now()

    with {:ok, reason} <- reason(reason),
         {:ok, _control, _deadline} <- prepare(table, reason, started),
         do: :ok
  end

  def command(table) do
    with {:ok, control} <- lookup(table),
         true <- live?(control),
         [{:stop, reason, _deadline, _started}] <- :ets.lookup(control.ledger, :stop) do
      :atomics.put(control.cells, 7, 0)
      {:ok, reason, cutoff(control), force_at(control)}
    else
      _unavailable -> {:error, :shutdown_control_unavailable}
    end
  rescue
    ArgumentError -> {:error, :shutdown_control_unavailable}
  end

  def await(control, deadline, previous_trap) do
    monitor = Process.monitor(control.pid)

    try do
      wait(control, deadline, previous_trap, monitor)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp wait(control, deadline, previous_trap, monitor) do
    now = Deadline.now()
    deadline = min(deadline, cutoff(control))

    cond do
      now >= deadline ->
        {:error, :shutdown_cleanup_unconfirmed}

      :atomics.get(control.cells, 2) == 3 and not Process.alive?(control.pid) ->
        :ok

      not Process.alive?(control.pid) ->
        {:error, :shutdown_control_unavailable}

      true ->
        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} ->
            wait(control, deadline, previous_trap, monitor)

          {:EXIT, pid, _reason} when pid == control.root ->
            wait(control, deadline, previous_trap, monitor)

          {:EXIT, _pid, :normal} when not previous_trap ->
            wait(control, deadline, previous_trap, monitor)

          {:EXIT, _pid, reason} when not previous_trap ->
            {:foreign_exit, reason}
        after
          min(@tick_ms, Deadline.remaining(deadline)) ->
            wait(control, deadline, previous_trap, monitor)
        end
    end
  end

  # The existing guard has at most one graceful stopper. Register its exact
  # freshly created identity before it may enter blocking Supervisor.stop.
  def stopper(table, root, reason) do
    with {:ok, control} <- lookup(table),
         true <- root == control.root,
         true <- registered?(control, self()) do
      token = make_ref()

      pid =
        spawn_link(fn ->
          receive do: ({^token, :go} -> Supervisor.stop(root, reason, :infinity))
        end)

      case register_created(control, pid, :stopper) do
        :ok ->
          send(pid, {token, :go})
          {:ok, pid}

        error ->
          Process.exit(pid, :kill)
          error
      end
    else
      _unqualified -> {:error, :invalid_owned_process}
    end
  end

  def failure(table) do
    # Only the pre-existing native/owned proof records for this exact root.
    # There is no link traversal and no borrowed service/listener adoption.
    root = :ets.info(table, :owner)

    with {:ok, _runtime} <- Ref.validate(Ref.new(root, table)) do
      records = :ets.match_object(table, {{:runtime_owned, :_}, :_})
      close_route(table, Deadline.now())
      if root != self(), do: Process.exit(root, :kill)

      for {{:runtime_owned, pid}, _role} <- records,
          pid != self() and pid != root,
          do: Process.exit(pid, :kill)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def stats(table) do
    with {:ok, control} <- lookup(table), true <- live?(control) do
      %{
        owned: length(owned(control)),
        capacity: @capacity,
        stop_records: if(:ets.member(control.ledger, :stop), do: 1, else: 0),
        phase: :atomics.get(control.cells, 2),
        cutoff: :atomics.get(control.cells, 1)
      }
    else
      _unavailable -> {:error, :shutdown_control_unavailable}
    end
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  @impl true
  def init(constructor) do
    {root, table, budget} = constructor.()

    ledger =
      :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    cells = :atomics.new(8, [])

    control = %__MODULE__{
      pid: self(),
      root: root,
      table: table,
      ledger: ledger,
      cells: cells,
      budget: budget,
      identity: make_ref(),
      managed: Ref.valid?(Ref.new(root, table))
    }

    token = make_ref()
    publication = :atomics.new(1, [])
    :atomics.put(publication, 1, 1)

    :ets.insert(ledger, [
      {{:owned_slot, 0}, token, root, :root, root, publication},
      {{:owned, root}, token, 0, :root, publication}
    ])

    :ets.insert(table, {:shutdown_control, control})

    {:ok,
     %{
       control: control,
       root_monitor: Process.monitor(root),
       root_down: false,
       children: %{},
       monitors: %{},
       pending_publications: %{},
       forcing: false
     }, @tick_ms}
  end

  @impl true
  def handle_info(:shutdown_wake, state) do
    :atomics.put(state.control.cells, 3, 0)
    advance(state)
  end

  def handle_info(:timeout, state), do: advance(state)

  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{root_monitor: monitor} = state) do
    retire(state.control, pid, root_token(state.control), 0)
    state = %{state | root_down: true}

    # A healthy guard and its linked graceful stopper may finish after root ACK.
    # It still gets only the remaining first-stop budget. Forced root loss
    # and late-published obligations are independently enforced.
    keep_guard =
      not state.forcing and cutoff(state.control) != 0 and
        Deadline.now() < force_at(state.control)

    force(state, keep_guard)
    finish_or_wait(%{state | forcing: not keep_guard})
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state, @tick_ms}

      {{^pid, token, role, index, producer, publication}, monitors} ->
        state = %{state | monitors: monitors}
        state = retire_or_hold(state, pid, token, role, index, producer, publication)

        if role == :guard and state.control.managed and not state.root_down and not state.forcing do
          force(state)
          finish_or_wait(%{state | forcing: true})
        else
          finish_or_wait(state)
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state, @tick_ms}

  defp advance(state) do
    state = state |> reap_publications() |> collect()

    case :ets.lookup(state.control.ledger, :stop) do
      [{:stop, _reason, deadline, started}] ->
        earliest(state.control.cells, deadline, @attempts)
        :atomics.compare_exchange(state.control.cells, 2, 0, 1)
        close_route(state.control.table, started)
        guard_wake(state.control)

        if Deadline.now() >= force_at(state.control) and not state.forcing do
          force(state)
          finish_or_wait(%{state | forcing: true})
        else
          finish_or_wait(state)
        end

      [] ->
        finish_or_wait(state)
    end
  end

  defp collect(state) do
    Enum.reduce(owned(state.control), state, fn
      {{:owned_slot, index}, token, pid, role, producer, publication}, acc ->
        key = {pid, token}

        if pid == acc.control.root or Map.has_key?(acc.children, key) do
          acc
        else
          monitor = Process.monitor(pid)

          if acc.forcing or (acc.root_down and role not in [:guard, :stopper]),
            do: Process.exit(pid, :kill)

          %{
            acc
            | children: Map.put(acc.children, key, monitor),
              monitors:
                Map.put(acc.monitors, monitor, {pid, token, role, index, producer, publication})
          }
        end
    end)
  end

  defp retire_or_hold(state, pid, token, role, index, producer, publication) do
    key = {pid, token}

    if :atomics.get(publication, 1) == 1 or not Process.alive?(producer) do
      retire(state.control, pid, token, index)
      %{state | children: Map.delete(state.children, key)}
    else
      entry = {pid, token, role, index, producer, publication}
      %{state | pending_publications: Map.put(state.pending_publications, key, entry)}
    end
  end

  defp reap_publications(state) do
    Enum.reduce(state.pending_publications, state, fn {key, entry}, acc ->
      {pid, token, _role, index, producer, publication} = entry

      if :atomics.get(publication, 1) == 1 or not Process.alive?(producer) do
        retire(acc.control, pid, token, index)

        %{
          acc
          | children: Map.delete(acc.children, key),
            pending_publications: Map.delete(acc.pending_publications, key)
        }
      else
        acc
      end
    end)
  end

  defp force(state, keep_guard \\ false) do
    :atomics.put(state.control.cells, 2, 2)
    if not state.root_down, do: Process.exit(state.control.root, :kill)

    for {{:owned_slot, _index}, _token, pid, role, _producer, _publication} <-
          owned(state.control),
        pid != state.control.root and (not keep_guard or role not in [:guard, :stopper]),
        do: Process.exit(pid, :kill)

    :ok
  end

  defp finish_or_wait(state) do
    state = if state.root_down and map_size(state.children) == 0, do: collect(state), else: state

    if state.root_down and map_size(state.children) == 0 and owned(state.control) == [] do
      :atomics.put(state.control.cells, 2, 3)
      {:stop, :normal, state}
    else
      timeout =
        case :atomics.get(state.control.cells, 1) do
          0 -> @tick_ms
          _deadline -> min(@tick_ms, Deadline.remaining(force_at(state.control)))
        end

      {:noreply, state, max(1, timeout)}
    end
  end

  defp register(control, pid, role) do
    cond do
      registered?(control, pid) -> :ok
      owned_constructor?(control, pid) -> register_created(control, pid, role)
      true -> {:error, :invalid_owned_process}
    end
  end

  defp register_created(control, pid, role) do
    cond do
      not live?(control) -> {:error, :shutdown_control_unavailable}
      not registration_open?(control, role) -> {:error, :runtime_stopped}
      registered?(control, pid) -> :ok
      :ets.member(control.ledger, {:owned, pid}) -> {:error, :ownership_registration_busy}
      true -> publish_registration(control, pid, role)
    end
  rescue
    ArgumentError -> {:error, :shutdown_control_unavailable}
  end

  defp publish_registration(control, pid, role) do
    with {:ok, index, token, publication} <- claim(control, pid, role, @attempts) do
      row = {{:owned, pid}, token, index, role, publication}

      if :ets.insert_new(control.ledger, row) do
        :ets.insert(control.table, {{:runtime_owned, pid}, role})
        :atomics.put(publication, 1, 1)
        wake(control)

        cond do
          not registration_open?(control, role) ->
            Process.exit(pid, :kill)
            {:error, :runtime_stopped}

          not Process.alive?(pid) ->
            {:error, :owned_process_unavailable}

          true ->
            :ok
        end
      else
        :atomics.put(publication, 1, 1)
        retire_slot(control, index, token)
        {:error, :ownership_registration_busy}
      end
    end
  end

  defp registration_open?(control, :stopper),
    do: :atomics.get(control.cells, 2) == 1 and Deadline.now() < force_at(control)

  defp registration_open?(control, _role), do: :atomics.get(control.cells, 2) == 0

  defp owned_constructor?(control, pid) do
    caller = self()

    cond do
      caller == control.root ->
        true

      not control.managed and caller == pid ->
        true

      caller == pid ->
        Enum.any?(ancestors(pid), &known_ancestor?(control, &1))

      registered?(control, caller) ->
        Enum.any?(ancestors(pid), &known_ancestor?(control, &1)) or
          startup_observer?(control, pid)

      true ->
        false
    end
  end

  # ServiceStartup publishes the exact helper under its current cohort before
  # registering it. Its initiating producer must itself already be owned.
  defp startup_observer?(control, pid) do
    case :ets.lookup(control.table, :service_start_observer) do
      [{:service_start_observer, generation, ^pid}] ->
        case :ets.lookup(control.table, :services_startup) do
          [{:services_startup, ^generation, deadline, :starting}] -> Deadline.now() < deadline
          _retired -> false
        end

      _unproven ->
        false
    end
  end

  defp known_ancestor?(control, pid) when is_pid(pid),
    do: pid == control.root or registered?(control, pid)

  defp known_ancestor?(_control, nil), do: false

  defp known_ancestor?(control, name) when is_atom(name),
    do: known_ancestor?(control, Process.whereis(name))

  defp known_ancestor?(_control, _name), do: false

  defp ancestors(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, :"$ancestors", 0) do
          {:"$ancestors", ancestors} when is_list(ancestors) -> ancestors
          _missing -> []
        end

      _dead ->
        []
    end
  end

  # A slot row is the reservation itself. An abrupt producer death between
  # reservation and PID-index publication leaves a tangible exact PID/token
  # obligation that the observer monitors and reaps. No counter-only orphan.
  defp claim(control, _pid, _role, 0) do
    if length(owned(control)) == @capacity,
      do: {:error, :ownership_capacity},
      else: {:error, :ownership_registration_busy}
  end

  defp claim(control, pid, role, attempts) do
    index = rem(:atomics.add_get(control.cells, 8, 1), @capacity)
    token = make_ref()
    publication = :atomics.new(1, [])
    row = {{:owned_slot, index}, token, pid, role, self(), publication}

    if :ets.insert_new(control.ledger, row),
      do: {:ok, index, token, publication},
      else: claim(control, pid, role, attempts - 1)
  end

  defp earliest(_cells, _deadline, 0), do: {:error, :shutdown_control_busy}

  defp earliest(cells, deadline, attempts) do
    old = :atomics.get(cells, 1)

    cond do
      old != 0 and old <= deadline -> :ok
      :atomics.compare_exchange(cells, 1, old, deadline) == :ok -> :ok
      true -> earliest(cells, deadline, attempts - 1)
    end
  end

  defp cutoff(control), do: :atomics.get(control.cells, 1)

  defp force_at(control),
    do: cutoff(control) - min(@force_margin_ms, max(1, div(control.budget, 4)))

  defp owned(control),
    do: :ets.match_object(control.ledger, {{:owned_slot, :_}, :_, :_, :_, :_, :_})

  defp registered?(control, pid) do
    case :ets.lookup(control.ledger, {:owned, pid}) do
      [{{:owned, ^pid}, _token, _index, _role, publication}] ->
        :atomics.get(publication, 1) == 1 and Process.alive?(pid)

      _missing ->
        false
    end
  end

  defp root_token(control) do
    [{{:owned, _root}, token, _index, :root, _publication}] =
      :ets.lookup(control.ledger, {:owned, control.root})

    token
  end

  defp retire(control, pid, token, index) do
    # Publication is finished (or its exact producer is DOWN) before this path.
    # While the old PID index is present, a competing registration cannot
    # publish a new root row. Retire the mirror before releasing that index.
    case :ets.lookup(control.ledger, {:owned, pid}) do
      [{{:owned, ^pid}, ^token, ^index, _role, _publication}] ->
        retire_root_record(control.table, pid)
        :ets.select_delete(control.ledger, [{{{:owned, pid}, token, index, :_, :_}, [], [true]}])

      _unpublished_or_retired ->
        :ok
    end

    retire_slot(control, index, token)
    :ok
  end

  defp retire_root_record(table, pid) do
    :ets.delete(table, {:runtime_owned, pid})
  rescue
    ArgumentError -> :ok
  end

  defp retire_slot(control, index, token) do
    :ets.select_delete(control.ledger, [
      {{{:owned_slot, index}, token, :_, :_, :_, :_}, [], [true]}
    ])

    :ok
  end

  defp live?(control),
    do: Process.alive?(control.pid) and :ets.info(control.ledger, :owner) == control.pid

  defp wake(control) do
    if :atomics.compare_exchange(control.cells, 3, 0, 1) == :ok,
      do: send(control.pid, :shutdown_wake)

    :ok
  end

  defp guard_wake(control) do
    case :ets.lookup(control.ledger, :guard) do
      [{:guard, guard}] ->
        if :atomics.compare_exchange(control.cells, 7, 0, 1) == :ok,
          do: send(guard, :shutdown_control)

      [] ->
        :ok
    end

    :ok
  end

  defp close_route(table, started) do
    :ets.insert(table, [{:closing, started}, {:route, :closed}])
  rescue
    ArgumentError -> :ok
  end
end
