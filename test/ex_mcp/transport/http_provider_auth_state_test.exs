defmodule ExMCP.Transport.HTTPProviderAuthStateTest do
  @moduledoc """
  How the HTTP transport hands an auth provider's outcome back to its caller.

  A provider that fails returns `{:error, reason, provider_state}`, and the
  state records what it tried (the OAuth provider's loop guards). The
  transport keeps that state, but its callers still see the error shapes they
  always did: `{:error, reason}` from `send_message/2`, and the usual error
  from `ExMCP.Client`.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Transport.HTTP

  defmodule FailingProvider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{tried: 0}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, state),
      do: {:error, :flow_failed, %{state | tried: state.tried + 1}}

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule RotatingProvider do
    @moduledoc false
    # Every token it hands out spends the refresh token it holds and keeps the
    # next one, as a refresh with rotating refresh tokens does. A spent
    # refresh token used again would fail with invalid_grant.
    @behaviour ExMCP.Authorization.Provider

    @impl true
    def init(config),
      do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid), refresh_token: 0}}

    @impl true
    def get_token(state), do: rotate(state)

    @impl true
    def handle_unauthorized(_www_auth, _scopes, state), do: rotate(state)

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}

    defp rotate(%{refresh_token: spent} = state) do
      send(state.test_pid, {:spent, spent})
      {:ok, "access-#{spent + 1}", %{state | refresh_token: spent + 1}}
    end
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

  defp reject_every_post(bypass) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
      |> Plug.Conn.resp(401, "")
    end)
  end

  defp client_state(transport_state, overrides) do
    struct!(
      %Client{
        transport_mod: HTTP,
        transport_state: transport_state,
        pending_requests: %{},
        pending_batches: %{},
        cancelled_requests: MapSet.new(),
        async_post_tasks: %{},
        protocol_version: "2025-11-25"
      },
      overrides
    )
  end

  describe "a failed authentication" do
    for use_sse <- [false, true] do
      test "on the first request fails start_link as before (use_sse: #{use_sse})" do
        bypass = Bypass.open()
        reject_every_post(bypass)
        Process.flag(:trap_exit, true)

        assert {:error, {:transport_connect_failed, "flow_failed"}} =
                 Client.start_link(
                   transport: :http,
                   url: "http://127.0.0.1:#{bypass.port}/mcp",
                   use_sse: unquote(use_sse),
                   auth_provider: {FailingProvider, []},
                   protocol_mode: :legacy_only,
                   reconnect: false,
                   health_check_interval: nil
                 )
      end
    end

    test "returns {:error, reason} from send_message/2" do
      bypass = Bypass.open()
      reject_every_post(bypass)

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          auth_provider: {FailingProvider, []}
        )

      request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      assert {:error, :flow_failed} = HTTP.send_message(request, transport)
    end

    test "in an async POST answers the caller and keeps the provider's state" do
      bypass = Bypass.open()
      reject_every_post(bypass)

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: true,
          auth_provider: {FailingProvider, []}
        )

      # An open SSE stream makes the transport POST from a task.
      transport = %{transport | sse_pid: self()}
      request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"})

      assert {:ok, _transport} = HTTP.send_message(request, transport)
      assert_receive {:async_post_task, task_ref, 7}
      assert_receive {:async_post_result, result, meta}, 5_000

      assert result == {:error, :flow_failed}
      assert meta.state_changes.auth_provider_state == %{tried: 1}

      reply_tag = make_ref()

      state =
        client_state(transport,
          pending_requests: %{7 => {{self(), reply_tag}, :single, "tools/list"}},
          async_post_tasks: %{task_ref => 7}
        )

      assert {:noreply, state} = Client.handle_info({:async_post_result, result, meta}, state)
      assert_received {^reply_tag, {:error, {:transport_error, :flow_failed}}}
      assert state.pending_requests == %{}
      assert state.transport_state.auth_provider_state == %{tried: 1}
    end
  end

  describe "a provider's refreshed token" do
    # A legacy server whose tools/list answers come from `script`, in order.
    defp scripted_server(bypass, script) do
      script = start_supervised!({Agent, fn -> script end})

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(body) do
          %{"method" => "initialize", "id" => id} ->
            json(conn, 200, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "rotating", "version" => "1.0.0"}
              }
            })

          %{"method" => "tools/list", "id" => id} ->
            case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
              :ok ->
                json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => []}})

              :unauthorized ->
                conn
                |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
                |> Plug.Conn.resp(401, "")

              :server_error ->
                Plug.Conn.resp(conn, 500, "unavailable")
            end

          _notification ->
            Plug.Conn.resp(conn, 202, "")
        end
      end)
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    test "is kept by the client after every request, failed ones too" do
      bypass = Bypass.open()
      # A failure after a refresh before the request, then a failed retry
      # after a refresh on a 401, then a success.
      scripted_server(bypass, [:server_error, :unauthorized, :server_error, :ok])

      {:ok, client} =
        Client.start_link(
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          auth_provider: {RotatingProvider, test_pid: self()},
          protocol_mode: :legacy_only,
          reconnect: false,
          health_check_interval: nil
        )

      # initialize, then notifications/initialized
      assert_received {:spent, 0}
      assert_received {:spent, 1}

      assert {:error, _reason} = Client.list_tools(client, format: :map)
      assert_received {:spent, 2}

      assert {:error, _reason} = Client.list_tools(client, format: :map)
      # The token for the request, then the refresh after its 401
      assert_received {:spent, 3}
      assert_received {:spent, 4}

      assert {:ok, %{"tools" => []}} = Client.list_tools(client, format: :map)
      assert_received {:spent, 5}
      refute_received {:spent, _}

      Client.stop(client)
    end

    test "for an async POST is resolved by the caller, which keeps it" do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})

        json(conn, 200, %{"jsonrpc" => "2.0", "id" => 9, "result" => %{"tools" => []}})
      end)

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: true,
          auth_provider: {RotatingProvider, test_pid: self()}
        )

      transport = %{transport | sse_pid: self()}
      request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"})

      assert {:ok, transport} = HTTP.send_message(request, transport)
      assert_received {:spent, 0}
      assert transport.auth_provider_state.refresh_token == 1

      assert_receive {:async_post_result, result, meta}, 5_000
      assert elem(result, 0) == :ok
      assert_received {:authorization, ["Bearer access-1"]}
      # The task used the token it was given and refreshed nothing itself.
      refute Map.has_key?(meta.state_changes, :auth_provider_state)
      refute_received {:spent, _}
    end
  end

  describe "concurrent async POSTs rejected together" do
    test "run one refresh, answered by the client one challenge at a time" do
      bypass = Bypass.open()
      barrier = start_supervised!({Agent, fn -> [] end})

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"id" => id} = Jason.decode!(body)

        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => []}})
        else
          # Both POSTs get their 401 together.
          waiting = Agent.get_and_update(barrier, &{[self() | &1], [self() | &1]})
          if length(waiting) == 2, do: Enum.each(waiting, &send(&1, :release))

          receive do
            :release -> :ok
          after
            2_000 -> :ok
          end

          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        end
      end)

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: true,
          auth_provider: {RefreshingProvider, test_pid: self()}
        )

      # The test plays the client process: it gets the tasks' messages and
      # hands them to ExMCP.Client.handle_info/2.
      Process.put({ExMCP.Client, :client}, true)
      transport = %{transport | sse_pid: self()}

      transport =
        Enum.reduce([1, 2], transport, fn id, transport ->
          request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"})
          assert {:ok, transport} = HTTP.send_message(request, transport)
          transport
        end)

      assert_receive {:async_post_task, ref_1, 1}
      assert_receive {:async_post_task, ref_2, 2}
      state = client_state(transport, async_post_tasks: %{ref_1 => 1, ref_2 => 2})

      state =
        Enum.reduce(1..2, state, fn _challenge, state ->
          assert_receive {:http_post_auth_challenge, _task, _id, _ref, %{token: "stale"}} =
                           challenge,
                         5_000

          assert {:noreply, state} = Client.handle_info(challenge, state)
          state
        end)

      assert state.transport_state.access_token == "fresh"
      assert_received {:refreshed, "stale"}
      refute_received {:refreshed, _token}

      for id <- [1, 2] do
        assert_receive {:async_post_result, {:ok, _transport, _data}, %{request_id: ^id} = meta},
                       5_000

        # The token the client handed out stays the client's to change.
        refute Map.has_key?(meta.state_changes, :access_token)
      end
    end
  end
end
