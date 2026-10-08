defmodule Arbor.MCP.Compliance.OAuth21ComplianceTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization
  alias Arbor.MCP.Authorization.TokenManager

  @moduletag :compliance

  @auth_endpoint "https://auth.example.com/authorize"
  @token_endpoint "https://auth.example.com/token"

  # --- Test Data ---

  # --- Tests ---

  describe "OAuth 2.1 Parameter Validation" do
    test "validates HTTPS endpoints are required" do
      # Test various OAuth functions require HTTPS
      http_url = "http://insecure.example.com/token"

      assert {:error, :https_required} =
               Authorization.discover_server_metadata(http_url)

      assert {:error, :https_required} =
               Authorization.client_credentials_flow(%{
                 client_id: "test",
                 client_secret: "secret",
                 token_endpoint: http_url
               })

      assert {:error, :https_required} =
               Authorization.start_authorization_flow(%{
                 client_id: "test",
                 redirect_uri: "https://client.app/callback",
                 authorization_endpoint: http_url,
                 scopes: ["read"]
               })
    end

    test "allows HTTP for localhost development" do
      # These should not raise :https_required errors (though they may fail for other reasons)
      localhost_url = "http://127.0.0.1:65000/nonexistent-endpoint"

      # This will fail with network/connection errors since there's no server,
      # but should pass HTTPS validation (not return {:error, :https_required})
      result =
        Authorization.client_credentials_flow(%{
          client_id: "test",
          client_secret: "secret",
          token_endpoint: localhost_url
        })

      # Should fail with request error, not HTTPS validation error
      # Could be :request_failed, :http_error, etc. - just not :https_required
      assert {:error, {error_type, _}} = result
      assert error_type != :https_required
    end

    test "validates redirect URIs" do
      config = %{
        client_id: "test",
        # Non-localhost HTTP
        redirect_uri: "http://evil.example.com/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"]
      }

      assert {:error, :invalid_redirect_uri} = Authorization.start_authorization_flow(config)
    end
  end

  describe "PKCE (Proof Key for Code Exchange)" do
    test "generates valid PKCE challenge and verifier" do
      {:ok, verifier, challenge} = Authorization.generate_pkce_challenge()

      # RFC 7636 requirements
      assert is_binary(verifier)
      assert is_binary(challenge)
      # Minimum length
      assert byte_size(verifier) >= 43
      # Maximum length
      assert byte_size(verifier) <= 128
      # URL-safe characters
      assert String.match?(verifier, ~r/^[A-Za-z0-9\-\.\_~]+$/)

      # Verify the challenge matches the verifier
      assert :ok = Authorization.verify_pkce_challenge(verifier, challenge)
    end

    test "rejects mismatched PKCE challenge and verifier" do
      {:ok, verifier1, _challenge1} = Authorization.generate_pkce_challenge()
      {:ok, _verifier2, challenge2} = Authorization.generate_pkce_challenge()

      # Verifier1 should not match challenge2
      assert {:error, _} = Authorization.verify_pkce_challenge(verifier1, challenge2)
    end

    test "generates different challenges for different verifiers" do
      {:ok, verifier1, challenge1} = Authorization.generate_pkce_challenge()
      {:ok, verifier2, challenge2} = Authorization.generate_pkce_challenge()

      assert verifier1 != verifier2
      assert challenge1 != challenge2
    end
  end

  describe "Authorization Code Flow URL Generation" do
    test "generates correct authorization URL with all required parameters" do
      config = %{
        client_id: "my-client-id",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["mcp:read", "mcp:write", "offline_access"]
      }

      {:ok, auth_url, state} = Authorization.start_authorization_flow(config)

      # Verify state structure
      assert is_map(state)
      assert is_binary(state.code_verifier)
      assert is_binary(state.state_param)
      assert byte_size(state.code_verifier) >= 43

      # Parse and verify the generated URL
      uri = URI.parse(auth_url)
      assert uri.scheme == "https"
      assert uri.host == "auth.example.com"
      assert uri.path == "/authorize"

      # Verify all required OAuth 2.1 + PKCE parameters
      query = URI.decode_query(uri.query)
      assert query["response_type"] == "code"
      assert query["client_id"] == "my-client-id"
      assert query["redirect_uri"] == "https://client.app/callback"
      assert query["scope"] == "mcp:read mcp:write offline_access"
      assert query["state"] == state.state_param
      assert query["code_challenge_method"] == "S256"
      assert is_binary(query["code_challenge"])

      # Verify PKCE challenge matches verifier
      assert :ok ==
               Authorization.verify_pkce_challenge(state.code_verifier, query["code_challenge"])
    end

    test "includes additional parameters when specified" do
      config = %{
        client_id: "test-client",
        redirect_uri: "https://app.example.com/auth/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"],
        additional_params: %{
          "prompt" => "consent",
          "access_type" => "offline"
        }
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      # Additional parameters should be included
      assert query["prompt"] == "consent"
      assert query["access_type"] == "offline"
    end

    test "validates authorization endpoint and redirect URI" do
      # Test HTTPS requirement for authorization endpoint
      http_config = %{
        client_id: "test",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: "http://insecure.com/auth",
        scopes: ["read"]
      }

      assert {:error, :https_required} = Authorization.start_authorization_flow(http_config)

      # Test redirect URI validation (non-localhost HTTP not allowed)
      bad_redirect_config = %{
        client_id: "test",
        redirect_uri: "http://evil.com/steal-tokens",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"]
      }

      assert {:error, :invalid_redirect_uri} =
               Authorization.start_authorization_flow(bad_redirect_config)
    end
  end

  describe "TokenManager Core Functionality" do
    setup do
      auth_config = %{
        client_id: "test-client",
        client_secret: "test-secret",
        token_endpoint: @token_endpoint,
        # 5 minutes
        refresh_window: 300
      }

      # Create a token that expires in the future
      initial_token = %{
        "access_token" => "valid-access-token",
        "refresh_token" => "valid-refresh-token",
        # 2 hours
        "expires_in" => 7200,
        "token_type" => "Bearer",
        "scope" => "mcp:read mcp:write"
      }

      {:ok, manager} =
        TokenManager.start_link(auth_config: auth_config, initial_token: initial_token)

      on_exit(fn ->
        if Process.alive?(manager) do
          GenServer.stop(manager)
        end
      end)

      {:ok, manager: manager}
    end

    test "stores and retrieves valid tokens", %{manager: manager} do
      # Should return the current valid token
      {:ok, token} = TokenManager.get_token(manager)
      assert token == "valid-access-token"

      # Should return full token information
      {:ok, token_info} = TokenManager.get_token_info(manager)
      assert token_info.access_token == "valid-access-token"
      assert token_info.token_type == "Bearer"
      assert token_info.scope == "mcp:read mcp:write"
      assert is_struct(token_info.expires_at, DateTime)
    end

    test "handles token subscription and notifications", %{manager: manager} do
      # Subscribe to token updates
      :ok = TokenManager.subscribe(manager)

      # Set a new token
      new_token = %{
        "access_token" => "new-token-123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      }

      :ok = TokenManager.set_token(manager, new_token)

      # Should receive notification
      assert_receive {:token_updated, ^manager, token_info}, 1000
      assert token_info.access_token == "new-token-123"

      # Unsubscribe
      :ok = TokenManager.unsubscribe(manager)

      # Set another token - should not receive notification
      another_token = %{"access_token" => "another-token", "expires_in" => 3600}
      :ok = TokenManager.set_token(manager, another_token)

      refute_receive {:token_updated, ^manager, _}, 500
    end

    test "validates token expiration logic", %{manager: manager} do
      # Set a token that's already expired
      expired_token = %{
        "access_token" => "expired-token",
        # Already expired
        "expires_in" => -1
      }

      :ok = TokenManager.set_token(manager, expired_token)
      # Give time for processing
      Process.sleep(50)

      # Should return error for expired token
      assert {:error, :token_expired} = TokenManager.get_token(manager)
    end

    test "manages refresh timers correctly", %{manager: manager} do
      # Set a token that expires soon (should trigger refresh timer)
      short_lived_token = %{
        "access_token" => "short-lived-token",
        "refresh_token" => "refresh-token",
        # 10 seconds
        "expires_in" => 10
      }

      :ok = TokenManager.set_token(manager, short_lived_token)
      # Give time for timer setup
      Process.sleep(50)

      # The manager should have scheduled a refresh
      # We can't easily test the timer without mocking, but we can verify
      # the token is stored correctly
      {:ok, token} = TokenManager.get_token(manager)
      assert token == "short-lived-token"
    end
  end

  describe "OAuth 2.1 Compliance and Security" do
    test "validates OAuth 2.1 scopes format" do
      # Test that scopes are properly formatted in authorization URLs
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["mcp:read", "mcp:write", "offline_access"]
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      # Scopes should be space-separated per OAuth 2.1 spec
      assert query["scope"] == "mcp:read mcp:write offline_access"
    end

    test "enforces state parameter for CSRF protection" do
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"]
      }

      {:ok, auth_url, state} = Authorization.start_authorization_flow(config)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      # State parameter must be present and match
      assert query["state"] == state.state_param
      assert is_binary(state.state_param)
      assert byte_size(state.state_param) > 0
    end

    test "validates MCP-specific scope patterns" do
      # MCP typically uses resource:action pattern for scopes
      mcp_scopes = ["mcp:read", "mcp:write", "mcp:admin", "mcp:tools:execute"]

      config = %{
        client_id: "mcp-client",
        redirect_uri: "https://mcp.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: mcp_scopes
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      assert query["scope"] == "mcp:read mcp:write mcp:admin mcp:tools:execute"
    end

    test "ensures PKCE method is S256 (most secure)" do
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"]
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      # OAuth 2.1 recommends S256 over 'plain'
      assert query["code_challenge_method"] == "S256"
    end

    test "validates URL encoding of parameters" do
      config = %{
        client_id: "client with spaces",
        redirect_uri: "https://app.example.com/callback?param=value",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read write"]
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      # URL should be properly encoded (Elixir URI.encode_query uses + for spaces)
      assert String.contains?(auth_url, "client_id=client+with+spaces")

      assert String.contains?(
               auth_url,
               "redirect_uri=https%3A%2F%2Fapp.example.com%2Fcallback%3Fparam%3Dvalue"
             )

      assert String.contains?(auth_url, "scope=read+write")
    end
  end

  describe "RFC 8707 Resource Indicators" do
    @resource1 "https://api.example.com/resource1"
    @resource2 "https://api.example.com/resource2"

    test "includes single resource parameter in authorization URL" do
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"],
        resource: @resource1
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)
      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)

      assert query["resource"] == @resource1
    end

    test "includes multiple resource parameters in authorization URL" do
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"],
        resource: [@resource1, @resource2]
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)

      # RFC 8707 specifies repeating the resource parameter for multiple values
      assert String.contains?(auth_url, "resource=" <> URI.encode_www_form(@resource1))
      assert String.contains?(auth_url, "resource=" <> URI.encode_www_form(@resource2))
    end

    test "validates resource URI format" do
      # Must be an absolute URI
      assert {:error, {:invalid_resource_uri, _}} =
               Authorization.start_authorization_flow(%{
                 client_id: "test",
                 redirect_uri: "https://client.app/callback",
                 authorization_endpoint: @auth_endpoint,
                 scopes: ["read"],
                 resource: "not-an-absolute-uri"
               })

      # Cannot contain a fragment
      assert {:error, {:invalid_resource_uri, _}} =
               Authorization.start_authorization_flow(%{
                 client_id: "test",
                 redirect_uri: "https://client.app/callback",
                 authorization_endpoint: @auth_endpoint,
                 scopes: ["read"],
                 resource: "https://example.com/path#fragment"
               })

      # All URIs in a list must be valid
      assert {:error, {:invalid_resource_uri, _}} =
               Authorization.start_authorization_flow(%{
                 client_id: "test",
                 redirect_uri: "https://client.app/callback",
                 authorization_endpoint: @auth_endpoint,
                 scopes: ["read"],
                 resource: [@resource1, "invalid-uri"]
               })

      # Must be a string or list of strings
      assert {:error, :invalid_resource_parameter} =
               Authorization.start_authorization_flow(%{
                 client_id: "test",
                 redirect_uri: "https://client.app/callback",
                 authorization_endpoint: @auth_endpoint,
                 scopes: ["read"],
                 resource: %{uri: @resource1}
               })
    end

    test "includes resource parameter in token exchange request" do
      # This test verifies that the resource parameter passes validation and a
      # request is attempted. It cannot verify the contents of the request body
      # without a mechanism to mock HTTP requests.
      params = %{
        code: "auth_code",
        code_verifier: String.duplicate("v", 43),
        client_id: "test-client",
        redirect_uri: "http://localhost/callback",
        token_endpoint: "http://localhost:65001/token",
        resource: @resource1
      }

      result = Authorization.exchange_code_for_token(params)
      assert {:error, {error_type, _}} = result
      refute error_type == :invalid_resource_uri
      refute error_type == :invalid_resource_parameter
    end

    test "includes resource parameter in client credentials request" do
      # This test verifies that the resource parameter passes validation and a
      # request is attempted.
      params = %{
        client_id: "test-client",
        client_secret: "secret",
        token_endpoint: "http://localhost:65002/token",
        resource: [@resource1, @resource2]
      }

      result = Authorization.client_credentials_flow(params)
      assert {:error, {error_type, _}} = result
      refute error_type == :invalid_resource_uri
      refute error_type == :invalid_resource_parameter
    end

    test "includes resource parameter in token refresh request" do
      # This test verifies that the resource parameter passes validation and a
      # request is attempted via the generic token_request function.
      params = %{
        refresh_token: "rt-123",
        client_id: "test-client",
        token_endpoint: "http://localhost:65003/token",
        resource: @resource1
      }

      result = Authorization.token_request(params)
      assert {:error, {error_type, _}} = result
      refute error_type == :invalid_resource_uri
      refute error_type == :invalid_resource_parameter
    end

    test "works correctly without resource parameter (backwards compatibility)" do
      # Authorization flow
      config = %{
        client_id: "test-client",
        redirect_uri: "https://client.app/callback",
        authorization_endpoint: @auth_endpoint,
        scopes: ["read"]
      }

      {:ok, auth_url, _state} = Authorization.start_authorization_flow(config)
      refute String.contains?(auth_url, "resource=")

      # Client credentials flow
      params = %{
        client_id: "test-client",
        client_secret: "secret",
        token_endpoint: "http://localhost:65004/token"
      }

      result = Authorization.client_credentials_flow(params)
      assert {:error, {error_type, _reason}} = result
      # Should be a request error, not a validation error
      assert error_type == :request_failed
    end
  end
end
