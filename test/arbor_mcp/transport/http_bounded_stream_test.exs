defmodule Arbor.MCP.Transport.HTTP.BoundedStreamTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP.BoundedStream

  test "accepts a chunked non-streaming response exactly at the byte limit" do
    {port, server} = chunked_server(["4\r\n1234\r\n", "0\r\n\r\n"])

    assert {:ok, worker} = start_request(port, 4)
    assert_receive {:bounded_http, ^worker, {:complete, 500, _headers, "1234"}}, 1_000
    assert :ok = Task.await(server)
  end

  test "closes a chunked non-streaming response at max bytes plus one" do
    {port, server} = chunked_server(["4\r\n1234\r\n", "1\r\n5\r\n"])

    assert {:ok, worker} = start_request(port, 4)
    assert_receive {:bounded_http, ^worker, {:error, :response_too_large}}, 1_000
    assert {:error, :closed} = Task.await(server)
  end

  test "overwrites a caller-supplied Host header with the validated URI authority" do
    {port, server} = capture_server(self())

    assert {:ok, worker} =
             BoundedStream.start(
               self(),
               :get,
               "http://127.0.0.1:#{port}/mcp",
               [{"Host", "attacker.invalid"}, {"accept-encoding", "identity"}],
               nil,
               connect_timeout: 1_000,
               max_response_bytes: 4
             )

    assert_receive {:bounded_http, ^worker, {:complete, 200, _headers, ""}}, 1_000
    assert_receive {:raw_request, request}
    assert request =~ "\r\nhost: 127.0.0.1:#{port}\r\n"
    refute request =~ "attacker.invalid"
    assert :ok = Task.await(server)
  end

  defp start_request(port, max_response_bytes) do
    BoundedStream.start(
      self(),
      :get,
      "http://127.0.0.1:#{port}/mcp",
      [{"accept-encoding", "identity"}],
      nil,
      connect_timeout: 1_000,
      max_response_bytes: max_response_bytes
    )
  end

  defp chunked_server(chunks) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 500 Error\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Content-Type: text/plain\r\n",
            "Connection: close\r\n\r\n"
            | chunks
          ])

        result =
          if List.last(chunks) == "0\r\n\r\n" do
            :ok
          else
            :gen_tcp.recv(socket, 0, 1_000)
          end

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        result
      end)

    {port, server}
  end

  defp capture_server(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, request} = recv_headers(socket, "")
        send(owner, {:raw_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        :ok
      end)

    {port, server}
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> recv_headers(socket, acc <> data)
        error -> error
      end
    end
  end
end
