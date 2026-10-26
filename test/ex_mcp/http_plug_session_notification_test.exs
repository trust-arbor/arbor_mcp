defmodule ExMCP.HttpPlugSessionNotificationTest do
  @moduledoc """
  `ExMCP.HttpPlug.deliver_session_notification/2` persists a notification to
  its session's event log even when no GET stream is live (so Last-Event-ID
  replay recovers it), and reports an unknown session instead of raising. A
  bare `use ExMCP.Server.Handler` GenServer must survive the notify casts of
  `ExMCP.Server`: it has no transport, but the casts used to kill it.
  """

  use ExUnit.Case, async: true

  alias ExMCP.HttpPlug
  alias ExMCP.Server

  @notification %{
    "jsonrpc" => "2.0",
    "method" => "notifications/tools/list_changed",
    "params" => %{}
  }

  defmodule BareHandler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
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

  test "a bare handler GenServer survives the notify casts" do
    {:ok, server} = GenServer.start(BareHandler, [])

    :ok = Server.send_log_message(server, :info, "hello", %{})
    :ok = Server.notify_progress(server, "token", 1, 2)
    :ok = Server.notify_tools_changed(server)
    :ok = Server.notify_prompts_changed(server)
    :ok = Server.notify_resources_changed(server)
    :ok = Server.notify_resource_update(server, "file:///x")
    :ok = Server.notify_roots_changed(server)

    # The casts settle before the reply: a missing handle_cast clause would
    # have killed the process and failed this call with noproc.
    assert {:ok, [], nil} = GenServer.call(server, {:list_tools, nil})

    :ok = GenServer.stop(server)
  end
end
