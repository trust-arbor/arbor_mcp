defmodule Arbor.MCP.Server.RuntimeInitializationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Transport.Test

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    ExecutionSupervisor,
    Initialization,
    OutputController,
    OutputLedger,
    Ref
  }

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      send(
        opts[:parent],
        {:initializing, opts[:label], self(), Enum.at(Process.get(:"$ancestors"), 1)}
      )

      if opts[:hold], do: receive(do: (:release_init -> :ok))
      {:ok, %{parent: opts[:parent], label: opts[:label], count: 0}}
    end

    def dispatch(request, _handler, state, _opts) do
      if request["method"] == "hold" do
        send(state.parent, {:working, state.label, self()})
        receive do: (:release_work -> :ok)
      end

      next = state.count + 1

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => next},
       %{state | count: next}}
    end
  end

  defmodule Replay do
    use GenServer
    alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceOperation}

    def runtime_service_capabilities,
      do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}

    def consume(_id, _expires_at, _opts), do: :ok

    def runtime_service_binding(_server, _timeout),
      do: %{address: %{timeout: 1_000}, read_address: nil}

    def operate(:consume, _args, context, _opts),
      do: ServiceOperation.validate_context(context)

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: opts[:init_timeout_ms] || 1_000)

    @impl true
    def init(opts) do
      :ok = ServiceAdapter.watch_owned(opts)
      send(opts[:parent], {:replay_initializing, self()})
      if opts[:hold], do: receive(do: (:release_replay -> :ok))
      {:ok, opts}
    end
  end

  defmodule DelayedEdge do
    use GenServer
    alias Arbor.MCP.Server.Runtime.{Initialization, Ref}

    def start_link(opts) do
      table = Ref.table(opts[:runtime])

      with :ok <- Initialization.edge_start(table),
           do: GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(table))
    end

    @impl true
    def init(opts) do
      table = Ref.table(opts[:runtime])
      :ok = Initialization.watch(table, self())
      send(opts[:parent], {:edge_initializing, self(), table})
      receive do: (:release_edge -> :ok)
      :ets.insert(table, {:edge, self()})
      {:ok, opts}
    end
  end

  defmodule ConfigBlock do
    def runtime_service_capabilities do
      parent = :persistent_term.get({__MODULE__, :parent})
      send(parent, {:config_check, self()})
      receive do: (:release_config -> %{bounded_startup: 1})
    end

    def start_link(_opts), do: {:error, :must_not_start}
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  defmodule GuardStartupRoot do
    use Supervisor
    alias Arbor.MCP.Server.Runtime.{Config, Deadline, Initialization, ShutdownGuard}

    def start_link(opts),
      do: Initialization.start_supervisor(__MODULE__, opts, Deadline.now() + 500)

    @impl true
    def init(opts) do
      {:ok, config} =
        Config.new(
          handler: Handler,
          dispatcher: Handler,
          init_timeout_ms: 120,
          shutdown_timeout_ms: 40
        )

      table = :ets.new(__MODULE__, [:set, :public])
      {:ok, context} = Initialization.begin(table, config, :runtime)
      send(opts[:parent], {:before_guard, self(), table, context})
      receive do: (:start_guard -> :ok)

      case ShutdownGuard.start(self(), table, config) do
        {:ok, _guard} -> Supervisor.init([], strategy: :one_for_one)
        {:error, _reason} -> exit(:runtime_init_timeout)
      end
    end
  end

  defmodule BlockingVia do
    def runtime_name_capabilities, do: %{finite_lookup: 1}
    def whereis_name(_name), do: :undefined

    def register_name(parent, pid) do
      Kernel.send(parent, {:registering_name, pid})
      receive do: (:release_registration -> :yes)
    end

    def unregister_name(_name), do: :ok
    def send(_name, _message), do: :ok
  end

  defmodule UnqualifiedVia do
    def whereis_name(parent) do
      send(parent, :unqualified_lookup_ran)
      receive do: (:release_lookup -> :undefined)
    end
  end

  test "native name registration is bounded before runtime initialization for a non-trapping caller" do
    parent = self()

    options =
      runtime_opts(label: :named_block, name: {:via, BlockingVia, parent}, init_timeout_ms: 100)

    {caller, monitor} =
      spawn_monitor(fn ->
        result = Runtime.start_link(options)
        send(parent, {:registration_result, self(), result})
        {:messages, messages} = Process.info(self(), :messages)
        send(parent, {:registration_mailbox, messages})
      end)

    assert_receive {:registering_name, registering}, 500
    assert_receive {:registration_result, ^caller, {:error, :runtime_init_timeout}}, 500
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 500
    assert_receive {:registration_mailbox, []}
    eventually(fn -> not Process.alive?(registering) end)
    refute_receive {:initializing, :named_block, _scheduler, _root}, 20
  end

  test "unqualified via lookups fail before their initiating-caller callback can run" do
    assert {:error, {:invalid_runtime_name, :finite_lookup_required}} =
             Runtime.start_link(
               runtime_opts(label: :invalid_name, name: {:via, UnqualifiedVia, self()})
             )

    refute_receive :unqualified_lookup_ran, 20
    refute_receive {:initializing, :invalid_name, _scheduler, _root}, 20
  end

  test "named native supervisors preserve real OTP parent links and supervisor identity" do
    registry = __MODULE__.NameRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    for {name, id} <- [
          {__MODULE__.LocalRuntime, :local},
          {{:global, {__MODULE__, self()}}, :global},
          {{:via, Registry, {registry, self()}}, :via},
          {nil, :unnamed}
        ] do
      parent =
        start_supervised!(%{
          id: id,
          start:
            {Supervisor, :start_link,
             [[{Runtime, runtime_opts(label: id, name: name)}], [strategy: :one_for_one]]},
          type: :supervisor
        })

      [{_, root, :supervisor, _modules}] = Supervisor.which_children(parent)
      assert :proc_lib.translate_initial_call(root) == {:supervisor, Runtime, 1}
      {:dictionary, dictionary} = Process.info(root, :dictionary)
      assert hd(Keyword.fetch!(dictionary, :"$ancestors")) == parent
      {:links, links} = Process.info(root, :links)
      assert parent in links
      assert {:ok, _runtime_ref} = Runtime.ref(root)

      for {_, child, :supervisor, _} <- Supervisor.which_children(root) do
        {:dictionary, child_dictionary} = Process.info(child, :dictionary)
        assert GenServer.whereis(hd(Keyword.fetch!(child_dictionary, :"$ancestors"))) == root
        {:links, child_links} = Process.info(child, :links)
        assert root in child_links
        assert match?({:supervisor, _, 1}, :proc_lib.translate_initial_call(child))
      end
    end
  end

  test "service and handler initialization share one original runtime cutoff" do
    caller =
      start_async(
        label: :combined,
        hold: true,
        init_timeout_ms: 400,
        services: [replay_cache: [adapter: Replay, options: [parent: self(), hold: true]]]
      )

    assert_receive {:replay_initializing, service}, 1_000
    {:dictionary, dictionary} = Process.info(service, :dictionary)
    [cohort, root | _] = Keyword.fetch!(dictionary, :"$ancestors")
    {:ok, runtime} = Runtime.ref(root)
    {:ok, context} = Initialization.current(Ref.table(runtime))
    sleep_until(context.deadline - 100)
    send(service, :release_replay)
    assert_receive {:initializing, :combined, handler, ^root}, 500
    refute Process.alive?(cohort) == false
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500

    eventually(fn ->
      Enum.all?([root, handler, service, context.observer], &(not Process.alive?(&1)))
    end)
  end

  test "admission is closed until the edge and final root barrier complete" do
    caller =
      start_async(label: :edge, init_timeout_ms: 1_000, edge: {DelayedEdge, [parent: self()]})

    assert_receive {:edge_initializing, edge, table}, 1_000
    assert {:error, :runtime_unavailable} = Admission.route(table)
    assert {:ok, %{status: :starting} = context} = Initialization.current(table)
    send(edge, :release_edge)
    assert_receive {:startup_result, ^caller, {:ok, root}}, 1_000
    assert {:ok, %{initialization_epoch: epoch}} = Admission.route(table)
    assert epoch == context.epoch
    assert Initialization.ready?(table)
    assert :ok = Runtime.stop(root)
    eventually(fn -> not Process.alive?(context.observer) end)
  end

  test "a caller suspended after ready rejects queued success at its original cutoff" do
    caller = start_async(label: :late, hold: true, init_timeout_ms: 250)
    assert_receive {:initializing, :late, handler, root}, 1_000
    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    {:ok, context} = Initialization.current(table)
    :erlang.suspend_process(caller)
    on_exit(fn -> safe_resume(caller) end)
    send(handler, :release_init)
    eventually(fn -> Initialization.ready?(table) end)
    sleep_until(context.deadline + 30)
    :erlang.resume_process(caller)
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500
    eventually(fn -> not Process.alive?(root) and not Process.alive?(handler) end)
    send(caller, {:mailbox, self()})
    assert_receive {:startup_mailbox, messages}
    refute Enum.any?(messages, &match?({_, {:ok, _}}, &1))
  end

  test "configuration capability checks cannot outlive the original startup wait" do
    :persistent_term.put({ConfigBlock, :parent}, self())
    on_exit(fn -> :persistent_term.erase({ConfigBlock, :parent}) end)

    caller =
      start_async(
        label: :configuration,
        init_timeout_ms: 100,
        store_children: [[adapter: ConfigBlock]]
      )

    assert_receive {:config_check, helper}, 500
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500
    eventually(fn -> not Process.alive?(helper) end)
    refute_receive {:initializing, :configuration, _, _}, 20
  end

  test "late queued success returns a timeout to a non-trapping caller without killing it" do
    parent = self()
    options = runtime_opts(label: :non_trapping, hold: true, init_timeout_ms: 250)

    caller =
      spawn(fn ->
        result =
          Runtime.start_link(options)

        send(parent, {:non_trapping_result, self(), result})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:initializing, :non_trapping, scheduler, root}, 500
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    {:ok, context} = Initialization.current(table)
    :erlang.suspend_process(caller)
    on_exit(fn -> safe_resume(caller) end)
    send(scheduler, :release_init)
    eventually(fn -> Initialization.ready?(table) end)
    sleep_until(context.deadline + 30)
    :erlang.resume_process(caller)
    assert_receive {:non_trapping_result, ^caller, {:error, :runtime_init_timeout}}, 500
    assert Process.alive?(caller)
    eventually(fn -> not Process.alive?(root) and not Process.alive?(scheduler) end)
  end

  test "startup timeout never stops a borrowed service or sibling runtime" do
    external = start_supervised!({Replay, parent: self()})
    sibling = runtime(label: :sibling)

    caller =
      start_async(
        label: :borrowed,
        hold: true,
        init_timeout_ms: 100,
        services: [
          replay_cache: [
            ownership: :borrowed,
            adapter: Replay,
            server: external,
            namespace: "borrowed-logical-endpoint"
          ]
        ]
      )

    assert_receive {:initializing, :borrowed, handler, root}, 500
    {:ok, ref} = Runtime.ref(root)
    refute :ets.member(Ref.table(ref), {:runtime_owned, external})
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500
    eventually(fn -> not Process.alive?(root) and not Process.alive?(handler) end)
    assert Process.alive?(external) and Process.alive?(sibling)
    assert {:ok, %{"result" => 1}} = Runtime.request(sibling, request(1))
  end

  test "genuine service replacement gets a fresh shared deadline and retires its observer" do
    root = runtime(label: :restart, init_timeout_ms: 500)
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    {:ok, first} = Initialization.current(table)
    [{:services_generation, _, store}] = :ets.lookup(table, :services_generation)
    Process.sleep(10)
    Process.exit(store, :kill)

    eventually(fn ->
      case Initialization.current(table) do
        {:ok, %{status: :ready, epoch: epoch}} -> epoch != first.epoch
        _ -> false
      end
    end)

    {:ok, second} = Initialization.current(table)
    assert second.deadline > first.deadline
    assert second.scope == :cohort
    assert {:ok, ^ref} = Runtime.ref(root)
    assert {:ok, %{"result" => 1}} = Runtime.request(ref, request(1))
    eventually(fn -> not Process.alive?(second.observer) end)
    assert :ets.match_object(table, {{:initialization_complete, first.epoch, :_}, :_}) == []
  end

  test "execution-only replacement resets state while preserving the runtime and healthy edge" do
    root =
      start_supervised!(
        {HandlerServer,
         handler: Handler,
         handler_args: [parent: self(), label: :execution],
         dispatcher: Handler,
         transport: :test,
         init_timeout_ms: 500}
      )

    {:ok, runtime} = Runtime.ref(root)
    {:ok, edge} = Runtime.edge(root)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, request(1))
    table = Ref.table(runtime)
    {:ok, old} = Initialization.current(table)
    {:ok, route} = Admission.route(table)
    Process.exit(route.scheduler, :kill)

    eventually(fn ->
      case Initialization.current(table) do
        {:ok, %{status: :ready, epoch: epoch}} -> epoch != old.epoch
        _ -> false
      end
    end)

    assert {:ok, ^edge} = Runtime.edge(runtime)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, request(2))
    {:ok, latest} = Initialization.current(table)
    assert latest.scope == :execution
  end

  test "whole execution-supervisor replacement waits for the new edge and rejects old proposals" do
    root =
      start_supervised!(
        {HandlerServer,
         handler: Handler,
         handler_args: [parent: self(), label: :execution_root],
         dispatcher: Handler,
         transport: :test,
         init_timeout_ms: 1_000}
      )

    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    {:ok, edge} = Runtime.edge(ref)
    {:ok, old_context} = Initialization.current(table)
    {:ok, route} = Admission.route(table)
    [{:services_generation, _, stores}] = :ets.lookup(table, :services_generation)

    assert {:ok, token} =
             Runtime.submit(ref, %{"jsonrpc" => "2.0", "id" => 8, "method" => "hold"})

    assert_receive {:working, :execution_root, worker}, 500
    :sys.suspend(route.scheduler)
    send(worker, :release_work)
    eventually(fn -> prepared_ticket(route.scheduler) != nil end)
    ticket = prepared_ticket(route.scheduler)
    {_, execution, _, _} = List.keyfind(Supervisor.which_children(root), ExecutionSupervisor, 0)
    Process.exit(execution, :kill)
    assert {:error, :runtime_restarted} = Runtime.await(token, 1_000)

    eventually(fn ->
      case Initialization.current(table) do
        {:ok, %{status: :ready, epoch: epoch}} -> epoch != old_context.epoch
        _ -> false
      end
    end)

    assert {:ok, ^ref} = Runtime.ref(root)
    assert {:ok, replacement_edge} = Runtime.edge(ref)
    refute replacement_edge == edge
    assert Process.alive?(stores)
    assert {:error, :output_unavailable} = OutputLedger.value(ticket)
    assert {:ok, %{"result" => 1}} = Runtime.request(ref, request(9))
    refute_receive {:arbor_mcp_runtime, ^token, _late_proposal}, 20
    {:ok, current} = Initialization.current(table)
    assert current.scope == :runtime
  end

  test "edge recovery preserves committed state and retires prepared output from the old peer" do
    root =
      start_supervised!(
        {HandlerServer,
         handler: Handler,
         handler_args: [parent: self(), label: :edge_state],
         dispatcher: Handler,
         transport: :test,
         init_timeout_ms: 1_000}
      )

    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    assert_receive {:initializing, :edge_state, _original_owner, ^root}, 500
    assert {:ok, %{"result" => 1}} = Runtime.request(ref, request(1))
    {:ok, transport} = Test.connect(server: root)
    {:ok, route} = Admission.route(table)
    {:ok, old_context} = Initialization.current(table)
    {:ok, old_edge} = Runtime.edge(ref)

    assert {:ok, _} =
             Test.send_message(%{"jsonrpc" => "2.0", "id" => 8, "method" => "hold"}, transport)

    assert_receive {:working, :edge_state, worker}, 500
    :sys.suspend(route.scheduler)
    on_exit(fn -> safe_sys_resume(route.scheduler) end)
    send(worker, :release_work)
    eventually(fn -> prepared_ticket(route.scheduler) != nil end)
    ticket = prepared_ticket(route.scheduler)
    Process.exit(old_edge, :kill)

    eventually(fn ->
      case Runtime.edge(ref) do
        {:ok, edge} -> edge != old_edge and Initialization.ready?(table)
        _ -> false
      end
    end)

    assert {:ok, ^ref} = Runtime.ref(root)
    {:ok, current_route} = Admission.route(table)
    assert current_route.generation == route.generation
    assert {:error, _reason} = OutputLedger.value(ticket)
    {:ok, peer_transport} = Test.connect(server: root)
    assert {:error, :runtime_init_timeout} = OutputController.connect_startup(table, old_context)
    assert :ets.lookup(table, :output_peer) != []
    assert {:ok, _} = Test.send_message(request(9), peer_transport)
    :sys.resume(route.scheduler)
    assert_receive {:transport_message, encoded_response}, 1_000
    assert %{"id" => 9, "result" => 2} = Jason.decode!(encoded_response)
    refute_receive {:initializing, :edge_state, _new_state_owner, _root}, 20
  end

  test "whole runtime failure under a real parent replaces the logical reference and isolates siblings" do
    opts = [
      handler: Handler,
      handler_args: [parent: self(), label: :managed],
      dispatcher: Handler,
      transport: :test
    ]

    children = [
      Supervisor.child_spec({HandlerServer, opts}, id: :managed),
      Supervisor.child_spec({Runtime, runtime_opts(label: :healthy)}, id: :healthy)
    ]

    parent =
      start_supervised!(%{
        id: :real_parent,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

    children = Supervisor.which_children(parent)
    {_, old_root, _, _} = List.keyfind(children, :managed, 0)
    {_, sibling, _, _} = List.keyfind(children, :healthy, 0)
    {:ok, old_ref} = Runtime.ref(old_root)
    assert {:ok, _edge} = Runtime.edge(old_root)
    assert {:ok, %{"result" => 1}} = Runtime.request(old_ref, request(1))
    Process.exit(old_root, :kill)

    eventually(fn ->
      case List.keyfind(Supervisor.which_children(parent), :managed, 0) do
        {_, pid, _, _} when is_pid(pid) -> pid != old_root
        _ -> false
      end
    end)

    {_, replacement, _, _} = List.keyfind(Supervisor.which_children(parent), :managed, 0)
    assert {:error, :runtime_unavailable} = Runtime.ref(old_ref)
    assert {:ok, new_ref} = Runtime.ref(replacement)
    refute old_ref == new_ref
    assert {:ok, %{"result" => 1}} = Runtime.request(new_ref, request(2))
    assert Process.alive?(sibling)
  end

  test "native guard startup stays finite before service metadata exists" do
    parent = self()

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:guard_result, GuardStartupRoot.start_link(parent: parent)})
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:before_guard, root, table, context}, 500
    :erlang.suspend_process(context.observer)
    on_exit(fn -> safe_resume(context.observer) end)
    send(root, :start_guard)
    eventually(fn -> :ets.match_object(table, {{:runtime_owned, :_}, :guard}) != [] end)
    [{{:runtime_owned, guard}, :guard}] = :ets.match_object(table, {{:runtime_owned, :_}, :guard})
    assert :ets.lookup(table, :services_startup) == []
    assert_receive {:guard_result, {:error, :runtime_init_timeout}}, 500
    eventually(fn -> not Process.alive?(root) and not Process.alive?(guard) end)
    :erlang.resume_process(context.observer)
    eventually(fn -> not Process.alive?(context.observer) end)
  end

  test "a suspended guard during actual runtime startup cannot retain owned descendants" do
    sibling = runtime(label: :guard_sibling)

    caller =
      start_async(
        label: :guard_stall,
        init_timeout_ms: 200,
        services: [replay_cache: [adapter: Replay, options: [parent: self(), hold: true]]]
      )

    assert_receive {:replay_initializing, service}, 500
    {:dictionary, dictionary} = Process.info(service, :dictionary)
    [_cohort, root | _] = Keyword.fetch!(dictionary, :"$ancestors")
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)
    {:ok, context} = Initialization.current(table)
    :sys.suspend(guard)
    send(service, :release_replay)
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500

    eventually(fn ->
      Enum.all?([root, guard, service, context.observer], &(not Process.alive?(&1)))
    end)

    assert Process.alive?(sibling)
  end

  test "a suspended admission owner cannot publish late readiness" do
    caller = start_async(label: :admission_stall, hold: true, init_timeout_ms: 200)
    assert_receive {:initializing, :admission_stall, scheduler, root}, 500
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    [{:admission, admission}] = :ets.lookup(table, :admission)
    {:ok, context} = Initialization.current(table)
    :sys.suspend(admission)
    send(scheduler, :release_init)
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500

    eventually(fn ->
      Enum.all?([root, scheduler, admission, context.observer], &(not Process.alive?(&1)))
    end)

    assert :undefined == :ets.info(table)
  end

  test "root death before startup expiry cannot renew a suspended guard's cleanup budget" do
    sibling = runtime(label: :root_death_sibling)

    caller =
      start_async(
        label: :root_death_guard_stall,
        init_timeout_ms: 200,
        services: [replay_cache: [adapter: Replay, options: [parent: self(), hold: true]]]
      )

    assert_receive {:replay_initializing, service}, 500
    {:dictionary, dictionary} = Process.info(service, :dictionary)
    [_cohort, root | _] = Keyword.fetch!(dictionary, :"$ancestors")
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)
    {:ok, context} = Initialization.current(table)

    # Force root DOWN to be queued before the delayed observer's timeout. The
    # native caller still returns against its original 200ms cutoff; the guard
    # must not acquire a fresh normal-shutdown budget when that DOWN is read.
    :sys.suspend(guard)
    :erlang.suspend_process(context.observer)
    :erlang.suspend_process(caller)
    on_exit(fn -> safe_resume(context.observer) end)
    on_exit(fn -> safe_resume(caller) end)
    on_exit(fn -> Process.exit(guard, :kill) end)
    Process.exit(root, :kill)
    sleep_until(context.deadline)
    :erlang.resume_process(caller)
    assert_receive {:startup_result, ^caller, {:error, :runtime_init_timeout}}, 500
    :erlang.resume_process(context.observer)

    eventually(fn ->
      Enum.all?([root, guard, service, context.observer], &(not Process.alive?(&1)))
    end)

    assert Process.alive?(sibling)
    assert Process.alive?(caller)
  end

  test "repeated genuine replacements retain only current proofs and reject retired epochs" do
    root = runtime(label: :retention, init_timeout_ms: 500)
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)
    {:ok, first} = Initialization.current(table)
    eventually(fn -> not Process.alive?(first.observer) end)

    eventually(fn ->
      Enum.all?(:ets.match_object(table, {{:runtime_owned, :_}, :_}), fn
        {{:runtime_owned, pid}, _role} -> Process.alive?(pid)
      end)
    end)

    baseline_owned_count = length(:ets.match_object(table, {{:runtime_owned, :_}, :_}))

    for _cycle <- 1..2 do
      {:ok, old} = Initialization.current(table)
      [{:services_generation, _, store}] = :ets.lookup(table, :services_generation)
      Process.exit(store, :kill)

      eventually(fn ->
        case Initialization.current(table) do
          {:ok, %{status: :ready, epoch: epoch}} -> epoch != old.epoch
          _ -> false
        end
      end)

      eventually(fn ->
        Enum.all?(:ets.match_object(table, {{:runtime_owned, :_}, :_}), fn
          {{:runtime_owned, pid}, _role} -> Process.alive?(pid)
        end)
      end)

      {:ok, replacement} = Initialization.current(table)
      assert :ok = Initialization.abort(table, old)
      assert {:error, :runtime_init_timeout} = Admission.publish_ready(table, old)
      assert Initialization.ready?(table)
      eventually(fn -> not Process.alive?(replacement.observer) end)

      eventually(fn ->
        length(:ets.match_object(table, {{:runtime_owned, :_}, :_})) == baseline_owned_count
      end)

      assert length(:ets.match_object(table, {{:runtime_owned, :_}, :_})) == baseline_owned_count
      assert length(:ets.match_object(table, {{:initialization_complete, :_, :_}, :_})) == 2
    end

    assert :ets.match_object(table, {{:initialization_complete, first.epoch, :_}, :_}) == []
    assert {:ok, %{"result" => 1}} = Runtime.request(ref, request(7))
  end

  test "legacy and conflicting generic store specs fail before supported startup effects" do
    for {descriptors, reason} <- [
          {[{Replay, [parent: self()]}], :owned_descriptor_required},
          {[[adapter: Replay, id: :same], [adapter: Replay, id: :same]], :duplicate_id},
          {[[adapter: Replay, id: :tasks]], :reserved_id}
        ] do
      assert {:error, {:invalid_owned_store, _index, ^reason}} =
               Runtime.start_link(runtime_opts(label: :invalid, store_children: descriptors))

      refute_receive {:initializing, :invalid, _, _}, 10
      refute_receive {:replay_initializing, _}, 10
    end
  end

  defp runtime(opts), do: start_supervised!({Runtime, runtime_opts(opts)})

  defp runtime_opts(opts) do
    {handler_args, options} = Keyword.split(opts, [:label, :hold])

    [
      handler: Handler,
      handler_args: [parent: self()] ++ handler_args,
      dispatcher: Handler
    ] ++ options
  end

  defp start_async(opts) do
    parent = self()
    options = runtime_opts(opts)

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        result = Runtime.start_link(options)
        send(parent, {:startup_result, self(), result})
        caller_loop()
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    caller
  end

  defp caller_loop do
    receive do
      {:mailbox, parent} ->
        {:messages, messages} = Process.info(self(), :messages)
        send(parent, {:startup_mailbox, messages})
        caller_loop()

      _exit ->
        caller_loop()
    end
  end

  defp safe_sys_resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp prepared_ticket(scheduler) do
    case Process.info(scheduler, :messages) do
      {:messages, messages} ->
        Enum.find_value(messages, fn
          {_task_ref, {:prepared, _kind, _state, ticket}} -> ticket
          _other -> nil
        end)

      _dead ->
        nil
    end
  end

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "inc"}
  defp sleep_until(deadline), do: Process.sleep(max(0, deadline - Deadline.now()))

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: flunk("runtime initialization did not settle")

  defp eventually(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(predicate, attempts - 1)
        )
  end
end
