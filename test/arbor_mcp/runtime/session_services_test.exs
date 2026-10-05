defmodule Arbor.MCP.Server.RuntimeSessionServicesTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{ServiceOperation, Services}
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.{RuntimeStore, SessionLease}
  alias Arbor.MCP.SubscriptionRegistry
  alias Arbor.MCP.SubscriptionRegistry.RuntimeStore, as: ResourceStore

  defmodule Handler do
    def init(parent), do: {:ok, parent}

    def dispatch(request, _handler, parent, _opts) do
      {:ok, service} = Runtime.service(:sessions)

      if request["method"] == "late" do
        send(parent, {:waiting_service_callback, self()})
        receive do: (:release -> :ok)
      end

      result = SessionManager.create_session(service, %{}, session_id: "callback")
      send(parent, {:callback_session_result, result})
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "done"}, parent}
    end
  end

  defmodule Unqualified do
    def runtime_service_capabilities, do: %{namespace: 1}
    def runtime_service_binding(_server, _timeout), do: %{}
    def operate(_operation, _args, _context, _opts), do: :ok
    def lease_active?(_id, _epoch, _opts), do: true
  end

  defmodule BlockingBinding do
    use GenServer
    alias Arbor.MCP.Server.Runtime.ServiceAdapter

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: opts[:init_timeout_ms])

    def runtime_service_capabilities,
      do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}

    def runtime_service_binding(server, timeout), do: GenServer.call(server, :binding, timeout)
    def operate(_operation, _args, _context, _opts), do: {:error, :blocked}
    def lease_active?(_id, _epoch, _opts), do: false
    @impl true
    def init(opts) do
      :ok = ServiceAdapter.watch_owned(opts)
      Process.flag(:trap_exit, true)
      send(opts[:test_pid], {:blocking_service_owner, self()})
      {:ok, nil}
    end

    @impl true
    def handle_call(:binding, _from, state) do
      receive do: (:release -> :ok)
      {:reply, %{}, state}
    end
  end

  defmodule GatedStore do
    alias Arbor.MCP.Server.Runtime.{ServiceOperation, ServiceStore}

    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)

    def runtime_service_capabilities,
      do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}

    def runtime_service_binding(server, timeout), do: ServiceStore.binding(server, timeout)
    def lease_active?(_id, _epoch, _opts), do: false

    def operate(operation, args, context, opts),
      do:
        ServiceOperation.submit(
          opts[:service_address],
          operation,
          [opts[:namespace] | args],
          context
        )

    def open(opts),
      do: {:ok, %{table: :ets.new(__MODULE__, [:set, :protected]), parent: opts[:test_pid]}}

    def read_address(model), do: model.table
    def close(_model), do: :ok
    def info(_message, model), do: model
    def expire(model, _deadline), do: model

    def apply(:append, [namespace, marker], context, model) do
      if ServiceOperation.context_current?(context) do
        count =
          :ets.update_counter(model.table, {namespace, marker}, {2, 1}, {{namespace, marker}, 0})

        send(model.parent, {:service_commit, self(), marker, count})
        receive do: ({:finish, ^marker} -> :ok)
        {{:ok, count}, model}
      else
        {{:error, :operation_timeout}, model}
      end
    end
  end

  defmodule ResourcesWithoutReaper do
    alias Arbor.MCP.Server.Runtime.ServiceStore
    alias Arbor.MCP.SubscriptionRegistry.RuntimeStore

    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    defdelegate open(opts), to: RuntimeStore
    defdelegate read_address(model), to: RuntimeStore
    defdelegate close(model), to: RuntimeStore
    defdelegate info(message, model), to: RuntimeStore
    defdelegate apply(operation, args, context, model), to: RuntimeStore
    def expire(model, _deadline), do: model
  end

  test "sessions are opt in and explicit unavailable refs never use standalone stores" do
    start_supervised!({SessionManager, []})
    root = runtime(services: [])
    assert {:error, :service_not_configured} = Runtime.service(root, :sessions)
    assert Process.alive?(Process.whereis(SessionManager))
  end

  test "same session and typed request IDs are isolated across sibling runtimes" do
    a = runtime()
    b = runtime()
    {sa, ra} = services(a)
    {sb, rb} = services(b)
    {:ok, la} = SessionManager.create_session(sa, %{principal_id: "a"}, session_id: "same")
    {:ok, lb} = SessionManager.create_session(sb, %{principal_id: "b"}, session_id: "same")
    assert SessionLease.id(la) == SessionLease.id(lb)
    assert :ok = SessionManager.claim_request_id(sa, la, 1, [])
    assert :ok = SessionManager.claim_request_id(sa, la, "1", [])
    assert :ok = SessionManager.claim_request_id(sb, lb, 1, [])
    assert {:error, :duplicate_request_id} = SessionManager.claim_request_id(sa, la, 1, [])
    assert :ok = SubscriptionRegistry.subscribe(ra, la, "file://one", [])
    assert :ok = SubscriptionRegistry.subscribe(rb, lb, "file://one", [])

    assert {:error, :stale_session_lease} =
             SubscriptionRegistry.subscribe(rb, la, "file://foreign", [])

    assert :ok = SessionManager.terminate_session(sa, la, [])
    assert {:ok, []} = SubscriptionRegistry.sessions(ra, "file://one", [])
    assert {:ok, [_]} = SubscriptionRegistry.sessions(rb, "file://one", [])
  end

  test "initialization capability can complete from a different worker exactly once" do
    {sessions, _resources} = services(runtime())
    {:ok, lease} = SessionManager.create_session(sessions, %{principal_id: "alice"}, [])

    {:ok, claim} =
      SessionManager.claim_initialization(sessions, lease, owner: self(), timeout: 500)

    assert :ok =
             Task.async(fn ->
               SessionManager.complete_initialization(sessions, claim, "2025-06-18", [])
             end)
             |> Task.await()

    assert {:error, :stale_initialization_claim} =
             SessionManager.complete_initialization(sessions, claim, "2025-06-18", [])

    assert {:ok, _lease} =
             SessionManager.ensure_initialized_session(
               sessions,
               SessionLease.id(lease),
               %{principal_id: "alice"},
               []
             )

    assert {:error, _reason} =
             SessionManager.ensure_session(sessions, SessionLease.id(lease), %{}, [])
  end

  test "claim owner exit retires its epoch and resource subscriptions" do
    {sessions, resources} = services(runtime())
    {:ok, lease} = SessionManager.create_session(sessions, %{}, session_id: "abandoned")
    :ok = SubscriptionRegistry.subscribe(resources, lease, "file://held", [])
    owner = spawn(fn -> receive do: (:exit -> :ok) end)

    {:ok, _claim} =
      SessionManager.claim_initialization(sessions, lease, owner: owner, timeout: 500)

    monitor = Process.monitor(owner)
    send(owner, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    eventually(fn ->
      SessionManager.ensure_session(sessions, "abandoned", %{}, []) ==
        {:error, :session_not_found}
    end)

    assert {:ok, []} = SubscriptionRegistry.sessions(resources, "file://held", [])
  end

  test "TTL releases retained budgets and stale cleanup cannot remove a reused session ID" do
    {sessions, resources} = services(runtime(session_options: [session_ttl_ms: 50]))
    {:ok, old} = SessionManager.create_session(sessions, %{}, session_id: "reused")
    :ok = SubscriptionRegistry.subscribe(resources, old, "file://old", [])

    eventually(fn ->
      SessionManager.get_session(sessions, old, []) == {:error, :stale_session_lease}
    end)

    {:ok, new} = SessionManager.create_session(sessions, %{}, session_id: "reused")
    :ok = SubscriptionRegistry.subscribe(resources, new, "file://new", [])
    assert {:error, :stale_session_lease} = SessionManager.terminate_session(sessions, old, [])
    assert {:ok, []} = SubscriptionRegistry.sessions(resources, "file://old", [])
    assert {:ok, [_]} = SubscriptionRegistry.sessions(resources, "file://new", [])

    assert {:ok, %{request_ids: 0, events: 0, sessions: 1}} =
             SessionManager.get_stats(sessions, [])
  end

  test "session metadata deltas and request ID bytes are aggregate caps" do
    {sessions, _resources} =
      services(runtime(session_options: [max_metadata_bytes: 1_200, max_request_id_bytes: 80]))

    {:ok, lease} =
      SessionManager.create_session(
        sessions,
        %{client_info: %{name: String.duplicate("x", 400)}},
        []
      )

    assert {:error, :session_metadata_capacity_exhausted} =
             SessionManager.create_session(
               sessions,
               %{client_info: %{name: String.duplicate("y", 800)}},
               []
             )

    assert {:ok, _} =
             SessionManager.ensure_session(
               sessions,
               SessionLease.id(lease),
               %{client_info: %{name: "tiny"}},
               []
             )

    assert {:ok, _} =
             SessionManager.create_session(
               sessions,
               %{client_info: %{name: String.duplicate("y", 400)}},
               []
             )

    assert {:error, :request_id_capacity_exhausted} =
             SessionManager.claim_request_id(sessions, lease, String.duplicate("z", 80), [])

    assert {:ok, %{request_ids: 0}} = SessionManager.get_stats(sessions, [])
  end

  test "replay pages distinguish retained, evicted and foreign cursors" do
    {sessions, _resources} = services(runtime(session_options: [max_events_per_session: 2]))
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    {:ok, other} = SessionManager.create_session(sessions, %{}, [])
    {:ok, first} = SessionManager.append_event(sessions, lease, "message", %{value: 1}, [])
    {:ok, second} = SessionManager.append_event(sessions, lease, "message", %{value: 2}, [])
    {:ok, third} = SessionManager.append_event(sessions, lease, "message", %{value: 3}, [])
    assert {:error, :cursor_evicted} = SessionManager.replay_page(sessions, lease, first.id, [])
    assert {:error, :foreign_cursor} = SessionManager.replay_page(sessions, other, second.id, [])
    assert {:error, :unknown_cursor} = SessionManager.replay_page(sessions, lease, "123-0", [])

    assert {:ok, %{events: [^second], next_cursor: cursor, more?: true}} =
             SessionManager.replay_page(sessions, lease, nil, max_events: 1)

    assert {:ok, %{events: [^third], more?: false}} =
             SessionManager.replay_page(sessions, lease, cursor, [])

    assert {:error, :replay_page_too_small} =
             SessionManager.replay_page(sessions, lease, nil, max_bytes: 1)
  end

  test "suspended service admission bounds retained operation payloads before its mailbox" do
    root =
      runtime(
        session_options: [
          max_operations: 2,
          max_operation_bytes: 1_300,
          operation_timeout_ms: 500
        ]
      )

    {sessions, _resources} = services(root)
    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)
    on_exit(fn -> safe_resume(binding.server) end)

    tasks =
      for id <- ["one", "two"],
          do:
            Task.async(fn ->
              SessionManager.create_session(
                sessions,
                %{client_info: %{name: String.duplicate("x", 200)}},
                session_id: id
              )
            end)

    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations >= 1 end)

    assert {:error, :operation_capacity_exhausted} =
             SessionManager.create_session(
               sessions,
               %{client_info: %{name: String.duplicate("y", 800)}},
               []
             )

    stats = ServiceOperation.stats(binding.address)
    assert stats.pending_operations <= 2
    assert stats.pending_operation_bytes <= 1_300
    assert {:message_queue_len, queue} = Process.info(binding.server, :message_queue_len)
    assert queue <= 2
    :sys.resume(binding.server)

    for task <- tasks do
      result = Task.await(task)

      assert match?({:ok, _lease}, result) or
               match?({:error, :operation_capacity_exhausted}, result)
    end

    assert %{pending_operations: 0, pending_operation_bytes: 0} =
             ServiceOperation.stats(binding.address)
  end

  test "expired queued operation creates no session after resume and cannot leak late replies" do
    {sessions, _resources} = services(runtime(session_options: [operation_timeout_ms: 40]))
    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)

    assert {:error, :operation_timeout} =
             SessionManager.create_session(sessions, %{}, session_id: "expired")

    :sys.resume(binding.server)

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "expired", %{}, [])

    assert {:ok, _lease} = SessionManager.create_session(sessions, %{}, session_id: "legitimate")
    refute_receive {_token, {:ok, _lease}}, 10

    assert %{pending_operations: 0, pending_operation_bytes: 0} =
             ServiceOperation.stats(binding.address)
  end

  test "publisher death releases reservation and accepted payload without an orphan" do
    {sessions, _resources} = services(runtime())
    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)

    publisher =
      spawn(fn -> SessionManager.create_session(sessions, %{}, session_id: "orphan") end)

    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 1 end)
    Process.exit(publisher, :kill)
    :sys.resume(binding.server)
    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 0 end)

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "orphan", %{}, [])

    assert {:ok, _lease} =
             SessionManager.create_session(sessions, %{}, session_id: "after-orphan")
  end

  test "completed mutation is not repeated during delayed cleanup or returned after caller cutoff" do
    parent = self()
    root = runtime(services: [sessions: [adapter: GatedStore, options: [test_pid: parent]]])
    {:ok, sessions} = Runtime.service(root, :sessions)
    {:ok, binding} = Services.resolve(sessions, :sessions)

    caller =
      spawn(fn ->
        result = ServiceOperation.call(sessions, :sessions, :append, ["once"], timeout: 250)
        send(parent, {:persistent_caller_result, result, Process.info(self(), :messages)})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:service_commit, owner, "once", 1}
    :erlang.suspend_process(caller)
    on_exit(fn -> safe_resume_process(caller) end)
    [{token, entry}] = ServiceOperation.entries(binding.address)

    # The owner has already committed. Hold it beyond this maintenance turn's
    # cleanup budget and enqueue another wake before it can release the credit.
    Process.sleep(10)
    send(owner, :service_operations)
    send(owner, {:finish, "once"})
    eventually(fn -> :atomics.get(entry.phase, 1) == 2 end)
    eventually(fn -> Process.info(caller, :messages) == {:messages, [{token, {:ok, 1}}]} end)
    refute_receive {:service_commit, ^owner, "once", _duplicate}, 20
    assert [{{"owned", "once"}, 1}] = :ets.lookup(binding.read_address, {"owned", "once"})

    Process.sleep(max(0, entry.deadline - ServiceOperation.now()) + 10)
    :erlang.resume_process(caller)
    assert_receive {:persistent_caller_result, {:error, :operation_timeout}, {:messages, []}}
    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 0 end)
    assert Process.alive?(owner)
    assert [{{"owned", "once"}, 1}] = :ets.lookup(binding.read_address, {"owned", "once"})
    send(caller, :stop)
  end

  test "abandoned queued credit is retained until reap without mutation or readmission" do
    {sessions, _resources} =
      services(runtime(session_options: [max_operations: 1, operation_timeout_ms: 30]))

    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)
    on_exit(fn -> safe_resume(binding.server) end)

    assert {:error, :operation_timeout} =
             SessionManager.create_session(sessions, %{}, session_id: "abandoned")

    [{_token, entry}] = ServiceOperation.entries(binding.address)
    assert :atomics.get(entry.phase, 1) == 3
    refute ServiceOperation.current?(entry)
    refute ServiceOperation.context_current?(elem(entry.payload, 2))

    assert {:error, :operation_capacity_exhausted} =
             SessionManager.create_session(sessions, %{}, session_id: "too_early")

    :sys.resume(binding.server)
    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 0 end)

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "abandoned", %{}, [])

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "too_early", %{}, [])

    assert {:ok, _lease} = SessionManager.create_session(sessions, %{}, session_id: "after_reap")
    refute_receive {_token, _late_result}, 10
  end

  test "expired resource removals preserve their previously committed subscriptions" do
    {sessions, resources} = services(runtime(resource_options: [operation_timeout_ms: 30]))
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    :ok = SubscriptionRegistry.subscribe(resources, lease, "file://kept", [])
    {:ok, binding} = Services.resolve(resources, :resource_subscriptions)

    for operation <- [:unsubscribe, :remove_session] do
      :sys.suspend(binding.server)

      result =
        case operation do
          :unsubscribe -> SubscriptionRegistry.unsubscribe(resources, lease, "file://kept", [])
          :remove_session -> SubscriptionRegistry.remove_session(resources, lease, [])
        end

      assert {:error, :operation_timeout} = result

      :sys.resume(binding.server)
      assert {:ok, ["file://kept"]} = SubscriptionRegistry.subscriptions(resources, lease, [])
    end
  end

  test "finite wait and signed deadline validation rejects invalid caller budgets without effects" do
    {sessions, _resources} = services(runtime())

    for timeout <- [:infinity, 0, -1, 4_294_967_296] do
      assert {:error, :invalid_operation_timeout} =
               SessionManager.create_session(sessions, %{}, timeout: timeout)
    end

    for deadline <- [nil, :invalid, 9_223_372_036_854_775_808, -9_223_372_036_854_775_809] do
      assert {:error, :invalid_operation_deadline} =
               SessionManager.create_session(sessions, %{}, deadline: deadline)
    end

    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(sessions, [])
    assert {:ok, _lease} = SessionManager.create_session(sessions, %{}, deadline: :infinity)

    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)

      result =
        Runtime.start_link(
          handler: Handler,
          handler_args: self(),
          dispatcher: Handler,
          services: [sessions: [options: [operation_timeout_ms: 4_294_967_296]]]
        )

      send(parent, {:invalid_operation_limit_start, result})
    end)

    assert_receive {:invalid_operation_limit_start, {:error, _reason}}, 500
  end

  test "real producer contention preserves exact request ID and replay effects and reuses all credits" do
    parent = self()

    {sessions, _resources} =
      services(
        runtime(
          session_options: [
            operation_timeout_ms: 5_000,
            max_request_ids_per_session: 512,
            max_events_per_session: 512
          ]
        )
      )

    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    {:ok, binding} = Services.resolve(sessions, :sessions)

    producers =
      for producer <- 1..64 do
        spawn(fn ->
          receive do: (:go -> :ok)
          started = ServiceOperation.now()

          results =
            for index <- 1..4 do
              wire_id = producer * 1_000 + index
              claim = SessionManager.claim_request_id(sessions, lease, wire_id, [])

              append =
                SessionManager.append_event(sessions, lease, "message", %{wire_id: wire_id}, [])

              {wire_id, claim, append}
            end

          send(
            parent,
            {:producer_done, self(), results, ServiceOperation.now() - started,
             Process.info(self(), :messages)}
          )
        end)
      end

    Enum.each(producers, &send(&1, :go))

    results =
      Enum.flat_map(producers, fn producer ->
        assert_receive {:producer_done, ^producer, results, elapsed, {:messages, []}}, 10_000
        assert elapsed < 5_500
        results
      end)

    assert Enum.all?(results, fn {_id, claim, append} ->
             (claim == :ok or
                claim in [
                  {:error, :operation_contention},
                  {:error, :operation_capacity_exhausted}
                ]) and
               (match?({:ok, _event}, append) or
                  append in [
                    {:error, :operation_contention},
                    {:error, :operation_capacity_exhausted}
                  ])
           end)

    claims = Enum.count(results, fn {_id, result, _append} -> result == :ok end)
    events = Enum.count(results, fn {_id, _claim, result} -> match?({:ok, _event}, result) end)
    assert claims > 0 and events > 0
    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 0 end)
    assert %{pending_operation_bytes: 0} = ServiceOperation.stats(binding.address)

    assert {:ok, %{request_ids: ^claims, events: ^events}} =
             SessionManager.get_stats(sessions, [])

    {id, :ok, _append} = Enum.find(results, fn {_id, claim, _append} -> claim == :ok end)

    assert {:error, :duplicate_request_id} =
             SessionManager.claim_request_id(sessions, lease, id, [])

    assert {:ok, _event} =
             SessionManager.append_event(
               sessions,
               lease,
               "message",
               %{after_contention: true},
               []
             )
  end

  test "rotating resource maintenance eventually releases more than one turn of stale leases" do
    {sessions, resources} = services(runtime())
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])

    for index <- 1..96,
        do: :ok = SubscriptionRegistry.subscribe(resources, lease, "file://#{index}", [])

    assert :ok = SessionManager.terminate_session(sessions, lease, [])

    eventually(fn ->
      SubscriptionRegistry.get_stats(resources, []) ==
        {:ok, %{subscriptions: 0, subscription_bytes: 0}}
    end)
  end

  test "borrowed resource reads reject retained old cohorts before background reaping" do
    session_owner = start_supervised!({RuntimeStore, []})
    resource_owner = start_supervised!({ResourcesWithoutReaper, []})
    root = borrowed_runtime("persisted-logical-endpoint", session_owner, resource_owner)
    {sessions, resources} = services(root)
    {:ok, old} = SessionManager.create_session(sessions, %{}, session_id: "same-epoch")
    :ok = SubscriptionRegistry.subscribe(resources, old, "file://retired", [])
    {:ok, old_binding} = Services.resolve(sessions, :sessions)
    {:ok, tasks} = Runtime.service(root, :tasks)
    {:ok, task_binding} = Services.resolve(tasks, :tasks)
    Process.exit(task_binding.server, :kill)

    eventually(fn ->
      case Services.resolve(sessions, :sessions) do
        {:ok, binding} -> binding.generation != old_binding.generation
        _other -> false
      end
    end)

    {:ok, renewed} = SessionManager.ensure_session(sessions, "same-epoch", %{}, [])
    assert {:error, :stale_session_lease} = SessionManager.get_session(sessions, old, [])
    # The borrowed rows survive, and this adapter deliberately suppresses
    # background expiration so only the addressed read can reject the entry.
    assert {:ok, %{subscriptions: 1}} = SubscriptionRegistry.get_stats(resources, [])
    assert {:ok, []} = SubscriptionRegistry.subscriptions(resources, renewed, [])
    assert {:ok, %{subscriptions: 0}} = SubscriptionRegistry.get_stats(resources, [])
    assert :ok = SubscriptionRegistry.subscribe(resources, renewed, "file://retired", [])
    assert :ok = SubscriptionRegistry.subscribe(resources, renewed, "file://retired", [])
    assert {:ok, ["file://retired"]} = SubscriptionRegistry.subscriptions(resources, renewed, [])
    assert {:ok, %{subscriptions: 1}} = SubscriptionRegistry.get_stats(resources, [])
  end

  test "logical refs follow cohort restart but session leases retire" do
    root = runtime()
    {sessions, resources} = services(root)
    {:ok, old} = SessionManager.create_session(sessions, %{}, session_id: "restart")
    :ok = SubscriptionRegistry.subscribe(resources, old, "file://old", [])
    {:ok, binding} = Services.resolve(sessions, :sessions)
    Process.exit(binding.server, :kill)

    eventually(fn ->
      case Services.resolve(sessions, :sessions) do
        {:ok, next} -> next.server != binding.server
        _ -> false
      end
    end)

    assert {:error, :stale_session_lease} = SessionManager.get_session(sessions, old, [])
    assert {:ok, new} = SessionManager.create_session(sessions, %{}, session_id: "restart")
    assert :ok = SubscriptionRegistry.subscribe(resources, new, "file://new", [])
    assert {:ok, []} = SubscriptionRegistry.sessions(resources, "file://old", [])
  end

  test "borrowed namespace-capable stores isolate siblings and survive runtime stop" do
    sessions_server = start_supervised!({RuntimeStore, []})
    resources_server = start_supervised!({ResourceStore, []})
    a = borrowed_runtime("a", sessions_server, resources_server)
    b = borrowed_runtime("b", sessions_server, resources_server)
    {sa, ra} = services(a)
    {sb, rb} = services(b)
    {:ok, la} = SessionManager.create_session(sa, %{}, session_id: "same")
    {:ok, lb} = SessionManager.create_session(sb, %{}, session_id: "same")
    :ok = SubscriptionRegistry.subscribe(ra, la, "file://shared", [])
    :ok = SubscriptionRegistry.subscribe(rb, lb, "file://shared", [])
    :ok = Runtime.stop(a)
    assert Process.alive?(sessions_server) and Process.alive?(resources_server)
    assert {:ok, _row} = SessionManager.get_session(sb, lb, [])
    assert {:ok, [_]} = SubscriptionRegistry.sessions(rb, "file://shared", [])
    assert {:error, :runtime_unavailable} = SessionManager.get_session(sa, la, [])
  end

  test "runtime durable and insufficient borrowed operation contracts reject startup" do
    assert {:error, {:invalid_service, :sessions, :runtime_durable_sessions_unqualified}} =
             Runtime.start_link(
               handler: Handler,
               handler_args: self(),
               dispatcher: Handler,
               services: [sessions: [options: [storage_backend: :dets]]]
             )

    assert {:error, {:invalid_service, :sessions, :bounded_operations_required}} =
             Runtime.start_link(
               handler: Handler,
               handler_args: self(),
               dispatcher: Handler,
               services: [
                 sessions: [
                   ownership: :borrowed,
                   adapter: Unqualified,
                   server: self(),
                   namespace: "stable"
                 ]
               ]
             )
  end

  test "cancelled callback origin cannot create addressed session state" do
    root = runtime(cancel_grace_ms: 500)

    {:ok, token} =
      Runtime.submit(root, %{"jsonrpc" => "2.0", "id" => 1, "method" => "late"}, scope: :peer)

    assert_receive {:waiting_service_callback, callback}
    :ok = Runtime.cancel(root, :peer, 1)
    send(callback, :release)
    assert_receive {:callback_session_result, {:error, :service_unavailable}}
    assert_receive {:arbor_mcp_runtime, ^token, {:error, %{"error" => %{"code" => -32001}}}}
    {sessions, _resources} = services(root)

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "callback", %{}, [])
  end

  test "count and byte admission fail independently and credits are reusable" do
    for {options, payload} <- [
          {[max_operations: 1, max_operation_bytes: 100_000], "tiny"},
          {[max_operations: 4, max_operation_bytes: 1_000], String.duplicate("x", 250)}
        ] do
      {sessions, _resources} = services(runtime(session_options: options))
      {:ok, binding} = Services.resolve(sessions, :sessions)
      :sys.suspend(binding.server)

      task =
        Task.async(fn ->
          SessionManager.create_session(sessions, %{client_info: %{name: payload}}, [])
        end)

      eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 1 end)

      assert {:error, :operation_capacity_exhausted} =
               SessionManager.create_session(sessions, %{client_info: %{name: payload}}, [])

      assert ServiceOperation.stats(binding.address).pending_operations == 1
      :sys.resume(binding.server)
      assert {:ok, _lease} = Task.await(task)
      assert {:ok, _lease} = SessionManager.create_session(sessions, %{}, [])
      assert ServiceOperation.stats(binding.address).pending_operation_bytes == 0
    end
  end

  test "resource retained count and bytes release on unsubscribe and session closure" do
    {sessions, resources} = services(runtime(resource_options: [max_subscriptions: 1]))
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    assert :ok = SubscriptionRegistry.subscribe(resources, lease, "file://one", [])

    assert {:error, :subscription_capacity_exhausted} =
             SubscriptionRegistry.subscribe(resources, lease, "file://two", [])

    assert :ok = SubscriptionRegistry.unsubscribe(resources, lease, "file://one", [])
    assert :ok = SubscriptionRegistry.subscribe(resources, lease, "file://two", [])

    assert {:ok, %{subscriptions: 1, subscription_bytes: bytes}} =
             SubscriptionRegistry.get_stats(resources, [])

    assert bytes > 0
    assert :ok = SessionManager.terminate_session(sessions, lease, [])

    eventually(fn ->
      SubscriptionRegistry.get_stats(resources, []) ==
        {:ok, %{subscriptions: 0, subscription_bytes: 0}}
    end)

    {sessions, resources} = services(runtime(resource_options: [max_subscription_bytes: 10]))
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])

    assert {:error, :subscription_capacity_exhausted} =
             SubscriptionRegistry.subscribe(resources, lease, "file://bytes", [])

    assert {:ok, %{subscription_bytes: 0}} = SubscriptionRegistry.get_stats(resources, [])
  end

  test "aggregate replay failure neither evicts another session nor advances the cursor" do
    {sessions, _resources} = services(runtime(session_options: [max_events: 1]))
    {:ok, first} = SessionManager.create_session(sessions, %{}, [])
    {:ok, second} = SessionManager.create_session(sessions, %{}, [])
    {:ok, event} = SessionManager.append_event(sessions, first, "message", %{value: 1}, [])

    assert {:error, :replay_capacity_exhausted} =
             SessionManager.append_event(sessions, second, "message", %{value: 2}, [])

    assert {:ok, %{events: [^event]}} = SessionManager.replay_page(sessions, first, nil, [])
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, second, nil, [])
    assert :ok = SessionManager.terminate_session(sessions, first, [])

    assert {:ok, event} =
             SessionManager.append_event(sessions, second, "message", %{value: 3}, [])

    assert String.ends_with?(event.id, ":1")
  end

  test "blocked native service binding has bounded startup and kills its owned trap-exit child" do
    parent = self()
    started = System.monotonic_time(:millisecond)

    spawn(fn ->
      Process.flag(:trap_exit, true)

      result =
        Runtime.start_link(
          handler: Handler,
          handler_args: parent,
          dispatcher: Handler,
          init_timeout_ms: 1_000,
          shutdown_timeout_ms: 60,
          services: [sessions: [adapter: BlockingBinding, options: [test_pid: parent]]]
        )

      send(parent, {:blocked_start_result, result})
    end)

    assert_receive {:blocking_service_owner, owner}, 1_500
    assert_receive {:blocked_start_result, {:error, _reason}}, 1_500
    assert System.monotonic_time(:millisecond) - started < 2_000
    eventually(fn -> not Process.alive?(owner) end)
  end

  test "whole runtime shutdown invalidates service refs while sibling and borrowed owners survive" do
    a = runtime(shutdown_timeout_ms: 60)
    b = runtime()
    {sessions, _resources} = services(a)
    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)
    task = Task.async(fn -> SessionManager.create_session(sessions, %{}, []) end)
    eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 1 end)
    assert :ok = Runtime.stop(a)
    assert {:error, :service_unavailable} = Task.await(task)
    refute Process.alive?(binding.server)
    assert Process.alive?(b)
    assert {:error, :runtime_unavailable} = Services.resolve(sessions, :sessions)
    {other_sessions, _resources} = services(b)
    assert {:ok, _lease} = SessionManager.create_session(other_sessions, %{}, [])
  end

  test "service cohort failure retires blocked callbacks and rejects stale completion" do
    root = runtime()
    {sessions, _resources} = services(root)

    {:ok, token} =
      Runtime.submit(root, %{"jsonrpc" => "2.0", "id" => 9, "method" => "late"}, scope: :peer)

    assert_receive {:waiting_service_callback, callback}
    {:ok, old_binding} = Services.resolve(sessions, :sessions)
    Process.exit(old_binding.server, :kill)
    assert_receive {:arbor_mcp_runtime, ^token, {:error, _response}}, 500
    eventually(fn -> not Process.alive?(callback) end)

    eventually(fn ->
      case Services.resolve(sessions, :sessions) do
        {:ok, binding} -> binding.server != old_binding.server
        _ -> false
      end
    end)

    send(callback, :release)
    refute_receive {:callback_session_result, _result}, 20

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, "callback", %{}, [])
  end

  defp runtime(opts \\ []) do
    session_opts = Keyword.get(opts, :session_options, [])
    resource_opts = Keyword.get(opts, :resource_options, [])

    config = [
      handler: Handler,
      handler_args: self(),
      dispatcher: Handler,
      services: [
        sessions: [options: session_opts],
        resource_subscriptions: [options: resource_opts]
      ]
    ]

    {:ok, pid} =
      Runtime.start_link(
        Keyword.merge(config, Keyword.drop(opts, [:session_options, :resource_options]))
      )

    Process.unlink(pid)
    on_exit(fn -> Runtime.stop(pid) end)
    pid
  end

  defp borrowed_runtime(namespace, sessions, resources),
    do:
      runtime(
        services: [
          sessions: [ownership: :borrowed, server: sessions, namespace: namespace],
          resource_subscriptions: [ownership: :borrowed, server: resources, namespace: namespace]
        ]
      )

  defp services(root) do
    {:ok, sessions} = Runtime.service(root, :sessions)
    {:ok, resources} = Runtime.service(root, :resource_subscriptions)
    {sessions, resources}
  end

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp safe_resume_process(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp eventually(fun, 0), do: assert(fun.())
end
