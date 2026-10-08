defmodule Arbor.MCP.Client.ConnectionScopeHTTPTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.ConnectionScope.Ref
  alias Arbor.MCP.Server.Discover

  test "borrowed modern HTTP listener survives confirmed local stream cleanup" do
    bypass = Bypass.open()
    test = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "server/discover" ->
          result =
            Discover.build(%{"name" => "scope-http", "version" => "1"}, %{},
              protocol_mode: :modern_only
            )

          json(conn, request["id"], Map.put(result, "resultType", "complete"))

        "tools/call" ->
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          send(test, {:stream_fixture, self()})

          receive do
            :reply_stream -> :ok
          end

          final =
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "resultType" => "complete",
                "content" => [%{"type" => "text", "text" => "done"}]
              }
            })

          {:ok, conn} = Plug.Conn.chunk(conn, "data: #{final}\n\n")
          conn
      end
    end)

    assert {:ok, owned} =
             Client.with_connection(
               "http://127.0.0.1:#{bypass.port}/mcp",
               [protocol_mode: :modern_only, health_check_interval: nil],
               fn client ->
                 scope = :sys.get_state(client).transport_opts[:_connection_scope]
                 observer = Ref.observer(scope)

                 task =
                   Task.async(fn ->
                     Client.call_tool(client, "stream", %{}, progress_token: "scope-stream")
                   end)

                 assert_receive {:stream_fixture, fixture}, 2000
                 workers = :sys.get_state(observer).workers |> Map.values()
                 assert length(workers) >= 2
                 send(fixture, :reply_stream)
                 assert {:ok, _response} = Task.await(task, 2000)
                 [client, observer | workers]
               end
             )

    for pid <- owned, do: wait_down(pid)

    assert {:ok, :still_open} =
             Client.with_connection(
               "http://127.0.0.1:#{bypass.port}/mcp",
               [protocol_mode: :modern_only, health_check_interval: nil],
               fn _client -> :still_open end
             )
  end

  test "legacy DELETE success does not invent remote session cleanup proof" do
    bypass = Bypass.open()
    test = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "borrowed-session")
          |> json(request["id"], %{
            "protocolVersion" => "2025-11-25",
            "serverInfo" => %{"name" => "scope-http", "version" => "1"},
            "capabilities" => %{}
          })

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.expect(bypass, "DELETE", "/mcp", fn conn ->
      send(test, {:delete_attempt, Plug.Conn.get_req_header(conn, "mcp-session-id")})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert {:error, {:cleanup_failed, :remote_session_cleanup_unconfirmed, :value}} =
             Client.with_connection(
               "http://127.0.0.1:#{bypass.port}/mcp",
               [protocol_mode: :legacy_only, use_sse: false, health_check_interval: nil],
               fn _client -> :value end
             )

    assert_receive {:delete_attempt, ["borrowed-session"]}
  end

  defp json(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp wait_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1000
  end
end
