defmodule Arbor.MCP.Server.Runtime.HTTPCancellationTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    HTTPGateway,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Ref,
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
