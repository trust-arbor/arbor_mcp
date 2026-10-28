defmodule ExMCP.Client.InlineOAuthInterleavingTest do
  @moduledoc """
  Tests for concurrent no-provider POSTs performing inline OAuth discovery.
  Verifies that credential versions are allocated monotonically by the client process,
  preventing misordering, discarding of newer tokens, and clobbering by delayed older results.
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
      token =
        Agent.get_and_update(token_agent, fn tokens ->
          case tokens do
            [next | rest] -> {next, rest}
            [] -> {"fallback_token", []}
          end
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => 3600
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
        if Process.alive?(client), do: Process.exit(client, :kill)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  test "interleaving 1: A's 401 then 403 commits T2/v2, then B obtains newer T3 as v3 without discarding T3" do
    bypass = Bypass.open()
    tokens = start_supervised!({Agent, fn -> ["T1", "T2", "T3"] end})
    setup_oauth_bypass(bypass, tokens)
    test_pid = self()

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
          case name do
            "tool_a" ->
              case Plug.Conn.get_req_header(conn, "authorization") do
                [] ->
                  conn
                  |> Plug.Conn.put_resp_header(
                    "www-authenticate",
                    ~s(Bearer realm="mcp", scope="tools:a_initial")
                  )
                  |> Plug.Conn.resp(401, "")

                ["Bearer T1"] ->
                  # 403 scope step-up required
                  conn
                  |> Plug.Conn.put_resp_header(
                    "www-authenticate",
                    ~s(Bearer error="insufficient_scope", scope="tools:a_stepped_up")
                  )
                  |> Plug.Conn.resp(403, "")

                ["Bearer T2"] ->
                  conn
                  |> Plug.Conn.put_resp_content_type("application/json")
                  |> Plug.Conn.resp(
                    200,
                    Jason.encode!(%{
                      "jsonrpc" => "2.0",
                      "id" => id,
                      "result" => %{"content" => [%{"type" => "text", "text" => "a_done"}]}
                    })
                  )
              end

            "tool_b" ->
              case Plug.Conn.get_req_header(conn, "authorization") do
                ["Bearer T3"] ->
                  conn
                  |> Plug.Conn.put_resp_content_type("application/json")
                  |> Plug.Conn.resp(
                    200,
                    Jason.encode!(%{
                      "jsonrpc" => "2.0",
                      "id" => id,
                      "result" => %{"content" => [%{"type" => "text", "text" => "b_done"}]}
                    })
                  )

                _other ->
                  conn
                  |> Plug.Conn.put_resp_header(
                    "www-authenticate",
                    ~s(Bearer error="insufficient_scope", scope="tools:b")
                  )
                  |> Plug.Conn.resp(401, "")
              end

            "tool_c" ->
              auth = Plug.Conn.get_req_header(conn, "authorization")
              send(test_pid, {:c_auth, auth})

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(
                200,
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{"content" => [%{"type" => "text", "text" => "c_done"}]}
                })
              )
          end
      end
    end)

    client = start_client(bypass)

    # Tool A runs: 401 (gets T1), 403 (gets T2), completes with T2 at v2
    assert {:ok, res_a} = Client.call_tool(client, "tool_a", %{}, timeout: 10_000)
    assert [%{text: "a_done"}] = res_a.content
    assert :sys.get_state(client).transport_state.access_token == "T2"
    assert :sys.get_state(client).transport_state.auth_version == 2

    # Now Tool B runs: hits 401, gets T3, completes with T3 at client-allocated v3
    assert {:ok, res_b} = Client.call_tool(client, "tool_b", %{}, timeout: 10_000)
    assert [%{text: "b_done"}] = res_b.content

    # T3 MUST NOT be discarded: client has T3 at version 3
    assert :sys.get_state(client).transport_state.access_token == "T3"
    assert :sys.get_state(client).transport_state.auth_version == 3

    # Subsequent call tool_c uses the newer T3 credentials
    assert {:ok, _} = Client.call_tool(client, "tool_c", %{}, timeout: 5_000)
    assert_receive {:c_auth, ["Bearer T3"]}, 2_000
  end

  test "interleaving 2: two single-step flows: B commits v2, delayed older A at v1 cannot overwrite T2" do
    bypass = Bypass.open()
    tokens = start_supervised!({Agent, fn -> ["T1", "T2"] end})
    setup_oauth_bypass(bypass, tokens)
    test_pid = self()

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
          case name do
            "tool_a" ->
              case Plug.Conn.get_req_header(conn, "authorization") do
                ["Bearer T1"] ->
                  # Hold Task A's successful retry until signaled
                  send(test_pid, {:holding_a, self()})

                  receive do
                    :release_a -> :ok
                  after
                    5_000 -> :ok
                  end

                  conn
                  |> Plug.Conn.put_resp_content_type("application/json")
                  |> Plug.Conn.resp(
                    200,
                    Jason.encode!(%{
                      "jsonrpc" => "2.0",
                      "id" => id,
                      "result" => %{"content" => [%{"type" => "text", "text" => "a_done"}]}
                    })
                  )

                _other ->
                  conn
                  |> Plug.Conn.put_resp_header(
                    "www-authenticate",
                    ~s(Bearer realm="mcp", scope="tools:a")
                  )
                  |> Plug.Conn.resp(401, "")
              end

            "tool_b" ->
              case Plug.Conn.get_req_header(conn, "authorization") do
                ["Bearer T2"] ->
                  conn
                  |> Plug.Conn.put_resp_content_type("application/json")
                  |> Plug.Conn.resp(
                    200,
                    Jason.encode!(%{
                      "jsonrpc" => "2.0",
                      "id" => id,
                      "result" => %{"content" => [%{"type" => "text", "text" => "b_done"}]}
                    })
                  )

                _other ->
                  conn
                  |> Plug.Conn.put_resp_header(
                    "www-authenticate",
                    ~s(Bearer error="insufficient_scope", scope="tools:b")
                  )
                  |> Plug.Conn.resp(401, "")
              end

            "tool_c" ->
              auth = Plug.Conn.get_req_header(conn, "authorization")
              send(test_pid, {:c_auth, auth})

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(
                200,
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{"content" => [%{"type" => "text", "text" => "c_done"}]}
                })
              )
          end
      end
    end)

    client = start_client(bypass)

    # Start Task A: allocates v1, gets T1, retries and is held by Bypass
    task_a = Task.async(fn -> Client.call_tool(client, "tool_a", %{}, timeout: 10_000) end)
    assert_receive {:holding_a, handler_a}, 5_000

    # Start Task B: allocates v2, gets T2, completes and commits T2 with auth_version 2
    task_b = Task.async(fn -> Client.call_tool(client, "tool_b", %{}, timeout: 10_000) end)
    assert {:ok, res_b} = Task.await(task_b, 5_000)
    assert [%{text: "b_done"}] = res_b.content

    # Client now has T2 at version 2
    assert :sys.get_state(client).transport_state.access_token == "T2"
    assert :sys.get_state(client).transport_state.auth_version == 2

    # Now release delayed Task A (which finishes with T1 at version 1)
    send(handler_a, :release_a)
    assert {:ok, res_a} = Task.await(task_a, 5_000)
    assert [%{text: "a_done"}] = res_a.content

    # Client MUST STILL have T2 at version 2 (T1 at v1 was dropped)
    assert :sys.get_state(client).transport_state.access_token == "T2"
    assert :sys.get_state(client).transport_state.auth_version == 2

    # Subsequent call tool_c uses newer T2 credentials
    assert {:ok, _} = Client.call_tool(client, "tool_c", %{}, timeout: 5_000)
    assert_receive {:c_auth, ["Bearer T2"]}, 2_000
  end
end
