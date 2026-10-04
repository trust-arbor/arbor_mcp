defmodule Arbor.MCP.Client.EstablishDeadlineTest do
  @moduledoc """
  A host that accepts the connection and then answers nothing must not hold
  `Arbor.MCP.Client.start_link/1` past its timeouts: `:era_probe_timeout` bounds
  the probe exchange and `:handshake_timeout` the initialize exchange, a
  synchronous HTTP POST included, and `:establish_timeout` bounds the whole
  establishment. A failed attempt closes the transport it opened.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  # Far below the 30 s a synchronous POST was allowed before, and loose
  # enough for a loaded CI host.
  @bound 5_000

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "a silent HTTP host" do
    setup do
      port = start_silent_listener()
      %{url: "http://127.0.0.1:#{port}/mcp"}
    end

    test "legacy_only returns within :handshake_timeout", %{url: url} do
      {elapsed, result} =
        timed(fn -> start_client(url, protocol_mode: :legacy_only, handshake_timeout: 300) end)

      assert {:error, :handshake_timeout} = result
      assert elapsed < @bound
    end

    test "prefer_modern bounds the probe by :era_probe_timeout, then the fallback", %{url: url} do
      {elapsed, result} =
        timed(fn ->
          start_client(url,
            protocol_mode: :prefer_modern,
            era_probe_timeout: 200,
            handshake_timeout: 300
          )
        end)

      assert {:error, _reason} = result
      assert elapsed < @bound
      # A probe that timed out on its own bound counts as fallback evidence,
      # so initialize may follow it; nothing else is ever sent. (On a loaded
      # host a deadline can pass before a request is written, and then that
      # request is rightly not sent at all.)
      assert received_requests() in [
               [],
               ["server/discover"],
               ["initialize"],
               ["server/discover", "initialize"]
             ]
    end

    test "modern_only returns within :era_probe_timeout", %{url: url} do
      {elapsed, result} =
        timed(fn ->
          start_client(url, protocol_mode: :modern_only, era_probe_timeout: 200)
        end)

      assert {:error, _reason} = result
      assert elapsed < @bound
      # Never falls back to initialize.
      assert received_requests() in [[], ["server/discover"]]
    end

    test ":establish_timeout bounds the whole establishment", %{url: url} do
      {elapsed, result} =
        timed(fn ->
          start_client(url,
            protocol_mode: :legacy_only,
            handshake_timeout: 30_000,
            establish_timeout: 300
          )
        end)

      assert {:error, :establish_timeout} = result
      assert elapsed < @bound
    end

    test ":establish_timeout covers connection retries too", %{url: url} do
      {elapsed, result} =
        timed(fn ->
          start_client(url,
            protocol_mode: :legacy_only,
            handshake_timeout: 30_000,
            establish_timeout: 400,
            retry_policy: [max_attempts: 5, initial_delay: 50, jitter: false]
          )
        end)

      assert {:error, :establish_timeout} = result
      assert elapsed < @bound
    end
  end

  test "an invalid :establish_timeout is refused" do
    assert {:error, {:invalid_establish_timeout, -1}} =
             Client.start_link(
               transport: :test,
               establish_timeout: -1,
               health_check_interval: nil,
               reconnect: false
             )
  end

  @tag :tmp_dir
  test "a stdio handshake that times out stops the child it spawned", %{tmp_dir: tmp_dir} do
    pid_file = Path.join(tmp_dir, "child.pid")

    # The child ignores stdin, so closing the port alone would not stop it.
    command = ["sh", "-c", "echo $$ > #{pid_file}; exec sleep 30"]

    assert {:error, _reason} =
             Client.start_link(
               transport: :stdio,
               command: command,
               protocol_mode: :legacy_only,
               handshake_timeout: 300,
               health_check_interval: nil,
               reconnect: false
             )

    os_pid = pid_file |> File.read!() |> String.trim()
    refute os_process_alive?(os_pid)
  end

  test "a failed attempt closes the transport state it reached, not the one it began with" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "fails-after-initialize", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-from-initialize")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          )

        %{"method" => "notifications/initialized"} ->
          Plug.Conn.resp(conn, 500, "")
      end
    end)

    Bypass.expect(bypass, "DELETE", "/mcp", fn conn ->
      send(test_pid, {:session_deleted, Plug.Conn.get_req_header(conn, "mcp-session-id")})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert {:error, _reason} =
             start_client("http://127.0.0.1:#{bypass.port}/mcp", protocol_mode: :legacy_only)

    # Only the state after initialize knows the session; closing the
    # pre-handshake snapshot would leave it open on the server.
    assert_receive {:session_deleted, ["session-from-initialize"]}, 2_000
  end

  test "the session is still ended when the deadline is what failed the attempt" do
    port = start_session_server(self(), initialized: :hang, delete: :reply)

    assert {:error, :establish_timeout} =
             start_client("http://127.0.0.1:#{port}/mcp",
               protocol_mode: :legacy_only,
               handshake_timeout: 5_000,
               establish_timeout: 400
             )

    # notifications/initialized used up the deadline; the DELETE that ends the
    # session gets a cleanup budget of its own instead of being refused.
    assert_receive {:session_deleted, "session-from-initialize"}, 2_000
  end

  test "stopping a client does not wait on a session DELETE that never answers" do
    port = start_session_server(self(), initialized: :accept, delete: :hang)

    {:ok, client} =
      start_client("http://127.0.0.1:#{port}/mcp",
        protocol_mode: :legacy_only,
        request_timeout: 10_000
      )

    {elapsed, :ok} = timed(fn -> Client.stop(client) end)

    # The DELETE went out, and the stop did not wait out the 10 s request
    # timeout for its answer.
    assert_receive {:session_deleted, "session-from-initialize"}, 2_000
    assert elapsed < 3_000
  end

  test "a prefer_legacy fallback ends the session a failed initialize opened" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          error = %{"code" => -32_601, "message" => "Method not found"}

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-from-failed-initialize")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})
          )

        %{"method" => "server/discover"} ->
          Plug.Conn.resp(conn, 500, "")
      end
    end)

    Bypass.expect(bypass, "DELETE", "/mcp", fn conn ->
      send(test_pid, {:session_deleted, Plug.Conn.get_req_header(conn, "mcp-session-id")})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert {:error, _reason} =
             start_client("http://127.0.0.1:#{bypass.port}/mcp", protocol_mode: :prefer_legacy)

    assert_receive {:session_deleted, ["session-from-failed-initialize"]}, 2_000
  end

  defp start_client(url, opts) do
    Client.start_link(
      [
        transport: :http,
        url: url,
        use_sse: false,
        health_check_interval: nil,
        reconnect: false
      ] ++ opts
    )
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp os_process_alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end

  # A legacy MCP server on a raw socket: initialize opens a session,
  # notifications/initialized is accepted or hangs until the client gives up,
  # and DELETE reports the session it ends and then replies or hangs. (Bypass
  # would report a handler the client cuts off as a crash.)
  defp start_session_server(test_pid, behavior) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn_link(fn -> session_accept_loop(listener, test_pid, Map.new(behavior)) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp session_accept_loop(listener, test_pid, behavior) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> session_handle(socket, test_pid, behavior) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        session_accept_loop(listener, test_pid, behavior)

      {:error, _closed} ->
        :ok
    end
  end

  defp session_handle(socket, test_pid, behavior) do
    receive do
      :go -> :ok
    end

    {:ok, method, length, headers} = read_request_head(socket, nil, 0, %{})
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = if length > 0, do: :gen_tcp.recv(socket, length, 5_000), else: {:ok, ""}

    case {method, body} do
      {:DELETE, _body} ->
        send(test_pid, {:session_deleted, headers["mcp-session-id"]})

        case behavior.delete do
          :reply -> reply(socket, "204 No Content", [], "")
          :hang -> hang_until_closed(socket)
        end

      {:POST, body} ->
        case Jason.decode!(body) do
          %{"method" => "initialize", "id" => id} ->
            result = %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{},
              "serverInfo" => %{"name" => "slow-initialized", "version" => "1"}
            }

            reply(
              socket,
              "200 OK",
              [{"mcp-session-id", "session-from-initialize"}],
              Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
            )

          %{"method" => "notifications/initialized"} ->
            case behavior.initialized do
              :accept -> reply(socket, "202 Accepted", [], "")
              :hang -> hang_until_closed(socket)
            end
        end
    end

    :gen_tcp.close(socket)
  end

  defp hang_until_closed(socket) do
    {:error, _closed} = :gen_tcp.recv(socket, 0, 15_000)
  end

  defp read_request_head(socket, method, length, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_request, request_method, _uri, _version}} ->
        read_request_head(socket, request_method, length, headers)

      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        read_request_head(socket, method, String.to_integer(value), headers)

      {:ok, {:http_header, _, name, _, value}} ->
        name = name |> to_string() |> String.downcase()
        read_request_head(socket, method, length, Map.put(headers, name, value))

      {:ok, :http_eoh} ->
        {:ok, method, length, headers}

      {:error, _reason} = error ->
        error
    end
  end

  defp reply(socket, status, headers, body) do
    header_lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status}\r\n",
      "content-type: application/json\r\n",
      header_lines,
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  # Accepts every connection and reads each request, reporting its JSON-RPC
  # method as {:request, method}, but never writes a byte back.
  defp start_silent_listener do
    test_pid = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn_link(fn -> silent_accept_loop(listener, test_pid) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp silent_accept_loop(listener, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        reader = spawn(fn -> silent_read(socket, test_pid) end)
        :ok = :gen_tcp.controlling_process(socket, reader)
        send(reader, :go)
        silent_accept_loop(listener, test_pid)

      {:error, _closed} ->
        :ok
    end
  end

  defp silent_read(socket, test_pid) do
    receive do
      :go -> :ok
    end

    with {:ok, _method, length, _headers} <- read_request_head(socket, nil, 0, %{}),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, body} <- :gen_tcp.recv(socket, length, 5_000) do
      send(test_pid, {:request, Jason.decode!(body)["method"]})
    end

    # Hold the connection, unanswered, until the client gives up on it.
    :gen_tcp.recv(socket, 0, 15_000)
  end

  # The methods the silent host received, in order. Reading lags the client
  # slightly, so this collects until nothing more arrives for a moment.
  defp received_requests(acc \\ []) do
    receive do
      {:request, method} -> received_requests([method | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end
end
