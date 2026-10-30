defmodule Arbor.MCP.Transport.HTTPSessionExpiryTest do
  # A legacy Streamable HTTP server answers 404 to a request that carries a
  # session it has ended (Session Management, 2025-03-26 and later). The
  # transport reports that as `{:session_expired, {:http_error, 404, body}}`,
  # on a synchronous send and on a POST task's, so the client can start a new
  # session. Any other 404 stays `{:http_error, 404, body}`: one for a request
  # without a session id, and every modern one, since a 2026-07-28 request
  # never carries a session.
  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP

  @not_found ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Session not found"}})
  @legacy %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

  setup do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      send(test, {:session_header, Plug.Conn.get_req_header(conn, "mcp-session-id")})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, @not_found)
    end)

    {:ok, transport} =
      HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)

    %{transport: transport}
  end

  describe "a 404 for a legacy request carrying the session" do
    test "is a session expiry on a synchronous send", %{transport: transport} do
      transport = legacy(transport, "ended-session")

      assert {:error, {:session_expired, {:http_error, 404, @not_found}}} =
               HTTP.send_message(Jason.encode!(@legacy), transport)

      assert_received {:session_header, ["ended-session"]}
    end

    test "is a session expiry on a POST task's send", %{transport: transport} do
      transport = legacy(transport, "ended-session")

      assert {:ok, _transport} = HTTP.send_async(Jason.encode!(@legacy), transport)

      assert_receive {:async_post_result, {:error, reason}, %{request_id: 1}}, 2_000
      assert reason == {:session_expired, {:http_error, 404, @not_found}}
      assert_received {:session_header, ["ended-session"]}
    end

    test "is a session expiry for a notification too", %{transport: transport} do
      transport = legacy(transport, "ended-session")
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/roots/list_changed"}

      assert {:error, {:session_expired, {:http_error, 404, _body}}} =
               HTTP.send_message(Jason.encode!(notification), transport)
    end
  end

  test "a 404 for a request without a session stays an HTTP error", %{transport: transport} do
    transport = legacy(transport, nil)

    assert {:error, {:http_error, 404, @not_found}} =
             HTTP.send_message(Jason.encode!(@legacy), transport)

    assert_received {:session_header, []}
  end

  test "a 404 for a modern request stays an HTTP error", %{transport: transport} do
    transport = HTTP.settle_protocol_era(transport, :modern, "2026-07-28")

    request =
      put_in(@legacy, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
      })

    assert {:error, {:http_error, 404, @not_found}} =
             HTTP.send_message(Jason.encode!(request), transport)

    assert_received {:session_header, []}
  end

  # Before establishment settles, a modern request (the server/discover
  # probe) leaves out a configured session, so its 404 isn't the session's.
  test "a 404 for a modern request is no session expiry while the era is unsettled",
       %{transport: transport} do
    transport = %{transport | session_id: "configured-session"}

    probe = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      }
    }

    assert {:error, {:http_error, 404, @not_found}} =
             HTTP.send_message(Jason.encode!(probe), transport)

    assert_received {:session_header, []}
  end

  defp legacy(transport, session) do
    transport
    |> HTTP.settle_protocol_era(:legacy, "2025-11-25")
    |> Map.put(:session_id, session)
  end
end
