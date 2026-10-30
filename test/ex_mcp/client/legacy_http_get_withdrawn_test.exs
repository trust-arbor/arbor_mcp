defmodule ExMCP.Client.LegacyHTTPGetWithdrawnTest do
  # A legacy Streamable HTTP server closes its GET stream, and answers the
  # client's reopened GET with 405: it no longer offers one. The client keeps
  # its session and goes on POST-only, as with a server that never offered a
  # GET stream, and its receiver stops instead of waiting for events that
  # won't come (port of the 2.x regression test for that fix).
  use ExUnit.Case, async: false

  alias ExMCP.Client

  @version "2025-11-25"
  @session "withdrawn-session"

  @doc false
  def handle_disconnected(_event, _measurements, _meta, owner),
    do: send(owner, {:client_disconnected, self()})

  setup do
    bypass = Bypass.open()
    test = self()
    gets = start_supervised!({Agent, fn -> 0 end})

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      answer(conn, Jason.decode!(body))
    end)

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      case Agent.get_and_update(gets, &{&1 + 1, &1 + 1}) do
        1 -> hold_stream(conn, test)
        n -> send(test, {:get, n}) && Plug.Conn.resp(conn, 405, "")
      end
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    telemetry = "legacy-get-withdrawn-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry,
        [:ex_mcp, :client, :disconnected],
        &__MODULE__.handle_disconnected/4,
        test
      )

    on_exit(fn -> :telemetry.detach(telemetry) end)
    %{url: "http://127.0.0.1:#{bypass.port}/mcp"}
  end

  test "a 405 for the reopened GET stream leaves the connection up without its receiver",
       %{url: url} do
    client =
      start_supervised!(
        {Client,
         [
           transport: :http,
           url: url,
           protocol_mode: :legacy_only,
           protocol_version: @version,
           use_sse: true,
           health_check_interval: nil,
           reconnect: false
         ]}
      )

    %Task{pid: receiver} = :sys.get_state(client).receiver_task
    monitor = Process.monitor(receiver)
    {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

    # The receiver reads the first GET stream.
    assert_receive {:get_opened, stream}, 5_000
    send(stream, :notify)

    assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _params},
                   5_000

    # The server closes it, and answers the reopened GET with 405.
    send(stream, :close)
    assert_receive {:get, 2}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 5_000

    assert {:ok, _pong} = Client.ping(client, timeout: 5_000)
    assert Process.alive?(client)
    refute_received {:client_disconnected, ^client}
  end

  # The first GET sets a short retry, forwards one notification when the
  # test asks, and ends when the test says so.
  defp hold_stream(conn, test) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "retry: 10\n\n")
    send(test, {:get_opened, self()})

    receive do
      :notify -> :ok
    end

    # With params: a legacy peer on this line does not yet parse a
    # notification that leaves them out (the 2.x parser does).
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed",
      "params" => %{}
    }

    {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(notification) <> "\n\n")

    receive do
      :close -> conn
    end
  end

  defp answer(conn, %{"method" => "initialize", "id" => id}) do
    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", @session)
    |> json(id, %{
      "protocolVersion" => @version,
      "capabilities" => %{},
      "serverInfo" => %{"name" => "withdrawn", "version" => "1"}
    })
  end

  defp answer(conn, %{"id" => id}) do
    json(conn, id, %{})
  end

  defp answer(conn, _notification) do
    Plug.Conn.resp(conn, 202, "")
  end

  defp json(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end
end
