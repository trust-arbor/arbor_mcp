defmodule Arbor.MCP.Authorization.SecureHTTPTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.SecureHTTP

  @public_address {93, 184, 216, 34}

  test "pins the approved address while retaining Host, SNI, and hostname verification" do
    owner = self()

    request_fun = fn method, request, http_options, request_options ->
      send(owner, {:request, method, request, http_options, request_options})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~c"{}"}}
    end

    assert {:ok, {{_, 200, _}, [], "{}"}} =
             SecureHTTP.request(
               :post,
               "https://oauth.example/token?attempt=1",
               [{"content-type", "application/x-www-form-urlencoded"}],
               "grant_type=client_credentials",
               dns_resolver: resolver([@public_address]),
               request_fun: request_fun,
               request_timeout_ms: 1_234,
               connect_timeout_ms: 456
             )

    assert_receive {:request, :post, {url, headers, content_type, body}, http_options,
                    request_options}

    assert to_string(url) == "https://93.184.216.34/token?attempt=1"
    assert {~c"host", ~c"oauth.example"} in headers
    assert {~c"accept-encoding", ~c"identity"} in headers
    assert content_type == ~c"application/x-www-form-urlencoded"
    assert body == "grant_type=client_credentials"
    assert http_options[:autoredirect] == false
    assert http_options[:timeout] == 1_234
    assert http_options[:connect_timeout] == 456
    assert request_options[:body_format] == :binary

    ssl = http_options[:ssl]
    assert ssl[:verify] == :verify_peer
    assert ssl[:server_name_indication] == ~c"oauth.example"
    assert is_list(ssl[:cacerts])
    assert is_list(ssl[:customize_hostname_check])
  end

  test "never follows redirects" do
    owner = self()

    request_fun = fn _method, _request, http_options, _request_options ->
      send(owner, {:called, http_options[:autoredirect]})

      {:ok, {{~c"HTTP/1.1", 302, ~c"Found"}, [{~c"location", ~c"https://evil.example"}], ""}}
    end

    assert {:ok, {{_, 302, _}, _, ""}} =
             SecureHTTP.request(:get, "https://oauth.example/start", [], nil,
               dns_resolver: resolver([@public_address]),
               request_fun: request_fun
             )

    assert_receive {:called, false}
    refute_receive {:called, _}
  end

  test "rejects oversized and compressed responses" do
    oversized = fn _method, _request, _http_options, _request_options ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "12345"}}
    end

    assert {:error, :response_too_large} =
             SecureHTTP.request(:get, "https://oauth.example/data", [], nil,
               dns_resolver: resolver([@public_address]),
               request_fun: oversized,
               max_response_bytes: 4
             )

    compressed = fn _method, _request, _http_options, _request_options ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-encoding", ~c"gzip"}], "data"}}
    end

    assert {:error, :compressed_response} =
             SecureHTTP.request(:get, "https://oauth.example/data", [], nil,
               dns_resolver: resolver([@public_address]),
               request_fun: compressed
             )
  end

  test "default Mint path aborts a chunked response at max bytes plus one" do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Content-Type: application/json\r\n",
            "Connection: close\r\n\r\n",
            "4\r\n1234\r\n",
            "1\r\n5\r\n"
          ])

        # No terminating zero-sized chunk is sent. A post-materialization
        # implementation would wait for completion; the incremental client
        # must reject at byte five and close the socket immediately.
        closed = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        closed
      end)

    assert {:error, :response_too_large} =
             SecureHTTP.request(:get, "http://127.0.0.1:#{port}/chunked", [], nil,
               max_response_bytes: 4,
               request_timeout_ms: 1_000,
               connect_timeout_ms: 1_000
             )

    assert {:ok, {:error, :closed}} = Task.yield(server, 1_000)
  end

  test "rejects private, mixed, userinfo, fragmented, and non-loopback HTTP targets" do
    assert {:error, :non_public_address} =
             SecureHTTP.resolve_target("https://oauth.example/token",
               dns_resolver: resolver([{10, 0, 0, 1}])
             )

    assert {:error, :non_public_address} =
             SecureHTTP.resolve_target("https://oauth.example/token",
               dns_resolver: resolver([@public_address, {127, 0, 0, 1}])
             )

    assert {:error, :userinfo_forbidden} =
             SecureHTTP.resolve_target("https://user:secret@oauth.example/token",
               dns_resolver: resolver([@public_address])
             )

    assert {:error, :fragment_forbidden} =
             SecureHTTP.resolve_target("https://oauth.example/token#secret",
               dns_resolver: resolver([@public_address])
             )

    assert {:error, :https_required} =
             SecureHTTP.resolve_target("http://oauth.example/token",
               dns_resolver: resolver([@public_address])
             )
  end

  test "loopback HTTP is literal-only and can be disabled" do
    assert {:ok, %URI{host: "localhost"}, {127, 0, 0, 1}} =
             SecureHTTP.resolve_target("http://localhost:4000/token",
               dns_resolver: resolver([{127, 0, 0, 1}])
             )

    assert {:error, :https_required} =
             SecureHTTP.resolve_target("http://localhost:4000/token",
               allow_insecure_loopback: false,
               dns_resolver: resolver([{127, 0, 0, 1}])
             )

    assert {:error, :https_required} =
             SecureHTTP.resolve_target("http://localhost.example/token",
               dns_resolver: resolver([@public_address])
             )
  end

  test "security-critical TLS settings cannot be weakened by an override" do
    owner = self()

    request_fun = fn _method, _request, http_options, _request_options ->
      send(owner, {:ssl, http_options[:ssl]})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ""}}
    end

    assert {:ok, _response} =
             SecureHTTP.request(:get, "https://oauth.example", [], nil,
               dns_resolver: resolver([@public_address]),
               request_fun: request_fun,
               ssl_options: [
                 verify: :verify_none,
                 server_name_indication: ~c"evil.example",
                 verify_fun: {fn _, state, _ -> {:valid, state} end, nil},
                 partial_chain: fn _ -> {:trusted_ca, <<>>} end
               ]
             )

    assert_receive {:ssl, ssl}
    assert ssl[:verify] == :verify_peer
    assert ssl[:server_name_indication] == ~c"oauth.example"
    refute Keyword.has_key?(ssl, :verify_fun)
    refute Keyword.has_key?(ssl, :partial_chain)
  end

  defp resolver(addresses), do: fn _host, _timeout -> {:ok, addresses} end
end
