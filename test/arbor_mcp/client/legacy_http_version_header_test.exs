defmodule Arbor.MCP.Client.LegacyHTTPVersionHeaderTest do
  @moduledoc """
  The HTTP transport's `MCP-Protocol-Version` header must name the version
  the server selected in `initialize` from the first message after the
  handshake, `notifications/initialized` included. A strict server rejects a
  header that disagrees with the negotiated version.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.Server.Discover
  alias Arbor.MCP.Transport.HTTP

  @negotiated "2025-03-26"

  setup do
    bypass = Bypass.open()
    test_pid = self()
    path = "/mcp/#{System.unique_integer([:positive, :monotonic])}"

    # Era observations outlive clients and identify the endpoint, not the listener PID.
    Bypass.expect(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      header = Plug.Conn.get_req_header(conn, "mcp-protocol-version")
      send(test_pid, {:strict_server, message["method"], header})
      respond(conn, message, header)
    end)

    %{bypass: bypass, path: path, url: "http://127.0.0.1:#{bypass.port}#{path}"}
  end

  for mode <- [:legacy_only, :prefer_legacy, :prefer_modern] do
    test "notifications/initialized carries the negotiated version in #{mode}", %{url: url} do
      assert {:ok, client} =
               Client.start_link(
                 transport: :http,
                 url: url,
                 use_sse: false,
                 protocol_mode: unquote(mode),
                 health_check_interval: nil,
                 reconnect: false
               )

      assert_receive {:strict_server, "initialize", _requested}, 2_000
      assert_receive {:strict_server, "notifications/initialized", [@negotiated]}, 2_000
      assert {:ok, @negotiated} = Client.negotiated_version(client)

      assert {:ok, _pong} = Client.ping(client)
      assert_receive {:strict_server, "ping", [@negotiated]}, 2_000

      Client.stop(client)
    end
  end

  test "modern_only never falls back to initialize against the strict older server", %{
    url: url
  } do
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Client.start_link(
               transport: :http,
               url: url,
               use_sse: false,
               protocol_mode: :modern_only,
               health_check_interval: nil,
               reconnect: false
             )

    assert_receive {:strict_server, "server/discover", _header}, 2_000
    refute_received {:strict_server, "initialize", _header}
  end

  test "a real modern pin stays on its endpoint while an isolated legacy endpoint initializes", %{
    bypass: bypass,
    path: path,
    url: url
  } do
    test_pid = self()
    modern_path = "/mcp/pinned-#{System.unique_integer([:positive, :monotonic])}"
    modern_url = "http://127.0.0.1:#{bypass.port}#{modern_path}"

    Bypass.expect_once(bypass, "POST", modern_path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["method"] == "server/discover"

      result =
        Discover.build(%{"name" => "modern-pin-server", "version" => "1"}, %{},
          protocol_mode: :modern_only
        )

      json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "result" => Map.put(result, "resultType", "complete")
      })
    end)

    assert {:ok, modern} = start_client(modern_url, :modern_only)
    on_exit(fn -> stop_if_alive(modern) end)
    modern_state = :sys.get_state(modern)
    assert modern_state.transport_mod == HTTP
    modern_transport = modern_state.transport_state
    assert %HTTP{} = modern_transport
    modern_identity = EraCache.identity(HTTP, modern_transport, modern_state.transport_opts)

    assert {:ok, %{era: :modern, protocol_version: "2026-07-28", expires_at: :infinity}} =
             EraCache.lookup(modern_identity)

    # Project only the endpoint for a read-only identity lookup before connecting.
    # The actual legacy transport below must produce this same identity.
    legacy_identity =
      EraCache.identity(HTTP, %{modern_transport | endpoint: path}, modern_state.transport_opts)

    refute legacy_identity == modern_identity
    assert EraCache.lookup(legacy_identity) == :miss
    assert :ok = Client.stop(modern)

    Bypass.expect_once(bypass, "POST", modern_path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      header = Plug.Conn.get_req_header(conn, "mcp-protocol-version")
      send(test_pid, {:pinned_server, message["method"], header})
      respond(conn, message, header)
    end)

    Process.flag(:trap_exit, true)

    assert {:error, {:transport_connect_failed, reason}} =
             start_client(modern_url, :prefer_legacy)

    assert reason =~ "pinned_modern_era_probe_failed"
    assert_receive {:pinned_server, "server/discover", ["2026-07-28"]}, 2_000
    refute_received {:pinned_server, "initialize", _header}

    assert {:ok, legacy} = start_client(url, :prefer_legacy)
    on_exit(fn -> stop_if_alive(legacy) end)
    assert_receive {:strict_server, "initialize", _requested}, 2_000
    assert_receive {:strict_server, "notifications/initialized", [@negotiated]}, 2_000
    assert {:ok, @negotiated} = Client.negotiated_version(legacy)
    assert {:ok, _pong} = Client.ping(legacy)
    assert_receive {:strict_server, "ping", [@negotiated]}, 2_000
    legacy_state = :sys.get_state(legacy)

    assert EraCache.identity(
             legacy_state.transport_mod,
             legacy_state.transport_state,
             legacy_state.transport_opts
           ) == legacy_identity

    assert {:ok, %{era: :modern, protocol_version: "2026-07-28", expires_at: :infinity}} =
             EraCache.lookup(modern_identity)

    assert :ok = Client.stop(legacy)
  end

  defp start_client(url, mode) do
    Client.start_link(
      transport: :http,
      url: url,
      use_sse: false,
      protocol_mode: mode,
      health_check_interval: nil,
      reconnect: false
    )
  end

  defp stop_if_alive(client) do
    if Process.alive?(client), do: Client.stop(client)
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _header) do
    json(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @negotiated,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "strict-older-server", "version" => "1"}
      }
    })
  end

  defp respond(conn, %{"method" => _method} = message, header) when header != [@negotiated] do
    json(conn, 400, %{
      "jsonrpc" => "2.0",
      "id" => message["id"],
      "error" => %{"code" => -32600, "message" => "Unsupported MCP-Protocol-Version"}
    })
  end

  defp respond(conn, %{"method" => "notifications/initialized"}, _header) do
    Plug.Conn.resp(conn, 202, "")
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, _header) do
    json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
