defmodule Arbor.MCP.Server.Runtime.HTTPProtocolHeaderCompatibilityTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.{Context, Runtime}
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  @versions ["2025-03-26", "2025-06-18", "2025-11-25"]
  @capabilities %{"sampling" => %{}, "elicitation" => %{}}
  @client_info %{"name" => "header-policy", "version" => "2"}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts),
      do: {:ok, %{observer: opts[:observer], initialization: nil, count: 0}}

    def handle_initialize(params, state) do
      send(state.observer, {:header_initialized, params})

      {:ok,
       %{
         "protocolVersion" => params["protocolVersion"],
         "serverInfo" => %{"name" => "header-policy", "version" => "2"},
         "capabilities" => %{"tools" => %{"listChanged" => false}}
       }, %{state | initialization: params}}
    end

    def handle_list_tools(_cursor, state) do
      observe(state)
      {:ok, [], nil, state}
    end

    def handle_call_tool("snapshot", _arguments, state) do
      observe(state)

      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{
           "initialization" => state.initialization,
           "count" => state.count
         }
       }, %{state | count: state.count + 1}}
    end

    def handle_call_tool("large", _arguments, state) do
      observe(state)

      {:ok, %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 4_096)}]},
       %{state | count: state.count + 1}}
    end

    defp observe(state) do
      context = Context.current()
      send(state.observer, {:header_callback, context.request_id, context})
    end
  end

  setup do
    previous = Application.get_env(:arbor_mcp, :protocol_version_required)
    Application.put_env(:arbor_mcp, :protocol_version_required, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_mcp, :protocol_version_required),
        else: Application.put_env(:arbor_mcp, :protocol_version_required, previous)
    end)

    :ok
  end

  test "supported legacy HTTP headers keep initialized version and callback era" do
    for negotiated <- @versions do
      {runtime, opts, id, service, lease, before} = initialized(negotiated)

      matched = post(opts, list_tools(2), id, [negotiated])
      assert matched.status == 200, matched.resp_body
      assert_received {:header_callback, 2, matching_context}

      for {header, request_id} <- Enum.with_index(@versions, 3) do
        response = post(opts, list_tools(request_id), id, [header])
        assert response.status == 200, response.resp_body
        assert Jason.decode!(response.resp_body)["result"]["tools"] == []
        assert get_resp_header(response, "mcp-protocol-version") == [negotiated]
        assert get_resp_header(response, "mcp-session-id") == [id]

        assert_received {:header_callback, ^request_id, compatible_context}
        assert compatible_context.era == :legacy
        assert compatible_context.protocol_version == nil
        assert compatible_context.principal_id == "principal"
        assert compatible_context.tenant_id == "tenant"
        # Only the actual request ID and request-owned notification target differ.
        assert Map.drop(Map.from_struct(compatible_context), [:request_id, :notification_target]) ==
                 Map.drop(Map.from_struct(matching_context), [:request_id, :notification_target])

        unchanged_session(service, lease, before)
      end

      response = post(opts, snapshot(10), id, ["2025-03-26"])
      assert response.status == 200, response.resp_body

      assert Jason.decode!(response.resp_body)["result"]["structuredContent"]["initialization"] ==
               initialize(1, negotiated)["params"]

      assert_received {:header_callback, 10, %{era: :legacy}}
      refute_received {:header_initialized, _}
      settled(runtime)
    end
  end

  test "mixed-header batch preserves ordered members and the same session" do
    {runtime, opts, id, service, lease, before} = initialized("2025-11-25")
    settled(runtime)
    response = post(opts, [snapshot(2), snapshot(3)], id, ["2025-03-26"])
    assert response.status == 200, response.resp_body
    assert get_resp_header(response, "mcp-protocol-version") == ["2025-11-25"]

    assert [%{"id" => 2, "result" => first}, %{"id" => 3, "result" => second}] =
             Jason.decode!(response.resp_body)

    assert first["structuredContent"]["count"] == 0
    assert second["structuredContent"]["count"] == 1

    assert first["structuredContent"]["initialization"] ==
             second["structuredContent"]["initialization"]

    assert_received {:header_callback, 2, %{era: :legacy}}
    assert_received {:header_callback, 3, %{era: :legacy}}
    unchanged_session(service, lease, before)
    settled(runtime)
  end

  test "missing invalid unsupported duplicate and non-family headers do not enter callbacks" do
    {runtime, opts, id, service, lease, before} = initialized("2025-11-25")

    headers = [
      [],
      ["invalid"],
      ["2099-01-01"],
      ["2024-11-05"],
      ["2026-07-28"],
      ["2025-03-26", "2025-03-26"],
      ["2025-03-26", "2025-11-25"]
    ]

    for {values, request_id} <- Enum.with_index(headers, 2) do
      rejected = post(opts, snapshot(request_id), id, values)
      assert rejected.status == 400, rejected.resp_body
      assert is_map(Jason.decode!(rejected.resp_body)["error"])
      unchanged_session(service, lease, before)
    end

    refute_received {:header_callback, _, _}
    response = post(opts, snapshot(20), id, ["2025-03-26"])
    assert response.status == 200, response.resp_body
    assert Jason.decode!(response.resp_body)["result"]["structuredContent"]["count"] == 0
    assert_received {:header_callback, 20, %{era: :legacy}}
    settled(runtime)
  end

  test "supported header cannot borrow another principal tenant mount or retired lease" do
    {runtime, opts, id, service, lease, before} = initialized("2025-11-25")

    for {identity, prefix, request_id} <- [
          {{"other", "tenant"}, "a", 2},
          {{"principal", "other"}, "a", 3},
          {{"principal", "tenant"}, "b", 4}
        ] do
      rejected = post(opts, snapshot(request_id), id, ["2025-03-26"], identity, prefix)
      assert rejected.status == 404, rejected.resp_body
      unchanged_session(service, lease, before)
    end

    refute_received {:header_callback, _, _}
    assert :ok == SessionManager.terminate_session(service, lease, [])
    retired = post(opts, snapshot(5), id, ["2025-03-26"])
    assert retired.status == 404, retired.resp_body
    refute_received {:header_callback, _, _}
    settled(runtime)
  end

  test "initialize still rejects conflicting supported headers and duplicate headers" do
    {runtime, opts} = host()

    for {headers, request_id} <- [{["2025-03-26"], 1}, {["2025-11-25", "2025-11-25"], 2}] do
      rejected = post(opts, initialize(request_id, "2025-11-25"), nil, headers)
      assert rejected.status == 400, rejected.resp_body
      refute_received {:header_initialized, _}
    end

    accepted = post(opts, initialize(3, "2025-11-25"), nil, ["2025-11-25"])
    assert accepted.status == 200, accepted.resp_body
    assert_received {:header_initialized, %{"protocolVersion" => "2025-11-25"}}
    refute_received {:header_initialized, _}
    settled(runtime)
  end

  test "legacy header acceptance cannot bypass modern metadata or era validation" do
    {runtime, opts, id, service, lease, before} = initialized("2025-11-25")

    for {header, request_id} <- Enum.with_index(["2025-03-26", "2026-07-28"], 2) do
      request =
        put_in(snapshot(request_id), ["params", "_meta"], %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => @capabilities
        })

      rejected = post(opts, request, id, [header])
      assert rejected.status == 400, rejected.resp_body
      assert is_map(Jason.decode!(rejected.resp_body)["error"])
      unchanged_session(service, lease, before)
    end

    refute_received {:header_callback, _, _}
    settled(runtime)
  end

  test "compatibility preserves ID credits and frame limits before handler state commit" do
    {runtime, opts, id, service, lease, before} =
      initialized("2025-11-25",
        max_http_io_frames: 1,
        services: [sessions: [options: [max_request_ids: 3]]]
      )

    large = post(opts, tool(2, "large"), id, ["2025-03-26"])
    assert large.status == 200, large.resp_body
    assert Jason.decode!(large.resp_body)["error"]["code"] == -32603
    assert_received {:header_callback, 2, %{era: :legacy}}
    settled(runtime)

    accepted = post(opts, snapshot(3), id, ["2025-06-18"])
    assert accepted.status == 200, accepted.resp_body
    assert Jason.decode!(accepted.resp_body)["result"]["structuredContent"]["count"] == 0
    assert_received {:header_callback, 3, %{era: :legacy}}

    duplicated = post(opts, snapshot(3), id, ["2025-03-26"])
    exhausted = post(opts, snapshot(4), id, ["2025-03-26"])
    assert duplicated.status == 400, duplicated.resp_body
    assert exhausted.status == 429, exhausted.resp_body
    refute_received {:header_callback, _, _}
    unchanged_session(service, lease, before)
    settled(runtime)
  end

  test "matching and compatible headers produce identical method and capability decisions" do
    {runtime, opts, id, service, lease, before} = initialized("2025-11-25")

    for {method, index} <- Enum.with_index(["tools/list", "server/discover", "unknown/method"], 2) do
      matched_request = %{
        "jsonrpc" => "2.0",
        "id" => index * 2,
        "method" => method,
        "params" => %{}
      }

      compatible_request = %{matched_request | "id" => index * 2 + 1}
      matched = post(opts, matched_request, id, ["2025-11-25"])
      compatible = post(opts, compatible_request, id, ["2025-03-26"])
      assert matched.status == compatible.status

      assert Map.delete(Jason.decode!(matched.resp_body), "id") ==
               Map.delete(Jason.decode!(compatible.resp_body), "id")

      unchanged_session(service, lease, before)
      settled(runtime)
    end
  end

  test "deprecated SSE aliases keep exact negotiated-header fencing" do
    {runtime, opts} = host([], legacy_http_sse: true, sse_mode: :oneshot)
    conn = Plug.Test.conn(:get, "/a/sse")
    conn = %{conn | script_name: ["a"], path_info: ["sse"]}
    conn = conn |> assign(:header_principal, "principal") |> assign(:header_tenant, "tenant")
    greeting = conn |> put_req_header("accept", "text/event-stream") |> HttpPlug.call(opts)
    assert greeting.status == 200, greeting.resp_body
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, greeting.resp_body)
    id = URI.decode_query(URI.parse(endpoint).query)["sessionId"]
    relative = "message?sessionId=#{URI.encode_www_form(id)}"

    accepted =
      post(
        opts,
        initialize(1, "2025-11-25"),
        nil,
        ["2025-11-25"],
        {"principal", "tenant"},
        "a",
        relative
      )

    assert accepted.status == 202, accepted.resp_body
    assert accepted.resp_body == ""
    assert_received {:header_initialized, _}
    {:ok, service} = Runtime.service(runtime, :sessions)
    metadata = %{principal_id: "principal", tenant_id: "tenant", transport_endpoint: "/a"}
    {:ok, lease} = SessionManager.ensure_initialized_session(service, id, metadata, [])
    {:ok, before} = SessionManager.get_session(service, lease, [])

    rejected =
      post(opts, snapshot(2), nil, ["2025-03-26"], {"principal", "tenant"}, "a", relative)

    assert rejected.status == 400, rejected.resp_body
    refute_received {:header_callback, _, _}
    unchanged_session(service, lease, before)
    settled(runtime)
  end

  defp host(extra \\ [], mount_extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Handler,
             handler_args: [observer: self()],
             request_timeout_ms: 2_000,
             max_concurrency: 1,
             max_queue: 1,
             max_http_io_frames: 2,
             max_http_io_frame_bytes: 1_024,
             services: [sessions: []]
           ],
           extra
         )},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)

    opts =
      HttpPlug.init(
        Keyword.merge(
          [
            runtime: runtime,
            path: "/mcp",
            protocol_mode: :legacy_only,
            principal_id: & &1.assigns.header_principal,
            tenant_id: & &1.assigns.header_tenant
          ],
          mount_extra
        )
      )

    {runtime, opts}
  end

  defp initialized(version, extra \\ []) do
    {runtime, opts} = host(extra)
    response = post(opts, initialize(1, version), nil, [version])
    assert response.status == 200, response.resp_body
    assert Jason.decode!(response.resp_body)["result"]["protocolVersion"] == version
    assert_received {:header_initialized, _}
    [id] = get_resp_header(response, "mcp-session-id")
    {:ok, service} = Runtime.service(runtime, :sessions)
    metadata = %{principal_id: "principal", tenant_id: "tenant", transport_endpoint: "/a"}
    {:ok, lease} = SessionManager.ensure_initialized_session(service, id, metadata, [])
    {:ok, before} = SessionManager.get_session(service, lease, [])
    {runtime, opts, id, service, lease, before}
  end

  defp post(
         opts,
         request,
         id,
         versions,
         identity \\ {"principal", "tenant"},
         prefix \\ "a",
         relative \\ "mcp"
       ) do
    {principal, tenant} = identity
    conn = Plug.Test.conn(:post, "/#{prefix}/#{relative}", Jason.encode!(request))
    conn = %{conn | script_name: [prefix], path_info: [URI.parse(relative).path]}
    conn = conn |> assign(:header_principal, principal) |> assign(:header_tenant, tenant)
    conn = put_req_header(conn, "content-type", "application/json")
    conn = put_req_header(conn, "accept", "application/json, text/event-stream")
    conn = if id, do: put_req_header(conn, "mcp-session-id", id), else: conn

    conn = %{
      conn
      | req_headers: Enum.map(versions, &{"mcp-protocol-version", &1}) ++ conn.req_headers
    }

    HttpPlug.call(conn, opts)
  end

  defp initialize(id, version),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => @capabilities,
        "clientInfo" => @client_info
      }
    }

  defp list_tools(id),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}

  defp snapshot(id), do: tool(id, "snapshot")

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp unchanged_session(service, lease, before) do
    {:ok, current} = SessionManager.get_session(service, lease, [])

    assert Map.take(current, [:id, :epoch, :protocol_version, :initialized, :metadata, :sequence]) ==
             Map.take(before, [:id, :epoch, :protocol_version, :initialized, :metadata, :sequence])
  end

  defp settled(runtime, attempts \\ 200)

  defp settled(runtime, 0) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    assert Runtime.stats(runtime).reserved == 0
    assert HTTPWriterRegistry.stats(domain).frames == 0
  end

  defp settled(runtime, attempts) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    if Runtime.stats(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0 do
      :ok
    else
      Process.sleep(5)
      settled(runtime, attempts - 1)
    end
  end
end
