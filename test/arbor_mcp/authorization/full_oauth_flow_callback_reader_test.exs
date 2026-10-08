defmodule Arbor.MCP.Authorization.FullOAuthFlowCallbackReaderTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.FullOAuthFlow

  @max_header_bytes 16_384

  test "reads fragmented headers through the first CRLFCRLF" do
    {client, server} = socket_pair()

    sender =
      Task.async(fn ->
        for fragment <- [
              "GET /callback?code=abc&state=xyz HTTP/1.1\r",
              "\nHost: 127.0.0.1\r\nX-Test: frag",
              "mented\r",
              "\n\r",
              "\nignored-body"
            ] do
          :ok = :gen_tcp.send(client, fragment)
          Process.sleep(5)
        end
      end)

    expected =
      "GET /callback?code=abc&state=xyz HTTP/1.1\r\n" <>
        "Host: 127.0.0.1\r\nX-Test: fragmented\r\n\r\n"

    assert {:ok, ^expected} = FullOAuthFlow.read_callback_headers(server, 1_000)
    Task.await(sender)

    :ok = :inet.setopts(server, packet: :raw)
    assert {:ok, "ignored-body"} = :gen_tcp.recv(server, 0, 1_000)

    close_sockets(client, server)
  end

  test "rejects an oversized header line before materializing it" do
    {client, server} = socket_pair()

    prefix = "GET /callback HTTP/1.1\r\nX-Oversized: "
    request = prefix <> String.duplicate("a", @max_header_bytes + 1 - byte_size(prefix))
    assert byte_size(request) == @max_header_bytes + 1

    :ok = :gen_tcp.send(client, request)

    assert {:error, :callback_headers_too_large} =
             FullOAuthFlow.read_callback_headers(server, 1_000)

    close_sockets(client, server)
  end

  test "uses one absolute deadline across fragmented header lines" do
    {client, server} = socket_pair()

    sender =
      Task.async(fn ->
        Process.sleep(90)
        :ok = :gen_tcp.send(client, "GET /callback HTTP/1.1\r\n")
        Process.sleep(90)
        :ok = :gen_tcp.send(client, "Host: 127.0.0.1\r\n")
        Process.sleep(90)
        :gen_tcp.send(client, "\r\n")
      end)

    assert {:error, :callback_header_timeout} =
             FullOAuthFlow.read_callback_headers(server, 150)

    Task.shutdown(sender, :brutal_kill)
    close_sockets(client, server)
  end

  test "rejects LF-only header framing" do
    {client, server} = socket_pair()
    :ok = :gen_tcp.send(client, "GET /callback HTTP/1.1\n\n")

    assert {:error, :invalid_callback_headers} =
             FullOAuthFlow.read_callback_headers(server, 1_000)

    close_sockets(client, server)
  end

  defp socket_pair do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listener, 1_000)
    :ok = :gen_tcp.close(listener)
    {client, server}
  end

  defp close_sockets(client, server) do
    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end
end
