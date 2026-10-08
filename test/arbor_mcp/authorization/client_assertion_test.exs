defmodule Arbor.MCP.Authorization.ClientAssertionTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{ClientAssertion, JWT}

  setup do
    rsa_key = JWT.generate_rsa_key(size: 2048)
    %{rsa_key: rsa_key}
  end

  describe "build_assertion/1" do
    test "builds a valid JWT assertion", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      assert is_binary(assertion)

      # Verify the assertion structure
      public_key = JWT.to_public_key(rsa_key)
      assert {:ok, claims} = JWT.verify(assertion, public_key)
      assert claims["iss"] == "my-client"
      assert claims["sub"] == "my-client"
      assert claims["aud"] == "https://auth.example.com/token"
      assert is_integer(claims["exp"])
      assert is_integer(claims["iat"])
      assert is_binary(claims["jti"])
    end

    test "respects custom algorithm and kid", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key,
                 alg: "RS384",
                 kid: "key-1"
               )

      assert {:ok, header} = JWT.peek_header(assertion)
      assert header["alg"] == "RS384"
      assert header["kid"] == "key-1"
    end

    test "respects custom lifetime", %{rsa_key: rsa_key} do
      now = System.system_time(:second)

      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key,
                 lifetime: 60
               )

      public_key = JWT.to_public_key(rsa_key)
      assert {:ok, claims} = JWT.verify(assertion, public_key)
      # Should expire in about 60 seconds
      assert claims["exp"] - now <= 61
      assert claims["exp"] - now >= 59
    end

    test "includes additional claims", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key,
                 additional_claims: %{"custom" => "value"}
               )

      public_key = JWT.to_public_key(rsa_key)
      assert {:ok, claims} = JWT.verify(assertion, public_key)
      assert claims["custom"] == "value"
    end
  end

  describe "build_assertion_params/1" do
    test "returns correct form parameters", %{rsa_key: rsa_key} do
      assert {:ok, params} =
               ClientAssertion.build_assertion_params(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      params_map = Map.new(params)
      assert params_map["client_assertion_type"] == ClientAssertion.assertion_type()
      assert is_binary(params_map["client_assertion"])
      assert params_map["client_id"] == "my-client"
    end
  end

  describe "verify_assertion/3" do
    test "verifies a valid assertion", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      public_key = JWT.to_public_key(rsa_key)

      assert {:ok, claims} =
               ClientAssertion.verify_assertion(assertion, "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 client_jwks: [public_key]
               )

      assert claims["iss"] == "my-client"
      assert claims["sub"] == "my-client"
    end

    test "rejects assertion with wrong client_id", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      public_key = JWT.to_public_key(rsa_key)

      assert {:error, {:invalid_issuer, _}} =
               ClientAssertion.verify_assertion(assertion, "wrong-client",
                 token_endpoint: "https://auth.example.com/token",
                 client_jwks: [public_key]
               )
    end

    test "rejects assertion with wrong token_endpoint audience", %{rsa_key: rsa_key} do
      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      public_key = JWT.to_public_key(rsa_key)

      assert {:error, {:invalid_audience, _}} =
               ClientAssertion.verify_assertion(assertion, "my-client",
                 token_endpoint: "https://wrong.example.com/token",
                 client_jwks: [public_key]
               )
    end

    test "rejects assertion with wrong signing key", %{rsa_key: rsa_key} do
      other_key = JWT.generate_rsa_key(size: 2048)

      assert {:ok, assertion} =
               ClientAssertion.build_assertion(
                 client_id: "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 private_key: rsa_key
               )

      other_pub = JWT.to_public_key(other_key)

      assert {:error, :verification_failed} =
               ClientAssertion.verify_assertion(assertion, "my-client",
                 token_endpoint: "https://auth.example.com/token",
                 client_jwks: [other_pub]
               )
    end

    test "returns error when no keys configured" do
      assert {:error, :no_client_keys_configured} =
               ClientAssertion.verify_assertion("some.jwt.token", "client",
                 token_endpoint: "https://auth.example.com/token"
               )
    end
  end

  describe "assertion_type/0" do
    test "returns the correct assertion type URI" do
      assert ClientAssertion.assertion_type() ==
               "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    end
  end
end
