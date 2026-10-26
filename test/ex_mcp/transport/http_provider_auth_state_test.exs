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
end
