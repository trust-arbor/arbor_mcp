defmodule Arbor.MCP.Server.RuntimeNativeStorePressureTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{ReplayCache, Runtime}
  alias Arbor.MCP.Server.Runtime.{ServiceOperation, Services}
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Store.ETS, as: TaskStore
  alias Arbor.MCP.Tasks.Task, as: TaskRecord

  @owner %{principal_id: nil, tenant_id: nil, audience: nil}

  defmodule Handler do
    def init(parent), do: {:ok, parent}

    def dispatch(request, _handler, parent, _opts) do
      send(parent, {:waiting, self()})
      receive do: (:proceed -> :ok)

      result =
        case request["method"] do
          "task" ->
            Tasks.create("probe", %{}, id: "expired-task", notify: false)

          "replay" ->
            {:ok, service} = Runtime.service(:replay_cache)
            ReplayCache.consume(service, "expired-jti", System.system_time(:second) + 60)
        end

      send(parent, {:operation_returned, result})
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "done"}, parent}
    end
  end

  defmodule LegacyTasks do
    def runtime_service_capabilities, do: %{bounded_startup: 1, namespace: 1}
    def start_link(_opts), do: raise("must not start")
    defdelegate create(task, owner, opts), to: TaskStore
    defdelegate fetch(id, owner, opts), to: TaskStore
    defdelegate submit_input(id, responses, owner, opts), to: TaskStore
    defdelegate request_cancel(id, owner, opts), to: TaskStore
    defdelegate transition(id, operation, owner, opts), to: TaskStore
    defdelegate take_input_responses(id, owner, opts), to: TaskStore
    defdelegate cancellation_requested?(id, owner, opts), to: TaskStore
  end

  test "runtime rejects custom descriptors without bounded operations before owned effects" do
    assert {:error, {:invalid_service, :tasks, :bounded_operations_required}} =
             Runtime.start_link(handler: Handler, services: [tasks: [adapter: LegacyTasks]])

    server = start_supervised!({TaskStore, name: nil})

    assert {:error, {:invalid_service, :tasks, :bounded_operations_required}} =
             Runtime.start_link(
               handler: Handler,
               services: [
                 tasks: [
                   adapter: LegacyTasks,
                   ownership: :borrowed,
                   server: server,
                   namespace: "stable-endpoint"
                 ]
               ]
             )

    assert Process.alive?(server)

    assert {:ok, %{"taskId" => "standalone"}} =
             Tasks.create("probe", %{},
               id: "standalone",
               ttl: 60_000,
               store: LegacyTasks,
               server: server,
               notify: false
             )
  end

  for {method, kind, key} <- [
        {"task", :tasks, "expired-task"},
        {"replay", :replay_cache, "expired-jti"}
      ] do
    test "#{kind} queued before original callback expiry cannot commit after its worker dies" do
      root =
        start_supervised!(
          {Runtime,
           handler: Handler,
           dispatcher: Handler,
           handler_args: self(),
           request_timeout_ms: 100,
           cancel_grace_ms: 0,
           services: [replay_cache: []]}
        )

      {:ok, runtime} = Runtime.ref(root)
      {:ok, binding} = Services.resolve(runtime, unquote(kind))
      :ok = :sys.suspend(binding.server)
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => unquote(method)}
      {:ok, token} = Runtime.submit(runtime, request)
      assert_receive {:waiting, worker}, 1_000
      monitor = Process.monitor(worker)
      send(worker, :proceed)
      eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 1 end)

      assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
               Runtime.await(token, 1_000)

      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      :ok = :sys.resume(binding.server)
      eventually(fn -> ServiceOperation.stats(binding.address).pending_operations == 0 end)
      refute Map.has_key?(:sys.get_state(binding.server).entries, unquote(key))
      refute_receive {:operation_returned, :ok}
    end
  end

  test "native task producers reserve count and bytes before a suspended owner's mailbox" do
    server =
      start_supervised!(
        {TaskStore,
         name: nil,
         max_tasks: 2,
         max_operations: 2,
         max_operation_bytes: 4_096,
         max_operation_payload_bytes: 2_048}
      )

    %{address: address} = TaskStore.runtime_service_binding(server, 1_000)
    :ok = :sys.suspend(server)
    parent = self()

    for id <- 1..16 do
      spawn(fn ->
        task =
          TaskRecord.new("probe", %{"data" => String.duplicate("x", 128)},
            id: "task-#{id}",
            ttl: 60_000
          )

        send(parent, {:created, TaskStore.create(task, @owner, server: server)})
      end)
    end

    for _ <- 1..14, do: assert_receive({:created, {:error, :operation_capacity_exhausted}}, 1_000)

    assert %{pending_operations: 2, pending_operation_bytes: bytes} =
             ServiceOperation.stats(address)

    assert bytes <= 4_096
    # Only coalesced wake + a timer can reach the owner; no payload is enqueued.
    assert elem(Process.info(server, :message_queue_len), 1) <= 2
    :ok = :sys.resume(server)
    for _ <- 1..2, do: assert_receive({:created, {:ok, _task}}, 1_000)
    eventually(fn -> ServiceOperation.stats(address).pending_operations == 0 end)
    assert map_size(:sys.get_state(server).entries) == 2
  end

  test "retained task byte exhaustion preserves the previous committed lifecycle" do
    server =
      start_supervised!(
        {TaskStore,
         name: nil,
         max_entry_bytes: 1_024,
         max_retained_bytes: 2_048,
         max_operation_payload_bytes: 8_192}
      )

    {:ok, task} =
      TaskStore.create(TaskRecord.new("probe", %{}, id: "one", ttl: 60_000), @owner,
        server: server
      )

    assert {:error, :store_full} =
             TaskStore.transition(
               "one",
               {:complete, %{"data" => String.duplicate("x", 2_000)}},
               @owner,
               server: server
             )

    assert {:ok, ^task} = TaskStore.fetch("one", @owner, server: server)
    assert :sys.get_state(server).retained_bytes <= 2_048
  end

  test "replay entry and ID limits fail closed while previously consumed IDs stay consumed" do
    server =
      start_supervised!(
        {ReplayCache.ETS,
         name: nil,
         max_replay_entries: 2,
         max_replay_bytes: 256,
         max_replay_id_bytes: 32,
         max_replay_ttl_ms: 60_000}
      )

    expires = System.system_time(:second) + 30
    assert :ok = ReplayCache.ETS.consume("one", expires, server: server)
    assert :ok = ReplayCache.ETS.consume("two", expires, server: server)

    assert {:error, :replay_cache_full} =
             ReplayCache.ETS.consume("three", expires, server: server)

    assert {:error, :replayed} = ReplayCache.ETS.consume("one", expires, server: server)

    assert {:error, :invalid_replay_id} =
             ReplayCache.ETS.consume(String.duplicate("x", 33), expires, server: server)

    assert {:error, :invalid_replay_expiry} =
             ReplayCache.ETS.consume("four", expires + 60, server: server)

    assert :sys.get_state(server).retained_bytes <= 256
  end

  test "late queued native success does not extend a suspended caller's original wait" do
    server = start_supervised!({TaskStore, name: nil, max_operations: 1})
    %{address: address} = TaskStore.runtime_service_binding(server, 1_000)
    :ok = :sys.suspend(server)
    parent = self()

    caller =
      spawn(fn ->
        task = TaskRecord.new("probe", %{}, id: "committed", ttl: 60_000)
        result = TaskStore.create(task, @owner, server: server, timeout: 100)
        send(parent, {:late_native_result, result, Process.info(self(), :messages)})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    eventually(fn -> ServiceOperation.stats(address).pending_operations == 1 end)
    [{_token, entry}] = ServiceOperation.entries(address)
    assert :erlang.suspend_process(caller)
    :ok = :sys.resume(server)
    eventually(fn -> Map.has_key?(:sys.get_state(server).entries, "committed") end)
    eventually(fn -> System.monotonic_time(:millisecond) >= entry.deadline end)
    assert :erlang.resume_process(caller)
    assert_receive {:late_native_result, {:error, :operation_timeout}, {:messages, []}}, 1_000
    assert {:ok, _task} = TaskStore.fetch("committed", @owner, server: server)
    eventually(fn -> ServiceOperation.stats(address).pending_operations == 0 end)
  end

  test "idle expiry reclaims a multi-turn backlog and retained bytes" do
    clock = :atomics.new(1, signed: false)
    :atomics.put(clock, 1, 1_000)
    server = start_supervised!({TaskStore, name: nil, now_fun: fn -> :atomics.get(clock, 1) end})

    for id <- 1..100 do
      assert {:ok, _task} =
               TaskStore.create(TaskRecord.new("probe", %{}, id: "expired-#{id}", ttl: 1), @owner,
                 server: server
               )
    end

    :atomics.put(clock, 1, 1_001)
    eventually(fn -> :sys.get_state(server).entries == %{} end)
    assert :sys.get_state(server).retained_bytes == 0
    assert :gb_sets.is_empty(:sys.get_state(server).expiry_queue)
  end

  test "native retained task fields and replay identifiers detach backing buffers" do
    server = start_supervised!({TaskStore, name: nil})
    replay = start_supervised!({ReplayCache.ETS, name: nil})
    parent = self()

    {producer, monitor} =
      spawn_monitor(fn ->
        blob = :binary.part(:binary.copy("x", 16_777_216), 0, 128)
        task = TaskRecord.new("probe", %{"data" => blob}, id: "detached", ttl: 60_000)
        assert {:ok, _task} = TaskStore.create(task, @owner, server: server)

        assert :ok =
                 ReplayCache.ETS.consume(blob, System.system_time(:second) + 60, server: replay)

        send(parent, :buffers_committed)
      end)

    assert_receive :buffers_committed, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 1_000
    assert {:ok, task} = TaskStore.fetch("detached", @owner, server: server)
    assert :binary.referenced_byte_size(task.arguments["data"]) == 128
    [identifier] = Map.keys(:sys.get_state(replay).entries)
    assert :binary.referenced_byte_size(identifier) == 128
  end

  test "idle replay TTL reclaims its identifier and byte credit without another operation" do
    server = start_supervised!({ReplayCache.ETS, name: nil})
    assert :ok = ReplayCache.ETS.consume("expires", System.system_time(:second), server: server)
    eventually(fn -> :sys.get_state(server).entries == %{} end, 400)
    assert :sys.get_state(server).retained_bytes == 0
    assert :gb_sets.is_empty(:sys.get_state(server).expiry_queue)
  end

  test "idle native task retention expires without a subsequent store operation" do
    server = start_supervised!({TaskStore, name: nil})

    assert {:ok, _} =
             TaskStore.create(TaskRecord.new("probe", %{}, id: "short", ttl: 30), @owner,
               server: server
             )

    eventually(fn -> :sys.get_state(server).entries == %{} end)
    assert :sys.get_state(server).retained_bytes == 0
  end

  defp eventually(predicate, attempts \\ 200)
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
