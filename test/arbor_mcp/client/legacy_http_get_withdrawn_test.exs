defmodule Arbor.MCP.Client.LegacyHTTPGetWithdrawnTest do
  # A legacy Streamable HTTP server closes its GET stream, and answers the
  # client's reopened GET with 405: it no longer offers one. The client keeps
  # its session and goes on POST-only, as with a server that never offered a
  # GET stream, and its receiver stops instead of waiting for events.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

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
        [:arbor_mcp, :client, :disconnected],
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
         transport: :http,
         url: url,
         protocol_mode: :legacy_only,
         protocol_version: @version,
         health_check_interval: nil,
         reconnect: false}
      )

    %Task{pid: receiver} = :sys.get_state(client).receiver_task
    monitor = Process.monitor(receiver)
    {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

    # The receiver reads the first GET stream.
    assert_receive {:get_opened, stream}, 2_000
    send(stream, :notify)

    assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _params},
                   2_000

    # The server closes it, and answers the reopened GET with 405.
    send(stream, :close)
    assert_receive {:get, 2}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 2_000

    assert {:ok, _pong} = Client.ping(client, timeout: 2_000)
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

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
    {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(notification) <> "\n\n")

    receive do
      :close -> conn
    end
  end

  defp answer(conn, %{"method" => "initialize", "id" => id}) do
    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", @session)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @version,
        "capabilities" => %{"tools" => %{"listChanged" => true}},
        "serverInfo" => %{"name" => "withdrawn", "version" => "1"}
      }
    })
  end

  defp answer(conn, %{"id" => id}),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp answer(conn, _notification), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
