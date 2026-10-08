defmodule Arbor.MCP.Authorization.EnterpriseFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.EnterpriseFlow

  describe "execute/1" do
    test "returns error when AS discovery fails" do
      config = %{
        id_token: "eyJ...",
        idp_token_endpoint: "https://idp.example.com/token",
        as_issuer: "https://nonexistent-as.example.com"
      }

      assert {:error, {:as_discovery_failed, _}} = EnterpriseFlow.execute(config)
    end

    test "uses explicit AS token endpoint when provided" do
      config = %{
        id_token: "eyJ...",
        idp_token_endpoint: "http://localhost:9999/token",
        as_issuer: "https://as.example.com",
        as_token_endpoint: "http://localhost:9998/token"
      }

      # Should try to exchange at the IdP (will fail at HTTP level)
      result = EnterpriseFlow.execute(config)
      assert {:error, {:request_failed, _}} = result
    end

    test "returns error when missing AS issuer and token endpoint" do
      config = %{
        id_token: "eyJ...",
        idp_token_endpoint: "https://idp.example.com/token"
      }

      assert {:error, :missing_as_issuer} = EnterpriseFlow.execute(config)
    end
  end

  describe "prepare_oidc_auth/1" do
    test "returns error when IdP discovery fails" do
      assert {:error, {:idp_discovery_failed, _}} =
               EnterpriseFlow.prepare_oidc_auth(
                 idp_issuer: "https://nonexistent-idp.example.com",
                 client_id: "my-client",
                 redirect_uri: "https://app.example.com/callback"
               )
    end
  end
end
