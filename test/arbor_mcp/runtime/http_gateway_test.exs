defmodule Arbor.MCP.Server.Runtime.HTTPGatewayTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    HTTPGateway,
    HTTPNotificationTarget,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    OutputController,
    Ref
  }

  defmodule Handler do
    def init(opts) do
      send(opts[:test], :http_handler_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def dispatch(request, _module, state, opts) do
      send(state.test, {:gateway_callback, request["id"], self()})

      if request["method"] == "notify" do
        :ok =
          HTTPNotificationTarget.deliver(opts[:target], %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{"progress" => 1}
          })
      end

      if request["method"] == "hold", do: receive(do: (:finish -> :ok))
      if request["method"] == "crash", do: raise("fixed fixture failure")

      if Map.has_key?(request, "id") do
        {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state.count},
         %{state | count: state.count + 1}}
      else
        {:notification, %{state | count: state.count + 1}}
      end
    end
  end

  test "sequential HTTP invocations share initialized handler state and independent writers" do
    runtime = runtime()
    assert_receive :http_handler_init
    assert %{jobs: 0} = OutputController.stats(Ref.table(runtime))

    for {id, expected} <- [{1, 0}, {2, 1}] do
      {:ok, binding} = HTTPWriterProxy.capture(runtime)
      {:ok, token} = HTTPGateway.submit(runtime, binding, message(id))
      {effect, wire} = checkout(binding)
      assert Jason.decode!(wire)["result"] == expected
      assert :ok = HTTPWriterRegistry.complete(effect, :ok)
      wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
      assert :ok = HTTPWriterRegistry.retire(binding)
      acknowledge(binding)
      refute_receive {:arbor_mcp_runtime, ^token, _}, 5
    end

    refute_receive :http_handler_init, 5
    assert %{jobs: 0, frames: 0} = OutputController.stats(Ref.table(runtime))
  end

  test "legacy batch is one complete array with ordered members and physical ACK" do
    runtime = runtime()
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, [message(1), message(2)])
    {effect, wire} = checkout(binding)
    assert [%{"id" => 1, "result" => 0}, %{"id" => 2, "result" => 1}] = Jason.decode!(wire)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    assert %{in_flight: 1, frames: 1, bytes: charged} = HTTPWriterRegistry.stats(domain)
    assert charged > byte_size(wire)
    assert %{reserved: 2} = Runtime.stats(runtime)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
  end

  test "invalid legacy members retain work permits and preserve notification omission and ordering" do
    runtime = runtime()
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    notification = Map.delete(message(1), "id")
    {:ok, _token} = HTTPGateway.submit(runtime, binding, [17, notification, message(2)])
    {effect, wire} = checkout(binding)

    assert [%{"id" => nil, "error" => %{"code" => -32600}}, %{"id" => 2, "result" => 1}] =
             Jason.decode!(wire)

    assert %{reserved: 3} = Runtime.stats(runtime)
    :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
  end

  test "later failed batch member never authorizes a partial array or retries prior committed state" do
    runtime = runtime()
    {:ok, binding} = HTTPWriterProxy.capture(runtime)

    {:ok, token} =
      HTTPGateway.submit(runtime, binding, [message(1), %{message(2) | "method" => "crash"}])

    {effect, wire} = checkout(binding)
    assert %{"id" => 2, "error" => %{"code" => -32603}} = Jason.decode!(wire)
    {:ok, gateway} = HTTPGateway.address(runtime)
    send(gateway, {:arbor_mcp_runtime, token, {:error, :handler_crash}})
    :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(3))
    assert :empty = HTTPWriterRegistry.checkout(binding)
  end

  test "physical aggregate pressure rejects a later proposal before its state commit" do
    runtime = runtime(max_http_io_frames: 2)
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, [message(1), message(2), message(3)])
    {effect, wire} = checkout(binding)
    assert %{"id" => 3, "error" => %{"code" => -32603}} = Jason.decode!(wire)
    :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    assert {:ok, %{"result" => 2}} = Runtime.request(runtime, message(4))
  end

  test "sse framing is prepared once before state commit and real IO acknowledgement" do
    runtime = runtime()
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, message(1), format: :sse)
    {effect, wire} = checkout(binding)
    assert wire == "data: {\"id\":1,\"jsonrpc\":\"2.0\",\"result\":0}\r\n\r\n"
    assert %{reserved: 1} = Runtime.stats(runtime)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
  end

  test "one fixed charged timeout error may use the entry failure tail without reviving success" do
    runtime = runtime()
    assert_receive :http_handler_init
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 40)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, %{message(7) | "method" => "hold"})
    assert_receive {:gateway_callback, 7, _worker}
    Process.sleep(50)
    {effect, wire} = checkout(binding)

    assert %{"id" => 7, "error" => %{"code" => -32603, "message" => "Request timeout"}} =
             Jason.decode!(wire)

    assert {:error, :http_invocation_closed} =
             HTTPWriterBinding.validate(binding, runtime)

    assert {:error, :http_invocation_closed} =
             HTTPWriterRegistry.prepare(binding, "{\"result\":1}")

    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    assert %{in_flight: 1, bytes: bytes} = HTTPWriterRegistry.stats(domain)
    assert bytes > byte_size(wire)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{frames: 0}, HTTPWriterRegistry.stats(domain)) end)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(8))
    refute_receive :http_handler_init, 5
  end

  test "202 IO is admitted before notification effects and normal socket return keeps accepted work" do
    runtime = runtime()
    parent = self()

    socket =
      spawn(fn ->
        {:ok, binding} = HTTPWriterProxy.capture(runtime)
        {:ok, _} = HTTPGateway.submit(runtime, binding, %{"jsonrpc" => "2.0", "method" => "hold"})
        {effect, ""} = checkout(binding)
        :ok = HTTPWriterRegistry.complete(effect, :ok)
        send(parent, :accepted_202)
      end)

    monitor = Process.monitor(socket)
    assert_receive {:gateway_callback, nil, worker}
    assert_receive :accepted_202
    assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}
    assert %{reserved: 1} = Runtime.stats(runtime)
    send(worker, :finish)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2))
  end

  test "expired logical output retains physical liability and late IO return reclaims input" do
    runtime = runtime(request_timeout_ms: 60, output_timeout_ms: 30)
    assert_receive :http_handler_init
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, token} = HTTPGateway.submit(runtime, binding, message(1))
    {effect, _wire} = checkout(binding)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    {:ok, gateway} = HTTPGateway.address(runtime)
    wait(fn -> not is_nil(:sys.get_state(gateway).jobs[token].observation) end)
    # Logical step completion may race output expiry. Neither event is an IO
    # return, and the retained Gateway bookkeeping must stay charged.
    send(gateway, {:arbor_mcp_step_ready, token})
    wait(fn -> :sys.get_state(gateway).jobs[token].done? end)
    wait(fn -> match?(%{jobs: 0}, OutputController.stats(Ref.table(runtime))) end)
    assert %{in_flight: 1, frames: 1} = HTTPWriterRegistry.stats(domain)
    # Logical input may already expire; physical IO capacity cannot be reused.
    assert %{reserved: reserved} = Runtime.stats(runtime)
    assert reserved in [0, 1]
    assert map_size(:sys.get_state(gateway).jobs) == 1
    assert Process.alive?(self())
    assert {:error, :http_write_uncertain} = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    wait(fn -> match?(%{frames: 0}, HTTPWriterRegistry.stats(domain)) end)
    wait(fn -> map_size(:sys.get_state(gateway).jobs) == 0 end)
    assert [] = :ets.lookup(Ref.table(runtime), {:output_failure, token})
    assert [] = :ets.lookup(Ref.table(runtime), {:output_commit, token})
    assert {:ok, %{"result" => 1}} = Runtime.request(runtime, message(2))
    refute_receive :http_handler_init, 5
  end

  test "a timeout during borrowed notification IO retains its original observation without a retry" do
    runtime = runtime(request_timeout_ms: 60, output_timeout_ms: 30)
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, target} = HTTPNotificationTarget.new(runtime, binding)

    {:ok, token} =
      HTTPGateway.submit(runtime, binding, %{message(1) | "method" => "notify"},
        format: :sse,
        dispatch_opts: [target: target]
      )

    {effect, wire} = checkout(binding)
    assert wire =~ "notifications/progress"
    {:ok, gateway} = HTTPGateway.address(runtime)
    send(gateway, {:arbor_mcp_runtime, token, {:error, :handler_timeout}})
    wait(fn -> :sys.get_state(gateway).jobs[token].failed? end)
    wait(fn -> match?(%{jobs: 0}, OutputController.stats(Ref.table(runtime))) end)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert map_size(:sys.get_state(gateway).jobs) == 1
    assert {:error, :http_write_uncertain} = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    wait(fn -> map_size(:sys.get_state(gateway).jobs) == 0 end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2))
    assert %{frames: 0, in_flight: 0} = HTTPWriterRegistry.stats(domain)

    assert HTTPWriterRegistry.checkout(binding) in [
             :empty,
             {:error, :http_invocation_closed},
             {:error, :http_failure_expired}
           ]
  end

  test "socket death cancels its accepted response work without mutating other invocation state" do
    runtime = runtime()
    parent = self()

    socket =
      spawn(fn ->
        {:ok, binding} = HTTPWriterProxy.capture(runtime)
        {:ok, token} = HTTPGateway.submit(runtime, binding, %{message(1) | "method" => "hold"})
        send(parent, {:submitted_socket, token})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:submitted_socket, _token}
    assert_receive {:gateway_callback, 1, worker}
    send(socket, :close)
    wait(fn -> not Process.alive?(worker) end)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats(runtime)) end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(2))
  end

  test "a notification cannot produce effects if its physical202 capacity is unavailable" do
    runtime = runtime(max_http_io_frames: 1)
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, held} = HTTPWriterRegistry.prepare(binding, "occupied")

    {:error, :http_output_busy} =
      HTTPGateway.submit(runtime, binding, %{"jsonrpc" => "2.0", "method" => "read"})

    assert %{reserved: 0} = Runtime.stats(runtime)
    refute_receive {:gateway_callback, nil, _}, 10
    :ok = HTTPWriterRegistry.release(held)
  end

  test "input rejection atomically reclaims the unpublished202 liability" do
    runtime = runtime(max_queue: 0)
    {:ok, _} = Runtime.submit(runtime, %{message(1) | "method" => "hold"})
    assert_receive {:gateway_callback, 1, worker}
    {:ok, binding} = HTTPWriterProxy.capture(runtime)

    assert {:error, :server_busy} =
             HTTPGateway.submit(runtime, binding, %{"jsonrpc" => "2.0", "method" => "read"})

    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    assert %{frames: 0, bytes: 0} = HTTPWriterRegistry.stats(domain)
    send(worker, :finish)
  end

  defp runtime(opts \\ []) do
    config =
      Keyword.merge(
        [
          handler: Handler,
          dispatcher: Handler,
          handler_args: [test: self()],
          request_timeout_ms: 2000,
          max_queue: 4
        ],
        opts
      )

    root = start_supervised!({Runtime, config})
    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp message(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "read"}

  defp checkout(binding) do
    wait(fn ->
      case HTTPWriterRegistry.checkout(binding) do
        {:ok, effect, wire} -> {effect, wire}
        :empty -> nil
        error -> flunk("HTTP checkout failed: #{inspect(error)}")
      end
    end)
  end

  defp acknowledge(binding) do
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)

    receive do
      {:mcp_http_output_wake, ^domain, nonce} ->
        :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    after
      50 -> :ok
    end

    HTTPWriterRegistry.acknowledge_retirement(binding)
  end

  defp wait(fun, remaining \\ 200)
  defp wait(_fun, 0), do: flunk("HTTP gateway state not reached")

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
