defmodule Arbor.MCP.Server.Runtime.HTTPResourcesWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize

    def init(opts), do: {:ok, %{observer: opts[:observer]}}

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(params, %{
           "serverInfo" => %{"name" => "resource-wire", "version" => "2"},
           "capabilities" => %{"resources" => %{"subscribe" => true}}
         }), state}

    def handle_subscribe_resource(_uri, state), do: {:ok, %{}, state}
    def handle_unsubscribe_resource(_uri, state), do: {:ok, %{}, state}

    def handle_call_tool("publish", _args, state) do
      result = Arbor.MCP.Server.notify_resource_update("test://wire")
      send(state.observer, {:resource_wire_result, result})
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
        runtime: HTTPResourcesWireTest.Root,
        path: "/mcp",
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :stream,
        allowed_origins: :any,
        principal_id: {Identity, :principal, []},
        tenant_id: {Identity, :tenant, []}
      ]
    )

    forward("/b",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPResourcesWireTest.Root,
        path: "/mcp",
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :stream,
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

  test "actual legacy resource publication reaches the charged live stream beyond the RPC cutoff" do
    {runtime, port} = host()
    {socket, id, endpoint} = stream(port)
    assert {202, _, ""} = post(port, endpoint, initialize())
    assert {202, _, ""} = post(port, endpoint, resource(2, "resources/subscribe"))
    receive_until(socket, "\"id\":2")
    Process.sleep(350)
    assert {202, _, ""} = post(port, endpoint, publish(3))
    assert_receive {:resource_wire_result, %{subscribers: 1, delivered: 1}}
    received = receive_until(socket, "notifications/resources/updated")
    assert received =~ "test://wire"
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: events}} = SessionManager.replay_page(service, lease, nil, [])
    assert Enum.count(events, &(&1.data["method"] == "notifications/resources/updated")) == 1
    assert Enum.map(events, & &1.data["id"]) == [1, 2, nil, 3]
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "actual GET gap preserves registrations and replays one durable update before unsubscribe" do
    {runtime, port} = host()
    {socket, id, endpoint} = stream(port)
    assert {202, _, ""} = post(port, endpoint, initialize())
    assert {202, _, ""} = post(port, endpoint, resource(2, "resources/subscribe"))
    receive_until(socket, "\"id\":2")
    {service, current_lease} = lease(runtime, id)

    {:ok, %{events: [_first, subscribed]}} =
      SessionManager.replay_page(service, current_lease, nil, [])

    :gen_tcp.close(socket)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    wait(fn -> HTTPWriterRegistry.stats(domain).bindings == 0 end)
    session_headers = [{"mcp-session-id", id}]
    assert {200, _, _body} = post(port, "/a/mcp", publish(3), session_headers)
    assert_receive {:resource_wire_result, %{subscribers: 1, delivered: 0}}
    replacement = socket(port, "/a/sse", session_headers ++ [{"last-event-id", subscribed.id}])
    received = receive_until(replacement, "notifications/resources/updated")
    assert received =~ "test://wire"
    refute received =~ "\"id\":1"

    assert {200, _, _} =
             post(port, "/a/mcp", resource(4, "resources/unsubscribe"), session_headers)

    assert {200, _, _} = post(port, "/a/mcp", publish(5), session_headers)
    assert_receive {:resource_wire_result, %{subscribers: 0, delivered: 0}}
    assert {204, _, ""} = request(port, :delete, "/a/mcp", nil, session_headers)
    :gen_tcp.close(replacement)
    settled(runtime)
  end

  test "actual private resources do not cross forward prefixes or trusted-to-anonymous scope" do
    {runtime, port} = host()

    targets =
      for {prefix, headers} <- [{"a", bearer()}, {"b", bearer()}, {"a", []}] do
        {socket, id, endpoint} = stream(port, prefix, headers)
        assert {202, _, ""} = post(port, endpoint, initialize(), headers)
        assert {202, _, ""} = post(port, endpoint, resource(2, "resources/subscribe"), headers)
        receive_until(socket, "\"id\":2")
        {socket, id, endpoint, headers}
      end

    {first, _id, endpoint, headers} = hd(targets)
    assert {202, _, ""} = post(port, endpoint, publish(3), headers)
    assert_receive {:resource_wire_result, %{subscribers: 1, delivered: 1}}
    receive_until(first, "notifications/resources/updated")

    for {socket, id, _endpoint, headers} <- tl(targets) do
      {service, current_lease} = lease(runtime, id, headers)

      assert {:ok, %{events: [_first, _subscribed]}} =
               SessionManager.replay_page(service, current_lease, nil, [])

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)
    end

    Enum.each(targets, fn {socket, _, _, _} -> :gen_tcp.close(socket) end)
    settled(runtime)
  end

  defp host do
    root =
      start_supervised!(
        {Runtime,
         [
           name: HTTPResourcesWireTest.Root,
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
      [{"mcp-protocol-version", "2025-11-25"} | headers]
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

  defp resource(id, method),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => %{"uri" => "test://wire"}
    }

  defp publish(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "publish", "arguments" => %{}}
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
        Runtime.stats!(runtime).reserved == 0 and
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
