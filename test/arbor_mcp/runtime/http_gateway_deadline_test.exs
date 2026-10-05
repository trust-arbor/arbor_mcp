defmodule Arbor.MCP.Server.Runtime.HTTPGatewayDeadlineTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    CallbackContext,
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
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 2000,
         max_queue: 4}
      )

    {:ok, runtime} = Runtime.ref(root)
    assert_receive :http_handler_init
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 40)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, %{message(7) | "method" => "hold"})
    assert_receive {:gateway_entry, 7, _worker, entered, cutoff}
    assert cutoff == proof.deadline
    assert entered < cutoff
    Process.sleep(50)
    {effect, wire} = checkout(binding)

    assert %{"id" => 7, "error" => %{"code" => -32603, "message" => "Request timeout"}} =
             Jason.decode!(wire)

    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)

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
