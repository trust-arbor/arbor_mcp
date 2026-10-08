defmodule Arbor.MCP.Client.RequestDeadlineCapTest do
  @moduledoc """
  A synchronous HTTP request runs inside the client process. When its caller
  gave it a timeout, the POST is cut off at the caller's deadline instead of
  holding the client for the transport's own request timeout.

  The server here is a raw socket rather than Bypass: cutting the connection
  is the behavior under test, and Bypass reports the handler it interrupts
  as a failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  test "a synchronous send is cut off at its caller's deadline" do
    port = start_server(self())

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        use_sse: false,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        reconnect: false
      )

    started = System.monotonic_time(:millisecond)
    assert {:error, _timeout} = Client.call_tool(client, "hang", %{}, timeout: 200)
    assert_receive {:tool_call_started, "hang", _handler}, 2_000

    # Without the cap the client stays inside the POST for the transport's
    # 30 s request timeout and cannot answer anything else. The bound leaves
    # room for a loaded CI host.
    assert %Client{} = :sys.get_state(client, 5_000)
    assert System.monotonic_time(:millisecond) - started < 5_000

    Client.stop(client)
  end

  # Answers initialize, accepts notifications, and never answers tools/call.
  defp start_server(test_pid) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn_link(fn -> accept_loop(listener, test_pid) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp accept_loop(listener, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> handle(socket, test_pid) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(listener, test_pid)

      {:error, _closed} ->
        :ok
    end
  end

  defp handle(socket, test_pid) do
    receive do
      :go -> :ok
    end

    {:ok, length} = read_head(socket, 0)
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = if length > 0, do: :gen_tcp.recv(socket, length, 5_000), else: {:ok, ""}

    case Jason.decode!(body) do
      %{"method" => "initialize", "id" => id} ->
        reply(socket, 200, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "hang", "version" => "1"}
          }
        })

      %{"method" => "tools/call", "params" => %{"name" => name}} ->
        send(test_pid, {:tool_call_started, name, self()})
        # Hold the request open until the client closes the connection.
        {:error, _closed} = :gen_tcp.recv(socket, 0, 10_000)

      _notification ->
        reply(socket, 202, nil)
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        read_head(socket, String.to_integer(value))

      {:ok, :http_eoh} ->
        {:ok, length}

      {:ok, _request_line_or_header} ->
        read_head(socket, length)
    end
  end

  defp reply(socket, status, body) do
    payload = if body, do: Jason.encode!(body), else: ""
    reason = if status == 200, do: "OK", else: "Accepted"

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(payload)}\r\n",
      "connection: close\r\n\r\n",
      payload
    ])
  end
end
