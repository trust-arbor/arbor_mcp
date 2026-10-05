defmodule Arbor.MCP.HttpPlug.SSEHandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.HttpPlug.SessionRegistry
  alias Arbor.MCP.HttpPlug.SSEHandler
  alias Arbor.MCP.SessionManager

  setup do
    start_supervised!(SessionManager)
    start_supervised!(SessionRegistry)
    :ok
  end

  # Test double for the SSE socket. A hand-written in-process stub implementing
  # the `Arbor.MCP.HttpPlug.SSEConnection` behaviour — no mocking library needed.
  # Injected through the handler's `:conn_module` option instead of being
  # duck-typed at runtime (audit L6).
  defmodule MockConn do
    @behaviour Arbor.MCP.HttpPlug.SSEConnection

    defstruct chunks: [], headers: %{}

    def new(headers \\ %{}), do: %__MODULE__{headers: headers}

    @impl true
    def chunk(%__MODULE__{} = conn, data) do
      {:ok, %{conn | chunks: conn.chunks ++ [data]}}
    end

    @impl true
    def get_req_header(%__MODULE__{} = conn, header) do
      Map.get(conn.headers, header, [])
    end
  end

  # Options every handler in this module starts with.
  defp opts, do: %{conn_module: MockConn}

  describe "backpressure control" do
    test "implements backpressure control mechanism" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # Verify that the handler module exports the backpressure functions
      assert function_exported?(SSEHandler, :request_send, 1)
      assert function_exported?(SSEHandler, :send_event, 4)

      # Test the basic flow: request permission, then send
      assert :ok = SSEHandler.request_send(handler)
      SSEHandler.send_event(handler, "test", %{data: "hello"})

      # send_event/4 is a cast from this process; :sys.get_state/1 is a call
      # from the same process, so it is guaranteed to be handled after it.
      state = :sys.get_state(handler)
      # Connected event + our test event
      assert length(state.conn.chunks) >= 2

      # Verify that the handler tracks producers set for backpressure
      assert Map.has_key?(state, :producers)
      assert is_struct(state.producers, MapSet)

      SSEHandler.close(handler)
    end

    test "unblocks producers when mailbox drains" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # First request should succeed immediately
      assert :ok = SSEHandler.request_send(handler)

      # Send an event
      SSEHandler.send_event(handler, "test", %{data: "test"})

      # Flush the cast: this call is ordered after it.
      _ = :sys.get_state(handler)

      # Next request should also succeed
      assert :ok = SSEHandler.request_send(handler)

      SSEHandler.close(handler)
    end

    test "returns error when connection is closed" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # Monitor the handler process
      ref = Process.monitor(handler)

      # Close the handler
      SSEHandler.close(handler)

      # Wait for the handler to stop
      assert_receive {:DOWN, ^ref, :process, ^handler, :normal}, 1000

      # Request should return error (process no longer exists)
      assert catch_exit(SSEHandler.request_send(handler))
    end
  end

  describe "SSE event formatting" do
    test "supports the raw endpoint handshake required by legacy HTTP+SSE" do
      conn = MockConn.new()

      {:ok, handler} =
        SSEHandler.start_link(conn, "test_session", %{
          conn_module: MockConn,
          initial_sse_event: {"endpoint", {:raw, "https://example.test/message?sessionId=test"}}
        })

      [initial_chunk | _] = :sys.get_state(handler).conn.chunks
      assert initial_chunk =~ "event: endpoint"
      assert initial_chunk =~ "data: https://example.test/message?sessionId=test"
      refute initial_chunk =~ ~s(data: "https://)

      SSEHandler.close(handler)
    end

    test "sends events with proper SSE format" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # The initial connection event is written in init/1, so it is already
      # there once start_link/3 returns.
      assert :ok = SSEHandler.request_send(handler)
      SSEHandler.send_event(handler, "test_event", %{message: "hello"})

      # Get the handler state to check chunks (ordered after the cast above)
      state = :sys.get_state(handler)
      chunks = state.conn.chunks

      # Should have initial connection event and our test event
      assert length(chunks) >= 2

      # Check format of last event
      last_chunk = List.last(chunks)
      assert last_chunk =~ "event: test_event"
      assert last_chunk =~ "data: {\"message\":\"hello\"}"
      assert last_chunk =~ "id: "

      SSEHandler.close(handler)
    end

    test "sends error events and closes connection" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      ref = Process.monitor(handler)

      # Send error
      SSEHandler.send_error(handler, {:test_error, "Something went wrong"})

      # The handler writes the error event and then stops itself.
      assert_receive {:DOWN, ^ref, :process, ^handler, _reason}, 1000
      refute Process.alive?(handler)
    end
  end

  describe "Last-Event-ID support" do
    test "extracts Last-Event-ID from headers" do
      conn = MockConn.new(%{"last-event-id" => ["event-123"]})
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # Get state to check if last_event_id was extracted
      state = :sys.get_state(handler)
      assert state.last_event_id == "event-123"

      SSEHandler.close(handler)
    end

    test "handles missing Last-Event-ID header" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # Get state to check last_event_id is nil
      state = :sys.get_state(handler)
      assert state.last_event_id == nil

      SSEHandler.close(handler)
    end

    test "persists live events and replays gap events on reconnect" do
      session_id = SessionManager.create_session(%{transport: :sse})

      on_exit(fn ->
        SessionRegistry.unregister(session_id)
      end)

      managed_opts = Map.put(opts(), :session_manager, SessionManager)

      {:ok, first_handler} = SSEHandler.start_link(MockConn.new(), session_id, managed_opts)
      :ok = SessionRegistry.register(session_id, first_handler)

      assert :ok = SSEHandler.request_send(first_handler)
      SSEHandler.send_event(first_handler, "message", %{message: "before-gap"})
      _state = :sys.get_state(first_handler)

      assert [first_event] = SessionManager.replay_events_after(session_id, nil)
      assert first_event.data == %{message: "before-gap"}

      SSEHandler.close(first_handler)

      assert {:ok, gap_event} =
               SessionManager.append_event(session_id, "message", %{message: "during-gap"})

      reconnect_conn =
        MockConn.new(%{"last-event-id" => [first_event.id]})

      {:ok, second_handler} = SSEHandler.start_link(reconnect_conn, session_id, managed_opts)
      :ok = SessionRegistry.register(session_id, second_handler)
      assert :ok = SSEHandler.replay(second_handler)

      chunks = :sys.get_state(second_handler).conn.chunks
      replayed_chunk = List.last(chunks)

      assert replayed_chunk =~ "id: #{gap_event.id}"
      assert replayed_chunk =~ "event: message"
      assert replayed_chunk =~ ~s(data: {"message":"during-gap"})
      refute Enum.any?(chunks, &String.contains?(&1, "before-gap"))

      # Replay delivery must not append a duplicate copy to persistent history.
      assert [^first_event, ^gap_event] = SessionManager.replay_events_after(session_id, nil)

      SSEHandler.close(second_handler)
    end
  end

  describe "heartbeat mechanism" do
    test "sends periodic heartbeats" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      initial_chunks = length(:sys.get_state(handler).conn.chunks)

      # Trigger heartbeat manually; the following :sys.get_state/1 call is
      # ordered behind the :heartbeat message we just sent.
      send(handler, :heartbeat)

      # Should have one more chunk
      final_chunks = length(:sys.get_state(handler).conn.chunks)
      assert final_chunks > initial_chunks

      # Check last chunk is a heartbeat
      last_chunk = List.last(:sys.get_state(handler).conn.chunks)
      assert last_chunk =~ "event: heartbeat"
      assert last_chunk =~ "timestamp"

      SSEHandler.close(handler)
    end
  end

  describe "event buffering" do
    test "buffers events for potential replay" do
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, "test_session", opts())

      # Send multiple events
      for i <- 1..5 do
        assert :ok = SSEHandler.request_send(handler)
        SSEHandler.send_event(handler, "event_#{i}", %{index: i})
      end

      # Check buffer contains events (this call drains the casts above)
      state = :sys.get_state(handler)
      buffer_size = :queue.len(state.event_buffer)
      assert buffer_size >= 5

      SSEHandler.close(handler)
    end
  end

  describe "session registry cleanup" do
    setup do
      # The registry is normally started by the :arbor_mcp application; start it
      # here only when running without the application (e.g. --no-start).
      if Process.whereis(SessionRegistry) == nil do
        start_supervised!(SessionRegistry)
      end

      :ok
    end

    test "conn owner exit stops the handler and removes the ETS entry" do
      session_id = "owner-exit-#{System.unique_integer([:positive])}"
      test_pid = self()

      owner =
        spawn(fn ->
          conn = MockConn.new()
          {:ok, handler} = SSEHandler.start_link(conn, session_id, opts())
          :ok = SessionRegistry.register(session_id, handler)
          send(test_pid, {:handler, handler})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:handler, handler}
      assert {:ok, ^handler} = SessionRegistry.lookup(session_id)

      ref = Process.monitor(handler)
      Process.exit(owner, :kill)

      # The handler traps the owner's exit, cleans up in terminate/2, and
      # stops; the DOWN message is delivered only after terminate/2 ran.
      assert_receive {:DOWN, ^ref, :process, ^handler, _reason}, 1000
      assert :ets.lookup(SessionRegistry.table(), session_id) == []
    end

    test "graceful close removes the ETS entry" do
      session_id = "close-#{System.unique_integer([:positive])}"
      conn = MockConn.new()
      {:ok, handler} = SSEHandler.start_link(conn, session_id, opts())
      :ok = SessionRegistry.register(session_id, handler)

      ref = Process.monitor(handler)
      SSEHandler.close(handler)

      assert_receive {:DOWN, ^ref, :process, ^handler, :normal}, 1000
      assert :ets.lookup(SessionRegistry.table(), session_id) == []
    end

    test "terminate does not clobber a newer registration for the same session" do
      session_id = "reregister-#{System.unique_integer([:positive])}"
      conn = MockConn.new()

      {:ok, old_handler} = SSEHandler.start_link(conn, session_id, opts())
      :ok = SessionRegistry.register(session_id, old_handler)

      # A reconnect registers a newer handler pid under the same session id.
      new_handler =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = SessionRegistry.register(session_id, new_handler)

      ref = Process.monitor(old_handler)
      SSEHandler.close(old_handler)
      assert_receive {:DOWN, ^ref, :process, ^old_handler, :normal}, 1000

      # The newer registration must survive the old handler's cleanup.
      assert {:ok, ^new_handler} = SessionRegistry.lookup(session_id)

      SessionRegistry.unregister(session_id)
      Process.exit(new_handler, :kill)
    end
  end
end
