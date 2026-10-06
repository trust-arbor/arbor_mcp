defmodule Arbor.MCP.ProtocolVersionTest do
  @moduledoc """
  Tests for MCP Protocol Version header validation.

  Tests the implementation of the 2025-06-18 specification requirement
  that HTTP transport must include MCP-Protocol-Version headers.
  """
  # Cannot be async: modifies global Application env (:protocol_version_required)
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def handle_list_tools(_cursor, state),
      do: {:ok, [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}], nil, state}

    def handle_call_tool("echo", params, state),
      do: {:ok, %{"content" => [], "structuredContent" => params}, state}
  end

  setup do
    # Enable protocol version header validation for tests
    original_value = Application.get_env(:arbor_mcp, :protocol_version_required)
    Application.put_env(:arbor_mcp, :protocol_version_required, true)

    on_exit(fn ->
      if original_value do
        Application.put_env(:arbor_mcp, :protocol_version_required, original_value)
      else
        Application.delete_env(:arbor_mcp, :protocol_version_required)
      end
    end)

    runtime = RuntimeHTTPFixture.start(Handler)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only)

    {:ok, opts: opts}
  end

  defp initialize_session(opts) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "protocol-version-test", "version" => "1.0.0"}
      },
      "id" => 0
    }

    conn =
      conn(:post, "/", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> HttpPlug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  describe "request validation" do
    test "initialization negotiates from the body without an HTTP version header", %{opts: opts} do
      session_id = initialize_session(opts)

      assert {:ok, %{protocol_version: "2025-06-18"}} =
               RuntimeHTTPFixture.session_state(opts.runtime, session_id)
    end

    test "accepts requests with correct protocol version header", %{opts: opts} do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(opts)

      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["result"]["structuredContent"] == %{"message" => "hello"}
    end

    test "rejects requests with incorrect protocol version", %{opts: opts} do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2024-01-01")
        |> HttpPlug.call(opts)

      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32600

      assert response["error"]["message"] =~
               "MCP-Protocol-Version does not match the negotiated version."

      assert response["error"]["data"]["expectedVersion"] == "2025-06-18"
    end

    test "rejects requests missing protocol version header", %{opts: opts} do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> HttpPlug.call(opts)

      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] =~ "Missing MCP-Protocol-Version header"
      assert response["error"]["data"]["expectedVersion"] == "2025-06-18"
    end

    test "accepts a compatible header while retaining the negotiated session version", %{
      opts: opts
    } do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> HttpPlug.call(opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["id"] == 1
      assert response["result"]["structuredContent"] == %{"message" => "hello"}
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]

      assert {:ok, %{protocol_version: "2025-06-18"}} =
               RuntimeHTTPFixture.session_state(opts.runtime, session_id)
    end
  end

  describe "response headers" do
    test "includes protocol version header in successful responses", %{opts: opts} do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end

    test "includes protocol version header in error responses", %{opts: opts} do
      session_id = initialize_session(opts)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "wrong-version")
        |> HttpPlug.call(opts)

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end
  end

  describe "feature flag" do
    test "bypasses validation when feature flag is disabled", %{opts: opts} do
      session_id = initialize_session(opts)

      # Disable the feature flag
      Application.put_env(:arbor_mcp, :protocol_version_required, false)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      # Request without protocol version header should still work
      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> HttpPlug.call(opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["structuredContent"] == %{"message" => "hello"}

      # Per MCP spec, server MUST always include mcp-protocol-version in responses,
      # even when incoming validation is disabled by feature flag
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end

    test "still rejects an explicitly invalid header when missing-header enforcement is disabled",
         %{
           opts: opts
         } do
      session_id = initialize_session(opts)
      Application.put_env(:arbor_mcp, :protocol_version_required, false)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}},
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "invalid")
        |> HttpPlug.call(opts)

      assert conn.status == 400

      assert Jason.decode!(conn.resp_body)["error"]["message"] =~
               "MCP-Protocol-Version does not match the negotiated version."
    end
  end

  describe "CORS integration" do
    test "includes mcp-protocol-version in allowed headers", %{opts: opts} do
      cors_opts = Map.put(opts, :cors_enabled, true)

      conn =
        conn(:options, "/")
        |> HttpPlug.call(cors_opts)

      assert conn.status == 200
      allowed_headers = get_resp_header(conn, "access-control-allow-headers")
      assert length(allowed_headers) == 1
      assert allowed_headers |> hd() |> String.contains?("mcp-protocol-version")
    end
  end
end
