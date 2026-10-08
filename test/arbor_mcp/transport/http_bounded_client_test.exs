defmodule Arbor.MCP.Transport.HTTP.BoundedClientTest do
  @moduledoc """
  Characterizes `Arbor.MCP.Transport.HTTP.BoundedClient` at its public boundary
  before the shared HTTP response reducer is extracted.

  Where this module differs from `Arbor.MCP.Internal.PinnedHTTPClient` and
  `Arbor.MCP.Authorization.PinnedHTTPClient` today, and must keep differing:

    * Result shape is the httpc-style
      `{{~c"HTTP/1.1", status, reason_charlist}, headers, body}` tuple, with
      the status reason requested from Mint.
    * Compressed responses are rejected as `:compressed_response`, and a
      response carrying both `content-length` and `transfer-encoding` would
      be `:invalid_response_framing`; Mint rejects that combination first,
      so it surfaces as `{:http_receive_failed, %Mint.HTTPError{}}`.
    * `content-length` handling is strict (single, trimmed, non-negative
      integer) and oversized values are `:response_too_large`.
    * Header validation runs over the accumulated header list, not only the
      latest Mint `:headers` event. Not observable because Mint strips
      `content-*` and `transfer-encoding` trailers.
    * Errors keep their Mint reason: `{:http_request_failed, reason}`,
      `{:http_receive_failed, reason}` (timeouts included), connect errors
      pass through from `Mint.HTTP1.connect/4`, and exceptions become
      `{:http_client_error, module_or_kind}`.
    * The target is resolved through `TargetPolicy`, the request body is
      bounded by `:max_request_bytes`, and the outgoing headers always get
      the caller's `host` removed plus `content-type` and
      `accept-encoding: identity` set.

  Events for a foreign request ref cannot be produced through this boundary
  (one HTTP/1 request per connection); that behavior is pinned by the
  reducer unit test.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Test.RawHTTPServer
  alias Arbor.MCP.Transport.HTTP.BoundedClient

  describe "limits" do
    test "accepts a response exactly at the limit" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 200, "1234")
      end)

      assert {:ok, {{_, 200, _}, _headers, "1234"}} =
               request(bypass, max_response_bytes: 4)
    end

    test "rejects a response one byte over the limit" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 200, "12345")
      end)

      assert {:error, :response_too_large} = request(bypass, max_response_bytes: 4)
    end

    test "rejects an oversized request before connecting" do
      bypass = Bypass.open()

      assert {:error, :request_too_large} =
               request(bypass, body: "12345", max_request_bytes: 4)
    end

    test "rejects an oversized content-length before reading the body" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345"])

      assert {:error, :response_too_large} = request_port(port, [], max_response_bytes: 4)
      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects a chunked body that exceeds max_response_bytes mid-stream" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
          "3\r\nabc\r\n",
          "3\r\ndef\r\n",
          "0\r\n\r\n"
        ])

      assert {:error, :response_too_large} = request_port(port, [], max_response_bytes: 4)
      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects a header section larger than max_header_bytes" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nX-Big: #{String.duplicate("x", 300)}\r\nContent-Length: 0\r\n\r\n"
        ])

      assert {:error, {:http_receive_failed, %Mint.HTTPError{}}} =
               request_port(port, [], max_header_bytes: 128)

      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "framing" do
    test "rejects duplicate content-length framing" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\n",
          "Content-Length: 4\r\n",
          "Content-Length: 4\r\n",
          "Connection: close\r\n\r\n",
          "1234"
        ])

      assert {:error,
              {:http_receive_failed,
               %Mint.HTTPError{reason: :more_than_one_content_length_header}}} =
               request_port(port)

      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects an invalid content-length" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n1234"])

      assert {:error,
              {:http_receive_failed,
               %Mint.HTTPError{reason: {:invalid_content_length_header, "abc"}}}} =
               request_port(port)

      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects content-length combined with transfer-encoding" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
          "4\r\n1234\r\n0\r\n\r\n"
        ])

      assert {:error,
              {:http_receive_failed,
               %Mint.HTTPError{reason: :transfer_encoding_and_content_length}}} =
               request_port(port)

      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "compression" do
    test "rejects compressed response bodies" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\n",
          "Content-Length: 4\r\n",
          "Content-Encoding: gzip\r\n",
          "Connection: close\r\n\r\n",
          "1234"
        ])

      assert {:error, :compressed_response} = request_port(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "accepts identity and blank content-encoding" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Encoding: Identity\r\n",
          "Content-Encoding: \r\n\r\n1234"
        ])

      assert {:ok, {{_, 200, _}, _headers, "1234"}} = request_port(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "accumulation" do
    test "accumulates status, reason, downcased headers in order, and body chunks in order" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 201 Created Fine\r\n",
          "X-First: one\r\nX-Dup: a\r\nContent-Type: text/plain\r\nX-Dup: B\r\n",
          "Transfer-Encoding: chunked\r\n\r\n",
          "2\r\nab\r\n",
          "2\r\ncd\r\n",
          "2\r\nef\r\n",
          "0\r\nX-Trailer: last\r\n\r\n"
        ])

      assert {:ok, {{~c"HTTP/1.1", 201, ~c"Created Fine"}, headers, "abcdef"}} =
               request_port(port)

      assert headers == [
               {"x-first", "one"},
               {"x-dup", "a"},
               {"content-type", "text/plain"},
               {"x-dup", "B"},
               {"transfer-encoding", "chunked"},
               {"x-trailer", "last"}
             ]

      assert :ok = RawHTTPServer.await(server)
    end

    test "returns an empty reason charlist when the status line has none" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 204\r\nContent-Length: 0\r\n\r\n"])

      assert {:ok, {{~c"HTTP/1.1", 204, ~c""}, [{"content-length", "0"}], ""}} =
               request_port(port)

      assert :ok = RawHTTPServer.await(server)
    end

    test "completes a connection-close delimited body" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", "abc", "def"])

      assert {:ok, {{_, 200, _}, _headers, "abcdef"}} = request_port(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "request line and headers" do
    test "overwrites a caller-supplied Host header with the validated URI authority" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      assert {:ok, {{_, 200, _}, _headers, ""}} =
               request_port(port, [{"Host", "attacker.invalid"}])

      assert_receive {:raw_request, request}
      assert request =~ "\r\nhost: 127.0.0.1:#{port}\r\n"
      refute request =~ "attacker.invalid"
      assert :ok = RawHTTPServer.await(server)
    end

    test "sends '/' for a bare authority and appends the query" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      assert {:ok, _response} = request_url("http://127.0.0.1:#{port}?a=1&b=2")

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "POST /?a=1&b=2 HTTP/1.1\r\n")
      assert :ok = RawHTTPServer.await(server)
    end

    test "upcases the method and forces content-type and accept-encoding" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      headers = [
        {"X-Custom", "Value"},
        {"Content-Type", "text/plain"},
        {"Accept-Encoding", "gzip"}
      ]

      assert {:ok, _response} = request_port(port, headers)

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "POST /mcp HTTP/1.1\r\n")
      assert request =~ "\r\nx-custom: Value\r\n"
      assert request =~ "\r\ncontent-type: application/json\r\n"
      assert request =~ "\r\naccept-encoding: identity\r\n"
      refute request =~ "text/plain"
      refute request =~ "gzip"
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "failures" do
    test "returns the Mint timeout when the request deadline expires" do
      {port, server} = RawHTTPServer.start(:hang)

      assert {:error, {:http_receive_failed, %Mint.TransportError{reason: :timeout}}} =
               request_port(port, [], request_timeout: 200)

      assert :ok = RawHTTPServer.await(server)
    end

    test "passes the Mint connect error through when the connection is refused" do
      {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      assert {:error, %Mint.TransportError{reason: :econnrefused}} = request_port(port)
    end

    test "returns the Mint close error when the server closes before any status" do
      {port, server} = RawHTTPServer.start([])

      assert {:error, {:http_receive_failed, %Mint.TransportError{reason: :closed}}} =
               request_port(port)

      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "an absolute :deadline" do
    test "refuses a request whose deadline has already passed, before connecting" do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        send(test_pid, :received) && Plug.Conn.resp(conn, 200, "")
      end)

      deadline = System.monotonic_time(:millisecond) - 1
      assert {:error, :deadline_expired} = request(bypass, deadline: deadline)
      refute_received :received
    end

    test "is checked again after DNS, so a request is not sent late" do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        send(test_pid, :received) && Plug.Conn.resp(conn, 200, "")
      end)

      deadline = System.monotonic_time(:millisecond) + 50

      # A resolver that answers only after the whole budget is spent (the
      # test is about the deadline passing mid-request).
      slow_dns = fn _host, _timeout ->
        Process.sleep(150)
        {:ok, [{127, 0, 0, 1}]}
      end

      assert {:error, :deadline_expired} =
               BoundedClient.request(
                 :post,
                 "http://localhost:#{bypass.port}/mcp",
                 [],
                 "application/json",
                 "{}",
                 Keyword.merge(base_opts(), deadline: deadline, dns_resolver: slow_dns)
               )

      refute_received :received
    end
  end

  defp request(bypass, overrides) do
    body = Keyword.get(overrides, :body, "{}")

    opts =
      base_opts()
      |> Keyword.merge(Keyword.drop(overrides, [:body]))

    BoundedClient.request(
      :post,
      "http://127.0.0.1:#{bypass.port}/mcp",
      [],
      "application/json",
      body,
      opts
    )
  end

  defp request_port(port, headers \\ [], overrides \\ []) do
    BoundedClient.request(
      :post,
      "http://127.0.0.1:#{port}/mcp",
      headers,
      "application/json",
      "{}",
      Keyword.merge(base_opts(), overrides)
    )
  end

  defp request_url(url) do
    BoundedClient.request(:post, url, [], "application/json", "{}", base_opts())
  end

  defp base_opts do
    [
      connect_timeout: 1_000,
      request_timeout: 1_000,
      max_request_bytes: 1_024,
      max_response_bytes: 1_024,
      transport_opts: []
    ]
  end
end
