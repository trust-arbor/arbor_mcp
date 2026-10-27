defmodule ExMCP.Integration.LegacyHTTPNotificationsTest do
  @moduledoc """
  A legacy Streamable HTTP server mounted through `ExMCP.HttpPlug` must be
  able to send progress and list-change notifications to its client while a
  request is still running: on the session's standalone GET stream, when the
  client has one, and never on another session's stream. Without a GET stream
  there is no channel for a server-initiated notification, but the notify
  helpers must still not disturb the request (2.x had the same bug; see the
  equivalent 2.x regression test).
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.HttpPlug
  alias ExMCP.Server

  defmodule Handler do
    @moduledoc false
    use ExMCP.Server.Handler

    alias ExMCP.Server.Context

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["progress", "change", "update_resource"] do
          %{name: name, inputSchema: %{type: "object", properties: %{}}}
        end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("progress", _args, state) do
      context_result = Context.report_progress(1, 2)

      outcome =
        case context_result do
          {:error, :request_not_streaming} ->
            # The documented legacy path: the server process with the
            # request's progress token.
            Server.notify_progress(self(), Context.progress_token(), 1, 2)

          result ->
            result
        end

      send(
        state.owner,
        {:server_progress, self(), Context.progress_token(), context_result, outcome}
      )

      receive do
        :release_progress -> {:ok, %{content: []}, state}
      after
        5_000 -> {:error, "test did not release progress tool", state}
      end
    end

    def handle_call_tool("change", _args, state) do
      outcome = Server.notify_tools_changed(self())
      send(state.owner, {:server_list_changed, outcome})
      {:ok, %{content: []}, state}
    end

    @impl true
    def handle_subscribe_resource(_uri, state), do: {:ok, state}

    @impl true
    def handle_unsubscribe_resource(_uri, state), do: {:ok, state}

    def handle_call_tool("update_resource", _args, state) do
      outcome = Server.notify_resource_update(self(), "file:///notify-test")
      send(state.owner, {:server_resource_update, outcome})
      {:ok, %{content: []}, state}
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour ExMCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}

    @impl true
    def handle_ping(owner), do: {:ok, %{}, owner}

    @impl true
    def handle_list_roots(owner), do: {:ok, [], owner}

    @impl true
    def handle_create_message(_params, owner), do: {:error, "unused", owner}

    @impl true
    def handle_progress(request_id, params, owner) do
      send(owner, {:client_progress, request_id, params})
      {:ok, owner}
    end
  end

  # A session manager that records append_event/3 and delegates everything
  # else to the default, so a plug configured with it must persist its
  # sessions' notifications through it.
  defmodule DelegatingManager do
    @moduledoc false

    def append_event(session_id, type, data) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:recorded_event, session_id, data})
      end

      ExMCP.SessionManager.append_event(session_id, type, data)
    end

    def create_session(metadata \\ %{}), do: ExMCP.SessionManager.create_session(metadata)
    def update_session(sid, attrs), do: ExMCP.SessionManager.update_session(sid, attrs)
    def ensure_session(sid, attrs), do: ExMCP.SessionManager.ensure_session(sid, attrs)

    def ensure_initialized_session(sid, attrs),
      do: ExMCP.SessionManager.ensure_initialized_session(sid, attrs)

    def claim_initialization(sid), do: ExMCP.SessionManager.claim_initialization(sid)

    def complete_initialization(sid, version),
      do: ExMCP.SessionManager.complete_initialization(sid, version)

    def claim_request_id(sid, rid), do: ExMCP.SessionManager.claim_request_id(sid, rid)
    def terminate_session(sid), do: ExMCP.SessionManager.terminate_session(sid)
    def get_session(sid), do: ExMCP.SessionManager.get_session(sid)

    def replay_events_after(sid, last_event_id \\ nil),
      do: ExMCP.SessionManager.replay_events_after(sid, last_event_id)

    def replay_events_after(sid, last_event_id, handler_pid),
      do: ExMCP.SessionManager.replay_events_after(sid, last_event_id, handler_pid)
  end

  # The standalone GET stream used by legacy Streamable HTTP is served when
  # the deprecated-transport flag is on; it is the one 1.x configuration in
  # which a mounted server has a channel for server-initiated notifications.
  defp start_pair(use_sse, opts \\ []) do
    port = free_port()
    ref = {:legacy_http_notifications, System.unique_integer([:positive])}

    plug_opts =
      [
        handler: Handler,
        handler_opts: [owner: self()],
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        # The suite's test_helper sets :test_mode, which serves GET streams
        # one-shot; a real server keeps the stream open (:stream default).
        sse_mode: :stream,
        allowed_origins: ["http://127.0.0.1:#{port}"],
        path: "/mcp"
      ]
      |> Keyword.merge(Keyword.get(opts, :plug_opts, []))

    {:ok, _listener} =
      Plug.Cowboy.http(
        HttpPlug,
        plug_opts,
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{port}/mcp",
          protocol_mode: :legacy_only,
          protocol_version: "2025-11-25",
          use_sse: use_sse,
          health_check_interval: nil,
          reconnect: false,
          handler: {ClientHandler, [owner: self()]}
        ] ++ opts
      )

    assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
    %{client: client, ref: ref}
  end

  defp close_pair(pair) do
    if Process.alive?(pair.client), do: Client.stop(pair.client)
    Plug.Cowboy.shutdown(pair.ref)
  catch
    :exit, _reason -> :ok
  end

  defp run_progress(client, token, opts) do
    task =
      Task.async(fn ->
        Client.call_tool(client, "progress", %{}, [timeout: 10_000, format: :map] ++ opts)
      end)

    assert_receive {:server_progress, worker, ^token, context_result, outcome}, 5_000

    # The window covers one GET-stream reconnect cycle: a dropped stream is
    # reopened with Last-Event-ID and the persisted notification replayed, so
    # delivery can follow a reconnect. That the notification arrives while
    # the call is still open is enforced by control flow — the handler blocks
    # for :release_progress below — not by this window.
    received =
      receive do
        {:client_progress, _request_id, %{"progressToken" => ^token, "progress" => 1}} -> :ok
      after
        3_000 -> :missing
      end

    send(worker, :release_progress)
    assert {:ok, _} = Task.await(task, 10_000)
    {{context_result, outcome}, received}
  end

  test "the GET stream delivers progress and list changes while a call runs" do
    pair = start_pair(true)
    client = pair.client

    try do
      token = "legacy-get-progress"

      assert {:ok, listener} =
               Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      # The progress notification reaches the handler's handle_progress/3
      # while the tool call is still waiting for :release_progress.
      assert {{{:error, :request_not_streaming}, :ok}, :ok} =
               run_progress(client, token, progress_token: token)

      assert {:ok, _} = Client.call_tool(client, "change", %{}, timeout: 5_000, format: :map)
      assert_receive {:server_list_changed, :ok}, 2_000

      assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _},
                     2_000

      assert :ok = Client.unsubscribe_notifications(listener)
    after
      close_pair(pair)
    end
  end

  test "without a GET stream the notify helpers neither deliver nor disturb the call" do
    pair = start_pair(false)
    client = pair.client

    try do
      token = "legacy-post-progress"

      # There is no stream to carry a server-initiated notification, so
      # nothing is delivered — but the call still succeeds and the handler
      # process is not crashed by the notify casts (the casts used to kill a
      # bare handler GenServer, which has no handle_cast clauses of its own).
      assert {{{:error, :request_not_streaming}, :ok}, :missing} =
               run_progress(client, token, meta: %{"progressToken" => token})

      assert {:ok, _} = Client.call_tool(client, "change", %{}, timeout: 5_000, format: :map)
      assert_receive {:server_list_changed, :ok}, 2_000
      refute_received {:client_progress, _, _}
    after
      close_pair(pair)
    end
  end

  test "one session's notification never reaches another session's GET stream" do
    pair_a = start_pair(true)
    pair_b = start_pair(true)

    try do
      assert {:ok, listener_a} =
               Client.subscribe_notifications(pair_a.client, %{"toolsListChanged" => true})

      assert {:ok, listener_b} =
               Client.subscribe_notifications(pair_b.client, %{"toolsListChanged" => true})

      # Drain the subscriptions' registration round-trips before notifying.
      assert {:ok, _} =
               ExMCP.Client.call_tool(pair_a.client, "change", %{}, timeout: 5_000, format: :map)

      assert_receive {:server_list_changed, :ok}, 2_000

      assert_receive {:ex_mcp_notification, ^listener_a, "notifications/tools/list_changed", _},
                     2_000

      # A short window rather than an instant check, so a stray delivery to
      # session B's stream cannot slip past a scheduling gap.
      refute_receive {:ex_mcp_notification, ^listener_b, "notifications/tools/list_changed", _},
                     200
    after
      close_pair(pair_b)
      close_pair(pair_a)
    end
  end

  test "a plug configured with another session manager persists its notifications there" do
    :persistent_term.put({DelegatingManager, :owner}, self())

    pair = start_pair(true, plug_opts: [session_manager: DelegatingManager])
    client = pair.client

    try do
      assert {:ok, listener} =
               Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      assert {:ok, _} = Client.call_tool(client, "change", %{}, timeout: 5_000, format: :map)
      assert_receive {:server_list_changed, :ok}, 2_000

      session_id = :sys.get_state(client).transport_state.session_id

      # The notification was persisted through the plug's configured session
      # manager, not the default one.
      assert_receive {:recorded_event, ^session_id,
                      %{"method" => "notifications/tools/list_changed"}},
                     2_000

      assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _},
                     2_000
    after
      :persistent_term.put({DelegatingManager, :owner}, nil)
      close_pair(pair)
    end
  end

  test "a resource update from a callback is persisted by the configured session manager" do
    :persistent_term.put({DelegatingManager, :owner}, self())

    pair = start_pair(true, plug_opts: [session_manager: DelegatingManager])
    client = pair.client

    try do
      assert {:ok, _} = Client.subscribe_resource(client, "file:///notify-test")

      assert {:ok, _} =
               Client.call_tool(client, "update_resource", %{}, timeout: 5_000, format: :map)

      assert_receive {:server_resource_update, :ok}, 2_000

      session_id = :sys.get_state(client).transport_state.session_id

      # The broadcast persisted the update through the plug's configured
      # session manager, not the default one.
      assert_receive {:recorded_event, ^session_id,
                      %{"method" => "notifications/resources/updated"}},
                     2_000
    after
      :persistent_term.put({DelegatingManager, :owner}, nil)
      close_pair(pair)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
