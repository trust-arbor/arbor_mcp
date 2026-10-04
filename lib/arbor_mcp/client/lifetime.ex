defmodule Arbor.MCP.Client.Lifetime do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Client.Deadline

  @key {__MODULE__, :context}
  @marker {__MODULE__, :identity}
  @registration_ms 1_000
  @max_timer 4_294_967_295

  def install(opts) do
    with {:ok, limit} <- limit(opts, :max_client_workers, 256, 4_096),
         {:ok, cleanup} <- limit(opts, :client_cleanup_timeout, 1_000, @max_timer),
         token = make_ref(),
         epoch = make_ref(),
         {:ok, observer} <-
           GenServer.start(
             __MODULE__,
             {self(), opts[:_lifetime_parent], token, epoch, limit, cleanup},
             timeout: @registration_ms
           ) do
      context = {observer, token, epoch}
      Process.put(@key, context)
      Process.put({__MODULE__, :cleanup_ms}, cleanup)
      :ok
    end
  end

  def current, do: Process.get(@key)

  def from_client(client) do
    with pid when is_pid(pid) and node(pid) == node() <- GenServer.whereis(client),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         true <- :proplists.get_value({Arbor.MCP.Client, :client}, dictionary) == true do
      :proplists.get_value(@key, dictionary)
    else
      _other -> nil
    end
  end

  def request_cleanup(client, deadline) do
    case from_client(client) do
      nil -> :ok
      context -> call(context, {:request_cleanup, GenServer.whereis(client), deadline}, deadline)
    end
  end

  def client_cleanup_ms(client) do
    with pid when is_pid(pid) and node(pid) == node() <- GenServer.whereis(client),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         n when is_integer(n) and n > 0 <-
           :proplists.get_value({__MODULE__, :cleanup_ms}, dictionary) do
      n
    else
      _other -> Deadline.cleanup_timeout()
    end
  end

  def opening do
    case current() do
      nil ->
        :ok

      context ->
        case call(context, :opening) do
          {:ok, next} ->
            Process.put(@key, next)
            :ok

          error ->
            error
        end
    end
  end

  def quiesce(deadline, mode \\ :all) do
    if context = current(), do: call(context, {:quiesce, deadline, mode}, deadline), else: :ok
  end

  def cleanup(deadline, mode \\ :all) do
    if context = current(), do: call(context, {:cleanup, deadline, mode}, deadline), else: :ok
  end

  def cleanup_timeout do
    Process.get({__MODULE__, :cleanup_ms}) || observer_cleanup_timeout()
  end

  defp observer_cleanup_timeout do
    case current() do
      nil ->
        Deadline.cleanup_timeout()

      context ->
        case call(context, :cleanup_timeout) do
          ms when is_integer(ms) -> ms
          _error -> Deadline.cleanup_timeout()
        end
    end
  end

  def valid?(nil), do: true
  def valid?(context), do: context == current() and call(context, :active?) == true

  def deliver(target, message, context \\ current()) do
    case context do
      nil ->
        send(target, message)

      {_observer, _token, epoch} ->
        case from_client(target) do
          ^context -> send(target, {:client_lifetime_event, epoch, message})
          nil -> send(target, message)
          _retired -> :ok
        end
    end
  end

  def peer_context do
    with true <- Process.get({Arbor.MCP.Client, :client}) == true,
         {_observer, _token, epoch} <- current() do
      %{owner: self(), epoch: epoch}
    else
      _other -> nil
    end
  end

  def event?(epoch) do
    case current() do
      {_observer, _token, ^epoch} = context -> valid?(context)
      _other -> false
    end
  end

  def spawn_monitor(fun), do: start_worker(fun, :monitor)
  def spawn_link(fun), do: start_worker(fun, :link)
  def async(fun), do: start_worker(fun, :task)

  def close_async(fun) do
    start_worker(fun, :task, :cleanup)
  end

  def start_process(module, opts, mode, deadline \\ Deadline.after_ms(@registration_ms)) do
    case reserve(current(), module, :ordinary, deadline) do
      {:ok, nil} ->
        native_start(module, opts, mode, Deadline.remaining(deadline))

      {:ok, reservation} ->
        opts =
          opts
          |> Keyword.put(:_client_lifetime, reservation)
          |> Keyword.put(:_client_lifetime_deadline, deadline)

        # Native construction stays linked until the early registration ACK.
        result = native_start(module, opts, :linked, Deadline.remaining(deadline))

        if mode == :unlinked and match?({:ok, _pid}, result) do
          {:ok, pid} = result
          Process.unlink(pid)
        end

        result

      error ->
        error
    end
  end

  def register_process(reservation, deadline \\ Deadline.after_ms(@registration_ms))
  def register_process(nil, _deadline), do: :ok

  def register_process({context, nonce}, deadline) do
    Process.put(@key, context)
    Process.put(@marker, {context, nonce})
    call(context, {:register, nonce, self()}, deadline)
  end

  def async_stream(items, fun, opts) do
    case current() do
      nil ->
        Task.async_stream(items, fun, opts)

      context ->
        items
        |> Stream.map(fn item -> {item, reserve(context, :worker, :ordinary)} end)
        |> Task.async_stream(
          fn
            {item, {:ok, reservation}} ->
              case register_process(reservation) do
                :ok -> fun.(item)
                {:error, reason} -> exit(reason)
              end

            {_item, {:error, reason}} ->
              exit(reason)
          end,
          opts
        )
    end
  end

  def persist_subscription do
    if context = current(), do: call(context, :persist_subscription), else: :ok
  end

  def stop_owned(pid, deadline) when is_pid(pid) do
    case current() do
      nil -> {:error, :unregistered_client_worker}
      context -> call(context, {:stop_owned, pid, deadline}, deadline)
    end
  end

  def native_stop(pid, module, operation, deadline) when is_pid(pid) do
    with true <- node(pid) == node(),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         true <- :proplists.get_value(:"$initial_call", dictionary) == {module, :init, 1},
         true <- owned_process?(dictionary) do
      monitor = Process.monitor(pid)

      result =
        try do
          operation.(max(Deadline.remaining(deadline) - 50, 0))
        catch
          :exit, {:noproc, _call} -> :ok
          :exit, {:normal, _call} -> :ok
          :exit, {:timeout, _call} -> {:error, :http_cleanup_timeout}
          :exit, _reason -> {:error, :http_cleanup_unconfirmed}
        end

      down =
        if result == :ok do
          case wait_down(pid, monitor, deadline) do
            :ok ->
              :ok

            error ->
              Process.exit(pid, :kill)
              error
          end
        else
          # Force only our registered child, preserving the original error.
          Process.exit(pid, :kill)
          wait_down(pid, monitor, deadline)
        end

      Process.demonitor(monitor, [:flush])
      if result == :ok, do: down, else: result
    else
      nil -> :ok
      _unowned -> {:error, :unregistered_client_worker}
    end
  end

  defp owned_process?(dictionary) do
    case current() do
      nil -> :proplists.get_value({__MODULE__, :native_parent}, dictionary) == self()
      context -> :proplists.get_value(@key, dictionary) == context
    end
  end

  defp native_start(module, opts, :linked, timeout),
    do: GenServer.start_link(module, opts, timeout: timeout)

  defp native_start(module, opts, :unlinked, timeout),
    do: GenServer.start(module, opts, timeout: timeout)

  defp start_worker(fun, mode, kind \\ :ordinary) do
    context = current()
    owner = self()

    case reserve(context, :worker, kind) do
      {:ok, nil} ->
        spawn_native(mode, fun)

      {:ok, {^context, nonce}} ->
        spawn_native(mode, fn ->
          Process.put(@key, context)
          Process.put(@marker, {context, nonce})
          owner_monitor = Process.monitor(owner)

          case call(context, {:register, nonce, self()}) do
            :ok ->
              Process.demonitor(owner_monitor, [:flush])
              fun.()

            {:error, reason} ->
              exit(reason)
          end
        end)

      {:error, reason} ->
        spawn_native(mode, fn -> exit(reason) end)
    end
  end

  defp spawn_native(:monitor, fun), do: Kernel.spawn_monitor(fun)
  defp spawn_native(:link, fun), do: Kernel.spawn_link(fun)
  defp spawn_native(:task, fun), do: Task.async(fun)

  defp reserve(context, module, kind, deadline \\ Deadline.after_ms(@registration_ms))
  defp reserve(nil, _module, _kind, _deadline), do: {:ok, nil}

  defp reserve(context, module, kind, deadline) do
    case call(context, {:reserve, module, kind}, deadline) do
      {:ok, nonce} -> {:ok, {context, nonce}}
      error -> error
    end
  end

  defp call({observer, token, epoch}, operation, deadline \\ Deadline.after_ms(@registration_ms)) do
    with {:dictionary, dictionary} <- Process.info(observer, :dictionary),
         true <- :proplists.get_value(@marker, dictionary) == token,
         true <- :proplists.get_value(:"$initial_call", dictionary) == {__MODULE__, :init, 1} do
      GenServer.call(observer, {token, epoch, operation}, Deadline.remaining(deadline))
    else
      _other -> {:error, :client_lifetime_unavailable}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :client_cleanup_timeout}
    :exit, _reason -> {:error, :client_lifetime_unavailable}
  end

  defp limit(opts, name, default, max) do
    case Keyword.get(opts, name, default) do
      n when is_integer(n) and n > 0 and n <= max -> {:ok, n}
      _other -> {:error, {:invalid_client_lifetime_option, name}}
    end
  end

  @impl true
  def init({owner, parent, token, epoch, limit, cleanup}) do
    Process.put(@marker, token)
    owner_monitor = Process.monitor(owner)
    parent_monitor = if is_pid(parent), do: Process.monitor(parent)
    :ok = arm_owner_watchdog(owner, parent, self(), cleanup)
    Process.send_after(self(), :reap, 50)

    {:ok,
     %{
       owner: owner,
       parent: parent,
       owner_monitor: owner_monitor,
       parent_monitor: parent_monitor,
       parent_retiring?: false,
       token: token,
       epoch: epoch,
       limit: limit,
       cleanup_ms: cleanup,
       phase: :active,
       workers: %{},
       reservations: %{},
       cutoff: nil,
       cleanup_timer: nil,
       retire_mode: :all
     }}
  end

  @impl true
  def handle_call({token, epoch, operation}, {caller, _tag}, state)
      when token == state.token and epoch == state.epoch do
    operation(operation, caller, state)
  end

  def handle_call(_operation, _from, state),
    do: {:reply, {:error, :client_generation_retired}, state}

  defp operation(:active?, _caller, state), do: {:reply, state.phase == :active, state}
  defp operation(:cleanup_timeout, _caller, state), do: {:reply, state.cleanup_ms, state}

  defp operation(:opening, caller, state) when caller == state.owner do
    if state.phase == :closed and not state.parent_retiring? and connection_workers(state) == [] do
      epoch = make_ref()

      {:reply, {:ok, {self(), state.token, epoch}},
       %{state | epoch: epoch, phase: :active, cutoff: nil, reservations: %{}}}
    else
      if state.phase == :active,
        do: {:reply, {:ok, {self(), state.token, state.epoch}}, state},
        else: {:reply, {:error, :client_cleanup_unconfirmed}, state}
    end
  end

  defp operation({:reserve, module, kind}, caller, state) do
    cleanup? = kind == :cleanup and caller == state.owner
    allowed = authorized?(caller, state) and (state.phase == :active or cleanup?)
    count = map_size(state.workers) + map_size(state.reservations)

    if allowed and count < state.limit + if(cleanup?, do: 1, else: 0) do
      nonce = make_ref()
      entry = %{creator: caller, module: module, deadline: Deadline.after_ms(@registration_ms)}
      {:reply, {:ok, nonce}, %{state | reservations: Map.put(state.reservations, nonce, entry)}}
    else
      reason = if allowed, do: :client_worker_limit, else: :client_generation_retired
      {:reply, {:error, reason}, state}
    end
  end

  defp operation({:register, nonce, pid}, caller, state) when caller == pid do
    case Map.pop(state.reservations, nonce) do
      {nil, _entries} ->
        {:reply, {:error, :client_generation_retired}, state}

      {entry, entries} ->
        state = %{state | reservations: entries}

        if not Deadline.expired?(entry.deadline) and worker_identity?(pid, nonce, entry, state) do
          monitor = Process.monitor(pid)
          lifetime = :atomics.new(1, [])
          watchdog = watchdog(pid, state.owner, entry.creator, self(), lifetime, entry.deadline)
          guard_monitor = Process.monitor(watchdog)

          worker = %{
            monitor: monitor,
            watchdog: watchdog,
            guard_monitor: guard_monitor,
            persistent?: false,
            lifetime: lifetime
          }

          {:reply, :ok, %{state | workers: Map.put(state.workers, pid, worker)}}
        else
          {:reply, {:error, :unregistered_client_worker}, state}
        end
    end
  end

  defp operation(:persist_subscription, caller, state) do
    with true <- state.phase == :active,
         %{persistent?: _} = worker <- Map.get(state.workers, caller),
         {:dictionary, dictionary} <- Process.info(caller, :dictionary),
         true <-
           :proplists.get_value(:"$initial_call", dictionary) ==
             {Arbor.MCP.Client.Subscription, :init, 1} do
      :atomics.put(worker.lifetime, 1, 1)

      {:reply, :ok,
       %{state | workers: Map.put(state.workers, caller, %{worker | persistent?: true})}}
    else
      _unowned -> {:reply, {:error, :unregistered_client_worker}, state}
    end
  end

  defp operation({:request_cleanup, owner, deadline}, _caller, state) when owner == state.owner do
    quiesce_state(deadline, :all, state)
  end

  defp operation({:quiesce, deadline, mode}, caller, state) when caller == state.owner do
    quiesce_state(deadline, mode, state)
  end

  defp operation({:cleanup, deadline, mode}, caller, state) when caller == state.owner do
    cutoff = Deadline.earliest(state.cutoff, deadline)

    {result, state} =
      stop_all(
        %{
          state
          | phase: :closing,
            cutoff: cutoff,
            retire_mode: if(state.retire_mode == :all, do: :all, else: mode)
        },
        cutoff
      )

    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
    {:reply, result, %{state | phase: :closed, reservations: %{}, cleanup_timer: nil}}
  end

  defp operation({:stop_owned, pid, deadline}, _caller, state) do
    case Map.fetch(state.workers, pid) do
      {:ok, worker} ->
        Process.exit(pid, :kill)

        case wait_down(pid, worker.monitor, deadline) do
          :ok -> {:reply, :ok, remove_worker(pid, state)}
          error -> {:reply, error, state}
        end

      :error ->
        {:reply, {:error, :unregistered_client_worker}, state}
    end
  end

  defp operation(_operation, _caller, state),
    do: {:reply, {:error, :invalid_lifetime_operation}, state}

  defp quiesce_state(deadline, mode, state) do
    cutoff =
      if state.phase == :closed, do: deadline, else: Deadline.earliest(state.cutoff, deadline)

    mode = if state.phase == :closing and state.retire_mode == :all, do: :all, else: mode

    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
    timer = Process.send_after(self(), {:cleanup_cutoff, state.epoch}, Deadline.remaining(cutoff))

    {:reply, :ok,
     %{
       state
       | phase: :closing,
         cutoff: cutoff,
         reservations: %{},
         cleanup_timer: timer,
         retire_mode: mode
     }}
  end

  defp authorized?(pid, state), do: pid == state.owner or Map.has_key?(state.workers, pid)

  defp worker_identity?(pid, nonce, entry, state) do
    context = {self(), state.token, state.epoch}

    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         true <- :proplists.get_value(@marker, dictionary) == {context, nonce} do
      entry.module == :worker or
        :proplists.get_value(:"$initial_call", dictionary) == {entry.module, :init, 1}
    else
      _other -> false
    end
  end

  defp arm_owner_watchdog(owner, parent, observer, cleanup_ms) do
    nonce = make_ref()

    guardian =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)
        observer_monitor = Process.monitor(observer)
        parent_monitor = if is_pid(parent), do: Process.monitor(parent)
        send(observer, {nonce, :owner_watchdog_ready})
        watch_owner(owner, owner_monitor, observer, observer_monitor, parent_monitor, cleanup_ms)
      end)

    receive do
      {^nonce, :owner_watchdog_ready} -> :ok
    after
      @registration_ms ->
        Process.exit(guardian, :kill)
        {:error, :client_lifetime_unavailable}
    end
  end

  defp watch_owner(owner, owner_monitor, observer, observer_monitor, parent_monitor, cleanup_ms) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        await_observer_cleanup(observer, observer_monitor, Deadline.after_ms(cleanup_ms))

      {:DOWN, ^observer_monitor, :process, ^observer, _reason} ->
        Process.exit(owner, :kill)

      {:DOWN, ^parent_monitor, :process, _parent, _reason} when is_reference(parent_monitor) ->
        deadline = Deadline.after_ms(cleanup_ms)

        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            await_observer_cleanup(observer, observer_monitor, deadline)

          {:DOWN, ^observer_monitor, :process, ^observer, _reason} ->
            Process.exit(owner, :kill)
        after
          Deadline.remaining(deadline) ->
            Process.exit(owner, :kill)
            Process.exit(observer, :kill)
        end
    end
  end

  defp await_observer_cleanup(observer, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^observer, _reason} -> :ok
    after
      Deadline.remaining(deadline) -> Process.exit(observer, :kill)
    end
  end

  defp watchdog(worker, owner, creator, observer, lifetime, deadline) do
    nonce = make_ref()

    guardian =
      spawn(fn ->
        monitors =
          [worker, owner, creator, observer]
          |> Enum.uniq()
          |> Enum.map(&{Process.monitor(&1), &1})

        send(observer, {nonce, :watchdog_ready})
        watch_worker(monitors, worker, owner, creator, lifetime)
      end)

    receive do
      {^nonce, :watchdog_ready} -> guardian
    after
      Deadline.remaining(deadline) ->
        Process.exit(guardian, :kill)
        Process.exit(worker, :kill)
        guardian
    end
  end

  defp watch_worker(monitors, worker, owner, creator, lifetime) do
    receive do
      {:DOWN, monitor, :process, pid, _reason} ->
        cond do
          {monitor, pid} not in monitors ->
            watch_worker(monitors, worker, owner, creator, lifetime)

          pid == worker ->
            :ok

          pid == creator and creator != owner and :atomics.get(lifetime, 1) == 1 ->
            watch_worker(List.delete(monitors, {monitor, pid}), worker, owner, creator, lifetime)

          true ->
            Process.exit(worker, :kill)
        end
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.owner_monitor do
    deadline = state.cutoff || Deadline.after_ms(state.cleanup_ms)
    {_result, state} = stop_all(%{state | retire_mode: :all}, deadline)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.parent_monitor do
    deadline = Deadline.earliest(state.cutoff, Deadline.after_ms(state.cleanup_ms))
    {:reply, :ok, state} = quiesce_state(deadline, :all, state)
    Enum.each(retired_workers(state), &Process.exit(&1, :kill))
    Process.send_after(self(), {:owner_cutoff, state.epoch}, Deadline.remaining(deadline))
    # Native GenServer retains its own parent's EXIT and termination reason.
    # Keep the observer responsive to its final cleanup-worker registration.
    {:noreply, %{state | parent_retiring?: true}}
  end

  def handle_info({:owner_cutoff, epoch}, %{epoch: epoch, parent_retiring?: true} = state) do
    if Process.alive?(state.owner), do: Process.exit(state.owner, :kill)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    state =
      case Map.get(state.workers, pid) do
        %{monitor: ^monitor} ->
          remove_worker(pid, state)

        _other ->
          case Enum.find(state.workers, fn {_pid, worker} -> worker.guard_monitor == monitor end) do
            {worker_pid, _entry} ->
              Process.exit(worker_pid, :kill)
              state

            nil ->
              state
          end
      end

    {:noreply, state}
  end

  def handle_info({:cleanup_cutoff, epoch}, state)
      when epoch == state.epoch and state.phase == :closing do
    Enum.each(retired_workers(state), &Process.exit(&1, :kill))
    {:noreply, state}
  end

  def handle_info(:reap, state) do
    entries =
      Map.reject(state.reservations, fn {_nonce, entry} -> Deadline.expired?(entry.deadline) end)

    Process.send_after(self(), :reap, 50)
    {:noreply, %{state | reservations: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connection_workers(state) do
    for {pid, %{persistent?: false}} <- state.workers, do: pid
  end

  defp retired_workers(%{retire_mode: :transport} = state), do: connection_workers(state)
  defp retired_workers(state), do: Map.keys(state.workers)

  defp stop_all(state, deadline) do
    Enum.each(retired_workers(state), &Process.exit(&1, :kill))

    Enum.reduce(retired_workers(state), {:ok, state}, fn pid, {result, current} ->
      worker = Map.fetch!(current.workers, pid)

      case wait_down(pid, worker.monitor, deadline) do
        :ok -> {result, remove_worker(pid, current)}
        error -> {if(result == :ok, do: error, else: result), current}
      end
    end)
  end

  defp wait_down(pid, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      Deadline.remaining(deadline) -> {:error, :client_cleanup_timeout}
    end
  end

  defp remove_worker(pid, state) do
    {worker, workers} = Map.pop(state.workers, pid)
    Process.demonitor(worker.monitor, [:flush])
    Process.demonitor(worker.guard_monitor, [:flush])
    %{state | workers: workers}
  end
end
