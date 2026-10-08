defmodule Arbor.MCP.Authorization.OIDCDiscoveryTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.OIDCDiscovery

  @moduletag :oauth

  describe "discover/2" do
    test "uses the hardened default client and reports DNS failure" do
      dns = fn _host, _timeout -> {:error, :dns_failed} end

      assert {:error, {:metadata_fetch_error, :dns_failed}} =
               OIDCDiscovery.discover("https://auth.example.com", dns_resolver: dns)
    end

    test "rejects an invalid custom HTTP client" do
      assert {:error, {:metadata_fetch_error, :invalid_options}} =
               OIDCDiscovery.discover("https://auth.example.com", http_client: nil)
    end

    test "requires HTTPS and blocks authorization-server metadata on private DNS" do
      assert {:error, {:metadata_fetch_error, :https_required}} =
               OIDCDiscovery.discover("http://auth.example.com")

      dns = fn _host, _timeout -> {:ok, [{169, 254, 169, 254}]} end
      client = fn _uri, _address, _opts -> flunk("request must not be made") end

      assert {:error, {:metadata_fetch_error, :non_public_address}} =
               OIDCDiscovery.discover("https://auth.example.com",
                 dns_resolver: dns,
                 http_client: client
               )
    end

    test "fetches metadata from OIDC well-known endpoint" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token",
        "userinfo_endpoint" => "https://auth.example.com/userinfo"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: Jason.encode!(metadata)}}
        })

      assert {:ok, ^metadata} =
               discover_with_client("https://auth.example.com", http_client)
    end

    test "falls back to OAuth well-known endpoint when OIDC fails" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" => {:ok, %{status: 404}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 200, body: Jason.encode!(metadata)}}
        })

      assert {:ok, ^metadata} =
               discover_with_client("https://auth.example.com", http_client)
    end

    test "returns error when all endpoints fail" do
      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" => {:ok, %{status: 404}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 500}}
        })

      assert {:error, _reason} = discover_with_client("https://auth.example.com", http_client)
    end

    test "returns error for invalid JSON response" do
      # With multiple discovery URLs tried, the final error is :discovery_failed
      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: "not valid json"}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 200, body: "also not valid json"}}
        })

      # OIDC endpoint returns invalid JSON, which is an error, so it falls
      # back to OAuth endpoint which also returns invalid JSON
      assert {:error, _reason} = discover_with_client("https://auth.example.com", http_client)
    end

    test "returns error when http_client returns error tuple" do
      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" => {:error, :timeout},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:error, :connection_refused}
        })

      assert {:error, _reason} = discover_with_client("https://auth.example.com", http_client)
    end

    test "skips a document whose issuer does not match and uses the next one" do
      foreign = %{
        "issuer" => "https://attacker.example.com",
        "authorization_endpoint" => "https://attacker.example.com/authorize",
        "token_endpoint" => "https://attacker.example.com/token"
      }

      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: Jason.encode!(foreign)}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 200, body: Jason.encode!(metadata)}}
        })

      assert {:ok, ^metadata} = discover_with_client("https://auth.example.com", http_client)
    end

    test "reports the issuer mismatch when no document names the issuer" do
      foreign = %{
        "issuer" => "https://attacker.example.com",
        "authorization_endpoint" => "https://attacker.example.com/authorize",
        "token_endpoint" => "https://attacker.example.com/token"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: Jason.encode!(foreign)}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 404}}
        })

      assert {:error,
              {:issuer_mismatch,
               expected: "https://auth.example.com", actual: "https://attacker.example.com"}} =
               discover_with_client("https://auth.example.com", http_client)
    end

    test "skips a document that carries no issuer" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: Jason.encode!(Map.delete(metadata, "issuer"))}},
          "https://auth.example.com/.well-known/oauth-authorization-server" =>
            {:ok, %{status: 200, body: Jason.encode!(metadata)}}
        })

      assert {:ok, ^metadata} = discover_with_client("https://auth.example.com", http_client)
    end

    test "preserves a trailing slash in exact issuer validation" do
      metadata = %{
        "issuer" => "https://auth.example.com/",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      http_client =
        mock_http_client(%{
          "https://auth.example.com/.well-known/openid-configuration" =>
            {:ok, %{status: 200, body: Jason.encode!(metadata)}}
        })

      assert {:ok, ^metadata} =
               discover_with_client("https://auth.example.com/", http_client)
    end
  end

  describe "validate_metadata/2" do
    test "returns :ok with all required fields and matching issuer" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      assert :ok = OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end

    test "returns error when issuer is missing" do
      metadata = %{
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      assert {:error, :missing_issuer} =
               OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end

    test "returns error when issuer does not match expected" do
      metadata = %{
        "issuer" => "https://other.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      assert {:error,
              {:issuer_mismatch,
               expected: "https://auth.example.com", actual: "https://other.example.com"}} =
               OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end

    test "returns error when authorization_endpoint is missing" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "token_endpoint" => "https://auth.example.com/token"
      }

      assert {:error, {:missing_required_field, "authorization_endpoint"}} =
               OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end

    test "returns error when token_endpoint is missing" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize"
      }

      assert {:error, {:missing_required_field, "token_endpoint"}} =
               OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end

    test "passes with additional optional fields present" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token",
        "userinfo_endpoint" => "https://auth.example.com/userinfo",
        "jwks_uri" => "https://auth.example.com/.well-known/jwks.json"
      }

      assert :ok = OIDCDiscovery.validate_metadata(metadata, "https://auth.example.com")
    end
  end

  describe "oidc_compliant?/1" do
    test "returns true when userinfo_endpoint is present" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "userinfo_endpoint" => "https://auth.example.com/userinfo"
      }

      assert OIDCDiscovery.oidc_compliant?(metadata) == true
    end

    test "returns true when id_token_signing_alg_values_supported is present" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "id_token_signing_alg_values_supported" => ["RS256"]
      }

      assert OIDCDiscovery.oidc_compliant?(metadata) == true
    end

    test "returns true when subject_types_supported is present" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "subject_types_supported" => ["public"]
      }

      assert OIDCDiscovery.oidc_compliant?(metadata) == true
    end

    test "returns false when no OIDC-specific fields are present" do
      metadata = %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token"
      }

      assert OIDCDiscovery.oidc_compliant?(metadata) == false
    end

    test "returns false for empty metadata" do
      assert OIDCDiscovery.oidc_compliant?(%{}) == false
    end
  end

  describe "build_metadata/0" do
    setup do
      original_oauth = Application.get_env(:arbor_mcp, :oauth2_authorization_server_metadata)
      original_oidc = Application.get_env(:arbor_mcp, :oidc_discovery)

      on_exit(fn ->
        if original_oauth do
          Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata, original_oauth)
        else
          Application.delete_env(:arbor_mcp, :oauth2_authorization_server_metadata)
        end

        if original_oidc do
          Application.put_env(:arbor_mcp, :oidc_discovery, original_oidc)
        else
          Application.delete_env(:arbor_mcp, :oidc_discovery)
        end
      end)

      :ok
    end

    test "builds metadata merging base OAuth metadata with OIDC fields" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.example.com",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token"
      )

      Application.put_env(:arbor_mcp, :oidc_discovery,
        userinfo_endpoint: "https://auth.example.com/userinfo",
        jwks_uri: "https://auth.example.com/.well-known/jwks.json",
        id_token_signing_alg_values_supported: ["RS256"],
        subject_types_supported: ["public"],
        claims_supported: ["sub", "name", "email"],
        scopes_supported: ["openid", "profile", "email"]
      )

      metadata = OIDCDiscovery.build_metadata()

      # Base OAuth fields from AuthorizationServerMetadata
      assert metadata["issuer"] == "https://auth.example.com"
      assert metadata["authorization_endpoint"] == "https://auth.example.com/authorize"
      assert metadata["token_endpoint"] == "https://auth.example.com/token"

      # OIDC-specific fields
      assert metadata["userinfo_endpoint"] == "https://auth.example.com/userinfo"
      assert metadata["jwks_uri"] == "https://auth.example.com/.well-known/jwks.json"
      assert metadata["id_token_signing_alg_values_supported"] == ["RS256"]
      assert metadata["subject_types_supported"] == ["public"]
      assert metadata["claims_supported"] == ["sub", "name", "email"]
      assert metadata["scopes_supported"] == ["openid", "profile", "email"]
    end

    test "builds metadata with no OIDC config" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.example.com",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token"
      )

      Application.delete_env(:arbor_mcp, :oidc_discovery)

      metadata = OIDCDiscovery.build_metadata()

      # Base fields should still be present
      assert metadata["issuer"] == "https://auth.example.com"
      assert metadata["authorization_endpoint"] == "https://auth.example.com/authorize"
      assert metadata["token_endpoint"] == "https://auth.example.com/token"

      # OIDC-specific fields should not be present
      refute Map.has_key?(metadata, "userinfo_endpoint")
      refute Map.has_key?(metadata, "id_token_signing_alg_values_supported")
      refute Map.has_key?(metadata, "subject_types_supported")
    end

    test "only includes configured OIDC fields" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.example.com",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token"
      )

      Application.put_env(:arbor_mcp, :oidc_discovery,
        userinfo_endpoint: "https://auth.example.com/userinfo"
      )

      metadata = OIDCDiscovery.build_metadata()

      assert metadata["userinfo_endpoint"] == "https://auth.example.com/userinfo"
      refute Map.has_key?(metadata, "jwks_uri")
      refute Map.has_key?(metadata, "id_token_signing_alg_values_supported")
      refute Map.has_key?(metadata, "subject_types_supported")
      refute Map.has_key?(metadata, "claims_supported")
    end
  end

  # Helper to create a mock HTTP client module that routes responses by URL.
  # Uses an Agent to store the URL-to-response mapping and creates a unique
  # module for each test invocation with a get/1 function.
  defp mock_http_client(url_responses) do
    {:ok, agent} = Agent.start_link(fn -> url_responses end)
    agent_pid = agent

    module_name = :"Arbor.MCP.Test.MockHTTPClient_#{System.unique_integer([:positive])}"

    Module.create(
      module_name,
      quote do
        def get(uri, _address, _opts) do
          url = to_string(uri)
          responses = Agent.get(unquote(agent_pid), & &1)

          case Map.get(responses, url) do
            nil ->
              {:error, {:unexpected_url, url}}

            {:ok, response} when is_map(response) ->
              {:ok, response |> Map.put_new(:headers, []) |> Map.put_new(:body, "")}

            response ->
              response
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module_name
  end

  defp discover_with_client(issuer, http_client) do
    OIDCDiscovery.discover(issuer,
      http_client: http_client,
      dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end
    )
  end
end
