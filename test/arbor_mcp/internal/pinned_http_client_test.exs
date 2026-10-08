defmodule Arbor.MCP.Internal.PinnedHTTPClientTest do
  @moduledoc """
  Characterizes `Arbor.MCP.Internal.PinnedHTTPClient` at its public boundary
  before the shared HTTP response reducer is extracted.

  Where this module differs from `Arbor.MCP.Authorization.PinnedHTTPClient` and
  `Arbor.MCP.Transport.HTTP.BoundedClient` today, and must keep differing:

    * Result shape is `{:ok, %{status, headers, body}}`, not an httpc-style
      `{{~c"HTTP/1.1", status, reason}, headers, body}` tuple. No status
      reason is requested from Mint.
    * Every failure that is not a size limit collapses to `:fetch_failed`,
      including connect errors, timeouts, and Mint framing rejections.
    * Compressed responses are accepted; there is no `:compressed_response`
      error. Callers are expected to send `accept-encoding: identity`.
    * `content-length` handling is lenient: any parseable value is compared
      against `max_response_bytes`, and an unparseable value is rejected as
      `:response_too_large`. Mint rejects duplicate and non-digit values
      before this module sees them, so only the oversized case is reachable.
    * Header validation looks at each Mint `:headers` event on its own, not
      the accumulated list. Because Mint strips `content-*` and
      `transfer-encoding` trailers, this is not observable here.
    * Only GET is supported; request headers arrive via `:request_headers`.

  Events for a foreign request ref cannot be produced through this boundary
  (one HTTP/1 request per connection); that behavior is pinned by the
  reducer unit test.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.PinnedHTTPClient
  alias Arbor.MCP.Test.RawHTTPServer

  @loopback {127, 0, 0, 1}

  describe "accumulation" do
    test "accumulates status, downcased headers in order, and body chunks in order" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 201 Created\r\n",
          "X-First: one\r\nX-Dup: a\r\nContent-Type: text/plain\r\nX-Dup: B\r\n",
          "Transfer-Encoding: chunked\r\n\r\n",
          "2\r\nab\r\n",
          "2\r\ncd\r\n",
          "2\r\nef\r\n",
          "0\r\nX-Trailer: last\r\n\r\n"
        ])

      assert {:ok, response} = get(port)
      assert response.status == 201
      assert response.body == "abcdef"

      assert response.headers == [
               {"x-first", "one"},
               {"x-dup", "a"},
               {"content-type", "text/plain"},
               {"x-dup", "B"},
               {"transfer-encoding", "chunked"},
               {"x-trailer", "last"}
             ]

      refute Map.has_key?(response, :reason)
      assert :ok = RawHTTPServer.await(server)
    end

    test "returns an empty body when content-length is zero" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"])

      assert {:ok, %{status: 204, headers: [{"content-length", "0"}], body: ""}} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "completes a connection-close delimited body" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", "abc", "def"])

      assert {:ok, %{status: 200, body: "abcdef"}} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "accepts a body exactly at max_response_bytes" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234"])

      assert {:ok, %{body: "1234"}} = get(port, max_response_bytes: 4)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "bounded body" do
    test "rejects an oversized content-length before reading the body" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345"])

      assert {:error, :response_too_large} = get(port, max_response_bytes: 4)
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

      assert {:error, :response_too_large} = get(port, max_response_bytes: 4)
      assert :ok = RawHTTPServer.await(server)
    end

    test "collapses an invalid content-length rejected by Mint to :fetch_failed" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n1234"])

      assert {:error, :fetch_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "collapses duplicate content-length headers rejected by Mint to :fetch_failed" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n1234"
        ])

      assert {:error, :fetch_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "collapses content-length plus transfer-encoding rejected by Mint to :fetch_failed" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
          "4\r\n1234\r\n0\r\n\r\n"
        ])

      assert {:error, :fetch_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "compression" do
    test "accepts a compressed response and returns the raw bytes" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Encoding: gzip\r\n\r\n1234"
        ])

      assert {:ok, %{status: 200, headers: headers, body: "1234"}} = get(port)
      assert {"content-encoding", "gzip"} in headers
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "request line" do
    test "sends '/' for a nil path and appends the query" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      uri = %URI{scheme: "http", host: "127.0.0.1", port: port, path: nil, query: "a=1&b=2"}
      assert {:ok, _response} = PinnedHTTPClient.get(uri, @loopback, opts([]))

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "GET /?a=1&b=2 HTTP/1.1\r\n")
      assert :ok = RawHTTPServer.await(server)
    end

    test "sends '/' for an empty path with no query" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      uri = %URI{scheme: "http", host: "127.0.0.1", port: port, path: "", query: nil}
      assert {:ok, _response} = PinnedHTTPClient.get(uri, @loopback, opts([]))

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "GET / HTTP/1.1\r\n")
      assert :ok = RawHTTPServer.await(server)
    end

    test "sends the path and the configured request headers" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      headers = [{"accept", "application/json"}, {"x-custom", "Value"}]
      assert {:ok, _response} = get(port, path: "/a/b", request_headers: headers)

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "GET /a/b HTTP/1.1\r\n")
      assert request =~ "\r\naccept: application/json\r\n"
      assert request =~ "\r\nx-custom: Value\r\n"
      assert request =~ "\r\nhost: 127.0.0.1:#{port}\r\n"
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "failures" do
    test "returns :fetch_failed when the request deadline expires" do
      {port, server} = RawHTTPServer.start(:hang)

      assert {:error, :fetch_failed} = get(port, request_timeout_ms: 200)
      assert :ok = RawHTTPServer.await(server)
    end

    test "returns :fetch_failed when the connection is refused" do
      {:ok, listener} = :gen_tcp.listen(0, ip: @loopback)
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      assert {:error, :fetch_failed} = get(port)
    end

    test "returns :fetch_failed when the server closes before any status" do
      {port, server} = RawHTTPServer.start([])

      assert {:error, :fetch_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  defp get(port, overrides \\ []) do
    {path, overrides} = Keyword.pop(overrides, :path, "/mcp")
    uri = %URI{scheme: "http", host: "127.0.0.1", port: port, path: path}
    PinnedHTTPClient.get(uri, @loopback, opts(overrides))
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        connect_timeout_ms: 1_000,
        request_timeout_ms: 1_000,
        max_response_bytes: 1_024,
        request_headers: []
      ],
      overrides
    )
  end
end
