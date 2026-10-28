defmodule Arbor.MCP.Server.Runtime.HTTPStreamDisconnectTest do
  # A client that closes the connection carrying a request's event stream.
  # The legacy Streamable HTTP revisions say the server SHOULD NOT take that
  # for a cancellation, so a legacy request runs to its end and its response,
  # which no stream can carry any more, is released. A modern request is
  # cancelled with its stream, as before.
  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]
  import ExUnit.CaptureLog

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry, Ref}

  @legacy "2025-11-25"
  @modern "2026-07-28"

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    def handle_call_tool("hold", _args, state) do
      send(state.owner, {:holding, self(), Context.report_progress(1, 3)})
      hold(state)
    end

    def handle_call_tool("ping", _args, state), do: {:ok, %{content: []}, state}

    defp hold(state) do
      receive do
        :report ->
          send(state.owner, {:reported, self(), Context.report_progress(2, 3)})
          hold(state)

        :release ->
          send(state.owner, {:finishing, self(), Context.cancelled?()})
          {:ok, %{content: []}, state}
      after
        5_000 -> {:error, "the test did not release the tool", state}
      end
    end
  end

  setup do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [owner: self()],
         transport: :mounted_http,
         protocol_mode: :prefer_modern}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: {HttpPlug, [runtime: root, path: "/mcp", protocol_mode: :prefer_modern]},
       options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]}
    )

    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    %{runtime: runtime, port: port}
  end

  test "a legacy request whose stream's client went away runs to its end",
       %{runtime: runtime, port: port} do
    session = legacy_session(port)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}]

    log =
      capture_log(fn ->
        {worker, monitor} = disconnect_while_holding(runtime, port, hold(2, %{}), headers)

        send(worker, :release)
        assert_receive {:finishing, ^worker, false}, 2_000
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
        settled(runtime)
      end)

    refute log =~ "[error]"

    # The session and the runtime go on serving.
    assert {200, body} = post(port, call(3, "ping", %{}), headers)
    assert %{"id" => 3, "result" => _result} = Jason.decode!(body)
  end

  test "a modern request is cancelled with its stream", %{runtime: runtime, port: port} do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    headers = [
      {"mcp-protocol-version", @modern},
      {"mcp-method", "tools/call"},
      {"mcp-name", "hold"}
    ]

    {worker, monitor} = disconnect_while_holding(runtime, port, hold(2, meta), headers)
    send(worker, :release)

    # Cancelled: it sees so when released, or it was already stopped.
    receive do
      {:finishing, ^worker, cancelled?} -> assert cancelled?
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      2_000 -> flunk("the modern request was neither cancelled nor stopped")
    end

    settled(runtime)
  end

  # Opens the request's event stream, reads its first progress and closes
  # the connection. Returns once the connection's request process has exited
  # and the gateway has handled that exit. A progress sent after the close
  # makes the request process notice it, if the server hasn't yet.
  defp disconnect_while_holding(runtime, port, request, headers) do
    socket = open_stream(port, request, headers)
    assert_receive {:holding, worker, :ok}, 2_000
    monitor = Process.monitor(worker)
    assert read_until(socket, "notifications/progress") =~ "text/event-stream"

    [{:http_gateway, gateway}] = :ets.lookup(Ref.table(runtime), :http_gateway)

    # The held request's job; an earlier POST's may still be settling.
    [writer] =
      for {_token, job} <- :sys.get_state(gateway).jobs,
          not job.notification_only? and not job.done?,
          do: job.socket

    writer_monitor = Process.monitor(writer)

    :ok = :gen_tcp.close(socket)
    send(worker, :report)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}, 2_000
    _state = :sys.get_state(gateway)
    {worker, monitor}
  end

  defp legacy_session(port) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "disconnect", "version" => "1"}
      }
    }

    {:ok, {{_, 200, _}, headers, _body}} =
      httpc(port, initialize, [{"mcp-protocol-version", @legacy}])

    {_key, session} = List.keyfind(headers, ~c"mcp-session-id", 0)
    session = to_string(session)
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    {:ok, {{_, 202, _}, _headers, _body}} =
      httpc(port, notification, [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}])

    session
  end

  defp hold(id, meta),
    do: call(id, "hold", Map.put(meta, "progressToken", "held"))

  defp call(id, name, meta),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}, "_meta" => meta}
    }

  defp open_stream(port, value, headers) do
    body = Jason.encode!(value)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    rendered = Enum.map_join(headers, "", fn {name, value} -> name <> ": " <> value <> "\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Type: application/json\r\n" <>
          "Accept: application/json, text/event-stream\r\n" <>
          rendered <> "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      )

    socket
  end

  defp post(port, value, headers) do
    {:ok, {{_, status, _}, _headers, body}} = httpc(port, value, headers)
    {status, body}
  end

  defp httpc(port, value, headers) do
    headers =
      Enum.map([{"accept", "application/json"} | headers], fn {key, value} ->
        {to_charlist(key), to_charlist(value)}
      end)

    :httpc.request(
      :post,
      {~c"http://127.0.0.1:#{port}/mcp", headers, ~c"application/json", Jason.encode!(value)},
      [timeout: 5_000, connect_timeout: 1_000],
      body_format: :binary
    )
  end

  defp settled(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    wait_until(
      fn ->
        Runtime.stats!(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0
      end,
      timeout: 3_000
    )
  end

  defp read_until(socket, marker, bytes \\ "") do
    if String.contains?(bytes, marker) do
      bytes
    else
      assert {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, marker, bytes <> chunk)
    end
  end
end
