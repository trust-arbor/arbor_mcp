defmodule Arbor.MCP.Server.RuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, ByteBudget, CallbackContext, Ref}

  defmodule Handler do
    def init(args) do
      if args[:block_init] do
        root = Enum.at(Process.get(:"$ancestors"), 1)
        send(args[:test_pid], {:blocking_handler_init, self(), root})

        receive do
          :allow_init -> :ok
        end
      end

      send(args[:test_pid], {:initialized, args[:label], self()})

      {:ok,
       %{
         test_pid: args[:test_pid],
         label: args[:label],
         counter: 0,
         block_terminate: args[:block_terminate] || false
       }}
    end

    def dispatch(request, _module, state, _opts) do
      id = request["id"]
      method = request["method"]
      send(state.test_pid, {:started, state.label, id, self(), state.counter})

      case method do
        "inc" ->
          response(id, state.counter + 1, %{state | counter: state.counter + 1})

        "read" ->
          response(id, state.counter, state)

        "hold" ->
          receive do
            :release -> response(id, state.counter, state)
            :mutate -> response(id, 900, %{state | counter: 900})
          end

        "trap_hold" ->
          Process.flag(:trap_exit, true)
          send(state.test_pid, {:trapping_worker, state.label, self()})

          receive do
            :release -> response(id, state.counter, state)
          end

        "poll" ->
          poll(id, state)

        "crash" ->
          raise "private-payload-and-credentials"

        "invalid" ->
          :invalid_result

        "malformed_response" ->
          {:response, %{"result" => "malformed"}, %{state | counter: 901}}

        "suppress_response" ->
          {:notification, %{state | counter: 901}}

        "error_with_state" ->
          {:response, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32603}},
           %{state | counter: state.counter + 1}}
      end
    end

    def terminate(reason, state) do
      send(state.test_pid, {:terminating_handler, state.label, self(), reason})

      if state.block_terminate do
        receive do
          :allow_terminate -> :ok
        end
      end

      :ok
    end

    defp poll(id, state) do
      if Runtime.cancelled?() do
        send(state.test_pid, {:observed_cancel, state.label, id, CallbackContext.current()})
        response(id, 900, %{state | counter: 900})
      else
        receive do
          :release -> response(id, state.counter, state)
        after
          5 -> poll(id, state)
        end
      end
    end

    defp response(id, value, state) do
      {:response, %{"jsonrpc" => "2.0", "id" => id, "result" => value}, state}
    end
  end

  defmodule BlockingStore do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid) do
      Process.flag(:trap_exit, true)
      send(test_pid, {:owned_store, self()})
      {:ok, test_pid}
    end

    @impl true
    def terminate(_reason, test_pid) do
      send(test_pid, {:terminating_store, self()})

      receive do
        :allow_terminate -> :ok
      end
    end
  end

  defmodule StoreTree do
    use Supervisor

    def start_link(test_pid), do: Supervisor.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: Supervisor.init([{BlockingStore, test_pid}], strategy: :one_for_one)
  end

  test "stateful callbacks are serialized in separate supervised processes" do
    runtime = start_runtime(label: :serial)
    assert_receive {:initialized, :serial, owner}
    assert {:ok, first} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :serial, 1, callback, 0}
    refute callback == owner
    refute callback == Ref.supervisor(runtime)
    {:links, links} = Process.info(callback, :links)
    refute self() in links

    assert {:ok, second} = Runtime.submit(runtime, message(2, "inc"))
    assert {:ok, third} = Runtime.submit(runtime, message(3, "inc"))
    wait_for(fn -> Runtime.stats(runtime).queued == 2 end)
    refute_receive {:started, :serial, 2, _, _}, 20
    send(callback, :release)
    assert {:ok, %{"result" => 0}} = Runtime.await(first, 1_000)
    assert {:ok, %{"result" => 1}} = Runtime.await(second, 1_000)
    assert {:ok, %{"result" => 2}} = Runtime.await(third, 1_000)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "blocked callback keeps cancellation responsive and cannot commit after cancellation" do
    runtime = start_runtime(label: :cancel, cancel_grace_ms: 200)
    scope = {:session, "shared-id"}
    assert {:ok, token} = Runtime.submit(runtime, message(7, "poll"), scope: scope)
    assert_receive {:started, :cancel, 7, worker, 0}
    started = System.monotonic_time(:millisecond)
    assert :ok = Runtime.cancel(runtime, scope, 7)
    assert System.monotonic_time(:millisecond) - started < 500
    assert {:error, %{"error" => %{"code" => -32001}}} = Runtime.await(token, 1_000)
    assert_receive {:observed_cancel, :cancel, 7, %{token: ^token, scope: ^scope}}
    wait_for(fn -> not Process.alive?(worker) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(8, "inc"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "sibling runtimes and sessions can reuse IDs without sharing cancellation or state" do
    a = start_runtime(label: :a)
    b = start_runtime(label: :b)
    scope = {:session, "same-session"}
    assert {:ok, ta} = Runtime.submit(a, message(1, "hold"), scope: scope)
    assert {:ok, tb} = Runtime.submit(b, message(1, "hold"), scope: scope)
    assert_receive {:started, :a, 1, pa, 0}
    assert_receive {:started, :b, 1, pb, 0}
    assert :ok = Runtime.cancel(a, scope, 1)
    assert {:error, _} = Runtime.await(ta, 1_000)
    assert Process.alive?(pb)
    send(pb, :release)
    assert {:ok, _} = Runtime.await(tb, 1_000)
    wait_for(fn -> not Process.alive?(pa) end)
    assert :ok = Runtime.stop(a)
    assert {:ok, %{"result" => 1}} = Runtime.request(b, message(2, "inc"))

    assert {:ok, t1} = Runtime.submit(b, message(5, "hold"), scope: {:session, "one"})
    assert_receive {:started, :b, 5, p1, 1}
    assert {:ok, t2} = Runtime.submit(b, message(5, "inc"), scope: {:session, "two"})
    assert :ok = Runtime.cancel(b, {:session, "two"}, 5)
    assert {:error, _} = Runtime.await(t2, 1_000)
    send(p1, :release)
    assert {:ok, _} = Runtime.await(t1, 1_000)
  end

  test "queue count rejects excess payload before it enters the scheduler mailbox" do
    runtime = start_runtime(label: :bounded, max_queue: 1)
    assert {:ok, active} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :bounded, 1, worker, 0}
    assert {:ok, queued} = Runtime.submit(runtime, message(2, "inc"))
    wait_for(fn -> Runtime.stats(runtime).queued == 1 end)

    parent = self()

    results =
      3..102
      |> Task.async_stream(
        fn id ->
          Runtime.submit(runtime, message(id, "inc"), owner: parent, reply_to: parent)
        end,
        max_concurrency: 50
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:error, :server_busy}}))
    assert %{active: 1, queued: 1, reserved: 2, confirmed: 2} = Runtime.stats(runtime)
    {:ok, route} = Admission.route(Ref.table(runtime))
    assert {:message_queue_len, 0} = Process.info(route.scheduler, :message_queue_len)

    assert :ok = Runtime.cancel(runtime, {:connection, self()}, 2)
    assert {:error, _} = Runtime.await(queued, 1_000)
    refute_receive {:started, :bounded, 2, _, _}, 20
    assert {:ok, replacement} = Runtime.submit(runtime, message(200, "inc"))
    send(worker, :release)
    assert {:ok, _} = Runtime.await(active, 1_000)
    assert {:ok, %{"result" => 1}} = Runtime.await(replacement, 1_000)
  end

  test "combined retained bytes reject a second request even when count slots are available" do
    held = Map.put(message(1, "hold"), "params", %{"data" => String.duplicate("x", 100)})
    following = message(2, "inc")
    budget = input_bytes(held) + input_bytes(following) - 1
    runtime = start_runtime(label: :bytes, max_pending_bytes: budget, max_queue: 4)
    assert {:ok, token} = Runtime.submit(runtime, held)
    assert_receive {:started, :bytes, 1, worker, 0}
    assert {:error, :server_busy} = Runtime.submit(runtime, following)
    assert Runtime.stats(runtime).pending_bytes == input_bytes(held)
    send(worker, :release)
    assert {:ok, _} = Runtime.await(token, 1_000)
    wait_for(fn -> Runtime.stats(runtime).pending_bytes == 0 end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, following)
  end

  test "a queued deadline expires without invoking the handler and frees capacity" do
    runtime = start_runtime(label: :queued_timeout, max_queue: 1, request_timeout_ms: 500)
    assert {:ok, held} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :queued_timeout, 1, worker, 0}
    assert {:ok, queued} = Runtime.submit(runtime, message(2, "inc"), timeout: 30)

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
             Runtime.await(queued, 1_000)

    refute_receive {:started, :queued_timeout, 2, _, _}, 20
    assert Runtime.stats(runtime).reserved == 1
    send(worker, :release)
    assert {:ok, _} = Runtime.await(held, 1_000)
  end

  test "running deadline reaps blocked work before another stateful callback starts" do
    runtime = start_runtime(label: :timeout, request_timeout_ms: 100, cancel_grace_ms: 30)
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"), timeout: 20)
    assert_receive {:started, :timeout, 1, worker, 0}
    monitor = Process.monitor(worker)

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
             Runtime.await(token, 1_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "worker crashes and malformed results preserve committed state and do not kill owners" do
    runtime = start_runtime(label: :fault)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(1, "inc"))
    assert {:error, response} = Runtime.request(runtime, message(2, "crash"))
    assert response["error"]["data"]["type"] == "handler_crash"
    refute inspect(response) =~ "private-payload"
    assert {:error, invalid} = Runtime.request(runtime, message(3, "invalid"))
    assert invalid["error"]["data"]["type"] == "invalid_handler_result"
    assert {:ok, %{"result" => 2}} = Runtime.request(runtime, message(4, "inc"))
    assert Process.alive?(Ref.supervisor(runtime))
  end

  test "well formed application error can commit its returned state" do
    runtime = start_runtime(label: :application_error)
    assert {:ok, %{"error" => _}} = Runtime.request(runtime, message(1, "error_with_state"))
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "read"))
  end

  test "explicit stateless concurrency reaches its bound and rejects state changes" do
    runtime =
      start_runtime(label: :stateless, execution: :stateless, max_concurrency: 2, max_queue: 0)

    assert {:ok, first} = Runtime.submit(runtime, message(1, "hold"))
    assert {:ok, second} = Runtime.submit(runtime, message(2, "hold"))
    assert_receive {:started, :stateless, 1, one, 0}
    assert_receive {:started, :stateless, 2, two, 0}
    assert %{active: 2} = Runtime.stats(runtime)
    assert {:error, :server_busy} = Runtime.submit(runtime, message(3, "read"))
    send(two, :release)
    assert {:ok, _} = Runtime.await(second, 1_000)
    send(one, :release)
    assert {:ok, _} = Runtime.await(first, 1_000)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)

    assert {:error, %{"error" => %{"data" => %{"type" => "invalid_handler_state"}}}} =
             Runtime.request(runtime, message(4, "inc"))

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(5, "read"))
  end

  test "concurrency configuration requires explicit stateless opt in" do
    assert {:error, :invalid_execution_configuration} =
             Runtime.start_link(handler: Handler, max_concurrency: 2)

    assert {:error, {:invalid_limit, :max_queue}} =
             Runtime.start_link(handler: Handler, max_queue: -1)
  end

  test "owner death cancels only the owner's work" do
    runtime = start_runtime(label: :disconnect)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, token} = Runtime.submit(runtime, message(1, "hold"), reply_to: parent)
        send(parent, {:submitted, token})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:submitted, token}
    assert_receive {:started, :disconnect, 1, worker, 0}
    Process.exit(owner, :kill)

    assert {:error, %{"error" => %{"data" => %{"type" => "owner_down"}}}} =
             Runtime.await(token, 1_000)

    wait_for(fn -> not Process.alive?(worker) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
  end

  test "execution restart invalidates stale completion and keeps the same runtime reference" do
    runtime = start_runtime(label: :restart)
    assert_receive {:initialized, :restart, old_scheduler}
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :restart, 1, worker, 0}
    old_generation = Runtime.stats(runtime).generation
    worker_monitor = Process.monitor(worker)
    Process.exit(old_scheduler, :kill)
    assert {:error, :runtime_restarted} = Runtime.await(token, 1_000)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert_receive {:initialized, :restart, new_scheduler}, 1_000
    refute new_scheduler == old_scheduler
    assert {:ok, ^runtime} = Runtime.ref(runtime)

    wait_for(fn ->
      case Runtime.stats(runtime) do
        %{generation: generation} -> generation != old_generation
        _ -> false
      end
    end)

    send(new_scheduler, {:deadline, old_generation, token})
    send(new_scheduler, {:submit, old_generation, token, message(99, "inc"), []})
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "duplicate cancellation and late success deliver exactly one terminal outcome" do
    runtime = start_runtime(label: :race, cancel_grace_ms: 200)
    scope = {:connection, self()}
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :race, 1, worker, 0}
    assert :ok = Runtime.cancel(runtime, scope, 1)
    assert :ok = Runtime.cancel(runtime, scope, 1)
    send(worker, :mutate)
    assert {:error, %{"error" => %{"code" => -32001}}} = Runtime.await(token, 1_000)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 30
  end

  test "completed callback wins over later cancellation and direction keys do not alias" do
    runtime = start_runtime(label: :direction)
    scope = {:session, "direction"}
    assert {:ok, inbound} = Runtime.submit(runtime, message(1, "inc"), scope: scope)
    assert {:ok, %{"result" => 1}} = Runtime.await(inbound, 1_000)
    assert :ok = Runtime.cancel(runtime, scope, 1)

    assert {:ok, outbound} =
             Runtime.submit(runtime, message(1, "hold"), scope: scope, direction: :outbound)

    assert_receive {:started, :direction, 1, worker, 1}
    assert :ok = Runtime.cancel(runtime, scope, 1)
    assert Process.alive?(worker)
    send(worker, :release)
    assert {:ok, %{"result" => 1}} = Runtime.await(outbound, 1_000)
  end

  test "stopping runtime cleans up callback tasks, queued work and the owned table" do
    runtime = start_runtime(label: :stop)
    assert {:ok, held} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :stop, 1, worker, 0}
    assert {:ok, queued} = Runtime.submit(runtime, message(2, "inc"))
    worker_monitor = Process.monitor(worker)
    assert :ok = Runtime.stop(runtime)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert {:error, _} = Runtime.await(held, 1_000)
    assert {:error, _} = Runtime.await(queued, 1_000)
    assert :undefined == :ets.info(Ref.table(runtime))
    assert {:error, :runtime_unavailable} = Runtime.ref(runtime)
  end

  test "admission owner restart fails pending callers and preserves runtime reference" do
    runtime = start_runtime(label: :admission_restart)
    assert {:ok, held} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :admission_restart, 1, worker, 0}
    assert {:ok, queued} = Runtime.submit(runtime, message(2, "inc"))
    old_generation = Runtime.stats(runtime).generation
    {:ok, route} = Admission.route(Ref.table(runtime))
    Process.exit(route.admission, :kill)
    assert {:error, :runtime_restarted} = Runtime.await(held, 1_000)
    assert {:error, :runtime_restarted} = Runtime.await(queued, 1_000)

    wait_for(fn ->
      case Runtime.stats(runtime) do
        %{generation: generation} -> generation != old_generation
        _ -> false
      end
    end)

    refute Process.alive?(worker)
    assert {:ok, ^runtime} = Runtime.ref(runtime)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(3, "inc"))
  end

  test "completion cannot commit after deadline even when the result was queued before the timer" do
    runtime = start_runtime(label: :deadline_order, request_timeout_ms: 200)
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"), timeout: 40)
    assert_receive {:started, :deadline_order, 1, worker, 0}
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.scheduler)
    send(worker, :mutate)
    wait_for(fn -> not Process.alive?(worker) end)
    Process.sleep(60)
    :sys.resume(route.scheduler)

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_timeout"}}}} =
             Runtime.await(token, 1_000)

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "owner death prevents a queued completion from committing before its DOWN is handled" do
    runtime = start_runtime(label: :owner_completion)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"), owner: owner)
    assert_receive {:started, :owner_completion, 1, worker, 0}
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.scheduler)
    send(worker, :mutate)
    wait_for(fn -> not Process.alive?(worker) end)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    :sys.resume(route.scheduler)

    assert {:error, %{"error" => %{"data" => %{"type" => "owner_down"}}}} =
             Runtime.await(token, 1_000)

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "batch ID metadata never enters a suspended admission mailbox and abandoned candidates are cleaned" do
    runtime = start_runtime(label: :metadata_handoff, max_queue: 0)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.admission)
    on_exit(fn -> if Process.alive?(route.admission), do: :sys.resume(route.admission) end)
    parent = self()
    ids = for id <- 1..250, do: "#{id}-" <> String.duplicate("x", 128)

    producer =
      spawn(fn ->
        Runtime.submit(runtime, message(1, "inc"), wire_ids: ids, owner: parent, reply_to: parent)
      end)

    on_exit(fn -> if Process.alive?(producer), do: Process.exit(producer, :kill) end)

    wait_for(fn ->
      case :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, producer}) do
        [{_key, token, ^producer}] -> not is_nil(ByteBudget.candidate(Ref.table(runtime), token))
        _ -> false
      end
    end)

    [{_slot, token, ^producer}] =
      :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, producer})

    candidate = ByteBudget.candidate(Ref.table(runtime), token)
    assert candidate.wire_ids == ids
    {:messages, messages} = Process.info(route.admission, :messages)

    assert [{:"$gen_call", _from, {:confirm, token}} = confirmation] =
             Enum.filter(messages, &match?({:"$gen_call", _, {:confirm, _}}, &1))

    assert token == candidate.token
    assert :erlang.external_size(confirmation) < 256
    monitor = Process.monitor(producer)
    Process.exit(producer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :killed}
    :sys.resume(route.admission)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert ByteBudget.candidate(Ref.table(runtime), token) == nil
    assert %{data: 0, outgoing: 0, incoming: 0} = ByteBudget.used(Ref.table(runtime))
    refute_receive {:started, :metadata_handoff, _, _, _}, 20
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
  end

  test "aggregate candidate bytes stay within the lane budget while admission is suspended" do
    runtime = start_runtime(label: :candidate_bytes, max_pending_bytes: 6_000)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.admission)
    on_exit(fn -> if Process.alive?(route.admission), do: :sys.resume(route.admission) end)
    parent = self()
    ids = for id <- 1..12, do: "#{id}-" <> String.duplicate("x", 250)

    producers =
      for id <- 1..20 do
        spawn(fn ->
          result =
            Runtime.submit(runtime, message(id, "inc"),
              wire_ids: ids,
              owner: parent,
              reply_to: parent
            )

          send(parent, {:candidate_result, self(), result})
        end)
      end

    on_exit(fn -> for pid <- producers, Process.alive?(pid), do: Process.exit(pid, :kill) end)

    for _index <- 1..19,
        do: assert_receive({:candidate_result, _pid, {:error, :server_busy}}, 1_000)

    assert %{data: retained} = ByteBudget.used(Ref.table(runtime))
    assert retained > 3_000 and retained <= 6_000

    assert [{_slot, token, producer}] =
             :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, :_})

    assert ByteBudget.candidate(Ref.table(runtime), token).wire_ids == ids
    monitor = Process.monitor(producer)
    Process.exit(producer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :killed}
    :sys.resume(route.admission)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert %{data: 0, outgoing: 0, incoming: 0} = ByteBudget.used(Ref.table(runtime))
    refute_receive {:started, :candidate_bytes, _, _, _}, 20
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(100, "inc"))
  end

  test "producer killed before scheduler handoff releases admission capacity" do
    runtime = start_runtime(label: :producer, max_queue: 0)
    parent = self()

    producer =
      spawn(fn ->
        {:ok, _route, reservation} =
          Admission.reserve(runtime, message(1, "hold"), reply_to: parent)

        send(parent, {:reserved, reservation.token})

        receive do
          :continue -> :ok
        end
      end)

    assert_receive {:reserved, token}
    assert Runtime.stats(runtime).reserved == 1
    Process.exit(producer, :kill)

    assert {:error, %{"error" => %{"data" => %{"type" => "producer_down"}}}} =
             Runtime.await(token, 1_000)

    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert Runtime.stats(runtime).pending_bytes == 0
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
    refute_receive {:started, :producer, 1, _, _}, 20
  end

  test "an earlier edge wake takes ownership before a later publisher-ready cast" do
    runtime = start_runtime(label: :early_checkout)
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    owner = self()

    producer =
      spawn(fn ->
        {:ok, route, reservation} =
          Admission.reserve(runtime, %{"payload" => :reverse_control},
            owner: owner,
            reply_to: owner,
            edge: owner,
            kind: :edge_control,
            via_edge: true
          )

        send(owner, {:control_reserved, reservation.token})

        receive do
          :publish ->
            result = Admission.publish(table, route, reservation, :reverse_control, owner)
            send(owner, {:control_published, result})
        end

        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(producer), do: Process.exit(producer, :kill) end)
    assert_receive {:control_reserved, token}
    :sys.suspend(route.admission)
    on_exit(fn -> if Process.alive?(route.admission), do: :sys.resume(route.admission) end)

    # Queue the checkout as if it came from an earlier coalesced edge wake;
    # publish atomically places the payload before its ready cast is enqueued.
    checkout = Task.async(fn -> Admission.checkout(table, token) end)

    wait_for(fn ->
      {:messages, messages} = Process.info(route.admission, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:checkout, ^token}}, &1))
    end)

    send(producer, :publish)
    assert_receive {:control_published, :ok}
    :sys.resume(route.admission)
    assert {:ok, %{stage: :processing}, :reverse_control} = Task.await(checkout)
    assert %{reserved: 1, confirmed: 1} = Admission.stats(table)

    monitor = Process.monitor(producer)
    send(producer, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    refute_receive {:arbor_mcp_runtime, ^token, _premature_terminal}, 30
    assert {:ok, %{terminal: false}} = Admission.current(table, token)
    assert %{reserved: 1} = Admission.stats(table)

    # Native reverse controls hold their credit without Scheduler.bind/2.
    assert :ok = Admission.terminal(table, token, {:ok, :delivered})
    assert {:ok, :delivered} = Runtime.await(token, 1_000)
    assert :ok = Admission.release(table, token)
    assert %{reserved: 0, pending_bytes: 0} = Admission.stats(table)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(1, "inc"))
  end

  test "cancel before scheduler handoff has the same terminal outcome as a running cancellation" do
    runtime = start_runtime(label: :before_handoff, max_queue: 0)
    scope = {:session, "handoff"}
    {:ok, _route, reservation} = Admission.reserve(runtime, message(1, "inc"), scope: scope)
    assert :ok = Runtime.cancel(runtime, scope, 1)
    assert {:error, %{"error" => %{"code" => -32001}}} = Runtime.await(reservation.token, 1_000)
    assert Runtime.stats(runtime).reserved == 0
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "inc"))
    refute_receive {:started, :before_handoff, 1, _, _}, 20
  end

  test "retained dispatch context is included in the byte admission budget" do
    runtime = start_runtime(label: :context_bytes, max_pending_bytes: 200)

    assert {:error, :server_busy} =
             Runtime.submit(runtime, message(1, "inc"),
               dispatch_opts: [application_data: String.duplicate("x", 500)]
             )

    assert {:error, :server_busy} =
             Runtime.submit(runtime, message(2, "inc"),
               scope: {:session, String.duplicate("s", 500)}
             )

    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
    refute_receive {:started, :context_bytes, 1, _, _}, 20
  end

  test "terminal telemetry fires once without request payloads during cancellation races" do
    runtime = start_runtime(label: :telemetry)
    parent = self()
    handler_id = {:runtime_test, make_ref()}
    event = [:arbor_mcp, :server, :request, :completed]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, _config ->
          if metadata.runtime == Ref.supervisor(runtime),
            do: send(parent, {:terminal_telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :telemetry, 1, worker, 0}
    assert :ok = Runtime.cancel(runtime, {:connection, self()}, 1)
    send(worker, :mutate)
    assert {:error, _} = Runtime.await(token, 1_000)
    assert_receive {:terminal_telemetry, %{count: 1}, %{outcome: "request_cancelled"} = metadata}
    assert Map.keys(metadata) |> Enum.sort() == [:outcome, :runtime]
    refute_receive {:terminal_telemetry, _, _}, 30
  end

  test "malformed normalized response never commits state or escapes to a transport" do
    runtime = start_runtime(label: :malformed)

    assert {:error, %{"error" => %{"data" => %{"type" => "invalid_handler_result"}}}} =
             Runtime.request(runtime, message(1, "malformed_response"))

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
  end

  test "notification completion commits state without generating a JSON RPC response" do
    runtime = start_runtime(label: :notification)
    notification = Map.delete(message(nil, "inc"), "id")
    assert :notification = Runtime.request(runtime, notification)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "read"))
  end

  test "synchronous requester observes abrupt runtime death instead of waiting forever" do
    runtime = start_runtime(label: :abrupt)
    task = Task.async(fn -> Runtime.request(runtime, message(1, "hold")) end)
    assert_receive {:started, :abrupt, 1, worker, 0}
    Process.exit(Ref.supervisor(runtime), :kill)
    assert {:error, :runtime_unavailable} = Task.await(task, 1_000)
    wait_for(fn -> not Process.alive?(worker) end)
    assert {:error, :runtime_unavailable} = Runtime.ref(runtime)
  end

  test "finite synchronous wait discards late replies while server work can still commit" do
    runtime = start_runtime(label: :finite_wait)
    parent = self()

    caller =
      spawn(fn ->
        result = Runtime.request(runtime, message(1, "hold"), await_timeout: 20)
        send(parent, {:wait_returned, self(), result})

        receive do
          :inspect_mailbox ->
            send(parent, {:caller_mailbox, Process.info(self(), :messages)})
        end
      end)

    assert_receive {:started, :finite_wait, 1, worker, 0}
    assert_receive {:wait_returned, ^caller, {:error, :await_timeout}}
    send(worker, :mutate)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    send(caller, :inspect_mailbox)
    assert_receive {:caller_mailbox, {:messages, []}}
    assert {:ok, %{"result" => 900}} = Runtime.request(runtime, message(2, "read"))
  end

  test "asynchronous await timeout permits retry without cancelling accepted work" do
    runtime = start_runtime(label: :retry_wait)
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"))
    assert_receive {:started, :retry_wait, 1, worker, 0}
    assert {:error, :await_timeout} = Runtime.await(token, 1)
    assert %{active: 1, reserved: 1} = Runtime.stats(runtime)
    send(worker, :release)
    assert {:ok, %{"result" => 0}} = Runtime.await(token, 1_000)
    refute_receive {:arbor_mcp_runtime, ^token, _}, 20
  end

  test "dead explicit owners never invoke callbacks or retain admission capacity" do
    runtime = start_runtime(label: :dead_owner)
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert {:error, :owner_down} = Runtime.submit(runtime, message(1, "inc"), owner: owner)
    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
    refute_receive {:started, :dead_owner, 1, _, _}, 20
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
  end

  test "owner death before bind cannot start a callback when scheduler resumes" do
    runtime = start_runtime(label: :owner_before_bind)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.scheduler)

    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    assert {:ok, token} = Runtime.submit(runtime, message(1, "inc"), owner: owner)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    :sys.resume(route.scheduler)

    assert {:error, %{"error" => %{"data" => %{"type" => "owner_down"}}}} =
             Runtime.await(token, 1_000)

    refute_receive {:started, :owner_before_bind, 1, _, _}, 20
    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
  end

  test "reference resolution never sends supervisor protocol messages to an unrelated server" do
    agent = start_supervised!({Agent, fn -> :untouched end})
    assert {:error, :runtime_unavailable} = Runtime.ref(agent)
    assert Process.alive?(agent)
    assert :untouched = Agent.get(agent, & &1)
  end

  test "request cannot suppress its required response or commit the suppressed response state" do
    runtime = start_runtime(label: :suppressed_response)

    assert {:error, %{"error" => %{"data" => %{"type" => "invalid_handler_result"}}}} =
             Runtime.request(runtime, message(1, "suppress_response"))

    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2, "read"))
  end

  test "unrecognized producer options are not retained behind the byte admission budget" do
    runtime = start_runtime(label: :option_bytes, max_pending_bytes: 200)

    assert {:ok, token} =
             Runtime.submit(runtime, message(1, "hold"),
               producer_private_context: String.duplicate("x", 100_000)
             )

    assert_receive {:started, :option_bytes, 1, worker, 0}
    {:ok, route} = Admission.route(Ref.table(runtime))
    state = :sys.get_state(route.scheduler)
    retained = state.work[token].opts
    assert :erlang.external_size(retained) < 1_000
    assert Runtime.stats(runtime).pending_bytes < 200
    send(worker, :release)
    assert {:ok, _} = Runtime.await(token, 1_000)
  end

  test "stop budget covers blocked terminate hooks and registered descendants without killing siblings" do
    sibling = start_runtime(label: :shutdown_sibling)

    runtime =
      start_runtime(
        label: :bounded_stop,
        block_terminate: true,
        shutdown_timeout_ms: 100,
        cancel_grace_ms: 10_000,
        store_children: [{StoreTree, self()}]
      )

    assert_receive {:owned_store, store}
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    assert {:ok, _token} = Runtime.submit(runtime, message(1, "trap_hold"))
    assert_receive {:trapping_worker, :bounded_stop, worker}

    monitors =
      Enum.map([Ref.supervisor(runtime), guard, store, worker], &{&1, Process.monitor(&1)})

    started = System.monotonic_time(:millisecond)
    stop = Task.async(fn -> Runtime.stop(Ref.supervisor(runtime)) end)
    assert_receive {:terminating_handler, :bounded_stop, _scheduler, :shutdown}, 1_000
    assert :ok = Task.await(stop, 1_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 70
    assert elapsed < 450

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      refute Process.alive?(pid)
    end

    assert {:ok, %{"result" => 1}} = Runtime.request(sibling, message(2, "inc"))
    assert :undefined == :ets.info(Ref.table(runtime))
  end

  test "parent child shutdown budget cleans a blocking store tree and its guard" do
    runtime =
      start_runtime(
        label: :parent_stop,
        shutdown_timeout_ms: 100,
        store_children: [{StoreTree, self()}]
      )

    assert_receive {:owned_store, store}
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    monitors = Enum.map([Ref.supervisor(runtime), guard, store], &{&1, Process.monitor(&1)})
    started = System.monotonic_time(:millisecond)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    assert :ok = Supervisor.terminate_child(supervisor, runtime_id(Ref.supervisor(runtime)))
    assert_receive {:terminating_store, ^store}
    assert System.monotonic_time(:millisecond) - started < 450

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      refute Process.alive?(pid)
    end
  end

  test "normal stop invokes handler termination and does not leave a guard behind" do
    runtime = start_runtime(label: :normal_terminate)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    monitor = Process.monitor(guard)
    assert :ok = Runtime.stop(runtime)
    assert_receive {:terminating_handler, :normal_terminate, _scheduler, :shutdown}
    assert_receive {:DOWN, ^monitor, :process, ^guard, :normal}
  end

  test "finite stop remains responsive when admission cannot answer scheduler cleanup" do
    runtime = start_runtime(label: :stuck_admission, shutdown_timeout_ms: 100)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.admission)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    guard_monitor = Process.monitor(guard)
    started = System.monotonic_time(:millisecond)
    assert :ok = Runtime.stop(Ref.supervisor(runtime))
    assert System.monotonic_time(:millisecond) - started < 450
    assert_receive {:DOWN, ^guard_monitor, :process, ^guard, :normal}
    assert :undefined == :ets.info(Ref.table(runtime))
  end

  test "invalid synchronous await timeout does not admit server work" do
    runtime = start_runtime(label: :invalid_wait)

    assert {:error, :invalid_await_timeout} =
             Runtime.request(runtime, message(1, "inc"), await_timeout: -1)

    assert %{reserved: 0, pending_bytes: 0} = Runtime.stats(runtime)
    refute_receive {:started, :invalid_wait, 1, _, _}, 20
  end

  test "stop during blocked initialization cleans the not-yet-ready owned scheduler" do
    parent = self()

    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          Runtime.start_link(
            handler: Handler,
            dispatcher: Handler,
            handler_args: [test_pid: parent, label: :blocked_init, block_init: true],
            init_timeout_ms: 5_000,
            shutdown_timeout_ms: 100
          )

        send(parent, {:startup_returned, result})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:blocking_handler_init, scheduler, root}
    {:ok, runtime} = Runtime.ref(root)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    monitors = Enum.map([root, scheduler, guard], &{&1, Process.monitor(&1)})
    started = System.monotonic_time(:millisecond)
    assert :ok = Runtime.stop(root)
    assert System.monotonic_time(:millisecond) - started < 450

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    end

    assert_receive {:startup_returned, {:error, _}}, 1_000
    send(starter, :finish)
    assert :undefined == :ets.info(Ref.table(runtime))
  end

  test "opaque references reject mismatched tables, foreign owners and remote supervisors" do
    one = start_runtime(label: :ref_one)
    two = start_runtime(label: :ref_two)
    assert Ref.valid?(one)
    refute Ref.valid?(Ref.new(Ref.supervisor(one), Ref.table(two)))

    assert {:error, :runtime_unavailable} =
             Runtime.ref(Ref.new(Ref.supervisor(one), Ref.table(two)))

    agent = start_supervised!({Agent, fn -> :ets.new(:foreign_owner, []) end})
    foreign_table = Agent.get(agent, & &1)
    refute Ref.valid?(Ref.new(agent, foreign_table))
    refute Ref.valid?(Ref.new(remote_pid(), Ref.table(one)))
    assert {:error, :runtime_unavailable} = Runtime.ref(remote_pid())
    assert :ok = Runtime.stop(one)
    refute Ref.valid?(one)
    assert {:ok, %{"result" => 1}} = Runtime.request(two, message(1, "inc"))
    assert Process.alive?(agent)
  end

  test "nonlocal owners and reply targets are rejected without admission or handler side effects" do
    runtime = start_runtime(label: :remote_owners)
    {:ok, route} = Admission.route(Ref.table(runtime))
    generation = Runtime.stats(runtime).generation
    remote = remote_pid()
    assert node(remote) != node()

    assert {:error, :invalid_owner} = Runtime.submit(runtime, message(1, "inc"), owner: remote)
    assert {:error, :invalid_owner} = Runtime.submit(runtime, message(2, "inc"), owner: :invalid)

    assert {:error, :invalid_reply_target} =
             Runtime.submit(runtime, message(3, "inc"), reply_to: remote)

    assert {:error, :invalid_reply_target} =
             Runtime.submit(runtime, message(4, "inc"), reply_to: :invalid)

    assert %{reserved: 0, pending_bytes: 0, generation: ^generation} = Runtime.stats(runtime)
    assert Process.alive?(route.admission)
    refute_receive {:started, :remote_owners, _, _, _}, 20
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(5, "inc"))
  end

  test "an ordinary reference reply target cannot crash admission or roll back committed state" do
    runtime = start_runtime(label: :invalid_delivery, max_queue: 0)
    {:ok, route} = Admission.route(Ref.table(runtime))
    generation = Runtime.stats(runtime).generation

    assert {:ok, token} =
             Runtime.submit(runtime, message(1, "inc"), reply_to: make_ref())

    assert_receive {:started, :invalid_delivery, 1, _worker, 0}
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert %{pending_bytes: 0, generation: ^generation} = Runtime.stats(runtime)
    assert Process.alive?(route.admission)
    assert Process.alive?(route.scheduler)
    assert {:error, :await_timeout} = Runtime.await(token, 0)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2, "read"))
  end

  test "deactivating an asynchronous reply alias discards delivery and releases the work budget" do
    runtime = start_runtime(label: :inactive_delivery, max_queue: 0)
    generation = Runtime.stats(runtime).generation
    reply_alias = :erlang.alias()
    assert {:ok, token} = Runtime.submit(runtime, message(1, "hold"), reply_to: reply_alias)
    assert_receive {:started, :inactive_delivery, 1, worker, 0}
    assert :erlang.unalias(reply_alias)
    send(worker, :mutate)
    wait_for(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert %{pending_bytes: 0, generation: ^generation} = Runtime.stats(runtime)
    assert {:error, :await_timeout} = Runtime.await(token, 0)
    assert {:ok, %{"result" => 900}} = Runtime.request(runtime, message(2, "read"))
  end

  test "admission restart survives outstanding invalid and deactivated alias destinations" do
    runtime = start_runtime(label: :restart_delivery)
    {:ok, route} = Admission.route(Ref.table(runtime))
    old_generation = Runtime.stats(runtime).generation

    assert {:ok, _invalid_token} =
             Runtime.submit(runtime, message(1, "hold"), reply_to: make_ref())

    assert_receive {:started, :restart_delivery, 1, worker, 0}
    reply_alias = :erlang.alias()

    assert {:ok, _inactive_token} =
             Runtime.submit(runtime, message(2, "inc"), reply_to: reply_alias)

    assert :erlang.unalias(reply_alias)
    assert {:ok, legitimate} = Runtime.submit(runtime, message(3, "inc"))
    Process.exit(route.admission, :kill)
    assert {:error, :runtime_restarted} = Runtime.await(legitimate, 1_000)

    wait_for(fn ->
      case Runtime.stats(runtime) do
        %{generation: generation, reserved: 0, pending_bytes: 0} -> generation != old_generation
        _ -> false
      end
    end)

    refute Process.alive?(worker)
    assert {:ok, ^runtime} = Runtime.ref(runtime)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(4, "inc"))
  end

  defp start_runtime(opts) do
    {label, opts} = Keyword.pop(opts, :label, :runtime)
    {block_terminate, opts} = Keyword.pop(opts, :block_terminate, false)

    options =
      Keyword.merge(
        [
          id: make_ref(),
          handler: Handler,
          dispatcher: Handler,
          handler_args: [test_pid: self(), label: label, block_terminate: block_terminate]
        ],
        opts
      )

    pid = start_supervised!({Runtime, options})
    {:ok, runtime} = Runtime.ref(pid)
    runtime
  end

  defp message(id, method), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}
  defp input_bytes(message), do: :erlang.external_size(message) + :erlang.external_size([])

  defp remote_pid do
    name = "arbor_runtime_test_remote@invalid"

    :erlang.binary_to_term(
      <<131, 103, 100, 0, byte_size(name), name::binary, 0, 0, 0, 1, 0, 0, 0, 0, 0>>
    )
  end

  defp runtime_id(pid) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    Supervisor.which_children(supervisor)
    |> Enum.find_value(fn {id, child, _type, _modules} -> if child == pid, do: id end)
  end

  defp wait_for(predicate, remaining \\ 100)
  defp wait_for(_predicate, 0), do: flunk("runtime did not reach the expected state")

  defp wait_for(predicate, remaining) do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      wait_for(predicate, remaining - 1)
    end
  end
end
