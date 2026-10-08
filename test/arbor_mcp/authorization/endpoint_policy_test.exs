defmodule Arbor.MCP.Authorization.EndpointPolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{EndpointPolicy, HTTPClient}

  test "accepts discovered endpoints on the issuer's exact origin" do
    metadata = %{
      "authorization_endpoint" => "https://issuer.example/oauth/authorize",
      "token_endpoint" => "https://issuer.example/oauth/token",
      "jwks_uri" => "https://issuer.example/.well-known/jwks.json"
    }

    assert :ok = EndpointPolicy.validate_metadata(metadata, "https://issuer.example")
  end

  test "rejects cross-origin and insecure discovered endpoints by default" do
    assert {:error, {:invalid_endpoint, "token_endpoint", :cross_origin}} =
             EndpointPolicy.validate_metadata(
               %{"token_endpoint" => "https://attacker.example/token"},
               "https://issuer.example"
             )

    assert {:error, {:invalid_endpoint, "token_endpoint", :invalid_uri}} =
             EndpointPolicy.validate_metadata(
               %{"token_endpoint" => "http://issuer.example/token"},
               "https://issuer.example"
             )
  end

  test "allows only an explicitly listed canonical endpoint origin" do
    metadata = %{"token_endpoint" => "https://tokens.example/token"}

    assert :ok =
             EndpointPolicy.validate_metadata(metadata, "https://issuer.example",
               allowed_endpoint_origins: ["https://tokens.example"]
             )

    assert {:error, :invalid_allowed_endpoint_origin} =
             EndpointPolicy.validate_metadata(metadata, "https://issuer.example",
               allowed_endpoint_origins: ["https://tokens.example/"]
             )
  end

  test "metadata fetch pins the advertised issuer to the requested issuer" do
    body =
      Jason.encode!(%{
        issuer: "https://attacker.example",
        authorization_endpoint: "https://attacker.example/authorize",
        token_endpoint: "https://attacker.example/token"
      })

    request_fun = fn _method, _request, _http_options, _request_options ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
    end

    assert {:error, {:issuer_mismatch, mismatch}} =
             HTTPClient.fetch_server_metadata(
               "https://issuer.example/.well-known/oauth-authorization-server",
               expected_issuer: "https://issuer.example",
               dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request_fun
             )

    assert mismatch[:expected] == "https://issuer.example"
    assert mismatch[:actual] == "https://attacker.example"
  end
end
