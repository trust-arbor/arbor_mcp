defmodule Arbor.MCP.Authorization.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization
  alias Arbor.MCP.Authorization.OAuthFlow

  describe "validate_authorization_response/2" do
    test "accepts a matching RFC 9207 issuer" do
      transaction = transaction("https://auth.example.com")

      assert {:ok, "code-1"} =
               OAuthFlow.validate_authorization_response(
                 %{
                   "code" => "code-1",
                   "state" => "state-1",
                   "iss" => "https://auth.example.com"
                 },
                 transaction
               )
    end

    test "accepts an omitted optional issuer" do
      assert {:ok, "code-1"} =
               OAuthFlow.validate_authorization_response(
                 %{"code" => "code-1", "state" => "state-1"},
                 transaction("https://auth.example.com")
               )
    end

    test "rejects an omitted issuer when the authorization server advertised it as required" do
      assert {:error, :missing_callback_issuer} =
               OAuthFlow.validate_authorization_response(
                 %{"code" => "code-1", "state" => "state-1"},
                 transaction("https://auth.example.com") |> Map.put(:require_issuer, true)
               )
    end

    test "rejects issuer mismatches without URL normalization" do
      for actual <- ["https://other.example.com", "https://auth.example.com/"] do
        assert {:error, {:issuer_mismatch, expected: "https://auth.example.com", actual: ^actual}} =
                 OAuthFlow.validate_authorization_response(
                   %{"code" => "code-1", "state" => "state-1", "iss" => actual},
                   transaction("https://auth.example.com")
                 )
      end
    end

    test "rejects a present issuer when the transaction did not record one" do
      assert {:error, :missing_expected_issuer} =
               OAuthFlow.validate_authorization_response(
                 %{
                   "code" => "code-1",
                   "state" => "state-1",
                   "iss" => "https://auth.example.com"
                 },
                 transaction(nil)
               )
    end

    test "validates state and code before redemption" do
      transaction = transaction("https://auth.example.com")

      assert {:error, :state_mismatch} =
               OAuthFlow.validate_authorization_response(
                 %{"code" => "code-1", "state" => "wrong"},
                 transaction
               )

      assert {:error, :missing_authorization_code} =
               OAuthFlow.validate_authorization_response(
                 %{"state" => "state-1"},
                 transaction
               )
    end
  end

  test "start_authorization_flow/1 records the issuer in transaction state" do
    assert {:ok, _url, state} =
             OAuthFlow.start_authorization_flow(%{
               client_id: "client-1",
               redirect_uri: "http://127.0.0.1:8080/callback",
               authorization_endpoint: "https://auth.example.com/authorize",
               issuer: "https://auth.example.com",
               scopes: []
             })

    assert state.issuer == "https://auth.example.com"
  end

  test "start_authorization_flow/1 records whether RFC 9207 iss is required" do
    assert {:ok, _url, state} =
             OAuthFlow.start_authorization_flow(%{
               client_id: "client-1",
               redirect_uri: "http://127.0.0.1:8080/callback",
               authorization_endpoint: "https://auth.example.com/authorize",
               issuer: "https://auth.example.com",
               require_issuer: true,
               scopes: []
             })

    assert state.require_issuer

    assert {:error, :missing_callback_issuer} =
             OAuthFlow.validate_authorization_response(
               %{"code" => "code-1", "state" => state.state_param},
               state
             )
  end

  test "the authorization facade preserves the configured issuer" do
    assert {:ok, _url, state} =
             Authorization.start_authorization_flow(%{
               client_id: "client-1",
               client_secret: nil,
               authorization_endpoint: "https://auth.example.com/authorize",
               token_endpoint: "https://auth.example.com/token",
               redirect_uri: "http://127.0.0.1:8080/callback",
               issuer: "https://auth.example.com",
               scopes: [],
               additional_params: nil,
               resource: nil
             })

    assert state.issuer == "https://auth.example.com"
  end

  defp transaction(issuer) do
    %{state_param: "state-1", issuer: issuer}
  end
end
