defmodule Arbor.MCP.Server.Runtime.ShutdownControlTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    Initialization,
    Ref,
    ShutdownControl,
    ShutdownGuard
  }

  defmodule Handler do
    def init(parent), do: {:ok, parent}

    def dispatch(request, _module, parent, _opts) do
      send(parent, {:callback, self()})
      if request["method"] == "hold", do: receive(do: (:release -> :ok))
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => true}, parent}
    end
  end

  defmodule Owned do
    use GenServer
    alias Arbor.MCP.Server.Runtime.{Initialization, ServiceAdapter, ShutdownGuard}
    def runtime_service_capabilities, do: %{bounded_startup: 1}

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: opts[:init_timeout_ms])

    def init(opts) do
      Process.flag(:trap_exit, true)
      :ok = ServiceAdapter.watch_owned(opts)
      send(opts[:parent], {:owned, self()})
      {:ok, %{table: opts[:runtime_table], parent: opts[:parent]}}
    end

    def handle_call(:fill, _from, state) do
      parent = self()
      result = fill(state.table, parent, [])
      {:reply, result, state}
    end

    def handle_call({:children, count, tracked?}, _from, state) do
      parent = self()

      pids =
        for _ <- 1..count do
          pid =
            :proc_lib.spawn_link(fn ->
              Process.flag(:trap_exit, true)
              result = if tracked?, do: Initialization.track(state.table, self()), else: :ok
              send(parent, {:early_child, self(), result})
              receive do: (:release -> :ok)
            end)

          receive do: ({:early_child, ^pid, :ok} -> pid)
        end

      {:reply, pids, state}
    end

    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

    def terminate(_reason, state) do
      send(state.parent, {:held_terminate, self()})
      receive do: (:release -> :ok)
    end

    defp fill(table, parent, pids) do
      pid =
        :proc_lib.spawn_link(fn ->
          Process.flag(:trap_exit, true)

          case Initialization.track(table, self()) do
            :ok ->
              result = ShutdownGuard.watch(table, self())
              send(parent, {:registration, self(), result})
              receive do: (:release -> :ok)

            error ->
              send(parent, {:registration, self(), error})
          end
        end)

      receive do
        {:registration, ^pid, :ok} -> fill(table, parent, [pid | pids])
        {:registration, ^pid, error} -> {error, pids, pid}
        {:EXIT, _pid, _reason} -> fill(table, parent, pids)
      end
    end
  end

  test "suspended guard cannot postpone original stop cutoff or leak an owned blocked descendant" do
    {root, ref, table, guard, observer} = runtime(180, owned: true)
    assert_receive {:owned, owned}
    sibling = runtime(500)
    :ok = :sys.suspend(guard)
    monitors = Enum.map([root, guard, observer, owned], &{&1, Process.monitor(&1)})
    started = Deadline.now()
    result = Runtime.stop(ref)
    assert result in [:ok, {:error, :shutdown_cleanup_unconfirmed}]
    assert Deadline.now() - started < 300
    for {pid, monitor} <- monitors, do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 300)
    assert :ets.info(table) == :undefined
    {sibling_root, sibling_ref, _, _, _} = sibling
    assert Process.alive?(sibling_root)
    assert {:ok, %{"result" => true}} = Runtime.request(sibling_ref, message(1))
    assert :ok = Runtime.stop(sibling_root)
    refute_receive {:EXIT, ^root, _}
  end

  test "guard stalled after graceful root ACK still retires within the first stop cutoff" do
    {root, ref, table, guard, observer} = runtime(400, owned: true)
    assert_receive {:owned, owner}
    parent = self()
    root_monitor = Process.monitor(root)
    guard_monitor = Process.monitor(guard)
    observer_monitor = Process.monitor(observer)

    caller =
      spawn(fn ->
        result = Runtime.stop(ref)
        returned_at = Deadline.now()
        send(parent, {:after_root_stop, result, returned_at})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:held_terminate, ^owner}
    %{cutoff: cutoff} = ShutdownControl.stats(table)
    :sys.suspend(guard)
    send(owner, :release)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}, 300
    assert Process.alive?(guard)

    assert_receive {:after_root_stop, result, returned_at}
                   when result in [:ok, {:error, :shutdown_cleanup_unconfirmed}],
                   500

    assert returned_at <= cutoff + 50
    assert_receive {:DOWN, ^guard_monitor, :process, ^guard, :killed}, 100
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :normal}, 100
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 100
  end

  test "first stop survives abrupt caller death and repeats never renew the deadline" do
    {root, ref, table, guard, observer} = runtime(240)
    :sys.suspend(guard)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:entered, self()})
        Runtime.stop(ref)
      end)

    assert_receive {:entered, ^caller}
    eventually(fn -> match?(%{stop_records: 1}, ShutdownControl.stats(table)) end)
    %{cutoff: first} = ShutdownControl.stats(table)
    Process.exit(caller, :kill)
    Process.sleep(30)
    assert :ok = ShutdownGuard.request_stop(table, {:shutdown, :later})
    assert %{cutoff: ^first, stop_records: 1} = ShutdownControl.stats(table)
    root_monitor = Process.monitor(root)
    observer_monitor = Process.monitor(observer)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _}, 400
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, _}, 400
  end

  test "concurrent public stops retain one reason and bounded token wakes" do
    {root, ref, table, guard, observer} = runtime(800)
    :sys.suspend(guard)
    :sys.suspend(observer)
    parent = self()

    :erlang.trace_pattern({ShutdownControl, :await, 3}, true, [])
    on_exit(fn -> :erlang.trace_pattern({ShutdownControl, :await, 3}, false, []) end)

    callers =
      for _ <- 1..128 do
        spawn(fn ->
          receive do
            :stop ->
              send(parent, {:caller, self()})
              send(parent, {:result, Runtime.stop(ref)})
          end
        end)
      end

    on_exit(fn ->
      Enum.each(callers, fn caller ->
        if Process.alive?(caller), do: Process.exit(caller, :kill)
      end)
    end)

    Enum.each(callers, fn caller ->
      :erlang.trace(caller, true, [:call, :arity, {:tracer, parent}])
      send(caller, :stop)
    end)

    for _ <- callers, do: assert_receive({:caller, _}, 1_000)

    # Entry into await proves each public stop accepted the original control;
    # a marker sent before Runtime.stop cannot establish that barrier.
    for caller <- callers do
      assert_receive {:trace, ^caller, :call, {ShutdownControl, :await, 3}}, 1_000
    end

    eventually(fn -> match?(%{stop_records: 1, phase: 1}, ShutdownControl.stats(table)) end)
    Process.sleep(20)
    assert %{stop_records: 1} = ShutdownControl.stats(table)
    {:messages, messages} = Process.info(guard, :messages)
    assert Enum.count(messages, &(&1 == :shutdown_control)) == 1
    refute Enum.any?(messages, &match?({:"$gen_call", _, {:stop, _}}, &1))
    {:messages, messages} = Process.info(observer, :messages)
    assert Enum.count(messages, &(&1 == :shutdown_wake)) <= 1
    :sys.resume(observer)

    for _ <- callers,
        do:
          assert_receive(
            {:result, result} when result in [:ok, {:error, :shutdown_cleanup_unconfirmed}],
            1_000
          )

    refute Process.alive?(root)
  end

  test "caller suspended after accepted stop cannot consume a late success or retain EXIT messages" do
    {root, ref, table, guard, _observer} = runtime(200, owned: true)
    assert_receive {:owned, _owner}
    :sys.suspend(guard)
    parent = self()

    caller =
      spawn(fn ->
        result = Runtime.stop(ref)

        send(
          parent,
          {:late_result, result, Process.info(self(), :messages),
           Process.info(self(), :trap_exit)}
        )
      end)

    eventually(fn -> match?(%{stop_records: 1}, ShutdownControl.stats(table)) end)
    %{cutoff: cutoff} = ShutdownControl.stats(table)
    :erlang.suspend_process(caller)
    root_monitor = Process.monitor(root)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _}, 400
    Process.sleep(Deadline.remaining(cutoff) + 1)
    :erlang.resume_process(caller)

    assert_receive {:late_result, {:error, :shutdown_cleanup_unconfirmed}, {:messages, []},
                    {:trap_exit, false}},
                   300
  end

  test "authority death fails the exact root closed and does not adopt borrowed PIDs" do
    {root, ref, table, guard, observer} = runtime(200)
    :sys.suspend(guard)
    borrowed = spawn(fn -> receive do: (:stop -> :ok) end)
    assert {:error, :invalid_owned_process} = ShutdownControl.track(table, borrowed, :worker)
    monitor = Process.monitor(root)
    observer_monitor = Process.monitor(observer)
    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :killed}
    assert {:error, :runtime_unavailable} = Runtime.request(ref, message(1))
    refute_receive {:callback, _}
    assert {:error, :shutdown_control_unavailable} = Runtime.stop(ref)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 300
    assert Process.alive?(borrowed)
    send(borrowed, :stop)
  end

  test "guard sees authority loss without another stop caller" do
    {root, _ref, _table, _guard, observer} = runtime(200)
    monitor = Process.monitor(root)
    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 300
  end

  test "oversized stop reason is rejected before closing a healthy runtime" do
    {root, ref, table, _guard, _observer} = runtime(200)
    assert {:error, :shutdown_reason_too_large} = Runtime.stop(ref, String.duplicate("x", 4_096))
    assert %{stop_records: 0, phase: 0} = ShutdownControl.stats(table)
    assert {:ok, %{"result" => true}} = Runtime.request(ref, message(1))
    assert :ok = Runtime.stop(root, {:shutdown, :ordinary})
  end

  test "previous trap flag and foreign linked-exit semantics survive stop" do
    {root, ref, table, guard, _observer} = runtime(500)
    :sys.suspend(guard)
    parent = self()

    caller =
      spawn(fn ->
        linked = spawn_link(fn -> receive do: (:die -> exit(:foreign_failure)) end)
        send(parent, {:linked, linked})
        Runtime.stop(ref)
      end)

    assert_receive {:linked, linked}
    eventually(fn -> match?(%{stop_records: 1}, ShutdownControl.stats(table)) end)
    monitor = Process.monitor(caller)
    send(linked, :die)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :foreign_failure}, 300
    root_monitor = Process.monitor(root)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _}, 700

    {root, ref, _table, _guard, _observer} = runtime(200)
    old = Process.flag(:trap_exit, true)
    foreign = make_ref()
    send(self(), {:EXIT, foreign, :keep_this})
    assert :ok = Runtime.stop(ref)
    assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    assert_receive {:EXIT, ^foreign, :keep_this}
    Process.flag(:trap_exit, old)
    refute_receive {:EXIT, ^root, _}
  end

  test "admission replacement preserves control identity and whole-root replacement cannot inherit old stop" do
    {root, ref, table, guard, observer} = runtime(400)
    {:ok, route} = Admission.route(table)
    Process.exit(route.admission, :kill)

    eventually(fn ->
      match?(
        {:ok, %{admission: pid}} when pid != route.admission,
        Admission.route(table)
      ) and Initialization.ready?(table)
    end)

    assert {:ok, control} = ShutdownControl.lookup(table)
    assert ShutdownControl.observer(control) == observer
    assert :ets.lookup(table, :shutdown_guard) == [{:shutdown_guard, guard}]
    assert {:ok, %{"result" => true}} = Runtime.request(ref, message(9))
    assert :ok = Runtime.stop(ref)
    assert {:error, :runtime_unavailable} = Runtime.ref(ref)
    {replacement, replacement_ref, _, _, _} = runtime(400)
    assert {:error, :runtime_unavailable} = Runtime.stop(ref)
    assert Process.alive?(replacement)
    assert {:ok, %{"result" => true}} = Runtime.request(replacement_ref, message(10))
    assert :ok = Runtime.stop(replacement)
    refute Process.alive?(root)
  end

  test "newly created linked root cannot kill its nontrapping stop caller" do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, root} =
          Runtime.start_link(
            handler: Handler,
            handler_args: parent,
            dispatcher: Handler,
            shutdown_timeout_ms: 180,
            store_children: [[adapter: Owned, options: [parent: parent]]]
          )

        {:ok, ref} = Runtime.ref(root)
        send(parent, {:linked_root, self(), root, ref})
        receive do: (:stop -> :ok)
        result = Runtime.stop(ref)

        send(
          parent,
          {:linked_stop, result, Process.info(self(), :trap_exit),
           Process.info(self(), :messages)}
        )
      end)

    assert_receive {:owned, _owner}
    assert_receive {:linked_root, ^caller, root, ref}
    {guard, _observer} = runtime_guards(Ref.table(ref))
    :sys.suspend(guard)
    monitor = Process.monitor(caller)
    send(caller, :stop)

    assert_receive {:linked_stop, result, {:trap_exit, false}, {:messages, []}}
                   when result in [:ok, {:error, :shutdown_cleanup_unconfirmed}],
                   400

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    refute Process.alive?(root)
  end

  test "graceful stopper is registered before blocked Supervisor.stop and retires on actual DOWN" do
    {root, ref, table, guard, observer} = runtime(240, owned: true)
    assert_receive {:owned, owner}
    parent = self()
    caller = spawn(fn -> send(parent, {:graceful_result, Runtime.stop(ref)}) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:held_terminate, ^owner}
    stopper = :sys.get_state(guard).stopper
    assert is_pid(stopper) and Process.alive?(stopper)
    stopper_monitor = Process.monitor(stopper)

    assert_receive {:graceful_result, result}
                   when result in [:ok, {:error, :shutdown_cleanup_unconfirmed}],
                   500

    assert_receive {:DOWN, ^stopper_monitor, :process, ^stopper, _}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
    eventually(fn -> not Process.alive?(observer) end)
    refute Process.alive?(root)
    assert :ets.info(table) == :undefined
  end

  test "native supervising parent restarts a stopped permanent root without stale authority effects" do
    options = [
      handler: Handler,
      handler_args: self(),
      dispatcher: Handler,
      shutdown_timeout_ms: 200
    ]

    {:ok, parent} = Supervisor.start_link([{Runtime, options}], strategy: :one_for_one)
    Process.unlink(parent)
    [{Runtime, root, :supervisor, _modules}] = Supervisor.which_children(parent)
    {:ok, old_ref} = Runtime.ref(root)
    {:dictionary, dictionary} = Process.info(root, :dictionary)
    assert {:"$ancestors", [parent | _]} = List.keyfind(dictionary, :"$ancestors", 0)
    assert :ok = Runtime.stop(old_ref)

    eventually(fn ->
      match?(
        [{Runtime, pid, :supervisor, _}] when is_pid(pid) and pid != root,
        Supervisor.which_children(parent)
      )
    end)

    [{Runtime, replacement, :supervisor, _}] = Supervisor.which_children(parent)
    assert {:ok, %{"result" => true}} = Runtime.request(replacement, message(20))
    assert {:error, :runtime_unavailable} = Runtime.stop(old_ref)
    assert Process.alive?(replacement)
    assert :ok = Supervisor.terminate_child(parent, Runtime)
    eventually(fn -> not Process.alive?(replacement) end)
    assert :ok = Supervisor.stop(parent)
  end

  @tag timeout: 60_000
  test "native owned registration hits the live PID cap before effects and reaps exact obligations" do
    {root, _ref, table, _guard, observer} = runtime(3_000, owned: true)
    assert_receive {:owned, owner}
    {{:error, :ownership_capacity}, pids, rejected} = GenServer.call(owner, :fill, 45_000)
    assert %{owned: 16_384, capacity: 16_384} = ShutdownControl.stats(table)
    refute Process.alive?(rejected)
    {:messages, guard_messages} = Process.info(elem(runtime_guards(table), 0), :messages)
    assert length(guard_messages) <= 16_384
    started = Deadline.now()
    assert Runtime.stop(root) in [:ok, {:error, :shutdown_cleanup_unconfirmed}]
    assert Deadline.now() - started < 3_200
    eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end, 200)
    eventually(fn -> not Process.alive?(observer) end, 200)
  end

  test "forcing collection kills an authentic child published after the last force snapshot" do
    {root, _ref, table, guard, observer} = runtime(500, owned: true)
    assert_receive {:owned, producer}
    [child] = GenServer.call(producer, {:children, 1, false})
    child_monitor = Process.monitor(child)
    producer_monitor = Process.monitor(producer)
    :sys.suspend(guard)
    state = :sys.get_state(observer)
    :sys.suspend(observer)
    ledger = control_ledger(observer)
    started = Deadline.now() - 500
    assert {:ok, _control, _cutoff} = ShutdownControl.prepare(table, :normal, started)
    {:noreply, forcing, _timeout} = ShutdownControl.handle_info(:shutdown_wake, state)
    assert forcing.forcing
    assert_receive {:DOWN, ^producer_monitor, :process, ^producer, _}
    assert Process.alive?(child)
    refute Process.alive?(root)

    # The journal write is the constructor's publication window after it passed
    # the open-phase check. Its native producer is now actually DOWN.
    {token, _publication} = pending_registration(ledger, child, producer, 16_383)
    {:noreply, collected, _timeout} = ShutdownControl.handle_info(:timeout, forcing)
    assert :ets.member(ledger, {:owned_slot, 16_383})
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}

    {monitor, _entry} =
      Enum.find(collected.monitors, fn {_ref, entry} -> elem(entry, 0) == child end)

    assert_receive {:DOWN, ^monitor, :process, ^child, _}

    {:noreply, retired, _timeout} =
      ShutdownControl.handle_info({:DOWN, monitor, :process, child, :killed}, collected)

    refute :ets.member(ledger, {:owned_slot, 16_383})
    refute Map.has_key?(retired.children, {child, token})
    :sys.resume(observer)
    eventually(fn -> not Process.alive?(observer) end)
  end

  test "actual DOWN before guard watch reaps ownership metadata across native constructor churn" do
    {root, _ref, table, guard, observer} = runtime(500, owned: true)
    assert_receive {:owned, producer}
    :sys.suspend(guard)
    baseline = length(:ets.match_object(table, {{:runtime_owned, :_}, :_}))
    baseline_slots = ShutdownControl.stats(table).owned

    for _ <- 1..5 do
      children = GenServer.call(producer, {:children, 32, true})
      assert Enum.all?(children, &:ets.member(table, {:runtime_owned, &1}))
      refute Enum.any?(children, &Map.has_key?(:sys.get_state(guard).children, &1))
      monitors = Enum.map(children, &{&1, Process.monitor(&1)})
      Enum.each(children, &send(&1, :release))

      for {pid, monitor} <- monitors,
          do: assert_receive({:DOWN, ^monitor, :process, ^pid, :normal})

      eventually(fn ->
        length(:ets.match_object(table, {{:runtime_owned, :_}, :_})) == baseline and
          ShutdownControl.stats(table).owned == baseline_slots
      end)
    end

    :sys.resume(guard)
    assert :ok = Runtime.stop(root)
    eventually(fn -> not Process.alive?(observer) end)
  end

  test "child DOWN retains a pending publication until its last metadata write is fenced" do
    {root, _ref, table, guard, observer} = runtime(500, owned: true)
    assert_receive {:owned, producer}
    [child] = GenServer.call(producer, {:children, 1, false})
    :sys.suspend(guard)
    state = :sys.get_state(observer)
    :sys.suspend(observer)
    ledger = control_ledger(observer)
    {token, publication} = pending_registration(ledger, child, producer, 16_383)
    {:noreply, collected, _timeout} = ShutdownControl.handle_info(:timeout, state)

    {monitor, _entry} =
      Enum.find(collected.monitors, fn {_ref, entry} -> elem(entry, 0) == child end)

    send(child, :release)
    assert_receive {:DOWN, ^monitor, :process, ^child, :normal}

    {:noreply, pending, _timeout} =
      ShutdownControl.handle_info({:DOWN, monitor, :process, child, :normal}, collected)

    assert Map.has_key?(pending.pending_publications, {child, token})
    assert :ets.member(ledger, {:owned_slot, 16_383})
    assert Process.alive?(producer)
    :ets.insert(table, {{:runtime_owned, child}, :worker})
    :atomics.put(publication, 1, 1)
    {:noreply, retired, _timeout} = ShutdownControl.handle_info(:timeout, pending)
    refute :ets.member(table, {:runtime_owned, child})
    refute :ets.member(ledger, {:owned_slot, 16_383})
    assert retired.pending_publications == %{}
    :sys.resume(observer)
    :sys.resume(guard)
    assert :ok = Runtime.stop(root)
  end

  defp control_ledger(observer) do
    Enum.find(:ets.all(), fn table ->
      :ets.info(table, :owner) == observer and :ets.info(table, :name) == ShutdownControl
    end)
  end

  defp pending_registration(ledger, child, producer, index) do
    token = make_ref()
    publication = :atomics.new(1, [])

    assert :ets.insert_new(
             ledger,
             {{:owned_slot, index}, token, child, :worker, producer, publication}
           )

    assert :ets.insert_new(ledger, {{:owned, child}, token, index, :worker, publication})
    {token, publication}
  end

  defp runtime(budget, opts \\ []) do
    owned = if opts[:owned], do: [[adapter: Owned, options: [parent: self()]]], else: []

    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: self(),
        dispatcher: Handler,
        shutdown_timeout_ms: budget,
        init_timeout_ms: 5_000,
        store_children: owned
      )

    Process.unlink(root)
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    {guard, observer} = runtime_guards(table)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {root, ref, table, guard, observer}
  end

  defp runtime_guards(table) do
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)
    {:ok, control} = ShutdownControl.lookup(table)
    {guard, ShutdownControl.observer(control)}
  end

  defp message(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}
  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end

  defp eventually(_fun, 0), do: flunk("condition did not settle")
end
