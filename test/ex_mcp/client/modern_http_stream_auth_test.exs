defmodule ExMCP.Client.ModernHTTPStreamAuthTest do
  @moduledoc """
  A modern request stream that gets a 401 or 403 hands the challenge to the
  client process, which answers the challenges of all its streams one at a
  time: concurrent streams run one refresh (a rotating refresh token is spent
  once) and reuse the token another stream already got, and the provider's
  state is kept whatever the outcome.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.Internal.Headers
  alias ExMCP.Transport.HTTP

  defmodule Provider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid), generation: 0}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(www_auth, scopes, state) do
      send(state.test_pid, {:provider_challenge, www_auth, scopes})
      next = %{state | generation: state.generation + 1}
      {:ok, "request-stream-token", next}
    end

    @impl true
    def handle_forbidden(www_auth, scopes, state) do
      send(state.test_pid, {:provider_step_up, www_auth, scopes})
      next = %{state | generation: state.generation + 1}
      {:ok, "request-stream-step-up-token", next}
    end
  end

  defmodule GuardedProvider do
    @moduledoc false
    # Like the OAuth provider after a rejection: a failed flow records a loop
    # guard in its state, and while the guard is set a 401 is refused without
    # starting the flow (which may open a browser) again.
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid), guard: false}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, %{guard: true} = state),
      do: {:error, :auth_loop_detected, state}

    def handle_unauthorized(_www_auth, _scopes, state) do
      send(state.test_pid, :flow_started)
      {:error, :flow_failed, %{state | guard: true}}
    end

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule RefreshingProvider do
    @moduledoc false
    # Holds an expired token; a 401 refreshes it, spending the one refresh
    # token it has.
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid), token: "stale"}}

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, state) do
      send(state.test_pid, {:refreshed, state.token})
      {:ok, "fresh", %{state | token: "fresh"}}
    end

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule SelfCallingProvider do
    @moduledoc false
    # Calls the client it authenticates, which runs it.
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, _state),
      do: GenServer.call(self(), :list_tools)

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule ToolServer do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_call_tool(_name, _arguments, state), do: {:ok, %{content: []}, state}
  end

  defmodule AuthGate do
    @moduledoc false
    # Lets server/discover, and requests carrying the `:accept` token, through
    # to the MCP plug, and answers every other request with a 401. With a
    # `:barrier`, rejected requests wait until two of them have arrived, so
    # concurrent requests get their 401s together.
    @behaviour Plug

    @impl true
    def init(opts) do
      {gate, mcp_opts} = Keyword.split(opts, [:accept, :barrier])
      {Map.new(gate), ExMCP.HttpPlug.init(mcp_opts)}
    end

    @impl true
    def call(conn, {gate, mcp_opts}) do
      cond do
        Plug.Conn.get_req_header(conn, "mcp-method") == ["server/discover"] ->
          ExMCP.HttpPlug.call(conn, mcp_opts)

        Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{gate[:accept]}"] ->
          ExMCP.HttpPlug.call(conn, mcp_opts)

        true ->
          await_barrier(gate[:barrier])

          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.send_resp(401, "")
      end
    end

    defp await_barrier(nil), do: :ok

    defp await_barrier(barrier) do
      waiting = Agent.get_and_update(barrier, fn pids -> {[self() | pids], [self() | pids]} end)
      if length(waiting) >= 2, do: Enum.each(waiting, &send(&1, :release))

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  defp start_gated_server(gate_opts) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    ranch_ref = {__MODULE__, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        AuthGate,
        gate_opts ++
          [
            handler: ToolServer,
            path: "/mcp",
            protocol_mode: :modern_only,
            allowed_origins: ["http://127.0.0.1:#{port}"]
          ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ranch_ref) end)
    port
  end

  defp start_modern_client(port, auth_provider) do
    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        use_sse: false,
        auth_provider: auth_provider,
        health_check_interval: nil,
        reconnect: false
      )

    client
  end

  defp client_state(transport_state) do
    %Client{
      transport_mod: HTTP,
      transport_state: transport_state,
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{}
    }
  end

  # The test is the stream's parent, so it hands each auth challenge to the
  # client's handler, as ExMCP.Client does.
  defp answer_challenge(stream_pid, request_id, client_state) do
    assert_receive {:modern_http_stream_auth_challenge, ^stream_pid, ^request_id, _ref,
                    _challenge} = message,
                   1_000

    assert {:noreply, client_state} = Client.handle_info(message, client_state)
    client_state
  end

  test "a request stream's failed authentication keeps the provider's loop guard" do
    port = start_gated_server([])
    client = start_modern_client(port, {GuardedProvider, test_pid: self()})

    # A progress token makes each call its own request stream.
    for token <- ["guarded-1", "guarded-2"] do
      assert {:error, _reason} =
               Client.call_tool(client, "anything", %{}, progress_token: token, timeout: 5_000)
    end

    assert_received :flow_started
    refute_received :flow_started

    Client.stop(client)
  end

  test "concurrent request streams rejected together refresh the token once" do
    barrier = start_supervised!({Agent, fn -> [] end})
    port = start_gated_server(accept: "fresh", barrier: barrier)
    client = start_modern_client(port, {RefreshingProvider, test_pid: self()})

    tasks =
      for token <- ["race-1", "race-2"] do
        Task.async(fn ->
          Client.call_tool(client, "anything", %{}, progress_token: token, timeout: 5_000)
        end)
      end

    assert [{:ok, _first}, {:ok, _second}] = Task.await_many(tasks, 6_000)
    assert Agent.get(barrier, &length/1) == 2

    assert_received {:refreshed, "stale"}
    refute_received {:refreshed, _token}

    Client.stop(client)
  end

  test "a modern POST-owned request stream reauthenticates and persists provider state" do
    bypass = Bypass.open()
    attempts = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      attempt = Agent.get_and_update(attempts, fn current -> {current + 1, current + 1} end)

      case attempt do
        1 ->
          assert Plug.Conn.get_req_header(conn, "authorization") == []

          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer realm="mcp", scope="tools.read tools.call")
          )
          |> Plug.Conn.resp(401, "authentication required")

        2 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-token"]

          body =
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => 42,
                "result" => %{"resultType" => "complete", "content" => []}
              }) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    {:ok, transport_state} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_version: "2026-07-28",
        auth_provider: {Provider, test_pid: self()},
        stream_idle_timeout: 2_000
      )

    transport_state = HTTP.settle_protocol_era(transport_state, :modern, "2026-07-28")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/call"})

    assert {:ok, transport_state} = HTTP.open_stream(request, transport_state, self())
    stream_pid = Map.fetch!(transport_state.modern_streams, 42)

    client_state = answer_challenge(stream_pid, 42, client_state(transport_state))

    assert_received {:provider_challenge, ~s(Bearer realm="mcp", scope="tools.read tools.call"),
                     ["tools.read", "tools.call"]}

    assert client_state.transport_state.access_token == "request-stream-token"
    assert client_state.transport_state.auth_provider_state.generation == 1

    assert Headers.get(client_state.transport_state.headers, "authorization") ==
             "Bearer request-stream-token"

    assert_receive {:modern_http_stream_message, ^stream_pid, 42,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => 42,
                      "result" => %{"resultType" => "complete", "content" => []}
                    }},
                   1_000

    send(stream_pid, {:modern_http_stream_ack, self(), 42})
    assert_receive {:modern_http_stream_finished, ^stream_pid, 42}, 1_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "a request stream performs one bounded insufficient-scope step-up" do
    bypass = Bypass.open()
    attempts = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      attempt = Agent.get_and_update(attempts, fn current -> {current + 1, current + 1} end)

      case attempt do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer scope="tools.call"))
          |> Plug.Conn.resp(401, "authentication required")

        2 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-token"]

          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer error="insufficient_scope", scope="admin")
          )
          |> Plug.Conn.resp(403, "more scope required")

        3 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-step-up-token"]

          body =
            "data: " <>
              Jason.encode!(%{"jsonrpc" => "2.0", "id" => 84, "result" => %{}}) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    {:ok, transport_state} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_version: "2026-07-28",
        auth_provider: {Provider, test_pid: self()},
        stream_idle_timeout: 2_000
      )

    transport_state = HTTP.settle_protocol_era(transport_state, :modern, "2026-07-28")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 84, "method" => "tools/call"})

    assert {:ok, transport_state} = HTTP.open_stream(request, transport_state, self())
    stream_pid = Map.fetch!(transport_state.modern_streams, 84)

    client_state = answer_challenge(stream_pid, 84, client_state(transport_state))
    assert_received {:provider_challenge, ~s(Bearer scope="tools.call"), ["tools.call"]}
    assert client_state.transport_state.access_token == "request-stream-token"

    client_state = answer_challenge(stream_pid, 84, client_state)

    assert_received {:provider_step_up, ~s(Bearer error="insufficient_scope", scope="admin"),
                     ["admin"]}

    assert client_state.transport_state.access_token == "request-stream-step-up-token"
    assert client_state.transport_state.auth_provider_state.generation == 2

    assert_receive {:modern_http_stream_message, ^stream_pid, 84,
                    %{"jsonrpc" => "2.0", "id" => 84, "result" => %{}}},
                   1_000

    send(stream_pid, {:modern_http_stream_ack, self(), 84})
    assert_receive {:modern_http_stream_finished, ^stream_pid, 84}, 1_000
    assert Agent.get(attempts, & &1) == 3
  end

  test "a stale stream's challenge neither runs the provider nor changes the transport" do
    active_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn -> Process.exit(active_pid, :kill) end)

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer current"}],
      access_token: "current",
      auth_provider: Provider,
      auth_provider_state: %{test_pid: self(), generation: 2},
      modern_streams: %{42 => active_pid}
    }

    ref = make_ref()
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: "current"}

    assert {:noreply, unchanged} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, self(), 42, ref, challenge},
               client_state(transport_state)
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:error, :stream_retired}}
    refute_received {:provider_challenge, _, _}
    assert unchanged.transport_state.access_token == "current"
    assert unchanged.transport_state.auth_provider_state.generation == 2
  end

  test "a 403 reuses a newer token only if it was granted the challenged scopes" do
    stream_pid = self()

    for {granted, reused?} <- [{["tools.read"], false}, {["tools.read", "admin"], true}] do
      transport_state = %HTTP{
        headers: [{"Authorization", "Bearer fresh"}],
        access_token: "fresh",
        auth_provider: Provider,
        auth_provider_state: %{test_pid: self(), generation: 1, granted_scopes: granted},
        modern_streams: %{7 => stream_pid}
      }

      ref = make_ref()
      challenge = %{status: 403, www_authenticate: "Bearer", scopes: ["admin"], token: "old"}

      assert {:noreply, _client_state} =
               Client.handle_info(
                 {:modern_http_stream_auth_challenge, stream_pid, 7, ref, challenge},
                 client_state(transport_state)
               )

      if reused? do
        assert_received {:modern_http_stream_auth_result, ^ref, {:ok, "fresh"}}
        refute_received {:provider_step_up, _, _}
      else
        assert_received {:provider_step_up, "Bearer", ["admin"]}

        assert_received {:modern_http_stream_auth_result, ^ref,
                         {:ok, "request-stream-step-up-token"}}
      end
    end
  end

  test "a challenge for a token another stream already replaced reuses the new token" do
    stream_pid = self()

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer fresh"}],
      access_token: "fresh",
      auth_provider: Provider,
      auth_provider_state: %{test_pid: self(), generation: 1},
      modern_streams: %{7 => stream_pid}
    }

    ref = make_ref()
    # Sent with the token the first stream's 401 already replaced.
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: "expired"}

    assert {:noreply, client_state} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, stream_pid, 7, ref, challenge},
               client_state(transport_state)
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:ok, "fresh"}}
    refute_received {:provider_challenge, _, _}
    assert client_state.transport_state.auth_provider_state.generation == 1
  end

  test "a challenge reaching a client without the stream's connection is refused" do
    ref = make_ref()
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: nil}
    state = %{client_state(nil) | transport_mod: nil}

    assert {:noreply, ^state} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, self(), 7, ref, challenge},
               state
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:error, :stream_retired}}
  end

  test "a stream waits for its challenge's answer only until its request's deadline" do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
      |> Plug.Conn.resp(401, "")
    end)

    {:ok, transport_state} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_version: "2026-07-28",
        auth_provider: {Provider, test_pid: self()}
      )

    transport_state = HTTP.settle_protocol_era(transport_state, :modern, "2026-07-28")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 51, "method" => "tools/call"})
    deadline = System.monotonic_time(:millisecond) + 300

    assert {:ok, transport_state} =
             HTTP.open_stream(request, transport_state, self(), deadline: deadline)

    stream_pid = Map.fetch!(transport_state.modern_streams, 51)

    # The client is busy and never answers; the request's deadline ends the
    # wait instead of the 10 minute bound.
    assert_receive {:modern_http_stream_auth_challenge, ^stream_pid, 51, _ref, challenge}, 2_000

    assert_receive {:modern_http_stream_closed, ^stream_pid, 51,
                    {:authentication_failed, :timeout}},
                   2_000

    # The client sees the deadline too, and refuses a challenge past it.
    assert challenge.deadline == deadline
  end

  test "a challenge whose request is past its deadline runs no provider" do
    stream_pid = self()

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer old"}],
      access_token: "old",
      auth_provider: Provider,
      auth_provider_state: %{test_pid: self(), generation: 1},
      modern_streams: %{7 => stream_pid}
    }

    ref = make_ref()
    past = System.monotonic_time(:millisecond) - 1

    challenge = %{
      status: 401,
      www_authenticate: "Bearer",
      scopes: [],
      token: "old",
      deadline: past
    }

    assert {:noreply, client_state} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, stream_pid, 7, ref, challenge},
               client_state(transport_state)
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:error, :timeout}}
    refute_received {:provider_challenge, _, _}
    assert client_state.transport_state.auth_provider_state.generation == 1
  end

  test "a provider that calls the client it authenticates gets an error, not a client crash" do
    stream_pid = self()

    transport_state = %HTTP{
      headers: [],
      auth_provider: SelfCallingProvider,
      auth_provider_state: %{},
      modern_streams: %{7 => stream_pid}
    }

    ref = make_ref()
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: nil}

    # The test runs the handler, so it is the client the provider calls.
    capture = fn ->
      assert {:noreply, _client_state} =
               Client.handle_info(
                 {:modern_http_stream_auth_challenge, stream_pid, 7, ref, challenge},
                 client_state(transport_state)
               )
    end

    assert ExUnit.CaptureLog.capture_log(capture) =~ "called the client it authenticates"

    assert_received {:modern_http_stream_auth_result, ^ref,
                     {:error, :auth_provider_called_client}}
  end
end
