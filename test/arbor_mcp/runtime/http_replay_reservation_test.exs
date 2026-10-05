defmodule Arbor.MCP.Server.Runtime.HTTPReplayReservationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.{EventTicket, RuntimeEvents, RuntimeStore, SessionLease}

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    HTTPGateway,
    HTTPOutput,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    OutputTicket,
    Ref,
    ServiceOperation,
    Services,
    ServiceStore
  }

  defmodule Handler do
    def init(opts), do: {:ok, %{test: opts[:test], count: 0, stateless: opts[:stateless]}}

    def dispatch(request, _module, state, _opts) do
      send(state.test, {:replay_callback, request["id"], self()})
      if request["method"] == "hold", do: receive(do: (:finish -> :ok))
      if request["method"] == "crash", do: raise("fixed test failure")

      next =
        if state.stateless or request["method"] == "state",
          do: state,
          else: %{state | count: state.count + 1}

      result =
        if request["method"] == "initialize",
          do: %{"protocolVersion" => "2025-11-25"},
          else: state.count

      if Map.has_key?(request, "id"),
        do: {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}, next},
        else: {:notification, next}
    end
  end

  defmodule HeldHandoffStore do
    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)
    defdelegate runtime_service_capabilities(), to: RuntimeStore
    defdelegate runtime_service_binding(server, timeout), to: RuntimeStore
    defdelegate operate(operation, args, context, opts), to: RuntimeStore
    defdelegate lease_active?(id, epoch, opts), to: RuntimeStore
    defdelegate read_address(model), to: RuntimeStore
    defdelegate close(model), to: RuntimeStore
    defdelegate expire(model, deadline), to: RuntimeStore
    defdelegate info(message, model), to: RuntimeStore

    def open(opts) do
      with {:ok, model} <- RuntimeStore.open(opts),
           do:
             {:ok,
              Map.merge(model, %{
                test_parent: opts[:test_parent],
                tamper_initialization: opts[:tamper_initialization],
                interleave: opts[:interleave] == true
              })}
    end

    def apply(:prepare_event, [namespace, key, source, wire, group], context, model) do
      source =
        if model.tamper_initialization,
          do: %{source | initialization: not source.initialization},
          else: source

      if model.interleave and Jason.decode!(wire)["id"] == 1 do
        send(model.test_parent, {:held_replay_prepare, self(), context.owner})
        receive do: (:resume -> :ok)
      end

      result =
        RuntimeStore.apply(:prepare_event, [namespace, key, source, wire, group], context, model)

      if model.interleave,
        do: send(model.test_parent, {:replay_preparation_complete, self(), context.owner})

      result
    end

    def apply(:handoff_event, args, context, model) do
      [_namespace, ticket] = args

      if model.interleave do
        result = RuntimeStore.apply(:handoff_event, args, context, model)

        {_reply, next} = result

        {_key, entry} =
          Enum.find(next.pending_events, fn {_key, entry} ->
            EventTicket.matches?(ticket, entry)
          end)

        if Jason.decode!(elem(hd(entry.members), 1))["id"] == 2 do
          send(model.test_parent, {:held_replay_handoff, self(), context.owner, ticket})
          receive do: (:resume -> :ok)
        end

        result
      else
        send(model.test_parent, {:held_replay_handoff, self(), context.owner, ticket})
        receive do: (:resume -> RuntimeStore.apply(:handoff_event, args, context, model))
      end
    end

    def apply(operation, args, context, model),
      do: RuntimeStore.apply(operation, args, context, model)
  end

  test "prepared replay is invisible, handed off before worker exit, and published once by its socket" do
    {runtime, service, lease, binding} = setup_runtime()
    {:ok, _token} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {effect, wire, primary} = prepared(binding)
    assert Jason.decode!(wire)["result"] == 0
    assert {:ok, %{events: [], more?: false}} = replay(service, lease)
    assert {:ok, %{pending_events: 1, events: 0}} = SessionManager.get_stats(service, [])
    assert_receive {:replay_callback, 1, worker}
    wait(fn -> not Process.alive?(worker) end)
    assert EventTicket.receipt(OutputTicket.session(primary)) == 0

    {:ok, route} =
      Admission.route(Ref.table(runtime))

    assert :sys.get_state(route.scheduler).handler_state.count == 1
    assert :ok = RuntimeEvents.publish(primary)
    assert {:error, :session_event_already_published} = RuntimeEvents.publish(primary)
    assert {:ok, %{events: [%{data: %{"id" => 1, "result" => 0}}]}} = replay(service, lease)
    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
    complete(binding, effect, wire)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(99, "state"))
  end

  test "complete legacy array has one durable event and preserves invalid member order and omission" do
    {runtime, service, lease, binding} = setup_runtime()
    notice = Map.delete(message(1), "id")

    {:ok, _token} =
      HTTPGateway.submit(runtime, binding, [message(1), notice, 17, message(2)],
        format: :legacy_sse
      )

    {effect, wire, primary} = prepared(binding)
    decoded = Jason.decode!(wire)

    assert [
             %{"id" => 1, "result" => 0},
             %{"id" => nil, "error" => _},
             %{"id" => 2, "result" => 2}
           ] = decoded

    assert {:ok, %{events: []}} = replay(service, lease)
    assert :ok = RuntimeEvents.publish(primary)
    assert {:ok, %{events: [%{data: ^decoded}]}} = replay(service, lease)
    complete(binding, effect, wire)
    assert {:ok, %{"result" => 3}} = Runtime.request(runtime, message(99, "state"))
  end

  test "replay saturation rejects callback proposal before its state commit" do
    {runtime, service, lease, binding} = setup_runtime(max_events: 1)
    {:ok, _} = SessionManager.append_event(service, lease, "message", %{"occupied" => true}, [])
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {effect, wire} = ready(binding)
    assert %{"error" => %{"code" => -32603}} = Jason.decode!(wire)
    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
    complete(binding, effect, wire)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(99, "state"))
  end

  test "direct rolling append cannot steal a pending replay permit" do
    {runtime, service, lease, binding} = setup_runtime(max_events: 1, max_events_per_session: 1)
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {effect, wire, primary} = prepared(binding)

    assert {:error, :replay_capacity_exhausted} =
             SessionManager.append_event(service, lease, "message", %{}, [])

    assert :ok = RuntimeEvents.publish(primary)
    complete(binding, effect, wire)
    assert {:ok, _} = SessionManager.append_event(service, lease, "message", %{"new" => true}, [])
    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
  end

  test "a failed later batch never publishes an earlier committed member" do
    {runtime, service, lease, binding} = setup_runtime()

    {:ok, _} =
      HTTPGateway.submit(runtime, binding, [message(1), message(2, "crash")], format: :legacy_sse)

    {effect, wire} = ready(binding)
    assert %{"error" => _} = Jason.decode!(wire)
    assert {:ok, %{events: []}} = replay(service, lease)
    complete(binding, effect, wire)
    wait(fn -> match?({:ok, %{pending_events: 0}}, SessionManager.get_stats(service, [])) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(99, "state"))
  end

  test "producer death during handoff reaps invisible capacity and cannot commit state" do
    {runtime, service, lease, binding} =
      setup_runtime(adapter: HeldHandoffStore, test_parent: self())

    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    assert_receive {:held_replay_handoff, actor, worker, _ticket}
    Process.exit(worker, :kill)
    send(actor, :resume)
    wait(fn -> match?({:ok, %{pending_events: 0}}, SessionManager.get_stats(service, [])) end)
    assert {:ok, %{events: []}} = replay(service, lease)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(99, "state"))
  end

  test "a different writer cannot publish a genuine prepared companion" do
    {runtime, service, lease, binding} = setup_runtime()
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {effect, wire, primary} = prepared(binding)
    result = Task.async(fn -> RuntimeEvents.publish(primary) end) |> Task.await()
    assert {:error, :session_event_retired} = result
    assert {:ok, %{events: []}} = replay(service, lease)
    assert :ok = RuntimeEvents.publish(primary)
    complete(binding, effect, wire)
  end

  test "expired original source releases pending capacity without replay or refreshed authority" do
    {runtime, service, lease, binding} = setup_runtime(capture_timeout: 80)
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {_effect, _wire, primary} = prepared(binding)
    Process.sleep(90)
    assert {:error, _} = RuntimeEvents.publish(primary)
    wait(fn -> match?({:ok, %{pending_events: 0}}, SessionManager.get_stats(service, [])) end)
    assert {:ok, %{events: []}} = replay(service, lease)
    assert :ok = HTTPWriterRegistry.retire(binding)
  end

  test "prospective complete-array byte pressure rejects the second state proposal" do
    {runtime, service, lease, binding} = setup_runtime(max_event_bytes: 100)
    {:ok, _} = HTTPGateway.submit(runtime, binding, [message(1), message(2)], format: :legacy_sse)
    {effect, wire} = ready(binding)
    assert %{"id" => 2, "error" => _} = Jason.decode!(wire)
    assert {:ok, %{events: []}} = replay(service, lease)
    complete(binding, effect, wire)
    wait(fn -> match?({:ok, %{pending_events: 0}}, SessionManager.get_stats(service, [])) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(99, "state"))
  end

  test "caller-authored source metadata cannot obtain a worker replay permit" do
    {runtime, service, lease, binding} = setup_runtime()
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {effect, wire, primary} = prepared(binding)
    {:ok, store} = Services.resolve(service, :sessions)
    [{_key, entry}] = Map.to_list(:sys.get_state(store.server).model.pending_events)
    {:ok, key} = SessionLease.validate(lease, service, :sessions)
    forged = %{entry.source | producer: self()}

    assert {:error, :invalid_session_event_origin} =
             ServiceOperation.call(
               service,
               :sessions,
               :prepare_event,
               [key, forged, wire, false],
               deadline: forged.deadline
             )

    assert {:ok, %{pending_events: 1}} = SessionManager.get_stats(service, [])
    assert :ok = RuntimeEvents.publish(primary)
    complete(binding, effect, wire)
  end

  test "durability uncertainty survives actor loss and cannot be released as confirmed" do
    {runtime, service, _lease, binding} = setup_runtime()
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {_effect, _wire, primary} = prepared(binding)
    {:ok, store} = Services.resolve(service, :sessions)
    # Destroy only the event destination inside its real owner. The session
    # row/final guards still succeed; the actual insert fails after entering
    # the publication receipt, which must survive the native actor failure.
    :sys.replace_state(store.server, fn state ->
      :ets.delete(state.model.store.events)
      state
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :session_event_durability_unconfirmed} = RuntimeEvents.publish(primary)
    end)

    wait(fn -> not Process.alive?(store.server) end)
    assert {:error, :session_event_durability_unconfirmed} = RuntimeEvents.release(primary)
    assert {:error, :session_event_durability_unconfirmed} = HTTPOutput.release(primary)
    assert EventTicket.receipt(OutputTicket.session(primary)) == 3
  end

  test "stale batch member release cannot delete a newer aggregate reservation" do
    {runtime, service, lease, binding} =
      setup_runtime(adapter: HeldHandoffStore, test_parent: self())

    {:ok, _} = HTTPGateway.submit(runtime, binding, [message(1), message(2)], format: :legacy_sse)
    assert_receive {:held_replay_handoff, actor, _first, first_ticket}
    send(actor, :resume)
    assert_receive {:held_replay_handoff, ^actor, _second, second_ticket}
    assert EventTicket.receipt(first_ticket) == 2
    assert EventTicket.receipt(second_ticket) == 0
    send(actor, :resume)
    {effect, wire, final} = prepared(binding)

    assert :ok =
             ServiceOperation.call(
               service,
               :sessions,
               :release_event,
               [first_ticket],
               deadline: EventTicket.deadline(first_ticket)
             )

    assert :ok =
             ServiceOperation.call(
               service,
               :sessions,
               :release_event,
               [second_ticket],
               deadline: EventTicket.deadline(second_ticket)
             )

    assert {:ok, %{pending_events: 1, events: 0}} = SessionManager.get_stats(service, [])
    assert :ok = RuntimeEvents.publish(final)
    assert {:ok, %{events: [%{data: [%{"id" => 1}, %{"id" => 2}]}]}} = replay(service, lease)
    complete(binding, effect, wire)
  end

  test "retired session epoch cannot publish or delete a reused ID's event" do
    {runtime, service, lease, binding} = setup_runtime()
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {_effect, _wire, primary} = prepared(binding)
    assert :ok = SessionManager.terminate_session(service, lease, [])
    id = SessionLease.id(lease)

    {:ok, fresh} =
      SessionManager.create_session(service, %{transport_endpoint: "/mcp"}, session_id: id)

    assert {:ok, _event} =
             SessionManager.append_event(service, fresh, "message", %{"fresh" => true}, [])

    assert {:error, :session_event_retired} = RuntimeEvents.publish(primary)
    assert :ok = RuntimeEvents.release(primary)
    assert {:ok, %{events: [%{data: %{"fresh" => true}}]}} = replay(service, fresh)
    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
  end

  test "successful initialization cannot publish before its exact addressed claim settles" do
    {runtime, service, lease, binding} = setup_runtime()
    {:ok, claim} = SessionManager.claim_initialization(service, lease, invocation: binding)
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1, "initialize"), format: :legacy_sse)
    {effect, wire, primary} = prepared(binding)
    assert {:error, :session_initialization_unsettled} = RuntimeEvents.publish(primary)
    assert {:ok, %{events: []}} = replay(service, lease)
    assert :ok = SessionManager.complete_initialization(service, claim, "2025-11-25", [])
    assert :ok = RuntimeEvents.publish(primary)

    assert {:ok, %{events: [%{data: %{"result" => %{"protocolVersion" => "2025-11-25"}}}]}} =
             replay(service, lease)

    complete(binding, effect, wire)
  end

  test "replay service rejects tampered initialization metadata before handler state commit" do
    {runtime, service, lease, binding} =
      setup_runtime(adapter: HeldHandoffStore, tamper_initialization: true)

    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1, "initialize"), format: :legacy_sse)
    {effect, wire} = ready(binding)
    assert %{"error" => %{"code" => -32603}} = Jason.decode!(wire)
    assert {:ok, %{events: []}} = replay(service, lease)
    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(service, [])
    complete(binding, effect, wire)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(99, "state"))
  end

  test "two workers can prepare while Scheduler is held behind a completed proposal" do
    {runtime, service, lease, second} =
      setup_runtime(
        adapter: HeldHandoffStore,
        test_parent: self(),
        interleave: true,
        stateless: true
      )

    {:ok, _} = HTTPGateway.submit(runtime, second, message(2, "hold"), format: :legacy_sse)
    assert_receive {:replay_callback, 2, worker}
    send(worker, :finish)
    assert_receive {:held_replay_handoff, actor, ^worker, _ticket}
    :erlang.suspend_process(worker)
    send(actor, :resume)
    {:ok, route} = Admission.route(Ref.table(runtime))
    [{:output_producers, proofs}] = :ets.lookup(Ref.table(runtime), :output_producers)
    assert :ets.info(proofs, :owner) == route.scheduler
    assert :ets.info(proofs, :protection) == :protected
    assert_raise ArgumentError, fn -> :ets.insert(proofs, {:forged, %{}}) end

    first_socket =
      Task.async(fn ->
        {:ok, first} = HTTPWriterProxy.capture(runtime, timeout: 2_000)
        :ok = HTTPWriterRegistry.bind_lease(first, lease)
        {:ok, _} = HTTPGateway.submit(runtime, first, message(1), format: :legacy_sse)
        receive do: (:publish -> :ok)
        {effect, wire, primary} = prepared(first)
        assert :ok = RuntimeEvents.publish(primary)
        complete(first, effect, wire)
      end)

    on_exit(fn ->
      if Process.alive?(first_socket.pid), do: Process.exit(first_socket.pid, :kill)
    end)

    assert_receive {:held_replay_prepare, ^actor, first_worker}
    :sys.suspend(route.scheduler)

    try do
      :erlang.resume_process(worker)
      wait(fn -> not Process.alive?(worker) end)
      send(actor, :resume)
      # The store must authenticate A without waiting on Scheduler, which has
      # B's completed proposal queued and would synchronously ask this store.
      assert_receive {:replay_preparation_complete, ^actor, ^first_worker}
      assert {:ok, %{pending_events: 2, events: 0}} = SessionManager.get_stats(service, [])
    after
      if Process.alive?(worker), do: :erlang.resume_process(worker)
      :sys.resume(route.scheduler)
      send(actor, :resume)
    end

    {effect2, wire2, primary2} = prepared(second)
    wait(fn -> :ets.info(proofs, :size) == 0 end)
    assert :ok = RuntimeEvents.publish(primary2)
    complete(second, effect2, wire2)
    send(first_socket.pid, :publish)
    Task.await(first_socket, 1_000)

    assert {:ok, %{events: [%{data: %{"id" => 2}}, %{data: %{"id" => 1}}]}} =
             replay(service, lease)
  end

  test "Controller death reaps held replay credits and retires the old cohort proof" do
    {runtime, service, lease, binding} = setup_runtime(max_events: 1)
    {:ok, _} = HTTPGateway.submit(runtime, binding, message(1), format: :legacy_sse)
    {_effect, _wire, primary} = prepared(binding)
    table = Ref.table(runtime)
    {:ok, old_route} = Admission.route(table)
    [{:output_producers, old_proofs}] = :ets.lookup(table, :output_producers)
    [{:output_controller, controller}] = :ets.lookup(table, :output_controller)
    ExUnit.CaptureLog.capture_log(fn -> Process.exit(controller, :kill) end)
    wait(fn -> match?({:ok, %{pending_events: 0}}, SessionManager.get_stats(service, [])) end)

    wait(fn ->
      case Admission.route(table) do
        {:ok, route} -> route.generation != old_route.generation
        _replacing -> false
      end
    end)

    assert :ets.info(old_proofs, :owner) == :undefined
    assert {:error, _retired} = RuntimeEvents.publish(primary)

    assert {:ok, _} =
             SessionManager.append_event(service, lease, "message", %{"fresh" => true}, [])

    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(99, "state"))
  end

  defp setup_runtime(options \\ []) do
    adapter = Keyword.get(options, :adapter, RuntimeStore)
    capture_timeout = Keyword.get(options, :capture_timeout, 2_000)
    stateless = Keyword.get(options, :stateless, false)
    options = Keyword.drop(options, [:adapter, :capture_timeout, :stateless])

    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self(), stateless: stateless],
         execution: if(stateless, do: :stateless, else: :stateful),
         max_concurrency: if(stateless, do: 2, else: 1),
         request_timeout_ms: 2_000,
         services: [sessions: [adapter: adapter, options: options]]}
      )

    {:ok, runtime} = Runtime.ref(root)
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(service, %{transport_endpoint: "/mcp"}, [])
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: capture_timeout)
    :ok = HTTPWriterRegistry.bind_lease(binding, lease)
    {runtime, service, lease, binding}
  end

  defp replay(service, lease), do: SessionManager.replay_page(service, lease, nil, [])
  defp message(id, method \\ "read"), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  defp prepared(binding) do
    {effect, wire} = ready(binding)
    {:ok, primary} = HTTPWriterRegistry.response_primary(effect)
    {effect, wire, primary}
  end

  defp ready(binding) do
    wait(fn ->
      case HTTPWriterRegistry.peek(binding) do
        {:ok, effect, wire} -> {effect, wire}
        :empty -> nil
        {:error, :http_invocation_closed} -> nil
        error -> flunk("unexpected replay output: #{inspect(error)}")
      end
    end)
  end

  defp complete(binding, effect, wire) do
    assert {:ok, actual, ^wire} = HTTPWriterRegistry.checkout(binding)
    assert HTTPWriterRegistry.kind(effect) != :closed
    assert :ok = HTTPWriterRegistry.complete(actual, :ok)
  end

  defp wait(fun, remaining \\ 300)
  defp wait(_fun, 0), do: flunk("replay state did not settle")

  defp wait(fun, remaining) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        Process.sleep(5)
        wait(fun, remaining - 1)
    end
  end
end
