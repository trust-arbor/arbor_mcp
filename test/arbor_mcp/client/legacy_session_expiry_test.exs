defmodule Arbor.MCP.Client.LegacySessionExpiryTest do
  @moduledoc """
  A legacy Streamable HTTP server answers 404 to a request that carries a
  session it has ended, after a restart for example, and the client MUST then
  start a new session with an `initialize` that carries no session id
  (Session Management, 2025-03-26 and later).

  The request that found the session gone fails with
  `{:session_expired, _}` and is not sent again, and requests in flight on
  the session fail with it too. The client then reconnects, which starts the
  new session, or stays disconnected under `reconnect: false`. Modern
  (2026-07-28) connections carry no session and are unaffected.
  """

  use ExUnit.Case, async: false

  # A client whose test ends stops through terminate/2, and a Bypass handler
  # can answer on a connection the client has closed; neither is under test.
  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.{ProtocolError, TransportError}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Transport.ReliabilityWrapper

  @version "2025-11-25"
  @not_found ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Session not found"}})

  @events [
    [:arbor_mcp, :client, :disconnected],
    [:arbor_mcp, :client, :reconnect, :attempt],
    [:arbor_mcp, :client, :reconnect, :success]
  ]

  @doc false
  def handle_event(event, _measurements, %{pid: pid} = meta, test),
    do: send(test, {:telemetry, event, pid, meta})

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-11-25",
         serverInfo: %{name: "session-ending", version: "1"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}
  end

  setup do
    test = self()
    bypass = Bypass.open()
    # An initialize without a session id opens a new session, and one with
    # the live session's id resumes it. A request for any other session, an
    # ended one included, gets the 404 a legacy server answers. `new:` says
    # how an initialize that opens a session is answered: `:open`, or
    # `:unavailable` (503), or `:held` until the test releases it. One that
    # offers a revision outside `accepts:` is rejected with -32602, and
    # `discover:` `{:unsupported, versions}` answers server/discover with a
    # -32022 that lists them (nil: the 404 of a server without it).
    server =
      start_supervised!(
        {Agent, fn -> %{generation: 0, live: nil, new: :open, accepts: :any, discover: nil} end}
      )

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      session = session_header(conn)
      message = Jason.decode!(body)
      send(test, {:post, message["method"], session})
      answer(conn, message, session, server, test)
    end)

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      session = session_header(conn)
      send(test, {:get, session})

      if live?(server, session),
        do: hold_stream(conn, session, test),
        else: not_found(conn)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      send(test, {:delete, session_header(conn)})
      Plug.Conn.resp(conn, 204, "")
    end)

    handler = "legacy-session-expiry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, test)
    on_exit(fn -> :telemetry.detach(handler) end)

    %{url: "http://127.0.0.1:#{bypass.port}/mcp", server: server}
  end

  describe "with reconnect: true" do
    test "the request that finds the session gone fails, and a new session starts",
         %{url: url, server: server} do
      client = start_client(url, reconnect: true)
      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-1"}

      end_session(server)

      assert {:error,
              %TransportError{
                transport: :http,
                reason: {:session_expired, {:http_error, 404, @not_found}}
              } = error} = Client.list_tools(client)

      assert_receive {:post, "tools/list", "session-1"}
      # The server answered it, as it answers any HTTP error: whether it acted
      # is for the caller to judge.
      assert Client.delivery_outcome(error) == :unknown

      # The transport closed as for a lost connection, the session DELETE
      # included, and a reconnect is under way.
      assert {:ok, %{connection_status: :reconnecting}} = Client.get_status(client)

      assert_receive {:telemetry, [:arbor_mcp, :client, :disconnected], ^client,
                      %{reason: {:session_expired, _detail}}}

      assert_receive {:delete, "session-1"}

      # The new session comes from an initialize without the old session id.
      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert_receive {:post, "initialize", nil}
      assert_receive {:post, "notifications/initialized", "session-2"}

      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-2"}

      # The request that found the session gone was not sent again.
      refute_received {:post, "tools/list", _session}
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    end

    test "requests in flight on the ended session fail with it too, and none hangs",
         %{url: url, server: server} do
      client = start_client(url, reconnect: true)

      held =
        for _ <- 1..2,
            do: Task.async(fn -> Client.call_tool(client, "hold", %{}, timeout: 10_000) end)

      handlers = for _ <- 1..2, do: receive_holding()
      end_session(server)

      assert {:error, %TransportError{reason: {:session_expired, _detail} = reason}} =
               Client.list_tools(client)

      for task <- held do
        assert {:error, %TransportError{transport: :http, reason: ^reason}} =
                 Task.await(task, 2_000)
      end

      assert Client.get_pending_requests(client) == []
      Enum.each(handlers, &send(&1, :release))
      await_handlers(handlers)

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-2"}
    end

    # A notification goes out synchronously without a GET stream; its 404
    # ends the session as a request's does.
    test "a notification that finds the session gone starts a new session too",
         %{url: url, server: server} do
      client = start_client(url, reconnect: true)
      end_session(server)

      Client.notify(client, "notifications/roots/list_changed", %{})
      assert_receive {:post, "notifications/roots/list_changed", "session-1"}

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert_receive {:post, "initialize", nil}
      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-2"}
    end

    # The GET stream carries the session too. The server closes it as it
    # ends the session, and the reopened GET gets the 404.
    test "a 404 for the reopened GET stream ends the session", %{url: url, server: server} do
      client = start_client(url, reconnect: true, use_sse: true)
      assert_receive {:get_opened, "session-1", stream}, 2_000

      held = Task.async(fn -> Client.call_tool(client, "hold", %{}, timeout: 10_000) end)
      handler = receive_holding()

      end_session(server)
      send(stream, :release)
      await_handlers([stream])

      assert {:error,
              %TransportError{reason: {:session_expired, {:sse_error, {:http_error, 404}}}}} =
               Task.await(held, 3_000)

      send(handler, :release)
      await_handlers([handler])

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     3_000

      assert_receive {:post, "initialize", nil}
      assert_receive {:get_opened, "session-2", new_stream}, 2_000
      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-2"}

      stop(client)
      send(new_stream, :release)
      await_handlers([new_stream])
    end

    # A configured `:session_id` the server resumed is the session it ended.
    test "a configured session_id isn't sent with the new session's initialize",
         %{url: url, server: server} do
      resume(server, "configured-session")
      client = start_client(url, reconnect: true, session_id: "configured-session")
      assert_receive {:post, "initialize", "configured-session"}
      assert_receive {:post, "notifications/initialized", "configured-session"}
      end_session(server)

      assert {:error, %TransportError{reason: {:session_expired, _detail}}} =
               Client.list_tools(client)

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert_receive {:post, "initialize", nil}
      assert_receive {:post, "notifications/initialized", "session-1"}
      refute_received {:post, "initialize", _session}
    end

    # The server ended the configured session while the client was away for
    # another reason (here a lost connection), so the reconnect's initialize
    # gets the 404: the client sends another without the id.
    test "a reconnect starts a new session when the configured one has ended",
         %{url: url, server: server} do
      resume(server, "configured-session")
      client = start_client(url, reconnect: true, session_id: "configured-session")
      assert_receive {:post, "initialize", "configured-session"}
      end_session(server)

      send(client, {:transport_closed, :connection_lost})

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert_received {:post, "initialize", "configured-session"}
      assert_received {:post, "initialize", nil}

      refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], ^client,
                       %{attempt: 2}}

      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-1"}

      # The configured id is no longer offered to a later connection.
      send(client, {:transport_closed, :connection_lost})

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      assert_received {:post, "initialize", nil}
      refute_received {:post, "initialize", _session}
    end

    # The client keeps the circuit breaker and health check `reliability:`
    # starts itself (#186): the session's end stops them, and the new
    # connection starts its own.
    test "the reliability components stop with the session, and new ones start",
         %{url: url, server: server} do
      client =
        start_client(url,
          reconnect: true,
          reliability: [
            circuit_breaker: [failure_threshold: 5],
            health_check: [check_interval: 60_000]
          ]
        )

      %ReliabilityWrapper{circuit_breaker_pid: breaker, health_check_pid: checker} =
        :sys.get_state(client).transport_state.reliability

      breaker_ref = Process.monitor(breaker)
      checker_ref = Process.monitor(checker)
      end_session(server)

      assert {:error, %TransportError{reason: {:session_expired, _detail}}} =
               Client.list_tools(client)

      assert_receive {:DOWN, ^breaker_ref, :process, ^breaker, _reason}, 2_000
      assert_receive {:DOWN, ^checker_ref, :process, ^checker, _reason}, 2_000

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                     2_000

      %ReliabilityWrapper{circuit_breaker_pid: new_breaker, health_check_pid: new_checker} =
        :sys.get_state(client).transport_state.reliability

      assert Process.alive?(new_breaker) and new_breaker != breaker
      assert Process.alive?(new_checker) and new_checker != checker
      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-2"}
    end
  end

  # start_link/1's initialize carries the configured id, and the server
  # answers 404 for it: the client must start a new session instead.
  describe "a configured session_id the server has ended" do
    test "is replaced at start by a new session", %{url: url} do
      client = start_client(url, reconnect: false, session_id: "ended-session")

      assert_received {:post, "initialize", "ended-session"}
      assert_received {:post, "initialize", nil}
      assert_received {:post, "notifications/initialized", "session-1"}
      refute_received {:post, "initialize", _session}

      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive {:post, "tools/list", "session-1"}
    end

    test "is retried once, and the new session's failure is reported", %{
      url: url,
      server: server
    } do
      Process.flag(:trap_exit, true)
      Agent.update(server, &%{&1 | new: :unavailable})

      assert {:error, reason} = start(url, reconnect: false, session_id: "ended-session")
      assert inspect(reason) =~ "503"
      refute inspect(reason) =~ "session_expired"

      assert_received {:post, "initialize", "ended-session"}
      assert_received {:post, "initialize", nil}
      refute_received {:post, "initialize", _session}
    end

    # The second initialize gets no more than the connection has left.
    test "is retried within the establish deadline", %{url: url, server: server} do
      Process.flag(:trap_exit, true)
      Agent.update(server, &%{&1 | new: :held})
      started = System.monotonic_time(:millisecond)

      assert {:error, reason} =
               start(url, reconnect: false, session_id: "ended-session", establish_timeout: 500)

      elapsed = System.monotonic_time(:millisecond) - started
      assert reason in [:establish_timeout, :handshake_timeout]
      assert elapsed < 3_000

      assert_received {:post, "initialize", "ended-session"}
      assert_received {:post, "initialize", nil}
      handler = receive_holding()
      send(handler, :release)
      await_handlers([handler])
    end
  end

  # Each connection attempt offers an ended configured session once, whatever
  # else the attempt goes on to try.
  describe "a configured session_id the server has ended, while the era is negotiated" do
    # Under :prefer_legacy the session-free initialize can be rejected for
    # its revision. The client then probes and initializes again with a
    # revision the server lists; that initialize must not offer the ended
    # session again.
    test "is offered once across a prefer_legacy version retry", %{url: url, server: server} do
      Agent.update(
        server,
        &%{&1 | accepts: ["2025-06-18"], discover: {:unsupported, ["2025-06-18"]}}
      )

      client =
        start_client(url,
          reconnect: false,
          protocol_mode: :prefer_legacy,
          session_id: "ended-session"
        )

      assert {:ok, "2025-06-18"} = Client.negotiated_version(client)

      assert posts() == [
               {"initialize", "ended-session"},
               {"initialize", nil},
               {"server/discover", nil},
               {"initialize", nil},
               {"notifications/initialized", "session-1"}
             ]

      assert_received {:initialize, "ended-session", "2025-11-25"}
      assert_received {:initialize, nil, "2025-11-25"}
      assert_received {:initialize, nil, "2025-06-18"}
    end

    test "is offered once under prefer_modern's legacy fallback", %{url: url, server: server} do
      Agent.update(
        server,
        &%{&1 | accepts: ["2025-06-18"], discover: {:unsupported, ["2025-06-18"]}}
      )

      client =
        start_client(url,
          reconnect: false,
          protocol_mode: :prefer_modern,
          session_id: "ended-session"
        )

      assert {:ok, "2025-06-18"} = Client.negotiated_version(client)

      assert posts() == [
               {"server/discover", nil},
               {"initialize", "ended-session"},
               {"initialize", nil},
               {"notifications/initialized", "session-1"}
             ]
    end

    test "is offered once when prefer_modern's fallback fails", %{url: url, server: server} do
      Process.flag(:trap_exit, true)
      Agent.update(server, &%{&1 | accepts: [], discover: {:unsupported, ["2025-06-18"]}})

      assert {:error, reason} =
               start(url,
                 reconnect: false,
                 protocol_mode: :prefer_modern,
                 session_id: "ended-session"
               )

      assert inspect(reason) =~ "era_probe_and_initialize_failed"

      assert posts() == [
               {"server/discover", nil},
               {"initialize", "ended-session"},
               {"initialize", nil}
             ]
    end
  end

  test "with reconnect: false the client disconnects instead", %{url: url, server: server} do
    client = start_client(url, reconnect: false)
    end_session(server)

    assert {:error, %TransportError{reason: {:session_expired, {:http_error, 404, _body}}}} =
             Client.list_tools(client)

    assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
    assert {:error, :not_connected} = Client.list_tools(client)

    assert_received {:telemetry, [:arbor_mcp, :client, :disconnected], ^client,
                     %{reason: {:session_expired, _detail}}}

    refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], ^client, _meta}
    refute_received {:post, "initialize", _session}
  end

  test "a modern connection has no session, so a 404 leaves it as it was" do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      send(test, {:modern_post, message["method"], session_header(conn)})
      answer_modern(conn, message)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        response_cache: false,
        health_check_interval: nil,
        reconnect: true,
        reconnect_backoff: [initial: 10, max: 10, multiplier: 1]
      )

    on_exit(fn -> stop(client) end)
    assert_receive {:modern_post, "server/discover", nil}

    assert {:error, %ProtocolError{code: -32601, message: "Method not found"}} =
             Client.call_tool(client, "missing", %{}, timeout: 2_000)

    assert_receive {:modern_post, "tools/call", nil}
    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert {:ok, _tools} = Client.list_tools(client, timeout: 2_000)

    refute_received {:modern_post, "server/discover", _session}
    refute_received {:modern_post, _method, <<_session::binary>>}
    refute_received {:telemetry, [:arbor_mcp, :client, :disconnected], ^client, _meta}
    refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], ^client, _meta}
  end

  # An arbor_mcp server's own answer: a DELETE ends the session, and the
  # server answers its next request with 404 "Session not found".
  test "a session an arbor_mcp server ended is replaced by a new one" do
    runtime =
      start_supervised!(
        {Runtime, handler: ServerHandler, transport: :mounted_http, protocol_mode: :legacy_only},
        id: make_ref()
      )

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, runtime: runtime, path: "/mcp", protocol_mode: :legacy_only},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    url = "http://127.0.0.1:#{port}/mcp"

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: url,
        protocol_mode: :legacy_only,
        protocol_version: @version,
        use_sse: false,
        security: %{origin: nil},
        response_cache: false,
        health_check_interval: nil,
        reconnect: true,
        reconnect_backoff: [initial: 10, max: 10, multiplier: 1]
      )

    on_exit(fn -> stop(client) end)
    assert {:ok, _tools} = Client.list_tools(client)
    ended = :sys.get_state(client).transport_state.session_id
    assert is_binary(ended)

    assert {:ok, {{_version, 204, _reason}, _headers, _body}} =
             :httpc.request(
               :delete,
               {String.to_charlist(url),
                [
                  {~c"mcp-session-id", String.to_charlist(ended)},
                  {~c"mcp-protocol-version", String.to_charlist(@version)}
                ]},
               [],
               []
             )

    assert {:error, %TransportError{reason: {:session_expired, {:http_error, 404, body}}}} =
             Client.list_tools(client)

    assert body =~ "Session not found"

    assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], ^client, _meta},
                   2_000

    assert {:ok, _tools} = Client.list_tools(client)
    assert :sys.get_state(client).transport_state.session_id not in [nil, ended]
  end

  defp start_client(url, opts) do
    {:ok, client} = start(url, opts)
    on_exit(fn -> stop(client) end)

    # A test that configures a session checks the handshake itself.
    unless Keyword.has_key?(opts, :session_id) do
      assert_receive {:post, "initialize", nil}
      assert_receive {:post, "notifications/initialized", "session-1"}
    end

    client
  end

  defp start(url, opts) do
    defaults = [
      transport: :http,
      url: url,
      protocol_mode: :legacy_only,
      protocol_version: @version,
      use_sse: false,
      response_cache: false,
      health_check_interval: nil,
      reconnect_backoff: [initial: 10, max: 10, multiplier: 1]
    ]

    Client.start_link(Keyword.merge(defaults, opts))
  end

  defp end_session(server), do: Agent.update(server, &%{&1 | live: nil})
  defp resume(server, session), do: Agent.update(server, &%{&1 | live: session})

  defp live?(server, session),
    do: is_binary(session) and Agent.get(server, & &1.live) == session

  defp session_header(conn),
    do: conn |> Plug.Conn.get_req_header("mcp-session-id") |> List.first()

  defp answer(conn, %{"method" => "initialize", "id" => id} = message, session, server, test) do
    version = get_in(message, ["params", "protocolVersion"])
    send(test, {:initialize, session, version})

    case initialize_session(server, session, version) do
      {:ok, session} ->
        result = %{
          "protocolVersion" => version,
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "session-ending", "version" => "1"}
        }

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", session)
        |> json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

      {:unsupported_version, supported} ->
        error = %{
          "code" => -32_602,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => supported, "requested" => version}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error}))

      :not_found ->
        not_found(conn)

      :unavailable ->
        Plug.Conn.resp(conn, 503, "unavailable")

      :held ->
        Process.flag(:trap_exit, true)
        send(test, {:holding, self()})
        hold_until_released()
        Plug.Conn.resp(conn, 503, "unavailable")
    end
  end

  defp answer(conn, %{"method" => "server/discover", "id" => id}, _session, server, _test) do
    case Agent.get(server, & &1.discover) do
      {:unsupported, supported} ->
        error = %{
          "code" => -32_022,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => supported, "requested" => "2026-07-28"}
        }

        json(conn, %{"jsonrpc" => "2.0", "id" => id, "error" => error})

      nil ->
        not_found(conn)
    end
  end

  defp answer(conn, message, session, server, test) do
    if live?(server, session), do: serve(conn, message, test), else: not_found(conn)
  end

  defp initialize_session(server, nil, version) do
    Agent.get_and_update(server, fn
      %{accepts: accepts} = state when is_list(accepts) ->
        if version in accepts,
          do: open_session(state),
          else: {{:unsupported_version, accepts}, state}

      %{new: :open} = state ->
        open_session(state)

      %{new: refusal} = state ->
        {refusal, state}
    end)
  end

  defp initialize_session(server, session, _version) do
    if live?(server, session), do: {:ok, session}, else: :not_found
  end

  defp open_session(state) do
    generation = state.generation + 1
    session = "session-#{generation}"
    {{:ok, session}, %{state | generation: generation, live: session}}
  end

  # The posts the server has received so far, in order, as {method, session}.
  defp posts(acc \\ []) do
    receive do
      {:post, method, session} -> posts([{method, session} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # tools/call holds until the test releases it, or the client closes its
  # connection, which Cowboy reports to this handler as an exit.
  defp serve(conn, %{"method" => "tools/call", "id" => id}, test) do
    Process.flag(:trap_exit, true)
    send(test, {:holding, self()})
    hold_until_released()
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
  end

  defp serve(conn, %{"method" => "tools/list", "id" => id}, _test),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => []}})

  defp serve(conn, %{"id" => id}, _test),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp serve(conn, _notification, _test), do: Plug.Conn.resp(conn, 202, "")

  defp not_found(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(404, @not_found)
  end

  # The session's GET stream, with a short retry so the client reopens it
  # soon after the test ends it.
  defp hold_stream(conn, session, test) do
    Process.flag(:trap_exit, true)

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "retry: 10\n\n")
    send(test, {:get_opened, session, self()})
    hold_until_released()
    conn
  end

  defp answer_modern(conn, %{"method" => "server/discover", "id" => id}) do
    result = %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "stateless", "version" => "1"}
      }
    }

    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp answer_modern(conn, %{"method" => "tools/list", "id" => id}),
    do:
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "resultType" => "complete",
          "tools" => [],
          "ttlMs" => 0,
          "cacheScope" => "private"
        }
      })

  defp answer_modern(conn, %{"method" => "tools/call", "id" => id}) do
    error = %{"code" => -32_601, "message" => "Method not found"}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(404, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error}))
  end

  defp receive_holding do
    assert_receive {:holding, handler}, 2_000
    handler
  end

  defp hold_until_released do
    receive do
      :release -> :ok
      {:EXIT, _from, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  # A Bypass handler still running when its test ends can make Bypass's
  # on_exit crash (see ReliabilityHTTPTest), so a test waits for the handlers
  # it holds.
  defp await_handlers(handlers) do
    for handler <- handlers do
      ref = Process.monitor(handler)
      assert_receive {:DOWN, ^ref, :process, ^handler, _reason}, 3_000
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
