defmodule Arbor.MCP.Server.Runtime.HTTPLegacyAliasTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize

    def init(opts) do
      send(opts[:observer], :alias_initialized)
      {:ok, %{count: 0, observer: opts[:observer]}}
    end

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(
           params,
           %{"serverInfo" => %{"name" => "aliases", "version" => "2"}, "capabilities" => %{}}
         ), state}

    def handle_call_tool("count", _args, state),
      do:
        {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
         %{state | count: state.count + 1}}

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}}, state}

    def handle_call_tool("crash", _args, _state), do: raise("fixed alias test failure")
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "legacy endpoint handshake creates an addressed session without per-request handler init" do
    {runtime, opts} = host()
    get = get(opts)
    assert get.status == 200
    assert get.resp_body =~ "event: endpoint\ndata: http://www.example.com/message?sessionId="
    refute get.resp_body =~ "event: connected"
    id = session_id(get)
    {service, lease} = lease(runtime, id)
    assert {:ok, %{initialized: false}} = SessionManager.get_session(service, lease, [])
    assert_receive :alias_initialized
    refute_receive :alias_initialized, 5
    settled(runtime)
  end

  test "initialize is durable before202 and subsequent POSTs share the same state" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202, resp_body: ""} = post(opts, id, initial())
    {service, lease} = lease(runtime, id)

    assert {:ok, %{initialized: true, protocol_version: "2025-11-25"}} =
             SessionManager.get_session(service, lease, [])

    assert %{status: 202, resp_body: ""} = post(opts, id, tool(2))
    assert %{status: 202, resp_body: ""} = post(opts, id, tool(3))
    assert {:ok, %{events: events}} = SessionManager.replay_page(service, lease, nil, [])
    assert Enum.map(events, & &1.data["id"]) == [1, 2, 3]
    assert Enum.map(tl(events), & &1.data["result"]["structuredContent"]["count"]) == [0, 1]
    refute_received {:alias_initialized, _}
    settled(runtime)
  end

  test "complete legacy array is one event with invalid ordering and notification omission" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    notice = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert %{status: 202} = post(opts, id, [tool(2), notice, 17, tool(3)])
    {service, lease} = lease(runtime, id)

    assert {:ok, %{events: [_initial, %{data: output}]}} =
             SessionManager.replay_page(service, lease, nil, [])

    assert [%{"id" => 2}, %{"id" => nil, "error" => %{"code" => -32600}}, %{"id" => 3}] = output
    assert hd(output)["result"]["structuredContent"]["count"] == 0
    assert List.last(output)["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "same-forward default and configured aliases keep one session/replay domain" do
    {runtime, opts} = host(legacy_http_sse_path: "/events", legacy_http_sse_post_path: "/inbox")
    hello = get(opts, "/a/events", prefix: ["a"], relative: ["events"])
    assert hello.resp_body =~ "http://www.example.com/a/inbox?sessionId="
    id = session_id(hello)

    assert %{status: 202} =
             post(opts, id, initial(), "/a/inbox", prefix: ["a"], relative: ["inbox"])

    assert %{status: 202} =
             post(opts, id, tool(2), "/a/inbox", prefix: ["a"], relative: ["inbox"])

    {service, lease} = lease(runtime, id)
    {:ok, %{events: [first, _]}} = SessionManager.replay_page(service, lease, nil, [])

    resumed =
      get(opts, "/a/events",
        prefix: ["a"],
        relative: ["events"],
        headers: [{"mcp-session-id", id}, {"last-event-id", first.id}]
      )

    assert resumed.status == 200
    assert resumed.resp_body =~ "\"id\":2"

    wrong =
      get(opts, "/b/events",
        prefix: ["b"],
        relative: ["events"],
        headers: [{"mcp-session-id", id}, {"last-event-id", first.id}]
      )

    assert wrong.status == 404
    settled(runtime)
  end

  test "query and header identity conflict rejects before initialization effects" do
    {runtime, opts} = host()
    first = opts |> get() |> session_id()
    second = opts |> get() |> session_id()
    rejected = post(opts, first, initial(), "/message", headers: [{"mcp-session-id", second}])
    assert rejected.status == 400
    {service, lease} = lease(runtime, first)
    assert {:ok, %{initialized: false}} = SessionManager.get_session(service, lease, [])
    assert {:ok, %{events: []}} = SessionManager.replay_page(service, lease, nil, [])
    assert %{status: 202} = post(opts, first, initial())
    settled(runtime)
  end

  test "terminal callback failure remains retired after actual return and never repeats earlier state" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    assert %{status: 202} = post(opts, id, tool(2))
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    guardian = HTTPWriterRegistry.guardian(domain)
    :sys.suspend(guardian)

    try do
      failed = post(opts, id, tool(3, "crash"))
      assert failed.status == 500
      assert Jason.decode!(failed.resp_body)["error"]["code"] == -32603
      # Physical return was recorded while guardian maintenance was paused.
      # Retire cannot release a receipt that has not yet been reaped.
      assert %{frames: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    after
      :sys.resume(guardian)
    end

    send(guardian, :reap)
    _barrier = :sys.get_state(guardian)
    assert %{bindings: 0, frames: 0, in_flight: 0} = HTTPWriterRegistry.stats(domain)
    {service, lease} = lease(runtime, id)

    assert {:ok, %{events: [_initial, _count]}} =
             SessionManager.replay_page(service, lease, nil, [])

    assert %{status: 202} = post(opts, id, tool(4))
    assert {:ok, %{events: [_, _, event]}} = SessionManager.replay_page(service, lease, nil, [])
    assert event.data["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "initialization array settles one exact claim before the complete replay event" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, [initial(), tool(2)])
    {service, lease} = lease(runtime, id)

    assert {:ok, %{initialized: true, initialization_claimed: false}} =
             SessionManager.get_session(service, lease, [])

    assert {:ok, %{events: [%{data: [%{"id" => 1}, %{"id" => 2}]}]}} =
             SessionManager.replay_page(service, lease, nil, [])

    assert %{status: 202} = post(opts, id, tool(3))
    assert {:ok, %{events: [_, last]}} = SessionManager.replay_page(service, lease, nil, [])
    assert last.data["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "failed final array preserves earlier state and never publishes a partial event" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    assert %{status: 500} = post(opts, id, [tool(2), tool(3, "crash")])
    {service, lease} = lease(runtime, id)
    assert {:ok, %{events: [_initial]}} = SessionManager.replay_page(service, lease, nil, [])
    assert %{status: 202} = post(opts, id, tool(4))
    assert {:ok, %{events: [_, last]}} = SessionManager.replay_page(service, lease, nil, [])
    assert last.data["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "notification-only array continues after accepted202 without durable response fabrication" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    notice = Map.delete(tool(2), "id")
    assert %{status: 202, resp_body: ""} = post(opts, id, [notice, notice])
    settled(runtime)
    assert %{status: 202} = post(opts, id, tool(3))
    {service, lease} = lease(runtime, id)

    assert {:ok, %{events: [_initial, last]}} =
             SessionManager.replay_page(service, lease, nil, [])

    assert last.data["result"]["structuredContent"]["count"] == 2
    settled(runtime)
  end

  test "combined visible replay capacity rejects a tool proposal before state commit" do
    {runtime, opts} =
      host([], services: [sessions: [options: [max_events: 1, max_events_per_session: 1]]])

    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    failed = post(opts, id, tool(2))
    assert failed.status == 500
    {service, lease} = lease(runtime, id)
    assert {:ok, %{pending_events: 0, events: 1}} = SessionManager.get_stats(service, [])
    assert {:ok, %{events: [_initial]}} = SessionManager.replay_page(service, lease, nil, [])
    assert {:ok, response} = Runtime.request(runtime, tool(3, "peek"))
    assert response["result"]["structuredContent"]["count"] == 0
    settled(runtime)
  end

  test "modern envelopes on the legacy alias reject before initialization claim or callback" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()

    request =
      put_in(initial(), ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
      })

    assert %{status: 400} = post(opts, id, request)
    {service, lease} = lease(runtime, id)

    assert {:ok, %{initialized: false, initialization_claimed: false}} =
             SessionManager.get_session(service, lease, [])

    assert {:ok, %{events: []}} = SessionManager.replay_page(service, lease, nil, [])
    assert %{status: 202} = post(opts, id, initial())
    settled(runtime)
  end

  test "disabled legacy POST alias rejects while explicit primary and mountroot remain valid" do
    {runtime, opts} = host(legacy_http_sse: false)
    assert %{status: 404} = post(opts, "unused", initial())
    assert %{status: 404} = get(opts)
    assert %{status: 404} = connection(:delete, "/sse", nil, []) |> HttpPlug.call(opts)
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])

    assert %{status: 200} =
             connection(:post, "/", Jason.encode!(initial()), [])
             |> put_req_header("content-type", "application/json")
             |> HttpPlug.call(opts)

    {other, primary} = host(legacy_http_sse: false, path: "/message")
    assert %{status: 200} = post(primary, "unused", initial())
    settled(runtime)
    settled(other)
  end

  test "foreign and malformed alias replay cursors return bounded400 without stream takeover" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    other_id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())
    {service, lease} = lease(runtime, id)
    {:ok, %{events: [event]}} = SessionManager.replay_page(service, lease, nil, [])

    assert %{status: 400} =
             get(opts, "/sse",
               headers: [
                 {"mcp-session-id", other_id},
                 {"last-event-id", event.id}
               ]
             )

    assert %{status: 400} =
             get(opts, "/sse",
               headers: [
                 {"mcp-session-id", id},
                 {"last-event-id", String.duplicate("x", 257)}
               ]
             )

    assert %{status: 202} = post(opts, id, tool(2))
    settled(runtime)
  end

  test "DELETE on a recognized alias retains addressed deletion and cannot enter the GET handshake" do
    {runtime, opts} = host()
    id = opts |> get() |> session_id()
    assert %{status: 202} = post(opts, id, initial())

    removed =
      connection(:delete, "/sse", nil,
        headers: [{"mcp-session-id", id}, {"mcp-protocol-version", "2025-11-25"}]
      )
      |> HttpPlug.call(opts)

    assert removed.status == 204
    assert removed.resp_body == ""
    {:ok, service} = Runtime.service(runtime, :sessions)

    assert {:error, :session_not_found} =
             SessionManager.ensure_initialized_session(service, id, %{}, [])

    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "modern alias GET and DELETE reject before session or stream setup effects" do
    for {mode, headers} <- [
          {:modern_only, []},
          {:prefer_modern, [{"mcp-protocol-version", "2026-07-28"}]}
        ] do
      {runtime, opts} = host(protocol_mode: mode)

      for method <- [:get, :delete] do
        response = connection(method, "/sse", nil, headers: headers) |> HttpPlug.call(opts)
        assert response.status == 405
        assert Plug.Conn.get_resp_header(response, "allow") == ["POST"]
      end

      {:ok, service} = Runtime.service(runtime, :sessions)
      assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
      settled(runtime)
    end
  end

  test "configured primary SSE path keeps addressed session methods with aliases disabled" do
    {runtime, opts} = host(legacy_http_sse: false, path: "/sse")
    assert %{status: 400} = get(opts)

    initialized =
      connection(:post, "/sse", Jason.encode!(initial()), [])
      |> put_req_header("content-type", "application/json")
      |> HttpPlug.call(opts)

    assert initialized.status == 200
    [id] = Plug.Conn.get_resp_header(initialized, "mcp-session-id")
    headers = [{"mcp-session-id", id}, {"mcp-protocol-version", "2025-11-25"}]
    stream = get(opts, "/sse", headers: [{"accept", "text/event-stream"} | headers])
    assert stream.status == 200
    refute stream.resp_body =~ "event: endpoint"

    removed = connection(:delete, "/sse", nil, headers: headers) |> HttpPlug.call(opts)
    assert removed.status == 204
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "enabled POST aliases cannot replace configured primary or mountroot MCP semantics" do
    for config <- [[path: "/message"], [legacy_http_sse_post_path: "/"]] do
      {runtime, opts} = host(Keyword.merge([protocol_mode: :prefer_modern], config))
      path = if config[:path], do: "/message", else: "/"

      rejected = get(opts)
      assert rejected.status == 400

      assert Jason.decode!(rejected.resp_body)["error"]["message"] ==
               "Legacy SSE requires a distinct POST alias path"

      {:ok, sessions} = Runtime.service(runtime, :sessions)
      assert {:ok, %{sessions: 0}} = SessionManager.get_stats(sessions, [])

      initialized =
        connection(:post, path, Jason.encode!(initial()), [])
        |> put_req_header("content-type", "application/json")
        |> HttpPlug.call(opts)

      assert initialized.status == 200
      assert Jason.decode!(initialized.resp_body)["result"]["protocolVersion"] == "2025-11-25"
      assert [_session] = Plug.Conn.get_resp_header(initialized, "mcp-session-id")

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

      modern =
        connection(:post, path, Jason.encode!(discover), [])
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> put_req_header("mcp-method", "server/discover")
        |> HttpPlug.call(opts)

      assert modern.status == 200
      assert Jason.decode!(modern.resp_body)["id"] == 9
      assert Plug.Conn.get_resp_header(modern, "mcp-session-id") == []
      settled(runtime)
    end
  end

  defp host(opts \\ [], runtime_opts \\ []) do
    {:ok, root} =
      Runtime.start_link(
        Keyword.merge(
          [
            handler: Handler,
            handler_args: [observer: self()],
            request_timeout_ms: 2_000,
            services: [sessions: []]
          ],
          runtime_opts
        )
      )

    {:ok, runtime} = Runtime.ref(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)

    opts =
      HttpPlug.init(
        Keyword.merge(
          [
            runtime: runtime,
            protocol_mode: :legacy_only,
            legacy_http_sse: true,
            sse_mode: :oneshot
          ],
          opts
        )
      )

    {runtime, opts}
  end

  defp get(opts, path \\ "/sse", config \\ []),
    do: connection(:get, path, nil, config) |> HttpPlug.call(opts)

  defp post(opts, id, request, path \\ "/message", config \\ []) do
    connection(
      :post,
      path <> "?sessionId=" <> URI.encode_www_form(id),
      Jason.encode!(request),
      config
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> HttpPlug.call(opts)
  end

  defp connection(method, path, body, config) do
    conn = Plug.Test.conn(method, path, body)

    conn =
      if config[:prefix],
        do: %{conn | script_name: config[:prefix], path_info: config[:relative]},
        else: conn

    Enum.reduce(config[:headers] || [], conn, fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp session_id(conn) do
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, conn.resp_body)
    URI.decode_query(URI.parse(endpoint).query)["sessionId"]
  end

  defp lease(runtime, id) do
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])
    {service, lease}
  end

  defp initial,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "alias", "version" => "2"}
      }
    }

  defp tool(id, name \\ "count"),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp settled(runtime, attempts \\ 200)
  defp settled(runtime, 0), do: assert(Runtime.stats(runtime).reserved == 0)

  defp settled(runtime, attempts) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    if Runtime.stats(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0,
      do: :ok,
      else:
        (
          Process.sleep(5)
          settled(runtime, attempts - 1)
        )
  end
end
