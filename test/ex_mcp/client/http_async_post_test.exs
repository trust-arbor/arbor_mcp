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

  defmodule VersionedProvider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      send(state.test_pid, :authed_t1)
      {:ok, "T1", Map.put(state, :token, "T1")}
    end

    @impl true
    def handle_forbidden(_www_authenticate, _scopes, state) do
      send(state.test_pid, :authed_t2)
      {:ok, "T2", Map.put(state, :token, "T2")}
    end
  end

  defmodule TokenRotationProvider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(config, :test_pid),
         token_agent: Keyword.fetch!(config, :token_agent)
       }}
    end

    @impl true
    def get_token(state) do
      token = Agent.get(state.token_agent, & &1)
      {:ok, token, state}
    end

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      send(state.test_pid, :unexpected_reauth)
      {:ok, "T_unexpected", state}
    end

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  defmodule SlowAuthProvider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      Process.sleep(200)
      send(state.test_pid, :slow_auth_finished)
      {:ok, "T_slow", state}
    end

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
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

  test "cursor page 401 retry carrying captured older generation does not merge into newer generation" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    client = start_client(auth_provider: {Provider, test_pid: self()}, cursor_counter: counter)

    # Establish generation 1 with a first page
    p_gen1_first = Task.async(fn -> Client.list_tools(client, timeout: 5_000) end)
    {nil, gen1_first_handler} = receive_list_started_with_cursor()
    send(gen1_first_handler, :release)
    assert {:ok, _} = Task.await(p_gen1_first, 2_000)

    cache = :sys.get_state(client).transport_state.tool_headers
    assert Map.has_key?(cache, "tool_first")

    # Start cursor page for generation 1 (captures generation 1)
    p_cursor = Task.async(fn -> Client.list_tools(client, cursor: "hold_401", timeout: 5_000) end)
    assert_receive {:cursor_hold_started, cursor_handler}, 2_000

    # In the meantime, start and complete a fresh first page (generation 2)
    p_gen2_first = Task.async(fn -> Client.list_tools(client, timeout: 5_000) end)
    {nil, gen2_first_handler} = receive_list_started_with_cursor()

    send(
      gen2_first_handler,
      {:release_tools, [%{"name" => "tool_gen2", "inputSchema" => %{"type" => "object"}}]}
    )

    assert {:ok, _} = Task.await(p_gen2_first, 2_000)

    cache = :sys.get_state(client).transport_state.tool_headers
    assert Map.has_key?(cache, "tool_gen2")
    refute Map.has_key?(cache, "tool_first")

    # Release cursor request: it gets 401, client reauthenticates and retries
    send(cursor_handler, :release)
    assert_receive :authenticated, 2_000
    assert {:ok, _} = Task.await(p_cursor, 5_000)

    # Stale generation 1 cursor retry must NOT have merged into generation 2
    cache = :sys.get_state(client).transport_state.tool_headers
    assert Map.has_key?(cache, "tool_gen2")
    refute Map.has_key?(cache, "tool_stale_hold")
    refute Map.has_key?(cache, "tool_first")
  end

  test "a delayed older retry credentials do not overwrite newer credentials" do
    client = start_client(auth_provider: {VersionedProvider, test_pid: self()})

    task_a = Task.async(fn -> Client.call_tool(client, "versioned_a", %{}, timeout: 5_000) end)
    assert_receive :authed_t1, 2_000
    assert_receive {:holding_a, handler_a}, 2_000

    task_b = Task.async(fn -> Client.call_tool(client, "versioned_b", %{}, timeout: 5_000) end)
    assert_receive :authed_t2, 2_000
    assert {:ok, _} = Task.await(task_b, 2_000)

    # Client now has T2
    assert :sys.get_state(client).transport_state.access_token == "T2"

    # Now release delayed Task A (which completed with T1)
    send(handler_a, :release)
    assert {:ok, _} = Task.await(task_a, 2_000)

    # Client MUST STILL have T2 (T1 did not overwrite T2)
    assert :sys.get_state(client).transport_state.access_token == "T2"

    # Third call gets T2
    assert {:ok, _} = Client.call_tool(client, "versioned_c", %{}, timeout: 5_000)
    assert_receive {:c_auth, ["Bearer T2"]}, 2_000
  end

  test "a healthy legacy HTTP connection survives several health intervals" do
    client = start_client(health_check_interval: 40)

    # First health ping arrives and is answered
    assert_receive {:health_ping, first_id}, 1_000

    # Wait for second and third health pings across multiple intervals
    assert_receive {:health_ping, second_id}, 1_000
    assert second_id != first_id

    assert_receive {:health_ping, third_id}, 1_000
    assert third_id != second_id

    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert Client.get_pending_requests(client) == []
  end

  test "a cancelled request does not authenticate and re-send on a delayed 401" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    task =
      Task.async(fn ->
        Client.call_tool(client, "cancel_then_401", %{}, timeout: 5_000)
      end)

    assert_receive {:tool_cancel_attempt, req_id, handler}, 2_000

    # Cancel the request while it is held at the server
    :ok = Client.send_cancelled(client, req_id, "user_cancelled")
    assert {:error, :cancelled} = Task.await(task, 2_000)

    # Deliver delayed 401 challenge from the held POST
    send(handler, :send_401)

    # On 9dabc8d, client authenticates and re-sends the cancelled request.
    # With the fix, the retired task is refused and never re-sent.
    refute_receive {:tool_cancel_attempt, ^req_id, _}, 1_000
    refute_receive :authenticated, 1_000
  end

  test "a delayed T0 challenge after a refresh reuses T1 with no second refresh" do
    {:ok, agent} = Agent.start_link(fn -> "T0" end)

    client =
      start_client(auth_provider: {TokenRotationProvider, test_pid: self(), token_agent: agent})

    # Send Request A with initial token T0 (held on server)
    task_a =
      Task.async(fn ->
        Client.call_tool(client, "t0_held", %{}, timeout: 5_000)
      end)

    assert_receive {:t0_held, _req_id_a, handler_a}, 2_000

    # Rotate provider token to T1
    Agent.update(agent, fn _ -> "T1" end)

    # Send Request B which picks up T1 in apply_provider_token
    assert {:ok, _} = Client.call_tool(client, "fast", %{}, timeout: 5_000)

    # Now deliver delayed 401 challenge to Request A (which sent with T0)
    send(handler_a, :send_401)

    # On 9dabc8d, returned transport did not keep T1, so it reauthenticates (fires :unexpected_reauth).
    # With the fix, T1 is kept in the client's transport and reused without reauth.
    refute_receive :unexpected_reauth, 500
    assert_receive {:t0_retry_success, _}, 2_000
    assert {:ok, _} = Task.await(task_a, 2_000)
  end

  test "a request without explicit timeout uses default timeout to bound auth wait and never re-sends past deadline" do
    client =
      start_client(
        auth_provider: {SlowAuthProvider, test_pid: self()},
        default_timeout: 40
      )

    task =
      Task.async(fn ->
        # No explicit timeout option passed (timeout: nil)
        Client.call_tool(client, "timeout_auth", %{}, timeout: nil, retry_policy: false)
      end)

    assert_receive {:timeout_auth_post, req_id, _auth}, 2_000

    # The caller must time out at the 40ms default timeout
    assert {:error, %ExMCP.Error.ProtocolError{message: "Request timeout"}} =
             Task.await(task, 2_000)

    # Auth flow takes 200ms
    assert_receive :slow_auth_finished, 2_000

    # On 9dabc8d, task waited for auth and re-sent past the 40ms default deadline.
    # With the fix, the task never re-sends after its deadline expired.
    refute_receive {:unexpected_resend_past_deadline, ^req_id}, 500
    refute_receive {:timeout_auth_post, ^req_id, ["Bearer T_slow"]}, 500
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
    cursor_counter = Keyword.get(opts, :cursor_counter)
    opts = Keyword.delete(opts, :cursor_counter)

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid, cursor_counter)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 204, "")
    end)

    base_opts = [
      transport: :http,
      url: "http://127.0.0.1:#{bypass.port}/mcp",
      use_sse: true,
      protocol_mode: :legacy_only,
      health_check_interval: nil,
      reconnect: false
    ]

    {:ok, client} = Client.start_link(Keyword.merge(base_opts, opts))

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp respond(conn, message, test_pid, counter)

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid, _counter) do
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

  defp respond(
         conn,
         %{"method" => "tools/list", "id" => id, "params" => params},
         test_pid,
         counter
       ) do
    cursor = params["cursor"]
    auth = Plug.Conn.get_req_header(conn, "authorization")

    case {cursor, auth} do
      {"hold_401", ["Bearer fresh"]} ->
        tools = [%{"name" => "tool_stale_hold", "inputSchema" => %{"type" => "object"}}]
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})

      {"hold_401", _stale_auth} ->
        attempt = if counter, do: Agent.get_and_update(counter, &{&1 + 1, &1 + 1}), else: 1

        if attempt == 1 do
          send(test_pid, {:cursor_hold_started, self()})

          receive do
            :release -> :ok
          after
            2_000 -> :ok
          end
        end

        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")

      _ ->
        send(test_pid, {:list_started, cursor, self()})

        receive do
          :release ->
            tools = [
              %{"name" => "tool_#{cursor || "first"}", "inputSchema" => %{"type" => "object"}}
            ]

            json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})

          {:release_tools, tools} ->
            json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
        after
          2_000 ->
            tools = [
              %{"name" => "tool_#{cursor || "first"}", "inputSchema" => %{"type" => "object"}}
            ]

            json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
        end
    end
  end

  defp respond(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}},
         test_pid,
         _counter
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

  defp respond(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => params},
         test_pid,
         _counter
       ) do
    name = params["name"]
    send(test_pid, {:tool_call_started, name, self()})
    respond_tool(conn, id, name, test_pid)
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, test_pid, _counter) do
    send(test_pid, {:health_ping, id})
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp respond(
         conn,
         %{"method" => "notifications/cancelled" = method} = message,
         test_pid,
         _counter
       ) do
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

  defp respond(conn, %{"method" => method} = message, test_pid, _counter) do
    send(test_pid, {:notification, method, Map.get(message, "params", %{})})
    Plug.Conn.resp(conn, 202, "")
  end

  defp respond_tool(conn, _id, "null_id", _test_pid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Invalid Request"}
    })
  end

  defp respond_tool(conn, id, "string_id", _test_pid) do
    json(conn, %{"jsonrpc" => "2.0", "id" => to_string(id), "result" => %{"content" => []}})
  end

  defp respond_tool(conn, id, "hang", _test_pid) do
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
  end

  defp respond_tool(conn, id, "protected", _test_pid) do
    if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
      json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
    else
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
      |> Plug.Conn.resp(401, "")
    end
  end

  defp respond_tool(conn, id, name, test_pid)
       when name in ["versioned_a", "versioned_b", "versioned_c"] do
    respond_versioned(conn, id, name, test_pid)
  end

  defp respond_tool(conn, id, "cancel_then_401", test_pid) do
    send(test_pid, {:tool_cancel_attempt, id, self()})

    receive do
      :send_401 ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")

      :allow ->
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
    after
      2_000 ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")
    end
  end

  defp respond_tool(conn, id, "t0_held", test_pid) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer T1"] ->
        send(test_pid, {:t0_retry_success, id})
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})

      _other ->
        send(test_pid, {:t0_held, id, self()})

        receive do
          :send_401 ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
            |> Plug.Conn.resp(401, "")
        after
          2_000 ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
            |> Plug.Conn.resp(401, "")
        end
    end
  end

  defp respond_tool(conn, id, "fast", _test_pid) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
  end

  defp respond_tool(conn, id, "timeout_auth", test_pid) do
    auth = Plug.Conn.get_req_header(conn, "authorization")
    send(test_pid, {:timeout_auth_post, id, auth})

    case auth do
      ["Bearer T_slow"] ->
        send(test_pid, {:unexpected_resend_past_deadline, id})
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})

      _ ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")
    end
  end

  defp respond_versioned(conn, id, "versioned_a", test_pid) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer T1"] ->
        send(test_pid, {:holding_a, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"content" => [%{"type" => "text", "text" => "a_done"}]}
        })

      _other ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")
    end
  end

  defp respond_versioned(conn, id, "versioned_b", _test_pid) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer T2"] ->
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"content" => [%{"type" => "text", "text" => "b_done"}]}
        })

      _other ->
        conn
        |> Plug.Conn.put_resp_header(
          "www-authenticate",
          ~s(Bearer error="insufficient_scope", scope="tools:b")
        )
        |> Plug.Conn.resp(403, "")
    end
  end

  defp respond_versioned(conn, id, "versioned_c", test_pid) do
    auth = Plug.Conn.get_req_header(conn, "authorization")
    send(test_pid, {:c_auth, auth})

    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"content" => [%{"type" => "text", "text" => "c_done"}]}
    })
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
