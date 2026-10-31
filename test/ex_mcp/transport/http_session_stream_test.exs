defmodule ExMCP.Transport.HTTPSessionStreamTest do
  # The legacy Streamable HTTP session GET stream on the client side: the SSE
  # client hands each event to whichever process reads the stream, and the
  # HTTP transport's reader skips events that aren't MCP messages and outlives
  # the stream closing.
  use ExUnit.Case, async: true

  alias ExMCP.Transport.{HTTP, SSEClient}

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

    test "a 404 ends an established legacy session", %{state: state, sse: sse} do
      state = %{state | session_id: "expired-session"}
      send(self(), {:sse_error, sse, {:http_error, 404}})

      assert {:error, {:session_expired, {:sse_error, {:http_error, 404}}}} =
               HTTP.receive_message(state)
    end

    test "still ends on a stream error", %{state: state, sse: sse} do
      send(self(), {:sse_error, sse, {:http_error, 404}})
      assert {:error, {:sse_error, {:http_error, 404}}} = HTTP.receive_message(state)
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
