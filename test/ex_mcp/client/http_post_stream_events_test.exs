defmodule ExMCP.Client.HTTPPostStreamEventsTest do
  @moduledoc """
  In the legacy Streamable HTTP revisions a server may answer a POST with an
  event stream that carries the request's notifications, and its own
  requests, ahead of the response. The client read the whole body and joined
  every event's data into one JSON document, so a notification ahead of the
  response left the call waiting until it timed out, and a request the
  server waited on could never be answered.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client

  @initialize_result %{
    "protocolVersion" => "2025-11-25",
    "capabilities" => %{"tools" => %{}},
    "serverInfo" => %{"name" => "stub", "version" => "1"}
  }

  defmodule AuthProvider do
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{owner: Keyword.fetch!(config, :owner)}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_challenge, _scopes, state) do
      send(state.owner, :authenticated)
      {:ok, "first-token", state}
    end

    @impl true
    def handle_forbidden(_challenge, _scopes, state) do
      send(state.owner, :stepped_up)
      {:ok, "step-up-token", state}
    end
  end

  # `answer_call` gets the tools/call request and the conn, and sends the
  # POST's response itself. A GET relay keeps the legacy standalone stream
  # open, so the call's POST runs from its own task and can hand the events
  # it carries to the client as they arrive (see
  # ExMCP.Transport.HTTP.PostStream). Returns the client and the GET relay,
  # which each test closes.
  defp start(answer_call, opts \\ []) do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(test, {:stream_open, self()})
      relay(conn)
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "s1")
          |> answer_initialize(id, Keyword.get(opts, :initialize, :json))

        %{"method" => "tools/call"} = request ->
          answer_call.(request, conn)

        %{"id" => id} = response when not is_map_key(response, "method") ->
          send(test, {:client_answered, id, response})
          Plug.Conn.resp(conn, 202, "")

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          protocol_mode: :legacy_only,
          protocol_version: "2025-11-25",
          use_sse: true,
          health_check_interval: nil,
          reconnect: false
        ] ++ Keyword.get(opts, :client, [])
      )

    assert_receive {:stream_open, stream}, 5_000
    {client, stream}
  end

  defp answer_initialize(conn, id, :json) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(response(id, @initialize_result)))
  end

  defp answer_initialize(conn, id, :stream_with_log) do
    log = notification("notifications/message", %{"level" => "info", "data" => "starting"})

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, event(log) <> event(response(id, @initialize_result)))
  end

  defp event(message, fields \\ ""), do: "#{fields}data: #{Jason.encode!(message)}\n\n"

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp done(id), do: response(id, %{"content" => [%{"type" => "text", "text" => "done"}]})

  defp progress(token, n),
    do: notification("notifications/progress", %{"progressToken" => token, "progress" => n})

  # A list change without params, as the TypeScript SDK's servers send it.
  defp tools_list_changed,
    do: %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

  defp call(client) do
    Task.async(fn ->
      Client.call_tool(client, "slow", %{},
        timeout: 10_000,
        format: :map,
        meta: %{"progressToken" => "t1"}
      )
    end)
  end

  # Sends `first` on the POST stream, then the response once released.
  defp hold_after(first) do
    test = self()

    fn %{"id" => id}, conn ->
      conn = open_stream(conn)
      {:ok, conn} = Plug.Conn.chunk(conn, event(first))
      send(test, {:holding, self()})

      # A watchdog well past the test's own timeouts.
      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end

      {:ok, conn} = Plug.Conn.chunk(conn, event(done(id)))
      conn
    end
  end

  defp open_stream(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
  end

  test "a notification ahead of the response doesn't leave the call waiting" do
    {client, stream} = start(hold_after(progress("t1", 1)))

    task = call(client)
    assert_receive {:holding, server}, 5_000
    send(server, :release)

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
    send(stream, :close)
  end

  # The notification was handed over while the stream was still held open:
  # the listener sees it before the response exists.
  test "a list change ahead of the response is seen while the call is still open" do
    {client, stream} = start(hold_after(tools_list_changed()))
    assert {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

    task = call(client)
    assert_receive {:holding, server}, 5_000

    assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", %{}},
                   5_000

    send(server, :release)
    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
    send(stream, :close)
  end

  test "a request the server waits on is answered while the stream is open" do
    {client, stream} =
      start(
        hold_after(%{
          "jsonrpc" => "2.0",
          "id" => "server-ping",
          "method" => "ping",
          "params" => %{}
        })
      )

    task = call(client)
    assert_receive {:holding, server}, 5_000
    assert_receive {:client_answered, "server-ping", %{"result" => %{}}}, 5_000
    send(server, :release)

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
    send(stream, :close)
  end

  test "a retried POST still handles server requests on its event stream" do
    attempts = start_supervised!({Agent, fn -> 0 end})
    test = self()

    answer = fn %{"id" => id}, conn ->
      attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

      case attempt do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer scope="tools.call"))
          |> Plug.Conn.resp(401, "authentication required")

        2 ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer first-token"]

          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer error="insufficient_scope", scope="tools.call")
          )
          |> Plug.Conn.resp(403, "more scope required")

        3 ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer step-up-token"]
          conn = open_stream(conn)

          ping = %{"jsonrpc" => "2.0", "id" => "retry-ping", "method" => "ping"}
          {:ok, conn} = Plug.Conn.chunk(conn, event(ping))
          send(test, {:retry_stream_open, self()})

          receive do
            :release -> :ok
          after
            3_000 -> :ok
          end

          {:ok, conn} = Plug.Conn.chunk(conn, event(done(id)))
          conn
      end
    end

    {client, stream} = start(answer, client: [auth_provider: {AuthProvider, owner: self()}])
    task = call(client)

    assert_receive :authenticated, 5_000
    assert_receive :stepped_up, 5_000
    assert_receive {:retry_stream_open, server}, 5_000
    assert_receive {:client_answered, "retry-ping", %{"result" => %{}}}, 2_000
    send(server, :release)

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
    assert Agent.get(attempts, & &1) == 3
    send(stream, :close)
  end

  test "an id on a handed-over event still counts for resumption" do
    {client, stream} =
      start(fn %{"id" => id}, conn ->
        body =
          "id: e0\nretry: 250\ndata: \n\n" <>
            event(progress("t1", 1), "id: e1\n") <> event(done(id))

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

    assert {:ok, _} = Task.await(call(client))

    transport = :sys.get_state(client).transport_state
    assert transport.last_event_id == "e1"
    assert transport.retry_delay == 250
    send(stream, :close)
  end

  # Its declared length is above the limit; what the client keeps isn't.
  test "a stream of handed-over messages isn't limited by :max_response_bytes" do
    {client, stream} =
      start(
        fn %{"id" => id}, conn ->
          body = Enum.map_join(1..40, &event(progress("t1", &1))) <> event(done(id))

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
        end,
        client: [max_response_bytes: 2_048]
      )

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(call(client))
    send(stream, :close)
  end

  test "a notification ahead of the initialize response doesn't stop the client connecting" do
    {client, stream} =
      start(fn _request, conn -> Plug.Conn.resp(conn, 500, "") end,
        initialize: :stream_with_log
      )

    assert {:ok, %{"name" => "stub"}} = Client.server_info(client)
    send(stream, :close)
  end

  # Sends nothing on the legacy standalone GET stream; it stays open so the
  # call's POST runs from its own task, until the test closes it.
  defp relay(conn) do
    receive do
      :close -> conn
    after
      30_000 -> conn
    end
  end
end
