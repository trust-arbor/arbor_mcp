defmodule Arbor.MCP.Server.Runtime.InputByteCleanupTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, ByteBudget, Deadline, Ref}

  defmodule Handler do
    def init(_opts), do: {:ok, %{}}

    def dispatch(request, _handler, state, _opts),
      do: {:response, %{"id" => request["id"], "result" => true}, state}
  end

  test "expired rollback keeps byte and count credit with one wake until the owner resumes" do
    {runtime, route} = runtime(max_queue: 0)
    pause(route.admission)
    {producer, candidate} = candidate(runtime)
    table = Ref.table(runtime)
    charged = ByteBudget.used(table).data

    for _repeat <- 1..30,
        do:
          assert(
            {:pending, :release} = ByteBudget.release(table, candidate.token, deadline: past())
          )

    assert charged > 0
    assert ByteBudget.used(table).data == charged
    assert length(slots(table)) == 1
    assert length(ByteBudget.pending(table)) == 1
    {:messages, messages} = Process.info(route.admission, :messages)
    assert Enum.count(messages, &(&1 == :byte_cleanup)) == 1
    assert Enum.all?(messages, &(:erlang.external_size(&1) < 256))
    assert {:error, :server_busy} = reserve(runtime)

    :sys.resume(route.admission)
    assert_receive {:candidate_returned, ^producer, {:error, :admission_lost}}, 1_000
    empty(runtime)
    assert {:ok, _route, fresh} = reserve(runtime)
    assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    empty(runtime)
  end

  test "all three lanes retain expired cleanup ownership and reuse credit after reaping" do
    {runtime, route} = runtime(max_queue: 0, max_control_queue: 1)
    pause(route.admission)
    table = Ref.table(runtime)

    held =
      for kind <- [:ingress, :edge_control, :edge_response], do: candidate(runtime, kind: kind)

    used = ByteBudget.used(table)
    assert Enum.all?(Map.values(used), &(&1 > 0))

    for {_producer, candidate} <- held,
        do:
          assert(
            {:pending, :release} = ByteBudget.release(table, candidate.token, deadline: past())
          )

    assert ByteBudget.used(table) == used
    assert length(slots(table)) == 3
    assert length(ByteBudget.pending(table)) == 3
    {:messages, messages} = Process.info(route.admission, :messages)
    assert Enum.count(messages, &(&1 == :byte_cleanup)) == 1

    for kind <- [:ingress, :edge_control, :edge_response],
        do: assert({:error, :server_busy} = reserve(runtime, kind: kind))

    :sys.resume(route.admission)

    for {producer, _candidate} <- held,
        do: assert_receive({:candidate_returned, ^producer, {:error, :admission_lost}}, 1_000)

    empty(runtime)

    for kind <- [:ingress, :edge_control, :edge_response] do
      assert {:ok, _route, fresh} = reserve(runtime, kind: kind)
      assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    end

    empty(runtime)
  end

  test "release upgrades a deferred trim and subsequent trims cannot undo the release" do
    {runtime, route} = runtime()
    pause(route.admission)
    {producer, candidate} = candidate(runtime)
    table = Ref.table(runtime)
    assert {:pending, :trim} = ByteBudget.confirm(table, candidate.token, deadline: past())
    assert [{candidate.token, producer, :trim}] == ByteBudget.pending(table)
    assert {:pending, :release} = ByteBudget.release(table, candidate.token, deadline: past())
    assert {:pending, :trim} = ByteBudget.confirm(table, candidate.token, deadline: past())
    assert [{candidate.token, producer, :release}] == ByteBudget.pending(table)
    assert is_map(ByteBudget.candidate(table, candidate.token))
    :sys.resume(route.admission)
    assert_receive {:candidate_returned, ^producer, {:error, :admission_lost}}, 1_000
    empty(runtime)
  end

  test "deferred trim can settle without releasing an accepted reservation" do
    {runtime, route} = runtime()
    pause(route.admission)
    {producer, candidate} = candidate(runtime)
    table = Ref.table(runtime)
    assert {:pending, :trim} = ByteBudget.confirm(table, candidate.token, deadline: past())
    :sys.resume(route.admission)
    assert_receive {:candidate_returned, ^producer, {:ok, _route, held}}, 1_000
    wait_for(fn -> ByteBudget.pending(table) == [] end)
    assert ByteBudget.candidate(table, held.token) == nil
    assert %{reserved: 1, confirmed: 1, pending_byte_cleanup: 0} = Runtime.stats(runtime)
    assert ByteBudget.used(table).data == held.bytes
    assert :ok = RuntimeIngress.discard_ingress(runtime, held.token)
    empty(runtime)
  end

  test "producer death with deferred cleanup reaps the complete batch without orphan bytes" do
    {runtime, route} = runtime(max_queue: 2)
    pause(route.admission)
    {producer, candidate} = candidate(runtime, members: [nil, 42, false])
    table = Ref.table(runtime)
    assert length(slots(table)) == 3
    assert {:pending, :release} = ByteBudget.release(table, candidate.token, deadline: past())
    Process.exit(producer, :kill)
    :sys.resume(route.admission)
    empty(runtime)
    assert {:ok, _route, fresh} = reserve(runtime, members: [nil, 42, false])
    assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    empty(runtime)
  end

  test "owner death after handoff retires pending cleanup without dropping a neighboring lease" do
    {runtime, route} = runtime(max_queue: 1)
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> kill(owner) end)
    assert {:ok, held_route, held} = reserve(runtime, owner: owner, reply_to: parent)

    assert :ok =
             RuntimeIngress.publish_ingress(
               runtime,
               held_route,
               held,
               {:probe, :held},
               owner
             )

    assert {:ok, _held, {:probe, :held}} = Admission.checkout(Ref.table(runtime), held.token)
    assert {:ok, _route, neighbor} = reserve(runtime)
    pause(route.admission)
    Process.exit(owner, :kill)

    assert {:pending, :release} =
             ByteBudget.release(Ref.table(runtime), held.token, deadline: past())

    :sys.resume(route.admission)
    wait_for(fn -> Runtime.stats(runtime).reserved == 1 end)
    assert {:ok, _neighbor} = Admission.current(Ref.table(runtime), neighbor.token)
    assert ByteBudget.used(Ref.table(runtime)).data == neighbor.bytes

    assert :ok =
             RuntimeIngress.discard_ingress(runtime, neighbor.token)

    empty(runtime)
  end

  test "duplicate old releases cannot delete freshly reused permits or their byte credit" do
    {runtime, _route} = runtime(max_queue: 0)
    assert {:ok, _route, old} = reserve(runtime)
    assert :ok = RuntimeIngress.discard_ingress(runtime, old.token)
    assert {:ok, _route, fresh} = reserve(runtime)

    for _repeat <- 1..20 do
      assert :ok = ByteBudget.release(Ref.table(runtime), old.token, deadline: past())
      assert :ok = RuntimeIngress.discard_ingress(runtime, old.token)
    end

    assert %{reserved: 1, admitted_work: 1, pending_bytes: bytes} = Runtime.stats(runtime)
    assert bytes == fresh.bytes
    assert {:ok, _fresh} = Admission.current(Ref.table(runtime), fresh.token)
    assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    empty(runtime)
  end

  test "scheduler generation retirement clears all lanes and late cleanup cannot delete new permits" do
    {runtime, route} = runtime(max_queue: 0, max_control_queue: 1)
    pause(route.admission)
    table = Ref.table(runtime)

    held =
      for kind <- [:ingress, :edge_control, :edge_response], do: candidate(runtime, kind: kind)

    for {_producer, old} <- held,
        do: assert({:pending, :release} = ByteBudget.release(table, old.token, deadline: past()))

    Process.exit(route.scheduler, :kill)
    :sys.resume(route.admission)

    wait_for(fn ->
      case Admission.route(table) do
        {:ok, fresh} -> fresh.generation != route.generation
        _error -> false
      end
    end)

    empty(runtime)
    assert {:ok, _route, fresh} = reserve(runtime)

    for {_producer, old} <- held,
        do: assert(:ok == ByteBudget.release(table, old.token, deadline: past()))

    assert %{reserved: 1, pending_bytes: bytes, pending_byte_cleanup: 0} = Runtime.stats(runtime)
    assert bytes == fresh.bytes
    assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    empty(runtime)
  end

  test "cleanup owner hard death replaces the generation and abandons retained token records" do
    {runtime, route} = runtime(max_queue: 0)
    pause(route.admission)
    {_producer, old} = candidate(runtime)
    table = Ref.table(runtime)
    assert {:pending, :release} = ByteBudget.release(table, old.token, deadline: past())
    Process.exit(route.admission, :kill)

    wait_for(fn ->
      case Admission.route(table) do
        {:ok, fresh} -> fresh.admission != route.admission
        _error -> false
      end
    end)

    empty(runtime)
    assert {:ok, _route, fresh} = reserve(runtime)
    assert :ok = ByteBudget.release(table, old.token, deadline: past())
    assert ByteBudget.used(table).data == fresh.bytes
    assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    empty(runtime)
  end

  @tag timeout: 20_000
  test "hot claim, trim and release contention stays within lane bounds and eventually readmits" do
    {runtime, _route} =
      runtime(
        max_queue: 7,
        max_control_queue: 8,
        max_pending_bytes: 16_000,
        max_control_bytes: 8_000
      )

    table = Ref.table(runtime)
    parent = self()
    kinds = [:ingress, :edge_control, :edge_response]

    sampler =
      spawn(fn ->
        sample(table, parent, %{data: 0, outgoing: 0, incoming: 0, slots: 0, markers: 0})
      end)

    on_exit(fn -> kill(sampler) end)

    producers =
      for index <- 1..60 do
        spawn(fn ->
          kind = Enum.at(kinds, rem(index, 3))

          outcomes =
            for _round <- 1..10 do
              case reserve(runtime, kind: kind) do
                {:ok, _route, held} ->
                  :ok =
                    RuntimeIngress.discard_ingress(runtime, held.token)

                  :accepted

                {:error, reason} ->
                  reason
              end
            end

          send(parent, {:hot_done, self(), outcomes})
        end)
      end

    on_exit(fn -> Enum.each(producers, &kill/1) end)

    outcomes =
      for _producer <- producers do
        assert_receive {:hot_done, _pid, results}, 5_000
        results
      end

    assert :accepted in List.flatten(outcomes)
    assert Enum.all?(List.flatten(outcomes), &(&1 in [:accepted, :server_busy, :handler_timeout]))
    send(sampler, :stop)
    assert_receive {:sampled, maximum}, 1_000
    assert maximum.data <= 16_000
    assert maximum.outgoing <= 8_000
    assert maximum.incoming <= 8_000
    assert maximum.slots <= 24
    assert maximum.markers <= 24
    empty(runtime)

    for kind <- kinds do
      assert {:ok, _route, fresh} = reserve(runtime, kind: kind)
      assert :ok = RuntimeIngress.discard_ingress(runtime, fresh.token)
    end

    empty(runtime)
  end

  defp runtime(opts \\ []) do
    options =
      Keyword.merge(
        [handler: Handler, dispatcher: Handler, request_timeout_ms: 5_000, max_queue: 2],
        opts
      )

    root = start_supervised!({Runtime, Keyword.put(options, :id, make_ref())})
    assert {:ok, runtime} = Runtime.ref(root)
    assert {:ok, route} = Admission.route(Ref.table(runtime))
    {runtime, route}
  end

  defp reserve(runtime, opts \\ []) do
    members = Keyword.get(opts, :members, [%{"one" => true}])

    RuntimeIngress.reserve_ingress(
      runtime,
      members,
      Keyword.delete(opts, :members)
    )
  end

  defp candidate(runtime, opts \\ []) do
    parent = self()

    producer =
      spawn(fn ->
        result = reserve(runtime, Keyword.merge([owner: parent, reply_to: parent], opts))
        send(parent, {:candidate_returned, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> kill(producer) end)

    candidate =
      wait_for(fn ->
        case Enum.find(slots(Ref.table(runtime)), fn {_key, _token, pid} -> pid == producer end) do
          {_key, token, _pid} -> ByteBudget.candidate(Ref.table(runtime), token)
          nil -> nil
        end
      end)

    {producer, candidate}
  end

  defp sample(table, parent, maximum) do
    values =
      ByteBudget.used(table)
      |> Map.put(:slots, length(slots(table)))
      |> Map.put(:markers, cleanup_records(table))

    maximum = Map.merge(maximum, values, fn _key, old, new -> max(old, new) end)

    receive do
      :stop -> send(parent, {:sampled, maximum})
    after
      1 -> sample(table, parent, maximum)
    end
  end

  defp pause(pid) do
    :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
  end

  defp empty(runtime),
    do:
      wait_for(fn ->
        case Runtime.stats(runtime) do
          %{reserved: 0, pending_bytes: 0, pending_byte_cleanup: 0} -> true
          _state -> false
        end
      end)

  defp cleanup_records(table),
    do: :ets.select_count(table, [{{{:byte_cleanup, :_}, :_, :_}, [], [true]}])

  defp slots(table), do: :ets.match_object(table, {{:slot, :_}, :_, :_})
  defp past, do: Deadline.now() - 1
  defp kill(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))
  defp wait_for(fun, attempts \\ 200)
  defp wait_for(_fun, 0), do: flunk("byte cleanup did not reach its expected state")

  defp wait_for(fun, attempts) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _result ->
        Process.sleep(5)
        wait_for(fun, attempts - 1)
    end
  end
end
