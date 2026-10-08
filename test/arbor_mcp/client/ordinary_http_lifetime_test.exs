defmodule Arbor.MCP.Client.OrdinaryHTTPLifetimeTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Lifetime
  alias Arbor.MCP.Server.Discover
  alias Arbor.MCP.Transport.HTTP

  test "failed legacy SSE startup preserves suspended actor cleanup failure and borrowed listener" do
    bypass = Bypass.open()
    test = self()

    Bypass.expect_once(bypass, "GET", "/sse", fn conn ->
      Process.flag(:trap_exit, true)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(test, {:legacy_startup_host, self()})

      receive do
        :release_startup -> conn
      end
    end)

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        Client.start_link(
          name: __MODULE__,
          transport: :sse,
          url: "http://127.0.0.1:#{bypass.port}",
          protocol_mode: :legacy_only,
          stream_handshake_timeout: 200,
          establish_timeout: 3_000
        )
      end)

    assert_receive {:legacy_startup_host, host}, 1_000
    on_exit(fn -> send(host, :release_startup) end)
    client = Process.whereis(__MODULE__)
    {observer, _token, _epoch} = Lifetime.from_client(client)

    actor =
      :sys.get_state(observer).workers
      |> Map.keys()
      |> Enum.find(fn pid ->
        {:dictionary, dictionary} = Process.info(pid, :dictionary)

        :proplists.get_value(:"$initial_call", dictionary) ==
          {Arbor.MCP.Transport.SSEClient, :init, 1}
      end)

    assert is_pid(actor)
    true = :erlang.suspend_process(actor)

    assert {:error,
            {:transport_connect_failed,
             {:cleanup_failed, :endpoint_timeout, {:error, :http_cleanup_timeout}}}} =
             Task.await(task, 2_000)

    assert_down(actor)
    assert_down(client)
    assert_down(observer)
    assert Process.alive?(bypass.pid)
    send(host, :release_startup)
  end

  test "disconnect stops a suspended real modern actor and reports its failed graceful close" do
    {bypass, client} = modern_client()

    task =
      Task.async(fn ->
        Client.call_tool(client, "held", %{}, timeout: 3_000, progress_token: "ordinary-held")
      end)

    assert_receive {:held_http_request, host}, 2_000

    actor =
      client
      |> :sys.get_state()
      |> Map.fetch!(:transport_state)
      |> Map.fetch!(:modern_streams)
      |> Map.values()
      |> hd()

    :ok = :sys.suspend(actor)
    {observer, _token, _epoch} = Lifetime.from_client(client)
    owned = :sys.get_state(observer).workers |> Map.keys()
    assert length(owned) >= 2
    assert {:error, :http_cleanup_timeout} = Client.disconnect(client)
    for pid <- owned, do: assert_down(pid)
    assert {:error, _connection_error} = Task.await(task)
    assert Process.alive?(bypass.pid)
    send(host, :release_http)
    # The independently hosted listener remains available to another client.
    assert {:ok, sibling} =
             Client.start_link(
               transport: :http,
               url: "http://127.0.0.1:#{bypass.port}/mcp",
               protocol_mode: :modern_only,
               reconnect: false,
               health_check_interval: nil
             )

    assert :ok = Client.stop(sibling)
    assert {:error, :http_cleanup_timeout} = Client.stop(client)
  end

  test "hard native owner death stops a suspended real HTTP actor and its socket worker" do
    {bypass, client} = modern_client()
    test = self()
    caller = spawn(fn -> send(test, {:held_http_outcome, catch_call(client)}) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:held_http_request, host}, 2_000

    actor =
      client
      |> :sys.get_state()
      |> Map.fetch!(:transport_state)
      |> Map.fetch!(:modern_streams)
      |> Map.values()
      |> hd()

    :ok = :sys.suspend(actor)
    {observer, _token, _epoch} = Lifetime.from_client(client)
    owned = :sys.get_state(observer).workers |> Map.keys()
    Process.unlink(client)
    Process.exit(client, :kill)
    for pid <- [observer | owned], do: assert_down(pid)
    assert Process.alive?(bypass.pid)
    send(host, :release_http)
  end

  test "close refuses an unrelated process stored in a forged HTTP stream state" do
    borrowed =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(borrowed, :kill) end)
    state = %HTTP{protocol_era: :modern, modern_streams: %{7 => borrowed}}
    assert {:error, :unregistered_client_worker} = HTTP.close(state)
    assert Process.alive?(borrowed)
  end

  test "ordinary legacy POST workers are retained by PID and cannot outlive disconnect" do
    {bypass, client, stream_host} = legacy_client()
    task = Task.async(fn -> Client.call_tool(client, "held", %{}, timeout: 3_000) end)
    assert_receive {:held_legacy_post, post_host}, 2_000

    [{worker, _request_id}] =
      :sys.get_state(client).async_post_tasks
      |> Map.values()
      |> Enum.reject(fn {_pid, id} -> is_nil(id) end)

    {observer, _token, _epoch} = Lifetime.from_client(client)
    assert Map.has_key?(:sys.get_state(observer).workers, worker)
    assert :ok = Client.disconnect(client)
    assert_down(worker)
    assert :sys.get_state(client).async_post_tasks == %{}
    assert {:error, _reason} = Task.await(task)
    assert Process.alive?(bypass.pid)
    send(post_host, :release_http)
    send(stream_host, :release_http)
    assert :ok = Client.stop(client)
  end

  test "untagged legacy POST completions cannot mutate an ordinary native connection" do
    {_bypass, client} = modern_client()
    before = :sys.get_state(client).transport_state

    send(
      client,
      {:async_post_result, {:ok, nil},
       %{request_id: 7, state_changes: %{session_id: "old-session"}}}
    )

    send(
      client,
      {:async_post_result,
       {:ok, nil, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "result" => %{}})}}
    )

    assert :sys.get_state(client).transport_state == before
    assert :ok = Client.stop(client)
  end

  defp legacy_client do
    bypass = Bypass.open()
    test = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "initialize" ->
          result = %{
            "protocolVersion" => "2025-11-25",
            "serverInfo" => %{"name" => "legacy", "version" => "1"},
            "capabilities" => %{}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "ordinary-legacy")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
          )

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 204, "")

        "tools/call" ->
          Process.flag(:trap_exit, true)
          send(test, {:held_legacy_post, self()})

          receive do
            :release_http -> :ok
          end

          Plug.Conn.resp(
            conn,
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
          )
      end
    end)

    Bypass.expect(bypass, "GET", "/mcp", fn conn ->
      Process.flag(:trap_exit, true)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, ": ready\n\n")
      send(test, {:held_legacy_get, self()})

      receive do
        :release_http -> :ok
      end

      conn
    end)

    Bypass.expect(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :legacy_only,
        protocol_version: "2025-11-25",
        use_sse: true,
        reconnect: false,
        health_check_interval: nil
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    assert_receive {:held_legacy_get, host}, 2_000
    {bypass, client, host}
  end

  defp modern_client do
    bypass = Bypass.open()
    test = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "server/discover" ->
          result =
            Discover.build(%{"name" => "ordinary-http", "version" => "1"}, %{},
              protocol_mode: :modern_only
            )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => Map.put(result, "resultType", "complete")
            })
          )

        "tools/call" ->
          Process.flag(:trap_exit, true)

          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          send(test, {:held_http_request, self()})

          receive do
            :release_http -> :ok
          end

          conn
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        reconnect: false,
        health_check_interval: nil
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    {bypass, client}
  end

  defp catch_call(client) do
    Client.call_tool(client, "held", %{}, timeout: 3_000, progress_token: "ordinary-held")
  catch
    :exit, reason -> {:exit, reason}
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 500
  end
end
