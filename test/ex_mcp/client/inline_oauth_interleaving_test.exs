defmodule ExMCP.Client.InlineOAuthInterleavingTest do
  @moduledoc """
  Tests for concurrent no-provider POSTs performing inline OAuth discovery.
  Verifies that 401 and 403 challenges are handed back to the client process,
  running exactly one OAuth flow across concurrent requests, reusing the newest
  token, and handling concurrent 403 scope step-ups cleanly.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client

  defp setup_oauth_bypass(bypass, token_agent) do
    Bypass.stub(
      bypass,
      "GET",
      "/.well-known/oauth-protected-resource/mcp",
      &Plug.Conn.resp(&1, 404, "")
    )

    Bypass.stub(
      bypass,
      "GET",
      "/.well-known/openid-configuration",
      &Plug.Conn.resp(&1, 404, "")
    )

    Bypass.stub(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "resource" => "http://127.0.0.1:#{bypass.port}/mcp",
          "authorization_servers" => ["http://127.0.0.1:#{bypass.port}"]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "issuer" => "http://127.0.0.1:#{bypass.port}",
          "authorization_endpoint" => "http://127.0.0.1:#{bypass.port}/authorize",
          "token_endpoint" => "http://127.0.0.1:#{bypass.port}/token",
          "grant_types_supported" => ["client_credentials"],
          "token_endpoint_auth_methods_supported" => ["client_secret_post"]
        })
      )
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      scope = params["scope"] || ""

      token_info =
        Agent.get_and_update(token_agent, fn state ->
          case state do
            fun when is_function(fun, 1) ->
              fun.(scope)

            %{tokens: [next | rest], count: c} ->
              {{next, scope}, %{state | tokens: rest, count: c + 1}}

            %{count: c} ->
              {{"fallback_token_#{c + 1}", scope}, %{state | count: c + 1}}
          end
        end)

      {token, granted_scope} =
        case token_info do
          {tok, sc} -> {tok, sc}
          tok when is_binary(tok) -> {tok, scope}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "scope" => granted_scope
        })
      )
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)
    end)
  end

  defp start_client(bypass) do
    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: true,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        reconnect: false,
        auth_provider: :none,
        auth: %{
          client_id: "auto-client",
          client_secret: "secret",
          metadata_fetch: [allow_insecure_loopback: true]
        }
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.stop(client)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  test "three concurrent 401s (no provider, inline OAuth) run exactly one OAuth flow, and every request retries with newest token" do
    bypass = Bypass.open()
    tokens = start_supervised!({Agent, fn -> %{count: 0} end})
    setup_oauth_bypass(bypass, tokens)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      case payload do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "test-session")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "test", "version" => "1"}
              }
            })
          )

        %{"method" => "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        %{"params" => %{"name" => name}, "id" => id} ->
          case Plug.Conn.get_req_header(conn, "authorization") do
            ["Bearer fallback_token_1"] ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(
                200,
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{"content" => [%{"type" => "text", "text" => "#{name}_done"}]}
                })
              )

            _other ->
              conn
              |> Plug.Conn.put_resp_header(
                "www-authenticate",
                ~s(Bearer realm="mcp", scope="tools:call")
              )
              |> Plug.Conn.resp(401, "")
          end
      end
    end)

    client = start_client(bypass)

    # Launch 3 concurrent requests. None have a token initially.
    tasks =
      for name <- ["tool_1", "tool_2", "tool_3"] do
        Task.async(fn ->
          Client.call_tool(client, name, %{}, timeout: 10_000)
        end)
      end

    results = Task.await_many(tasks, 10_000)

    # All 3 requests succeed
    for {res, name} <- Enum.zip(results, ["tool_1", "tool_2", "tool_3"]) do
      expected_text = "#{name}_done"
      assert {:ok, call_res} = res
      assert [%{text: ^expected_text}] = call_res.content
    end

    # Exactly ONE OAuth flow was executed across all concurrent requests!
    assert Agent.get(tokens, & &1.count) == 1
    assert :sys.get_state(client).transport_state.access_token == "fallback_token_1"

    # Subsequent request uses the token without re-authenticating
    assert {:ok, res_4} = Client.call_tool(client, "tool_4", %{}, timeout: 5_000)
    assert [%{text: "tool_4_done"}] = res_4.content
    assert Agent.get(tokens, & &1.count) == 1
  end

  test "a 403 step-up that arrives while another flow is running runs step-up and updates client with required scope" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(
      bypass,
      "GET",
      "/.well-known/oauth-protected-resource/mcp",
      &Plug.Conn.resp(&1, 404, "")
    )

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", &Plug.Conn.resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "resource" => "http://127.0.0.1:#{bypass.port}/mcp",
          "authorization_servers" => ["http://127.0.0.1:#{bypass.port}"]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "issuer" => "http://127.0.0.1:#{bypass.port}",
          "authorization_endpoint" => "http://127.0.0.1:#{bypass.port}/authorize",
          "token_endpoint" => "http://127.0.0.1:#{bypass.port}/token",
          "grant_types_supported" => ["client_credentials"],
          "token_endpoint_auth_methods_supported" => ["client_secret_post"]
        })
      )
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      scope = params["scope"] || ""

      if String.contains?(scope, "tools:admin") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "token_admin",
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "scope" => "tools:basic tools:admin"
          })
        )
      else
        send(test_pid, {:first_flow_in_token, self()})

        receive do
          :continue_first_flow -> :ok
        after
          5_000 -> :ok
        end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "token_basic",
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "scope" => "tools:basic"
          })
        )
      end
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      case payload do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "test-session")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "test", "version" => "1"}
              }
            })
          )

        %{"method" => "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        %{"params" => %{"name" => name}, "id" => id} ->
          auth = Plug.Conn.get_req_header(conn, "authorization")

          case name do
            "tool_basic" ->
              if auth in [["Bearer token_basic"], ["Bearer token_admin"]] do
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.resp(
                  200,
                  Jason.encode!(%{
                    "jsonrpc" => "2.0",
                    "id" => id,
                    "result" => %{"content" => [%{"type" => "text", "text" => "basic_done"}]}
                  })
                )
              else
                conn
                |> Plug.Conn.put_resp_header(
                  "www-authenticate",
                  ~s(Bearer realm="mcp", scope="tools:basic")
                )
                |> Plug.Conn.resp(401, "")
              end

            "tool_admin" ->
              if auth == ["Bearer token_admin"] do
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.resp(
                  200,
                  Jason.encode!(%{
                    "jsonrpc" => "2.0",
                    "id" => id,
                    "result" => %{"content" => [%{"type" => "text", "text" => "admin_done"}]}
                  })
                )
              else
                conn
                |> Plug.Conn.put_resp_header(
                  "www-authenticate",
                  ~s(Bearer error="insufficient_scope", scope="tools:admin")
                )
                |> Plug.Conn.resp(403, "")
              end
          end
      end
    end)

    client = start_client(bypass)

    # Start tool_basic: hits 401, triggers first OAuth flow which stalls in /token
    task_basic =
      Task.async(fn -> Client.call_tool(client, "tool_basic", %{}, timeout: 10_000) end)

    assert_receive {:first_flow_in_token, token_pid}, 5_000

    # While first flow is running, start tool_admin: hits 403 (insufficient_scope)
    # The 403 challenge queues in client process while first flow is running
    task_admin =
      Task.async(fn -> Client.call_tool(client, "tool_admin", %{}, timeout: 10_000) end)

    # Allow first flow to complete
    send(token_pid, :continue_first_flow)

    assert {:ok, res_basic} = Task.await(task_basic, 5_000)
    assert [%{text: "basic_done"}] = res_basic.content

    # The 403 step-up is processed next, obtains token_admin, and completes
    assert {:ok, res_admin} = Task.await(task_admin, 5_000)
    assert [%{text: "admin_done"}] = res_admin.content

    assert :sys.get_state(client).transport_state.access_token == "token_admin"
  end
end
