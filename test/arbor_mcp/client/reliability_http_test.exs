defmodule Arbor.MCP.Client.ReliabilityHTTPTest do
  @moduledoc """
  A Streamable HTTP client started with `reliability:` behaves like one
  without it, in every protocol mode: it connects, and each request after
  establishment POSTs from its own task, so calls run at the same time. The
  circuit breaker still admits every POST and records its outcome.
  """

  use ExUnit.Case, async: false

  # A client whose test process exits stops through terminate/2, which can
  # log its transport-close worker being refused; that is not under test.
  @moduletag :capture_log

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.HTTPAuth
  alias Arbor.MCP.Error.TransportError
  alias Arbor.MCP.Reliability.CircuitBreaker
  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper}

  @reliability [circuit_breaker: [failure_threshold: 2, reset_timeout: 60_000]]

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

  for {mode, era} <- [
        legacy_only: :legacy,
        prefer_legacy: :legacy,
        prefer_modern: :modern,
        modern_only: :modern
      ] do
    test "a #{mode} client connects and runs calls at the same time" do
      client = start_client(unquote(mode))

      assert {:ok, version} = Client.negotiated_version(client)
      assert era(version) == unquote(era)

      # The client sees a bare HTTP transport that carries the breaker.
      assert %{transport_mod: HTTP, transport_state: %HTTP{reliability: %ReliabilityWrapper{}}} =
               :sys.get_state(client)

      tasks =
        for label <- ["a", "b"],
            do: Task.async(fn -> Client.call_tool(client, "hold", %{"label" => label}, 5_000) end)

      # Both reached the server before either was answered, each POSTing
      # from its own task.
      handlers = for _ <- 1..2, do: receive_holding()
      assert map_size(:sys.get_state(client).async_post_tasks) == 2
      Enum.each(handlers, &send(&1, :release))

      assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, _}, &1))
      await_handlers(handlers)
    end
  end

  test "a cancelled request has its POST task stopped" do
    client = start_client(:modern_only)

    task =
      Task.async(fn -> Client.call_tool(client, "hold", %{"label" => "cancelled"}, 5_000) end)

    handler = receive_holding()
    [request_id] = Client.get_pending_requests(client)

    assert [{_monitor, {post_task, ^request_id}}] =
             Map.to_list(:sys.get_state(client).async_post_tasks)

    post_ref = Process.monitor(post_task)

    assert :ok = Client.send_cancelled(client, request_id, "not needed")
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^post_ref, :process, ^post_task, :killed}
    send(handler, :release)
    await_handlers([handler])
  end

  test "an auth challenge is answered by the client and re-sent by the task" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")} do
        {%{"method" => "server/discover", "id" => id}, _auth} ->
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover()})

        {%{"method" => "tools/call", "id" => id}, ["Bearer fresh"]} ->
          send(test_pid, :authenticated_call)
          result = %{"resultType" => "complete", "content" => []}
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

        {%{"method" => "tools/call"}, _stale} ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        reliability: @reliability,
        auth_provider: {Provider, test_pid: self()},
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)

    assert {:ok, _} = Client.call_tool(client, "protected", %{}, 5_000)
    assert_received :authenticated
    assert_received :authenticated_call
  end

  test "an open circuit refuses a request without sending it" do
    client = start_client(:modern_only)
    reliability = :sys.get_state(client).transport_state.reliability
    :ok = ReliabilityWrapper.open_circuit(reliability)

    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "hold", %{"label" => "refused"}, 2_000)

    refute_received {:holding, "refused", _handler}
  end

  describe "a POST task's admission is settled once" do
    @strict [circuit_breaker: [failure_threshold: 1, reset_timeout: 60_000]]

    test "as a failure when the task crashes" do
      client = start_client(:modern_only, @strict)

      task =
        Task.async(fn -> Client.call_tool(client, "hold", %{"label" => "crashed"}, 5_000) end)

      handler = receive_holding()
      [{_monitor, {post_task, _id}}] = Map.to_list(:sys.get_state(client).async_post_tasks)
      Process.exit(post_task, :kill)

      assert {:error, _crashed} = Task.await(task)
      send(handler, :release)
      await_handlers([handler])
      assert_refused(client)
    end

    test "as a failure when the client times the request out" do
      client = start_client(:modern_only, @strict)

      assert {:error, :timeout} =
               Client.call_tool(client, "hold", %{"label" => "slow"}, timeout: 300)

      assert_receive {:holding, "slow", handler}
      await_handlers([handler])
      assert_refused(client)
    end

    # Without a timeout of its own the POST runs past the client's default
    # timeout, which then stops the task.
    test "as a failure when the client's default timeout stops the task" do
      client = start_client(:modern_only, @strict, timeout: 300)

      assert {:error, :timeout} = Client.call_tool(client, "hold", %{"label" => "untimed"}, [])
      assert_receive {:holding, "untimed", handler}
      send(handler, :release)
      await_handlers([handler])
      assert_refused(client)
    end

    test "released, not counted, when the caller cancels" do
      client = start_client(:modern_only, @strict)

      task =
        Task.async(fn -> Client.call_tool(client, "hold", %{"label" => "cancelled"}, 5_000) end)

      handler = receive_holding()
      [request_id] = Client.get_pending_requests(client)
      assert :ok = Client.send_cancelled(client, request_id, "not needed")
      assert {:error, :cancelled} = Task.await(task)
      send(handler, :release)
      await_handlers([handler])

      assert %{total_failures: 0, state: :closed} = breaker_stats(client)
      assert {:ok, _} = Client.call_tool(client, "hold", %{"label" => "quick"}, 2_000)
      assert_receive {:holding, "quick", quick}
      await_handlers([quick])
    end

    # A caller's exit cancels its request upstream (default on for modern
    # requests); a cancellation isn't the server's failure.
    test "released, not counted, when the caller exits" do
      client = start_client(:modern_only, @strict)

      {caller, caller_ref} =
        spawn_monitor(fn -> Client.call_tool(client, "hold", %{"label" => "orphan"}, 5_000) end)

      handler = receive_holding()
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      # The client released the admission before it closed the POST, whose
      # handler then ends.
      await_handlers([handler])
      assert %{total_failures: 0, state: :closed} = breaker_stats(client)
    end

    # On legacy HTTP a timed-out POST runs on (its cancellation is only a
    # notification): the timeout settles it, and its late answer doesn't.
    test "as a failure, on legacy HTTP, when the client's timeout abandons the POST" do
      client = start_client(:legacy_only, @strict, timeout: 300)

      task =
        Task.async(fn -> Client.call_tool(client, "hold", %{"label" => "abandoned"}, []) end)

      handler = receive_holding()
      [{_monitor, {post_task, _id}}] = Map.to_list(:sys.get_state(client).async_post_tasks)
      post_ref = Process.monitor(post_task)

      assert {:error, :timeout} = Task.await(task)
      wait_until(fn -> breaker_stats(client).total_failures == 1 end, timeout: 2_000)
      successes = breaker_stats(client).total_successes

      # Its late success, once the POST task has ended, isn't recorded.
      send(handler, :release)
      assert_receive {:DOWN, ^post_ref, :process, ^post_task, _reason}, 3_000
      await_handlers([handler])
      assert %{total_failures: 1, total_successes: ^successes} = breaker_stats(client)
    end
  end

  # The client may settle a POST's admission as soon as it knows the task
  # (at its caller's exit, say), so the admission must be held by then: a
  # settle that came before the task held it was lost, and the task's own
  # result counted. A breaker that answers a process's hold of its own only
  # after the client's settle stands in for a task that runs late.
  test "a POST task's admission is held before the client knows the task" do
    bypass = Bypass.open()
    Bypass.stub(bypass, "POST", "/mcp", &Plug.Conn.resp(&1, 500, "unavailable"))

    {:ok, transport} = HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)
    transport = HTTP.settle_protocol_era(transport, :legacy, "2025-06-18")

    {:ok, wrapper} =
      ReliabilityWrapper.wrap(HTTP, transport,
        circuit_breaker: [failure_threshold: 1, reset_timeout: 60_000]
      )

    breaker = wrapper.circuit_breaker_pid
    proxy = spawn_link(fn -> late_own_holds(breaker, []) end)
    transport = HTTP.attach_reliability(transport, %{wrapper | circuit_breaker_pid: proxy})

    request =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => %{}})

    assert {:ok, _transport} = HTTP.send_async(request, transport)
    assert_received {:async_post_task, _ref, task, 7}

    # Its caller exited, so the client releases the request's admission.
    assert :ok = HTTP.settle_post(transport, task, :release)
    send(proxy, :settled)

    assert_receive {:async_post_result, {:error, _reason}, %{request_id: 7}}, 5_000
    assert %{total_failures: 0, state: :closed} = CircuitBreaker.get_stats(breaker)
  end

  # The client decides a cancelled request's outcome before it wakes the
  # POST task waiting on its authentication, so the task's own settle, an
  # auth failure from the :stream_retired it is woken with, can't count.
  # (A provider's challenge is answered in the client process, and without
  # one the auth worker's flow can't be held here, so a stand-in task waits
  # on a real waiter and settles at once when woken.)
  test "a cancellation during the POST's authentication releases its admission" do
    bypass = Bypass.open()
    Bypass.stub(bypass, "POST", "/mcp", &Plug.Conn.resp(&1, 202, ""))

    {:ok, transport} = HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)
    transport = HTTP.settle_protocol_era(transport, :legacy, "2025-06-18")

    {:ok, wrapper} =
      ReliabilityWrapper.wrap(HTTP, transport,
        circuit_breaker: [failure_threshold: 1, reset_timeout: 60_000]
      )

    transport = HTTP.attach_reliability(transport, wrapper)
    test_pid = self()
    request_id = 7
    ref = make_ref()

    task =
      spawn(fn ->
        :ok = ReliabilityWrapper.hold(wrapper)
        send(test_pid, :held)

        receive do
          {:http_post_auth_result, ^ref, result} ->
            ReliabilityWrapper.settle(
              wrapper,
              self(),
              {:result, {:error, {:auth_refused, result}}}
            )

            send(test_pid, :settled)
        end
      end)

    assert_receive :held
    monitor = Process.monitor(task)

    waiter = %{
      kind: :post,
      pid: task,
      request_id: request_id,
      ref: ref,
      deadline: Arbor.MCP.Client.Deadline.after_ms(5_000),
      challenge: %{},
      scopes: [],
      order: 1,
      flow: nil,
      monitor: monitor,
      timer: Process.send_after(self(), :unused, 60_000)
    }

    state = %Client{
      transport_mod: HTTP,
      transport_state: transport,
      pending_requests: %{request_id => {{self(), make_ref()}, :single, "tools/call"}},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{make_ref() => {task, request_id}},
      http_auth: %HTTPAuth{waiters: %{ref => waiter}, monitors: %{monitor => ref}}
    }

    {:ok, %{"method" => method, "params" => params}} =
      Arbor.MCP.Internal.Protocol.encode_cancelled(request_id, "not needed")

    assert {:reply, :ok, _state} =
             Client.handle_call(
               {:send_cancelled, request_id, method, params},
               {self(), make_ref()},
               state
             )

    assert_receive :settled
    assert %{total_failures: 0} = CircuitBreaker.get_stats(wrapper.circuit_breaker_pid)
  end

  # A 401 goes to the client process, which answers it (OAuth without a
  # provider, the provider otherwise), and the POST task re-sends the request
  # itself: the task's one admission settles with the final result, so a
  # definitive refusal counts as a failure.
  describe "a request whose authentication is refused" do
    test "counts as a failure when the OAuth flow fails" do
      client = start_refusing_client([])

      # The OAuth flow fails at once: this server's metadata isn't served
      # over HTTPS, so the request isn't sent again.
      assert {:error, %TransportError{reason: {:oauth_failed, _reason}}} =
               Client.call_tool(client, "protected", %{}, 2_000)

      assert_received :call_posted
      refute_received :call_posted
      assert %{total_failures: 1, state: :open} = breaker_stats(client)
      assert_refused_unsent(client)
    end

    test "counts as a failure when every re-send is refused" do
      client = start_refusing_client(auth_provider: {Provider, test_pid: self()})

      assert {:error, %TransportError{}} = Client.call_tool(client, "protected", %{}, 2_000)

      # The first POST and its two re-sends, after a 401 and a step-up.
      for _ <- 1..3, do: assert_received(:call_posted)
      refute_received :call_posted

      # One admission, settled once, with the final refusal. (A next call
      # is refused before the breaker sees it: the rejected credential
      # stops it in the client.)
      assert %{total_failures: 1, state: :open} = breaker_stats(client)
    end
  end

  # The client cuts off a close that stalls past its cleanup budget, before
  # the wrapper stops the components, and then stops them itself.
  test "the breaker and health check stop even when the session DELETE stalls" do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "stalling", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "stalling-session")
          |> json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    # The DELETE outlives the client's whole cleanup budget.
    test_pid = self()

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {:deleting, self()})
      hold_until_released()
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :legacy_only,
        use_sse: false,
        client_cleanup_timeout: 300,
        reliability: [
          circuit_breaker: [failure_threshold: 5],
          health_check: [check_interval: 60_000]
        ],
        health_check_interval: nil,
        reconnect: false
      )

    %ReliabilityWrapper{circuit_breaker_pid: breaker, health_check_pid: checker} =
      :sys.get_state(client).transport_state.reliability

    breaker_ref = Process.monitor(breaker)
    checker_ref = Process.monitor(checker)

    _cleanup = Client.disconnect(client)

    assert_receive {:DOWN, ^breaker_ref, :process, ^breaker, _reason}, 2_000
    assert_receive {:DOWN, ^checker_ref, :process, ^checker, _reason}, 2_000
    assert_receive {:deleting, deleting}, 2_000
    await_handlers([deleting])
  end

  # A health check waits on its check, so a busy checker can't answer a
  # graceful stop: the wrapper's wait for it outlasts the client's cleanup
  # budget. The session DELETE still goes first, and the client then stops
  # the checker itself.
  test "a busy health check neither outlives the client nor stops the session DELETE" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "busy-check", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "busy-check-session")
          |> json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      send(test_pid, :session_deleted)
      Plug.Conn.resp(conn, 204, "")
    end)

    check_fn = fn _target ->
      send(test_pid, :checking)

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :legacy_only,
        use_sse: false,
        client_cleanup_timeout: 300,
        reliability: [
          circuit_breaker: [failure_threshold: 5],
          health_check: [check_interval: 60_000, timeout: 30_000, check_fn: check_fn]
        ],
        health_check_interval: nil,
        reconnect: false
      )

    %ReliabilityWrapper{health_check_pid: checker} =
      :sys.get_state(client).transport_state.reliability

    checker_ref = Process.monitor(checker)
    # The first check starts a second after the checker does.
    assert_receive :checking, 3_000

    _cleanup = Client.disconnect(client)

    assert_receive {:DOWN, ^checker_ref, :process, ^checker, _reason}, 2_000
    assert_receive :session_deleted, 2_000
  end

  test "POSTs that fail open the circuit" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "server/discover", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => discover()})
          )

        %{"method" => "tools/call"} ->
          send(test_pid, :call_posted)
          Plug.Conn.resp(conn, 500, "unavailable")
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        reliability: @reliability,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)

    for _ <- 1..2 do
      assert {:error, %TransportError{}} = Client.call_tool(client, "any", %{}, 2_000)
      assert_received :call_posted
    end

    # Two failures reached the threshold.
    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "any", %{}, 2_000)

    refute_received :call_posted
  end

  # Forwards calls to `breaker`, keeping back a hold a process takes for
  # itself until told the client has settled.
  defp late_own_holds(breaker, kept) do
    receive do
      :settled ->
        Enum.each(kept, &send(breaker, &1))
        forward_all(breaker)

      {:"$gen_call", {caller, _tag}, request} = call ->
        if own_hold?(request, caller) do
          late_own_holds(breaker, kept ++ [call])
        else
          send(breaker, call)
          late_own_holds(breaker, kept)
        end

      other ->
        send(breaker, other)
        late_own_holds(breaker, kept)
    end
  end

  defp forward_all(breaker) do
    receive do
      message ->
        send(breaker, message)
        forward_all(breaker)
    end
  end

  defp own_hold?(:hold, _caller), do: true
  defp own_hold?({:hold, caller}, caller), do: true
  defp own_hold?(_request, _caller), do: false

  defp era(version), do: Arbor.MCP.Internal.VersionRegistry.era_for(version)

  # A Bypass handler still running when its test ends leaves Bypass 2.1.0's
  # instance to answer on_exit late, and it then crashes calling
  # GenServer.stop(:normal); a few such crashes in a row stop the
  # Bypass.Supervisor, and every later Bypass.open in the run fails. So a
  # test waits for the handlers it started.
  defp await_handlers(handlers) do
    for handler <- handlers do
      ref = Process.monitor(handler)
      assert_receive {:DOWN, ^ref, :process, ^handler, _reason}, 3_000
    end
  end

  # A modern server that refuses every tools/call with a Bearer 401.
  defp start_refusing_client(opts) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "server/discover", "id" => id} ->
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover()})

        %{"method" => "tools/call"} ->
          send(test_pid, :call_posted)

          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
          |> Plug.Conn.resp(401, "")
      end
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          protocol_mode: :modern_only,
          reliability: [circuit_breaker: [failure_threshold: 1, reset_timeout: 60_000]],
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp assert_refused_unsent(client) do
    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "protected", %{}, 2_000)

    refute_received :call_posted
  end

  # The circuit is open: a call is refused before anything is sent. The
  # caller hears of its failed call before the breaker has always recorded
  # it (the task settles at the same deadline, the client after it replies),
  # so the check waits for the failure first.
  defp assert_refused(client) do
    wait_until(fn -> breaker_stats(client).total_failures >= 1 end,
      timeout: 2_000
    )

    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "hold", %{"label" => "refused"}, 2_000)

    refute_received {:holding, "refused", _handler}
  end

  defp breaker_stats(client),
    do:
      ReliabilityWrapper.get_circuit_breaker_stats(
        :sys.get_state(client).transport_state.reliability
      )

  defp receive_holding do
    assert_receive {:holding, _label, handler}, 3_000
    handler
  end

  defp discover do
    %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "failing", "version" => "1"}
      }
    }
  end

  # A scripted dual-era server: it answers server/discover and initialize,
  # and holds each tools/call until the test releases it.
  defp start_client(protocol_mode, reliability \\ @reliability, opts \\ []) do
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
          protocol_mode: protocol_mode,
          reliability: reliability,
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, _test_pid),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover()})

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    result = %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "reliability-http", "version" => "1"}
    }

    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    label = get_in(params, ["arguments", "label"])
    # Trapping before it reports: the test may cancel as soon as it hears.
    Process.flag(:trap_exit, true)
    send(test_pid, {:holding, label, self()})
    unless label == "quick", do: hold_until_released()

    content = [%{"type" => "text", "text" => label}]
    result = %{"resultType" => "complete", "content" => content}
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond(conn, _notification, _test_pid), do: Plug.Conn.resp(conn, 202, "")

  # A client that cancels closes the connection; end normally when Cowboy
  # stops this handler for that. Callers trap exits first.
  defp hold_until_released do
    Process.flag(:trap_exit, true)

    receive do
      :release -> :ok
      {:EXIT, _from, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp stop(client) do
    if Process.alive?(client) do
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end
