defmodule Arbor.MCP.Server.Runtime.HTTPNotificationsWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.Context

    def init(opts), do: {:ok, %{observer: opts[:observer]}}

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(params, %{
           "serverInfo" => %{"name" => "resource-wire", "version" => "2"},
           "capabilities" => %{"tools" => %{}, "logging" => %{}}
         }), state}

    def handle_call_tool("progress", _args, state) do
      progress = Context.report_progress(1, 2, "working")

      log =
        if Context.current().era == :modern,
          do: Context.send_log_message(:info, "wire log"),
          else: Server.send_log_message(self(), :info, "wire log", %{})

      send(state.observer, {:control_wire_result, [progress, log]})
      {:ok, %{"content" => []}, state}
    end
  end

  defmodule Identity do
    def principal(conn, _request, _token), do: conn.assigns[:verified_principal]
    def tenant(conn, _request, _token), do: if(conn.assigns[:verified_principal], do: "team")
  end

  defmodule Router do
    use Plug.Router
    plug(:verified_identity)
    plug(:match)
    plug(:dispatch)

    defp verified_identity(conn, _opts) do
      verified = Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-token"]
      Plug.Conn.assign(conn, :verified_principal, if(verified, do: "alice"))
    end

    forward("/a",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPNotificationsWireTest.Root,
        path: "/mcp",
        protocol_mode: :prefer_modern,
        sse_mode: :stream,
        legacy_http_sse: true,
        allowed_origins: :any,
        principal_id: {Identity, :principal, []},
        tenant_id: {Identity, :tenant, []}
      ]
    )

    forward("/b",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPNotificationsWireTest.Root,
        path: "/mcp",
        protocol_mode: :prefer_modern,
        sse_mode: :stream,
        legacy_http_sse: true,
        allowed_origins: :any,
        principal_id: {Identity, :principal, []},
        tenant_id: {Identity, :tenant, []}
      ]
    )

    match(_, do: Plug.Conn.send_resp(conn, 404, "not found"))
  end

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "actual legacy progress and log remain ordered before durable final reply beyond GET entry cutoff" do
    {runtime, port} = host()
    {socket, id, endpoint} = stream(port)
    assert {202, _, ""} = post(port, endpoint, initialize())
    receive_until(socket, "\"id\":1")
    Process.sleep(350)
    assert {202, _, ""} = post(port, endpoint, progress(2))
    assert_receive {:control_wire_result, [:ok, :ok]}
    received = receive_until(socket, "\"id\":2")
    assert received =~ "notifications/progress"
    assert received =~ "notifications/message"
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: events}} = SessionManager.replay_page(service, lease, nil, [])

    assert [
             %{"id" => 1},
             %{"method" => "notifications/progress"},
             %{"method" => "notifications/message"},
             %{"id" => 2}
           ] = Enum.map(events, & &1.data)

    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "actual modern request SSE preserves progress log final ACK order without a session" do
    {runtime, port} = host()

    value =
      progress(2)
      |> put_in(["params", "_meta", "io.modelcontextprotocol/protocolVersion"], "2026-07-28")
      |> put_in(["params", "_meta", "io.modelcontextprotocol/clientCapabilities"], %{})
      |> put_in(["params", "_meta", "io.modelcontextprotocol/logLevel"], "info")

    headers = [
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "tools/call"},
      {"mcp-name", "progress"},
      {"accept", "text/event-stream"}
    ]

    assert {200, response_headers, body} = post(port, "/a/mcp", value, headers)
    refute List.keymember?(response_headers, ~c"mcp-session-id", 0)
    assert_receive {:control_wire_result, [:ok, :ok]}

    frames =
      body
      |> String.split("\r\n\r\n", trim: true)
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

    assert [
             %{"method" => "notifications/progress"},
             %{"method" => "notifications/message"},
             %{"id" => 2, "result" => _}
           ] = frames

    settled(runtime)
  end

  test "actual scoped progress never reaches another forward or its same-era session" do
    {runtime, port} = host()
    {first, id, endpoint} = stream(port, "a")
    {other, other_id, other_endpoint} = stream(port, "b")
    assert {202, _, ""} = post(port, endpoint, initialize())
    assert {202, _, ""} = post(port, other_endpoint, initialize())
    receive_until(first, "\"id\":1")
    receive_until(other, "\"id\":1")
    assert {202, _, ""} = post(port, endpoint, progress(2))
    assert_receive {:control_wire_result, [:ok, :ok]}
    receive_until(first, "\"id\":2")
    assert {:error, :timeout} = :gen_tcp.recv(other, 0, 50)
    assert {404, _, _} = post(port, "/b/mcp", progress(3), [{"mcp-session-id", id}])
    {service, lease} = lease(runtime, other_id)
    assert {:ok, %{events: [_initialize]}} = SessionManager.replay_page(service, lease, nil, [])
    :gen_tcp.close(first)
    :gen_tcp.close(other)
    settled(runtime)
  end

  defp host do
    root =
      start_supervised!(
        {Runtime,
         [
           name: HTTPNotificationsWireTest.Root,
           handler: Handler,
           handler_args: [observer: self()],
           request_timeout_ms: 300,
           services: [sessions: [options: [session_ttl_ms: 5_000]], resource_subscriptions: []]
         ]}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()
    {:ok, listener} = Plug.Cowboy.http(Router, [], port: 0, ip: {127, 0, 0, 1}, ref: ref)
    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)

    on_exit(fn ->
      monitor = Process.monitor(listener)
      assert :ok = :ranch.stop_listener(ref)
      assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 1_000

      assert {:error, :econnrefused} =
               :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    end)

    {runtime, port}
  end

  defp stream(port, prefix \\ "a", headers \\ []) do
    socket = socket(port, "/" <> prefix <> "/sse", headers)
    received = receive_until(socket, "sessionId=")
    assert received =~ "200 OK"
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, received)
    id = URI.decode_query(URI.parse(endpoint).query)["sessionId"]
    {socket, id, endpoint}
  end

  defp socket(port, path, headers) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    rendered = Enum.map_join(headers, "", fn {key, value} -> key <> ": " <> value <> "\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: text/event-stream\r\n" <>
          rendered <> "\r\n"
      )

    socket
  end

  defp post(port, endpoint, value, headers \\ []),
    do: request(port, :post, endpoint, value, headers)

  defp request(port, method, path, value, headers) do
    url = if String.starts_with?(path, "http"), do: path, else: "http://127.0.0.1:#{port}" <> path

    headers =
      if(List.keymember?(headers, "mcp-protocol-version", 0),
        do: headers,
        else: [{"mcp-protocol-version", "2025-11-25"} | headers]
      )
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    arg =
      if method == :post,
        do: {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(value)},
        else: {String.to_charlist(url), headers}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(method, arg, [timeout: 5_000, connect_timeout: 1_000], body_format: :binary)

    {status, headers, body}
  end

  defp lease(runtime, id, headers \\ []) do
    {:ok, service} = Runtime.service(runtime, :sessions)
    identity = if headers == bearer(), do: %{principal_id: "alice", tenant_id: "team"}, else: %{}
    {:ok, lease} = SessionManager.ensure_session(service, id, identity, [])
    {service, lease}
  end

  defp bearer, do: [{"authorization", "Bearer fixture-token"}]

  defp initialize,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "resource-wire", "version" => "2"}
      }
    }

  defp progress(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "wire"}
      }
    }

  defp receive_until(socket, marker, bytes \\ "") do
    if String.contains?(bytes, marker),
      do: bytes,
      else:
        (
          assert {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
          receive_until(socket, marker, bytes <> chunk)
        )
  end

  defp settled(runtime),
    do:
      wait(fn ->
        Runtime.stats(runtime).reserved == 0 and
          (HTTPWriterProxy.domain(runtime) |> elem(1) |> HTTPWriterRegistry.stats()).frames == 0
      end)

  defp wait(predicate, attempts \\ 300)
  defp wait(_predicate, 0), do: flunk("resource stream accounting did not settle")

  defp wait(predicate, attempts),
    do:
      if(predicate.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            wait(predicate, attempts - 1)
          )
      )
end
