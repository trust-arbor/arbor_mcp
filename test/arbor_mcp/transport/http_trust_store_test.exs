defmodule Arbor.MCP.Transport.HTTPTrustStoreTest do
  # Sets :arbor_mcp application env, so it cannot run concurrently with others.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Authorization.MetadataHTTPClient
  alias Arbor.MCP.Authorization.PinnedHTTPClient, as: AuthorizationPinnedHTTPClient
  alias Arbor.MCP.Content.SchemaHTTPClient
  alias Arbor.MCP.Internal.PinnedHTTPClient
  alias Arbor.MCP.Test.TLSServer
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.{BoundedClient, BoundedStream, LegacySSE}

  @loopback {127, 0, 0, 1}

  setup do
    previous = Application.fetch_env(:arbor_mcp, :cacerts)
    key = {__MODULE__, make_ref()}
    Application.put_env(:arbor_mcp, :cacerts, loader: fn -> [] end, cache_key: key)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :cacerts, value)
        :error -> Application.delete_env(:arbor_mcp, :cacerts)
      end
    end)
  end

  test "an HTTPS request fails closed with an error when the trust store is unavailable" do
    {:ok, state} = HTTP.connect(url: "https://127.0.0.1:1", endpoint: "/mcp", use_sse: false)
    message = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    capture_log(fn ->
      assert HTTP.send_message(message, state) ==
               {:error, {:trust_store_unavailable, :no_certificates}}
    end)
  end

  # Without :cacerts, Mint loads the OS store itself and falls back to CAStore
  # without the fallback: :castore opt-in. Every client that connects with
  # Mint must fail closed instead, before it opens a connection.
  describe "an HTTPS connection without CA options fails closed before connecting" do
    setup do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: @loopback])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)
      %{listener: listener, port: port}
    end

    test "BoundedClient", %{listener: listener, port: port} do
      capture_log(fn ->
        assert BoundedClient.request(
                 :post,
                 "https://127.0.0.1:#{port}/mcp",
                 [],
                 "application/json",
                 "{}",
                 connect_timeout: 1_000,
                 request_timeout: 1_000,
                 max_request_bytes: 1_024,
                 max_response_bytes: 1_024,
                 transport_opts: []
               ) == {:error, {:trust_store_unavailable, :no_certificates}}
      end)

      refute_connected(listener)
    end

    test "BoundedStream", %{listener: listener, port: port} do
      capture_log(fn ->
        assert {:ok, worker} =
                 BoundedStream.start(self(), :get, "https://127.0.0.1:#{port}/mcp", [], nil,
                   connect_timeout: 1_000,
                   max_response_bytes: 1_024
                 )

        assert_receive {:bounded_http, ^worker,
                        {:error, {:connect_failed, {:trust_store_unavailable, :no_certificates}}}},
                       1_000
      end)

      refute_connected(listener)
    end

    test "the legacy HTTP+SSE transport", %{listener: listener, port: port} do
      capture_log(fn ->
        assert LegacySSE.connect(
                 url: "https://127.0.0.1:#{port}",
                 timeout: 1_000,
                 stream_handshake_timeout: 1_000
               ) == {:error, {:trust_store_unavailable, :no_certificates}}
      end)

      refute_connected(listener)
    end

    test "the OAuth metadata and JSON Schema fetch client", %{listener: listener, port: port} do
      capture_log(fn ->
        assert PinnedHTTPClient.get(URI.parse("https://127.0.0.1:#{port}/"), @loopback,
                 connect_timeout_ms: 1_000,
                 request_timeout_ms: 1_000,
                 max_response_bytes: 1_024,
                 request_headers: []
               ) == {:error, :fetch_failed}
      end)

      refute_connected(listener)
    end

    test "the OAuth request client", %{listener: listener, port: port} do
      capture_log(fn ->
        assert AuthorizationPinnedHTTPClient.request(
                 :get,
                 URI.parse("https://127.0.0.1:#{port}/"),
                 @loopback,
                 {"", []},
                 [ssl: []],
                 connect_timeout_ms: 1_000,
                 request_timeout_ms: 1_000,
                 max_header_bytes: 65_536,
                 max_response_bytes: 1_024
               ) == {:error, {:trust_store_unavailable, :no_certificates}}
      end)

      refute_connected(listener)
    end
  end

  # The trust store is unavailable here, so these succeed only through the CA
  # certificates passed to each client.
  describe "configured CA certificates are trusted instead of the trust store" do
    test "by the OAuth metadata and JSON Schema fetch clients" do
      server = TLSServer.start(fn _head -> {:close, http_response(200, "{}")} end)
      uri = URI.parse("https://localhost:#{server.port}/document")
      opts = fetch_opts(cacerts: server.cacerts)

      for client <- [MetadataHTTPClient, SchemaHTTPClient] do
        assert {:ok, %{status: 200, body: "{}"}} = client.get(uri, @loopback, opts)
        assert_received {:tls_request, "GET /document HTTP/1.1" <> _}
      end
    end

    test "and a server they did not sign is rejected" do
      server = TLSServer.start(fn _head -> {:close, http_response(200, "{}")} end)
      other_ca = TLSServer.start(fn _head -> {:close, http_response(200, "{}")} end)
      uri = URI.parse("https://localhost:#{server.port}/document")

      assert PinnedHTTPClient.get(uri, @loopback, fetch_opts(cacerts: other_ca.cacerts)) ==
               {:error, :fetch_failed}

      refute_received {:tls_request, _head}
    end

    test "by the legacy HTTP+SSE transport, for its event stream and its POSTs" do
      server =
        TLSServer.start(fn
          "GET /sse " <> _ ->
            {:keep_open, sse_response("event: endpoint\ndata: /messages?sessionId=abc\n\n")}

          "POST /messages?sessionId=abc " <> _ ->
            {:close, http_response(202, "")}
        end)

      assert {:ok, state} =
               LegacySSE.connect(
                 url: "https://localhost:#{server.port}",
                 dns_resolver: fn "localhost", _timeout -> {:ok, [@loopback]} end,
                 security: %{tls: %{cacerts: server.cacerts}}
               )

      on_exit(fn -> LegacySSE.close(state) end)
      message = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert {:ok, _state} = LegacySSE.send_message(message, state)
      assert_received {:tls_request, "GET /sse HTTP/1.1" <> _}
      assert_received {:tls_request, "POST /messages?sessionId=abc HTTP/1.1" <> _}
    end
  end

  describe "verify: :verify_none does not need the trust store" do
    test "for the HTTP transport" do
      server = TLSServer.start(fn _head -> {:close, http_response(202, "")} end)

      {:ok, state} =
        HTTP.connect(
          url: "https://127.0.0.1:#{server.port}/mcp",
          use_sse: false,
          security: %{tls: %{verify: :verify_none}}
        )

      message = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      capture_log(fn -> HTTP.send_message(message, state) end)
      assert_received {:tls_request, "POST /mcp HTTP/1.1" <> _}
    end

    test "for the legacy HTTP+SSE transport" do
      server =
        TLSServer.start(fn "GET /sse " <> _ ->
          {:keep_open, sse_response("event: endpoint\ndata: /messages?sessionId=abc\n\n")}
        end)

      assert {:ok, state} =
               LegacySSE.connect(
                 url: "https://localhost:#{server.port}",
                 dns_resolver: fn "localhost", _timeout -> {:ok, [@loopback]} end,
                 security: %{tls: %{verify: :verify_none}}
               )

      LegacySSE.close(state)
    end
  end

  defp refute_connected(listener) do
    assert :gen_tcp.accept(listener, 0) == {:error, :timeout}
  end

  defp fetch_opts(overrides) do
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

  defp http_response(status, body) do
    "HTTP/1.1 #{status} Status\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
  end

  defp sse_response(event) do
    size = event |> byte_size() |> Integer.to_string(16)

    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
      "transfer-encoding: chunked\r\n\r\n#{size}\r\n#{event}\r\n"
  end
end
