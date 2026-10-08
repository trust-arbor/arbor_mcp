defmodule Arbor.MCP.Authorization.MetadataFetcherTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.MetadataFetcher

  @public_v4 {93, 184, 216, 34}
  @second_public_v4 {1, 1, 1, 1}

  test "requires a credential-free HTTPS URL" do
    assert {:error, {:metadata_fetch_error, :https_required}} =
             MetadataFetcher.validate_url("http://metadata.example/document")

    assert {:error, {:metadata_fetch_error, :userinfo_forbidden}} =
             MetadataFetcher.validate_url("https://user:secret@metadata.example/document")

    assert {:error, {:metadata_fetch_error, :fragment_forbidden}} =
             MetadataFetcher.validate_url("https://metadata.example/document#secret")

    assert :ok = MetadataFetcher.validate_url("https://metadata.example/document?version=1")
  end

  test "permits HTTP loopback metadata only with an explicit option" do
    assert {:error, {:metadata_fetch_error, :https_required}} =
             MetadataFetcher.validate_url("http://localhost/document")

    assert :ok =
             MetadataFetcher.validate_url("http://localhost/document",
               allow_insecure_loopback: true
             )

    assert {:error, {:metadata_fetch_error, :https_required}} =
             MetadataFetcher.validate_url("http://metadata.example/document",
               allow_insecure_loopback: true
             )

    client = fn uri, address, _opts ->
      assert uri.host == "localhost"
      assert address == {127, 0, 0, 1}
      response(200, "{}")
    end

    assert {:ok, %{status: 200}} =
             MetadataFetcher.fetch("http://localhost/document",
               allow_insecure_loopback: true,
               dns_resolver: fn _host, _timeout -> {:ok, [{127, 0, 0, 1}]} end,
               http_client: client
             )

    assert {:error, {:metadata_fetch_error, :non_public_address}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               allow_insecure_loopback: true,
               dns_resolver: fn _host, _timeout -> {:ok, [{127, 0, 0, 1}]} end,
               http_client: client
             )
  end

  test "rejects literal and resolved non-public addresses before requesting" do
    parent = self()
    client = fn _uri, _address, _opts -> send(parent, :requested) end

    for address <- [
          {10, 0, 0, 1},
          {127, 0, 0, 1},
          {169, 254, 169, 254},
          {172, 16, 0, 1},
          {192, 168, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1}
        ] do
      dns = fn _host, _timeout -> {:ok, [address]} end

      assert {:error, {:metadata_fetch_error, :non_public_address}} =
               MetadataFetcher.fetch("https://metadata.example/document",
                 dns_resolver: dns,
                 http_client: client
               )
    end

    refute_received :requested
  end

  test "rejects a mixed public and private DNS answer" do
    dns = fn _host, _timeout -> {:ok, [@public_v4, {127, 0, 0, 1}]} end
    client = fn _uri, _address, _opts -> flunk("request must not be made") end

    assert {:error, {:metadata_fetch_error, :non_public_address}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: dns,
               http_client: client
             )
  end

  test "re-resolves and pins each same-origin redirect hop" do
    {:ok, dns_calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    dns = fn "metadata.example", _timeout ->
      call = Agent.get_and_update(dns_calls, fn count -> {count, count + 1} end)
      if call == 0, do: {:ok, [@public_v4]}, else: {:ok, [@second_public_v4]}
    end

    client = fn uri, address, opts ->
      send(parent, {:request, to_string(uri), address, opts[:request_headers]})

      case uri.path do
        "/start" -> response(302, "", [{"location", "/final"}])
        "/final" -> response(200, ~s({"issuer":"https://metadata.example"}))
      end
    end

    assert {:ok, %{status: 200, final_url: "https://metadata.example/final"}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: client
             )

    assert_received {:request, "https://metadata.example/start", @public_v4, headers}
    assert_received {:request, "https://metadata.example/final", @second_public_v4, ^headers}
    assert Agent.get(dns_calls, & &1) == 2

    assert headers == [
             {"accept", "application/json"},
             {"accept-encoding", "identity"},
             {"user-agent", "ex_mcp-oauth-metadata"}
           ]

    refute Enum.any?(headers, fn {name, _value} ->
             String.downcase(name) in ["authorization", "cookie", "proxy-authorization"]
           end)
  end

  test "blocks cross-origin redirects unless the exact origin is allowed" do
    parent = self()

    dns = fn host, _timeout ->
      send(parent, {:resolved, host})
      {:ok, [@public_v4]}
    end

    client = fn uri, _address, _opts ->
      case uri.host do
        "metadata.example" -> response(302, "", [{"location", "https://other.example/final"}])
        "other.example" -> response(200, "{}")
      end
    end

    assert {:error, {:metadata_fetch_error, :cross_origin_redirect}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: client
             )

    assert_received {:resolved, "metadata.example"}
    refute_received {:resolved, "other.example"}

    assert {:ok, %{final_url: "https://other.example/final"}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: client,
               allowed_redirect_origins: ["https://other.example"]
             )

    assert_received {:resolved, "metadata.example"}
    assert_received {:resolved, "other.example"}
  end

  test "revalidates an explicitly allowed cross-origin redirect and blocks private DNS" do
    dns = fn
      "metadata.example", _timeout -> {:ok, [@public_v4]}
      "other.example", _timeout -> {:ok, [{169, 254, 169, 254}]}
    end

    client = fn _uri, _address, _opts ->
      response(302, "", [{"location", "https://other.example/final"}])
    end

    assert {:error, {:metadata_fetch_error, :non_public_address}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: client,
               allowed_redirect_origins: ["https://other.example"]
             )
  end

  test "rejects HTTPS downgrade redirects, redirect cycles, and redirect overflow" do
    dns = public_dns()

    downgrade = fn _uri, _address, _opts ->
      response(302, "", [{"location", "http://metadata.example/final"}])
    end

    assert {:error, {:metadata_fetch_error, :https_required}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: downgrade
             )

    cycle = fn uri, _address, _opts ->
      location = if uri.path == "/a", do: "/b", else: "/a"
      response(302, "", [{"location", location}])
    end

    assert {:error, {:metadata_fetch_error, :redirect_cycle}} =
             MetadataFetcher.fetch("https://metadata.example/a",
               dns_resolver: dns,
               http_client: cycle
             )

    assert {:error, {:metadata_fetch_error, :redirect_limit}} =
             MetadataFetcher.fetch("https://metadata.example/a",
               dns_resolver: dns,
               http_client: cycle,
               max_redirects: 0
             )
  end

  test "rejects duplicate or missing redirect locations" do
    dns = public_dns()

    for headers <- [[], [{"location", "/one"}, {"Location", "/two"}]] do
      client = fn _uri, _address, _opts -> response(302, "", headers) end

      assert {:error, {:metadata_fetch_error, reason}} =
               MetadataFetcher.fetch("https://metadata.example/start",
                 dns_resolver: dns,
                 http_client: client
               )

      assert reason in [:missing_redirect_location, :invalid_redirect]
    end
  end

  test "bounds individual, compressed, and aggregate responses" do
    dns = public_dns()

    oversized = fn _uri, _address, _opts -> response(200, "12345") end

    assert {:error, {:metadata_fetch_error, :response_too_large}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: dns,
               http_client: oversized,
               max_response_bytes: 4
             )

    compressed = fn _uri, _address, _opts ->
      response(200, "{}", [{"content-encoding", "gzip"}])
    end

    assert {:error, {:metadata_fetch_error, :compressed_response}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: dns,
               http_client: compressed
             )

    redirects = fn uri, _address, _opts ->
      if uri.path == "/start",
        do: response(302, "12345", [{"location", "/final"}]),
        else: response(200, "123456")
    end

    assert {:error, {:metadata_fetch_error, :aggregate_response_too_large}} =
             MetadataFetcher.fetch("https://metadata.example/start",
               dns_resolver: dns,
               http_client: redirects,
               max_aggregate_bytes: 10
             )
  end

  test "bounds DNS resolvers and custom clients that ignore their timeout" do
    slow_dns = fn _host, _timeout ->
      Process.sleep(100)
      {:ok, [@public_v4]}
    end

    assert {:error, {:metadata_fetch_error, :dns_timeout}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: slow_dns,
               dns_timeout_ms: 5
             )

    slow_client = fn _uri, _address, _opts ->
      Process.sleep(100)
      response(200, "{}")
    end

    assert {:error, {:metadata_fetch_error, :request_timeout}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: public_dns(),
               http_client: slow_client,
               connect_timeout_ms: 0,
               request_timeout_ms: 5
             )
  end

  test "contains crashes from custom DNS resolvers and HTTP clients" do
    crashing_dns = fn _host, _timeout -> raise "resolver crashed" end

    assert {:error, {:metadata_fetch_error, :dns_failed}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: crashing_dns
             )

    crashing_client = fn _uri, _address, _opts -> exit(:client_crashed) end

    assert {:error, {:metadata_fetch_error, :fetch_failed}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: public_dns(),
               http_client: crashing_client
             )
  end

  test "rejects legacy URL-only clients that cannot honor address pinning" do
    legacy_client = Module.concat(__MODULE__, LegacyClient)

    assert {:error, {:metadata_fetch_error, :invalid_options}} =
             MetadataFetcher.fetch("https://metadata.example/document",
               dns_resolver: public_dns(),
               http_client: legacy_client
             )
  end

  defmodule LegacyClient do
    def get(_url), do: response(200, "{}")

    defp response(status, body), do: {:ok, %{status: status, headers: [], body: body}}
  end

  defp public_dns do
    fn _host, _timeout -> {:ok, [@public_v4]} end
  end

  defp response(status, body, headers \\ []) do
    {:ok, %{status: status, headers: headers, body: body}}
  end
end
