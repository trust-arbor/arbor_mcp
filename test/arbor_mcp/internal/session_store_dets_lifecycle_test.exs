defmodule Arbor.MCP.Internal.SessionStoreDetsLifecycleTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.SessionStore.DETS
  alias Arbor.MCP.Internal.SessionStore.DETS.ClaimIngress
  alias Arbor.MCP.Internal.SessionStore.DETS.Error
  alias Arbor.MCP.Internal.SessionStore.DETS.PathClaims
  alias Arbor.MCP.SessionManager

  setup do
    path = unique_path()
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: path}
  end

  test "foreign caller closes the actual user and all four persisted tables reopen", %{path: path} do
    {:ok, store} = DETS.open(%{storage_path: path})
    pids = table_pids(store)
    {:dictionary, dictionary} = Process.info(store.owner, :dictionary)

    assert {Arbor.MCP.Internal.SessionStore.DETS.Owner, :init, 1} ==
             Keyword.fetch!(dictionary, :"$initial_call")

    assert hd(Keyword.fetch!(dictionary, :"$ancestors")) == self()
    assert Enum.all?(store.names, &is_reference/1)
    assert true == DETS.insert(store, :sessions, {"s", %{initialized: true}})
    assert true == DETS.insert(store, :events, {{"s", "7-0"}, %{__ex_mcp_sequence__: 7}})
    assert true == DETS.insert(store, :request_ids, {{"s", 12}, true})
    assert store == DETS.put_event_clock(store, 7)

    parent = self()
    spawn(fn -> send(parent, {:foreign_close, DETS.close(store)}) end)
    assert_receive {:foreign_close, :ok}
    assert_eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end)
    assert :ok == DETS.close(store)

    {:ok, reopened} = DETS.open(%{storage_path: path})
    assert [{"s", %{initialized: true}}] == DETS.lookup(reopened, :sessions, "s")

    assert [{{"s", "7-0"}, %{__ex_mcp_sequence__: 7}}] ==
             DETS.lookup(reopened, :events, {"s", "7-0"})

    assert [{{"s", 12}, true}] == DETS.lookup(reopened, :request_ids, {"s", 12})
    assert 7 == DETS.event_clock(reopened)
    assert :ok == DETS.close(reopened)
  end

  for table <- [:sessions, :events, :request_ids, :meta] do
    @table table
    test "#{table} blocked write is finite and its late physical result keeps the same path exclusive",
         %{path: path} do
      {:ok, store} = DETS.open(%{storage_path: path, storage_io_timeout_ms: 60})
      table = @table
      worker = :dets.info(Map.fetch!(store, table), :owner)
      :erlang.suspend_process(worker)
      parent = self()

      try do
        spawn(fn ->
          send(parent, {:write_result, storage_result(fn -> write(store, table) end)})
        end)

        assert_eventually(fn -> :atomics.get(store.gate, 2) == 1 end)
        assert_receive {:write_result, {:error, :storage_io_timeout}}, 500
        assert Process.alive?(store.owner)
        assert {:error, :storage_cleanup_pending} == DETS.close(store)

        assert {:error, :storage_io_timeout} ==
                 DETS.open(%{storage_path: path, storage_io_timeout_ms: 30})

        assert claim_owner(path) == store.owner
      after
        resume_if_alive(worker)
      end

      assert_eventually(fn -> not Process.alive?(store.owner) end)
      assert_eventually(fn -> Enum.all?(store.names, &(:dets.info(&1, :owner) == :undefined)) end)
      {:ok, reopened} = DETS.open(%{storage_path: path})
      assert_retained_write(reopened, table)
      assert :ok == DETS.close(reopened)
      refute_receive {_reference, _late_reply}, 10
    end

    test "#{table} blocked close retains the path claim until actual cleanup", %{path: path} do
      {:ok, store} = DETS.open(%{storage_path: path, storage_io_timeout_ms: 60})
      table = @table
      worker = :dets.info(Map.fetch!(store, table), :owner)
      :erlang.suspend_process(worker)
      pids = table_pids(store)

      try do
        before = System.monotonic_time(:millisecond)
        assert {:error, :storage_io_timeout} == DETS.close(store)
        assert System.monotonic_time(:millisecond) - before < 500
        assert {:error, :storage_cleanup_pending} == DETS.close(store)

        assert {:error, :storage_io_timeout} ==
                 DETS.open(%{storage_path: path, storage_io_timeout_ms: 30})

        assert claim_owner(path) == store.owner
        assert Process.alive?(worker)
      after
        resume_if_alive(worker)
      end

      assert_eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end)
      assert :ok == DETS.close(store)
      {:ok, reopened} = DETS.open(%{storage_path: path})
      assert :ok == DETS.close(reopened)
    end
  end

  test "one original operation cutoff covers consecutive calls without refreshing", %{path: path} do
    {:ok, store} = DETS.open(%{storage_path: path, storage_io_timeout_ms: 80})
    worker = :dets.info(store.sessions, :owner)
    :erlang.suspend_process(worker)

    try do
      before = System.monotonic_time(:millisecond)

      assert {:error, :storage_io_timeout} ==
               storage_result(fn ->
                 DETS.with_deadline(store, fn ->
                   Process.sleep(35)
                   DETS.lookup(store, :sessions, :missing)
                 end)
               end)

      elapsed = System.monotonic_time(:millisecond) - before
      assert elapsed >= 65
      assert elapsed < 110
    after
      resume_if_alive(worker)
    end

    assert_eventually(fn -> not Process.alive?(store.owner) end)
  end

  test "hard lifetime owner death cleans up tracked I/O and leaves another path usable", %{
    path: path
  } do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, store} = DETS.open(%{storage_path: path, storage_io_timeout_ms: 60})
        send(parent, {:opened, store})

        receive do
          :wait -> :ok
        end
      end)

    assert_receive {:opened, store}
    worker = :dets.info(store.sessions, :owner)
    sibling_path = unique_path()
    {:ok, sibling} = DETS.open(%{storage_path: sibling_path})
    :erlang.suspend_process(worker)

    try do
      spawn(fn ->
        send(parent, {:write_result, storage_result(fn -> write(store, :sessions) end)})
      end)

      assert_eventually(fn -> :atomics.get(store.gate, 2) == 1 end)
      Process.exit(caller, :kill)
      assert_receive {:write_result, {:error, :storage_io_timeout}}, 500
      assert true == DETS.insert(sibling, :sessions, {:alive, true})

      assert {:error, :storage_io_timeout} ==
               DETS.open(%{storage_path: path, storage_io_timeout_ms: 30})
    after
      resume_if_alive(worker)
      DETS.close(sibling)
      File.rm_rf!(sibling_path)
    end

    assert_eventually(fn -> not Process.alive?(store.owner) end)
    {:ok, reopened} = DETS.open(%{storage_path: path})
    assert_retained_write(reopened, :sessions)
    assert :ok == DETS.close(reopened)
  end

  test "SessionManager deliberately returns the storage failure before fail-stop", %{path: path} do
    spec =
      Supervisor.child_spec(
        {SessionManager,
         [name: nil, storage_backend: :dets, storage_path: path, storage_io_timeout_ms: 60]},
        restart: :temporary
      )

    manager = start_supervised!(spec)

    session_id =
      GenServer.call(manager, {:create_session, %{client_info: %{sentinel: "retained"}}})

    state = :sys.get_state(manager)
    worker = :dets.info(state.store.sessions, :owner)
    monitor = Process.monitor(manager)
    :erlang.suspend_process(worker)

    try do
      assert {:error, :storage_io_timeout} ==
               GenServer.call(manager, {:get_session, session_id}, 1_000)

      assert_receive {:DOWN, ^monitor, :process, ^manager, :storage_io_failed}, 500
      assert claim_owner(path) == state.store.owner
    after
      resume_if_alive(worker)
    end

    assert_eventually(fn -> not Process.alive?(state.store.owner) end)

    {:ok, reopened} =
      SessionManager.start_link(name: nil, storage_backend: :dets, storage_path: path)

    assert {:ok, %{client_info: %{sentinel: "retained"}}} =
             GenServer.call(reopened, {:get_session, session_id})

    assert :ok == GenServer.stop(reopened)
  end

  test "SessionManager crash and restart repairs process-local initialization claims", %{
    path: path
  } do
    {:ok, manager} =
      SessionManager.start_link(name: nil, storage_backend: :dets, storage_path: path)

    Process.unlink(manager)
    id = GenServer.call(manager, {:create_session, %{}})
    assert :ok == GenServer.call(manager, {:claim_initialization, id})
    Process.exit(manager, :kill)

    {:ok, restarted} =
      SessionManager.start_link(name: nil, storage_backend: :dets, storage_path: path)

    assert {:ok, %{initialization_claimed: false}} = GenServer.call(restarted, {:get_session, id})
    assert :ok == GenServer.stop(restarted)
  end

  test "invalid DETS deadlines fail before any path claim or I/O", %{path: path} do
    before = map_size(:sys.get_state(PathClaims).claims)

    for value <- [0, -1, :infinity, 4_294_967_296, 1.5] do
      assert {:error, :invalid_storage_io_timeout} ==
               DETS.open(%{storage_path: path, storage_io_timeout_ms: value})
    end

    assert map_size(:sys.get_state(PathClaims).claims) == before
    refute File.exists?(path)
  end

  test "retirement seals either opening phase and never reopens a terminal phase" do
    for phase <- [0, 1] do
      gate = :atomics.new(1, signed: true)
      :atomics.put(gate, 1, phase)
      assert :changed == PathClaims.seal(gate)
      assert :atomics.get(gate, 1) == 2
      assert :unchanged == PathClaims.seal(gate)
    end

    for phase <- [2, 3, 4] do
      gate = :atomics.new(1, signed: true)
      :atomics.put(gate, 1, phase)
      assert :unchanged == PathClaims.seal(gate)
      assert :atomics.get(gate, 1) == phase
    end

    parent = self()

    for _attempt <- 1..1_000 do
      gate = :atomics.new(1, signed: true)
      token = make_ref()

      spawn(fn ->
        :atomics.compare_exchange(gate, 1, 0, 1)
        send(parent, {:activated, token})
      end)

      assert :changed == PathClaims.seal(gate)
      assert_receive {:activated, ^token}
      assert :atomics.get(gate, 1) == 2
    end
  end

  test "cleanup flushes the processing reply queued between timeout and alias retirement" do
    parent = self()
    reply = :erlang.alias([:reply])
    tag = make_ref()

    processing =
      spawn(fn ->
        receive do
          :complete ->
            send(reply, {tag, {:ok, :claimed}})
            send(parent, {:processing_complete, self()})
        end
      end)

    timeout =
      receive do
        {^tag, _reply} -> :unexpected_reply
      after
        0 -> :timed_out
      end

    assert timeout == :timed_out

    send(processing, :complete)
    assert_receive {:processing_complete, ^processing}
    assert {tag, {:ok, :claimed}} in elem(Process.info(self(), :messages), 1)
    assert :ok == ClaimIngress.cleanup_reply(reply, tag)
    refute_receive {^tag, _late_reply}, 0
    send(reply, {tag, :after_retirement})
    refute_receive {^tag, _late_reply}, 0
  end

  defp write(store, :meta), do: DETS.put_event_clock(store, 19)
  defp write(store, table), do: DETS.insert(store, table, {:retained, table})
  defp assert_retained_write(store, :meta), do: assert(19 == DETS.event_clock(store))

  defp assert_retained_write(store, table),
    do: assert([{:retained, table}] == DETS.lookup(store, table, :retained))

  defp storage_result(operation) do
    operation.()
  rescue
    error in Error -> {:error, error.reason}
  end

  defp claim_owner(path), do: :sys.get_state(PathClaims).claims[path].owner
  defp table_pids(store), do: Enum.map(store.names, &:dets.info(&1, :owner))

  defp unique_path,
    do: Path.join(System.tmp_dir!(), "arbor-dets-lifecycle-#{System.unique_integer([:positive])}")

  defp resume_if_alive(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  end

  defp assert_eventually(check, remaining \\ 1_000)
  defp assert_eventually(check, remaining) when remaining <= 0, do: assert(check.())

  defp assert_eventually(check, remaining) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(check, remaining - 5)
    end
  end
end
