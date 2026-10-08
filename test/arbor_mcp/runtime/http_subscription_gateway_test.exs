defmodule Arbor.MCP.Server.Runtime.HTTPSubscriptionGatewayTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.{SubscriptionListener, Subscriptions}

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPGateway,
    HTTPListenerBinding,
    HTTPListenerCompletion,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  alias Arbor.MCP.Server.Subscriptions.{Mailbox, Origin}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts) do
      send(opts[:test], :subscription_handler_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def handle_call_tool("publish", args, state) do
      result = Subscriptions.publish("notifications/tools/list_changed", args)
      send(state.test, {:published, result, self()})
      if args["hold"], do: receive(do: (:finish -> :ok))

      {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
       %{state | count: state.count + 1}}
    end
  end

  test "Gateway registers a modern listener once and callbacks fan out after the RPC cutoff" do
    runtime = runtime(request_timeout_ms: 150)
    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    assert_receive :subscription_handler_init
    ack(socket, binding, listener, pid, :acknowledged)
    Process.sleep(180)
    assert {:ok, _} = HTTPListenerBinding.validate(listener, runtime)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    {source, _token} = publish(runtime)
    assert_receive {:published, %{enqueued: 1, subscribers: 1}, _worker}
    ack(socket, binding, listener, pid, :notification)
    settle_response(source)
    refute_receive :subscription_handler_init, 5
    eventually(fn -> Runtime.stats!(runtime).reserved == 0 end)
  end

  test "a cancelled callback cannot publish its queued loan or commit state" do
    runtime = runtime()
    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    ack(socket, binding, listener, pid, :acknowledged)
    {source, _token} = publish(runtime, %{"hold" => true})
    assert_receive {:published, %{enqueued: 1}, _worker}
    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}
    {:ok, source_proof} = HTTPWriterBinding.validate(source, runtime)
    :ok = Runtime.cancel_scope(runtime, source_proof.scope)
    eventually(fn -> match?({:ok, _effect, _wire}, HTTPWriterRegistry.peek(source)) end)

    assert {:error, :source_retired} =
             call(socket, fn -> SubscriptionListener.checkout_http(pid, id, listener, cutoff) end)

    settle_response(source)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).frames == 0 end)
  end

  test "public anonymous callbacks do not satisfy a trusted listener or another endpoint" do
    authorizer = fn _method, _params, _context -> true end

    runtime =
      runtime(
        services: [
          subscriptions: [
            options: [
              authorize_filter: fn filter, _context -> {:ok, filter} end,
              authorize_publication: authorizer
            ]
          ]
        ]
      )

    anonymous = socket()
    {binding, listener, pid, _} = listen(runtime, anonymous)
    ack(anonymous, binding, listener, pid, :acknowledged)
    trusted = socket()
    {tb, tl, tp, _} = listen(runtime, trusted, principal_id: "alice", tenant_id: "team")
    ack(trusted, tb, tl, tp, :acknowledged)
    other = socket()
    {ob, ol, op, _} = listen(runtime, other, endpoint: "/other")
    ack(other, ob, ol, op, :acknowledged)
    {source, _token} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}
    ack(anonymous, binding, listener, pid, :notification)
    refute_receive {:subscription_ready, ^trusted, ^tp, _id, _cutoff}, 15
    refute_receive {:subscription_ready, ^other, ^op, _id, _cutoff}, 15
    settle_response(source)
  end

  test "checked-out publication remains charged until actual IO return after source expiry" do
    runtime = runtime(request_timeout_ms: 180)
    socket = socket()
    {binding, listener, pid, _} = listen(runtime, socket)
    ack(socket, binding, listener, pid, :acknowledged)
    {source, _token} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}
    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}

    {:ok, :notification, message, origin} =
      call(socket, fn -> SubscriptionListener.checkout_http(pid, id, listener, cutoff) end)

    wire = Jason.encode!(message)

    {:ok, effect} =
      call(socket, fn ->
        HTTPWriterRegistry.prepare(binding, wire,
          deadline: cutoff,
          metadata: %{subscription_origin: origin, listener: listener}
        )
      end)

    :ok = call(socket, fn -> HTTPWriterRegistry.publish(effect) end)
    {:ok, effect, _wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)
    loan = :sys.get_state(pid).runtime_delivery.mailbox
    settle_response(source)
    Process.sleep(max(0, cutoff + 15 - Deadline.now()))
    assert not Origin.valid?(origin)
    assert Mailbox.stats(loan).count == 1
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain(binding))
    assert Process.alive?(socket)

    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)

    call(socket, fn -> SubscriptionListener.delivered_http(pid, id, listener) end)
    eventually(fn -> Mailbox.stats(loan).count == 0 end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).frames == 0 end)
  end

  test "listener expiry permits exactly its fixed completion while success authority stays retired" do
    runtime = runtime(services: [subscriptions: [options: [max_lifetime_ms: 120]]])
    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    ack(socket, binding, listener, pid, :acknowledged)
    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}, 1_000
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)

    {:ok, :complete, _message, origin} =
      call(socket, fn -> SubscriptionListener.checkout_http(pid, id, listener, cutoff) end)

    completion = Origin.completion(origin)
    assert {:ok, _} = HTTPListenerCompletion.validate(completion)

    assert {:error, :http_listener_completion_closed} =
             HTTPWriterRegistry.authorize_listener_completion(listener)

    assert {:error, :http_listener_completion_closed} =
             HTTPListenerCompletion.validate(HTTPListenerCompletion.new(listener, make_ref()))

    assert {:error, _} = call(socket, fn -> HTTPWriterRegistry.prepare(binding, "success") end)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)

    {:ok, effect} =
      call(socket, fn -> HTTPWriterRegistry.prepare_listener_completion(completion) end)

    assert {:error, :http_listener_completion_closed} =
             call(socket, fn -> HTTPWriterRegistry.prepare_listener_completion(completion) end)

    :ok = call(socket, fn -> HTTPWriterRegistry.publish(effect) end)
    {:ok, effect, wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)

    assert wire ==
             "data: " <>
               Jason.encode!(%{
                 "jsonrpc" => "2.0",
                 "id" => 91,
                 "result" => %{
                   "resultType" => "complete",
                   "_meta" => %{"io.modelcontextprotocol/subscriptionId" => 91}
                 }
               }) <> "\r\n\r\n"

    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain(binding))
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)
    call(socket, fn -> SubscriptionListener.delivered_http(pid, id, listener) end)
    eventually(fn -> not Process.alive?(pid) end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).frames == 0 end)
    assert Process.alive?(socket)
  end

  test "public close cannot reopen a retired listener row or refund its entered IO" do
    runtime = runtime()
    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    monitor = Process.monitor(pid)
    ack(socket, binding, listener, pid, :acknowledged)
    assert {:ok, listener_proof} = HTTPListenerBinding.validate(listener, runtime)
    wire = ":\r\n\r\n"

    {:ok, effect} = call(socket, fn -> HTTPWriterRegistry.prepare(binding, wire) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.publish(effect) end)
    assert {:ok, ^effect, ^wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)

    assert %{frames: 1, in_flight: 1, bindings: 1, bytes: charged_bytes} =
             HTTPWriterRegistry.stats(domain(binding))

    assert charged_bytes >= byte_size(wire)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)
    assert Process.alive?(pid) and Process.alive?(socket)
    assert Deadline.now() < listener_proof.deadline

    # The actual entered claim keeps the retired row present. This owned Listener
    # processes public close while all its original parties and cutoff are live.
    assert :ok = call(socket, fn -> SubscriptionListener.close(pid) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :subscription_delivery_expired}, 1_000
    refute_receive {:subscription_ready, ^socket, ^pid, _id, _cutoff}, 20

    assert %{frames: 1, in_flight: 1, bindings: 1, bytes: ^charged_bytes} =
             HTTPWriterRegistry.stats(domain(binding))

    # Only the genuine borrowed writer's return settles its existing receipt.
    assert {:error, :http_write_uncertain} =
             call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)

    eventually(fn ->
      match?(
        %{frames: 0, bytes: 0, in_flight: 0, bindings: 0},
        HTTPWriterRegistry.stats(domain(binding))
      )
    end)

    assert Process.alive?(socket)
  end

  test "captured completion tail expires without restoring publication or write authority" do
    runtime =
      runtime(
        output_timeout_ms: 80,
        services: [subscriptions: [options: [max_lifetime_ms: 100]]]
      )

    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    monitor = Process.monitor(pid)
    assert_receive {:subscription_ready, ^socket, ^pid, ack_id, ack_cutoff}, 1_000

    assert {:ok, capture} =
             call(socket, fn ->
               capture_completion_after_ack(runtime, listener, pid, ack_id, ack_cutoff)
             end)

    # Public close captures this genuine completion early; the adjacent case
    # separately preserves natural listener-expiry coverage.
    assert capture.ack_at < capture.listener_deadline
    assert capture.tail_deadline == capture.listener_deadline + 80
    assert capture.completion_at < capture.tail_deadline
    assert capture.checkout_cutoff == min(capture.ready_cutoff, capture.tail_deadline)
    assert capture.proof.deadline == capture.tail_deadline
    assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
    completion = Origin.completion(capture.origin)
    Process.sleep(max(0, capture.tail_deadline + 5 - Deadline.now()))
    assert not Origin.valid?(capture.origin)

    assert {:error, :http_listener_completion_closed} =
             call(socket, fn -> HTTPWriterRegistry.prepare_listener_completion(completion) end)

    assert {:error, _} = call(socket, fn -> HTTPWriterRegistry.prepare(binding, "late") end)
    assert %{frames: 0, in_flight: 0} = HTTPWriterRegistry.stats(domain(binding))
    call(socket, fn -> SubscriptionListener.delivered_http(pid, capture.id, listener) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).bindings == 0 end)
  end

  test "ACK and close processed after the original completion tail cannot renew authority" do
    runtime =
      runtime(
        output_timeout_ms: 80,
        services: [subscriptions: [options: [max_lifetime_ms: 100]]]
      )

    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    monitor = Process.monitor(pid)
    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}, 1_000

    assert {{:ok, listener_proof}, {:ok, tail_deadline}, {:ok, :acknowledged, _message, origin}} =
             call(socket, fn ->
               {:ok, proof} = HTTPListenerBinding.validate(listener, runtime)

               {{:ok, proof}, HTTPWriterRegistry.listener_wait_deadline(listener, runtime),
                SubscriptionListener.checkout_http(pid, id, listener, min(cutoff, proof.deadline))}
             end)

    assert Deadline.now() < listener_proof.deadline
    assert tail_deadline == listener_proof.deadline + 80
    :ok = :sys.suspend(pid, Deadline.remaining(listener_proof.deadline))

    try do
      assert :ok =
               call(socket, fn ->
                 :ok = SubscriptionListener.delivered_http(pid, id, listener)
                 SubscriptionListener.close(pid)
               end)

      Process.sleep(max(0, tail_deadline + 5 - Deadline.now()))
      assert not Origin.valid?(origin)
      assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)

      assert {:error, :http_listener_closed} =
               call(socket, fn -> HTTPWriterRegistry.listener_wait_deadline(listener, runtime) end)

      assert {:error, _} = call(socket, fn -> HTTPWriterRegistry.prepare(binding, "late") end)
      assert %{frames: 0, in_flight: 0} = HTTPWriterRegistry.stats(domain(binding))
      :ok = :sys.resume(pid, 1_000)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
      refute_receive {:subscription_ready, ^socket, ^pid, _id, _cutoff}, 20
      assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
      eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).bindings == 0 end)
      assert Process.alive?(socket)
    after
      if Process.alive?(pid), do: :sys.resume(pid, 1_000)
    end
  end

  test "maintenance retains completion authority after both ordinary listener and old invocation tails expire" do
    runtime =
      runtime(
        request_timeout_ms: 200,
        output_timeout_ms: 200,
        services: [subscriptions: [options: [max_lifetime_ms: 600]]]
      )

    socket = socket()
    {binding, listener, pid, _registration} = listen(runtime, socket)
    ack(socket, binding, listener, pid, :acknowledged)
    {:ok, proof} = HTTPListenerBinding.validate(listener, runtime)
    :sys.suspend(pid)

    try do
      Process.sleep(max(0, proof.deadline + 15 - Deadline.now()))
      # Synchronize actual maintenance rather than relying on its timer ordering.
      guardian = HTTPWriterRegistry.guardian(domain(binding))
      send(guardian, :reap)
      :sys.get_state(guardian)
      assert {:error, :http_listener_closed} = HTTPListenerBinding.validate(listener, runtime)
      assert Process.alive?(pid)

      assert {:ok, _tail} =
               call(socket, fn -> HTTPWriterRegistry.listener_wait_deadline(listener, runtime) end)
    after
      :sys.resume(pid)
    end

    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}, 1_000

    {:ok, :complete, _message, origin} =
      call(socket, fn -> SubscriptionListener.checkout_http(pid, id, listener, cutoff) end)

    completion = Origin.completion(origin)
    {:ok, _proof} = HTTPListenerCompletion.validate(completion)
    # Force another maintenance turn between authorization and preparation.
    guardian = HTTPWriterRegistry.guardian(domain(binding))
    send(guardian, :reap)
    :sys.get_state(guardian)

    {:ok, effect} =
      call(socket, fn -> HTTPWriterRegistry.prepare_listener_completion(completion) end)

    :ok = call(socket, fn -> HTTPWriterRegistry.publish(effect) end)
    {:ok, effect, _wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)
    call(socket, fn -> SubscriptionListener.delivered_http(pid, id, listener) end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).frames == 0 end)
  end

  test "same trusted identity still cannot publish across a private mount domain" do
    runtime =
      runtime(
        services: [
          subscriptions: [
            options: [
              authorize_filter: fn filter, _context -> {:ok, filter} end,
              authorize_publication: fn _method, _params, _context -> true end
            ]
          ]
        ]
      )

    socket = socket()

    {binding, listener, pid, _registration} =
      listen(runtime, socket, principal_id: "alice", endpoint: "/mcp", http_endpoint: "/api/a")

    ack(socket, binding, listener, pid, :acknowledged)

    {source, _token} =
      publish(runtime, %{}, principal_id: "alice", endpoint: "/mcp", http_endpoint: "/api/b")

    assert_receive {:published, %{enqueued: 0}, _worker}
    assert Process.alive?(pid)
    refute_receive {:subscription_ready, ^socket, ^pid, _id, _cutoff}, 10
    settle_response(source)

    {source, _token} =
      publish(runtime, %{}, principal_id: "alice", endpoint: "/mcp", http_endpoint: "/api/a")

    assert_receive {:published, %{enqueued: 1}, _worker}
    ack(socket, binding, listener, pid, :notification)
    settle_response(source)
  end

  test "rejected filter setup sends one charged error without retaining listener authority" do
    runtime =
      runtime(
        services: [
          subscriptions: [
            options: [authorize_filter: fn _filter, _context -> {:error, :denied} end]
          ]
        ]
      )

    reject_setup(runtime, 0)
  end

  test "listener capacity rejection preserves the active target and settles the new error" do
    runtime = runtime(services: [subscriptions: [options: [max_global: 1]]])
    first = socket()
    {binding, listener, pid, _registration} = listen(runtime, first)
    ack(first, binding, listener, pid, :acknowledged)
    reject_setup(runtime, 1)
    assert {:ok, _proof} = HTTPListenerBinding.validate(listener, runtime)
    assert Process.alive?(pid)
  end

  defp reject_setup(runtime, active) do
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    {:ok, initial} = call(socket, fn -> HTTPWriterBinding.validate(binding, runtime) end)

    {:ok, _token} =
      call(socket, fn ->
        HTTPGateway.submit(runtime, binding, listen_message(), dispatch_opts: dispatch_opts([]))
      end)

    {effect, wire} =
      eventually(fn ->
        case call(socket, fn -> HTTPWriterRegistry.checkout(binding) end) do
          {:ok, effect, wire} -> {effect, wire}
          _waiting -> nil
        end
      end)

    assert Jason.decode!(wire)["error"]["message"] == "Invalid subscription request"
    assert :empty == call(socket, fn -> HTTPWriterRegistry.listener_setup(binding) end)
    {:ok, final} = call(socket, fn -> HTTPWriterBinding.validate(binding, runtime) end)
    assert final.deadline == initial.deadline
    assert final.scope == initial.scope
    assert length(Subscriptions.entries(runtime: runtime)) == active
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain(binding))
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(effect, :ok) end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.retire(binding) end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).frames == 0 end)
    eventually(fn -> HTTPWriterRegistry.stats(domain(binding)).bindings == active end)
    eventually(fn -> Runtime.stats!(runtime).reserved == 0 end)
  end

  defp runtime(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [handler: Handler, handler_args: [test: self()], request_timeout_ms: 1_000],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp listen(runtime, socket, opts \\ []) do
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)

    {:ok, _token} =
      call(socket, fn ->
        HTTPGateway.submit(runtime, binding, listen_message(), dispatch_opts: dispatch_opts(opts))
      end)

    response =
      eventually(fn ->
        case call(socket, fn -> HTTPWriterRegistry.listener_setup(binding) end) do
          :empty -> nil
          value -> value
        end
      end)

    assert {:listener, listener, pid, registration} = response
    {binding, listener, pid, registration}
  end

  defp publish(runtime, args \\ %{}, opts \\ []) do
    {:ok, source} = HTTPWriterProxy.capture(runtime)

    request =
      modern(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => "publish", "arguments" => args}
      })

    {:ok, token} =
      HTTPGateway.submit(runtime, source, request, dispatch_opts: dispatch_opts(opts))

    {source, token}
  end

  defp listen_message do
    modern(%{
      "jsonrpc" => "2.0",
      "id" => 91,
      "method" => "subscriptions/listen",
      "params" => %{"notifications" => %{"toolsListChanged" => true}}
    })
  end

  defp modern(request),
    do:
      put_in(request, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

  defp dispatch_opts(opts),
    do: Keyword.merge([endpoint: "/mcp", protocol_mode: :modern_only], opts)

  defp domain(binding), do: elem(elem(HTTPWriterBinding.address(binding), 1), 0)

  defp ack(socket, binding, listener, pid, expected) do
    assert_receive {:subscription_ready, ^socket, ^pid, id, cutoff}, 1_000

    assert {:ok, ^expected, _message, _origin} =
             call(socket, fn -> SubscriptionListener.checkout_http(pid, id, listener, cutoff) end)

    assert :ok = call(socket, fn -> SubscriptionListener.delivered_http(pid, id, listener) end)
    assert HTTPWriterRegistry.stats(domain(binding)).in_flight == 0
  end

  defp capture_completion_after_ack(runtime, listener, pid, id, cutoff) do
    with {:ok, listener_proof} <- HTTPListenerBinding.validate(listener, runtime),
         {:ok, tail_deadline} <- HTTPWriterRegistry.listener_wait_deadline(listener, runtime),
         {:ok, :acknowledged, _message, _origin} <-
           SubscriptionListener.checkout_http(
             pid,
             id,
             listener,
             min(cutoff, listener_proof.deadline)
           ),
         :ok <- SubscriptionListener.delivered_http(pid, id, listener),
         remaining when remaining > 0 <- Deadline.remaining(listener_proof.deadline) do
      # The actual socket sent the cast and this system request to the same Listener.
      # The returned native state therefore proves that exact ACK was processed.
      state = :sys.get_state(pid, remaining)
      ack_at = Deadline.now()

      if is_nil(state.runtime_delivery.in_flight) and ack_at < listener_proof.deadline do
        :ok = SubscriptionListener.close(pid)

        receive do
          {:ex_mcp_subscription_ready, ^pid, complete_id, ready_cutoff} ->
            checkout_cutoff = min(ready_cutoff, tail_deadline)

            with {:ok, :complete, _message, origin} <-
                   SubscriptionListener.checkout_http(pid, complete_id, listener, checkout_cutoff),
                 {:ok, proof} <- HTTPListenerCompletion.validate(Origin.completion(origin)) do
              {:ok,
               %{
                 id: complete_id,
                 origin: origin,
                 proof: proof,
                 ack_at: ack_at,
                 listener_deadline: listener_proof.deadline,
                 tail_deadline: tail_deadline,
                 ready_cutoff: ready_cutoff,
                 checkout_cutoff: checkout_cutoff,
                 completion_at: Deadline.now()
               }}
            end
        after
          Deadline.remaining(tail_deadline) -> {:error, :completion_not_ready_before_cutoff}
        end
      else
        {:error, :ack_not_processed_before_cutoff}
      end
    end
  catch
    :exit, _reason -> {:error, :subscription_unavailable}
  end

  defp settle_response(binding) do
    {effect, _wire} =
      eventually(fn ->
        case HTTPWriterRegistry.checkout(binding) do
          {:ok, effect, wire} -> {effect, wire}
          _waiting -> nil
        end
      end)

    HTTPWriterRegistry.complete(effect, :ok)
    HTTPWriterRegistry.retire(binding)
  end

  defp socket do
    parent = self()
    pid = spawn(fn -> socket_loop(parent) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp socket_loop(parent) do
    receive do
      {:call, from, token, operation} ->
        send(from, {token, operation.()})
        socket_loop(parent)

      {:ex_mcp_subscription_ready, listener, id, cutoff} ->
        send(parent, {:subscription_ready, self(), listener, id, cutoff})
        socket_loop(parent)

      {:mcp_http_output_wake, domain, nonce} ->
        HTTPWriterRegistry.acknowledge_wake(domain, nonce)
        socket_loop(parent)

      _message ->
        socket_loop(parent)
    end
  end

  defp call(socket, operation) do
    token = make_ref()
    send(socket, {:call, self(), token, operation})
    receive do: ({^token, result} -> result), after: (1_000 -> flunk("socket did not reply"))
  end

  defp eventually(fun, remaining \\ 200)
  defp eventually(_fun, 0), do: flunk("condition did not settle")

  defp eventually(fun, remaining) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        Process.sleep(5)
        eventually(fun, remaining - 1)
    end
  end
end
