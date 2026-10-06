defmodule Arbor.MCP.Server.Runtime.OutputLedgerTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime.OutputLedger, as: Ledger

  defp ledger(opts \\ []) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Ledger, Keyword.merge([owner: self()], opts)}, id: make_ref())
      )

    assert {:ok, ref} = Ledger.ref(pid)
    if Keyword.get(opts, :open_session, true), do: assert(:ok == Ledger.open_scope(ref, :session))
    ref
  end

  defp prepare(ref, term \\ %{"ok" => true}, opts \\ []) do
    Ledger.prepare(ref, term, Keyword.merge([scope: :session, deadline: now() + 5_000], opts))
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end

  defp hold_producer(parent, ref, term, opts) do
    spawn(fn ->
      receive do
        :go -> :ok
      end

      result = prepare(ref, term, opts)
      send(parent, {:prepared, self(), result})

      receive do
        :stop -> :ok
      end
    end)
  end

  defp results(count) do
    for _ <- 1..count do
      receive do
        {:prepared, pid, result} -> {pid, result}
      after
        5_000 -> flunk("producer did not finish")
      end
    end
  end

  test "prepared output stays hidden and one credit covers prepared, queued and in-flight" do
    ref = ledger(max_output_frames: 1)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert :empty = Ledger.checkout(ref, :session)
    assert %{frames: 1, prepared: 1, queued: 0, in_flight: 0} = Ledger.stats(ref)
    assert {:error, :output_full} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    assert_receive {:arbor_mcp_output, _, :session, :ready}
    assert {:ok, ^ticket, %{"ok" => true}, wire} = Ledger.checkout(ref, :session)
    assert Jason.decode!(wire) == %{"ok" => true}
    assert %{frames: 1, in_flight: 1} = Ledger.stats(ref)
    assert {:error, :output_full} = prepare(ref)
    assert :ok = Ledger.ack(ticket)
    assert :ok = Ledger.ack(ticket)
    assert :ok = Ledger.release(ticket)
    assert %{frames: 0, bytes: 0} = Ledger.stats(ref)
  end

  test "concurrent producers cannot exceed count admission while actor is suspended" do
    ref = ledger(max_output_frames: 8)
    :sys.suspend(ref.pid)

    producers =
      for _ <- 1..80, do: hold_producer(self(), ref, %{"data" => String.duplicate("x", 100)}, [])

    Enum.each(producers, &send(&1, :go))
    # Count admission includes claims whose producer has not stored its payload
    # yet. Wait for that separate transition before asserting prepared stages.
    eventually(fn -> Ledger.stats(ref).prepared == 8 end)
    assert %{frames: 8, prepared: 8, queued: 0, in_flight: 0} = Ledger.stats(ref)
    {:messages, messages} = Process.info(ref.pid, :messages)

    assert Enum.all?(messages, fn
             {:"$gen_call", _, {:operation, id}} ->
               is_reference(id)

             :reap ->
               true

             _ ->
               false
           end)

    assert Enum.count(messages, &match?({:"$gen_call", _, _}, &1)) <= 8
    :sys.resume(ref.pid)
    outcomes = results(80)
    admitted = for {_, {:ok, ticket}} <- outcomes, do: ticket
    assert length(admitted) == 8

    assert Enum.all?(outcomes, fn {_, result} ->
             match?({:ok, _}, result) or result == {:error, :output_full}
           end)

    Enum.each(admitted, &assert(:ok == Ledger.publish(&1)))
    Enum.each(producers, &send(&1, :stop))
    eventually(fn -> Ledger.stats(ref).queued == 8 end)
    Enum.each(admitted, &assert(:ok == Ledger.release(&1)))
    assert Ledger.stats(ref).frames == 0
  end

  test "concurrent byte pressure rejects before retaining more payloads" do
    ref = ledger(max_output_bytes: 1_800, max_output_frames: 20)

    producers =
      for _ <- 1..60, do: hold_producer(self(), ref, %{"data" => String.duplicate("x", 100)}, [])

    Enum.each(producers, &send(&1, :go))
    outcomes = results(60)
    admitted = for {_, {:ok, ticket}} <- outcomes, do: ticket
    assert length(admitted) > 0 and length(admitted) < 20
    assert Ledger.stats(ref).bytes <= 1_800
    assert Ledger.stats(ref).frames == length(admitted)
    Enum.each(admitted, &assert(:ok == Ledger.release(&1)))
    Enum.each(producers, &send(&1, :stop))
    assert Ledger.stats(ref).bytes == 0
  end

  test "publishing hands producer lifetime to the configured runtime owner" do
    ref = ledger()
    producer = hold_producer(self(), ref, %{"ok" => true}, [])
    send(producer, :go)
    [{^producer, {:ok, ticket}}] = results(1)
    assert :ok = Ledger.publish(ticket)
    monitor = Process.monitor(producer)
    send(producer, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _}
    Process.sleep(30)
    assert %{frames: 1, queued: 1} = Ledger.stats(ref)
    assert :ok = Ledger.release(ticket)
  end

  test "producer loses release authority after runtime publication" do
    ref = ledger()
    parent = self()

    producer =
      spawn(fn ->
        {:ok, ticket} = prepare(ref)
        send(parent, {:ticket, ticket})

        receive do
          :release -> send(parent, {:producer_release, Ledger.release(ticket)})
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:ticket, ticket}
    assert :ok = Ledger.publish(ticket)
    send(producer, :release)
    assert_receive {:producer_release, {:error, :invalid_output_owner}}
    assert Ledger.stats(ref).queued == 1
    assert :ok = Ledger.release(ticket)
    send(producer, :stop)
  end

  test "producer dying during confirmation cannot leave an orphan payload" do
    ref = ledger()
    :sys.suspend(ref.pid)
    producer = spawn(fn -> prepare(ref) end)
    eventually(fn -> Ledger.stats(ref).prepared == 1 end)
    Process.exit(producer, :kill)
    :sys.resume(ref.pid)

    eventually(fn ->
      Ledger.stats(ref).frames == 0 and Ledger.stats(ref).pending_controls == 0
    end)

    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "retirement concurrent with producers prevents payload resurrection" do
    ref = ledger(max_output_frames: 40)

    producers =
      for _ <- 1..100, do: hold_producer(self(), ref, %{"data" => String.duplicate("z", 500)}, [])

    Enum.each(producers, &send(&1, :go))
    assert :ok = Ledger.retire_scope(ref, :session, :peer_closed)
    outcomes = results(100)

    Enum.each(outcomes, fn
      {_, {:ok, ticket}} ->
        assert :ok == Ledger.release(ticket)

      {_, {:error, reason}} ->
        assert reason in [
                 :output_unknown_scope,
                 :output_released,
                 :output_expired,
                 :output_full,
                 :output_call_expired
               ]
    end)

    Enum.each(producers, &send(&1, :stop))
    assert %{frames: 0, bytes: 0, scopes: 0} = Ledger.stats(ref)
    assert Ledger.drained?(ref, :session)
  end

  test "producer death before publication reaps hidden payload and credit" do
    ref = ledger()
    producer = hold_producer(self(), ref, %{"ok" => true}, [])
    send(producer, :go)
    [{^producer, {:ok, ticket}}] = results(1)
    Process.exit(producer, :kill)
    eventually(fn -> Ledger.stats(ref).frames == 0 end)
    assert {:error, :output_released} = Ledger.publish(ticket)
    assert :ok = Ledger.release(ticket)
  end

  test "wake coalescing recovers after checkout attempted without credit" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, first} = prepare(ref, %{"id" => 1})
    assert {:ok, second} = prepare(ref, %{"id" => 2})
    assert :ok = Ledger.publish(first)
    assert :ok = Ledger.publish(second)
    assert_receive {:arbor_mcp_output, _, :session, :ready}
    refute_receive {:arbor_mcp_output, _, :session, :ready}, 10
    assert {:ok, ^first, _, _} = Ledger.checkout(ref, :session)
    assert {:error, :output_credit_exhausted} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.ack(first)
    assert_receive {:arbor_mcp_output, _, :session, :ready}
    assert {:ok, ^second, _, _} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.ack(second)
  end

  test "only ticket owner publishes and only registered consumer acknowledges" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)

    assert {:error, :invalid_output_owner} =
             Task.async(fn -> Ledger.publish(ticket) end) |> Task.await()

    assert :ok = Ledger.publish(ticket)
    assert {:ok, _, _, _} = Ledger.checkout(ref, :session)

    assert {:error, :invalid_output_owner} =
             Task.async(fn -> Ledger.ack(ticket) end) |> Task.await()

    assert :ok = Ledger.ack(ticket)
  end

  test "scope retirement releases prepared queued and delivered frames atomically" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, hidden} = prepare(ref)
    assert {:ok, queued} = prepare(ref)
    assert {:ok, delivered} = prepare(ref)
    assert :ok = Ledger.publish(delivered)
    assert :ok = Ledger.publish(queued)
    assert {:ok, ^delivered, _, _} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.retire_scope(ref, :session, :peer_closed)
    assert_receive {:arbor_mcp_output, _, :session, {:closed, :peer_closed}}
    assert %{frames: 0, bytes: 0, scopes: 0} = Ledger.stats(ref)
    for ticket <- [hidden, queued, delivered], do: assert(:ok == Ledger.release(ticket))
    assert {:error, :output_unknown_scope} = prepare(ref)
    assert {:error, :output_unknown_scope} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.retire_scope(ref, :session)
    refute_receive {:arbor_mcp_output, _, :session, {:closed, _}}, 10
  end

  test "generation reset invalidates every old handle and recycles bounded tombstones" do
    ref = ledger(max_output_frames: 1)
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.retire_scope(ref, :session)
    assert :ok = Ledger.open_scope(ref, :other)
    assert {:error, :output_scope_limit} = Ledger.open_scope(ref, :extra)
    assert {:error, :invalid_generation} = Ledger.reset_generation(ref, ref.generation)
    assert {:ok, fresh} = Ledger.reset_generation(ref, make_ref())
    assert {:error, :output_unavailable} = Ledger.publish(ticket)
    assert {:error, :output_unavailable} = prepare(ref)
    assert %{scopes: 0, frames: 0} = Ledger.stats(fresh)
    assert :ok = Ledger.open_scope(fresh, :new)
    assert {:ok, _} = prepare(fresh, %{"new" => true}, scope: :new)
  end

  test "generation reset racing preparation cannot resurrect old payloads or monitors" do
    ref = ledger(max_output_frames: 40)

    producers =
      for _ <- 1..100, do: hold_producer(self(), ref, %{"data" => String.duplicate("z", 500)}, [])

    Enum.each(producers, &send(&1, :go))
    assert {:ok, fresh} = Ledger.reset_generation(ref, make_ref())
    outcomes = results(100)

    Enum.each(outcomes, fn
      {_, {:ok, ticket}} ->
        assert {:error, :output_unavailable} == Ledger.publish(ticket)

      {_, {:error, reason}} ->
        assert reason in [
                 :output_unavailable,
                 :output_expired,
                 :output_full,
                 :output_call_expired
               ]
    end)

    Enum.each(producers, &send(&1, :stop))
    assert %{frames: 0, bytes: 0, scopes: 0} = Ledger.stats(fresh)
    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "active scope count and subscriber metadata are bounded without unknown tombstones" do
    ref = ledger(max_output_frames: 3, max_scope_bytes: 2_000)
    for scope <- [:a, :b], do: assert(:ok == Ledger.open_scope(ref, scope))
    assert {:error, :output_scope_limit} = Ledger.open_scope(ref, :c)
    for n <- 1..20, do: assert(:ok == Ledger.retire_scope(ref, {:unknown, n}))
    assert %{scopes: 3} = Ledger.stats(ref)
    assert Ledger.stats(ref).metadata_bytes <= 2_000
    assert {:error, :invalid_output_scope} = Ledger.open_scope(ref, String.duplicate("s", 5_000))
    assert :ok = Ledger.retire_scope(ref, :a)
    assert :ok = Ledger.open_scope(ref, :c)
    assert Ledger.stats(ref).scopes == 3
    assert Process.alive?(ref.pid)
  end

  test "hundreds of retired connection scopes recycle capacity while an active scope survives" do
    ref = ledger(max_output_frames: 2)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, active} = prepare(ref)
    assert :ok = Ledger.publish(active)

    retired =
      for _ <- 1..350 do
        scope = make_ref()
        assert :ok = Ledger.open_scope(ref, scope)
        assert :ok = Ledger.retire_scope(ref, scope)
        scope
      end

    assert %{scopes: 1, queued: 1, frames: 1} = Ledger.stats(ref)

    for scope <- retired do
      assert {:error, :output_unknown_scope} = prepare(ref, %{"late" => true}, scope: scope)
    end

    assert {:ok, ^active, _, _} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.ack(active)
  end

  test "late live producers cannot recreate retired scope metadata" do
    ref = ledger()
    parent = self()
    old_scope = make_ref()
    assert :ok = Ledger.open_scope(ref, old_scope)

    producer =
      spawn(fn ->
        receive do
          :prepare -> send(parent, {:late_prepare, prepare(ref, %{}, scope: old_scope)})
        end
      end)

    assert :ok = Ledger.retire_scope(ref, old_scope)

    for _ <- 1..200 do
      scope = make_ref()
      assert :ok = Ledger.open_scope(ref, scope)
      assert :ok = Ledger.retire_scope(ref, scope)
    end

    send(producer, :prepare)
    assert_receive {:late_prepare, {:error, :output_unknown_scope}}
    assert %{scopes: 1, frames: 0} = Ledger.stats(ref)
  end

  test "scope opening is restricted to lifetime owner and unknown output cannot prepare" do
    ref = ledger()
    scope = make_ref()

    assert {:error, :invalid_output_owner} =
             Task.async(fn -> Ledger.open_scope(ref, scope) end) |> Task.await()

    assert {:error, :output_unknown_scope} = prepare(ref, %{}, scope: scope)
    assert :ok = Ledger.open_scope(ref, scope)
    assert {:ok, hidden} = prepare(ref, %{}, scope: scope)
    assert :ok = Ledger.release(hidden)
  end

  test "paused actor scope-control pressure is bounded and timed-out openings stay absent" do
    ref = ledger(max_output_frames: 1, max_scope_bytes: 1_000, call_timeout_ms: 5)
    :sys.suspend(ref.pid)
    results = for n <- 1..20, do: Ledger.open_scope(ref, {String.duplicate("s", 100), n})

    assert Enum.all?(results, fn result ->
             result in [
               {:error, :output_unavailable},
               {:error, :output_busy},
               {:error, :output_scope_limit},
               {:error, :output_call_expired}
             ]
           end)

    assert Ledger.stats(ref).scopes == 1
    assert Ledger.stats(ref).pending_controls <= 3
    assert Ledger.stats(ref).metadata_bytes <= 1_000
    {:messages, messages} = Process.info(ref.pid, :messages)
    assert Enum.count(messages, &match?({:"$gen_call", _, _}, &1)) <= 3
    :sys.resume(ref.pid)
    eventually(fn -> Ledger.stats(ref).pending_controls == 0 end)
    assert Ledger.stats(ref).scopes == 1
    assert Ledger.stats(ref).frames == 0
  end

  test "small metadata budgets reject subscriptions without leaked monitor state" do
    ref = ledger(max_scope_bytes: 600)

    assert {:error, :output_scope_limit} = Ledger.open_scope(ref, String.duplicate("s", 250))

    assert {:error, :output_unknown_scope} =
             Ledger.subscribe(ref, String.duplicate("s", 250), self())

    assert Ledger.stats(ref).scopes == 1
    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "bounded control slots survive timeouts without late preparation or scope effects" do
    ref = ledger(call_timeout_ms: 20)
    :sys.suspend(ref.pid)
    parent = self()

    producer =
      spawn(fn ->
        send(parent, {:result, prepare(ref)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:result, {:error, :output_unavailable}}, 500
    assert %{frames: 1, pending_controls: 1} = Ledger.stats(ref)

    assert {:error, :output_unavailable} = Ledger.subscribe(ref, :session, self())
    assert {:error, :output_busy} = Ledger.subscribe(ref, :session, self())

    :sys.resume(ref.pid)

    eventually(fn ->
      Ledger.stats(ref).frames == 0 and Ledger.stats(ref).pending_controls == 0
    end)

    assert :sys.get_state(ref.pid).monitors == %{}
    assert :sys.get_state(ref.pid).ref == ref
    send(producer, :stop)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert :empty = Ledger.checkout(ref, :session)
  end

  test "timed-out checkout preserves the frame for a subsequent live read" do
    ref = ledger(call_timeout_ms: 20)
    parent = self()

    consumer =
      spawn(fn ->
        receive do
          {:checkout, ref} -> send(parent, {:checkout_result, Ledger.checkout(ref, :session)})
        end

        receive do
          :again -> send(parent, {:second_checkout, Ledger.checkout(ref, :session)})
        end

        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Ledger.subscribe(ref, :session, consumer)
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    :sys.suspend(ref.pid)
    send(consumer, {:checkout, ref})
    assert_receive {:checkout_result, {:error, :output_unavailable}}, 500
    :sys.resume(ref.pid)
    eventually(fn -> Ledger.stats(ref).pending_controls == 0 end)
    assert Ledger.stats(ref).queued == 1
    send(consumer, :again)
    assert_receive {:second_checkout, {:ok, ^ticket, _, _}}
    assert :ok = Ledger.release(ticket)
    send(consumer, :stop)
  end

  test "claim-only transitions retain the exact metadata cap while new scopes remain bounded" do
    probe = ledger(max_output_frames: 8)
    assert :ok = Ledger.subscribe(probe, :session, self())
    budget = Ledger.stats(probe).metadata_bytes
    ref = ledger(max_output_frames: 8, max_scope_bytes: budget)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert {:ok, %{"ok" => true}} = Ledger.value(ticket)
    assert :ok = Ledger.handoff(ticket)
    assert :ok = Ledger.publish(ticket)
    assert %{frames: 1, queued: 1, metadata_bytes: ^budget} = Ledger.stats(ref)
    assert {:error, :output_scope_limit} = Ledger.open_scope(ref, :extra)
    assert %{scopes: 1, frames: 1, metadata_bytes: ^budget} = Ledger.stats(ref)
    assert {:ok, ^ticket, %{"ok" => true}, _} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.ack(ticket)
    assert %{scopes: 1, frames: 0, bytes: 0, metadata_bytes: ^budget} = Ledger.stats(ref)
    assert :ok = Ledger.retire_scope(ref, :session)
    assert :ok = Ledger.open_scope(ref, :session)
    assert Ledger.stats(ref).metadata_bytes == budget
  end

  test "external producers cannot skip a smaller metadata limit by copying actor dictionary state" do
    ref = ledger()
    budget = Ledger.stats(ref).metadata_bytes
    altered = %{ref | limits: %{ref.limits | max_scope_bytes: budget - 1}}
    assert {:error, :output_scope_limit} = prepare(altered)
    key = {Ledger, :reference}
    previous = Process.get(key)
    :sys.suspend(ref.pid)
    Process.put(key, altered)

    try do
      assert {:error, :output_scope_limit} = prepare(altered)

      assert %{frames: 0, bytes: 0, pending_controls: 0, metadata_bytes: ^budget} =
               Ledger.stats(ref)
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
      :sys.resume(ref.pid)
    end

    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.release(ticket)
  end

  test "actor confirmation does not inherit a larger external producer metadata limit" do
    probe = ledger(max_output_frames: 8)
    budget = Ledger.stats(probe).metadata_bytes
    ref = ledger(max_output_frames: 8, max_scope_bytes: budget)
    altered = %{ref | limits: %{ref.limits | max_scope_bytes: budget * 64}}
    parent = self()
    :sys.suspend(ref.pid)

    producers =
      for _ <- 1..8 do
        producer =
          spawn(fn ->
            send(parent, {:prepared, self(), prepare(altered, %{}, owner: self())})
          end)

        on_exit(fn ->
          if Process.alive?(producer), do: Process.exit(producer, :kill)
        end)

        producer
      end

    first =
      try do
        eventually(fn ->
          stats = Ledger.stats(ref)
          {:messages, messages} = Process.info(ref.pid, :messages)
          queued = Enum.count(messages, &match?({:"$gen_call", _, {:operation, _}}, &1))
          stats.prepared == 8 and stats.pending_controls == 8 and queued == 8
        end)

        assert Ledger.stats(ref).metadata_bytes > budget
        {:messages, messages} = Process.info(ref.pid, :messages)

        Enum.find_value(messages, fn
          {:"$gen_call", {producer, _}, {:operation, _}} -> producer
          _ -> nil
        end)
      after
        :sys.resume(ref.pid)
      end

    assert first in producers
    assert_receive {:prepared, ^first, {:error, :output_scope_limit}}, 1_000
    outcomes = results(7)

    assert Enum.all?(outcomes, fn {_, result} ->
             match?({:ok, _}, result) or result == {:error, :output_scope_limit}
           end)

    eventually(fn ->
      Ledger.stats(ref).frames == 0 and Ledger.stats(ref).pending_controls == 0
    end)
  end

  test "growing pending ticket controls cannot bypass the exact scope metadata cap" do
    probe = ledger(max_output_frames: 8)
    budget = Ledger.stats(probe).metadata_bytes
    ref = ledger(max_output_frames: 8, max_scope_bytes: budget)
    parent = self()

    producers =
      for _ <- 1..8 do
        producer =
          spawn(fn ->
            result = prepare(ref, %{"ok" => true}, owner: self())
            send(parent, {:prepared, self(), result})

            receive do
              :value ->
                {:ok, ticket} = result
                send(parent, {:metadata_value, self(), Ledger.value(ticket)})
            end

            receive do
              :stop ->
                {:ok, ticket} = result
                Ledger.release(ticket)
            end
          end)

        on_exit(fn ->
          if Process.alive?(producer), do: Process.exit(producer, :kill)
        end)

        assert [{^producer, {:ok, _}}] = results(1)
        producer
      end

    :sys.suspend(ref.pid)

    try do
      Enum.each(producers, &send(&1, :value))

      eventually(fn ->
        {:messages, messages} = Process.info(self(), :messages)
        completed = Enum.count(messages, &match?({:metadata_value, _, _}, &1))
        Ledger.stats(ref).pending_controls + completed == 8
      end)

      assert %{frames: 8, scopes: 1, pending_controls: pending} = Ledger.stats(ref)
      assert pending > 0 and pending < 8
      assert Ledger.stats(ref).metadata_bytes <= budget
    after
      :sys.resume(ref.pid)
    end

    outcomes =
      for _ <- producers do
        assert_receive {:metadata_value, producer, result}, 1_000
        assert producer in producers
        result
      end

    assert {:ok, %{"ok" => true}} in outcomes
    assert {:error, :output_scope_limit} in outcomes
    assert Enum.all?(outcomes, &(&1 in [{:ok, %{"ok" => true}}, {:error, :output_scope_limit}]))
    Enum.each(producers, &send(&1, :stop))

    eventually(fn ->
      Ledger.stats(ref).frames == 0 and Ledger.stats(ref).pending_controls == 0
    end)

    assert Ledger.stats(ref).metadata_bytes == budget
  end

  test "non-nil scope controls still charge function-captured binary backing" do
    ref = ledger(max_scope_bytes: 2_000)
    before = Ledger.stats(ref)
    backing = String.duplicate("x", 16_384)
    slice = binary_part(backing, 0, 128)
    marker = make_ref()
    scope = fn -> {marker, slice} end
    assert :erlang.external_size(scope) < 4_096
    assert :binary.referenced_byte_size(slice) > byte_size(slice)
    assert {:error, :output_scope_limit} = Ledger.open_scope(ref, scope)
    assert Ledger.stats(ref) == before
    assert :sys.get_state(ref.pid).monitors == %{}
  end

  test "generation replacement cannot authorize old claim-only changes or lose metadata limits" do
    probe = ledger(max_output_frames: 8)
    budget = Ledger.stats(probe).metadata_bytes
    ref = ledger(max_output_frames: 8, max_scope_bytes: budget)
    assert {:ok, old} = prepare(ref)
    assert :ok = Ledger.handoff(old)
    assert {:ok, fresh} = Ledger.reset_generation(ref, make_ref())
    assert {:ok, ^fresh} = Ledger.ref(ref.pid)
    assert {:error, :output_unavailable} = Ledger.publish(old)
    assert {:error, :output_unavailable} = prepare(ref)
    assert %{frames: 0, bytes: 0, scopes: 0, pending_controls: 0} = Ledger.stats(fresh)
    assert :ok = Ledger.open_scope(fresh, :session)
    assert {:error, :output_scope_limit} = Ledger.open_scope(fresh, :extra)
    assert {:ok, ticket} = prepare(fresh)
    assert :ok = Ledger.handoff(ticket)
    assert :ok = Ledger.release(ticket)
    assert %{frames: 0, bytes: 0, scopes: 1, metadata_bytes: ^budget} = Ledger.stats(fresh)
  end

  test "metadata reserved at admission permits drain and retirement at the exact cap" do
    probe = ledger()
    assert :ok = Ledger.subscribe(probe, :session, self())
    budget = Ledger.stats(probe).metadata_bytes
    ref = ledger(max_scope_bytes: budget)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    assert Ledger.stats(ref).metadata_bytes == budget
    assert :ok = Ledger.begin_drain(ref, :session, now() + 1_000)
    assert :ok = Ledger.seal(ref, :session)
    assert :ok = Ledger.retire_scope(ref, :session)
    assert Ledger.stats(ref).bytes == 0
    assert Ledger.stats(ref).metadata_bytes < budget
    assert :ok = Ledger.open_scope(ref, :another)
  end

  test "output drain allows prior prepared publication but rejects new preparations" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.begin_drain(ref, :session, now() + 1_000)
    assert {:error, :output_sealed} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    assert {:ok, ^ticket, _, _} = Ledger.checkout(ref, :session)
    refute Ledger.drained?(ref, :session)
    assert :ok = Ledger.ack(ticket)
    assert Ledger.drained?(ref, :session)
    assert :ok = Ledger.seal(ref, :session)
    assert {:error, :output_sealed} = prepare(ref)
  end

  test "seal releases hidden frames and drains previously published frames" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, hidden} = prepare(ref)
    assert {:ok, published} = prepare(ref)
    assert :ok = Ledger.publish(published)
    assert :ok = Ledger.seal(ref, :session)
    assert {:error, :output_released} = Ledger.publish(hidden)
    assert {:ok, ^published, _, _} = Ledger.checkout(ref, :session)
    assert :ok = Ledger.ack(published)
    assert Ledger.drained?(ref, :session)
  end

  test "drain timeout explicitly retires output without claiming delivery" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    assert :ok = Ledger.begin_drain(ref, :session, now() + 30)
    assert_receive {:arbor_mcp_output, _, :session, {:closed, :drain_timeout}}, 500
    assert Ledger.drained?(ref, :session)
    assert :ok = Ledger.release(ticket)
  end

  test "expired published frame emits a terminal event instead of silently disappearing" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref, %{"late" => true}, deadline: now() + 30)
    assert :ok = Ledger.publish(ticket)
    assert_receive {:arbor_mcp_output, _, :session, {:closed, :output_expired}}, 500
    assert Ledger.stats(ref).frames == 0
  end

  test "consumer death retires its scope and reclaims in-flight ownership" do
    ref = ledger()

    consumer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Ledger.subscribe(ref, :session, consumer)
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    Process.exit(consumer, :kill)
    eventually(fn -> Ledger.stats(ref).frames == 0 end)
    assert {:error, :output_unknown_scope} = prepare(ref)
  end

  test "lifetime owner death removes the actor and its ETS payloads" do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:open, ref} -> send(parent, {:opened, Ledger.open_scope(ref, :session)})
        end

        receive do
          :stop -> :ok
        end
      end)

    pid = start_supervised!({Ledger, owner: owner})
    monitor = Process.monitor(pid)
    assert {:ok, ref} = Ledger.ref(pid)
    send(owner, {:open, ref})
    assert_receive {:opened, :ok}
    assert {:ok, _} = prepare(ref, %{"owned" => true}, owner: parent)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
    assert :ets.info(ref.table) == :undefined
    assert {:error, :output_unavailable} = Ledger.stats(ref)
  end

  test "confirmation waits only until the original output deadline and cannot publish late" do
    ref = ledger(call_timeout_ms: 5_000)
    parent = self()
    :sys.suspend(ref.pid)

    producer =
      spawn(fn ->
        started = now()
        result = prepare(ref, %{}, deadline: started + 30)
        send(parent, {:bounded_prepare, result, now() - started})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:bounded_prepare, {:error, reason}, elapsed}, 250
    assert reason in [:output_unavailable, :output_call_expired]
    assert elapsed < 200
    :sys.resume(ref.pid)

    eventually(fn ->
      Ledger.stats(ref).frames == 0 and Ledger.stats(ref).pending_controls == 0
    end)

    assert :sys.get_state(ref.pid).monitors == %{}
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert :empty = Ledger.checkout(ref, :session)
    send(producer, :stop)
  end

  test "publication uses the ticket deadline rather than a fresh control wait" do
    ref = ledger(call_timeout_ms: 5_000)
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:publish, ticket} ->
            started = now()
            result = Ledger.publish(ticket)
            send(parent, {:bounded_publish, result, now() - started})
        end

        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, ticket} = prepare(ref, %{}, owner: owner, deadline: now() + 40)
    :sys.suspend(ref.pid)
    send(owner, {:publish, ticket})
    assert_receive {:bounded_publish, {:error, reason}, elapsed}, 250
    assert reason in [:output_unavailable, :output_call_expired]
    assert elapsed < 200
    :sys.resume(ref.pid)
    eventually(fn -> Ledger.stats(ref).frames == 0 end)
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert :empty = Ledger.checkout(ref, :session)
    send(owner, :stop)
  end

  test "sealing retains an established finite drain deadline" do
    ref = ledger()
    assert :ok = Ledger.subscribe(ref, :session, self())
    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.publish(ticket)
    assert :ok = Ledger.begin_drain(ref, :session, now() + 30)
    assert :ok = Ledger.seal(ref, :session)
    assert_receive {:arbor_mcp_output, _, :session, {:closed, :drain_timeout}}, 500
    assert Ledger.drained?(ref, :session)
  end

  test "preparation preserves the original deadline through serialization and admission" do
    ref = ledger()
    term = Enum.map(1..20_000, fn n -> %{"index" => n} end)
    result = prepare(ref, term, deadline: now() + 1)

    assert result in [
             {:error, :invalid_output_deadline},
             {:error, :output_call_expired},
             {:error, :output_expired}
           ]

    eventually(fn -> Ledger.stats(ref).frames == 0 end)
  end

  test "bounded terminal reason validation preserves a live scope on invalid input" do
    ref = ledger()

    assert {:error, :invalid_reason} =
             Ledger.retire_scope(ref, :session, String.to_atom(String.duplicate("r", 100)))

    assert {:ok, ticket} = prepare(ref)
    assert :ok = Ledger.release(ticket)
  end

  test "expired preparation deadline is rejected without retaining an output" do
    ref = ledger()
    assert {:error, :invalid_output_deadline} = prepare(ref, %{}, deadline: now() - 1)
    assert Ledger.stats(ref).frames == 0
    assert {:error, :invalid_output_scope} = Ledger.prepare(ref, %{}, deadline: now() + 1_000)
  end
end
