defmodule Arbor.MCP.Integration.LegacyHTTPNotificationsTest do
  # An Arbor runtime serving legacy Streamable HTTP (2025-03-26 to 2025-11-25)
  # under Cowboy and Bandit. A request's progress travels on its own POST
  # event stream when the client accepts one, and on the session's GET stream
  # when it accepts only JSON. A callback's log messages and list changes
  # travel on its own session's GET stream, and never on another session's.
  #
  # The Streamable HTTP GET stream is pinned to `sse_mode: :stream`: the test
  # environment sets `:arbor_mcp, :test_mode`, which makes `:oneshot` the
  # default, and a oneshot GET closes right after its `connected` event.
  use ExUnit.Case, async: false

  alias Arbor.MCP.{Client, HttpPlug, Server}
  alias Arbor.MCP.Server.{Context, Runtime}

  @moduletag :integration
  @version "2025-11-25"

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["progress", "announce", "roots"] do
          %{name: name, inputSchema: %{type: "object"}}
        end

      {:ok, tools, nil, state}
    end

    # Reports progress through both APIs and holds the request open until
    # the test releases it, so progress must reach the client while the
    # request is still running.
    @impl true
    def handle_call_tool("progress", _args, state) do
      token = Context.progress_token()
      reported = Context.report_progress(1, 2)
      notified = Server.notify_progress(self(), token, 2, 2)
      send(state.owner, {:server_progress, self(), token, [reported, notified]})

      receive do
        :release -> {:ok, %{content: []}, state}
      after
        5_000 -> {:error, "the test did not release the progress tool", state}
      end
    end

    def handle_call_tool("announce", %{"who" => who}, state) do
      logged = Server.send_log_message(self(), :info, "from " <> who, %{})
      changed = Server.notify_tools_changed(self())
      send(state.owner, {:server_announced, who, [logged, changed]})
      {:ok, %{content: []}, state}
    end

    def handle_call_tool("roots", _args, state) do
      send(state.owner, {:server_roots, Server.list_roots(self(), 3_000)})
      {:ok, %{content: []}, state}
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, {Keyword.fetch!(opts, :owner), Keyword.fetch!(opts, :name)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [%{uri: "file:///work", name: "work"}], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "unused", state}

    @impl true
    def handle_progress(request_id, params, {owner, name} = state) do
      send(owner, {:client_progress, name, request_id, params})
      {:ok, state}
    end

    @impl true
    def handle_log_message(request_id, params, {owner, name} = state) do
      send(owner, {:client_log, name, request_id, params})
      {:ok, state}
    end
  end

  @telemetry [
    [:arbor_mcp, :transport, :sse, :event],
    [:arbor_mcp, :transport, :sse, :disconnected],
    [:arbor_mcp, :client, :disconnected]
  ]

  # Each message names the MCP client it came from. SSE events run in the SSE
  # client, which the MCP client process starts; client events run in the MCP
  # client process itself.
  @doc false
  def handle_telemetry([:arbor_mcp, :transport, :sse, :event], _measurements, meta, owner),
    do: send(owner, {:sse_event, opener(), meta.event_type})

  def handle_telemetry([:arbor_mcp, :transport, :sse, :disconnected], _measurements, _, owner),
    do: send(owner, {:sse_disconnected, opener()})

  def handle_telemetry([:arbor_mcp, :client, :disconnected], _measurements, _meta, owner),
    do: send(owner, {:client_disconnected, self()})

  defp opener, do: hd(Process.get(:"$ancestors", [nil]))

  for server <- [:cowboy, :bandit] do
    describe "#{server}" do
      @describetag server: server

      test "a legacy POST answers a progress request with an event stream", %{server: server} do
        port = serve(server)
        client = connect(port, :solo, use_sse: false)

        assert_progress_while_running(client, :solo, "post-progress")
      end

      test "with the session GET stream open, a callback's log message and list change use it",
           %{server: server} do
        port = serve(server)
        client = connect(port, :solo, use_sse: true)

        assert_progress_while_running(client, :solo, "get-open-progress")

        {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})
        announce(client, "solo")

        # A nil request id: the log message came on the session's stream,
        # not on the announcing request's response.
        assert_receive {:client_log, :solo, nil, %{"message" => "from solo"}}, 2_000

        assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed",
                        _params},
                       2_000

        assert :ok = Client.unsubscribe_notifications(listener)
      end

      test "a callback's request to the client uses the GET stream and gets its answer",
           %{server: server} do
        port = serve(server)
        client = connect(port, :solo, use_sse: true)

        assert {:ok, _result} = Client.call_tool(client, "roots", %{}, timeout: 5_000)

        assert_receive {:server_roots,
                        {:ok, %{"roots" => [%{"uri" => "file:///work", "name" => "work"}]}}}
      end

      # The server closes a GET stream at its request deadline. The session
      # outlives it: the client opens the stream again, without dropping the
      # session or reconnecting.
      test "the client opens the GET stream again when the server closes it",
           %{server: server} do
        port = serve(server, request_timeout_ms: 1_000)
        client = connect(port, :solo, use_sse: true)
        {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

        assert_receive {:sse_disconnected, ^client}, 3_000
        assert_receive {:sse_event, ^client, "connected"}, 5_000
        announce(client, "again")
        assert_receive {:client_log, :solo, nil, %{"message" => "from again"}}, 2_000

        assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed",
                        _params},
                       2_000

        refute_received {:client_disconnected, ^client}
      end

      test "a session's notifications never reach another session's GET stream",
           %{server: server} do
        port = serve(server)
        a = connect(port, :a, use_sse: true)
        b = connect(port, :b, use_sse: true)
        {:ok, a_listener} = Client.subscribe_notifications(a, %{"toolsListChanged" => true})
        {:ok, b_listener} = Client.subscribe_notifications(b, %{"toolsListChanged" => true})

        # Each session's GET stream is ordered, so a notification that leaked
        # into the other session would arrive there before that session's
        # own next one and fail the match on its text.
        for {client, name, listener, who} <- [
              {a, :a, a_listener, "a1"},
              {b, :b, b_listener, "b1"},
              {a, :a, a_listener, "a2"},
              {b, :b, b_listener, "b2"}
            ] do
          announce(client, who)
          assert_receive {:client_log, ^name, nil, %{"message" => text}}, 2_000
          assert text == "from " <> who

          assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed",
                          _params},
                         2_000
        end

        refute_received {:client_log, _name, _request_id, _params}
        refute_received {:ex_mcp_notification, _listener, _method, _params}
      end

      # A list change sent outside a callback isn't addressed to a session.
      # Every legacy session with an open GET stream gets it there, beside
      # the modern subscriptions, and a session without a stream is skipped
      # (not queued for later) without holding up the others.
      test "a list change sent outside a callback reaches every open stream in both eras",
           %{server: server} do
        {root, port} = start_server(server, :prefer_modern, [])
        a = connect(port, :a, use_sse: true)
        b = connect(port, :b, use_sse: true)
        _postonly = connect(port, :postonly, use_sse: false)
        modern = connect(port, :modern, protocol_mode: :modern_only)
        filter = %{"toolsListChanged" => true, "promptsListChanged" => true}
        {:ok, a_listener} = Client.subscribe_notifications(a, filter)
        {:ok, b_listener} = Client.subscribe_notifications(b, filter)
        {:ok, subscription} = Client.listen(modern, filter, timeout: 2_000)

        # A session whose GET stream is open but never read, and one that has
        # none yet.
        slow = raw_session(port)
        _unread = raw_get(port, slow)
        later = raw_session(port)

        assert :ok = Server.notify_tools_changed(root)

        for listener <- [a_listener, b_listener] do
          assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed",
                          _params},
                         2_000
        end

        assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                        _params},
                       2_000

        assert :ok = Server.notify_prompts_changed(root)

        assert_receive {:ex_mcp_notification, ^a_listener, "notifications/prompts/list_changed",
                        _params},
                       2_000

        # The session that had no stream then didn't get the change queued:
        # its stream is ordered, so it would come ahead of this log message.
        stream = raw_get(port, later)

        assert {200, _headers, _body} =
                 raw_post(port, later, announce_call(2, "later"), "application/json")

        [before_log, _rest] =
          stream |> read_until("from later") |> String.split("from later", parts: 2)

        refute before_log =~ "list_changed"
        close_session(port, later, stream)
      end

      test "a list change sent outside a callback reports a session that didn't take it",
           %{server: server} do
        {root, port} =
          start_server(server, :legacy_only,
            services: [sessions: [options: [max_event_bytes: 16]]]
          )

        client = connect(port, :solo, use_sse: true)
        {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

        assert {:error, :partially_delivered} = Server.notify_tools_changed(root)
        refute_received {:ex_mcp_notification, ^listener, _method, _params}
      end

      test "a legacy POST that accepts only JSON gets JSON, with its progress on the GET stream",
           %{server: server} do
        port = serve(server)
        session = raw_session(port)
        stream = raw_get(port, session)

        task =
          Task.async(fn ->
            raw_post(port, session, progress_call(2, "json-progress"), "application/json")
          end)

        assert_receive {:server_progress, worker, "json-progress", [:ok, :ok]}, 2_000
        received = read_until(stream, ~s("progress":2))
        assert received =~ ~s("progressToken":"json-progress")
        send(worker, :release)

        assert {200, headers, body} = Task.await(task, 5_000)
        assert header(headers, "content-type") =~ "application/json"
        assert %{"id" => 2, "result" => _result} = Jason.decode!(body)
        close_session(port, session, stream)
      end

      test "a legacy POST that asks for progress and accepts an event stream gets one",
           %{server: server} do
        port = serve(server)
        session = raw_session(port)
        stream = raw_get(port, session)

        task =
          Task.async(fn ->
            raw_post(
              port,
              session,
              progress_call(2, "stream-progress"),
              "application/json, text/event-stream"
            )
          end)

        assert_receive {:server_progress, worker, "stream-progress", [:ok, :ok]}, 2_000
        send(worker, :release)

        assert {200, headers, body} = Task.await(task, 5_000)
        assert header(headers, "content-type") =~ "text/event-stream"
        assert header(headers, "mcp-session-id") == session

        assert [
                 %{"method" => "notifications/progress", "params" => %{"progress" => 1}},
                 %{"method" => "notifications/progress", "params" => %{"progress" => 2}},
                 %{"id" => 2, "result" => _result}
               ] = sse_messages(body)

        # The GET stream is ordered: had the progress gone there too, it would
        # arrive ahead of this announcement.
        assert {200, _headers, _body} =
                 raw_post(port, session, announce_call(3, "raw"), "application/json")

        received = read_until(stream, "from raw")
        refute received =~ "notifications/progress"
        close_session(port, session, stream)
      end
    end
  end

  defp assert_progress_while_running(client, name, token) do
    task =
      Task.async(fn ->
        Client.call_tool(client, "progress", %{},
          timeout: 5_000,
          meta: %{"progressToken" => token}
        )
      end)

    assert_receive {:server_progress, worker, ^token, [:ok, :ok]}, 2_000

    assert_receive {:client_progress, ^name, _id, %{"progressToken" => ^token, "progress" => 1}},
                   2_000

    assert_receive {:client_progress, ^name, _id, %{"progressToken" => ^token, "progress" => 2}},
                   2_000

    send(worker, :release)
    assert {:ok, _result} = Task.await(task, 5_000)
  end

  defp announce(client, who) do
    assert {:ok, _result} = Client.call_tool(client, "announce", %{"who" => who}, timeout: 5_000)
    assert_receive {:server_announced, ^who, [:ok, :ok]}, 1_000
  end

  defp serve(server, runtime_opts \\ []),
    do: server |> start_server(:legacy_only, runtime_opts) |> elem(1)

  defp start_server(server, mode, runtime_opts) do
    root =
      start_supervised!(
        {Runtime,
         [
           handler: Handler,
           handler_args: [owner: self()],
           transport: :mounted_http,
           protocol_mode: mode
         ] ++ runtime_opts}
      )

    plug_opts = [
      runtime: root,
      path: "/mcp",
      protocol_mode: mode,
      sse_mode: :stream,
      allowed_origins: :any
    ]

    port = listen(server, plug_opts)
    telemetry = "legacy-http-notifications-#{System.unique_integer([:positive])}"
    owner = self()

    :ok = :telemetry.attach_many(telemetry, @telemetry, &__MODULE__.handle_telemetry/4, owner)

    on_exit(fn -> :telemetry.detach(telemetry) end)
    {root, port}
  end

  defp listen(:cowboy, plug_opts) do
    ref = {__MODULE__, System.unique_integer([:positive])}

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: {HttpPlug, plug_opts},
       options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]},
      id: ref
    )

    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    port
  end

  defp listen(:bandit, plug_opts) do
    listener =
      start_supervised!(
        {Bandit, plug: {HttpPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    port
  end

  # Clients are started one at a time, and each waits for its GET stream's
  # `connected` event, sent after the server registered that stream.
  defp connect(port, name, opts) do
    era =
      if opts[:protocol_mode] == :modern_only,
        do: [protocol_mode: :modern_only],
        else: [protocol_mode: :legacy_only, protocol_version: @version]

    client =
      start_supervised!(
        {Client,
         [
           transport: :http,
           url: "http://127.0.0.1:#{port}/mcp",
           health_check_interval: nil,
           reconnect: false,
           capabilities: %{"roots" => %{}},
           handler: {ClientHandler, [owner: self(), name: name]}
         ]
         |> Keyword.merge(era)
         |> Keyword.merge(opts)},
        id: {:client, name}
      )

    if era[:protocol_version], do: assert({:ok, @version} = Client.negotiated_version(client))
    if opts[:use_sse], do: assert_receive({:sse_event, ^client, "connected"}, 2_000)
    client
  end

  defp raw_session(port) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "legacy-http-notifications", "version" => "1"}
      }
    }

    assert {200, headers, _body} = raw_post(port, nil, initialize, "application/json")
    session = header(headers, "mcp-session-id")
    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert {202, _headers, _body} = raw_post(port, session, initialized, "application/json")
    session
  end

  defp raw_get(port, session) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: text/event-stream\r\n" <>
          "Mcp-Session-Id: #{session}\r\nMcp-Protocol-Version: #{@version}\r\n\r\n"
      )

    assert read_until(socket, "event: connected") =~ "200 OK"
    socket
  end

  # Deleting the session ends its GET stream (the last, empty chunk), so the
  # listener doesn't wait for it at shutdown.
  defp close_session(port, session, stream) do
    request =
      {~c"http://127.0.0.1:#{port}/mcp",
       [
         {~c"mcp-session-id", to_charlist(session)},
         {~c"mcp-protocol-version", to_charlist(@version)}
       ]}

    assert {:ok, {{_, 204, _}, _headers, _body}} =
             :httpc.request(:delete, request, [timeout: 5_000], body_format: :binary)

    read_until(stream, "0\r\n\r\n")
    :gen_tcp.close(stream)
  end

  defp raw_post(port, session, value, accept) do
    headers =
      [{"accept", accept}, {"mcp-protocol-version", @version}] ++
        if(session, do: [{"mcp-session-id", session}], else: [])

    request =
      {~c"http://127.0.0.1:#{port}/mcp",
       Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end),
       ~c"application/json", Jason.encode!(value)}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(:post, request, [timeout: 5_000, connect_timeout: 1_000],
        body_format: :binary
      )

    {status, headers, body}
  end

  defp progress_call(id, token),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => token}
      }
    }

  defp announce_call(id, who),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "announce", "arguments" => %{"who" => who}}
    }

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp sse_messages(body) do
    body
    |> String.split(["\r\n\r\n", "\n\n"], trim: true)
    |> Enum.flat_map(fn event ->
      for "data: " <> json <- String.split(event, ["\r\n", "\n"]), do: Jason.decode!(json)
    end)
  end

  defp read_until(socket, marker, bytes \\ "") do
    if String.contains?(bytes, marker) do
      bytes
    else
      assert {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, marker, bytes <> chunk)
    end
  end
end
