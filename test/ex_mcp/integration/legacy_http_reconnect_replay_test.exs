defmodule ExMCP.Integration.LegacyHTTPReconnectReplayTest do
  @moduledoc """
  A notification persisted while a legacy session's GET stream is closed must
  reach the client when the stream reopens: the client resumes by
  `Last-Event-ID`, and the server's `connected` greeting carries no id of its
  own. It used to carry a wall-clock id outside the session's replay
  sequence, and a client that adopted it as its resume point saw every
  persisted event as older than it, so a notification stored during the
  reconnect gap never replayed.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.HttpPlug

  defmodule Handler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_call_tool("noop", _args, state), do: {:ok, %{content: []}, state}
  end

  @notification %{
    "jsonrpc" => "2.0",
    "method" => "notifications/tools/list_changed",
    "params" => %{}
  }

  test "a notification stored while the GET stream is closed replays on reopen" do
    port = free_port()
    ref = {:legacy_reconnect_replay, System.unique_integer([:positive])}

    {:ok, _listener} =
      Plug.Cowboy.http(
        HttpPlug,
        [
          handler: Handler,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          sse_mode: :stream,
          allowed_origins: ["http://127.0.0.1:#{port}"],
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :legacy_only,
        protocol_version: "2025-11-25",
        use_sse: true,
        health_check_interval: nil,
        reconnect: true
      )

    try do
      {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})
      assert {:ok, _} = Client.call_tool(client, "noop", %{}, timeout: 5_000, format: :map)

      session_id = :sys.get_state(client).transport_state.session_id

      # Wait for the GET stream to be live, then close it server-side: the
      # client keeps its session and opens the stream again.
      :ok =
        ExMCP.TestHelpers.wait_until(fn ->
          match?({:ok, _}, HttpPlug.SessionRegistry.lookup(session_id))
        end)

      {:ok, handler} = HttpPlug.SessionRegistry.lookup(session_id)
      :ok = HttpPlug.SSEHandler.close(handler)

      # With no live stream the notification is only persisted, for replay.
      assert :stored = HttpPlug.deliver_session_notification(session_id, @notification)

      # The reopened stream replays it to the listener.
      assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _},
                     5_000
    after
      if Process.alive?(client), do: Client.stop(client)
      Plug.Cowboy.shutdown(ref)
    end
  catch
    :exit, _reason -> :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
