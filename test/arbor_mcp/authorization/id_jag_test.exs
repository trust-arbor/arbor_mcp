defmodule Arbor.MCP.Authorization.IdJagTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{IdJag, JWT}

  setup do
    idp_key = JWT.generate_rsa_key(size: 2048)
    idp_public = JWT.to_public_key(idp_key)
    %{idp_key: idp_key, idp_public: idp_public}
  end

  describe "create/1" do
    test "creates a valid ID-JAG", %{idp_key: idp_key, idp_public: idp_public} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert is_binary(token)

      # Verify typ header
      assert {:ok, header} = JWT.peek_header(token)
      assert header["typ"] == "oauth-id-jag+jwt"

      # Verify claims
      assert {:ok, claims} = JWT.verify(token, idp_public)
      assert claims["iss"] == "https://idp.example.com"
      assert claims["sub"] == "user123"
      assert claims["aud"] == "https://as.example.com"
      assert claims["resource"] == "https://mcp.example.com"
      assert claims["client_id"] == "my-client"
      assert is_binary(claims["jti"])
      assert is_integer(claims["exp"])
      assert is_integer(claims["iat"])
    end

    test "includes optional scope", %{idp_key: idp_key, idp_public: idp_public} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client",
                 scope: "mcp:read mcp:write"
               )

      assert {:ok, claims} = JWT.verify(token, idp_public)
      assert claims["scope"] == "mcp:read mcp:write"
    end

    test "respects custom lifetime", %{idp_key: idp_key, idp_public: idp_public} do
      now = System.system_time(:second)

      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client",
                 lifetime: 120
               )

      assert {:ok, claims} = JWT.verify(token, idp_public)
      assert claims["exp"] - now <= 121
      assert claims["exp"] - now >= 119
    end
  end

  describe "validate/2" do
    test "validates a valid ID-JAG", %{idp_key: idp_key, idp_public: idp_public} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert {:ok, claims} =
               IdJag.validate(token,
                 idp_keys: [idp_public],
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com"
               )

      assert claims["sub"] == "user123"
    end

    test "rejects ID-JAG with wrong audience", %{idp_key: idp_key, idp_public: idp_public} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert {:error, {:invalid_audience, _}} =
               IdJag.validate(token,
                 idp_keys: [idp_public],
                 expected_audience: "https://wrong-as.example.com",
                 expected_resource: "https://mcp.example.com"
               )
    end

    test "rejects ID-JAG with wrong resource", %{idp_key: idp_key, idp_public: idp_public} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert {:error, {:invalid_resource, _}} =
               IdJag.validate(token,
                 idp_keys: [idp_public],
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://wrong-mcp.example.com"
               )
    end

    test "rejects ID-JAG with wrong signing key", %{idp_key: idp_key} do
      other_key = JWT.generate_rsa_key(size: 2048)
      other_public = JWT.to_public_key(other_key)

      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert {:error, :verification_failed} =
               IdJag.validate(token,
                 idp_keys: [other_public],
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com"
               )
    end

    test "rejects expired ID-JAG", %{idp_key: idp_key, idp_public: idp_public} do
      # Create ID-JAG with 0 lifetime (already expired)
      now = System.system_time(:second)

      claims = %{
        "iss" => "https://idp.example.com",
        "sub" => "user123",
        "aud" => "https://as.example.com",
        "resource" => "https://mcp.example.com",
        "client_id" => "my-client",
        "jti" => JWT.generate_jti(),
        "exp" => now - 60,
        "iat" => now - 120
      }

      assert {:ok, token} = JWT.sign(claims, idp_key, typ: "oauth-id-jag+jwt")

      assert {:error, :token_expired} =
               IdJag.validate(token,
                 idp_keys: [idp_public],
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com"
               )
    end

    test "rejects non-ID-JAG token", %{idp_key: idp_key, idp_public: idp_public} do
      # Create a regular JWT (typ: "JWT")
      claims = %{
        "iss" => "https://idp.example.com",
        "sub" => "user123",
        "aud" => "https://as.example.com",
        "resource" => "https://mcp.example.com",
        "client_id" => "my-client",
        "jti" => JWT.generate_jti(),
        "exp" => System.system_time(:second) + 300,
        "iat" => System.system_time(:second)
      }

      assert {:ok, token} = JWT.sign(claims, idp_key, typ: "JWT")

      assert {:error, {:invalid_typ, _}} =
               IdJag.validate(token,
                 idp_keys: [idp_public],
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com"
               )
    end
  end

  describe "id_jag?/1" do
    test "returns true for ID-JAG tokens", %{idp_key: idp_key} do
      assert {:ok, token} =
               IdJag.create(
                 private_key: idp_key,
                 issuer: "https://idp.example.com",
                 subject: "user123",
                 audience: "https://as.example.com",
                 resource: "https://mcp.example.com",
                 client_id: "my-client"
               )

      assert IdJag.id_jag?(token)
    end

    test "returns false for regular JWTs", %{idp_key: idp_key} do
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, idp_key)
      refute IdJag.id_jag?(token)
    end

    test "returns false for invalid tokens" do
      refute IdJag.id_jag?("not-a-token")
    end
  end

  describe "typ/0" do
    test "returns the correct typ value" do
      assert IdJag.typ() == "oauth-id-jag+jwt"
    end
  end
end
