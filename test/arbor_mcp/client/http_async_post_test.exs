defmodule Arbor.MCP.Client.HTTPAsyncPostTest do
  @moduledoc """
  The HTTP client POSTs each request from its own task. It must still behave
  as the synchronous path did: a POST's response answers the request it
  carried, a POST that runs past its caller's deadline is the caller's timeout
  and is cancelled on the server, and concurrent auth challenges run one
  authentication, from the client process.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  defmodule Provider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

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

  # A 401 refreshes to "fresh"; a later 403 steps up to "fresher".
  defmodule StepUpProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{token: "stale"}}
    @impl true
    def get_token(state), do: {:ok, state.token, state}
    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state),
      do: {:ok, "fresh", %{state | token: "fresh"}}

    @impl true
    def handle_forbidden(_www_authenticate, _scopes, state),
      do: {:ok, "fresher", %{state | token: "fresher"}}
  end

  test "a request that finishes late doesn't put back the token it was sent with" do
    client = start_client(auth_provider: {StepUpProvider, []})

    held =
      Task.async(fn -> Client.call_tool(client, "protected_held", %{}, timeout: 15_000) end)

    assert_receive {:tool_call_started, "protected_held", handler}, 5_000

    assert {:ok, _} = Client.call_tool(client, "step_up", %{}, timeout: 5_000)
    send(handler, :release)
    assert {:ok, _} = Task.await(held, 15_000)

    assert :sys.get_state(client).transport_state.access_token == "fresher"
  end

  test "a response with a null or different id answers the request its POST carried" do
    client = start_client()

    assert {:error, %{code: -32600}} = Client.call_tool(client, "null_id", %{}, timeout: 5_000)
    assert {:ok, _result} = Client.call_tool(client, "string_id", %{}, timeout: 5_000)
  end

  test "a request whose POST outlives an explicit timeout is cancelled on the server" do
    client = start_client()

    assert {:error, :timeout} = Client.call_tool(client, "hang", %{}, timeout: 300)
    assert_receive {:tool_call_started, "hang", _handler}
    assert_receive {:notification, "notifications/cancelled", %{"requestId" => _id}}, 2_000
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

  # The retried POST used to run in the client process, holding every other
  # request until it finished, and a request it carried couldn't be answered.
  test "a request re-sent after authenticating doesn't hold up the client" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    held =
      Task.async(fn -> Client.call_tool(client, "protected_held", %{}, timeout: 15_000) end)

    assert_receive :authenticated, 5_000
    assert_receive {:tool_call_started, "protected_held", handler}, 5_000

    assert {:ok, _} = Client.call_tool(client, "quick", %{}, timeout: 5_000)
    assert_receive {:client_answered, "server-ping"}, 5_000

    send(handler, :release)
    assert {:ok, _} = Task.await(held, 15_000)
  end

  test "a POST that answers after its request settled is dropped, not given to another" do
    client = start_client()

    late = Task.async(fn -> Client.call_tool(client, "late", %{}, timeout: 5_000) end)
    assert_receive {:tool_call_started, "late", _late_handler, late_id}
    other = Task.async(fn -> Client.call_tool(client, "other", %{}, timeout: 5_000) end)
    assert_receive {:tool_call_started, "other", other_handler, other_id}

    {late_ref, {late_post, ^late_id}} =
      Enum.find(:sys.get_state(client).async_post_tasks, fn
        {_ref, {_pid, ^late_id}} -> true
        _other -> false
      end)

    monitor = Process.monitor(late_post)

    :ok = Client.send_cancelled(client, late_id, "user")
    assert {:error, :cancelled} = Task.await(late)
    assert_receive {:notification, "notifications/cancelled", %{"requestId" => ^late_id}}
    assert_receive {:DOWN, ^monitor, :process, ^late_post, :killed}

    # Cancellation closes the POST now. A result queued before its worker
    # stopped must still be ignored, even if it names another pending request.
    stale_response =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => other_id,
        "result" => %{"content" => [%{"type" => "text", "text" => "late"}]}
      })

    send(
      client,
      {:async_post_result, {:ok, nil, stale_response},
       %{task_ref: late_ref, task_pid: late_post, request_id: late_id}}
    )

    _state = :sys.get_state(client)
    send(other_handler, :release)

    assert {:ok, response} = Task.await(other)
    assert [%{text: "other"}] = response.content
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

  test "a cancellation the server is slow to accept does not hold other requests" do
    client = start_client()

    cancel = Task.async(fn -> Client.send_cancelled(client, "unknown-request", "stall") end)
    assert_receive {:cancel_started, cancel_handler}, 2_000

    # Well inside the stalled cancellation's 2 s.
    assert {:ok, _} = Client.call_tool(client, "quick", %{}, timeout: 500)
    send(cancel_handler, :release)
    assert :ok = Task.await(cancel)
  end

  test "an auth challenge on a notification re-sends it after authenticating" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    :ok = Client.send_cancelled(client, "unknown-request", "auth")
    assert_receive :authenticated, 2_000
    assert_receive {:authenticated_notification, "notifications/cancelled"}, 2_000
  end

  test "a request refused a client worker fails at once" do
    client = start_client(max_client_workers: 1)

    held = Task.async(fn -> Client.call_tool(client, "hang", %{}, timeout: 5_000) end)
    assert_receive {:tool_call_started, "hang", handler}

    assert {:error, _not_sent} = Client.call_tool(client, "quick", %{}, timeout: 2_000)

    send(handler, :release)
    assert {:ok, _} = Task.await(held)
  end

  defp receive_list_started do
    assert_receive {:list_started, _cursor, handler}, 2_000
    handler
  end

  defp start_client(opts \\ []) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    json(conn, %{
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

    tools = [%{"name" => "tool_#{cursor}", "inputSchema" => %{"type" => "object"}}]
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
  end

  defp respond(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}},
         test_pid
       )
       when name in ["late", "other"] do
    Process.flag(:trap_exit, true)
    send(test_pid, {:tool_call_started, name, self(), id})

    receive do
      :release -> text_result(conn, id, name)
      {:EXIT, _from, _reason} -> text_result(conn, id, name)
    after
      2_000 -> text_result(conn, id, name)
    end
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    name = params["name"]
    if name != "protected_held", do: send(test_pid, {:tool_call_started, name, self()})

    case name do
      "quick" ->
        text_result(conn, id, name)

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

      name when name in ["protected", "protected_held", "step_up"] ->
        respond_protected(conn, name, id, test_pid)
    end
  end

  defp respond(conn, %{"method" => "notifications/cancelled" = method} = message, test_pid) do
    params = Map.get(message, "params", %{})
    send(test_pid, {:notification, method, params})

    case params["reason"] do
      "stall" ->
        send(test_pid, {:cancel_started, self()})
        Process.flag(:trap_exit, true)

        receive do
          :release -> :ok
          {:EXIT, _from, _reason} -> :ok
        after
          2_000 -> :ok
        end

        Plug.Conn.resp(conn, 202, "")

      "auth" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          send(test_pid, {:authenticated_notification, method})
          Plug.Conn.resp(conn, 202, "")
        else
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

  defp respond(conn, %{"id" => id, "result" => _result}, test_pid) do
    send(test_pid, {:client_answered, id})
    Plug.Conn.resp(conn, 202, "")
  end

  # Tools that need a bearer token the stub's providers hand out.
  defp respond_protected(conn, name, id, test_pid) do
    case name do
      # Once authenticated, asks the client something on the stream and
      # waits to be released.
      "protected_held" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          ping = %{"jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping"}
          {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(ping)}\n\n")
          send(test_pid, {:tool_call_started, name, self()})

          # A watchdog well past the test's own timeouts.
          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end

          done = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}}
          {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(done)}\n\n")
          conn
        else
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        end

      "step_up" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresher"] do
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
        else
          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer error="insufficient_scope", scope="more")
          )
          |> Plug.Conn.resp(403, "")
        end

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
