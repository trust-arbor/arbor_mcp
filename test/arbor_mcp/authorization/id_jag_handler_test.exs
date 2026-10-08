defmodule Arbor.MCP.Authorization.IdJagHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Authorization.{IdJag, IdJagHandler, JWT}
  alias Arbor.RPC.LogSummary

  setup do
    idp_key = JWT.generate_rsa_key(size: 2048)
    idp_public = JWT.to_public_key(idp_key)

    {:ok, id_jag} =
      IdJag.create(
        private_key: idp_key,
        issuer: "https://idp.example.com",
        subject: "user123",
        audience: "https://as.example.com",
        resource: "https://mcp.example.com",
        client_id: "my-client",
        scope: "mcp:read"
      )

    trusted_idps = %{
      "https://idp.example.com" => %{
        jwks: [idp_public]
      }
    }

    %{
      idp_key: idp_key,
      idp_public: idp_public,
      id_jag: id_jag,
      trusted_idps: trusted_idps
    }
  end

  describe "handle_grant/1" do
    test "processes a valid ID-JAG", %{id_jag: id_jag, trusted_idps: trusted_idps} do
      assert {:ok, result} =
               IdJagHandler.handle_grant(
                 assertion: id_jag,
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com",
                 trusted_idps: trusted_idps
               )

      assert result.issuer == "https://idp.example.com"
      assert result.subject == "user123"
      assert result.client_id == "my-client"
      assert result.scope == "mcp:read"
      assert result.resource == "https://mcp.example.com"
    end

    test "uses cached JWKS", %{id_jag: id_jag, trusted_idps: trusted_idps, idp_public: idp_public} do
      jwks_cache = %{
        "https://idp.example.com" => [idp_public]
      }

      assert {:ok, result} =
               IdJagHandler.handle_grant(
                 assertion: id_jag,
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com",
                 trusted_idps: trusted_idps,
                 jwks_cache: jwks_cache
               )

      assert result.subject == "user123"
    end

    test "rejects untrusted IdP", %{idp_key: idp_key} do
      issuer = "https://untrusted-idp-#{System.unique_integer([:positive])}.example.com"

      {:ok, id_jag} =
        IdJag.create(
          private_key: idp_key,
          issuer: issuer,
          subject: "user123",
          audience: "https://as.example.com",
          resource: "https://mcp.example.com",
          client_id: "my-client"
        )

      log =
        capture_log([metadata: [:issuer_hash]], fn ->
          assert {:error, {:untrusted_idp, ^issuer}} =
                   IdJagHandler.handle_grant(
                     assertion: id_jag,
                     expected_audience: "https://as.example.com",
                     expected_resource: "https://mcp.example.com",
                     trusted_idps: %{}
                   )
        end)

      refute log =~ issuer
      assert log =~ LogSummary.fingerprint(issuer)
    end

    test "rejects non-ID-JAG assertion", %{idp_key: idp_key, trusted_idps: trusted_idps} do
      # Create a regular JWT
      claims = %{
        "iss" => "https://idp.example.com",
        "sub" => "user123",
        "aud" => "https://as.example.com"
      }

      {:ok, regular_jwt} = JWT.sign(claims, idp_key, typ: "JWT")

      assert {:error, :not_id_jag} =
               IdJagHandler.handle_grant(
                 assertion: regular_jwt,
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com",
                 trusted_idps: trusted_idps
               )
    end

    test "rejects ID-JAG with wrong audience", %{idp_key: idp_key, trusted_idps: trusted_idps} do
      {:ok, id_jag} =
        IdJag.create(
          private_key: idp_key,
          issuer: "https://idp.example.com",
          subject: "user123",
          audience: "https://wrong-as.example.com",
          resource: "https://mcp.example.com",
          client_id: "my-client"
        )

      assert {:error, {:invalid_audience, _}} =
               IdJagHandler.handle_grant(
                 assertion: id_jag,
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com",
                 trusted_idps: trusted_idps
               )
    end

    test "rejects ID-JAG with wrong resource", %{idp_key: idp_key, trusted_idps: trusted_idps} do
      {:ok, id_jag} =
        IdJag.create(
          private_key: idp_key,
          issuer: "https://idp.example.com",
          subject: "user123",
          audience: "https://as.example.com",
          resource: "https://wrong-mcp.example.com",
          client_id: "my-client"
        )

      assert {:error, {:invalid_resource, _}} =
               IdJagHandler.handle_grant(
                 assertion: id_jag,
                 expected_audience: "https://as.example.com",
                 expected_resource: "https://mcp.example.com",
                 trusted_idps: trusted_idps
               )
    end
  end

  describe "fetch_idp_keys/1" do
    test "returns error for non-existent JWKS endpoint" do
      assert {:error, _} = IdJagHandler.fetch_idp_keys("https://nonexistent.example.com/jwks")
    end
  end
end
