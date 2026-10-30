defmodule ExMCP.Client.HTTPAuthRetirementTest do
  use ExUnit.Case, async: false

  alias ExMCP.Client

  @moduletag :capture_log

  defmodule GatedProvider do
    @moduledoc false
    @behaviour ExMCP.Authorization.Provider

    def init(config), do: {:ok, %{owner: Keyword.fetch!(config, :owner)}}
    def get_token(state), do: {:ok, nil, state}

    def handle_unauthorized(_www, _scopes, state) do
      send(state.owner, {:auth_waiting, self()})

      receive do
        :release_auth -> {:ok, "fresh", state}
      after
        5_000 -> {:error, :test_auth_not_released, state}
      end
    end

    def handle_forbidden(www, scopes, state),
      do: handle_unauthorized(www, scopes, state)
  end

  for auth <- [:provider, :inline], cancellation <- [:client, :server] do
    test "#{cancellation} cancellation stops an already-approved #{auth} auth retry" do
      owner = self()
      attempts = start_supervised!({Agent, fn -> 0 end})
      bypass = Bypass.open()
      url = "http://127.0.0.1:#{bypass.port}/mcp"
      stub_mcp(bypass, attempts, owner)
      auth_opts = auth_options(unquote(auth), bypass, owner)

      {:ok, client} =
        Client.start_link(
          [
            transport: :http,
            url: url,
            use_sse: true,
            protocol_mode: :legacy_only,
            health_check_interval: nil,
            reconnect: false
          ] ++ auth_opts
        )

      on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

      call =
        Task.async(fn ->
          Client.call_tool(client, "retirement", %{}, timeout: 10_000, retry_policy: false)
        end)

      assert_receive {:initial_post, request_id, handler}, 2_000

      post =
        Enum.find_value(:sys.get_state(client).async_post_tasks, fn
          {_ref, {pid, ^request_id}} -> pid
          _other -> nil
        end)

      assert is_pid(post)
      monitor = Process.monitor(post)
      on_exit(fn -> resume_if_alive(post) end)

      send(handler, :answer_401)
      assert_receive {:auth_waiting, auth_gate}, 2_000
      assert :erlang.suspend_process(post)

      # The client issues its auth reply before it can handle cancellation.
      # Keep the POST worker suspended so that reply is still in its mailbox.
      send(auth_gate, :release_auth)
      cancel(unquote(cancellation), client, request_id)
      assert {:error, :cancelled} = Task.await(call, 2_000)

      # The reply can reach the caller before the client's cancellation
      # handler returns. Finish that handler before releasing the worker.
      _state = :sys.get_state(client)

      resume_if_alive(post)
      assert_receive {:DOWN, ^monitor, :process, ^post, _reason}, 5_000
      assert Agent.get(attempts, & &1) == 1
    end
  end

  defp cancel(:client, client, request_id),
    do: assert(:ok = Client.send_cancelled(client, request_id, "finished"))

  defp cancel(:server, client, request_id) do
    send(
      client,
      {:transport_event,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "notifications/cancelled",
         "params" => %{"requestId" => request_id, "reason" => "finished"}
       })}
    )
  end

  defp resume_if_alive(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp auth_options(:provider, _bypass, owner),
    do: [auth_provider: {GatedProvider, owner: owner}]

  defp auth_options(:inline, bypass, owner) do
    base = "http://127.0.0.1:#{bypass.port}"

    for path <- ["/.well-known/oauth-protected-resource/mcp", "/.well-known/openid-configuration"] do
      Bypass.stub(bypass, "GET", path, &Plug.Conn.resp(&1, 404, ""))
    end

    Bypass.stub(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      json(conn, %{"resource" => base <> "/mcp", "authorization_servers" => [base]})
    end)

    Bypass.stub(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      json(conn, %{
        "issuer" => base,
        "authorization_endpoint" => base <> "/authorize",
        "token_endpoint" => base <> "/token",
        "grant_types_supported" => ["client_credentials"],
        "token_endpoint_auth_methods_supported" => ["client_secret_post"]
      })
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      send(owner, {:auth_waiting, self()})

      receive do
        :release_auth ->
          json(conn, %{"access_token" => "fresh", "token_type" => "Bearer", "expires_in" => 3600})
      after
        5_000 -> Plug.Conn.resp(conn, 500, "test auth not released")
      end
    end)

    [
      auth_provider: :none,
      auth: %{
        client_id: "test-client",
        client_secret: "test-secret",
        metadata_fetch: [allow_insecure_loopback: true]
      }
    ]
  end

  defp stub_mcp(bypass, attempts, owner) do
    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "retirement-session")
          |> json(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "retirement", "version" => "1"}
            }
          })

        %{"method" => "tools/call", "id" => id} ->
          Agent.update(attempts, &(&1 + 1))

          if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
            json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
          else
            send(owner, {:initial_post, id, self()})

            receive do
              :answer_401 ->
                conn
                |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
                |> Plug.Conn.resp(401, "")
            after
              5_000 -> Plug.Conn.resp(conn, 500, "test POST not released")
            end
          end

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
