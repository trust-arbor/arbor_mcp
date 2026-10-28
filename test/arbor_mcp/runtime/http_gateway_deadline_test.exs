defmodule Arbor.MCP.Server.Runtime.HTTPGatewayDeadlineTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  defmodule Handler do
    def init(opts) do
      send(opts[:test], :http_handler_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def dispatch(request, _module, state, _opts) do
      context = CallbackContext.current()

      send(
        state.test,
        {:gateway_entry, request["id"], self(), System.monotonic_time(:millisecond),
         context.deadline}
      )

      if request["method"] == "hold", do: receive(do: (:finish -> :ok))

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state.count},
       %{state | count: state.count + 1}}
    end
  end

  test "one fixed charged timeout error may use the entry failure tail without reviving success" do
    # The handler counts in its state, one callback at a time.
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 2000,
         max_queue: 4,
         execution: :stateful}
      )

    {:ok, runtime} = Runtime.ref(root)
    assert_receive :http_handler_init
    # Entry is the fast step: capture, submit and dispatch must land inside
    # the cutoff, which at 40 ms they did not on a loaded machine. The held
    # call is the far-past step: it never returns on its own.
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 250)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    {:ok, token} = HTTPGateway.submit(runtime, binding, %{message(7) | "method" => "hold"})
    assert_receive {:gateway_entry, 7, _worker, entered, cutoff}
    assert cutoff == proof.deadline
    assert entered < cutoff

    # The registry wakes this writer once the timeout error is queued on the
    # failure tail. Checking out before then can land in the gap after the
    # cutoff where the invocation reads as closed.
    assert_receive {:mcp_http_output_wake, ^domain, nonce}, 2_000
    assert Deadline.now() >= cutoff
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, effect, wire} = HTTPWriterRegistry.checkout(binding)

    assert %{"id" => 7, "error" => %{"code" => -32603, "message" => "Request timeout"}} =
             Jason.decode!(wire)

    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)

    assert {:error, :http_invocation_closed} =
             HTTPWriterRegistry.prepare(binding, "{\"result\":1}")

    assert %{in_flight: 1, bytes: bytes} = HTTPWriterRegistry.stats(domain)
    assert bytes > byte_size(wire)
    gateway = trace_release(runtime)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
    # complete/2 records the receipt and wakes the registry, whose next pass
    # drops the frame. This round trip returns only after that pass.
    _ = :sys.get_state(HTTPWriterRegistry.guardian(domain))
    assert %{frames: 0} = HTTPWriterRegistry.stats(domain)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    # Once the output settles, the gateway finishes the job and frees its slot
    # with a synchronous Admission.release/2. Its return is the sync point.
    assert_receive {:trace, ^gateway, :call, {Admission, :release, [_table, ^token]}}, 2_000
    assert_receive {:trace, ^gateway, :return_from, {Admission, :release, 2}, _result}, 2_000
    assert %{reserved: 0} = Runtime.stats!(runtime)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(8))
    refute_receive :http_handler_init, 5
  end

  defp message(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "read"}

  defp trace_release(runtime) do
    {:ok, gateway} = HTTPGateway.address(runtime)
    release = {Admission, :release, 2}

    # Registered first, so the global pattern is removed even if enabling
    # the trace below fails.
    on_exit(fn ->
      :erlang.trace_pattern(release, false, [:global])
      if Process.alive?(gateway), do: :erlang.trace(gateway, false, [:call])
    end)

    assert 1 == :erlang.trace_pattern(release, [{:_, [], [{:return_trace}]}], [:global])
    assert 1 == :erlang.trace(gateway, true, [:call])
    gateway
  end
end
