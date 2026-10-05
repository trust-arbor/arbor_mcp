defmodule Arbor.MCP.Server.Runtime.HTTPSubscriptionWireTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.{Client, HttpPlug, SessionManager}
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.Tasks.Extension
  alias Arbor.MCP.Server.{Context, Runtime, Subscriptions}
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    def init(opts), do: {:ok, %{observer: opts[:observer], count: 0}}

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(
         params,
         %{"serverInfo" => %{"name" => "wire", "version" => "2"}, "capabilities" => %{}}
       ), state}
    end

    def handle_call_tool("publish", _args, state) do
      result = Subscriptions.publish("notifications/tools/list_changed", %{})
      send(state.observer, {:wire_publication, result})
      {:ok, %{"content" => []}, state}
    end

    def handle_call_tool("hold", _args, state) do
      send(state.observer, {:wire_hold, self()})
      Context.report_progress(1)
      receive do: (:finish -> :ok)
      {:ok, %{"content" => []}, %{state | count: state.count + 1}}
    end

    def handle_call_tool("count", _args, state),
      do:
        {:ok,
         %{
           "content" => [],
           "structuredContent" => %{
             "count" => state.count,
             "endpoint" => Context.current().endpoint
           }
         }, state}
  end

  defmodule Identity do
    def principal(conn, _request, _token), do: conn.assigns[:verified_principal]
    def tenant(conn, _request, _token), do: if(conn.assigns[:verified_principal], do: "team")
  end

  defmodule Router do
    use Plug.Router
    plug(:verify_fixture_bearer)
    plug(:match)
    plug(:dispatch)

    defp verify_fixture_bearer(conn, _opts) do
      verified =
        Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-access-token"]

      Plug.Conn.assign(conn, :verified_principal, if(verified, do: "alice"))
    end

    forward("/a/mcp",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPSubscriptionWireTest.Root,
        path: "/mcp",
        protocol_mode: :prefer_modern,
        sse_mode: :oneshot,
        principal_id: {Identity, :principal, []},
        tenant_id: {Identity, :tenant, []},
        allowed_origins: :any,
        subscription_keepalive_interval_ms: :infinity
      ]
    )

    forward("/b/mcp",
      to: HttpPlug,
      init_opts: [
        runtime: HTTPSubscriptionWireTest.Root,
        path: "/mcp",
        protocol_mode: :prefer_modern,
        sse_mode: :oneshot,
        principal_id: {Identity, :principal, []},
        tenant_id: {Identity, :tenant, []},
        allowed_origins: :any,
        subscription_keepalive_interval_ms: :infinity
      ]
    )

    match(_, do: Plug.Conn.send_resp(conn, 404, "not found"))
  end

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "physical anonymous public subscription survives RPC expiry and stays within its forward" do
    {runtime, port} = host(request_timeout_ms: 250)
    socket = open_stream(port, "/a/mcp", listen())
    acknowledgment = receive_until(socket, "notifications/subscriptions/acknowledged")
    assert acknowledgment =~ "200 OK"
    refute acknowledgment =~ "mcp-session-id"
    Process.sleep(300)
    assert {200, _, _} = request(port, :post, "/b/mcp", modern(tool(2, "publish")))
    assert_receive {:wire_publication, %{enqueued: 0}}
    quiet(socket, "notifications/tools/list_changed")
    assert {200, _, _} = request(port, :post, "/a/mcp", modern(tool(3, "publish")))
    assert_receive {:wire_publication, %{enqueued: 1}}
    assert receive_until(socket, "notifications/tools/list_changed") =~ "data: "
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "physical trusted and anonymous listeners retain identity plus exact private mount" do
    {runtime, port} = host()
    trusted = open_stream(port, "/a/mcp", listen(), bearer())
    receive_until(trusted, "notifications/subscriptions/acknowledged")
    anonymous = open_stream(port, "/a/mcp", listen())
    receive_until(anonymous, "notifications/subscriptions/acknowledged")
    assert {200, _, _} = request(port, :post, "/b/mcp", modern(tool(2, "publish")), bearer())
    assert_receive {:wire_publication, %{enqueued: 0}}
    quiet(trusted, "notifications/tools/list_changed")
    quiet(anonymous, "notifications/tools/list_changed")
    assert {200, _, _} = request(port, :post, "/a/mcp", modern(tool(3, "publish")), bearer())
    assert_receive {:wire_publication, %{enqueued: 1}}
    receive_until(trusted, "notifications/tools/list_changed")
    quiet(anonymous, "notifications/tools/list_changed")
    assert {200, _, _} = request(port, :post, "/a/mcp", modern(tool(4, "publish")))
    assert_receive {:wire_publication, %{enqueued: 1}}
    receive_until(anonymous, "notifications/tools/list_changed")
    quiet(trusted, "notifications/tools/list_changed")
    :gen_tcp.close(trusted)
    :gen_tcp.close(anonymous)
    settled(runtime)
  end

  test "physical same-identity cancellation cannot cross forwarded mounts" do
    {runtime, port} = host()
    held = put_in(modern(tool(7, "hold")), ["params", "_meta", "progressToken"], "held")
    socket = open_stream(port, "/a/mcp", held, bearer())
    assert_receive {:wire_hold, worker}, 1_000
    receive_until(socket, "notifications/progress")
    assert {202, _, ""} = request(port, :post, "/b/mcp", modern(cancel(7)), bearer())
    assert Process.alive?(worker)
    assert {202, _, ""} = request(port, :post, "/a/mcp", modern(cancel(7)), bearer())
    receive_until(socket, "Request cancelled")
    {200, _, body} = request(port, :post, "/a/mcp", modern(tool(8, "count")), bearer())

    assert Jason.decode!(body)["result"]["structuredContent"] == %{
             "count" => 0,
             "endpoint" => "/mcp"
           }

    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "retained native Client opens receives and cancels the literal modern subscription" do
    {runtime, port} = host()

    client =
      start_supervised!(
        {Client,
         [
           transport: :http,
           url: "http://127.0.0.1:#{port}/a/mcp",
           protocol_mode: :modern_only,
           protocol_version: "2026-07-28",
           capabilities: Extension.put_capability(%{}),
           use_sse: false,
           health_check_interval: nil,
           stream_idle_timeout: 1_000
         ]}
      )

    assert {:ok, subscription} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 2_000)

    assert %Subscription.Ref{} = subscription
    assert subscription.acknowledged_filter == %{"toolsListChanged" => true}
    assert {:ok, _response} = Client.call_tool(client, "publish", %{}, 2_000)
    assert_receive {:wire_publication, %{enqueued: 1}}

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                    params},
                   1_000

    assert params["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription.request_id
    assert :ok = Subscription.cancel(subscription, "test complete")
    wait(fn -> Subscriptions.entries(runtime: runtime) == [] end)
    settled(runtime)
  end

  test "physical rejected filter returns one fixed error and promptly releases setup accounting" do
    {runtime, port} =
      host(
        services: [
          subscriptions: [
            options: [authorize_filter: fn _filter, _context -> {:error, :denied} end]
          ]
        ]
      )

    assert {200, _headers, body} = request(port, :post, "/a/mcp", listen())
    assert Jason.decode!(body)["error"]["message"] == "Invalid subscription request"
    assert Subscriptions.entries(runtime: runtime) == []
    settled(runtime)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    wait(fn -> HTTPWriterRegistry.stats(domain).bindings == 0 end)
  end

  test "physical listener saturation returns a bounded error and leaves the existing stream live" do
    {runtime, port} = host(services: [subscriptions: [options: [max_global: 1]]])
    socket = open_stream(port, "/a/mcp", listen())
    receive_until(socket, "notifications/subscriptions/acknowledged")
    assert {200, _headers, body} = request(port, :post, "/a/mcp", listen())
    assert Jason.decode!(body)["error"]["message"] == "Invalid subscription request"
    assert length(Subscriptions.entries(runtime: runtime)) == 1
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    wait(fn -> HTTPWriterRegistry.stats(domain).bindings == 1 end)
    :gen_tcp.close(socket)
    settled(runtime)
  end

  test "physical legacy session and replay authority cannot cross a forward" do
    {runtime, port} = host()
    {200, headers, _} = request(port, :post, "/a/mcp", initialize())
    id = headers |> List.keyfind(~c"mcp-session-id", 0) |> elem(1) |> List.to_string()

    headers = [
      {~c"mcp-session-id", String.to_charlist(id)},
      {~c"mcp-protocol-version", ~c"2025-11-25"}
    ]

    for method <- [:post, :get, :delete] do
      assert {404, _, _} = request(port, method, "/b/mcp", tool(2, "count"), headers)
    end

    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    {:ok, event} = SessionManager.append_event(service, lease, "message", %{"private" => "A"}, [])
    replay = [{~c"last-event-id", String.to_charlist(event.id)} | headers]
    assert {404, _, _} = request(port, :get, "/b/mcp", nil, replay)
    {200, _, body} = request(port, :post, "/a/mcp", tool(3, "count"), headers)

    assert Jason.decode!(body)["result"]["structuredContent"] == %{
             "count" => 0,
             "endpoint" => "/mcp"
           }

    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    settled(runtime)
  end

  defp host(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             name: HTTPSubscriptionWireTest.Root,
             handler: Handler,
             handler_args: [observer: self()],
             request_timeout_ms: 2_000,
             services: [
               sessions: [],
               subscriptions: [
                 options: [
                   max_lifetime_ms: 3_000,
                   authorize_filter: fn filter, _context -> {:ok, filter} end,
                   authorize_publication: fn _method, _params, _context -> true end
                 ]
               ]
             ]
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

  defp open_stream(port, path, value, headers \\ []) do
    body = Jason.encode!(value)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    rendered =
      Enum.map_join(modern_headers(value) ++ headers, "", fn {k, v} ->
        List.to_string(k) <> ": " <> List.to_string(v) <> "\r\n"
      end)

    :ok =
      :gen_tcp.send(
        socket,
        "POST #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" <>
          "Content-Type: application/json\r\nAccept: text/event-stream\r\n" <>
          rendered <>
          "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      )

    socket
  end

  defp request(port, method, path, value, headers \\ []) do
    url = String.to_charlist("http://127.0.0.1:#{port}" <> path)
    headers = modern_headers(value) ++ headers

    argument =
      if method == :post,
        do: {url, headers, ~c"application/json", Jason.encode!(value)},
        else: {url, headers}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(method, argument, [timeout: 5_000, connect_timeout: 1_000],
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
  defp bearer, do: [{~c"authorization", ~c"Bearer fixture-access-token"}]

  defp listen,
    do:
      modern(%{
        "jsonrpc" => "2.0",
        "id" => 91,
        "method" => "subscriptions/listen",
        "params" => %{"notifications" => %{"toolsListChanged" => true}}
      })

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp modern(value),
    do:
      put_in(value, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
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
        _closed -> flunk("HTTP stream closed before expected frame")
      end
    end
  end

  defp quiet(socket, marker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 50

    case :gen_tcp.recv(socket, 0, max(1, deadline - System.monotonic_time(:millisecond))) do
      {:ok, bytes} ->
        refute String.contains?(bytes, marker)
        quiet(socket, marker, deadline)

      {:error, :timeout} ->
        :ok

      _closed ->
        flunk("healthy listener closed")
    end
  end

  defp wait(fun, attempts \\ 200)
  defp wait(_fun, 0), do: flunk("wire state did not settle")

  defp wait(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            wait(fun, attempts - 1)
          )
      )
end
