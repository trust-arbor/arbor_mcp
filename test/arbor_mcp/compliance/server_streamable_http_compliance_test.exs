defmodule Arbor.MCP.Compliance.ServerStreamableHTTPComplianceTest do
  @moduledoc """
  Server-side compliance tests for MCP Streamable HTTP transport.

  These tests verify that the Arbor.MCP HttpPlug (server) conforms to the MCP spec's
  requirements for the Streamable HTTP transport. They test the server's behavior
  when handling client requests, focusing on issues discovered during cross-language
  interop testing.

  Spec requirements tested:
  1. Server MUST provide Mcp-Session-Id in response headers
  2. SSE GET MUST use the same endpoint as POST (not /sse)
  3. POST responses MUST return 200 with result body (even when SSE is enabled)
  4. Server MUST include mcp-protocol-version in responses
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  setup do
    runtime = RuntimeHTTPFixture.start(__MODULE__.ComplianceTestServer)
    Process.put(:compliance_runtime, runtime)
    :ok
  end

  # A simple MCP server handler for testing
  defmodule ComplianceTestServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "echo", "Echoes the input message" do
      param(:message, :string, required: true)
      run(fn %{message: message}, state -> {:ok, "Echo: #{message}", state} end)
    end
  end

  # Helper to build a standard initialize request
  defp initialize_request(id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "compliance-test", "version" => "1.0.0"}
      },
      "id" => id
    }
  end

  # Helper to build a tools/list request
  defp tools_list_request(id \\ 2) do
    %{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => id
    }
  end

  # Helper to build a tools/call request
  defp tools_call_request(id \\ 3) do
    %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "name" => "echo",
        "arguments" => %{"message" => "hello"}
      },
      "id" => id
    }
  end

  # Helper to build a notification (no id)
  defp initialized_notification do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }
  end

  # Helper to make a POST request to the plug
  defp post_request(path, body, opts \\ []) do
    plug_opts = Keyword.get(opts, :plug_opts, [])
    extra_headers = Keyword.get(opts, :headers, [])

    init_opts =
      Keyword.merge(
        [handler: ComplianceTestServer, sse_enabled: false],
        plug_opts
      )

    c =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    c = Enum.reduce(extra_headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    c =
      if get_req_header(c, "mcp-session-id") != [] and
           get_req_header(c, "mcp-protocol-version") == [],
         do: put_req_header(c, "mcp-protocol-version", "2025-06-18"),
         else: c

    HttpPlug.call(c, mount_opts(init_opts))
  end

  defp initialize_session(plug_opts \\ []) do
    conn = post_request("/", initialize_request(), plug_opts: plug_opts)
    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  # ---------- 1. Session ID in response headers ----------

  describe "Mcp-Session-Id in response headers (MCP spec: server provides session ID)" do
    test "initialize response includes Mcp-Session-Id header" do
      conn = post_request("/", initialize_request())

      assert conn.status == 200

      session_ids = get_resp_header(conn, "mcp-session-id")

      assert length(session_ids) == 1,
             "Server MUST include Mcp-Session-Id header in initialize response, got: #{inspect(session_ids)}"

      [session_id] = session_ids
      assert is_binary(session_id) and byte_size(session_id) > 0
    end

    test "session ID is consistent across requests in same session" do
      # First request (initialize) should establish session
      conn1 = post_request("/", initialize_request())
      assert conn1.status == 200
      [session_id] = get_resp_header(conn1, "mcp-session-id")

      # Second request with same session ID should get same session back
      conn2 =
        post_request("/", tools_list_request(), headers: [{"mcp-session-id", session_id}])

      assert conn2.status == 200
      response_session_ids = get_resp_header(conn2, "mcp-session-id")

      # Server should echo back the session ID (or at minimum include one)
      assert length(response_session_ids) >= 1,
             "Server MUST include Mcp-Session-Id in subsequent responses"
    end

    test "tools/list response includes Mcp-Session-Id header" do
      session_id = initialize_session()

      conn =
        post_request("/", tools_list_request(), headers: [{"mcp-session-id", session_id}])

      assert conn.status == 200

      session_ids = get_resp_header(conn, "mcp-session-id")

      assert length(session_ids) == 1,
             "All POST responses MUST include Mcp-Session-Id header"
    end

    test "tools/call response includes Mcp-Session-Id header" do
      session_id = initialize_session()

      conn =
        post_request("/", tools_call_request(), headers: [{"mcp-session-id", session_id}])

      assert conn.status == 200

      session_ids = get_resp_header(conn, "mcp-session-id")

      assert length(session_ids) == 1,
             "All POST responses MUST include Mcp-Session-Id header"
    end
  end

  # ---------- 2. SSE endpoint path ----------

  describe "SSE endpoint path (MCP spec: GET on same path as POST)" do
    test "GET to root endpoint starts SSE connection" do
      # Per MCP spec, SSE GET should use the same endpoint as POST.
      # If POST goes to "/" then GET to "/" should start SSE.
      session_id = initialize_session(sse_enabled: true)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(mount_opts(handler: ComplianceTestServer, sse_enabled: true))

      # Should start SSE (200 with text/event-stream), not 404
      assert conn.status == 200,
             "GET to the same endpoint as POST should start SSE, got status #{conn.status}"

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    test "GET to /mcp endpoint starts SSE connection" do
      session_id = initialize_session(sse_enabled: true)

      conn =
        conn(:get, "/mcp")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(mount_opts(handler: ComplianceTestServer, sse_enabled: true))

      assert conn.status == 200,
             "GET to /mcp should start SSE when that's the MCP endpoint, got status #{conn.status}"

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "GET to /mcp/v1 endpoint starts SSE connection" do
      session_id = initialize_session(sse_enabled: true, path: "/mcp/v1")

      conn =
        conn(:get, "/mcp/v1")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(
          mount_opts(handler: ComplianceTestServer, sse_enabled: true, path: "/mcp/v1")
        )

      assert conn.status == 200,
             "GET to /mcp/v1 should start SSE, got status #{conn.status}"

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "headerless Streamable HTTP GET does not mint a session" do
      before_count = session_count()

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> HttpPlug.call(mount_opts(handler: ComplianceTestServer, sse_enabled: true))

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      assert session_count() == before_count
    end
  end

  # ---------- 3. POST responses in SSE mode ----------

  describe "POST responses in SSE mode (MCP spec: result in body)" do
    test "initialize returns 200 with response body when SSE is enabled" do
      conn =
        post_request("/", initialize_request(), plug_opts: [sse_enabled: true])

      assert conn.status == 200,
             "POST initialize MUST return 200 with body even in SSE mode, got #{conn.status}"

      assert conn.resp_body != "",
             "POST response body MUST NOT be empty"

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert Map.has_key?(response["result"], "protocolVersion")
      assert Map.has_key?(response["result"], "capabilities")
    end

    test "tools/list returns 200 with response body when SSE is enabled" do
      session_id = initialize_session(sse_enabled: true)

      conn =
        post_request("/", tools_list_request(),
          plug_opts: [sse_enabled: true],
          headers: [{"mcp-session-id", session_id}]
        )

      assert conn.status == 200,
             "POST tools/list MUST return 200 with body in SSE mode, got #{conn.status}"

      assert conn.resp_body != ""
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert Map.has_key?(response["result"], "tools")
    end

    test "tools/call returns 200 with response body when SSE is enabled" do
      session_id = initialize_session(sse_enabled: true)

      conn =
        post_request("/", tools_call_request(),
          plug_opts: [sse_enabled: true],
          headers: [{"mcp-session-id", session_id}]
        )

      assert conn.status == 200,
             "POST tools/call MUST return 200 with body in SSE mode, got #{conn.status}"

      assert conn.resp_body != ""
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert Map.has_key?(response["result"], "content")
    end

    test "notifications return 202 Accepted (no body needed)" do
      session_id = initialize_session(sse_enabled: true)

      conn =
        post_request("/", initialized_notification(),
          plug_opts: [sse_enabled: true],
          headers: [{"mcp-session-id", session_id}]
        )

      # Notifications (no id) SHOULD get 202 Accepted
      assert conn.status == 202,
             "Notifications should return 202 Accepted, got #{conn.status}"
    end
  end

  # ---------- 4. Protocol version header ----------

  describe "mcp-protocol-version response header" do
    test "POST response includes mcp-protocol-version header" do
      conn = post_request("/", initialize_request())

      assert conn.status == 200

      version_headers = get_resp_header(conn, "mcp-protocol-version")

      assert length(version_headers) == 1,
             "Response MUST include mcp-protocol-version header, got: #{inspect(version_headers)}"

      [version] = version_headers
      assert is_binary(version) and byte_size(version) > 0
    end

    test "protocol version header present in SSE mode responses" do
      session_id = initialize_session(sse_enabled: true)

      conn =
        post_request("/", tools_list_request(),
          plug_opts: [sse_enabled: true],
          headers: [{"mcp-session-id", session_id}]
        )

      # Whether SSE is enabled or not, POST responses need the version header
      version_headers = get_resp_header(conn, "mcp-protocol-version")

      assert length(version_headers) == 1,
             "Response MUST include mcp-protocol-version in SSE mode too"
    end

    test "error responses include mcp-protocol-version header" do
      # Invalid JSON should still get the protocol version header
      init_opts = [handler: ComplianceTestServer, sse_enabled: false]

      conn =
        conn(:post, "/", "invalid json")
        |> put_req_header("content-type", "application/json")
        |> HttpPlug.call(mount_opts(init_opts))

      assert conn.status == 400

      version_headers = get_resp_header(conn, "mcp-protocol-version")

      assert length(version_headers) == 1,
             "Error responses MUST include mcp-protocol-version header"
    end
  end

  defp mount_opts(options) do
    options =
      options
      |> Keyword.drop([:handler, :sse_enabled])
      |> Keyword.put(:runtime, Process.get(:compliance_runtime))
      |> Keyword.put_new(:sse_mode, :oneshot)

    HttpPlug.init(options)
  end

  defp session_count do
    {:ok, service} = Runtime.service(Process.get(:compliance_runtime), :sessions)
    {:ok, stats} = SessionManager.get_stats(service, [])
    stats.sessions
  end
end
