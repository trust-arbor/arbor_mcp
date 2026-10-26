defmodule ExMCP.Client.ModernHTTPStreamAuthTest do
  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.Internal.Headers
  alias ExMCP.Transport.HTTP

  defmodule Provider do
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
    # Lets server/discover through to the MCP plug and answers every other
    # request with a 401.
    @behaviour Plug

    @impl true
    def init(opts), do: ExMCP.HttpPlug.init(opts)

    @impl true
    def call(conn, mcp_opts) do
      if Plug.Conn.get_req_header(conn, "mcp-method") == ["server/discover"] do
        ExMCP.HttpPlug.call(conn, mcp_opts)
      else
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.send_resp(401, "")
      end
    end
  end

  test "a request stream's failed authentication keeps the provider's loop guard" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    ranch_ref = {__MODULE__, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        AuthGate,
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

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        use_sse: false,
        auth_provider: {GuardedProvider, test_pid: self()},
        health_check_interval: nil,
        reconnect: false
      )

    # A progress token makes each call its own request stream.
    for token <- ["guarded-1", "guarded-2"] do
      assert {:error, _reason} =
               Client.call_tool(client, "anything", %{}, progress_token: token, timeout: 5_000)
    end

    assert_received :flow_started
    refute_received :flow_started

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

    assert_receive {:provider_challenge, ~s(Bearer realm="mcp", scope="tools.read tools.call"),
                    ["tools.read", "tools.call"]},
                   1_000

    assert_receive {:modern_http_stream_auth_updated, ^stream_pid, 42, changes}, 1_000

    client_state = %Client{
      transport_mod: HTTP,
      transport_state: transport_state,
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{}
    }

    assert {:noreply, client_state} =
             Client.handle_info(
               {:modern_http_stream_auth_updated, stream_pid, 42, changes},
               client_state
             )

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

    assert_receive {:provider_challenge, ~s(Bearer scope="tools.call"), ["tools.call"]}, 1_000

    assert_receive {:modern_http_stream_auth_updated, ^stream_pid, 84,
                    %{access_token: "request-stream-token"}},
                   1_000

    assert_receive {:provider_step_up, ~s(Bearer error="insufficient_scope", scope="admin"),
                    ["admin"]},
                   1_000

    assert_receive {:modern_http_stream_auth_updated, ^stream_pid, 84,
                    %{
                      access_token: "request-stream-step-up-token",
                      auth_provider_state: %{generation: 2}
                    }},
                   1_000

    assert_receive {:modern_http_stream_message, ^stream_pid, 84,
                    %{"jsonrpc" => "2.0", "id" => 84, "result" => %{}}},
                   1_000

    send(stream_pid, {:modern_http_stream_ack, self(), 84})
    assert_receive {:modern_http_stream_finished, ^stream_pid, 84}, 1_000
    assert Agent.get(attempts, & &1) == 3
  end

  test "auth updates from a stale stream cannot overwrite the active transport" do
    active_pid = spawn(fn -> Process.sleep(:infinity) end)
    stale_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(active_pid, :kill)
      Process.exit(stale_pid, :kill)
    end)

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer current"}],
      access_token: "current",
      auth_provider_state: %{generation: 2},
      modern_streams: %{42 => active_pid}
    }

    client_state = %Client{
      transport_mod: HTTP,
      transport_state: transport_state,
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{}
    }

    assert {:noreply, unchanged} =
             Client.handle_info(
               {:modern_http_stream_auth_updated, stale_pid, 42,
                %{access_token: "stale", auth_provider_state: %{generation: 1}}},
               client_state
             )

    assert unchanged.transport_state.access_token == "current"
    assert unchanged.transport_state.auth_provider_state == %{generation: 2}
  end
end
