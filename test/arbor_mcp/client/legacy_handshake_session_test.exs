defmodule Arbor.MCP.Client.LegacyHandshakeSessionTest do
  @moduledoc """
  The HTTP transport adopts the version `initialize` negotiated before
  `notifications/initialized` is sent, but the handshake stays in the legacy
  era until establishment settles it: the session `initialize` minted must
  still travel with `notifications/initialized`, whatever version string the
  server chose.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  test "notifications/initialized keeps the session initialize minted" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2026-07-28",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "session-minting", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-from-initialize")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          )

        %{"method" => "notifications/initialized"} ->
          send(
            test_pid,
            {:initialized,
             %{
               session: Plug.Conn.get_req_header(conn, "mcp-session-id"),
               version: Plug.Conn.get_req_header(conn, "mcp-protocol-version")
             }}
          )

          Plug.Conn.resp(conn, 202, "")

        _other ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn -> Plug.Conn.resp(conn, 204, "") end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: false,
        protocol_mode: :prefer_legacy,
        health_check_interval: nil,
        reconnect: false
      )

    assert_receive {:initialized, headers}, 2_000
    assert headers.session == ["session-from-initialize"]
    assert headers.version == ["2026-07-28"]

    Client.stop(client)
  end
end
