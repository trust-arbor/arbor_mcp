defmodule Arbor.MCP.Transport.HTTPSessionStreamTest do
  # The legacy Streamable HTTP session GET stream on the client side: the SSE
  # client hands each event to whichever process reads the stream, and the
  # HTTP transport's reader skips events that aren't MCP messages, outlives
  # the stream closing, and stops when the server no longer offers it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Client.ConnectionManager
  alias Arbor.MCP.Transport.{HTTP, SSEClient}

  describe "SSEClient consumer" do
    test "an event sent to a process that doesn't read the stream goes to the one that takes over" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/mcp", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: connected\ndata: {}\n\ndata: second\n\n")
      end)

      # The client process opens the GET stream before its receiver starts,
      # as the HTTP transport does; it forwards what it gets but never acks.
      test = self()
      opener = spawn_link(fn -> forward(test) end)
      {:ok, pid} = start_sse(bypass, parent: opener)

      assert_receive {:opener, {:sse_event, ^pid, %{type: "connected", data: "{}"}}}, 5_000
      send(pid, {:change_parent, self()})

      assert_receive {:sse_event, ^pid, %{type: "connected", data: "{}"}}, 1_000
      send(pid, {:sse_event_ack, self()})
      assert_receive {:sse_event, ^pid, %{data: "second"}}, 1_000
      send(pid, {:sse_event_ack, self()})
      refute_received {:opener, {:sse_event, ^pid, %{data: "second"}}}
      assert_stream_end(pid)
    end

    test "a consumer that takes over again gets each event once" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/mcp", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "data: first\n\ndata: second\n\n")
      end)

      {:ok, pid} = start_sse(bypass, parent: self())
      assert_receive {:sse_event, ^pid, %{data: "first"}}, 5_000
      send(pid, {:change_parent, self()})
      send(pid, {:sse_event_ack, self()})

      # Events reach a consumer in order, so a second copy of the first
      # would arrive ahead of the second.
      assert_receive {:sse_event, ^pid, %{data: "second"}}, 1_000
      send(pid, {:sse_event_ack, self()})
      refute_received {:sse_event, ^pid, %{data: "first"}}
      assert_stream_end(pid)
    end
  end

  describe "HTTP.receive_message/1 on the session GET stream" do
    setup do
      {:ok, state} = HTTP.connect(url: "http://127.0.0.1:1/mcp", use_sse: true)
      test = self()
      sse = spawn_link(fn -> forward(test) end)
      %{state: %{state | sse_pid: sse}, sse: sse}
    end

    test "skips events that aren't MCP messages and a closed stream", %{state: state, sse: sse} do
      message = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      send(self(), {:sse_event, sse, %{type: "connected", data: ~s({"session_id":"s"}), id: nil}})
      send(self(), {:sse_closed, sse})
      send(self(), {:sse_event, sse, %{type: "message", data: Jason.encode!(message), id: "7"}})

      assert {:ok, ^message, next} = HTTP.receive_message(state)
      assert next.last_event_id == "7"

      # Both events were acknowledged, so the SSE client could go on.
      assert_receive {:opener, {:sse_event_ack, _reader}}
      assert_receive {:opener, {:sse_event_ack, _reader}}
    end

    test "still ends on a stream error", %{state: state, sse: sse} do
      send(self(), {:sse_error, sse, {:http_error, 404}})
      assert {:error, {:sse_error, {:http_error, 404}}} = HTTP.receive_message(state)
    end

    # The GET carries the session's Mcp-Session-Id, so its 404 means the
    # server ended the session, as one for a POST does.
    test "reports a 404 for the session's stream as the session's end",
         %{state: state, sse: sse} do
      state = %{state | session_id: "ended-session"}

      send(self(), {:sse_error, sse, {:http_error, 404}})

      assert {:error, {:session_expired, {:sse_error, {:http_error, 404}}}} =
               HTTP.receive_message(state)

      send(self(), {:sse_error, sse, {:http_error, 500}})
      assert {:error, {:sse_error, {:http_error, 500}}} = HTTP.receive_message(state)
    end

    # A 405 for the reopened GET: the SSE client gives up, so the reader must
    # stop rather than wait for events that won't come.
    test "stops when the server no longer offers the stream", %{state: state, sse: sse} do
      reader =
        Task.async(fn ->
          receive do
            :read -> HTTP.receive_message(state)
          end
        end)

      send(reader.pid, {:sse_closed, sse})
      send(reader.pid, {:sse_not_supported, sse})
      send(reader.pid, :read)

      assert {:ok, {:error, :stream_withdrawn}} =
               Task.yield(reader, 1_000) || Task.shutdown(reader, :brutal_kill)
    end
  end

  describe "ConnectionManager.receive_loop/3" do
    defmodule WithdrawnTransport do
      def receive_message(:withdrawn), do: {:error, :stream_withdrawn}
    end

    test "ends without closing the connection when its stream is withdrawn" do
      assert :ok = ConnectionManager.receive_loop(self(), WithdrawnTransport, :withdrawn)
      assert_received {:transport_receiver_stopped, reader} when reader == self()
      refute_received {:transport_closed, _reason}
    end

    defmodule EndedSessionTransport do
      def receive_message(:ended),
        do: {:error, {:session_expired, {:sse_error, {:http_error, 404}}}}
    end

    # The server ending a session is no transport fault, so it isn't logged
    # as one: the client starts a new session.
    test "hands the client a session's end without logging a transport error" do
      log =
        capture_log(fn ->
          assert :ok = ConnectionManager.receive_loop(self(), EndedSessionTransport, :ended)
        end)

      assert_received {:transport_closed, {:session_expired, {:sse_error, {:http_error, 404}}}}

      refute log =~ "Transport error in receive loop"
    end
  end

  # Without reconnection the SSE client stops when the stream ends, and tells
  # its current consumer.
  defp assert_stream_end(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:sse_closed, ^pid}, 1_000

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason} when reason in [:normal, :noproc],
                   1_000
  end

  defp forward(test) do
    receive do
      message ->
        send(test, {:opener, message})
        forward(test)
    end
  end

  defp start_sse(bypass, overrides) do
    defaults = [
      url: "http://127.0.0.1:#{bypass.port}/mcp",
      connect_timeout: 500,
      handshake_timeout: 5_000,
      idle_timeout: 5_000,
      consumer_ack_timeout: 5_000,
      reconnect: false
    ]

    SSEClient.start_link(Keyword.merge(defaults, overrides))
  end
end
