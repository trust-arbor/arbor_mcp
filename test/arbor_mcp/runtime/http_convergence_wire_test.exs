defmodule Arbor.MCP.Server.Runtime.HTTPConvergenceWireTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.HTTPConvergenceTest.Handler
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "physical initialization arrays retain ordered results and one addressed lease" do
    {runtime, port} = host(:legacy_only)
    {200, headers, body} = request(port, [initialize(), tool(2, "count")])

    assert [
             %{"id" => 1, "result" => _},
             %{"id" => 2, "result" => %{"structuredContent" => %{"count" => 0}}}
           ] = Jason.decode!(body)

    id = session_id(headers)
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, _} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    {200, _, next} = request(port, tool(3, "count"), session_headers(id))
    assert Jason.decode!(next)["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "physical failed initializer cannot run following array callbacks or expose a lease" do
    {runtime, port} = host(:legacy_only)
    init = put_in(initialize(), ["params", "clientInfo", "name"], "fail")
    {200, headers, body} = request(port, [init, tool(2, "count")])
    assert [%{"id" => 1, "error" => _}] = Jason.decode!(body)
    refute List.keymember?(headers, ~c"mcp-session-id", 0)
    refute_receive {:convergence_count, _}, 5
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "physical notification arrays continue after their single 202 socket response" do
    {runtime, port} = host(:legacy_only)
    {200, headers, _} = request(port, initialize())
    id = session_id(headers)
    notices = Enum.map(["hold", "next"], &notification/1)
    assert {202, _, ""} = request(port, notices, session_headers(id))
    assert_receive {:convergence_notification, "hold", worker}, 1_000
    assert Process.alive?(worker)
    send(worker, :finish)
    assert_receive {:convergence_notification, "next", _}, 1_000
    settled(runtime)
    {200, _, body} = request(port, tool(3, "count"), session_headers(id))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 2
    settled(runtime)
  end

  test "physical modern MRTR completes and rejects replay before another handler effect" do
    {runtime, port} = host(:modern_only, mrtr_options())
    first = modern(tool(1, "collect"), %{"elicitation" => %{}})
    {200, headers, body} = request(port, first)
    refute List.keymember?(headers, ~c"mcp-session-id", 0)
    result = Jason.decode!(body)["result"]
    assert %{"inputRequests" => %{"profile" => _}, "requestState" => token} = result

    retry =
      modern(tool(2, "collect"), %{"elicitation" => %{}})
      |> put_in(["params", "requestState"], token)
      |> put_in(["params", "inputResponses"], %{
        "profile" => %{"action" => "accept", "content" => %{"name" => "Ada"}}
      })

    {200, _, body} = request(port, retry)

    assert Jason.decode!(body)["result"]["content"] == [
             %{"type" => "text", "text" => "Ada:profile"}
           ]

    assert_receive {:convergence_collect, nil}
    assert_receive {:convergence_collect, %{"profile" => _}}
    {200, _, body} = request(port, retry)
    assert Jason.decode!(body)["error"]["code"] == -32602
    refute_receive {:convergence_collect, _}, 5
    settled(runtime)
  end

  test "physical legacy controls cancel only the same initialized lease" do
    {runtime, port} = host(:legacy_only)
    {200, headers, _} = request(port, initialize())
    own_id = session_id(headers)
    {200, headers, _} = request(port, %{initialize() | "id" => 2})
    other_id = session_id(headers)
    socket = open_stream(port, tool(7, "hold"), session_headers(own_id))
    assert_receive {:convergence_hold, 7, worker}, 1_000
    assert {202, _, ""} = request(port, cancellation(7), session_headers(other_id))
    assert {202, _, ""} = request(port, cancellation("7"), session_headers(own_id))
    assert Process.alive?(worker)
    assert {202, _, ""} = request(port, cancellation(7), session_headers(own_id))
    assert receive_until(socket, "Request cancelled") =~ "\"id\":7"
    settled(runtime)
  end

  test "physical same-array cancellation suppresses its future request without a callback effect" do
    {runtime, port} = host(:legacy_only)
    {200, headers, _} = request(port, initialize())
    id = session_id(headers)
    {200, _, body} = request(port, [cancellation(7), tool(7, "count")], session_headers(id))
    assert %{"id" => 7, "error" => %{"message" => "Request cancelled"}} = Jason.decode!(body)
    refute_receive {:convergence_count, _}, 5
    settled(runtime)
    {200, _, body} = request(port, tool(8, "count"), session_headers(id))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 0
    settled(runtime)
  end

  test "physical future-member cancellation fails one aggregate and preserves earlier committed state" do
    {runtime, port} = host(:legacy_only)
    {200, headers, _} = request(port, initialize())
    id = session_id(headers)
    socket = open_stream(port, [tool(11, "hold"), tool(7, "count")], session_headers(id))
    assert_receive {:convergence_hold, 11, worker}, 1_000
    assert {202, _, ""} = request(port, cancellation("7"), session_headers(id))
    assert {202, _, ""} = request(port, cancellation(7), session_headers(id))
    assert Process.alive?(worker)
    send(worker, :finish)
    response = receive_until(socket, "Request cancelled")
    assert response =~ "\"id\":7"
    refute response =~ "\"id\":11"
    refute_receive {:convergence_count, _}, 5
    settled(runtime)
    {200, _, body} = request(port, tool(8, "count"), session_headers(id))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "physical queued current cancellation suppresses its callback without cancelling the active peer" do
    {runtime, port} = host(:legacy_only)
    {200, headers, _} = request(port, initialize())
    id = session_id(headers)
    active = open_stream(port, tool(11, "hold"), session_headers(id))
    assert_receive {:convergence_hold, 11, worker}, 1_000
    queued = open_stream(port, tool(7, "count"), session_headers(id))

    {:ok, route} =
      Arbor.MCP.Server.Runtime.Admission.route(Arbor.MCP.Server.Runtime.Ref.table(runtime))

    wait(fn ->
      Enum.any?(
        :sys.get_state(route.scheduler).work,
        fn {_token, work} -> work.request["id"] == 7 end
      )
    end)

    assert {202, _, ""} = request(port, cancellation(7), session_headers(id))
    assert receive_until(queued, "Request cancelled") =~ "\"id\":7"
    assert Process.alive?(worker)
    refute_receive {:convergence_count, _}, 5
    send(worker, :finish)
    assert receive_until(active, "structuredContent") =~ "\"id\":11"
    settled(runtime)
    {200, _, body} = request(port, tool(8, "count"), session_headers(id))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 1
    settled(runtime)
  end

  test "physical trusted modern cross-POST cancellation uses server identity" do
    {runtime, port} =
      host(:modern_only, principal_id: "alice", tenant_id: "team", endpoint: "/mcp")

    value = modern(tool(7, "hold")) |> put_in(["params", "_meta", "progressToken"], "held")
    socket = open_stream(port, value)
    assert_receive {:convergence_hold, 7, _worker}, 1_000
    assert receive_until(socket, "notifications/progress") =~ "200 OK"
    assert {202, _, ""} = request(port, modern(cancellation(7)))
    assert receive_until(socket, "Request cancelled") =~ "\"id\":7"
    settled(runtime)
  end

  test "physical anonymous control is advisory while originating socket close cancels" do
    {runtime, port} = host(:modern_only)
    value = modern(tool(7, "hold")) |> put_in(["params", "_meta", "progressToken"], "held")
    socket = open_stream(port, value)
    assert_receive {:convergence_hold, 7, worker}, 1_000
    assert receive_until(socket, "notifications/progress") =~ "200 OK"

    assert {202, _, ""} =
             request(port, modern(cancellation(7)))

    assert Process.alive?(worker)
    :ok = :gen_tcp.close(socket)
    wait(fn -> not Process.alive?(worker) end)
    settled(runtime)
    {200, _, body} = request(port, modern(tool(8, "count")))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 0
    settled(runtime)
  end

  defp host(mode, plug_extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         [
           handler: Handler,
           handler_args: [test: self()],
           request_timeout_ms: 2_000,
           services: [sessions: [], replay_cache: []]
         ]}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()
    opts = Keyword.merge([runtime: runtime, protocol_mode: mode], plug_extra)
    {:ok, _listener} = Plug.Cowboy.http(HttpPlug, opts, port: 0, ip: {127, 0, 0, 1}, ref: ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    {runtime, port}
  end

  defp open_stream(port, value, headers \\ []) do
    body = Jason.encode!(value)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    protocol_headers = modern_headers(value) ++ headers

    rendered =
      Enum.map_join(protocol_headers, "", fn {name, value} ->
        List.to_string(name) <> ": " <> List.to_string(value) <> "\r\n"
      end)

    wire =
      "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\n" <>
        rendered <> "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(socket, wire)
    socket
  end

  defp request(port, value, headers \\ []) do
    headers = modern_headers(value) ++ headers
    url = String.to_charlist("http://127.0.0.1:#{port}/mcp")

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", Jason.encode!(value)},
        [timeout: 5_000, connect_timeout: 1_000],
        body_format: :binary
      )

    {status, headers, body}
  end

  defp modern_headers(
         %{"params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}}} =
           value
       ) do
    [
      {~c"mcp-protocol-version", String.to_charlist(version)},
      {~c"mcp-method", String.to_charlist(value["method"])}
    ] ++
      if(value["params"]["name"],
        do: [{~c"mcp-name", String.to_charlist(value["params"]["name"])}],
        else: []
      )
  end

  defp modern_headers(_), do: []

  defp session_id(headers),
    do: headers |> List.keyfind(~c"mcp-session-id", 0) |> elem(1) |> List.to_string()

  defp session_headers(id),
    do: [{~c"mcp-session-id", String.to_charlist(id)}, {~c"mcp-protocol-version", ~c"2025-11-25"}]

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp notification(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/elicitation/complete",
      "params" => %{"elicitationId" => id}
    }

  defp cancellation(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp modern(value, capabilities \\ %{}),
    do:
      put_in(value, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => capabilities
      })

  defp initialize,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "wire", "version" => "2"}
      }
    }

  defp mrtr_options,
    do: [
      principal_id: "alice",
      tenant_id: "team",
      endpoint: "/mcp",
      require_replay_protection: true,
      request_state: [
        active_key_id: "fixture",
        keys: %{"fixture" => :binary.copy(<<42>>, 32)},
        ttl_seconds: 60
      ]
    ]

  defp settled(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    wait(fn ->
      Runtime.stats(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0
    end)
  end

  defp receive_until(socket, marker, acc \\ "") do
    if String.contains?(acc, marker) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, bytes} -> receive_until(socket, marker, acc <> bytes)
        _closed -> flunk("HTTP stream closed before the expected frame")
      end
    end
  end

  defp wait(fun, attempts \\ 200)
  defp wait(_fun, 0), do: flunk("physical convergence did not settle")

  defp wait(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, attempts - 1)
        )
  end
end
