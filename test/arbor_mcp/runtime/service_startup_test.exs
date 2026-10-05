defmodule Arbor.MCP.Server.RuntimeServiceStartupTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Config,
    Deadline,
    Initialization,
    Ref,
    ServiceAdapter,
    ServiceBinding,
    ShutdownGuard,
    StoreSupervisor
  }

  defmodule Handler do
    def init(parent), do: {:ok, parent}

    def dispatch(request, _handler, state, _opts),
      do: {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "ok"}, state}
  end

  defmodule PreReturnReplay do
    use GenServer
    alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceOperation}

    def runtime_service_capabilities, do: %{bounded_startup: 1, bounded_operations: 1}
    def consume(_jti, _expires_at, _opts), do: :ok

    def runtime_service_binding(_server, _timeout),
      do: %{address: %{timeout: 1_000}, read_address: nil}

    def operate(:consume, _args, context, _opts),
      do: ServiceOperation.validate_context(context)

    def start_link(opts) do
      result = GenServer.start_link(__MODULE__, opts, timeout: opts[:init_timeout_ms])

      if opts[:hold_return] do
        send(opts[:parent], {:pre_return_blocked, self(), result})
        receive do: (:release_start -> :ok)
      end

      result
    end

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      :ok = ServiceAdapter.watch_owned(opts)
      send(opts[:parent], {:owned_started, self(), hd(Process.get(:"$ancestors"))})
      {:ok, opts}
    end

    @impl true
    def terminate(reason, opts) do
      send(opts[:parent], {:owned_terminated, self(), reason})
      :ok
    end
  end

  defmodule BlockingHook do
    use GenServer
    alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceOperation}

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: opts[:init_timeout_ms] || 1_000)

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def runtime_service_capabilities,
      do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}

    def runtime_service_binding(server, _remaining),
      do: GenServer.call(server, :binding, :infinity)

    def operate(_operation, _args, _context, _opts), do: {:error, :unused}
    def lease_active?(_id, _epoch, _opts), do: false

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      :ok = ServiceAdapter.watch_owned(opts)
      {:ok, address} = ServiceOperation.new([])
      {:ok, %{parent: opts[:parent], address: address}}
    end

    @impl true
    def handle_call(:binding, from, state) do
      send(state.parent, {:binding_blocked, self(), elem(from, 0)})
      receive do: (:release_binding -> :ok)
      {:reply, %{address: state.address, read_address: nil}, state}
    end

    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule MustNotStart do
    def start_link(opts) do
      send(opts[:parent], :unexpected_start_effect)
      {:error, :unexpected_start}
    end
  end

  test "cohort cutoff interrupts an adapter blocked after creating its registered owner" do
    {table, config, guard} =
      cohort_fixture(
        replay_cache: [adapter: PreReturnReplay, options: [parent: self(), hold_return: true]]
      )

    start_cohort(table, config)
    assert_receive {:owned_started, owner, cohort}, 500
    assert_receive {:pre_return_blocked, ^cohort, {:ok, ^owner}}, 500
    assert_receive {:cohort_result, {:error, :service_start_timeout}, elapsed}, 500
    assert elapsed < 400
    eventually(fn -> not Process.alive?(owner) and not Process.alive?(cohort) end)

    assert [{:services_startup, _generation, _deadline, :failed}] =
             :ets.lookup(table, :services_startup)

    assert :ets.lookup(table, :services_generation) == []
    assert :ets.match_object(table, {{:service, :_}, :_}) == []
    assert :ets.match_object(table, {{:service_start_owned, :_, :_}, :_}) == []
    assert :ets.lookup(table, :service_start_observer) == []
    eventually(fn -> :sys.get_state(guard).children == %{} end)
  end

  test "suspended guard cannot extend cohort startup or leave registered owned children alive" do
    sibling = runtime()

    {table, config, guard} =
      cohort_fixture(
        replay_cache: [adapter: PreReturnReplay, options: [parent: self(), hold_return: true]]
      )

    start_cohort(table, config)
    assert_receive {:owned_started, owner, cohort}, 500
    assert_receive {:pre_return_blocked, ^cohort, {:ok, ^owner}}, 500
    :sys.suspend(guard)
    on_exit(fn -> safe_resume(guard) end)
    send(cohort, :release_start)
    assert_receive {:cohort_result, {:error, :service_start_timeout}, elapsed}, 500
    assert elapsed < 400
    eventually(fn -> not Process.alive?(owner) and not Process.alive?(cohort) end)
    assert :ets.lookup(table, :services_generation) == []
    assert :ets.match_object(table, {{:service_start_owned, :_, :_}, :_}) == []
    assert Process.alive?(sibling)
    :sys.resume(guard)
    eventually(fn -> :sys.get_state(guard).children == %{} end)
  end

  test "binding hook cutoff kills owned target and proxy while a borrowed target survives" do
    for ownership <- [:owned, :borrowed] do
      external =
        if ownership == :borrowed,
          do: start_supervised!({BlockingHook, parent: self()}),
          else: nil

      descriptor =
        if external,
          do: [
            ownership: :borrowed,
            adapter: BlockingHook,
            server: external,
            namespace: "stable-endpoint"
          ],
          else: [adapter: BlockingHook, options: [parent: self()]]

      {table, config, _guard} = cohort_fixture(sessions: descriptor)
      start_cohort(table, config)
      assert_receive {:binding_blocked, target, binding_owner}, 500
      assert_receive {:cohort_result, {:error, :service_start_timeout}, elapsed}, 500
      assert elapsed < 400
      eventually(fn -> not Process.alive?(binding_owner) end)
      assert :ets.lookup(table, :services_generation) == []
      assert :ets.lookup(table, {:service, :sessions}) == []

      if external do
        assert target == external and Process.alive?(external)
        send(external, :release_binding)
        assert :pong = GenServer.call(external, :ping, 100)
      else
        eventually(fn -> not Process.alive?(target) end)
      end
    end
  end

  test "later children share the original cohort cutoff after an earlier adapter returns" do
    {table, config, _guard} =
      cohort_fixture(
        [
          replay_cache: [adapter: PreReturnReplay, options: [parent: self(), hold_return: true]],
          sessions: [adapter: BlockingHook, options: [parent: self()]]
        ],
        400
      )

    start_cohort(table, config)
    assert_receive {:owned_started, owner, cohort}, 500
    assert_receive {:pre_return_blocked, ^cohort, {:ok, ^owner}}, 500

    [{:services_startup, _generation, deadline, :starting}] =
      :ets.lookup(table, :services_startup)

    Process.sleep(max(0, deadline - Deadline.now() - 70))
    send(cohort, :release_start)
    assert_receive {:binding_blocked, target, ^cohort}, 500
    assert_receive {:cohort_result, {:error, :service_start_timeout}, elapsed}, 500
    assert elapsed < 600
    eventually(fn -> not Process.alive?(owner) and not Process.alive?(target) end)
    assert :ets.lookup(table, :services_generation) == []
  end

  test "observer retains acknowledged ownership when its startup caller's ETS table disappears" do
    {table, config, guard} =
      cohort_fixture(
        replay_cache: [adapter: PreReturnReplay, options: [parent: self(), hold_return: true]]
      )

    parent = self()

    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          {:"ETS-TRANSFER", ^table, ^parent, :start} ->
            :ok = Initialization.track(table, self())
            StoreSupervisor.start_link(table: table, config: config)
        end
      end)

    :ets.give_away(table, starter, :start)
    assert_receive {:owned_started, owner, cohort}, 500
    assert_receive {:pre_return_blocked, ^cohort, {:ok, ^owner}}, 500

    [{:service_start_observer, _generation, observer}] =
      :ets.lookup(table, :service_start_observer)

    :sys.suspend(guard)
    on_exit(fn -> safe_resume(guard) end)
    Process.exit(starter, :kill)

    eventually(fn ->
      :ets.info(table) == :undefined and not Process.alive?(owner) and
        not Process.alive?(cohort) and not Process.alive?(observer)
    end)

    :sys.resume(guard)
    eventually(fn -> :sys.get_state(guard).children == %{} end)
  end

  test "expired owned, borrowed and listener starts reject before new work" do
    table = :ets.new(__MODULE__, [:set, :public])
    generation = make_ref()
    deadline = Deadline.now() - 1
    :ets.insert(table, {:services_startup, generation, deadline, :starting})
    opts = [table: table, generation: generation, deadline: deadline]

    owned = %{
      ownership: :owned,
      kind: :replay_cache,
      adapter: MustNotStart,
      options: [parent: self()]
    }

    borrowed = %{
      ownership: :borrowed,
      kind: :sessions,
      adapter: BlockingHook,
      server: self(),
      options: [],
      namespace: "stable"
    }

    assert {:error, :service_start_timeout} = ServiceBinding.start_link(owned, opts)

    assert {:error, :service_start_timeout} =
             ServiceBinding.start_link(%{owned | kind: :subscriptions}, opts)

    assert {:error, :service_start_timeout} = ServiceBinding.start_link(borrowed, opts)
    assert {:error, :service_start_timeout} = StoreSupervisor.start_listeners(opts)
    refute_receive :unexpected_start_effect, 10
    assert :ets.lookup(table, :service_listeners) == []
    assert :ets.lookup(table, :services_generation) == []
  end

  test "finite recursive registration does not wait indefinitely for an owned supervisor" do
    root = runtime()
    {:ok, ref} = Runtime.ref(root)
    table = Ref.table(ref)

    {_id, cohort, :supervisor, _modules} =
      Enum.find(Supervisor.which_children(root), fn {id, _pid, _type, _modules} ->
        id == StoreSupervisor
      end)

    :sys.suspend(cohort)
    on_exit(fn -> safe_resume(cohort) end)
    started = Deadline.now()

    assert {:error, :service_start_timeout} =
             ShutdownGuard.watch(table, cohort, :supervisor, started + 30)

    assert Deadline.now() - started < 200
    :sys.resume(cohort)
    refute_receive {[:alias | _reference], _late_reply}, 20
  end

  test "successful startup keeps actual OTP parents and graceful owned termination" do
    root =
      runtime(services: [replay_cache: [adapter: PreReturnReplay, options: [parent: self()]]])

    assert_receive {:owned_started, owner, parent}

    {_id, cohort, :supervisor, _modules} =
      Enum.find(Supervisor.which_children(root), fn {id, _pid, _type, _modules} ->
        id == StoreSupervisor
      end)

    assert parent == cohort and Process.alive?(parent)
    {:ok, ref} = Runtime.ref(root)
    assert :ets.lookup(Ref.table(ref), :service_start_observer) == []
    assert :ok = Runtime.stop(root)
    assert_receive {:owned_terminated, ^owner, :shutdown}, 500
    refute Process.alive?(owner)
  end

  defp cohort_fixture(services, init_timeout \\ 80) do
    table = :ets.new(__MODULE__, [:set, :public])

    {:ok, config} =
      Config.new(
        handler: Handler,
        handler_args: self(),
        dispatcher: Handler,
        services: services,
        init_timeout_ms: init_timeout,
        shutdown_timeout_ms: 60
      )

    {:ok, guard} = ShutdownGuard.start(self(), table, config)
    :ets.insert(table, {:shutdown_guard, guard})
    on_exit(fn -> Process.exit(guard, :kill) end)
    {table, config, guard}
  end

  defp start_cohort(table, config) do
    parent = self()

    :proc_lib.spawn(fn ->
      Process.flag(:trap_exit, true)
      :ok = Initialization.track(table, self())
      started = Deadline.now()
      result = StoreSupervisor.start_link(table: table, config: config)
      send(parent, {:cohort_result, result, Deadline.now() - started})
    end)
  end

  defp runtime(opts \\ []) do
    {:ok, root} =
      Runtime.start_link(
        Keyword.merge([handler: Handler, handler_args: self(), dispatcher: Handler], opts)
      )

    Process.unlink(root)
    on_exit(fn -> Runtime.stop(root) end)
    root
  end

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

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

  defp eventually(fun, 0), do: assert(fun.())
end
