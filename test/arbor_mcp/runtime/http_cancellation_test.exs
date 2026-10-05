defmodule Arbor.MCP.Server.Runtime.HTTPCancellationTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    HTTPCancellation,
    HTTPGateway,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    OutputController,
    Ref,
    Scheduler,
    ServiceOperation,
    Services
  }

  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease

  defmodule Handler do
    def init(opts), do: {:ok, %{test: opts[:test], count: 0}}

    def dispatch(request, _module, state, _opts) do
      send(state.test, {:cancel_callback, request["id"], self()})
      if request["method"] in ["hold", "initialize"], do: receive(do: (:finish -> :ok))
      result = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state.count}
      {:response, result, %{state | count: state.count + 1}}
    end
  end

  defmodule EpochStore do
    alias Arbor.MCP.Server.Runtime.{ServiceOperation, ServiceStore}
    alias Arbor.MCP.SessionManager.RuntimeStore
    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)
    defdelegate runtime_service_capabilities(), to: RuntimeStore
    defdelegate runtime_service_binding(server, timeout), to: RuntimeStore
    defdelegate operate(operation, args, context, opts), to: RuntimeStore
    defdelegate lease_active?(id, epoch, opts), to: RuntimeStore
    defdelegate read_address(model), to: RuntimeStore
    defdelegate open(opts), to: RuntimeStore
    defdelegate close(model), to: RuntimeStore
    defdelegate expire(model, deadline), to: RuntimeStore
    defdelegate info(message, model), to: RuntimeStore

    def apply(:fixture_epoch, [namespace, id, epoch], context, model) do
      :ok = ServiceOperation.validate_context(context)
      key = {namespace, id}
      [{^key, session}] = :ets.lookup(model.store.sessions, key)
      :ets.insert(model.store.sessions, {key, %{session | epoch: epoch}})
      {:ok, model}
    end

    def apply(operation, args, context, model),
      do: RuntimeStore.apply(operation, args, context, model)
  end

  test "same request ID in another session and a different ID type cannot cancel a callback" do
    runtime = runtime()
    lease_a = lease(runtime)
    lease_b = lease(runtime)
    target = binding(runtime, lease_a)
    {:ok, _} = submit(runtime, target, request(7))
    assert_receive {:cancel_callback, 7, worker}

    cancel(runtime, lease_b, 7)
    cancel(runtime, lease_a, "7")
    assert Process.alive?(worker)
    assert :empty = call(target, fn -> HTTPWriterRegistry.checkout(target) end)

    cancel(runtime, lease_a, 7)
    wait(fn -> not Process.alive?(worker) end)
    {effect, wire} = checkout(target)
    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    {:ok, route} = Admission.route(Ref.table(runtime))
    assert :sys.get_state(route.admission).monitors == %{}
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "a Scheduler-queued current target is cancelled before its callback" do
    runtime = runtime()
    lease = lease(runtime)
    running = binding(runtime, lease)
    {:ok, _} = submit(runtime, running, request(1))
    assert_receive {:cancel_callback, 1, worker}
    queued = binding(runtime, lease)
    {:ok, _} = submit(runtime, queued, request(7))
    {:ok, route} = Admission.route(Ref.table(runtime))

    wait(fn ->
      Enum.any?(:sys.get_state(route.scheduler).work, fn {_token, work} ->
        work.request["id"] == 7
      end)
    end)

    refute_receive {:cancel_callback, 7, _}, 5
    cancel(runtime, lease, 7)
    {effect, wire} = checkout(queued)
    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(queued, effect)
    refute_receive {:cancel_callback, 7, _}, 5
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, _wire} = checkout(running)
    :ok = complete(running, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "duplicate future-ID markers coalesce and fail the aggregate without replaying earlier state" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, worker}
    table = Ref.table(runtime)
    cancel(runtime, lease, "7")
    refute :ets.member(table, {:http_wire_cancel, token, 7})
    cancel(runtime, lease, 7)
    assert [{_, %{deadline: first_deadline}}] = :ets.lookup(table, {:http_wire_cancel, token, 7})
    for _repeat <- 1..2, do: cancel(runtime, lease, 7)

    assert [{{:http_wire_cancel, ^token, 7}, %{deadline: marker_deadline}}] =
             :ets.match_object(table, {{:http_wire_cancel, token, :_}, :_})

    assert marker_deadline == first_deadline
    [{key, receipt}] = :ets.lookup(table, {:http_wire_cancel, token, 7})
    {:ok, reservation} = Admission.current(table, token)

    assert HTTPCancellation.marker_metadata_bytes(runtime, reservation.scope, lease, nil, [7]) >=
             :erlang.external_size({key, receipt})

    assert marker_deadline > System.monotonic_time(:millisecond)

    assert Runtime.stats(runtime).reserved == 2
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, wire} = checkout(target)

    assert [{{:output_failure, ^token}, %{reason: :request_cancelled}}] =
             :ets.lookup(table, {:output_failure, token})

    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(target, effect)
    refute_receive {:cancel_callback, 7, _}, 5
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    output_settled(runtime)
    refute :ets.member(table, {:http_wire_cancel, token, 7})
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "a cancellation member can suppress its own admitted envelope's future ID" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, _token} = submit(runtime, target, [cancellation(7), request(7)])
    {effect, wire} = checkout(target)
    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(target, effect)
    refute_receive {:cancel_callback, 7, _}, 5
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    output_settled(runtime)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "a queued control marks a future ID during completed-phase to holding handoff" do
    assert_cancel_handoff(:holding)
  end

  test "a queued control suppresses a promoted member before Scheduler binding" do
    assert_cancel_handoff(:promoted)
  end

  test "a failed member phase cannot authorize a future marker while its IO is held" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, worker}
    cancel(runtime, lease, 1)
    wait(fn -> not Process.alive?(worker) end)
    {effect, wire} = checkout(target)
    assert Jason.decode!(wire)["error"]["message"] == "Request cancelled"
    table = Ref.table(runtime)
    assert [{_, %{phase: phase}}] = :ets.lookup(table, {:http_session_origin, token})
    assert :atomics.get(phase, 1) == 3
    cancel(runtime, lease, 7)
    refute :ets.member(table, {:http_wire_cancel, token, 7})
    :ok = complete(target, effect)
    refute_receive {:cancel_callback, 7, _}, 5
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    output_settled(runtime)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "an accepted future marker expires at the control's original cutoff" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    table = Ref.table(runtime)
    source = binding(runtime, lease, timeout: 200)
    {:ok, source_token} = submit(runtime, source, cancellation(7))
    {acceptance, ""} = checkout(source)
    :ok = complete(source, acceptance)
    wait(fn -> match?({:error, _}, Admission.current(table, source_token)) end)
    assert [{_, %{deadline: deadline}}] = :ets.lookup(table, {:http_wire_cancel, token, 7})
    Process.sleep(max(0, deadline + 5 - System.monotonic_time(:millisecond)))
    send(first_worker, :finish)
    assert_receive {:cancel_callback, 7, second_worker}
    send(second_worker, :finish)
    {effect, wire} = checkout(target)
    assert [%{"id" => 1, "result" => 0}, %{"id" => 7, "result" => 1}] = Jason.decode!(wire)
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    refute :ets.member(table, {:http_wire_cancel, token, 7})
  end

  test "future string IDs remain distinct and initialize IDs stay protected" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request("first"), request("7")])
    assert_receive {:cancel_callback, "first", first_worker}
    cancel(runtime, lease, 7)
    refute :ets.member(Ref.table(runtime), {:http_wire_cancel, token, "7"})
    cancel(runtime, lease, "7")
    send(first_worker, :finish)
    {effect, wire} = checkout(target)
    assert %{"id" => "7", "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(target, effect)
    refute_receive {:cancel_callback, "7", _}, 5
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)

    protected = binding(runtime, lease)

    {:ok, token} =
      submit(runtime, protected, [request(2), %{request(3) | "method" => "initialize"}])

    assert_receive {:cancel_callback, 2, first_worker}
    cancel(runtime, lease, 3)
    refute :ets.member(Ref.table(runtime), {:http_wire_cancel, token, 3})
    send(first_worker, :finish)
    assert_receive {:cancel_callback, 3, initialize_worker}
    send(initialize_worker, :finish)
    {effect, wire} = checkout(protected)
    assert [%{"id" => 2, "result" => 1}, %{"id" => 3, "result" => 2}] = Jason.decode!(wire)
    :ok = complete(protected, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "a stored marker cannot survive same-ID session epoch replacement" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    cancel(runtime, lease, 7)
    table = Ref.table(runtime)
    assert HTTPCancellation.cancelled_member?(table, token, 7)
    {:ok, service} = Runtime.service(runtime, :sessions)

    :ok =
      ServiceOperation.call(
        service,
        :sessions,
        :fixture_epoch,
        [SessionLease.id(lease), "marker-replacement-epoch"],
        []
      )

    refute HTTPCancellation.cancelled_member?(table, token, 7)
    refute :ets.member(table, {:http_wire_cancel, token, 7})
    send(first_worker, :finish)
    wait(fn -> not Process.alive?(first_worker) end)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    refute_receive {:cancel_callback, 7, _}, 5
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "a stored marker cannot affect a replacement runtime cohort's same wire ID" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    cancel(runtime, lease, 7)
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    assert HTTPCancellation.cancelled_member?(table, token, 7)
    Process.exit(route.scheduler, :kill)

    wait(fn ->
      case Admission.route(table) do
        {:ok, current} -> current.generation != route.generation
        _restarting -> false
      end
    end)

    refute HTTPCancellation.cancelled_member?(table, token, 7)
    wait(fn -> not Process.alive?(first_worker) end)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    fresh = binding(runtime, lease(runtime))
    {:ok, _fresh_token} = submit(runtime, fresh, request(7))
    assert_receive {:cancel_callback, 7, fresh_worker}
    send(fresh_worker, :finish)
    {effect, wire} = checkout(fresh)
    assert %{"id" => 7, "result" => 0} = Jason.decode!(wire)
    :ok = complete(fresh, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "uncertain expired marker admission holds its source permit until the real acknowledgement" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    :sys.suspend(route.scheduler)
    source = binding(runtime, lease, timeout: 200)
    {:ok, source_token} = submit(runtime, source, cancellation(7))
    {acceptance, ""} = checkout(source)
    :ok = complete(source, acceptance)
    {:ok, gateway} = HTTPGateway.address(runtime)
    wait(fn -> :sys.get_state(gateway).jobs[source_token].cancelling? end)
    :sys.suspend(route.admission)
    :sys.resume(route.scheduler)

    try do
      wait(fn ->
        {:messages, pending} = Process.info(route.admission, :messages)

        Enum.any?(
          pending,
          &match?({:"$gen_call", _, {:http_future_cancel, ^source_token, _, _}}, &1)
        )
      end)

      {:ok, source_reservation} = Admission.current(table, source_token)

      Process.sleep(
        max(0, source_reservation.deadline + 10 - System.monotonic_time(:millisecond))
      )

      assert Enum.count(:ets.match_object(table, {{:slot, :_}, :_, :_})) == 3
      assert {:messages, messages} = Process.info(route.admission, :messages)

      assert Enum.count(
               messages,
               &match?({:"$gen_call", _, {:http_future_cancel, ^source_token, _, _}}, &1)
             ) == 1

      assert :sys.get_state(gateway).jobs[source_token].cancelling?
      refute :ets.member(table, {:http_wire_cancel, token, 7})
    after
      :sys.resume(route.admission)
    end

    wait(fn -> Runtime.stats(runtime).reserved == 2 end)
    refute :ets.member(table, {:http_wire_cancel, token, 7})
    send(first_worker, :finish)
    assert_receive {:cancel_callback, 7, second_worker}
    send(second_worker, :finish)
    {effect, wire} = checkout(target)
    assert [%{"id" => 1, "result" => 0}, %{"id" => 7, "result" => 1}] = Jason.decode!(wire)
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "Scheduler death retires an uncertain old-generation control without reusing live credit" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, _token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    :sys.suspend(route.scheduler)
    source = binding(runtime, lease)
    {:ok, source_token} = submit(runtime, source, cancellation(7))
    {acceptance, ""} = checkout(source)
    :ok = complete(source, acceptance)
    {:ok, gateway} = HTTPGateway.address(runtime)
    wait(fn -> :sys.get_state(gateway).jobs[source_token].cancelling? end)
    :sys.suspend(route.admission)
    :sys.resume(route.scheduler)

    try do
      wait(fn ->
        {:messages, messages} = Process.info(route.admission, :messages)

        Enum.any?(
          messages,
          &match?({:"$gen_call", _, {:http_future_cancel, ^source_token, _, _}}, &1)
        )
      end)

      assert Enum.count(:ets.match_object(table, {{:slot, :_}, :_, :_})) == 3
      Process.exit(route.scheduler, :kill)
    after
      :sys.resume(route.admission)
    end

    wait(fn ->
      case Admission.route(table) do
        {:ok, current} -> current.generation != route.generation
        _restarting -> false
      end
    end)

    wait(fn -> not Process.alive?(first_worker) end)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    wait(fn -> :sys.get_state(gateway).jobs == %{} end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "expired queued cancellation retains its permit until ACK and cannot cancel late" do
    runtime = runtime(max_queue: 1)
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, _} = submit(runtime, target, request(7))
    assert_receive {:cancel_callback, 7, worker}
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.scheduler)

    try do
      source = binding(runtime, lease, timeout: 30)
      {:ok, token} = submit(runtime, source, cancellation(7))
      {effect, ""} = checkout(source)
      :ok = complete(source, effect)

      wait(fn ->
        match?({:ok, %{terminal: true}}, Admission.current(Ref.table(runtime), token))
      end)

      assert %{reserved: 2} = Admission.stats(Ref.table(runtime))
      excess = binding(runtime, lease)
      assert {:error, :server_busy} = submit(runtime, excess, cancellation(7))
      assert {:messages, messages} = Process.info(route.scheduler, :messages)
      assert Enum.count(messages, &match?({:http_cancel, _, _, _}, &1)) == 1
    after
      :sys.resume(route.scheduler)
    end

    wait(fn -> Runtime.stats(runtime).reserved == 1 end)
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, wire} = checkout(target)
    assert Jason.decode!(wire)["result"] == 0
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "initialize remains protected from a current same-session cancellation" do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, _} = submit(runtime, target, %{request(1) | "method" => "initialize"})
    assert_receive {:cancel_callback, 1, worker}
    cancel(runtime, lease, 1)
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, _wire} = checkout(target)
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "modern sessionless controls require the same trusted principal tenant and endpoint" do
    runtime = runtime()
    target = binding(runtime, nil)
    identity = [endpoint: "/mcp", principal_id: "alice", tenant_id: "team"]
    {:ok, _} = submit(runtime, target, modern(request(7)), dispatch_opts: identity)
    assert_receive {:cancel_callback, 7, worker}

    for other <- [
          [endpoint: "/mcp", principal_id: "bob", tenant_id: "team"],
          [endpoint: "/mcp", principal_id: "alice", tenant_id: "another"],
          [endpoint: "/another", principal_id: "alice", tenant_id: "team"],
          []
        ] do
      cancel(runtime, nil, 7, dispatch_opts: other, modern: true)
      assert Process.alive?(worker)
    end

    cancel(runtime, nil, 7, dispatch_opts: identity, modern: true)
    wait(fn -> not Process.alive?(worker) end)
    {effect, wire} = checkout(target)
    assert Jason.decode!(wire)["error"]["message"] == "Request cancelled"
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "anonymous modern cross-POST cancellation is an advisory no-op" do
    runtime = runtime()
    target = binding(runtime, nil)
    {:ok, _} = submit(runtime, target, modern(request(7)))
    assert_receive {:cancel_callback, 7, worker}
    cancel(runtime, nil, 7, modern: true)
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, wire} = checkout(target)
    assert Jason.decode!(wire)["result"] == 0
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
  end

  test "trusted modern controls cannot cross a runtime lifetime" do
    runtime = runtime()
    other_runtime = runtime()
    target = binding(runtime, nil)
    identity = [endpoint: "/mcp", principal_id: "alice", tenant_id: "team"]
    {:ok, _} = submit(runtime, target, modern(request(7)), dispatch_opts: identity)
    assert_receive {:cancel_callback, 7, worker}
    cancel(other_runtime, nil, 7, dispatch_opts: identity, modern: true)
    assert Process.alive?(worker)
    send(worker, :finish)
    {effect, _wire} = checkout(target)
    :ok = complete(target, effect)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert Runtime.stats(other_runtime).reserved == 0
  end

  test "an originating anonymous socket death still cancels its own modern work" do
    runtime = runtime()
    target = binding(runtime, nil)
    {:ok, _} = submit(runtime, target, modern(request(7)))
    assert_receive {:cancel_callback, 7, worker}
    send(Process.get({:cancel_socket, target}), :close)
    wait(fn -> not Process.alive?(worker) end)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  test "a reused wire session ID in a new store epoch does not cancel old-epoch work" do
    runtime = runtime()
    old_lease = lease(runtime)
    target = binding(runtime, old_lease)
    {:ok, _} = submit(runtime, target, request(7))
    assert_receive {:cancel_callback, 7, worker}
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, store} = Services.resolve(service, :sessions)
    id = SessionLease.id(old_lease)
    key = {store.namespace || "owned", id}
    assert [{^key, _session}] = :ets.lookup(store.read_address, key)
    epoch = "isolated-replacement-epoch"
    # Simulate an addressed backend's wire-ID reuse without replacing the
    # runtime cohort. The old typed lease must fail its final epoch check.
    :ok = ServiceOperation.call(service, :sessions, :fixture_epoch, [id, epoch], [])
    {:ok, fresh_lease} = SessionLease.new(service, id, epoch)
    assert {:error, :stale_session_lease} = SessionLease.validate(old_lease, service, :sessions)
    cancel(runtime, fresh_lease, 7)
    assert Process.alive?(worker)
    send(worker, :finish)
    wait(fn -> not Process.alive?(worker) end)
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  defp assert_cancel_handoff(handoff) do
    runtime = runtime()
    lease = lease(runtime)
    target = binding(runtime, lease)
    {:ok, token} = submit(runtime, target, [request(1), request(7)])
    assert_receive {:cancel_callback, 1, first_worker}
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    task_ref = :sys.get_state(route.scheduler).work[token].task.ref
    :sys.suspend(route.scheduler)
    send(first_worker, :finish)

    wait(fn ->
      {:messages, messages} = Process.info(route.scheduler, :messages)
      Enum.any?(messages, &match?({^task_ref, _result}, &1))
    end)

    source = binding(runtime, lease)
    {:ok, source_token} = submit(runtime, source, cancellation(7))
    {acceptance, ""} = checkout(source)
    :ok = complete(source, acceptance)
    {:ok, gateway} = HTTPGateway.address(runtime)
    wait(fn -> :sys.get_state(gateway).jobs[source_token].cancelling? end)
    :sys.suspend(gateway)

    # Drive only the already-produced native events on their actual owner
    # processes. The queued source control remains untouched until the prior
    # member settles, and the Gateway cannot promote the next member yet.
    native_event(route.scheduler, Scheduler, fn ->
      receive do
        {^task_ref, _proposal} = event -> event
      end
    end)

    native_event(gateway, HTTPGateway, fn ->
      receive do
        {:arbor_mcp_runtime, ^token, {:ok, %{"__runtime_output" => _}}} = event -> event
      end
    end)

    native_event(route.scheduler, Scheduler, fn ->
      receive do
        {:DOWN, ^task_ref, :process, ^first_worker, _reason} = event -> event
      end
    end)

    native_event(route.scheduler, Scheduler, fn ->
      receive do
        {:runtime_output_settled, ^token, _result} = event -> event
      end
    end)

    assert {:ok, %{bound: false, stage: :holding}} = Admission.current(table, token)

    if handoff == :promoted do
      native_event(gateway, HTTPGateway, fn ->
        receive do
          {:arbor_mcp_step_ready, ^token} = event -> event
        end
      end)

      assert {:ok, %{bound: false, request_id: 7}} = Admission.current(table, token)
      assert {:messages, messages} = Process.info(route.scheduler, :messages)
      assert Enum.any?(messages, &match?({:submit, _, ^token, %{"id" => 7}, _}, &1))
    end

    native_event(route.scheduler, Scheduler, fn ->
      receive do
        {:http_cancel, _generation, ^source_token, _phase} = event -> event
      end
    end)

    native_event(route.scheduler, Scheduler, fn ->
      receive do
        {:http_future_cancel_settled, ^source_token, _generation, _phase} = event -> event
      end
    end)

    assert [{_, %{cancellation: :completed}}] =
             :ets.lookup(table, {:http_session_origin, source_token})

    assert :ets.member(table, {:http_wire_cancel, token, 7})
    :sys.resume(route.scheduler)
    :sys.resume(gateway)

    {effect, wire} = checkout(target)
    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(wire)
    :ok = complete(target, effect)
    refute_receive {:cancel_callback, 7, _}, 5
    wait(fn -> Runtime.stats(runtime).reserved == 0 end)
    output_settled(runtime)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, %{request(8) | "method" => "read"})
  end

  defp native_event(pid, module, receive_event) do
    :sys.replace_state(pid, fn state ->
      {:noreply, next_state} = module.handle_info(receive_event.(), state)
      next_state
    end)
  end

  defp output_settled(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    table = Ref.table(runtime)

    wait(fn ->
      match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain)) and
        OutputController.stats(table).frames == 0
    end)
  end

  defp runtime(opts \\ []) do
    root =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime,
           Keyword.merge(
             [
               handler: Handler,
               dispatcher: Handler,
               handler_args: [test: self()],
               request_timeout_ms: 2_000,
               services: [sessions: [adapter: EpochStore]]
             ],
             opts
           )},
          id: make_ref()
        )
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp lease(runtime) do
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(service, %{}, [])
    {:ok, claim} = SessionManager.claim_initialization(service, lease, [])
    :ok = SessionManager.complete_initialization(service, claim, "2025-11-25", [])
    lease
  end

  defp binding(runtime, lease, opts \\ []) do
    socket = spawn(fn -> socket_loop() end)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

    binding =
      socket_call(socket, fn ->
        {:ok, binding} = HTTPWriterProxy.capture(runtime, opts)
        if lease, do: :ok = HTTPWriterRegistry.bind_lease(binding, lease)
        binding
      end)

    Process.put({:cancel_socket, binding}, socket)
    binding
  end

  defp submit(runtime, binding, message, opts \\ []),
    do: call(binding, fn -> HTTPGateway.submit(runtime, binding, message, opts) end)

  defp complete(binding, effect),
    do: call(binding, fn -> HTTPWriterRegistry.complete(effect, :ok) end)

  defp call(binding, fun), do: socket_call(Process.get({:cancel_socket, binding}), fun)

  defp socket_call(socket, fun) do
    token = make_ref()
    send(socket, {:call, self(), token, fun})

    receive do
      {^token, result} -> result
    after
      1_000 -> flunk("owned fixture socket did not return")
    end
  end

  defp socket_loop do
    receive do
      {:call, from, token, fun} ->
        send(from, {token, fun.()})
        socket_loop()

      :close ->
        :ok
    end
  end

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "hold"}

  defp cancellation(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp cancel(runtime, lease, id, opts \\ []) do
    source = binding(runtime, lease)
    notice = if opts[:modern], do: modern(cancellation(id)), else: cancellation(id)
    {:ok, _token} = submit(runtime, source, notice, Keyword.delete(opts, :modern))
    {effect, ""} = checkout(source)
    :ok = complete(source, effect)
    send(Process.get({:cancel_socket, source}), :close)
    {:ok, gateway} = HTTPGateway.address(runtime)

    wait(fn ->
      not Enum.any?(:sys.get_state(gateway).jobs, fn {_token, job} -> job.cancelling? end)
    end)
  end

  defp modern(request) do
    params =
      Map.get(request, "params", %{})
      |> Map.put("_meta", %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    Map.put(request, "params", params)
  end

  defp checkout(binding) do
    wait(fn ->
      case call(binding, fn -> HTTPWriterRegistry.checkout(binding) end) do
        {:ok, effect, wire} -> {effect, wire}
        :empty -> false
        _closed -> false
      end
    end)
  end

  defp wait(fun, left \\ 200)
  defp wait(_fun, 0), do: flunk("cancellation state not reached")

  defp wait(fun, left) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        Process.sleep(5)
        wait(fun, left - 1)
    end
  end
end
