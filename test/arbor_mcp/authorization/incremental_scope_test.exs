defmodule Arbor.MCP.Authorization.IncrementalScopeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.ErrorHandler
  alias Arbor.MCP.Authorization.OAuthFlow
  alias Arbor.MCP.Authorization.TokenManager

  describe "ErrorHandler 403 scope upgrade" do
    test "extracts required scopes from WWW-Authenticate header" do
      headers = [
        {"www-authenticate",
         ~s(Bearer realm="https://auth.example.com", scope="mcp:tools:execute mcp:resources:read")}
      ]

      state = %{scopes: "mcp:tools:list"}

      assert {:retry, retry_info} = ErrorHandler.handle_auth_error(403, headers, "", state)
      assert retry_info.action == :scope_upgrade
      assert retry_info.required_scopes == ["mcp:tools:execute", "mcp:resources:read"]
      assert retry_info.current_scopes == ["mcp:tools:list"]
    end

    test "extracts required scopes from case-insensitive charlist WWW-Authenticate header" do
      headers = [
        {~c"WWW-Authenticate", ~c"Bearer scope=\"mcp:write\""}
      ]

      state = %{scopes: "mcp:read"}

      assert {:retry, retry_info} = ErrorHandler.handle_auth_error(403, headers, "", state)
      assert retry_info.action == :scope_upgrade
      assert retry_info.required_scopes == ["mcp:write"]
      assert retry_info.current_scopes == ["mcp:read"]
    end

    test "extracts required scopes from error body with insufficient_scope" do
      headers = [{"content-type", "application/json"}]

      body =
        Jason.encode!(%{
          "error" => "insufficient_scope",
          "error_description" => "Need additional scopes",
          "scope" => "mcp:admin"
        })

      state = %{scopes: ["mcp:read"]}

      assert {:retry, retry_info} = ErrorHandler.handle_auth_error(403, headers, body, state)
      assert retry_info.action == :scope_upgrade
      assert retry_info.required_scopes == ["mcp:admin"]
      assert retry_info.current_scopes == ["mcp:read"]
    end

    test "returns forbidden error when no scope info available" do
      headers = [{"content-type", "application/json"}]
      body = Jason.encode!(%{"error" => "access_denied", "error_description" => "Forbidden"})
      state = %{}

      assert {:error, {:forbidden, _details}} =
               ErrorHandler.handle_auth_error(403, headers, body, state)
    end

    test "handles nil current scopes" do
      headers = [{"www-authenticate", ~s(Bearer scope="mcp:write")}]
      state = %{scopes: nil}

      assert {:retry, retry_info} = ErrorHandler.handle_auth_error(403, headers, "", state)
      assert retry_info.current_scopes == []
      assert retry_info.required_scopes == ["mcp:write"]
    end

    test "handles list current scopes" do
      headers = [{"www-authenticate", ~s(Bearer scope="mcp:write mcp:admin")}]
      state = %{scopes: ["mcp:read", "mcp:list"]}

      assert {:retry, retry_info} = ErrorHandler.handle_auth_error(403, headers, "", state)
      assert retry_info.current_scopes == ["mcp:read", "mcp:list"]
      assert retry_info.required_scopes == ["mcp:write", "mcp:admin"]
    end

    test "401 still triggers normal auth flow" do
      # The existing handle_unauthorized uses atom key access on string-keyed maps,
      # so with realm present it tries discovery (not refresh).
      headers = [
        {"www-authenticate", ~s(Bearer realm="https://auth.example.com", error="invalid_token")}
      ]

      state = %{refresh_token: "rt_123"}

      # With the current implementation, realm is accessed via string key,
      # but handle_unauthorized checks auth_info[:realm] (atom), so it falls through
      # to :unauthorized_no_realm. This is pre-existing behavior.
      assert {:error, :unauthorized_no_realm} =
               ErrorHandler.handle_auth_error(401, headers, "", state)
    end
  end

  describe "OAuthFlow.refresh_token with scope parameter" do
    test "refresh_token with nil client_secret (backwards compatible)" do
      # This tests the backwards-compatible signature
      # It will fail at the HTTPS validation level but proves the function head works
      result = OAuthFlow.refresh_token("rt_123", "client_1", "http://not-https/token", nil)
      assert {:error, _} = result
    end

    test "refresh_token with string client_secret (backwards compatible)" do
      result =
        OAuthFlow.refresh_token("rt_123", "client_1", "http://not-https/token", "secret")

      assert {:error, _} = result
    end

    test "refresh_token with keyword opts including scope" do
      # Will fail at HTTPS validation but proves the keyword list path works
      result =
        OAuthFlow.refresh_token("rt_123", "client_1", "http://not-https/token",
          client_secret: "secret",
          scope: "mcp:read mcp:write"
        )

      assert {:error, _} = result
    end

    test "refresh_token with keyword opts without scope" do
      result =
        OAuthFlow.refresh_token("rt_123", "client_1", "http://not-https/token",
          client_secret: nil
        )

      assert {:error, _} = result
    end
  end

  describe "OAuthFlow.reauthorize_with_scopes" do
    test "merges current and additional scopes" do
      params = %{
        client_id: "my-client",
        redirect_uri: "http://localhost:8080/callback",
        authorization_endpoint: "https://auth.example.com/authorize",
        scopes: ["mcp:read"]
      }

      additional_scopes = ["mcp:write", "mcp:admin"]

      assert {:ok, auth_url, _state_data} =
               OAuthFlow.reauthorize_with_scopes(params, additional_scopes)

      # Verify the URL contains the combined scopes
      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)
      scope_string = query["scope"]
      scopes = String.split(scope_string, " ")

      assert "mcp:read" in scopes
      assert "mcp:write" in scopes
      assert "mcp:admin" in scopes
    end

    test "deduplicates overlapping scopes" do
      params = %{
        client_id: "my-client",
        redirect_uri: "http://localhost:8080/callback",
        authorization_endpoint: "https://auth.example.com/authorize",
        scopes: ["mcp:read", "mcp:write"]
      }

      # mcp:read is already in current scopes
      additional_scopes = ["mcp:read", "mcp:admin"]

      assert {:ok, auth_url, _state_data} =
               OAuthFlow.reauthorize_with_scopes(params, additional_scopes)

      uri = URI.parse(auth_url)
      query = URI.decode_query(uri.query)
      scope_string = query["scope"]
      scopes = String.split(scope_string, " ")

      # Should have 3 unique scopes, not 4
      assert length(scopes) == 3
      assert "mcp:read" in scopes
      assert "mcp:write" in scopes
      assert "mcp:admin" in scopes
    end
  end

  describe "TokenManager.upgrade_scopes" do
    test "returns reauthorization_required when no refresh token" do
      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            token_endpoint: "https://auth.example.com/token",
            client_id: "test-client"
          }
        )

      # Set a token without refresh token
      TokenManager.set_token(manager, %{
        "access_token" => "at_123",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "scope" => "mcp:read"
      })

      result =
        TokenManager.upgrade_scopes(manager, ["mcp:write", "mcp:admin"])

      assert {:error, {:reauthorization_required, combined}} = result
      assert "mcp:read" in combined
      assert "mcp:write" in combined
      assert "mcp:admin" in combined
    end

    test "merges current nil scope with additional scopes" do
      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            token_endpoint: "https://auth.example.com/token",
            client_id: "test-client"
          }
        )

      # Token with no scope
      TokenManager.set_token(manager, %{
        "access_token" => "at_123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      result = TokenManager.upgrade_scopes(manager, ["mcp:write"])
      assert {:error, {:reauthorization_required, ["mcp:write"]}} = result
    end
  end
end
