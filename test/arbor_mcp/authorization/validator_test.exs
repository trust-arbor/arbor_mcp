defmodule Arbor.MCP.Authorization.ValidatorTest do
  use ExUnit.Case

  alias Arbor.MCP.Authorization.Validator

  describe "validate_https_endpoint/1" do
    test "accepts HTTPS URLs" do
      assert Validator.validate_https_endpoint("https://example.com/oauth/authorize") == :ok
      assert Validator.validate_https_endpoint("https://auth.example.com/token") == :ok
    end

    test "accepts HTTP localhost URLs" do
      assert Validator.validate_https_endpoint("http://localhost:8080/auth") == :ok
      assert Validator.validate_https_endpoint("http://127.0.0.1:3000/token") == :ok
    end

    test "rejects HTTP non-localhost URLs" do
      assert Validator.validate_https_endpoint("http://example.com/auth") ==
               {:error, :https_required}

      assert Validator.validate_https_endpoint("http://192.168.1.1/auth") ==
               {:error, :https_required}
    end

    test "rejects invalid URLs" do
      assert Validator.validate_https_endpoint("ftp://example.com") == {:error, :https_required}
      assert Validator.validate_https_endpoint("not-a-url") == {:error, :https_required}
    end
  end

  describe "validate_redirect_uri/1" do
    test "accepts HTTPS redirect URIs" do
      assert Validator.validate_redirect_uri("https://app.example.com/callback") == :ok
    end

    test "accepts HTTP localhost redirect URIs" do
      assert Validator.validate_redirect_uri("http://localhost:8080/callback") == :ok
      assert Validator.validate_redirect_uri("http://127.0.0.1:3000/auth/callback") == :ok
    end

    test "rejects HTTP non-localhost redirect URIs" do
      assert Validator.validate_redirect_uri("http://example.com/callback") ==
               {:error, :invalid_redirect_uri}
    end

    test "rejects invalid redirect URIs" do
      assert Validator.validate_redirect_uri("not-a-uri") == {:error, :invalid_redirect_uri}
    end
  end

  describe "validate_resource_parameters/1" do
    test "accepts missing resource parameters" do
      assert Validator.validate_resource_parameters(%{}) == :ok
      assert Validator.validate_resource_parameters(%{resource: nil}) == :ok
    end

    test "accepts valid single resource URI" do
      config = %{resource: "https://api.example.com"}
      assert Validator.validate_resource_parameters(config) == :ok
    end

    test "accepts valid multiple resource URIs" do
      config = %{resource: ["https://api.example.com", "https://data.example.com"]}
      assert Validator.validate_resource_parameters(config) == :ok
    end

    test "rejects resource URI without scheme" do
      config = %{resource: "api.example.com"}

      assert Validator.validate_resource_parameters(config) ==
               {:error, {:invalid_resource_uri, "missing scheme: api.example.com"}}
    end

    test "rejects resource URI with fragment" do
      config = %{resource: "https://api.example.com#fragment"}

      assert Validator.validate_resource_parameters(config) ==
               {:error,
                {:invalid_resource_uri, "contains fragment: https://api.example.com#fragment"}}
    end

    test "rejects blank resource URI" do
      config = %{resource: ""}

      assert Validator.validate_resource_parameters(config) ==
               {:error, {:invalid_resource_uri, "cannot be a blank string"}}

      config = %{resource: "   "}

      assert Validator.validate_resource_parameters(config) ==
               {:error, {:invalid_resource_uri, "cannot be a blank string"}}
    end

    test "rejects non-string resource URI" do
      config = %{resource: 123}

      assert Validator.validate_resource_parameters(config) ==
               {:error, :invalid_resource_parameter}
    end

    test "rejects invalid resource parameter type" do
      config = %{resource: %{invalid: "type"}}

      assert Validator.validate_resource_parameters(config) ==
               {:error, :invalid_resource_parameter}
    end
  end

  describe "validate_client_credentials/2" do
    test "accepts valid client credentials" do
      assert Validator.validate_client_credentials("client123", "secret456") == :ok
    end

    test "accepts public client (no secret)" do
      assert Validator.validate_client_credentials("client123", nil) == :ok
    end

    test "rejects empty client ID" do
      assert Validator.validate_client_credentials("", "secret") == {:error, :invalid_client_id}

      assert Validator.validate_client_credentials("   ", "secret") ==
               {:error, :invalid_client_id}
    end

    test "rejects non-string client ID" do
      assert Validator.validate_client_credentials(123, "secret") == {:error, :invalid_client_id}
    end

    test "rejects empty client secret when provided" do
      assert Validator.validate_client_credentials("client", "") ==
               {:error, :invalid_client_secret}

      assert Validator.validate_client_credentials("client", "   ") ==
               {:error, :invalid_client_secret}
    end

    test "rejects non-string client secret when provided" do
      assert Validator.validate_client_credentials("client", 123) ==
               {:error, :invalid_client_secret}
    end
  end

  describe "validate_scopes/1" do
    test "accepts valid scope list" do
      assert Validator.validate_scopes(["read", "write", "admin"]) == :ok
      assert Validator.validate_scopes(["mcp:read", "mcp:write"]) == :ok
    end

    test "accepts empty scope list" do
      assert Validator.validate_scopes([]) == :ok
    end

    test "rejects non-list scopes" do
      assert Validator.validate_scopes("read write") == {:error, :invalid_scopes}
      assert Validator.validate_scopes(%{scopes: ["read"]}) == {:error, :invalid_scopes}
    end

    test "rejects scopes with invalid characters" do
      # Contains space
      assert Validator.validate_scopes(["read write"]) == {:error, :invalid_scopes}
      # Contains tab
      assert Validator.validate_scopes(["read\ttab"]) == {:error, :invalid_scopes}
      # Contains newline
      assert Validator.validate_scopes(["read\nnewline"]) == {:error, :invalid_scopes}
    end

    test "rejects non-string scope values" do
      assert Validator.validate_scopes([123, "read"]) == {:error, :invalid_scopes}
      assert Validator.validate_scopes([:read, "write"]) == {:error, :invalid_scopes}
    end
  end

  describe "validate_grant_params/2" do
    test "validates authorization_code grant parameters" do
      valid_params = %{
        code: "auth_code_123",
        redirect_uri: "https://app.com/callback",
        client_id: "client123",
        code_verifier: "verifier456"
      }

      assert Validator.validate_grant_params("authorization_code", valid_params) == :ok
    end

    test "rejects authorization_code grant with missing parameters" do
      incomplete_params = %{
        code: "auth_code_123",
        redirect_uri: "https://app.com/callback"
        # Missing client_id and code_verifier
      }

      assert Validator.validate_grant_params("authorization_code", incomplete_params) ==
               {:error, {:missing_required_params, [:client_id, :code_verifier]}}
    end

    test "validates client_credentials grant parameters" do
      valid_params = %{
        client_id: "client123",
        client_secret: "secret456"
      }

      assert Validator.validate_grant_params("client_credentials", valid_params) == :ok
    end

    test "rejects client_credentials grant with missing parameters" do
      incomplete_params = %{
        client_id: "client123"
        # Missing client_secret
      }

      assert Validator.validate_grant_params("client_credentials", incomplete_params) ==
               {:error, {:missing_required_params, [:client_secret]}}
    end

    test "validates refresh_token grant parameters" do
      valid_params = %{
        refresh_token: "refresh123",
        client_id: "client123"
      }

      assert Validator.validate_grant_params("refresh_token", valid_params) == :ok
    end

    test "rejects unsupported grant types" do
      assert Validator.validate_grant_params("password", %{}) ==
               {:error, {:unsupported_grant_type, "password"}}

      assert Validator.validate_grant_params("implicit", %{}) ==
               {:error, {:unsupported_grant_type, "implicit"}}
    end
  end
end
