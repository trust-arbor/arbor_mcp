defmodule ExMCP.Client.HTTPProviderFailureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias ExMCP.Client
  alias ExMCP.Server.Discover

  @moduletag :capture_log

  defmodule Provider do
    @behaviour ExMCP.Authorization.Provider
    def init(opts), do: {:ok, %{script: Keyword.fetch!(opts, :script)}}

    def get_token(%{script: script} = state) do
      case Agent.get(script, & &1) do
        {:token, token} -> {:ok, token, state}
        :none -> {:ok, nil, state}
        {:error, reason} -> {:error, reason}
        :raise -> raise ArgumentError, "fixture-secret"
        :throw -> throw("fixture-secret")
        :exit -> exit("fixture-secret")
        :invalid -> {"fixture-secret", :invalid}
        :nonbinary -> {:ok, %{secret: "fixture-secret"}, state}
      end
    end

    def handle_unauthorized(_www, _scopes, state), do: {:error, :unauthorized, state}
    def handle_forbidden(_www, _scopes, state), do: {:error, :forbidden, state}
  end

  for {mode, sse?} <- [modern_only: false, legacy_only: false, legacy_only: true] do
    @mode mode
    @sse sse?

    test "#{mode}, SSE #{sse?}: a provider failure sends nothing and can recover" do
      {client, script} = connect(@mode, @sse)
      assert {:ok, _} = Client.list_tools(client, format: :map)
      assert_receive {:seen, "tools/list", ["Bearer t1"]}
      set(script, {:error, :expired})

      assert {:error,
              %{type: :transport_error, reason: {:auth_provider_token_failed, Provider, :expired}} =
                error} =
               Client.list_tools(client, format: :map)

      assert Client.delivery_outcome(error) == :not_sent
      refute_received {:seen, "tools/list", _}
      assert :sys.get_state(client).transport_state.access_token == nil

      set(script, {:token, "t2"})
      assert {:ok, _} = Client.list_tools(client, format: :map)
      assert_receive {:seen, "tools/list", ["Bearer t2"]}
    end

    test "#{mode}, SSE #{sse?}: nil removes the previous token" do
      {client, script} = connect(@mode, @sse)
      assert {:ok, _} = Client.list_tools(client, format: :map)
      assert_receive {:seen, "tools/list", ["Bearer t1"]}
      set(script, :none)
      assert {:ok, _} = Client.list_tools(client, format: :map)
      assert_receive {:seen, "tools/list", []}
      assert :sys.get_state(client).transport_state.access_token == nil
    end
  end

  test "provider refusals prevent a dedicated stream and retain the 1.x map envelope" do
    {client, script} = connect(:modern_only, false)

    assert {:ok, _} =
             Client.call_tool(client, "echo", %{}, progress_token: "before", format: :map)

    assert_receive {:seen, "tools/call", ["Bearer t1"]}
    set(script, {:error, :expired})

    assert {:error,
            %{type: :transport_error, reason: {:auth_provider_token_failed, Provider, :expired}} =
              error} =
             Client.call_tool(client, "echo", %{}, progress_token: "after", format: :map)

    assert Client.delivery_outcome(error) == :not_sent
    refute_received {:seen, "tools/call", _}
  end

  test "a dedicated stream drops the earlier token when the provider returns nil" do
    {client, script} = connect(:modern_only, false)

    assert {:ok, _} =
             Client.call_tool(client, "echo", %{}, progress_token: "before", format: :map)

    assert_receive {:seen, "tools/call", ["Bearer t1"]}
    set(script, :none)
    assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "after", format: :map)
    assert_receive {:seen, "tools/call", []}
  end

  test "callback failures are contained and sensitive reasons are redacted" do
    {client, script} = connect(:modern_only, false)
    assert {:ok, _} = Client.list_tools(client, format: :map)
    assert_receive {:seen, "tools/list", _}

    log =
      capture_log(fn ->
        for {value, expected} <- [
              {{:error, %{secret: "fixture-secret"}}, :redacted},
              {:raise, {:raised, ArgumentError}},
              {:throw, :throw},
              {:exit, :exit},
              {:invalid, :invalid_token_result},
              {:nonbinary, :invalid_token_result}
            ] do
          set(script, value)

          assert {:error, %{reason: {:auth_provider_token_failed, Provider, ^expected}} = error} =
                   Client.list_tools(client, format: :map)

          assert Client.delivery_outcome(error) == :not_sent
          refute_received {:seen, "tools/list", _}
        end
      end)

    refute log =~ "fixture-secret"
    assert Process.alive?(client)
  end

  test "a configured Authorization header cannot survive a provider's nil token" do
    {client, _script} =
      connect(:modern_only, false, :none, headers: [{"AUTHORIZATION", "Bearer configured"}])

    assert {:ok, _} = Client.list_tools(client, format: :map)
    assert_receive {:seen, "tools/list", []}
  end

  test "a provider refusal during startup fails through the existing connection envelope" do
    bypass = server()
    script = start_supervised!({Agent, fn -> {:error, "fixture-secret"} end})
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert {:error, {:transport_connect_failed, reason}} =
                 start_client(bypass, script, :modern_only, false, [])

        assert is_binary(reason)
        refute reason =~ "fixture-secret"
      end)

    refute log =~ "fixture-secret"
    refute_received {:seen, _, _}
  end

  defp connect(mode, sse?, initial \\ {:token, "t1"}, opts \\ []) do
    bypass = server()
    script = start_supervised!({Agent, fn -> initial end})
    client = start_supervised!({Client, client_options(bypass, script, mode, sse?, opts)})
    {client, script}
  end

  defp start_client(bypass, script, mode, sse?, opts),
    do: Client.start_link(client_options(bypass, script, mode, sse?, opts))

  defp client_options(bypass, script, mode, sse?, opts) do
    [
      transport: :http,
      url: "http://127.0.0.1:#{bypass.port}/mcp",
      protocol_mode: mode,
      use_sse: sse?,
      auth_provider: {Provider, script: script},
      reconnect: false,
      health_check_interval: nil
    ] ++ opts
  end

  defp server do
    bypass = Bypass.open()
    owner = self()

    for method <- ["GET", "POST", "DELETE"] do
      Bypass.stub(bypass, method, "/mcp", fn conn ->
        case conn.method do
          "GET" ->
            monitor = Process.monitor(owner)

            conn =
              conn
              |> Plug.Conn.put_resp_content_type("text/event-stream")
              |> Plug.Conn.send_chunked(200)

            {:ok, conn} = Plug.Conn.chunk(conn, ":ready\n\n")

            receive do
              {:DOWN, ^monitor, :process, ^owner, _} -> conn
            end

          "DELETE" ->
            Plug.Conn.resp(conn, 200, "")

          "POST" ->
            reply_post(conn, owner)
        end
      end)
    end

    bypass
  end

  defp reply_post(conn, owner) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    send(owner, {:seen, request["method"], Plug.Conn.get_req_header(conn, "authorization")})

    result =
      case request["method"] do
        "server/discover" ->
          Discover.build(%{"name" => "provider-test", "version" => "1"}, %{"tools" => %{}},
            protocol_mode: :modern_only
          )

        "initialize" ->
          %{
            "protocolVersion" => "2025-11-25",
            "serverInfo" => %{"name" => "provider-test", "version" => "1"},
            "capabilities" => %{"tools" => %{}}
          }

        "tools/list" ->
          %{
            "ttlMs" => 0,
            "cacheScope" => "private",
            "tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]
          }

        "tools/call" ->
          %{"content" => [%{"type" => "text", "text" => "ok"}]}

        _ ->
          %{}
      end

    if Map.has_key?(request, "id") do
      conn
      |> Plug.Conn.put_resp_header("mcp-session-id", "provider-session")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => Map.put(result, "resultType", "complete")
        })
      )
    else
      Plug.Conn.resp(conn, 202, "")
    end
  end

  defp set(script, value), do: Agent.update(script, fn _ -> value end)
end
