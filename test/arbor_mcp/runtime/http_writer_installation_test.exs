defmodule Arbor.MCP.Server.Runtime.HTTPWriterInstallationTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Ref
  }

  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.{InitializationClaim, SessionLease}

  defmodule Handler do
    def init(args), do: {:ok, args}
    def terminate(_reason, _state), do: :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "root owns proxy but the borrowed-IO guardian is outside forced child provenance" do
    {_root, runtime, domain} = runtime()
    {:ok, proxy} = HTTPWriterProxy.active_proxy(runtime)
    guardian = HTTPWriterRegistry.guardian(domain)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    state = :sys.get_state(guard)
    assert Map.has_key?(state.children, proxy)
    refute Map.has_key?(state.children, guardian)
    {:links, links} = Process.info(guardian, :links)
    assert links == []
    assert {:ok, ^domain} = HTTPWriterProxy.domain(runtime)
  end

  test "entry captures actual socket and one cutoff, rejecting caller-authored proof options" do
    {_root, runtime, domain} = runtime(request_timeout_ms: 200)
    assert {:error, :invalid_http_entry_options} = HTTPWriterProxy.capture(runtime, proof: %{})

    assert {:error, :invalid_http_entry_options} =
             HTTPWriterProxy.capture(runtime, writer: self())

    assert {:error, :invalid_http_entry_options} =
             HTTPWriterProxy.capture(runtime, deadline: Integer.pow(2, 100))

    assert HTTPWriterRegistry.stats(domain).writers == 0
    socket = socket()
    entered = Deadline.now()

    {:ok, binding} =
      call(socket, fn -> HTTPWriterProxy.capture(runtime, deadline: entered + 10_000) end)

    assert {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    assert proof.owner == socket
    assert proof.deadline <= entered + 220
    :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    cutoff = Deadline.now() + 20
    Process.sleep(25)

    assert {:error, :invalid_http_entry_options} =
             call(socket, fn -> HTTPWriterProxy.capture(runtime, deadline: cutoff) end)
  end

  test "raw standalone registrations cannot authenticate an installed service invocation" do
    {_root, runtime, domain} = runtime()
    socket = socket()
    {:ok, proxy} = HTTPWriterProxy.active_proxy(runtime)
    [{:route, route}] = :ets.lookup(Ref.table(runtime), :route)

    proof = %{
      invocation: make_ref(),
      generation: route.generation,
      scope: :forged,
      lease: nil,
      deadline: Deadline.now() + 2_000
    }

    {:ok, raw} = HTTPWriterRegistry.register(domain, socket, proof, owner: proxy)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(raw, runtime)
    :ok = call(socket, fn -> HTTPWriterRegistry.retire(raw) end)
    {:ok, real} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert {:ok, %{owner: ^socket}} = HTTPWriterBinding.validate(real, runtime)
  end

  test "proxy replacement preserves original domain and checked-out credit" do
    {root, runtime, domain} = runtime(max_http_io_frames: 1)
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    checked = start_write(binding, socket)
    guardian = HTTPWriterRegistry.guardian(domain)
    {:ok, old_proxy} = HTTPWriterProxy.active_proxy(runtime)
    Process.exit(old_proxy, :kill)

    eventually(fn ->
      match?({:ok, pid} when pid != old_proxy, HTTPWriterProxy.active_proxy(runtime))
    end)

    eventually(fn -> match?({:ok, _}, Runtime.ref(root)) and ready?(runtime) end)
    assert {:ok, ^domain} = HTTPWriterProxy.domain(runtime)
    assert HTTPWriterRegistry.guardian(domain) == guardian
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    other = socket()
    {:ok, fresh} = call(other, fn -> HTTPWriterProxy.capture(runtime) end)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(fresh, "fresh")

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, _} = HTTPWriterRegistry.prepare(fresh, "fresh")
    assert Process.alive?(socket)
  end

  test "Admission replacement fences old generation without replacing guardian credits" do
    {_root, runtime, domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    checked = start_write(binding, socket)
    [{:admission, admission}] = :ets.lookup(Ref.table(runtime), :admission)
    {:ok, proxy} = HTTPWriterProxy.active_proxy(runtime)
    Process.exit(admission, :kill)

    eventually(fn ->
      ready?(runtime) and
        match?(
          [{:admission, pid}] when pid != admission,
          :ets.lookup(Ref.table(runtime), :admission)
        )
    end)

    assert {:ok, ^proxy} = HTTPWriterProxy.active_proxy(runtime)
    assert {:ok, ^domain} = HTTPWriterProxy.domain(runtime)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)
  end

  test "root stop reports unsettled borrowed IO while receipt survives deleted runtime ETS" do
    {root, runtime, domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    checked = start_write(binding, socket)
    assert {:error, {:http_io_unsettled, 1, bytes}} = Runtime.stop(runtime)
    assert bytes > 0
    refute Process.alive?(root)
    assert :ets.info(Ref.table(runtime)) == :undefined
    assert Process.alive?(socket)
    assert Process.alive?(HTTPWriterRegistry.guardian(domain))

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    eventually(fn -> HTTPWriterRegistry.cleanup_status(domain) == :ok end)
    eventually(fn -> not Process.alive?(HTTPWriterRegistry.guardian(domain)) end)
    assert :ok = HTTPWriterRegistry.cleanup_status(domain)
    assert Process.alive?(socket)
  end

  test "guardian loss poisons the domain and cannot restart with fresh capacity" do
    {root, runtime, domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    checked = start_write(binding, socket)
    Process.exit(HTTPWriterRegistry.guardian(domain), :kill)
    eventually(fn -> not Process.alive?(root) end)
    assert {:error, :http_io_cleanup_unconfirmed} = HTTPWriterRegistry.cleanup_status(domain)

    assert {:error, :http_writer_unavailable} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    assert Process.alive?(socket)
  end

  test "real blocked IO return is required after Runtime.stop reports uncertainty" do
    {_root, runtime, domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    checked = start_write(binding, socket)
    parent = self()

    device =
      spawn(fn ->
        receive do
          {:io_request, from, token, _request} ->
            send(parent, :physical_write_started)

            receive do
              :allow_return -> send(from, {:io_reply, token, :ok})
            end
        end
      end)

    on_exit(fn -> if Process.alive?(device), do: Process.exit(device, :kill) end)
    token = make_ref()

    send(
      socket,
      {:call, self(), token,
       fn ->
         :ok = IO.binwrite(device, "data: {}\r\n\r\n")
         HTTPWriterRegistry.complete(checked, :ok)
       end}
    )

    assert_receive :physical_write_started
    assert {:error, {:http_io_unsettled, 1, _bytes}} = Runtime.stop(runtime)
    assert Process.alive?(socket)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    refute_receive {^token, _result}, 20
    send(device, :allow_return)
    assert_receive {^token, {:error, :http_write_uncertain}}
    eventually(fn -> HTTPWriterRegistry.cleanup_status(domain) == :ok end)
    assert Process.alive?(socket)
  end

  test "session-bound claim keeps entry lifetime beyond the separate short service wait" do
    {_root, runtime, _domain} = runtime(request_timeout_ms: 3_000, services: [sessions: []])
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)

    assert {:error, :invalid_http_invocation} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions, lease, invocation: binding)
             end)

    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, lease) end)

    assert {:error, :invalid_http_invocation} =
             SessionManager.claim_initialization(sessions, lease,
               invocation: binding,
               owner: socket
             )

    assert {:ok, claim} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions, lease,
                 invocation: binding,
                 timeout: 50
               )
             end)

    assert {:ok, _key, _token, ^socket, cutoff} = InitializationClaim.validate(claim, sessions)
    assert cutoff > Deadline.now() + 2_000
    Process.sleep(75)

    assert :ok =
             call(socket, fn ->
               SessionManager.complete_initialization(sessions, claim, "2026-07-28", [])
             end)
  end

  test "lease binds once and cross-session proof cannot mutate another session" do
    {_root, runtime, _domain} = runtime(services: [sessions: []])
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, first} = SessionManager.create_session(sessions, %{}, [])
    {:ok, other} = SessionManager.create_session(sessions, %{}, [])
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, first) end)

    assert {:error, :invalid_http_session_lease} =
             call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, other) end)

    assert {:error, _} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions, other, invocation: binding)
             end)

    assert {:ok, %{initialization_claimed: false}} =
             SessionManager.get_session(sessions, other, [])

    assert {:ok, _claim} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions, first, invocation: binding)
             end)
  end

  test "cross-runtime entry proof rejects before session mutation" do
    {_root, runtime, _domain} = runtime(services: [sessions: []])
    {_root2, runtime2, _domain2} = runtime(services: [sessions: []])
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, sessions2} = Runtime.service(runtime2, :sessions)
    {:ok, first} = SessionManager.create_session(sessions, %{}, [])
    {:ok, second} = SessionManager.create_session(sessions2, %{}, [])
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, first) end)

    assert {:error, :invalid_http_invocation} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions2, second, invocation: binding)
             end)

    assert {:ok, %{initialization_claimed: false}} =
             SessionManager.get_session(sessions2, second, [])
  end

  test "recreated same session ID has a fresh epoch and old claim cannot complete it" do
    {_root, runtime, _domain} = runtime(services: [sessions: []])
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, lease) end)

    {:ok, claim} =
      call(socket, fn ->
        SessionManager.claim_initialization(sessions, lease, invocation: binding)
      end)

    assert :ok = SessionManager.terminate_session(sessions, lease, [])

    {:ok, fresh} =
      SessionManager.create_session(sessions, %{}, session_id: SessionLease.id(lease))

    assert {:error, _} =
             call(socket, fn ->
               SessionManager.complete_initialization(sessions, claim, "2026-07-28", [])
             end)

    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)

    assert {:ok, %{initialized: false, initialization_claimed: false}} =
             SessionManager.get_session(sessions, fresh, [])
  end

  test "work binds only matching owner scope and token once, then cancellation revokes it" do
    {_root, runtime, _domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, proxy} = HTTPWriterProxy.active_proxy(runtime)
    request = %{method: "ping", params: %{}, id: 7}

    {:ok, _route, bad} =
      Admission.reserve(runtime, request, owner: proxy, scope: :wrong, timeout: 1_000)

    assert {:error, :invalid_http_work_origin} =
             call(socket, fn -> HTTPWriterRegistry.bind_work(binding, bad.token) end)

    :ok = Admission.release(Ref.table(runtime), bad.token)

    {:ok, _route, good} =
      Admission.reserve(runtime, request, owner: proxy, scope: proof.scope, timeout: 1_000)

    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_work(binding, good.token) end)

    assert {:error, :invalid_http_work_origin} =
             call(socket, fn -> HTTPWriterRegistry.bind_work(binding, good.token) end)

    assert {:ok, _} = HTTPWriterBinding.validate(binding, runtime)
    :ok = Admission.release(Ref.table(runtime), good.token)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
  end

  test "paused session backend cannot extend entry cutoff or apply late queued claim" do
    {_root, runtime, _domain} = runtime(services: [sessions: []])
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime, timeout: 120) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, lease) end)
    {:ok, service} = Arbor.MCP.Server.Runtime.Services.resolve(sessions, :sessions)
    :sys.suspend(service.server)
    started = Deadline.now()

    assert {:error, :operation_timeout} =
             call(socket, fn ->
               SessionManager.claim_initialization(sessions, lease, invocation: binding)
             end)

    assert Deadline.now() - started < 300
    :sys.resume(service.server)

    assert {:ok, %{initialization_claimed: false, initialized: false}} =
             SessionManager.get_session(sessions, lease, [])
  end

  test "a batch member phase cannot authorize the aggregate HTTP response" do
    {_root, runtime, domain} = runtime()
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, proxy} = HTTPWriterProxy.active_proxy(runtime)

    batch = %{
      "payload" => [%{"method" => "ping", "id" => 1}, %{"method" => "ping", "id" => 2}]
    }

    {:ok, _route, reservation} =
      Admission.reserve(runtime, batch,
        owner: proxy,
        scope: proof.scope,
        batch?: true,
        timeout: 1_000
      )

    assert reservation.work_count == 2
    before = HTTPWriterRegistry.stats(domain)

    assert {:error, :invalid_http_work_origin} =
             call(socket, fn -> HTTPWriterRegistry.bind_work(binding, reservation.token) end)

    assert HTTPWriterRegistry.stats(domain).writer_metadata_bytes == before.writer_metadata_bytes
    assert {:ok, _} = HTTPWriterBinding.validate(binding, runtime)
    assert %{admitted_work: 2} = Admission.stats(Ref.table(runtime))
    :ok = Admission.release(Ref.table(runtime), reservation.token)
    assert %{admitted_work: 0} = Admission.stats(Ref.table(runtime))

    {:ok, _route, scalar} =
      Admission.reserve(runtime, %{method: "ping", id: 3},
        owner: proxy,
        scope: proof.scope,
        timeout: 1_000
      )

    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_work(binding, scalar.token) end)
    :ok = Admission.release(Ref.table(runtime), scalar.token)
  end

  defp runtime(opts \\ []) do
    {:ok, root} = Runtime.start_link(Keyword.merge([handler: Handler, handler_args: %{}], opts))
    {:ok, runtime} = Runtime.ref(root)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {root, runtime, domain}
  end

  defp ready?(runtime), do: Arbor.MCP.Server.Runtime.Initialization.ready?(Ref.table(runtime))

  defp socket do
    pid = spawn(fn -> socket_loop() end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp socket_loop do
    receive do
      {:call, from, token, operation} ->
        result = operation.()
        send(from, {token, result})
        socket_loop()

      _wake ->
        socket_loop()
    end
  end

  defp call(socket, operation) do
    token = make_ref()
    send(socket, {:call, self(), token, operation})

    receive do
      {^token, result} -> result
    after
      3_000 -> flunk("socket operation did not finish")
    end
  end

  defp start_write(binding, socket) do
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "data: {}\r\n\r\n")
    :ok = HTTPWriterRegistry.publish(ticket)
    {:ok, checked, _wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)
    checked
  end

  defp eventually(fun, remaining \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end
end
