defmodule Arbor.MCP.Server.Runtime.HTTPSubscriptionStreamTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.SubscriptionListener

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Server.Subscriptions

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

  defmodule RecordingAdapter do
    alias Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Conn
    def send_resp(state, status, headers, body), do: Conn.send_resp(state, status, headers, body)

    def send_chunked(state, status, headers) do
      send(state.observer, {:stream_headers, self(), status})
      Conn.send_chunked(state, status, headers)
    end

    def chunk(state, body) do
      wire = IO.iodata_to_binary(body)
      send(state.observer, {:stream_wire, self(), wire})

      state =
        if wire == ":\r\n\r\n" and state.hold_keepalive do
          send(state.observer, {:keepalive_entered, self()})
          receive do: (:return_io -> :ok)
          %{state | hold_keepalive: false}
        else
          state
        end

      Conn.chunk(state, body)
    end
  end

  test "a queued retired source is discarded and a later fresh source reaches the same borrowed stream" do
    runtime =
      runtime(
        request_timeout_ms: 250,
        services: [subscriptions: [options: [max_lifetime_ms: 3_000]]]
      )

    socket = stream(runtime, true)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "notifications/subscriptions/acknowledged"
    assert_receive {:keepalive_entered, ^socket}, 1_000
    {source, cutoff} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}, 1_000
    eventually(fn -> match?({:ok, _effect, _wire}, HTTPWriterRegistry.peek(source)) end)
    settle(source)

    eventually(fn ->
      Enum.any?(
        elem(Process.info(socket, :messages), 1),
        &match?({:ex_mcp_subscription_ready, _, _, _}, &1)
      )
    end)

    Process.sleep(max(0, cutoff + 10 - Deadline.now()))
    send(socket, :return_io)
    # The old notification never enters physical IO after its original cutoff.
    refute_receive {:stream_wire, ^socket, "data: " <> _notification}, 20
    assert Process.alive?(socket)
    {fresh, _cutoff} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}, 1_000
    assert_receive {:stream_wire, ^socket, "data: " <> _json = notification}, 1_000
    assert notification =~ "notifications/tools/list_changed"
    settle(fresh)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    eventually(fn -> HTTPWriterRegistry.stats(domain).in_flight == 0 end)
    assert Process.alive?(socket)
  end

  test "natural listener expiry sends one fixed completion and returns after actual adapter ACK" do
    runtime = runtime(services: [subscriptions: [options: [max_lifetime_ms: 300]]])
    socket = stream(runtime, false)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "notifications/subscriptions/acknowledged"
    completion = await_completion(socket)
    assert completion =~ "\"resultType\":\"complete\""
    assert_receive {:stream_returned, ^socket, 200}, 1_000
    refute_receive {:stream_wire, ^socket, "data: " <> _duplicate}, 20
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "a notification refused by the listener's completion tail is discarded and the completion still arrives" do
    runtime = runtime(services: [subscriptions: [options: [max_lifetime_ms: 3_000]]])
    socket = stream(runtime, true)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "notifications/subscriptions/acknowledged"
    # The socket is now blocked inside a keepalive's actual IO.
    assert_receive {:keepalive_entered, ^socket}, 1_000
    {source, _cutoff} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}, 1_000
    {listener, _cutoff} = ready_listener(socket)
    # Close while the notification is in flight: the listener authorizes its
    # fixed completion (the tail) and queues it behind that notification.
    :ok = SubscriptionListener.close(listener)
    _ = :sys.get_state(listener)
    send(socket, :return_io)
    completion = await_completion(socket)
    assert completion =~ "\"resultType\":\"complete\""
    assert_receive {:stream_returned, ^socket, 200}, 1_000
    settle(source)
  end

  test "a stream parked in its listener's completion tail waits for the completion without spinning" do
    runtime =
      runtime(
        request_timeout_ms: 250,
        services: [subscriptions: [options: [max_lifetime_ms: 3_000]]]
      )

    socket = stream(runtime, true)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, _acknowledgment}, 1_000
    assert_receive {:keepalive_entered, ^socket}, 1_000
    {source, _cutoff} = publish(runtime)
    assert_receive {:published, %{enqueued: 1}, _worker}, 1_000
    {listener, cutoff} = ready_listener(socket)
    settle(source)
    :ok = SubscriptionListener.close(listener)
    _ = :sys.get_state(listener)
    # Hold the listener so the completion stays queued behind the in-flight
    # notification. That notification's own cutoff then passes, so the socket
    # retires it without asking the listener and has nothing left to write.
    :ok = :sys.suspend(listener)
    Process.sleep(max(0, cutoff + 10 - Deadline.now()))
    waits = trace_waits(socket)
    send(socket, :return_io)
    # One wait follows the returned IO and one the retired notification; every
    # other wait ends a 50 ms receive, so 300 ms allows at most 8. A retry
    # without that receive makes tens of thousands of waits in this window.
    assert collect_waits(socket, Deadline.now() + 300, 0) <= 10
    stop_trace(socket, waits)
    assert Process.alive?(socket)
    :ok = :sys.resume(listener)
    completion = await_completion(socket)
    assert completion =~ "\"resultType\":\"complete\""
    assert_receive {:stream_returned, ^socket, 200}, 1_000
  end

  defp runtime(extra) do
    root =
      start_supervised!({Runtime,
       Keyword.merge(
         [
           handler: Handler,
           handler_args: [test: self()],
           request_timeout_ms: 1_000,
           # "publish" counts in handler state; its publication commits with it.
           execution: :stateful
         ],
         extra
       )})

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp stream(runtime, hold_keepalive) do
    parent = self()

    socket =
      spawn(fn ->
        request =
          modern(%{
            "jsonrpc" => "2.0",
            "id" => 91,
            "method" => "subscriptions/listen",
            "params" => %{"notifications" => %{"toolsListChanged" => true}}
          })

        conn =
          Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("accept", "text/event-stream")
          |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
          |> Plug.Conn.put_req_header("mcp-method", "subscriptions/listen")

        {_adapter, state} = conn.adapter

        conn = %{
          conn
          | adapter:
              {RecordingAdapter,
               Map.merge(
                 state,
                 %{observer: parent, hold_keepalive: hold_keepalive}
               )}
        }

        opts =
          HttpPlug.init(
            runtime: runtime,
            protocol_mode: :modern_only,
            subscription_keepalive_interval_ms: 20
          )

        conn = HttpPlug.call(conn, opts)
        send(parent, {:stream_returned, self(), conn.status})
      end)

    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    socket
  end

  defp publish(runtime) do
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)

    request =
      modern(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => "publish", "arguments" => %{}}
      })

    assert {:ok, _token} =
             HTTPGateway.submit(runtime, binding, request,
               dispatch_opts: [endpoint: "/mcp", protocol_mode: :modern_only]
             )

    {binding, proof.deadline}
  end

  defp modern(request),
    do:
      put_in(request, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

  defp settle(binding) do
    {effect, _wire} =
      eventually(fn ->
        case HTTPWriterRegistry.checkout(binding) do
          {:ok, effect, wire} -> {effect, wire}
          _wait -> nil
        end
      end)

    HTTPWriterRegistry.complete(effect, :ok)
    HTTPWriterRegistry.retire(binding)
  end

  defp ready_listener(socket) do
    eventually(fn ->
      Enum.find_value(elem(Process.info(socket, :messages), 1), fn
        {:ex_mcp_subscription_ready, listener, _id, cutoff} -> {listener, cutoff}
        _other -> nil
      end)
    end)
  end

  defp trace_waits(socket) do
    waits = {HTTPWriterRegistry, :listener_wait_deadline, 2}
    1 = :erlang.trace_pattern(waits, true, [:global])
    1 = :erlang.trace(socket, true, [:call])
    on_exit(fn -> :erlang.trace_pattern(waits, false, [:global]) end)
    waits
  end

  defp stop_trace(socket, waits) do
    :erlang.trace(socket, false, [:call])
    :erlang.trace_pattern(waits, false, [:global])
  end

  defp collect_waits(socket, deadline, count) do
    receive do
      {:trace, ^socket, :call, {HTTPWriterRegistry, :listener_wait_deadline, _args}} ->
        collect_waits(socket, deadline, count + 1)
    after
      Deadline.remaining(deadline) -> count
    end
  end

  defp await_completion(socket) do
    receive do
      {:stream_wire, ^socket, "data: " <> _json = wire} -> wire
      {:stream_wire, ^socket, ":\r\n\r\n"} -> await_completion(socket)
    after
      1_000 -> flunk("listener completion missing")
    end
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
