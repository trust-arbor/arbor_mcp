defmodule Arbor.MCP.Server.RuntimeServicesTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{HandlerServer, ReplayCache, Runtime, Subscriptions}
  alias Arbor.MCP.Server.Runtime.{Admission, Ref, ServiceAdapter, Services}
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.{Extension, Store}

  defmodule Handler do
    def init(parent), do: {:ok, %{parent: parent, counter: 0}}

    def dispatch(request, _handler, state, _opts) do
      value =
        case request["method"] do
          "create" ->
            {:ok, task} = Tasks.create("background", %{}, id: "same-id", notify: false)
            task

          "worker_service" ->
            {:ok, service} = Runtime.service(:tasks)
            owner = Tasks.owner()
            parent = state.parent

            spawn(fn ->
              send(
                parent,
                {:worker_created,
                 Tasks.create("background", %{},
                   service: service,
                   owner: owner,
                   id: "worker-task",
                   notify: false
                 )}
              )
            end)

            "worker_started"

          "late_service" ->
            send(state.parent, {:late_service_waiting, self()})
            receive do: (:release -> :ok)
            result = Tasks.create("late", %{}, id: "late-task", notify: false)
            send(state.parent, {:late_service_result, result})
            "late_done"

          "hold" ->
            send(state.parent, {:holding, self()})

            receive do
              :release -> 900
            end

          "read" ->
            state.counter
        end

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => value}, state}
    end
  end

  defmodule SharedTasks do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
    def runtime_service_capabilities, do: %{namespace: 1}

    for {operation, arity} <- [
          create: 3,
          fetch: 3,
          submit_input: 4,
          request_cancel: 3,
          transition: 4,
          take_input_responses: 3,
          cancellation_requested?: 3
        ] do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(unquote_splicing(args), opts) do
        GenServer.call(
          Keyword.fetch!(opts, :server),
          {unquote(operation), [unquote_splicing(args)], Keyword.fetch!(opts, :namespace)}
        )
      end
    end

    @impl true
    def init(stores), do: {:ok, stores}

    @impl true
    def handle_call({operation, args, namespace}, _from, stores) do
      {server, stores} =
        case stores[namespace] do
          nil ->
            {:ok, pid} = Store.ETS.start_link(name: nil)
            {pid, Map.put(stores, namespace, pid)}

          pid ->
            {pid, stores}
        end

      {:reply, apply(Store.ETS, operation, args ++ [[server: server]]), stores}
    end
  end

  defmodule StoredHandler do
    use Arbor.MCP.Server.Handler,
      tasks: :store,
      task_store_opts: [server: __MODULE__.LegacyStore]

    alias Arbor.MCP.Tasks.Server, as: TaskServer

    @impl true
    def handle_call_tool("background", arguments, state) do
      TaskServer.create(
        "background",
        arguments,
        state,
        Keyword.put(__task_store_options__(), :id, "same-id")
      )
    end
  end

  defmodule CancellationTracker do
    def mark_cancelled(request_id, state) do
      send(state.parent, {:cancellation_tracked, request_id})
      %{state | counter: state.counter + 1}
    end
  end

  defmodule LifecycleReplay do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: Keyword.fetch!(opts, :init_timeout_ms))

    def runtime_service_capabilities, do: %{bounded_startup: 1}
    def consume(_jti, _expires_at, _opts), do: :ok

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      :ok = ServiceAdapter.watch_owned(opts)
      table = Keyword.fetch!(opts, :runtime_table)
      [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)

      # Snapshot while startup owns the table: a failed init can delete it
      # before the test process receives this message.
      owned =
        :ets.tab2list(table)
        |> Enum.flat_map(fn
          {{:service, _kind}, %{server: pid}} -> [pid]
          _other -> []
        end)

      send(opts[:parent], {:service_initializing, self(), table, guard, owned})

      case opts[:mode] do
        :block_init -> receive do: (:release -> {:ok, opts})
        :fail_init -> {:stop, :intentional_init_failure}
        _normal -> {:ok, opts}
      end
    end

    @impl true
    def terminate(_reason, opts) do
      if opts[:mode] == :block_terminate do
        send(opts[:parent], {:service_terminating, self()})
        receive do: (:release -> :ok)
      end

      :ok
    end
  end

  test "callbacks automatically use isolated owned task stores with equal IDs" do
    a = start_runtime()
    b = start_runtime()

    assert {:ok, %{"result" => %{"taskId" => "same-id"}}} =
             Runtime.request(a, request(1, "create"))

    assert {:ok, %{"result" => %{"taskId" => "same-id"}}} =
             Runtime.request(b, request(1, "create"))

    assert {:ok, ta} = Runtime.service(a, :tasks)
    assert {:ok, tb} = Runtime.service(b, :tasks)
    assert {:ok, _task} = Tasks.complete("same-id", %{"runtime" => "a"}, service: ta)

    assert {:ok, %{"status" => "completed", "result" => %{"runtime" => "a"}}} =
             Tasks.get("same-id", service: ta)

    assert {:ok, %{"status" => "working"}} = Tasks.get("same-id", service: tb)
    assert {:error, :not_found_or_unauthorized} = Tasks.get("same-id")
  end

  for transport <- [:test, :beam] do
    test "#{transport} protocol callbacks inject owned task services over legacy handler defaults" do
      transport = unquote(transport)

      a =
        start_supervised!(
          {HandlerServer,
           [
             id: make_ref(),
             handler: StoredHandler,
             transport: transport,
             protocol_mode: :modern_only
           ]}
        )

      b =
        start_supervised!(
          {HandlerServer,
           [
             id: make_ref(),
             handler: StoredHandler,
             transport: transport,
             protocol_mode: :modern_only
           ]}
        )

      for server <- [a, b] do
        {:ok, edge, runtime, connection} = HandlerServer.connect(server, self())
        request = modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}})
        assert :ok = HandlerServer.ingress(runtime, edge, connection, request)

        assert %{"id" => 1, "result" => %{"resultType" => "task", "taskId" => "same-id"}} =
                 receive_response(transport)
      end

      assert {:ok, _task} =
               Tasks.complete("same-id", %{"runtime" => "a"}, runtime: a, notify: false)

      assert {:ok, %{"status" => "completed"}} = Tasks.get("same-id", runtime: a)
      assert {:ok, %{"status" => "working"}} = Tasks.get("same-id", runtime: b)
    end
  end

  test "logical references resolve replacement services and reject whole-runtime replacement" do
    runtime = start_runtime()
    assert {:ok, service} = Runtime.service(runtime, :tasks)
    assert {:ok, binding} = Services.resolve(service, :tasks)
    assert {:ok, _task} = Tasks.create("before", %{}, service: service, id: "restart-id")
    old_generation = Runtime.stats(runtime).generation
    Process.exit(binding.server, :kill)

    eventually(fn ->
      match?({:ok, %{server: pid}} when pid != binding.server, Services.resolve(service, :tasks))
    end)

    eventually(fn ->
      match?(%{generation: generation} when generation != old_generation, Runtime.stats(runtime))
    end)

    assert {:error, :not_found_or_unauthorized} = Tasks.get("restart-id", service: service)
    assert {:ok, _task} = Tasks.create("after", %{}, service: service, id: "restart-id")
    assert :ok = Runtime.stop(runtime)
    replacement = start_runtime()
    assert {:ok, _new_ref} = Runtime.service(replacement, :tasks)
    assert {:error, :task_store_unavailable} = Tasks.get("restart-id", service: service)
  end

  test "service failure restarts execution cohort and rejects old completions without affecting sibling" do
    runtime = start_runtime()
    sibling = start_runtime()
    {:ok, route} = Admission.route(Ref.table(runtime))
    assert {:ok, token} = Runtime.submit(runtime, request(1, "hold"))
    assert_receive {:holding, worker}
    old_scheduler = :sys.get_state(route.scheduler)
    task_ref = old_scheduler.work[token].task.ref
    {:ok, binding} = Services.resolve(runtime, :tasks)
    Process.exit(binding.server, :kill)
    assert {:error, :runtime_restarted} = Runtime.await(token, 1_000)
    eventually(fn -> not Process.alive?(worker) end)

    eventually(fn ->
      match?(
        {:ok, %{scheduler: pid}} when pid != route.scheduler,
        Admission.route(Ref.table(runtime))
      )
    end)

    {:ok, replacement} = Admission.route(Ref.table(runtime))

    send(
      replacement.scheduler,
      {task_ref,
       {:response, %{"jsonrpc" => "2.0", "id" => 1, "result" => 900},
        %{parent: self(), counter: 900}}}
    )

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, request(2, "read"))
    assert {:ok, %{"result" => 0}} = Runtime.request(sibling, request(1, "read"))
  end

  test "owned replay caches are opt in and isolate equal durable tokens" do
    plain = start_runtime()
    assert {:error, :service_not_configured} = Runtime.service(plain, :replay_cache)
    a = start_runtime(services: [replay_cache: []])
    b = start_runtime(services: [replay_cache: []])
    assert {:ok, ra} = Runtime.service(a, :replay_cache)
    assert {:ok, rb} = Runtime.service(b, :replay_cache)
    expiry = System.system_time(:second) + 60
    assert :ok = ReplayCache.consume(ra, "same-jti", expiry)
    assert {:error, :replayed} = ReplayCache.consume(ra, "same-jti", expiry)
    assert :ok = ReplayCache.consume(rb, "same-jti", expiry)

    assert {:error, :wrong_service} =
             ReplayCache.consume(elem(Runtime.service(a, :tasks), 1), "token", expiry)
  end

  test "task authorization and publications use the same runtime domain despite legacy overrides" do
    services = [
      subscriptions: [
        options: [
          authorize_filter: fn requested, _context -> {:ok, requested} end,
          authorize_publication: fn _method, _params, _context -> true end
        ]
      ]
    ]

    a = start_runtime(services: services)
    b = start_runtime(services: services)
    legacy_store = start_supervised!({Store.ETS, name: nil}, id: make_ref())
    owner = %{principal_id: "alice", tenant_id: "same-tenant", audience: "mcp://same"}

    for runtime <- [a, b] do
      assert {:ok, _task} =
               Tasks.create("background", %{},
                 runtime: runtime,
                 id: "shared",
                 owner: owner,
                 notify: false
               )
    end

    listen_opts = [
      principal_id: "alice",
      tenant_id: "same-tenant",
      audience: "mcp://same",
      client_capabilities: Extension.put_capability(%{}),
      task_store_opts: [server: legacy_store]
    ]

    assert {:ok, ea} =
             Subscriptions.listen(
               1,
               %{"taskIds" => ["shared"]},
               self(),
               [runtime: a] ++ listen_opts
             )

    assert {:ok, eb} =
             Subscriptions.listen(
               1,
               %{"taskIds" => ["shared"]},
               self(),
               [runtime: b] ++ listen_opts
             )

    assert ea.filter == %{"taskIds" => ["shared"]}
    assert eb.filter == ea.filter
    la = ea.listener_pid
    lb = eb.listener_pid
    assert_receive {:ex_mcp_subscription_message, ^la, :acknowledged, _ack}
    assert_receive {:ex_mcp_subscription_message, ^lb, :acknowledged, _ack}
    Subscriptions.delivered(la)
    Subscriptions.delivered(lb)
    assert {:ok, _task} = Tasks.complete("shared", %{"runtime" => "a"}, runtime: a, owner: owner)
    assert_receive {:ex_mcp_subscription_message, ^la, :notification, notification}
    assert notification["params"]["status"] == "completed"
    refute_receive {:ex_mcp_subscription_message, ^lb, :notification, _cross_domain}, 30
    assert :ok = Subscriptions.cancel(self(), 1, runtime: a)
    assert Subscriptions.entries(runtime: a) == []
    assert [_entry] = Subscriptions.entries(runtime: b)
  end

  test "disabled or stale explicit task services never fall back to an available global task" do
    id = "global-#{System.unique_integer([:positive])}"
    assert {:ok, _task} = Tasks.create("legacy", %{}, id: id, notify: false)
    runtime = start_runtime(services: [tasks: nil])
    assert {:error, :service_not_configured} = Runtime.service(runtime, :tasks)
    assert {:error, :task_store_unavailable} = Tasks.get(id, runtime: runtime)
    assert {:ok, _task} = Tasks.get(id)

    assert {:error, :replay_cache_required} =
             Runtime.start_link(base_opts() ++ [require_replay_protection: true])

    assert {:error, :replay_cache_requires_service_descriptor} =
             Runtime.start_link(base_opts() ++ [replay_cache: ReplayCache.ETS])
  end

  test "workers retain captured service and owner without inheriting callback context" do
    runtime = start_runtime()
    assert {:error, :no_runtime_context} = Runtime.service(:tasks)

    assert {:ok, %{"result" => "worker_started"}} =
             Runtime.request(runtime, request(1, "worker_service"))

    assert_receive {:worker_created, {:ok, %{"taskId" => "worker-task"}}}
    assert {:ok, %{"status" => "working"}} = Tasks.get("worker-task", runtime: runtime)
    assert {:error, :not_found_or_unauthorized} = Tasks.get("worker-task")
  end

  test "expired callback service effects fail before a suspended scheduler handles its deadline" do
    runtime = start_runtime(request_timeout_ms: 40, cancel_grace_ms: 300)
    {:ok, route} = Admission.route(Ref.table(runtime))
    {:ok, token} = Runtime.submit(runtime, request(1, "late_service"))
    assert_receive {:late_service_waiting, worker}
    :sys.suspend(route.scheduler)
    on_exit(fn -> if Process.alive?(route.scheduler), do: :sys.resume(route.scheduler) end)
    Process.sleep(60)
    send(worker, :release)
    assert_receive {:late_service_result, {:error, :task_store_unavailable}}
    :sys.resume(route.scheduler)

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
             Runtime.await(token, 1_000)

    assert {:error, :not_found_or_unauthorized} = Tasks.get("late-task", runtime: runtime)
  end

  test "opt-in replay does not suppress ordered cancellation tracker state commits" do
    runtime =
      start_runtime(
        cancellation_tracker: CancellationTracker,
        cancel_grace_ms: 10,
        services: [replay_cache: []]
      )

    {:ok, token} = Runtime.submit(runtime, request(1, "hold"), scope: :tracker)
    assert_receive {:holding, _worker}
    assert :ok = Runtime.cancel(runtime, :tracker, 1)
    assert {:error, %{"error" => %{"code" => -32001}}} = Runtime.await(token, 1_000)
    assert_receive {:cancellation_tracked, 1}
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, request(2, "read"))
  end

  test "borrowed service loss fails closed and does not kill an independently owned runtime" do
    parent = self()
    backend = start_supervised!({SharedTasks, []})

    {:ok, root} =
      Runtime.start_link(
        base_opts(parent) ++
          [
            services: [
              tasks: [
                ownership: :borrowed,
                adapter: SharedTasks,
                server: backend,
                namespace: "shared"
              ]
            ]
          ]
      )

    Process.unlink(root)
    {:ok, runtime} = Runtime.ref(root)
    {:ok, service} = Runtime.service(runtime, :tasks)
    sibling = start_runtime()
    monitor = Process.monitor(root)
    Process.exit(backend, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _failed_restart}, 1_000
    assert {:error, :task_store_unavailable} = Tasks.create("unavailable", %{}, service: service)
    assert {:ok, %{"result" => 0}} = Runtime.request(sibling, request(1, "read"))
  end

  test "borrowed namespace-aware task backends preserve data and live beyond runtime shutdown" do
    backend = start_supervised!({SharedTasks, []})

    a =
      start_runtime(
        services: [
          tasks: [
            ownership: :borrowed,
            adapter: SharedTasks,
            server: backend,
            namespace: "tenant/a"
          ]
        ]
      )

    b =
      start_runtime(
        persistence_key: "tenant/b",
        services: [tasks: [ownership: :borrowed, adapter: SharedTasks, server: backend]]
      )

    assert {:ok, ra} = Runtime.service(a, :tasks)
    assert {:ok, rb} = Runtime.service(b, :tasks)
    assert {:ok, _task} = Tasks.create("a", %{}, service: ra, id: "shared")
    assert {:ok, _task} = Tasks.create("b", %{}, service: rb, id: "shared")
    assert :ok = Tasks.cancel("shared", service: ra)
    assert {:ok, true} = Tasks.cancellation_requested?("shared", service: ra)
    assert {:ok, false} = Tasks.cancellation_requested?("shared", service: rb)
    assert :ok = Runtime.stop(a)
    assert Process.alive?(backend)
    assert {:ok, %{"status" => "working"}} = Tasks.get("shared", service: rb)

    replacement =
      start_runtime(
        services: [
          tasks: [
            ownership: :borrowed,
            adapter: SharedTasks,
            server: backend,
            namespace: "tenant/a"
          ]
        ]
      )

    assert {:ok, true} = Tasks.cancellation_requested?("shared", runtime: replacement)
  end

  test "unnamespaced borrowing and ambiguous raw registry overrides fail before starting runtime" do
    assert {:error, {:invalid_service, :tasks, :namespaced_operations_required}} =
             Runtime.start_link(
               base_opts() ++
                 [services: [tasks: [ownership: :borrowed, server: self(), namespace: "stable"]]]
             )

    assert {:error, {:invalid_service, :tasks, :stable_namespace_required}} =
             Runtime.start_link(
               base_opts() ++
                 [services: [tasks: [ownership: :borrowed, adapter: SharedTasks, server: self()]]]
             )

    assert {:error,
            {:subscription_registry_requires_service_descriptor,
             :configure_owned_subscriptions_or_namespaced_borrowed_service}} =
             Runtime.start_link(base_opts() ++ [subscription_registry: self()])
  end

  for mode <- [:block_init, :fail_init] do
    test "#{mode} startup is bounded and cleans already started services" do
      mode = unquote(mode)
      parent = self()

      spawn(fn ->
        Process.flag(:trap_exit, true)
        started = System.monotonic_time(:millisecond)

        result =
          Runtime.start_link(
            base_opts(parent) ++
              [
                init_timeout_ms: 80,
                shutdown_timeout_ms: 80,
                services: [
                  replay_cache: [adapter: LifecycleReplay, options: [mode: mode, parent: parent]]
                ]
              ]
          )

        send(parent, {:startup_finished, result, System.monotonic_time(:millisecond) - started})
      end)

      assert_receive {:service_initializing, service, table, guard, owned}
      assert owned != []

      assert_receive {:startup_finished, {:error, _reason}, elapsed}, 1_000
      assert elapsed < 500
      eventually(fn -> Enum.all?([service, guard | owned], &(not Process.alive?(&1))) end)
      assert :undefined == :ets.info(table)
    end
  end

  test "owned blocked termination obeys total shutdown budget and leaves siblings alive" do
    sibling = start_runtime()

    runtime =
      start_runtime(
        shutdown_timeout_ms: 80,
        services: [
          replay_cache: [
            adapter: LifecycleReplay,
            options: [mode: :block_terminate, parent: self()]
          ]
        ]
      )

    assert_receive {:service_initializing, service, _table, guard, _owned}
    {:ok, task_binding} = Services.resolve(runtime, :tasks)
    {:ok, subscription_binding} = Services.resolve(runtime, :subscriptions)
    started = System.monotonic_time(:millisecond)
    assert :ok = Runtime.stop(runtime)
    assert_receive {:service_terminating, ^service}
    assert System.monotonic_time(:millisecond) - started < 450

    eventually(fn ->
      Enum.all?(
        [service, guard, task_binding.server, subscription_binding.server],
        &(not Process.alive?(&1))
      )
    end)

    assert {:ok, %{"result" => 0}} = Runtime.request(sibling, request(1, "read"))
  end

  test "dynamically owned listener blocked in a trapping authorizer is forcefully cleaned" do
    parent = self()

    authorizer = fn _method, _params, _context ->
      Process.flag(:trap_exit, true)
      send(parent, {:blocked_listener, self()})
      receive do: (:release -> true)
    end

    sibling = start_runtime()

    runtime =
      start_runtime(
        shutdown_timeout_ms: 80,
        services: [subscriptions: [options: [authorize_publication: authorizer]]]
      )

    {:ok, entry} =
      Subscriptions.listen(1, %{"toolsListChanged" => true}, self(), runtime: runtime)

    listener = entry.listener_pid
    assert_receive {:ex_mcp_subscription_message, ^listener, :acknowledged, _ack}
    Subscriptions.delivered(listener)

    publication =
      Task.async(fn ->
        try do
          Subscriptions.publish("notifications/tools/list_changed", %{}, runtime: runtime)
        catch
          :exit, _closed -> :closed
        end
      end)

    assert_receive {:blocked_listener, ^listener}
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    started = System.monotonic_time(:millisecond)
    assert :ok = Runtime.stop(runtime)
    assert System.monotonic_time(:millisecond) - started < 450
    eventually(fn -> not Process.alive?(listener) and not Process.alive?(guard) end)
    Task.await(publication, 1_000)
    assert {:ok, %{"result" => 0}} = Runtime.request(sibling, request(1, "read"))
  end

  defp start_runtime(opts \\ []) do
    root = start_supervised!({Runtime, Keyword.merge(base_opts(), opts)})
    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp base_opts(parent \\ self()),
    do: [id: make_ref(), handler: Handler, dispatcher: Handler, handler_args: parent]

  defp request(id, method), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  defp modern_request(id, method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => Extension.put_capability(%{}),
      "io.modelcontextprotocol/clientInfo" => %{"name" => "services-test", "version" => "1"}
    }

    Map.put(request(id, method), "params", Map.put(params, "_meta", meta))
  end

  defp receive_response(transport) do
    assert_receive {:transport_message, response}, 1_000
    if transport == :test, do: Jason.decode!(response), else: response
  end

  defp eventually(predicate, attempts \\ 150)
  defp eventually(predicate, 0), do: assert(predicate.())

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
