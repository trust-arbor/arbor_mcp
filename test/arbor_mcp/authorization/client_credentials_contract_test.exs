defmodule Arbor.MCP.Authorization.ClientCredentialsContractTest do
  # These contracts open HTTP peers and exercise discovery/token I/O. Keep
  # them out of the parallel schema-validation cohort's bounded workers.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.{DiscoveryFlow, FullOAuthFlow, JWT}

  @tag assurance: ["cc.no_anonymous"]
  test "client credentials never falls back to anonymous authentication" do
    config = fixture(["private_key_jwt", "none"])
    assert {:error, _reason} = FullOAuthFlow.execute(config)
    refute_received {:token_request, _, _}
  end

  @tag assurance: ["cc.no_dcr"]
  test "client credentials never dynamically registers a client" do
    config = fixture(["client_secret_basic"]) |> Map.delete(:client_id)
    assert {:error, _reason} = FullOAuthFlow.execute(config)
    refute_received :registration_request
    refute_received {:token_request, _, _}
  end

  @tag assurance: ["cc.jwt_algorithm"]
  test "JWT signing must agree with advertised algorithms before a token request" do
    config =
      fixture(["private_key_jwt"])
      |> Map.merge(%{private_key: JWT.generate_ec_key(), signing_algorithm: "ES256"})

    assert {:error, _reason} = FullOAuthFlow.execute(config)
    refute_received {:token_request, _, _}
  end

  @tag assurance: ["cc.discovery_algorithm"]
  test "dedicated discovery also rejects an unadvertised JWT algorithm" do
    config =
      fixture(["private_key_jwt"])
      |> Map.merge(%{
        auth_method: :private_key_jwt,
        private_key: JWT.generate_ec_key(),
        alg: "ES256"
      })

    assert {:error, _reason} = DiscoveryFlow.execute(config)
    refute_received {:token_request, _, _}
  end

  @tag assurance: ["cc.basic"]
  test "pre-registered Basic credentials obtain a resource-bound access token" do
    config =
      fixture(["client_secret_basic"])
      |> Map.merge(%{client_secret: "fake-secret", scopes: ["mcp:read"]})

    assert {:ok, %{access_token: "fake-token"}} = FullOAuthFlow.execute(config)
    assert_received {:token_request, [header], body}
    assert header == "Basic " <> Base.encode64("pre-registered-app:fake-secret")
    assert body["grant_type"] == "client_credentials"
    assert body["resource"] == config.resource_url
    assert body["scope"] == "mcp:read"
    refute Map.has_key?(body, "client_secret")
    refute_received :registration_request
  end

  @tag assurance: ["cc.resource_mismatch"]
  test "dedicated discovery rejects resource overrides inconsistent with PRM" do
    config =
      fixture(["client_secret_basic"])
      |> Map.merge(%{
        client_secret: "fake-secret",
        auth_method: :client_secret,
        resource: "https://other-resource.example"
      })

    assert {:error, {:resource_mismatch, "https://other-resource.example", expected}} =
             DiscoveryFlow.execute(config)

    assert expected == config.resource_url
    refute_received {:token_request, _, _}
  end

  for {value, label} <- [{"", "empty"}, {nil, "nil"}] do
    @secret value
    @tag assurance: ["cc.discovery.secret.#{label}"]
    test "dedicated discovery rejects a #{label} secret before a token request" do
      config =
        fixture(["client_secret_basic"])
        |> Map.merge(%{client_secret: @secret, auth_method: :client_secret})

      assert {:error, :missing_client_secret} = DiscoveryFlow.execute(config)
      refute_received {:token_request, _, _}
    end
  end

  defp fixture(methods) do
    bypass = Bypass.open()
    parent = self()
    origin = "http://localhost:#{bypass.port}"
    issuer = "https://auth-contract.example"
    resource = "https://resource-contract.example/mcp"

    Bypass.stub(bypass, "POST", "/register", fn conn ->
      send(parent, :registration_request)
      json(conn, 201, %{"client_id" => "registered-app", "client_secret" => "fake-secret"})
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:token_request, Plug.Conn.get_req_header(conn, "authorization"), URI.decode_query(body)}
      )

      json(conn, 200, %{"access_token" => "fake-token", "token_type" => "Bearer"})
    end)

    metadata = fn uri, _address, _opts ->
      body =
        if uri.host == "resource-contract.example" do
          %{"resource" => resource, "authorization_servers" => [issuer]}
        else
          %{
            "issuer" => issuer,
            "authorization_endpoint" => origin <> "/authorize",
            "token_endpoint" => origin <> "/token",
            "registration_endpoint" => origin <> "/register",
            "grant_types_supported" => ["client_credentials"],
            "token_endpoint_auth_methods_supported" => methods,
            "token_endpoint_auth_signing_alg_values_supported" => ["RS256"]
          }
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end

    %{
      resource_url: resource,
      client_id: "pre-registered-app",
      credential_issuer: issuer,
      client_registration: :auto,
      application_type: :native,
      redirect_port: 45_321,
      protocol_version: "2026-07-28",
      metadata_fetch: [
        http_client: metadata,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [origin],
        allow_insecure_loopback: true
      ]
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
