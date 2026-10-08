defmodule Arbor.MCP.Server.Runtime.OutputLedgerRevisionTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.OutputLedger, as: Ledger
  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  defp ledger(opts \\ []) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Ledger, Keyword.merge([owner: self()], opts)}, id: make_ref())
      )

    assert {:ok, ref} = Ledger.ref(pid)
    ref
  end

  defp snapshot(ref) do
    [{:gate, revision, gate}] = :ets.lookup(ref.table, :gate)
    assert is_reference(revision)
    assert gate.generation == ref.generation
    {revision, gate}
  end

  defp prepare(ref, term \\ %{"ok" => true}) do
    Ledger.prepare(ref, term, scope: :session, deadline: now() + 5_000)
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "changed output lifecycle rotates revisions without changing tickets or capacity" do
    ref = ledger(max_output_frames: 1)
    {initial, _} = snapshot(ref)
    assert :ok = Ledger.open_scope(ref, :session)
    {opened, _} = snapshot(ref)
    refute opened == initial
    assert :ok = Ledger.subscribe(ref, :session, self())
    {subscribed, _} = snapshot(ref)
    refute subscribed == opened
    term = %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 262_144)}]}
    assert {:ok, ticket} = prepare(ref, term)
    {prepared, gate} = snapshot(ref)
    refute prepared == subscribed
    refute Map.has_key?(gate, :revision)
    refute Map.has_key?(ticket, :revision)
    assert ticket.generation == ref.generation
    assert ticket.table == ref.table
    assert %{frames: 1, prepared: 1, pending_controls: 0} = Ledger.stats(ref)
    assert :empty = Ledger.checkout(ref, :session)
    assert {:error, :output_full} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    {published, _} = snapshot(ref)
    refute published == prepared
    assert_receive {:arbor_mcp_output, generation, :session, :ready}
    assert generation == ref.generation
    assert {:ok, ^ticket, ^term, wire} = Ledger.checkout(ref, :session)
    assert Jason.decode!(wire) == term
    {delivered, _} = snapshot(ref)
    refute delivered == published
    assert %{frames: 1, in_flight: 1, pending_controls: 0} = Ledger.stats(ref)
    assert :ok = Ledger.ack(ticket)
    {released, gate} = snapshot(ref)
    refute released == delivered
    assert gate.claims == %{}
    assert %{frames: 0, bytes: 0, scopes: 1, pending_controls: 0} = Ledger.stats(ref)
    assert :sys.get_state(ref.pid).monitors |> map_size() == 1
    assert :ok = Ledger.retire_scope(ref, :session)
    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "unchanged maintenance preserves the revision and complete logical gate" do
    ref = ledger()
    assert :ok = Ledger.open_scope(ref, :session)
    assert {:ok, ticket} = prepare(ref)
    before = snapshot(ref)

    for _ <- 1..3 do
      send(ref.pid, :reap)
      assert :sys.get_state(ref.pid).ref == ref
      assert snapshot(ref) == before
    end

    assert {:ok, %{"ok" => true}} = Ledger.value(ticket)
    assert :ok = Ledger.release(ticket)
    assert %{frames: 0, bytes: 0, pending_controls: 0} = Ledger.stats(ref)
  end

  test "synchronized producer claims preserve count and byte accounting across CAS retries" do
    ref = ledger(max_output_frames: 2)
    assert :ok = Ledger.open_scope(ref, :session)
    assert :ok = Ledger.subscribe(ref, :session, self())
    parent = self()
    tag = make_ref()
    :sys.suspend(ref.pid)

    on_exit(fn ->
      if Process.alive?(ref.pid), do: :sys.resume(ref.pid)
    end)

    producers =
      for index <- 1..8 do
        pid =
          spawn(fn ->
            send(parent, {:ready, tag, self()})

            receive do
              {:go, ^tag} ->
                result = prepare(ref, %{"producer" => index})
                send(parent, {:prepared, tag, self(), index, result})

                receive do
                  :stop -> :ok
                end

              :stop ->
                :ok
            end
          end)

        on_exit(fn -> send(pid, :stop) end)
        pid
      end

    for producer <- producers, do: assert_receive({:ready, ^tag, ^producer}, 1_000)
    Enum.each(producers, &send(&1, {:go, tag}))

    try do
      wait_until(fn -> Ledger.stats(ref).prepared == 2 end, timeout: 1_000)
      {_revision, gate} = snapshot(ref)
      assert gate.frames == 2
      assert map_size(gate.claims) == 2
      assert gate.bytes == Enum.sum(Enum.map(gate.claims, fn {_, entry} -> entry.bytes end))
      assert gate.bytes <= ref.limits.max_output_bytes
    after
      :sys.resume(ref.pid)
    end

    outcomes =
      for producer <- producers do
        assert_receive {:prepared, ^tag, ^producer, index, result}, 1_000
        {index, result}
      end

    admitted = for {index, {:ok, ticket}} <- outcomes, do: {index, ticket}
    assert length(admitted) == 2
    assert Enum.count(outcomes, &match?({_, {:error, :output_full}}, &1)) == 6

    for {index, ticket} <- admitted do
      assert :ok = Ledger.publish(ticket)
      assert {:ok, ^ticket, %{"producer" => ^index}, _wire} = Ledger.checkout(ref, :session)
      assert :ok = Ledger.ack(ticket)
    end

    monitors = Enum.map(producers, &{&1, Process.monitor(&1)})
    Enum.each(producers, &send(&1, :stop))

    for {producer, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^producer, :normal}, 500)

    assert %{frames: 0, bytes: 0, pending_controls: 0} = Ledger.stats(ref)
    assert :ok = Ledger.retire_scope(ref, :session)
    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "generation reuse never reuses a revision or resurrects old ticket payloads" do
    ref = ledger()
    {initial_revision, initial_gate} = snapshot(ref)
    assert :ok = Ledger.open_scope(ref, :session)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, old} = prepare(ref, %{"old" => true})
    {old_revision, _} = snapshot(ref)
    assert {:ok, next} = Ledger.reset_generation(ref, make_ref())
    {next_revision, _} = snapshot(next)
    refute next_revision in [initial_revision, old_revision]
    assert {:error, :output_unavailable} = Ledger.publish(old)
    assert {:error, :output_unavailable} = prepare(ref)
    assert :sys.get_state(next.pid).monitors == %{}
    assert {:ok, reused} = Ledger.reset_generation(next, ref.generation)
    {reused_revision, reused_gate} = snapshot(reused)
    refute reused_revision in [initial_revision, old_revision, next_revision]
    assert reused_gate == initial_gate
    assert {:error, :output_released} = Ledger.value(old)
    assert %{frames: 0, bytes: 0, scopes: 0, pending_controls: 0} = Ledger.stats(reused)
    assert :ok = Ledger.open_scope(reused, :session)
    assert {:ok, current} = prepare(reused, %{"current" => true})
    assert {:ok, %{"current" => true}} = Ledger.value(current)
    assert :ok = Ledger.release(current)
    assert %{frames: 0, bytes: 0, pending_controls: 0} = Ledger.stats(reused)
  end

  test "revision references and wildcard generations confer no ticket or scope authority" do
    ref = ledger()
    assert :ok = Ledger.open_scope(ref, :session)
    assert {:ok, ticket} = prepare(ref)
    {revision, _} = snapshot(ref)
    before = Ledger.stats(ref)
    forged = %{ticket | token: revision}
    assert {:error, :output_released} = Ledger.value(forged)
    assert {:error, :output_released} = Ledger.publish(forged)
    assert :ok = Ledger.release(forged)

    for generation <- [:_, :"$1", :"$2"] do
      assert {:error, :output_unavailable} =
               Ledger.open_scope(%{ref | generation: generation}, :forged)

      assert {:error, :output_unavailable} =
               Ledger.value(%{ticket | generation: generation})
    end

    assert {:error, :invalid_output_ticket} = Ledger.value(%{ticket | scope: :other})
    assert Ledger.stats(ref) == before
    assert {:ok, %{"ok" => true}} = Ledger.value(ticket)
    assert :ok = Ledger.release(ticket)
    assert %{frames: 0, bytes: 0, pending_controls: 0} = Ledger.stats(ref)
  end
end
