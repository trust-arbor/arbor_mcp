defmodule Arbor.MCP.Server.Runtime.HTTPReverseWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    ByteBudget,
    HTTPGateway,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Ref
  }

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server

    def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(params, %{
           "serverInfo" => %{"name" => "reverse-wire", "version" => "2"},
           "capabilities" => %{"tools" => %{}}
         }), state}

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}

    def handle_call_tool(control, _args, state) do
      send(state.observer, {:reverse_wire_worker, self()})

      result =
        case control do
          "ping" ->
            Server.ping(self(), 1_500)

          "roots" ->
            Server.list_roots(self(), 1_500)

          "sampling" ->
            Server.create_message(self(), %{"messages" => [], "maxTokens" => 10})

          "form" ->
            Server.elicit(
              self(),
              %{
                "message" => "Choose",
                "requestedSchema" => %{"type" => "object", "properties" => %{}}
              },
              1_500
            )

          "url" ->
            Server.elicit(
              self(),
              %{
                "mode" => "url",
                "message" => "Open",
                "url" => "https://example.com/input",
                "elicitationId" => "input-1"
              },
              1_500
            )
        end

      send(state.observer, {:reverse_wire_result, result})
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end
  end

  defmodule Router do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    forward("/a",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPReverseWireTest.Root,
        path: "/mcp",
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :stream,
        allowed_origins: :any
      ]
    )

    match(_, do: Plug.Conn.send_resp(conn, 404, "not found"))
  end

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "actual JSON requests settle roots sampling and ping through their exact live GET" do
    {runtime, port} = host()
    {200, headers, _body} = post(port, "/a/mcp", initialize())
    {_, id} = List.keyfind(headers, ~c"mcp-session-id", 0)
    id = to_string(id)
    session_headers = [{"mcp-session-id", id}]
    stream = socket(port, "/a/mcp", session_headers)
    receive_until(stream, "200 OK")
    settled(runtime)

    for {control, method, index} <- [
          {"ping", "ping", 2},
          {"roots", "roots/list", 3},
          {"sampling", "sampling/createMessage", 4}
        ] do
      caller = Task.async(fn -> post(port, "/a/mcp", tool(index, control), session_headers) end)
      assert_receive {:reverse_wire_worker, _worker}
      request = reverse_event(stream, method)
      result = %{"wire" => control}
      assert {202, _, ""} = post(port, "/a/mcp", response(request["id"], result), session_headers)
      assert_receive {:reverse_wire_result, {:ok, ^result}}
      assert {200, _, body} = Task.await(caller)
      assert Jason.decode!(body)["id"] == index
      settled(runtime)
    end

    {sessions, lease} = lease(runtime, id)
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])

    assert Enum.map(events, & &1.data["method"]) == [
             "ping",
             "roots/list",
             "sampling/createMessage"
           ]

    :gen_tcp.close(stream)
    settled(runtime)
  end

  test "actual legacy aliases durably settle form and URL elicitation before final response events" do
    {runtime, port} = host()
    {stream, id, endpoint} = stream(port)
    assert {202, _, ""} = post(port, endpoint, initialize())
    receive_until(stream, "\"id\":1")
    settled(runtime)

    for {control, index} <- [{"form", 2}, {"url", 3}] do
      caller = Task.async(fn -> post(port, endpoint, tool(index, control)) end)
      assert_receive {:reverse_wire_worker, _worker}
      request = reverse_event(stream, "elicitation/create")

      if control == "form",
        do: assert(request["params"]["requestedSchema"]["type"] == "object"),
        else: assert(request["params"]["mode"] == "url")

      assert {202, _, ""} = post(port, endpoint, response(request["id"], %{"action" => "accept"}))
      assert_receive {:reverse_wire_result, {:ok, %{"action" => "accept"}}}
      assert {202, _, ""} = Task.await(caller)
      receive_until(stream, "\"id\":#{index}")
      settled(runtime)
    end

    {sessions, lease} = lease(runtime, id)
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert length(events) == 5
    assert Enum.count(events, &(&1.data["method"] == "elicitation/create")) == 2
    :gen_tcp.close(stream)
    settled(runtime)
  end

  test "actual mixed arrays settle responses at full work capacity and preserve aggregate members" do
    {runtime, port} = host()
    {200, headers, _body} = post(port, "/a/mcp", initialize())
    {_, id} = List.keyfind(headers, ~c"mcp-session-id", 0)
    session_headers = [{"mcp-session-id", to_string(id)}]
    stream = socket(port, "/a/mcp", session_headers)
    receive_until(stream, "200 OK")
    settled(runtime)
    caller = Task.async(fn -> post(port, "/a/mcp", tool(2, "ping"), session_headers) end)
    assert_receive {:reverse_wire_worker, _worker}
    request = reverse_event(stream, "ping")

    assert {200, _, body} =
             post(
               port,
               "/a/mcp",
               [tool(3, "peek"), response(request["id"], %{"mixed" => true})],
               session_headers
             )

    assert [%{"id" => 3, "result" => %{"structuredContent" => %{"calls" => 1}}}] =
             Jason.decode!(body)

    assert_receive {:reverse_wire_result, {:ok, %{"mixed" => true}}}
    assert {200, _, _body} = Task.await(caller)
    :gen_tcp.close(stream)
    settled(runtime)
  end

  test "actual response from a different session cannot settle a same-ID reverse wait" do
    {runtime, port} = host()
    {stream, id, endpoint} = stream(port)
    assert {202, _, ""} = post(port, endpoint, initialize())
    receive_until(stream, "\"id\":1")
    settled(runtime)
    {200, headers, _body} = post(port, "/a/mcp", initialize())
    {_, other} = List.keyfind(headers, ~c"mcp-session-id", 0)
    settled(runtime)
    caller = Task.async(fn -> post(port, endpoint, tool(2, "ping")) end)
    assert_receive {:reverse_wire_worker, _worker}
    request = reverse_event(stream, "ping")

    assert {202, _, ""} =
             post(port, "/a/mcp", response(request["id"], %{"wrong" => true}), [
               {"mcp-session-id", to_string(other)}
             ])

    refute_receive {:reverse_wire_result, _result}, 20
    assert {202, _, ""} = post(port, endpoint, response(request["id"], %{"right" => true}))
    assert_receive {:reverse_wire_result, {:ok, %{"right" => true}}}
    assert {202, _, ""} = Task.await(caller)
    receive_until(stream, "\"id\":2")
    {sessions, lease} = lease(runtime, id)

    assert {:ok, %{events: [_initialize, _request, _result]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    :gen_tcp.close(stream)
    settled(runtime)
  end

  test "actual nested response member returns invalid request without replacing runtime actors" do
    {runtime, port} = host()
    {200, headers, _body} = post(port, "/a/mcp", initialize())
    {_, id} = List.keyfind(headers, ~c"mcp-session-id", 0)
    session_headers = [{"mcp-session-id", to_string(id)}]
    settled(runtime)
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    {:ok, gateway} = HTTPGateway.address(runtime)

    assert {200, _, body} =
             post(port, "/a/mcp", [[response(7, %{})]], session_headers)

    assert [%{"id" => nil, "error" => %{"code" => -32600}}] = Jason.decode!(body)
    settled(runtime)
    assert {200, _, body} = post(port, "/a/mcp", tool(8, "peek"), session_headers)
    assert Jason.decode!(body)["result"]["structuredContent"]["calls"] == 0
    settled(runtime)
    assert {:ok, same} = Admission.route(table)
    assert same.admission == route.admission and same.generation == route.generation
    assert Process.alive?(route.admission) and Process.alive?(gateway)
    assert ByteBudget.used(table).incoming == 0
    assert Runtime.stats!(runtime).response_bytes == 0
  end

  defp host do
    root =
      start_supervised!(
        {Runtime,
         [
           name: HTTPReverseWireTest.Root,
           handler: Handler,
           handler_args: [observer: self()],
           request_timeout_ms: 2_000,
           max_concurrency: 1,
           max_queue: 0,
           services: [sessions: [options: [session_ttl_ms: 10_000]]]
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

      assert {:error, reason} =
               :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

      # Linux can reset an in-flight loopback handshake after listener DOWN.
      # Both failures prove this probe obtained no live connection.
      assert reason in [:econnrefused, :econnreset]

      root_monitor = Process.monitor(root)
      if Process.alive?(root), do: assert(Runtime.stop(root) == :ok)
      assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, 1_000
    end)

    {runtime, port}
  end

  defp reverse_event(socket, method) do
    bytes = receive_until(socket, method)

    event =
      for [_, data] <- Regex.scan(~r/data: ([^\n]+)/, bytes),
          {:ok, message} <- [Jason.decode(data)],
          message["method"] == method,
          do: message

    assert [request | _] = event
    request
  end

  defp initialize,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "reverse-wire", "version" => "2"},
        "capabilities" => %{}
      }
    }

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

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

    on_exit(fn ->
      :gen_tcp.close(socket)
      assert Port.info(socket) == nil
    end)

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
    # A held request and its reverse reply must use physically independent
    # HTTP/1 connections. Every call owns a fresh TCP socket; no HTTPc profile
    # or persistent connection queue can serialize a reply behind its origin.
    uri = URI.parse(path)
    path = if uri.host, do: uri.path <> if(uri.query, do: "?" <> uri.query, else: ""), else: path
    body = if method == :post, do: Jason.encode!(value), else: ""
    headers = [{"mcp-protocol-version", "2025-11-25"} | headers]
    rendered = Enum.map_join(headers, "", fn {key, value} -> key <> ": " <> value <> "\r\n" end)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    deadline = System.monotonic_time(:millisecond) + 5_000

    try do
      :ok =
        :gen_tcp.send(
          socket,
          String.upcase(Atom.to_string(method)) <>
            " #{path} HTTP/1.1\r\n" <>
            "Host: 127.0.0.1:#{port}\r\nConnection: close\r\n" <>
            "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n" <>
            rendered <> "\r\n" <> body
        )

      http_response(socket, "", deadline)
    after
      :gen_tcp.close(socket)
      assert Port.info(socket) == nil
    end
  end

  defp http_response(socket, bytes, deadline) do
    case :binary.split(bytes, "\r\n\r\n") do
      [header, body] ->
        [status | headers] = String.split(header, "\r\n")
        [_, code] = Regex.run(~r/^HTTP\/1\.[01] ([0-9]+)/, status)

        headers =
          Enum.map(headers, fn header ->
            [key, value] = String.split(header, ":", parts: 2)

            {String.downcase(key) |> String.to_charlist(),
             String.trim(value) |> String.to_charlist()}
          end)

        {_, length} = List.keyfind(headers, ~c"content-length", 0)
        length = length |> to_string() |> String.to_integer()

        if byte_size(body) >= length,
          do: {String.to_integer(code), headers, binary_part(body, 0, length)},
          else: http_response(socket, bytes <> recv_http(socket, deadline), deadline)

      [_partial] ->
        http_response(socket, bytes <> recv_http(socket, deadline), deadline)
    end
  end

  defp recv_http(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, remaining)
    bytes
  end

  defp lease(runtime, id) do
    {:ok, service} = Runtime.service(runtime, :sessions)
    identity = %{}
    {:ok, lease} = SessionManager.ensure_session(service, id, identity, [])
    {service, lease}
  end

  defp receive_until(socket, marker, bytes \\ "", deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if String.contains?(bytes, marker) do
      bytes
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0
      assert {:ok, chunk} = :gen_tcp.recv(socket, 0, remaining)
      receive_until(socket, marker, bytes <> chunk, deadline)
    end
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
