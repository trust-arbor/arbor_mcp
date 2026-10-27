defmodule ExMCP.Client.HTTPAsyncPostTest do
  @moduledoc """
  The legacy SSE HTTP client POSTs each request from its own task. It must
  still behave as the synchronous path did: a POST's response answers the
  request it carried, a POST that runs past its caller's deadline is the
  caller's timeout and is cancelled on the server, and a late response for a
  settled request is dropped rather than misrouted to another request.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client

  defmodule Provider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{token: "stale", test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      send(state.test_pid, :authenticated)
      {:ok, "fresh", %{state | token: "fresh"}}
    end

    @impl true
    def handle_forbidden(www_authenticate, scopes, state),
      do: handle_unauthorized(www_authenticate, scopes, state)
  end

  test "a response with a null or different id answers the request its POST carried" do
    client = start_client()

    assert {:error, %{code: -32600}} = Client.call_tool(client, "null_id", %{}, timeout: 5_000)
    assert {:ok, _result} = Client.call_tool(client, "string_id", %{}, timeout: 5_000)
  end

  test "a request whose POST outlives an explicit timeout is cancelled on the server" do
    client = start_client()

    assert {:error, :timeout} = Client.call_tool(client, "hang", %{}, format: :map, timeout: 300)
    assert_receive {:tool_call_started, "hang", _handler}
    assert_receive {:notification, "notifications/cancelled", %{"requestId" => _id}}, 2_000
  end

  test "a POST that answers after its request settled is dropped, not given to another" do
    client = start_client()

    late = Task.async(fn -> Client.call_tool(client, "late", %{}, timeout: 5_000) end)
    assert_receive {:tool_call_started, "late", late_handler, late_id}
    other = Task.async(fn -> Client.call_tool(client, "other", %{}, timeout: 5_000) end)
    assert_receive {:tool_call_started, "other", other_handler, other_id}

    :ok = Client.send_cancelled(client, late_id, "user")
    assert {:error, :cancelled} = Task.await(late)
    assert_receive {:notification, "notifications/cancelled", %{"requestId" => ^late_id}}

    # The cancelled request's POST answers with the other request's id.
    send(late_handler, {:respond_with_id, other_id})
    assert_receive {:responded, ^late_handler}
    send(other_handler, :release)

    assert {:ok, response} = Task.await(other)
    assert [%{text: "other"}] = response.content
  end

  test "concurrent auth challenges run one authentication" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    tasks =
      for _ <- 1..4,
          do: Task.async(fn -> Client.call_tool(client, "protected", %{}, timeout: 5_000) end)

    assert Enum.all?(Task.await_many(tasks, 10_000), &match?({:ok, _}, &1))
    assert_received :authenticated
    refute_received :authenticated
  end

  test "an auth challenge on a notification re-sends it after authenticating" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    :ok = Client.send_cancelled(client, "unknown-request", "auth")
    assert_receive :authenticated, 2_000
    assert_receive {:authenticated_notification, "notifications/cancelled"}, 2_000
  end

  test "concurrent tools/list pages each reach the header cache" do
    client = start_client()

    pages =
      for cursor <- ["p1", "p2"],
          do: Task.async(fn -> Client.list_tools(client, cursor: cursor, timeout: 5_000) end)

    handlers = for _ <- 1..2, do: receive_list_started()
    Enum.each(handlers, &send(&1, :release))
    assert Enum.all?(Task.await_many(pages, 5_000), &match?({:ok, _}, &1))

    _ = :sys.get_state(client)
    cache = :sys.get_state(client).transport_state.tool_headers
    assert Map.has_key?(cache, "tool_p1") and Map.has_key?(cache, "tool_p2")
  end

  test "a 401 challenge on a notification POST after disconnect/1 does not crash the client" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    :ok = Client.send_cancelled(client, "req-1", "delayed_auth")
    assert_receive {:notification_held, handler}, 2_000

    assert :ok = Client.disconnect(client)

    send(handler, :release_401)

    refute_receive :authenticated, 500
    assert Process.alive?(client)
  end

  test "cursor page completing before first page retains both pages' tools in cache" do
    client = start_client()

    p_first = Task.async(fn -> Client.list_tools(client, timeout: 5_000) end)
    {nil, first_handler} = receive_list_started_with_cursor()

    p_cursor = Task.async(fn -> Client.list_tools(client, cursor: "c1", timeout: 5_000) end)
    {"c1", cursor_handler} = receive_list_started_with_cursor()

    # Release cursor handler first
    send(cursor_handler, :release)
    assert {:ok, _} = Task.await(p_cursor, 2_000)

    # Release first handler second
    send(first_handler, :release)
    assert {:ok, _} = Task.await(p_first, 2_000)

    cache = :sys.get_state(client).transport_state.tool_headers
    assert Map.has_key?(cache, "tool_c1")
    assert Map.has_key?(cache, "tool_first")
  end

  defp receive_list_started do
    assert_receive {:list_started, _cursor, handler}, 2_000
    handler
  end

  defp receive_list_started_with_cursor do
    assert_receive {:list_started, cursor, handler}, 2_000
    {cursor, handler}
  end

  defp start_client(opts \\ []) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: true,
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", "test-session")
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "async-post", "version" => "1"}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/list", "id" => id, "params" => params}, test_pid) do
    cursor = params["cursor"]
    send(test_pid, {:list_started, cursor, self()})

    receive do
      :release -> :ok
    after
      2_000 -> :ok
    end

    tools = [%{"name" => "tool_#{cursor || "first"}", "inputSchema" => %{"type" => "object"}}]
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
  end

  defp respond(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}},
         test_pid
       )
       when name in ["late", "other"] do
    send(test_pid, {:tool_call_started, name, self(), id})

    receive do
      {:respond_with_id, other_id} ->
        send(test_pid, {:responded, self()})
        text_result(conn, other_id, name)

      :release ->
        text_result(conn, id, name)
    after
      2_000 -> text_result(conn, id, name)
    end
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    name = params["name"]
    send(test_pid, {:tool_call_started, name, self()})

    case name do
      "null_id" ->
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32600, "message" => "Invalid Request"}
        })

      "string_id" ->
        json(conn, %{"jsonrpc" => "2.0", "id" => to_string(id), "result" => %{"content" => []}})

      "hang" ->
        # The client gives up at its deadline and closes the connection;
        # end normally when Cowboy stops this handler for that.
        Process.flag(:trap_exit, true)

        receive do
          :release -> :ok
          {:EXIT, _from, _reason} -> :ok
        after
          2_000 -> :ok
        end

        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})

      "protected" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
        else
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        end
    end
  end

  defp respond(conn, %{"method" => "notifications/cancelled" = method} = message, test_pid) do
    params = Map.get(message, "params", %{})
    send(test_pid, {:notification, method, params})

    case params["reason"] do
      "auth" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          send(test_pid, {:authenticated_notification, method})
          Plug.Conn.resp(conn, 202, "")
        else
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        end

      "delayed_auth" ->
        send(test_pid, {:notification_held, self()})

        receive do
          :release_401 ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
            |> Plug.Conn.resp(401, "")
        after
          2_000 ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
            |> Plug.Conn.resp(401, "")
        end

      _other ->
        Plug.Conn.resp(conn, 202, "")
    end
  end

  defp respond(conn, %{"method" => method} = message, test_pid) do
    send(test_pid, {:notification, method, Map.get(message, "params", %{})})
    Plug.Conn.resp(conn, 202, "")
  end

  defp text_result(conn, id, text) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
