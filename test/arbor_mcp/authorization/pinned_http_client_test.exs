defmodule Arbor.MCP.Authorization.PinnedHTTPClientTest do
  @moduledoc """
  Characterizes `Arbor.MCP.Authorization.PinnedHTTPClient` at its public boundary
  before the shared HTTP response reducer is extracted.

  Where this module differs from `Arbor.MCP.Internal.PinnedHTTPClient` and
  `Arbor.MCP.Transport.HTTP.BoundedClient` today, and must keep differing:

    * Result shape is the httpc-style
      `{{~c"HTTP/1.1", status, reason_charlist}, headers, body}` tuple, with
      the status reason requested from Mint.
    * Compressed responses (`content-encoding` other than blank or
      `identity`) are rejected as `:compressed_response`.
    * `content-length` handling is strict: the value is trimmed, must be a
      single non-negative integer, and is compared against
      `max_response_bytes`; anything else is `:response_too_large`. Mint
      rejects duplicate and non-digit values first, so only the oversized
      case is reachable.
    * There is no conflicting-framing check of its own; Mint's
      `:transfer_encoding_and_content_length` error surfaces as
      `:request_failed`.
    * Header validation looks at each Mint `:headers` event on its own, not
      the accumulated list. Not observable because Mint strips `content-*`
      and `transfer-encoding` trailers.
    * A `:done` event without an integer status would be
      `:invalid_response`; Mint never emits that sequence.
    * Receive errors and timeouts collapse to `:request_failed`. Connect
      errors are passed through from `Mint.HTTP1.connect/4` untouched, and
      malformed request tuples are `:invalid_request`.
    * Request headers are downcased and a `content-type` is added to a
      body-carrying request only when the caller did not supply one; the
      caller's `host` header is not removed (Mint adds its own).

  Events for a foreign request ref cannot be produced through this boundary
  (one HTTP/1 request per connection); that behavior is pinned by the
  reducer unit test.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.PinnedHTTPClient
  alias Arbor.MCP.Test.RawHTTPServer

  @loopback {127, 0, 0, 1}

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

      assert {:ok, {{~c"HTTP/1.1", 201, ~c"Created Fine"}, headers, "abcdef"}} = get(port)

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

      assert {:ok, {{~c"HTTP/1.1", 204, ~c""}, [{"content-length", "0"}], ""}} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "completes a connection-close delimited body" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", "abc", "def"])

      assert {:ok, {{_, 200, _}, _headers, "abcdef"}} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "accepts a body exactly at max_response_bytes" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234"])

      assert {:ok, {{_, 200, _}, _headers, "1234"}} = get(port, max_response_bytes: 4)
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

    test "collapses an invalid content-length rejected by Mint to :request_failed" do
      {port, server} = RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n1234"])

      assert {:error, :request_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "collapses duplicate content-length headers rejected by Mint to :request_failed" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n1234"
        ])

      assert {:error, :request_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "collapses content-length plus transfer-encoding rejected by Mint to :request_failed" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
          "4\r\n1234\r\n0\r\n\r\n"
        ])

      assert {:error, :request_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects a header section larger than max_header_bytes as :request_failed" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nX-Big: #{String.duplicate("x", 300)}\r\nContent-Length: 0\r\n\r\n"
        ])

      assert {:error, :request_failed} = get(port, max_header_bytes: 128)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "compression" do
    test "rejects a compressed response" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Encoding: gzip\r\n\r\n1234"
        ])

      assert {:error, :compressed_response} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects a compressed response regardless of value case and padding" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Encoding:  Br \r\n\r\n1234"
        ])

      assert {:error, :compressed_response} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end

    test "accepts identity and blank content-encoding" do
      {port, server} =
        RawHTTPServer.start([
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Encoding: Identity\r\n",
          "Content-Encoding: \r\n\r\n1234"
        ])

      assert {:ok, {{_, 200, _}, _headers, "1234"}} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  describe "request line and headers" do
    test "sends '/' for a nil path and appends the query" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      uri = %URI{scheme: "http", host: "127.0.0.1", port: port, path: nil, query: "a=1&b=2"}

      assert {:ok, _response} =
               PinnedHTTPClient.request(:get, uri, @loopback, {"", []}, [ssl: []], opts([]))

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "GET /?a=1&b=2 HTTP/1.1\r\n")
      assert :ok = RawHTTPServer.await(server)
    end

    test "sends '/' for an empty path with no query" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      uri = %URI{scheme: "http", host: "127.0.0.1", port: port, path: "", query: nil}

      assert {:ok, _response} =
               PinnedHTTPClient.request(:get, uri, @loopback, {"", []}, [ssl: []], opts([]))

      assert_receive {:raw_request, request}
      assert String.starts_with?(request, "GET / HTTP/1.1\r\n")
      assert :ok = RawHTTPServer.await(server)
    end

    test "upcases the method, downcases request headers, and adds content-type for a body" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      request = {"", [{"X-Custom", "Value"}], ~c"application/x-www-form-urlencoded", "a=1"}

      assert {:ok, _response} =
               PinnedHTTPClient.request(
                 :post,
                 uri(port, "/token"),
                 @loopback,
                 request,
                 [ssl: []],
                 opts([])
               )

      assert_receive {:raw_request, raw}
      assert String.starts_with?(raw, "POST /token HTTP/1.1\r\n")
      assert raw =~ "\r\nx-custom: Value\r\n"
      assert raw =~ "\r\ncontent-type: application/x-www-form-urlencoded\r\n"
      assert raw =~ "\r\ncontent-length: 3\r\n"
      assert :ok = RawHTTPServer.await(server)
    end

    test "keeps a caller-supplied content-type instead of the request's" do
      {port, server} =
        RawHTTPServer.start(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"], owner: self())

      request = {"", [{"Content-Type", "text/plain"}], "application/json", "{}"}

      assert {:ok, _response} =
               PinnedHTTPClient.request(
                 :put,
                 uri(port, "/x"),
                 @loopback,
                 request,
                 [ssl: []],
                 opts([])
               )

      assert_receive {:raw_request, raw}
      assert String.starts_with?(raw, "PUT /x HTTP/1.1\r\n")
      assert raw =~ "\r\ncontent-type: text/plain\r\n"
      refute raw =~ "application/json"
      assert :ok = RawHTTPServer.await(server)
    end

    test "rejects a malformed request tuple as :invalid_request without connecting" do
      assert {:error, :invalid_request} =
               PinnedHTTPClient.request(:get, uri(1, "/"), @loopback, :bogus, [ssl: []], opts([]))
    end
  end

  describe "failures" do
    test "returns :request_failed when the request deadline expires" do
      {port, server} = RawHTTPServer.start(:hang)

      assert {:error, :request_failed} = get(port, request_timeout_ms: 200)
      assert :ok = RawHTTPServer.await(server)
    end

    test "passes the Mint connect error through when the connection is refused" do
      {:ok, listener} = :gen_tcp.listen(0, ip: @loopback)
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      assert {:error, %Mint.TransportError{reason: :econnrefused}} = get(port)
    end

    test "returns :request_failed when the server closes before any status" do
      {port, server} = RawHTTPServer.start([])

      assert {:error, :request_failed} = get(port)
      assert :ok = RawHTTPServer.await(server)
    end
  end

  defp get(port, overrides \\ []) do
    PinnedHTTPClient.request(
      :get,
      uri(port, "/mcp"),
      @loopback,
      {"", []},
      [ssl: []],
      opts(overrides)
    )
  end

  defp uri(port, path), do: %URI{scheme: "http", host: "127.0.0.1", port: port, path: path}

  defp opts(overrides) do
    Keyword.merge(
      [
        connect_timeout_ms: 1_000,
        request_timeout_ms: 1_000,
        max_header_bytes: 65_536,
        max_response_bytes: 1_024
      ],
      overrides
    )
  end
end
