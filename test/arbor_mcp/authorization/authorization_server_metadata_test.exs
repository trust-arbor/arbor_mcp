defmodule Arbor.MCP.Authorization.AuthorizationServerMetadataTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.AuthorizationServerMetadata

  @moduletag :oauth

  # Clean up global application config between tests to prevent contamination
  setup do
    on_exit(fn ->
      Application.delete_env(:arbor_mcp, :oauth2_authorization_server_metadata)
    end)

    :ok
  end

  describe "build_metadata/0" do
    test "builds complete metadata from configuration" do
      # Set up test configuration
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.test.com",
        authorization_endpoint: "https://auth.test.com/authorize",
        token_endpoint: "https://auth.test.com/token",
        jwks_uri: "https://auth.test.com/.well-known/jwks.json",
        scopes_supported: ["mcp:read", "mcp:write"],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code"],
        code_challenge_methods_supported: ["S256"],
        introspection_endpoint: "https://auth.test.com/introspect",
        revocation_endpoint: "https://auth.test.com/revoke"
      )

      metadata = AuthorizationServerMetadata.build_metadata()

      # Verify required fields
      assert metadata["issuer"] == "https://auth.test.com"
      assert metadata["authorization_endpoint"] == "https://auth.test.com/authorize"
      assert metadata["token_endpoint"] == "https://auth.test.com/token"

      # Verify optional fields
      assert metadata["jwks_uri"] == "https://auth.test.com/.well-known/jwks.json"
      assert metadata["scopes_supported"] == ["mcp:read", "mcp:write"]
      assert metadata["response_types_supported"] == ["code"]
      assert metadata["grant_types_supported"] == ["authorization_code"]
      assert metadata["code_challenge_methods_supported"] == ["S256"]
      assert metadata["introspection_endpoint"] == "https://auth.test.com/introspect"
      assert metadata["revocation_endpoint"] == "https://auth.test.com/revoke"
    end

    test "builds minimal metadata with only required fields" do
      # Set up minimal configuration
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://minimal.test.com",
        authorization_endpoint: "https://minimal.test.com/auth",
        token_endpoint: "https://minimal.test.com/token"
      )

      metadata = AuthorizationServerMetadata.build_metadata()

      # Verify required fields are present
      assert metadata["issuer"] == "https://minimal.test.com"
      assert metadata["authorization_endpoint"] == "https://minimal.test.com/auth"
      assert metadata["token_endpoint"] == "https://minimal.test.com/token"

      # Verify optional fields are not present
      refute Map.has_key?(metadata, "jwks_uri")
      refute Map.has_key?(metadata, "scopes_supported")
      refute Map.has_key?(metadata, "response_types_supported")
    end

    test "raises ArgumentError when required fields are missing" do
      # Missing issuer
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token"
      )

      assert_raise ArgumentError,
                   ~r/Required OAuth authorization server metadata field issuer/,
                   fn ->
                     AuthorizationServerMetadata.build_metadata()
                   end

      # Missing authorization_endpoint
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://test.com",
        token_endpoint: "https://test.com/token"
      )

      assert_raise ArgumentError,
                   ~r/Required OAuth authorization server metadata field authorization_endpoint/,
                   fn ->
                     AuthorizationServerMetadata.build_metadata()
                   end

      # Missing token_endpoint
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://test.com",
        authorization_endpoint: "https://test.com/auth"
      )

      assert_raise ArgumentError,
                   ~r/Required OAuth authorization server metadata field token_endpoint/,
                   fn ->
                     AuthorizationServerMetadata.build_metadata()
                   end
    end

    test "raises ArgumentError when required fields are not strings" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        # Not a string
        issuer: 12345,
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token"
      )

      assert_raise ArgumentError,
                   ~r/OAuth authorization server metadata field issuer must be a string/,
                   fn ->
                     AuthorizationServerMetadata.build_metadata()
                   end
    end
  end

  describe "validate_config/0" do
    test "validates complete valid configuration" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.test.com",
        authorization_endpoint: "https://auth.test.com/authorize",
        token_endpoint: "https://auth.test.com/token",
        jwks_uri: "https://auth.test.com/.well-known/jwks.json",
        introspection_endpoint: "https://auth.test.com/introspect"
      )

      assert :ok = AuthorizationServerMetadata.validate_config()
    end

    test "validates minimal valid configuration" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://minimal.test.com",
        authorization_endpoint: "https://minimal.test.com/auth",
        token_endpoint: "https://minimal.test.com/token"
      )

      assert :ok = AuthorizationServerMetadata.validate_config()
    end

    test "allows localhost HTTP URLs for development" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "http://localhost:8080",
        authorization_endpoint: "http://127.0.0.1:8080/auth",
        token_endpoint: "http://localhost:8080/token"
      )

      assert :ok = AuthorizationServerMetadata.validate_config()
    end

    test "rejects missing required fields" do
      # Missing issuer
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token"
      )

      assert {:error, {:missing_required_field, :issuer}} =
               AuthorizationServerMetadata.validate_config()

      # Missing authorization_endpoint
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://test.com",
        token_endpoint: "https://test.com/token"
      )

      assert {:error, {:missing_required_field, :authorization_endpoint}} =
               AuthorizationServerMetadata.validate_config()
    end

    test "rejects non-HTTPS URLs for remote endpoints" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        # Non-localhost HTTP
        issuer: "http://insecure.example.com",
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token"
      )

      assert {:error, {:https_required, :issuer, "http"}} =
               AuthorizationServerMetadata.validate_config()
    end

    test "rejects invalid URLs" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "not-a-valid-url",
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token"
      )

      assert {:error, {:https_required, :issuer, nil}} =
               AuthorizationServerMetadata.validate_config()
    end

    test "validates optional endpoint URLs when present" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://test.com",
        authorization_endpoint: "https://test.com/auth",
        token_endpoint: "https://test.com/token",
        # Non-HTTPS optional field
        jwks_uri: "http://insecure.example.com/jwks"
      )

      assert {:error, {:https_required, :jwks_uri, "http"}} =
               AuthorizationServerMetadata.validate_config()
    end
  end

  describe "RFC 8414 compliance" do
    test "includes all RFC 8414 required metadata fields" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://rfc8414.test.com",
        authorization_endpoint: "https://rfc8414.test.com/authorize",
        token_endpoint: "https://rfc8414.test.com/token"
      )

      metadata = AuthorizationServerMetadata.build_metadata()

      # RFC 8414 Section 2 - Required metadata
      assert is_binary(metadata["issuer"])
      assert is_binary(metadata["authorization_endpoint"])
      assert is_binary(metadata["token_endpoint"])

      # Verify URLs are properly formed
      assert String.starts_with?(metadata["issuer"], "https://")
      assert String.starts_with?(metadata["authorization_endpoint"], "https://")
      assert String.starts_with?(metadata["token_endpoint"], "https://")
    end

    test "includes recommended optional fields when configured" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://rfc8414.test.com",
        authorization_endpoint: "https://rfc8414.test.com/authorize",
        token_endpoint: "https://rfc8414.test.com/token",
        jwks_uri: "https://rfc8414.test.com/.well-known/jwks.json",
        scopes_supported: ["mcp:read", "mcp:write", "openid"],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256"]
      )

      metadata = AuthorizationServerMetadata.build_metadata()

      # RFC 8414 Section 2 - Recommended optional metadata
      assert is_binary(metadata["jwks_uri"])
      assert is_list(metadata["scopes_supported"])
      assert is_list(metadata["response_types_supported"])
      assert is_list(metadata["grant_types_supported"])
      assert is_list(metadata["code_challenge_methods_supported"])

      # Verify OAuth 2.1 / PKCE compliance
      assert "S256" in metadata["code_challenge_methods_supported"]
      assert "code" in metadata["response_types_supported"]
    end

    test "supports MCP-specific scopes" do
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://mcp.test.com",
        authorization_endpoint: "https://mcp.test.com/authorize",
        token_endpoint: "https://mcp.test.com/token",
        scopes_supported: ["mcp:read", "mcp:write", "mcp:admin", "mcp:tools:execute"]
      )

      metadata = AuthorizationServerMetadata.build_metadata()

      mcp_scopes = metadata["scopes_supported"]
      assert "mcp:read" in mcp_scopes
      assert "mcp:write" in mcp_scopes
      assert "mcp:admin" in mcp_scopes
      assert "mcp:tools:execute" in mcp_scopes
    end
  end
end
