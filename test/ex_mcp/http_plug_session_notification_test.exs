defmodule ExMCP.HttpPlugSessionNotificationTest do
  @moduledoc """
  `ExMCP.HttpPlug.deliver_session_notification/3` persists a notification to
  its session's event log — under the session manager the plug serving the
  session was configured with — even when no GET stream is live (so
  Last-Event-ID replay recovers it), and reports an unknown session instead
  of raising. A notification sent from inside a request callback reaches only
  the session of the request that produced it, whatever the handler process
  served before, and a handler's own `handle_cast/2` clauses are never
  shadowed by the library. A notify cast to a dead server pid must neither
  crash nor hang the caller.
  """

  use ExUnit.Case, async: true

  alias ExMCP.HttpPlug
  alias ExMCP.MessageProcessor
  alias ExMCP.Server

  @notification %{
    "jsonrpc" => "2.0",
    "method" => "notifications/tools/list_changed",
    "params" => %{}
  }

  # Records append_event/3 calls to the test process; every other function
  # delegates to the default manager, so a plug can be configured with it.
  defmodule RecordingSessionManager do
    @moduledoc false

    def append_event(session_id, type, data) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:recorded_event, session_id, type, data})
      end

      ExMCP.SessionManager.append_event(session_id, type, data)
    end

    def create_session(metadata \\ %{}), do: ExMCP.SessionManager.create_session(metadata)
    def update_session(sid, attrs), do: ExMCP.SessionManager.update_session(sid, attrs)

    def claim_initialization(sid),
      do: ExMCP.SessionManager.claim_initialization(sid)

    def complete_initialization(sid, version),
      do: ExMCP.SessionManager.complete_initialization(sid, version)

    def claim_request_id(sid, rid), do: ExMCP.SessionManager.claim_request_id(sid, rid)
    def terminate_session(sid), do: ExMCP.SessionManager.terminate_session(sid)
  end

  defmodule NotifyingHandler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_call_tool(_name, _args, state) do
      Server.notify_tools_changed(self())
      {:ok, %{content: []}, state}
    end
  end

  defmodule CustomCastHandler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    # The handler's own clause for a notify cast must not be shadowed by
    # anything the library injects.
    @impl GenServer
    def handle_cast({:notify_tools_changed}, state) do
      send(state.owner, :custom_cast_received)
      {:noreply, state}
    end
  end

  setup do
    :persistent_term.put({RecordingSessionManager, :owner}, self())
    on_exit(fn -> :persistent_term.put({RecordingSessionManager, :owner}, nil) end)
  end

  test "a notification is stored for replay when the session has no live stream" do
    session_id = ExMCP.SessionManager.create_session(%{})

    assert :stored = HttpPlug.deliver_session_notification(session_id, @notification)

    assert [%{type: "message", data: data}] = ExMCP.SessionManager.replay_events_after(session_id)
    assert data == @notification
  end

  test "an unknown session is reported, not raised" do
    assert {:error, :not_delivered} =
             HttpPlug.deliver_session_notification("no-such-session", @notification)
  end

  test "a notification reaches only the session of the request that produced it" do
    # One reusable handler process serves both requests, as a server given to
    # MessageProcessor through the :server option does: a notification sent
    # from the second request must not reach the first request's session.
    {:ok, server} = GenServer.start(NotifyingHandler, owner: self())

    assert {:ok, _conn} = process_request(server, "session-a")
    assert_receive {:recorded_event, "session-a", "message", @notification}

    # The second request carries no session; its notification has nowhere to
    # go, and in particular not to session-a.
    assert {:ok, _conn} = process_request(server, nil)
    refute_received {:recorded_event, "session-a", "message", @notification}
    refute_received {:recorded_event, _, "message", @notification}

    # Nor does a notification outside any request callback: with no request
    # context there is no session to deliver to, and the notify cast to a
    # bare handler is not a clause such a handler defines — the documented
    # limitation is that mounted notifications are sent while the request is
    # in flight. The cast itself still returns :ok.
    monitor = Process.monitor(server)
    assert :ok = Server.notify_tools_changed(server)
    refute_received {:recorded_event, _, "message", @notification}
    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 2_000
  end

  test "a handler's own handle_cast clause is not shadowed" do
    {:ok, server} = GenServer.start(CustomCastHandler, owner: self())

    :ok = Server.notify_tools_changed(server)

    assert_receive :custom_cast_received, 2_000
  end

  test "a notify cast to a dead server pid neither crashes nor hangs" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert :ok = Server.notify_tools_changed(pid)
    assert :ok = Server.notify_progress(pid, "token", 1, 2)
  end

  defp process_request(server, session_id) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "notify", "arguments" => %{}}
    }

    conn = MessageProcessor.new(request, transport: :http, session_id: session_id)

    processed =
      MessageProcessor.process(conn, %{
        server: server,
        handler: NotifyingHandler,
        handler_opts: [owner: self()],
        session_manager: RecordingSessionManager,
        protocol_mode: :legacy_only
      })

    {:ok, processed}
  end
end
