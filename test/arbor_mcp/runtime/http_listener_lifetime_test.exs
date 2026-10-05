defmodule Arbor.MCP.Server.Runtime.HTTPListenerLifetimeTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPGateway,
    HTTPListenerBinding,
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

  test "established default listener keeps its original hour beyond the RPC cutoff" do
    {_root, runtime, domain} = runtime(request_timeout_ms: 120)
    socket = socket()
    entered = Deadline.now()
    {binding, listener, original} = establish(runtime, socket)
    assert {:ok, proof} = HTTPListenerBinding.validate(listener, runtime)
    assert proof.deadline in (entered + 3_599_980)..(entered + 3_600_100)
    assert original.deadline < proof.deadline
    Process.sleep(max(0, original.deadline + 10 - Deadline.now()))
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert {:ok, %{deadline: same}} = HTTPListenerBinding.validate(listener, runtime)
    assert same == proof.deadline
    effect = start_write(binding, socket)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, %{deadline: ^same}} = HTTPListenerBinding.validate(listener, runtime)
    assert Runtime.stats(runtime).reserved == 0
  end

  test "shortening is captured once and neither establishing again nor IO renews it" do
    {_root, runtime, domain} =
      runtime(
        request_timeout_ms: 150,
        services: [subscriptions: [options: [max_lifetime_ms: 300]]]
      )

    socket = socket()
    cutoff = Deadline.now() + 180
    {binding, listener, _proof} = establish(runtime, socket, deadline: cutoff)
    assert {:ok, %{deadline: ^cutoff}} = HTTPListenerBinding.validate(listener, runtime)
    {:ok, gateway} = HTTPGateway.address(runtime)

    assert {:error, _} =
             as_gateway(gateway, fn ->
               HTTPWriterRegistry.establish_listener(binding, make_ref(),
                 deadline: cutoff + 1_000
               )
             end)

    checked = start_write(binding, socket)
    Process.sleep(max(0, cutoff + 10 - Deadline.now()))
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert Process.alive?(socket)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "only installed Gateway and exact registration can establish or validate a listener" do
    {_root, runtime, _domain} = runtime()
    socket = socket()
    {binding, listener, _proof} = establish(runtime, socket)
    forged = HTTPListenerBinding.new(binding, make_ref())
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(forged, runtime)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    {_replacement_binding, replacement, _proof} = establish(runtime, socket)
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    assert {:ok, _proof} = HTTPListenerBinding.validate(replacement, runtime)
    {_other_root, other_runtime, _domain} = runtime()
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, other_runtime)
    other_socket = socket()
    {:ok, fresh} = call(other_socket, fn -> HTTPWriterProxy.capture(runtime) end)

    assert {:error, :http_invocation_closed} =
             call(other_socket, fn -> HTTPWriterRegistry.establish_listener(fresh, make_ref()) end)
  end

  test "malformed shortening and identity options fail before establishing listener authority" do
    {_root, runtime, domain} = runtime()

    for opts <- [
          [deadline: Integer.pow(2, 100)],
          [deadline: Deadline.now() + 2_000, deadline: Deadline.now() + 3_000],
          [endpoint: "/mcp", identity: {"/another", "alice", "team"}],
          [scope: :forged]
        ] do
      {binding, result, _original} = attempt_establish(runtime, socket(), opts)
      assert {:error, :invalid_http_listener_binding} = result
      assert {:ok, _proof} = HTTPWriterBinding.validate(binding, runtime)
    end

    assert HTTPWriterRegistry.stats(domain).frames == 0
    assert Runtime.stats(runtime).reserved == 0
  end

  test "listener establishment remains inside the configured aggregate writer metadata budget" do
    {_root, runtime, domain} = runtime()
    socket = socket()
    {binding, result, _original} = attempt_establish(runtime, socket, endpoint: "/mcp")
    assert {:ok, _listener} = result
    used = HTTPWriterRegistry.stats(domain).writer_metadata_bytes
    assert used > 0
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    {_limited_root, limited, limited_domain} = runtime(max_http_writer_metadata_bytes: used + 32)

    {fresh, result, _original} =
      attempt_establish(limited, socket(), endpoint: String.duplicate("e", 4_096))

    assert {:error, :http_writer_busy} = result
    assert {:ok, _proof} = HTTPWriterBinding.validate(fresh, limited)
    assert HTTPWriterRegistry.stats(limited_domain).writer_metadata_bytes <= used + 32
    assert HTTPWriterRegistry.stats(limited_domain).frames == 0
    assert Runtime.stats(limited).reserved == 0
  end

  test "listener cohort replacement cannot reuse held IO credit or kill a borrowed socket" do
    {_root, runtime, domain} = runtime(max_http_io_frames: 1)
    socket = socket()
    {binding, listener, _proof} = establish(runtime, socket)
    checked = start_write(binding, socket)
    {:ok, route} = Admission.route(Ref.table(runtime))
    Process.exit(route.scheduler, :kill)

    eventually(fn ->
      Initialization.ready?(Ref.table(runtime)) and
        match?(
          {:ok, %{generation: generation}} when generation != route.generation,
          Admission.route(Ref.table(runtime))
        )
    end)

    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    fresh_socket = socket()
    {:ok, fresh} = call(fresh_socket, fn -> HTTPWriterProxy.capture(runtime) end)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(fresh, "fresh")
    assert Process.alive?(socket)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, _effect} = HTTPWriterRegistry.prepare(fresh, "fresh")
  end

  test "root stop retains the listener's entered IO until an actual return" do
    {root, runtime, domain} = runtime()
    socket = socket()
    {binding, listener, _proof} = establish(runtime, socket)
    checked = start_write(binding, socket)
    assert {:error, {:http_io_unsettled, 1, retained_bytes}} = Runtime.stop(root)
    assert retained_bytes > 0
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert Process.alive?(socket)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    eventually(fn -> not Process.alive?(HTTPWriterRegistry.guardian(domain)) end)
    assert Process.alive?(socket)
  end

  defp runtime(opts \\ []) do
    {:ok, root} = Runtime.start_link(Keyword.merge([handler: Handler, handler_args: []], opts))
    {:ok, runtime} = Runtime.ref(root)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {root, runtime, domain}
  end

  # Pause native ingress and run establishment on the real installed Gateway.
  # No caller-authored generation/scope/owner is accepted by the implementation.
  defp establish(runtime, socket, opts \\ []) do
    {binding, {:ok, listener}, proof} = attempt_establish(runtime, socket, opts)
    {binding, listener, proof}
  end

  defp attempt_establish(runtime, socket, opts) do
    {:ok, gateway} = HTTPGateway.address(runtime)
    :sys.suspend(gateway)
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    request = %{"jsonrpc" => "2.0", "id" => 91, "method" => "subscriptions/listen"}
    {:ok, token} = call(socket, fn -> HTTPGateway.submit(runtime, binding, request) end)

    try do
      result =
        as_gateway(gateway, fn ->
          {:ok, _reservation} = Admission.promote(Ref.table(runtime), token, request, kind: :rpc)
          result = HTTPWriterRegistry.establish_listener(binding, token, opts)

          if match?({:ok, _listener}, result),
            do: :ok = Admission.complete_output_phase(Ref.table(runtime), token)

          :ok = Admission.release(Ref.table(runtime), token)
          result
        end)

      {binding, result, proof}
    after
      :sys.resume(gateway)
    end
  end

  defp as_gateway(gateway, operation) do
    caller = self()
    token = make_ref()

    :sys.replace_state(gateway, fn state ->
      send(caller, {token, operation.()})
      state
    end)

    assert_receive {^token, result}
    result
  end

  defp start_write(binding, socket) do
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "data: {}\r\n\r\n")
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

  defp call(socket, operation) do
    token = make_ref()
    send(socket, {:call, self(), token, operation})

    receive do
      {^token, result} -> result
    after
      3_000 -> flunk("borrowed fixture writer did not return")
    end
  end

  defp eventually(operation, attempts \\ 200)
  defp eventually(operation, 0), do: assert(operation.())

  defp eventually(operation, attempts) do
    if operation.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(operation, attempts - 1)
        )
  end
end
