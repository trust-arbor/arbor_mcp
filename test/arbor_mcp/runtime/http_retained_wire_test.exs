defmodule Arbor.MCP.Server.Runtime.HTTPRetainedWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.HTTPRetainedSessionTest.Handler

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "physical GET replay and DELETE preserve one root-addressed session epoch" do
    {runtime, port} = host()
    {id, service, lease} = initialize(runtime, port)
    {:ok, first} = SessionManager.append_event(service, lease, "message", %{"seq" => 1}, [])
    assert {200, _, handshake} = request(port, :get, nil, session_headers(id))
    assert handshake =~ "event: connected"
    refute handshake =~ "\"seq\":1"
    {:ok, second} = SessionManager.append_event(service, lease, "message", %{"seq" => 2}, [])
    headers = [{~c"last-event-id", String.to_charlist(first.id)} | session_headers(id)]
    assert {200, _, replay} = request(port, :get, nil, headers)
    assert replay =~ "id: #{second.id}\nevent: message\ndata: {\"seq\":2}"
    assert {204, _, ""} = request(port, :delete, nil, session_headers(id))
    assert {404, _, _} = request(port, :get, nil, session_headers(id))

    assert {:ok, %{sessions: 0, events: 0, request_ids: 0}} =
             SessionManager.get_stats(service, [])
  end

  test "physical stream delivers live replay and DELETE ends only that stream" do
    {runtime, port} = host(sse_mode: :stream)
    {id, service, lease} = initialize(runtime, port)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, get_wire(port, id))
    initial = receive_until(socket, "event: connected")
    assert initial =~ "200 OK"
    {:ok, event} = SessionManager.append_event(service, lease, "message", %{"live" => true}, [])
    live = receive_until(socket, "\"live\":true")
    assert live =~ "id: #{event.id}"
    assert {204, _, ""} = request(port, :delete, nil, session_headers(id))
    assert receive_until(socket, "0\r\n\r\n") =~ "0\r\n\r\n"
    assert {:ok, fresh} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :gen_tcp.close(fresh)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
  end

  test "physical stream disconnection preserves the initialized session for reconnect" do
    {runtime, port} = host(sse_mode: :stream)
    {id, service, lease} = initialize(runtime, port)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, get_wire(port, id))
    assert receive_until(socket, "event: connected") =~ "200 OK"
    :gen_tcp.close(socket)

    {:ok, event} =
      SessionManager.append_event(service, lease, "message", %{"retained" => true}, [])

    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    assert event.session_id == id
    assert {204, _, ""} = request(port, :delete, nil, session_headers(id))
  end

  test "physical replay cursor errors retain status and never start an SSE response" do
    {runtime, port} = host()
    {id, service, lease} = initialize(runtime, port)
    {:ok, foreign} = SessionManager.create_session(service, %{}, [])
    {:ok, event} = SessionManager.append_event(service, foreign, "message", %{}, [])

    for cursor <- ["unknown", event.id] do
      headers = [{~c"last-event-id", String.to_charlist(cursor)} | session_headers(id)]
      assert {400, response_headers, body} = request(port, :get, nil, headers)
      assert Jason.decode!(body)["error"]["code"] == -32600

      refute List.keyfind(response_headers, ~c"content-type", 0) ==
               {~c"content-type", ~c"text/event-stream"}
    end

    assert {:ok, _} = SessionManager.get_session(service, lease, [])
  end

  defp host(plug_extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         [
           handler: Handler,
           handler_args: [],
           request_timeout_ms: 1_000,
           services: [sessions: [options: [max_replay_page_events: 1]]]
         ]}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()

    plug_opts =
      Keyword.merge(
        [runtime: runtime, protocol_mode: :legacy_only, sse_mode: :oneshot],
        plug_extra
      )

    {:ok, _listener} =
      Plug.Cowboy.http(HttpPlug, plug_opts, port: 0, ip: {127, 0, 0, 1}, ref: ref)

    on_exit(fn -> :ranch.stop_listener(ref) end)
    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    {runtime, port}
  end

  defp initialize(runtime, port) do
    value = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "retained-wire", "version" => "2"}
      }
    }

    {200, headers, _body} = request(port, :post, value)
    {_, chars} = List.keyfind(headers, ~c"mcp-session-id", 0)
    id = List.to_string(chars)
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    {id, service, lease}
  end

  defp request(port, method, value, headers \\ []) do
    url = String.to_charlist("http://127.0.0.1:#{port}/mcp")

    data =
      if method == :post,
        do: {url, headers, ~c"application/json", Jason.encode!(value)},
        else: {url, headers}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(method, data, [timeout: 5_000, connect_timeout: 1_000], body_format: :binary)

    {status, headers, body}
  end

  defp session_headers(id),
    do: [
      {~c"mcp-session-id", String.to_charlist(id)},
      {~c"mcp-protocol-version", ~c"2025-11-25"},
      {~c"accept", ~c"text/event-stream"}
    ]

  defp get_wire(port, id),
    do:
      "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" <>
        "MCP-Session-Id: #{id}\r\nMCP-Protocol-Version: 2025-11-25\r\nAccept: text/event-stream\r\n\r\n"

  defp receive_until(socket, marker, acc \\ "", attempts \\ 20)
  defp receive_until(_socket, _marker, _acc, 0), do: flunk("physical SSE frame was not received")

  defp receive_until(socket, marker, acc, attempts) do
    if String.contains?(acc, marker),
      do: acc,
      else:
        (case :gen_tcp.recv(socket, 0, 1_000) do
           {:ok, chunk} -> receive_until(socket, marker, acc <> chunk, attempts - 1)
           error -> flunk("physical SSE ended before expected frame: #{inspect(error)}")
         end)
  end
end
