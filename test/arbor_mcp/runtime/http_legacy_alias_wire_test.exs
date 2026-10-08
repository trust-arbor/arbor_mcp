defmodule Arbor.MCP.Server.Runtime.HTTPLegacyAliasWireTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize

    def init(opts) do
      send(opts[:observer], :wire_alias_initialized)
      {:ok, %{count: 0}}
    end

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(
           params,
           %{"serverInfo" => %{"name" => "alias-wire", "version" => "2"}, "capabilities" => %{}}
         ), state}

    def handle_call_tool("count", _args, state),
      do:
        {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
         %{state | count: state.count + 1}}

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}}, state}

    def handle_call_tool("crash", _args, _state), do: raise("fixed alias wire failure")
  end

  defmodule Router do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    forward("/a",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPLegacyAliasWireTest.Root,
        path: "/mcp",
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :stream,
        allowed_origins: :any
      ]
    )

    forward("/b",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPLegacyAliasWireTest.Root,
        path: "/mcp",
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :stream,
        allowed_origins: :any
      ]
    )

    forward("/primary",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPLegacyAliasWireTest.Root,
        path: "/sse",
        protocol_mode: :legacy_only,
        legacy_http_sse: false,
        sse_mode: :stream,
        allowed_origins: :any
      ]
    )

    forward("/postprimary",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPLegacyAliasWireTest.Root,
        path: "/message",
        protocol_mode: :prefer_modern,
        legacy_http_sse: true,
        sse_mode: :stream,
        allowed_origins: :any
      ]
    )

    forward("/postroot",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPLegacyAliasWireTest.Root,
        path: "/mcp",
        protocol_mode: :prefer_modern,
        legacy_http_sse: true,
        legacy_http_sse_post_path: "/",
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

  test "actual endpoint stream outlives the RPC cutoff and responses are durable before202" do
    {runtime, port} = host(request_timeout_ms: 200)
    {socket, id, endpoint} = open_stream(port)
    assert endpoint =~ "/a/message?sessionId="
    assert_receive :wire_alias_initialized
    refute_receive :wire_alias_initialized, 5
    Process.sleep(250)
    assert {202, _, ""} = post(port, endpoint, initial())
    {service, lease} = lease(runtime, id)
    assert {:ok, %{initialized: true}} = SessionManager.get_session(service, lease, [])
    assert {:ok, %{events: [%{data: %{"id" => 1}}]}} = replay(service, lease)
    receive_until(socket, "\"id\":1")
    assert {202, _, ""} = post(port, endpoint, tool(2))
    assert {:ok, %{events: [_, %{data: second}]}} = replay(service, lease)
    assert second["result"]["structuredContent"]["count"] == 0
    receive_until(socket, "\"id\":2")
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "physical complete batch has one ordered replay event and a failed array has none" do
    {runtime, port} = host()
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    receive_until(socket, "\"id\":1")
    notice = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert {202, _, ""} = post(port, endpoint, [tool(2), notice, 17, tool(3)])
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: [_, %{data: array}]}} = replay(service, lease)
    assert [%{"id" => 2}, %{"id" => nil}, %{"id" => 3}] = array
    assert hd(array)["result"]["structuredContent"]["count"] == 0
    assert List.last(array)["result"]["structuredContent"]["count"] == 1
    receive_until(socket, "\"id\":3")
    assert {500, _, _} = post(port, endpoint, [tool(4), tool(5, "crash")])
    assert {:ok, %{events: [_, _]}} = replay(service, lease)
    assert {202, _, ""} = post(port, endpoint, tool(6))
    assert {:ok, %{events: [_, _, %{data: last}]}} = replay(service, lease)
    assert last["result"]["structuredContent"]["count"] == 3
    receive_until(socket, "\"id\":6")
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "reconnect uses Last-Event-ID while equal root forward B cannot use the lease" do
    {runtime, port} = host()
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    assert {202, _, ""} = post(port, endpoint, tool(2))
    {service, lease} = lease(runtime, id)
    {:ok, %{events: [first, _]}} = replay(service, lease)
    headers = [{"mcp-session-id", id}, {"last-event-id", first.id}]
    replacement = open_socket(port, "/a/sse", headers)
    replayed = receive_until(replacement, "\"id\":2")
    refute replayed =~ "\"id\":1"
    assert {404, _, _} = request(port, :get, "/b/sse", nil, headers)
    assert {404, _, _} = post(port, String.replace(endpoint, "/a/message", "/b/message"), tool(3))
    assert {202, _, ""} = post(port, endpoint, tool(4))
    receive_until(replacement, "\"id\":4")
    :gen_tcp.close(socket)
    :gen_tcp.close(replacement)
    settled(runtime)
  end

  test "physical initialization array settles the exact session claim before durable202" do
    {runtime, port} = host()
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, [initial(), tool(2)])
    {service, lease} = lease(runtime, id)

    assert {:ok, %{initialized: true, initialization_claimed: false}} =
             SessionManager.get_session(service, lease, [])

    assert {:ok, %{events: [%{data: [%{"id" => 1}, %{"id" => 2}]}]}} = replay(service, lease)
    receive_until(socket, "\"id\":2")
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "physical saturation rejects before state commit without a false durable202" do
    {runtime, port} =
      host(services: [sessions: [options: [max_events: 1, max_events_per_session: 1]]])

    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    receive_until(socket, "\"id\":1")
    assert {500, _, body} = post(port, endpoint, tool(2))
    assert Jason.decode!(body)["error"]["code"] == -32603
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: [_]}} = replay(service, lease)
    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(service, [])
    assert {:ok, response} = Runtime.request(runtime, tool(3, "peek"))
    assert response["result"]["structuredContent"]["count"] == 0
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "a physically failed callback returns500 and leaves prior durable state usable" do
    {runtime, port} = host()
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    receive_until(socket, "\"id\":1")
    assert {202, _, ""} = post(port, endpoint, tool(2))
    receive_until(socket, "\"id\":2")
    assert {500, _, body} = post(port, endpoint, tool(3, "crash"))
    assert Jason.decode!(body)["error"]["code"] == -32603
    assert {202, _, ""} = post(port, endpoint, tool(4))
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: [_, _, %{data: last}]}} = replay(service, lease)
    assert last["result"]["structuredContent"]["count"] == 1
    receive_until(socket, "\"id\":4")
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "the literal2024 protocol negotiates and receives deprecated transport messages" do
    {runtime, port} = host()
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial("2024-11-05"), "2024-11-05")
    received = receive_until(socket, "\"protocolVersion\":\"2024-11-05\"")
    assert received =~ "event: message"
    assert {202, _, ""} = post(port, endpoint, tool(2), "2024-11-05")
    receive_until(socket, "\"id\":2")
    {service, lease} = lease(runtime, id)

    assert {:ok, %{protocol_version: "2024-11-05"}} =
             SessionManager.get_session(service, lease, [])

    assert {:ok, %{events: [_, _]}} = replay(service, lease)
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "the established physical stream ends at its original session lifetime" do
    {runtime, port} =
      host(request_timeout_ms: 200, services: [sessions: [options: [session_ttl_ms: 600]]])

    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    receive_until(socket, "\"id\":1")
    Process.sleep(250)
    assert {202, _, ""} = post(port, endpoint, tool(2))
    receive_until(socket, "\"id\":2")
    assert :complete == wait_complete(socket)
    # Session activity may renew its lease; it cannot renew the old stream.
    assert {202, _, ""} = post(port, endpoint, tool(3))
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, _lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "physical alias DELETE closes the addressed stream and modern alias methods have no setup effects" do
    {runtime, port} = host()
    modern_headers = [{"mcp-protocol-version", "2026-07-28"}]

    for method <- [:get, :delete] do
      assert {405, _, _} = request(port, method, "/a/sse", nil, modern_headers)
    end

    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    {socket, id, endpoint} = open_stream(port)
    assert {202, _, ""} = post(port, endpoint, initial())
    receive_until(socket, "\"id\":1")
    headers = [{"mcp-session-id", id}, {"mcp-protocol-version", "2025-11-25"}]
    assert {204, _, ""} = request(port, :delete, "/a/sse", nil, headers)
    assert :complete == wait_complete(socket)
    assert {404, _, _} = post(port, endpoint, tool(2))
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "actual configured primary SSE path remains addressed with aliases disabled" do
    {runtime, port} = host()
    assert {400, _, _} = request(port, :get, "/primary/sse", nil, [])
    assert {200, headers, _body} = post(port, "/primary/sse", initial())
    id = headers |> List.keyfind(~c"mcp-session-id", 0) |> elem(1) |> to_string()
    headers = [{"mcp-session-id", id}, {"mcp-protocol-version", "2025-11-25"}]
    socket = open_socket(port, "/primary/sse", headers)
    response = receive_until(socket, "\r\n\r\n")
    assert response =~ "200"
    refute response =~ "event: endpoint"
    assert {204, _, ""} = request(port, :delete, "/primary/sse", nil, headers)
    assert :complete = wait_complete(socket, response)
    :gen_tcp.close(socket)
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "actual enabled alias configuration preserves primary POST legacy and modern envelopes" do
    {runtime, port} = host()

    for path <- ["/postprimary/message", "/postroot"] do
      {:ok, sessions} = Runtime.service(runtime, :sessions)
      {:ok, %{sessions: before_count}} = SessionManager.get_stats(sessions, [])
      alias_get = if path == "/postroot", do: "/postroot/sse", else: "/postprimary/sse"
      assert {400, _, rejected} = request(port, :get, alias_get, nil, [])

      assert Jason.decode!(rejected)["error"]["message"] ==
               "Legacy SSE requires a distinct POST alias path"

      assert {:ok, %{sessions: ^before_count}} = SessionManager.get_stats(sessions, [])
      assert {200, headers, body} = post(port, path, initial())
      assert Jason.decode!(body)["result"]["protocolVersion"] == "2025-11-25"
      assert List.keyfind(headers, ~c"mcp-session-id", 0)

      discover = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "server/discover",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      headers = [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", "server/discover"}]
      assert {200, returned_headers, result} = request(port, :post, path, discover, headers)
      assert Jason.decode!(result)["id"] == 9
      refute List.keyfind(returned_headers, ~c"mcp-session-id", 0)
    end

    settled(runtime)
  end

  defp host(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             name: HTTPLegacyAliasWireTest.Root,
             handler: Handler,
             handler_args: [observer: self()],
             request_timeout_ms: 2_000,
             services: [sessions: [options: [session_ttl_ms: 5_000]]]
           ],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()
    {:ok, _listener} = Plug.Cowboy.http(Router, [], port: 0, ip: {127, 0, 0, 1}, ref: ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    {runtime, port}
  end

  defp open_stream(port) do
    socket = open_socket(port, "/a/sse")
    received = receive_until(socket, "sessionId=")
    assert received =~ "200 OK"
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, received)
    id = URI.decode_query(URI.parse(endpoint).query)["sessionId"]
    {socket, id, endpoint}
  end

  defp open_socket(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    rendered = Enum.map_join(headers, "", fn {k, v} -> k <> ": " <> v <> "\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: text/event-stream\r\n" <>
          rendered <> "\r\n"
      )

    socket
  end

  defp post(port, endpoint, value, version \\ "2025-11-25"),
    do: request(port, :post, endpoint, value, [{"mcp-protocol-version", version}])

  defp request(port, method, path, value, headers) do
    url = if String.starts_with?(path, "http"), do: path, else: "http://127.0.0.1:#{port}" <> path
    headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    arg =
      if method == :post,
        do: {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(value)},
        else: {String.to_charlist(url), headers}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(method, arg, [timeout: 5_000, connect_timeout: 1_000], body_format: :binary)

    {status, headers, body}
  end

  defp lease(runtime, id) do
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])
    {service, lease}
  end

  defp replay(service, lease), do: SessionManager.replay_page(service, lease, nil, [])

  defp initial(version \\ "2025-11-25"),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "alias-wire", "version" => "2"}
      }
    }

  defp tool(id, name \\ "count"),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp receive_until(socket, marker, acc \\ "") do
    if String.contains?(acc, marker) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, bytes} -> receive_until(socket, marker, acc <> bytes)
        failure -> flunk("alias stream did not deliver expected marker: #{inspect(failure)}")
      end
    end
  end

  # Cowboy may retain a keepalive TCP connection after the chunked response
  # finishes. The zero-length final chunk proves the stream ended.
  defp wait_complete(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} ->
        bytes = acc <> chunk

        if String.ends_with?(bytes, "0\r\n\r\n"),
          do: :complete,
          else: wait_complete(socket, bytes)

      failure ->
        flunk("original listener lifetime did not end the response: #{inspect(failure)}")
    end
  end

  defp settled(runtime, attempts \\ 200)
  defp settled(_runtime, 0), do: flunk("alias IO or admission credits did not settle")

  defp settled(runtime, attempts) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    if Runtime.stats!(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0,
      do: :ok,
      else:
        (
          Process.sleep(5)
          settled(runtime, attempts - 1)
        )
  end
end
