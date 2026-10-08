defmodule Arbor.MCP.Server.Runtime.HTTPMountIdentityTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    def init(_args), do: {:ok, 0}

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(
         params,
         %{"serverInfo" => %{"name" => "mount", "version" => "2"}, "capabilities" => %{}}
       ), state}
    end

    def handle_call_tool("count", _args, state) do
      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{"count" => state, "endpoint" => Context.current().endpoint}
       }, state + 1}
    end
  end

  test "a forwarded lease cannot authorize another prefix while standalone inspection is retained" do
    {runtime, opts} = runtime()
    conn = forward(:post, ["api", "a"], initialize(), opts)
    assert conn.status == 200
    [id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    assert {:ok, session} = SessionManager.get_session(service, lease, [])
    assert session.metadata.transport_endpoint == "/api/a"

    for method <- [:post, :get, :delete] do
      conn = forward(method, ["api", "b"], tool(2), opts, id)
      assert conn.status == 404
    end

    conn = forward(:post, ["api", "a"], tool(3), opts, id)
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body)["result"]["structuredContent"] ==
             %{"count" => 0, "endpoint" => "/mcp"}

    assert {:ok, _} = SessionManager.get_session(service, lease, [])
  end

  test "root and logical endpoint routes under one forward retain the same lease domain" do
    {runtime, opts} = runtime()
    conn = forward(:post, ["api", "a"], initialize(), opts)
    [id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    {:ok, service} = Runtime.service(runtime, :sessions)

    for {path, request_id} <- [{[], 2}, {["mcp"], 3}] do
      conn = forward(:post, ["api", "a"], tool(request_id), opts, id, path)
      assert conn.status == 200
    end

    assert {:ok, lease} =
             SessionManager.ensure_initialized_session(
               service,
               id,
               %{transport_endpoint: "/api/a"},
               []
             )

    assert {:ok, session} = SessionManager.get_session(service, lease, [])
    assert session.metadata.transport_endpoint == "/api/a"

    assert {:error, :session_identity_mismatch} =
             SessionManager.ensure_initialized_session(
               service,
               id,
               %{transport_endpoint: "/api/a/mcp"},
               []
             )
  end

  test "explicit malformed transport metadata cannot select absence or a different mount" do
    {runtime, _opts} = runtime()
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.create_session(service, %{transport_endpoint: "/api/a"}, [])
    id = Arbor.MCP.SessionManager.SessionLease.id(lease)

    for value <- [nil, "", :private, "/api/b"] do
      assert {:error, :session_identity_mismatch} =
               SessionManager.ensure_session(service, id, %{transport_endpoint: value}, [])
    end

    assert {:ok, _} = SessionManager.ensure_session(service, id, %{}, [])

    assert {:ok, _} =
             SessionManager.ensure_session(service, id, %{transport_endpoint: "/api/a"}, [])
  end

  defp runtime(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler, handler_args: [], services: [sessions: []], request_timeout_ms: 2_000}
      )

    {:ok, runtime} = Runtime.ref(root)

    {runtime,
     HttpPlug.init([runtime: runtime, protocol_mode: :legacy_only, sse_mode: :oneshot] ++ extra)}
  end

  defp initialize,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mount", "version" => "2"}
      }
    }

  defp tool(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "count", "arguments" => %{}}
    }

  defp forward(method, prefix, message, opts, session \\ nil, path \\ []) do
    conn = request(method, "/mcp", message, session)
    conn = if prefix == [], do: conn, else: %{conn | script_name: prefix, path_info: path}
    HttpPlug.call(conn, opts)
  end

  defp request(method, path, message, session) do
    conn =
      Plug.Test.conn(method, path, if(method == :post, do: Jason.encode!(message), else: nil))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25")

    if session, do: Plug.Conn.put_req_header(conn, "mcp-session-id", session), else: conn
  end
end
