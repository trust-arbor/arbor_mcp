defmodule Arbor.MCP.Server.Runtime.HTTPGatewayBorrowedIOTest do
  use ExUnit.Case, async: false
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

  # This deadline fixture must enter borrowed IO before testing its expiry.
  # Keep it serial so unrelated asynchronous test modules cannot consume the
  # original 60 ms request/30 ms output cutoffs before checkout begins.
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

  defp runtime(opts) do
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
