defmodule Arbor.MCP.Authorization.TokenExchangeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.TokenExchange

  describe "exchange/1" do
    test "rejects non-HTTPS endpoint" do
      assert {:error, :https_required} =
               TokenExchange.exchange(
                 token_endpoint: "http://insecure.example.com/token",
                 subject_token: "some-token",
                 subject_token_type: "urn:ietf:params:oauth:token-type:id_token"
               )
    end

    test "allows localhost HTTP for development" do
      # This will fail at the HTTP level but should pass validation
      result =
        TokenExchange.exchange(
          token_endpoint: "http://localhost:19876/token",
          subject_token: "some-token",
          subject_token_type: "urn:ietf:params:oauth:token-type:id_token"
        )

      # Should fail with connection/HTTP error, not validation error
      assert {:error, reason} = result
      refute reason == :https_required
    end
  end

  describe "exchange_id_token_for_id_jag/1" do
    test "rejects non-HTTPS endpoint" do
      assert {:error, :https_required} =
               TokenExchange.exchange_id_token_for_id_jag(
                 token_endpoint: "http://insecure.example.com/token",
                 id_token: "eyJ...",
                 audience: "https://as.example.com"
               )
    end
  end

  describe "constants" do
    test "grant_type/0 returns correct value" do
      assert TokenExchange.grant_type() ==
               "urn:ietf:params:oauth:grant-type:token-exchange"
    end

    test "token_type_access/0 returns correct value" do
      assert TokenExchange.token_type_access() ==
               "urn:ietf:params:oauth:token-type:access_token"
    end

    test "token_type_id/0 returns correct value" do
      assert TokenExchange.token_type_id() ==
               "urn:ietf:params:oauth:token-type:id_token"
    end

    test "token_type_id_jag/0 returns correct value" do
      assert TokenExchange.token_type_id_jag() ==
               "urn:ietf:params:oauth:token-type:id-jag"
    end
  end
end
