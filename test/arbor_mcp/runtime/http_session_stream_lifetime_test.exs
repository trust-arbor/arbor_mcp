defmodule Arbor.MCP.Server.Runtime.HTTPSessionStreamLifetimeTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPGateway,
    HTTPSessionStreamBinding,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Initialization,
    Ref
  }

  defmodule Handler do
    def init(args), do: {:ok, args}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "installed long session target keeps original TTL without extending request authority" do
    {runtime, domain} = runtime(request_timeout_ms: 120)
    socket = socket()
    entered = Deadline.now()
    {binding, target, lease} = establish(runtime, socket)
    assert {:ok, proof} = HTTPSessionStreamBinding.validate(target, runtime)
    assert proof.deadline in (entered + 3_599_950)..(entered + 3_600_100)
    assert {:ok, request} = HTTPWriterRegistry.proof(binding)
    Process.sleep(max(0, request.deadline + 10 - Deadline.now()))
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert {:ok, %{deadline: same}} = HTTPSessionStreamBinding.validate(target, runtime)
    assert same == proof.deadline
    {:ok, service} = Runtime.service(runtime, :sessions)

    assert {:ok, ^lease} =
             SessionManager.ensure_session(
               service,
               SessionManager.SessionLease.id(lease),
               %{},
               []
             )

    assert {:ok, %{deadline: ^same}} = HTTPSessionStreamBinding.validate(target, runtime)
    checked = start_write(binding, socket)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)
    wait(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, %{deadline: ^same}} = HTTPSessionStreamBinding.validate(target, runtime)
  end

  test "only installed Gateway and original socket can establish under live entry" do
    {runtime, _domain} = runtime()
    socket = socket()
    {binding, target, _lease} = establish(runtime, socket)

    assert {:error, :http_session_stream_closed} =
             HTTPSessionStreamBinding.validate(
               HTTPSessionStreamBinding.new(binding, make_ref()),
               runtime
             )

    assert {:error, _} =
             HTTPWriterRegistry.establish_session_stream(binding, Deadline.now() + 1_000)

    assert {:error, _} =
             call(socket, fn -> HTTPGateway.establish_session_stream(runtime, binding, "/mcp") end)

    {other, _domain} = runtime()

    assert {:error, :http_session_stream_closed} =
             HTTPSessionStreamBinding.validate(target, other)
  end

  test "endpoint mismatch and original expired setup cannot establish a target" do
    {runtime, domain} = runtime(request_timeout_ms: 100)
    socket = socket()
    {binding, _lease} = capture(runtime, socket)

    assert {:error, :invalid_http_session_stream} =
             call(socket, fn ->
               HTTPGateway.establish_session_stream(runtime, binding, "/other")
             end)

    Process.sleep(110)

    assert {:error, _} =
             call(socket, fn -> HTTPGateway.establish_session_stream(runtime, binding, "/mcp") end)

    assert HTTPWriterRegistry.stats(domain).frames == 0
  end

  test "one replacement atomically retires prior target while retaining its entered IO" do
    {runtime, domain} = runtime(max_http_io_frames: 1)
    old_socket = socket()
    {old_binding, old, lease} = establish(runtime, old_socket)
    checked = start_write(old_binding, old_socket)
    new_socket = socket()
    {new_binding, new, ^lease} = establish(runtime, new_socket, lease)
    assert {:error, :http_session_stream_closed} = HTTPSessionStreamBinding.validate(old, runtime)
    assert {:ok, _proof} = HTTPSessionStreamBinding.validate(new, runtime)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(new_binding, "later")
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert Process.alive?(old_socket)

    assert {:error, :http_write_uncertain} =
             call(old_socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    wait(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    {:ok, fresh} = HTTPWriterRegistry.prepare(new_binding, "later")
    assert :ok = HTTPWriterRegistry.release(fresh)
  end

  test "cohort replacement cannot renew target or release actual borrowed write credit" do
    {runtime, domain} = runtime(max_http_io_frames: 1)
    socket = socket()
    {binding, target, _lease} = establish(runtime, socket)
    checked = start_write(binding, socket)
    {:ok, route} = Admission.route(Ref.table(runtime))
    Process.exit(route.scheduler, :kill)

    wait(fn ->
      Initialization.ready?(Ref.table(runtime)) and
        match?(
          {:ok, %{generation: gen}} when gen != route.generation,
          Admission.route(Ref.table(runtime))
        )
    end)

    assert {:error, :http_session_stream_closed} =
             HTTPSessionStreamBinding.validate(target, runtime)

    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert Process.alive?(socket)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    wait(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "captured TTL and actual lease expiry are immutable target ceilings" do
    {runtime, domain} =
      runtime(
        request_timeout_ms: 100,
        services: [sessions: [options: [session_ttl_ms: 250]]]
      )

    socket = socket()
    {binding, target, _lease} = establish(runtime, socket)
    assert {:ok, %{deadline: cutoff}} = HTTPSessionStreamBinding.validate(target, runtime)
    checked = start_write(binding, socket)
    Process.sleep(max(0, cutoff + 10 - Deadline.now()))

    assert {:error, :http_session_stream_closed} =
             HTTPSessionStreamBinding.validate(target, runtime)

    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    wait(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "paused Gateway cannot establish after the original entry cutoff" do
    {runtime, domain} = runtime(request_timeout_ms: 100)
    socket = socket()
    {binding, _lease} = capture(runtime, socket)
    {:ok, gateway} = HTTPGateway.address(runtime)
    :sys.suspend(gateway)
    started = Deadline.now()

    try do
      assert {:error, :http_session_stream_closed} =
               call(socket, fn ->
                 HTTPGateway.establish_session_stream(runtime, binding, "/mcp")
               end)

      assert Deadline.now() - started < 500
    after
      :sys.resume(gateway)
    end

    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    wait(fn -> HTTPWriterRegistry.stats(domain).bindings == 0 end)
    assert HTTPWriterRegistry.stats(domain).frames == 0
    assert Process.alive?(socket)
  end

  test "stale setup cannot retire a healthy replacement target in a new route generation" do
    {runtime, domain} = runtime(request_timeout_ms: 2_000)
    old_socket = socket()
    {old, lease} = capture(runtime, old_socket)

    assert :ok =
             call(old_socket, fn -> HTTPWriterRegistry.request_session_stream(old, "/mcp") end)

    guardian = HTTPWriterRegistry.guardian(domain)
    :sys.suspend(guardian)

    try do
      {:ok, previous} = Admission.route(Ref.table(runtime))
      Process.exit(previous.scheduler, :kill)

      wait(fn ->
        Initialization.ready?(Ref.table(runtime)) and
          match?(
            {:ok, %{generation: gen}} when gen != previous.generation,
            Admission.route(Ref.table(runtime))
          )
      end)

      {_fresh, target, ^lease} = establish(runtime, socket(), lease)
      {:ok, gateway} = HTTPGateway.address(runtime)

      assert {:error, _} =
               as_gateway(gateway, fn ->
                 HTTPWriterRegistry.establish_session_stream(old, Deadline.now() + 1_000)
               end)

      assert {:ok, _proof} = HTTPSessionStreamBinding.validate(target, runtime)

      assert {:error, _} =
               call(old_socket, fn ->
                 HTTPWriterRegistry.request_session_stream(old, "/mcp")
               end)
    after
      :sys.resume(guardian)
    end
  end

  test "queued successful setup reply cannot renew the caller cutoff" do
    {runtime, domain} = runtime(request_timeout_ms: 150)
    socket = socket()
    {binding, _lease} = capture(runtime, socket)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, gateway} = HTTPGateway.address(runtime)
    :sys.suspend(gateway)
    tag = make_ref()

    send(
      socket,
      {:call, self(), tag,
       fn ->
         HTTPGateway.establish_session_stream(runtime, binding, "/mcp")
       end}
    )

    wait(fn -> gateway_call_pending?(gateway) end)
    :erlang.suspend_process(socket)

    try do
      :sys.resume(gateway)
      wait(fn -> socket_reply_pending?(socket) end)
      Process.sleep(max(0, proof.deadline + 10 - Deadline.now()))
    after
      :erlang.resume_process(socket)
    end

    assert_receive {^tag, {:error, :invalid_http_session_stream}}
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    wait(fn -> HTTPWriterRegistry.stats(domain).bindings == 0 end)
    assert HTTPWriterRegistry.stats(domain).frames == 0
  end

  defp gateway_call_pending?(gateway) do
    {:messages, messages} = Process.info(gateway, :messages)
    Enum.any?(messages, &match?({:"$gen_call", _, {:establish_session_stream, _}}, &1))
  end

  defp socket_reply_pending?(socket) do
    {:messages, messages} = Process.info(socket, :messages)
    Enum.any?(messages, &match?({_, {:ok, _target}}, &1))
  end

  defp as_gateway(gateway, operation) do
    caller = self()
    tag = make_ref()

    :sys.replace_state(gateway, fn state ->
      send(caller, {tag, operation.()})
      state
    end)

    assert_receive {^tag, result}
    result
  end

  test "long target metadata is charged before Gateway receives setup control" do
    {runtime, domain} = runtime()
    socket = socket()
    {binding, _lease} = capture(runtime, socket)
    baseline = HTTPWriterRegistry.stats(domain).writer_metadata_bytes
    {limited, limited_domain} = runtime(max_http_writer_metadata_bytes: baseline + 32)
    other = socket()
    {fresh, _lease} = capture(limited, other)

    assert {:error, :http_writer_busy} =
             call(other, fn ->
               HTTPGateway.establish_session_stream(limited, fresh, String.duplicate("e", 4_096))
             end)

    assert {:ok, _proof} = HTTPWriterBinding.validate(fresh, limited)
    assert HTTPWriterRegistry.stats(limited_domain).writer_metadata_bytes <= baseline + 32
    assert HTTPWriterRegistry.stats(limited_domain).frames == 0
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
  end

  defp runtime(opts \\ []) do
    opts = Keyword.merge([handler: Handler, handler_args: [], services: [sessions: []]], opts)
    {:ok, root} = Runtime.start_link(opts)
    {:ok, ref} = Runtime.ref(root)
    {:ok, domain} = HTTPWriterProxy.domain(ref)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {ref, domain}
  end

  defp establish(runtime, socket, lease \\ nil) do
    {binding, lease} = capture(runtime, socket, lease)

    {:ok, target} =
      call(socket, fn -> HTTPGateway.establish_session_stream(runtime, binding, "/mcp") end)

    {binding, target, lease}
  end

  defp capture(runtime, socket, lease \\ nil) do
    {:ok, service} = Runtime.service(runtime, :sessions)

    lease =
      lease || elem(SessionManager.create_session(service, %{transport_endpoint: "/mcp"}, []), 1)

    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.bind_lease(binding, lease) end)
    {binding, lease}
  end

  defp start_write(binding, socket) do
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "data: {}\n\n")
    :ok = HTTPWriterRegistry.publish(ticket)
    {:ok, checked, _wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)
    checked
  end

  defp socket do
    pid = spawn(fn -> socket_loop() end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp socket_loop do
    receive do
      {:call, from, token, operation} ->
        send(from, {token, operation.()})
        socket_loop()

      _wake ->
        socket_loop()
    end
  end

  defp call(pid, operation) do
    token = make_ref()
    send(pid, {:call, self(), token, operation})

    receive do: ({^token, result} -> result),
            after: (3_000 -> flunk("fixture writer did not return"))
  end

  defp wait(operation, attempts \\ 200)
  defp wait(operation, 0), do: assert(operation.())

  defp wait(operation, attempts) do
    if operation.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(operation, attempts - 1)
        )
  end
end
