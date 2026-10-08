defmodule Arbor.MCP.Authorization.JWTTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.JWT

  setup do
    rsa_key = JWT.generate_rsa_key(size: 2048)
    ec_key = JWT.generate_ec_key(curve: "P-256")
    %{rsa_key: rsa_key, ec_key: ec_key}
  end

  describe "load_key/1" do
    test "loads a JWK from a map with string keys", %{rsa_key: rsa_key} do
      jwk_map = JWT.to_map(rsa_key)
      assert {:ok, _jwk} = JWT.load_key(jwk_map)
    end

    test "loads a JWK from a map with atom keys", %{rsa_key: rsa_key} do
      jwk_map = JWT.to_map(rsa_key)
      atom_map = Map.new(jwk_map, fn {k, v} -> {String.to_atom(k), v} end)
      assert {:ok, _jwk} = JWT.load_key(atom_map)
    end

    test "loads a JWK from a PEM string", %{rsa_key: rsa_key} do
      {_type, pem} = JOSE.JWK.to_pem(rsa_key)
      assert {:ok, _jwk} = JWT.load_key(pem)
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_key_format} = JWT.load_key(12345)
      assert {:error, :invalid_key_format} = JWT.load_key("not a pem")
    end

    test "returns error for file that doesn't exist" do
      assert {:error, {:file_read_error, :enoent}} = JWT.load_key({:pem_file, "/nonexistent"})
    end
  end

  describe "generate_rsa_key/1" do
    test "generates an RSA key pair" do
      jwk = JWT.generate_rsa_key()
      map = JWT.to_map(jwk)
      assert map["kty"] == "RSA"
    end
  end

  describe "generate_ec_key/1" do
    test "generates an EC key pair with default curve" do
      jwk = JWT.generate_ec_key()
      map = JWT.to_map(jwk)
      assert map["kty"] == "EC"
      assert map["crv"] == "P-256"
    end

    test "generates an EC key pair with specified curve" do
      jwk = JWT.generate_ec_key(curve: "P-384")
      map = JWT.to_map(jwk)
      assert map["crv"] == "P-384"
    end
  end

  describe "to_public_key/1" do
    test "extracts public key from RSA private key", %{rsa_key: rsa_key} do
      pub = JWT.to_public_key(rsa_key)
      pub_map = JWT.to_map(pub)
      assert pub_map["kty"] == "RSA"
      # Public key should not have private components
      refute Map.has_key?(pub_map, "d")
    end

    test "extracts public key from EC private key", %{ec_key: ec_key} do
      pub = JWT.to_public_key(ec_key)
      pub_map = JWT.to_map(pub)
      assert pub_map["kty"] == "EC"
      refute Map.has_key?(pub_map, "d")
    end
  end

  describe "sign/3 and verify/2" do
    test "round-trip with RSA key", %{rsa_key: rsa_key} do
      claims = %{"sub" => "user123", "iss" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key)
      assert {:ok, decoded} = JWT.verify(token, rsa_key)
      assert decoded["sub"] == "user123"
      assert decoded["iss"] == "test"
    end

    test "round-trip with EC key", %{ec_key: ec_key} do
      claims = %{"sub" => "user456"}
      assert {:ok, token} = JWT.sign(claims, ec_key, alg: "ES256")
      assert {:ok, decoded} = JWT.verify(token, ec_key)
      assert decoded["sub"] == "user456"
    end

    test "includes kid in header when provided", %{rsa_key: rsa_key} do
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key, kid: "key-1")
      assert {:ok, header} = JWT.peek_header(token)
      assert header["kid"] == "key-1"
    end

    test "includes custom typ header", %{rsa_key: rsa_key} do
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key, typ: "at+jwt")
      assert {:ok, header} = JWT.peek_header(token)
      assert header["typ"] == "at+jwt"
    end

    test "fails with wrong key", %{rsa_key: rsa_key} do
      other_key = JWT.generate_rsa_key(size: 2048)
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key)
      assert {:error, :verification_failed} = JWT.verify(token, other_key)
    end

    test "verifies against a list of keys (JWKS)", %{rsa_key: rsa_key} do
      other_key = JWT.generate_rsa_key(size: 2048)
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key)
      # Should succeed when correct key is in the list
      assert {:ok, decoded} = JWT.verify(token, [other_key, rsa_key])
      assert decoded["sub"] == "test"
    end
  end

  describe "validate_claims/2" do
    setup do
      now = System.system_time(:second)
      %{now: now, valid_exp: %{"exp" => now + 300}}
    end

    test "validates exp - valid token", %{now: now} do
      claims = %{"exp" => now + 300}
      assert {:ok, _} = JWT.validate_claims(claims)
    end

    test "validates exp - expired token", %{now: now} do
      claims = %{"exp" => now - 60}
      assert {:error, :token_expired} = JWT.validate_claims(claims)
    end

    test "rejects a token with no exp claim" do
      assert {:error, :missing_exp} = JWT.validate_claims(%{"sub" => "user123"})
    end

    test "accepts a token with no exp claim when require_exp: false" do
      assert {:ok, _} = JWT.validate_claims(%{"sub" => "user123"}, require_exp: false)
    end

    test "rejects a non-numeric exp claim" do
      assert {:error, {:invalid_claim_type, "exp"}} = JWT.validate_claims(%{"exp" => "whenever"})
      assert {:error, {:invalid_claim_type, "exp"}} = JWT.validate_claims(%{"exp" => nil})

      # A string exp must not slip past even with the opt-out.
      assert {:error, {:invalid_claim_type, "exp"}} =
               JWT.validate_claims(%{"exp" => "whenever"}, require_exp: false)
    end

    test "rejects a non-numeric nbf claim", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "nbf", "soon")
      assert {:error, {:invalid_claim_type, "nbf"}} = JWT.validate_claims(claims)
    end

    test "rejects a non-numeric iat claim", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "iat", "yesterday")
      assert {:error, {:invalid_claim_type, "iat"}} = JWT.validate_claims(claims)
    end

    test "honors the leeway option for expired tokens", %{now: now} do
      # 45s past expiry: outside the 30s default leeway, inside a 120s leeway.
      claims = %{"exp" => now - 45}
      assert {:error, :token_expired} = JWT.validate_claims(claims)
      assert {:ok, _} = JWT.validate_claims(claims, leeway: 120)
      assert {:error, :token_expired} = JWT.validate_claims(claims, leeway: 0)
    end

    test "honors the leeway option for nbf", %{now: now} do
      claims = %{"exp" => now + 300, "nbf" => now + 45}
      assert {:error, :token_not_yet_valid} = JWT.validate_claims(claims)
      assert {:ok, _} = JWT.validate_claims(claims, leeway: 120)
    end

    test "validates iss", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "iss", "correct-issuer")
      assert {:ok, _} = JWT.validate_claims(claims, iss: "correct-issuer")
      assert {:error, {:invalid_issuer, _}} = JWT.validate_claims(claims, iss: "wrong-issuer")
    end

    test "validates aud - string", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "aud", "my-audience")
      assert {:ok, _} = JWT.validate_claims(claims, aud: "my-audience")
      assert {:error, {:invalid_audience, _}} = JWT.validate_claims(claims, aud: "wrong")
    end

    test "validates aud - list in claims", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "aud", ["aud1", "aud2"])
      assert {:ok, _} = JWT.validate_claims(claims, aud: "aud1")
      assert {:ok, _} = JWT.validate_claims(claims, aud: "aud2")
      assert {:error, {:invalid_audience, _}} = JWT.validate_claims(claims, aud: "aud3")
    end

    test "validates sub", %{valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "sub", "user123")
      assert {:ok, _} = JWT.validate_claims(claims, sub: "user123")
      assert {:error, {:invalid_subject, _}} = JWT.validate_claims(claims, sub: "other")
    end

    test "validates max_age", %{now: now, valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "iat", now - 10)
      assert {:ok, _} = JWT.validate_claims(claims, max_age: 60)
      assert {:error, :token_too_old} = JWT.validate_claims(claims, max_age: 5)
    end

    test "validates required claims", %{valid_exp: valid_exp} do
      claims = Map.merge(valid_exp, %{"iss" => "test", "sub" => "user"})
      assert {:ok, _} = JWT.validate_claims(claims, required: ["iss", "sub"])

      assert {:error, {:missing_required_claims, ["aud"]}} =
               JWT.validate_claims(claims, required: ["iss", "aud"])
    end

    test "validates nbf - not yet valid", %{now: now, valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "nbf", now + 300)
      assert {:error, :token_not_yet_valid} = JWT.validate_claims(claims)
    end

    test "validates iat - future iat rejected", %{now: now, valid_exp: valid_exp} do
      claims = Map.put(valid_exp, "iat", now + 300)
      assert {:error, :invalid_iat} = JWT.validate_claims(claims)
    end
  end

  describe "verify_and_validate/3" do
    test "full round-trip with validation", %{rsa_key: rsa_key} do
      now = System.system_time(:second)

      claims = %{
        "iss" => "test-issuer",
        "sub" => "user123",
        "aud" => "my-audience",
        "exp" => now + 300,
        "iat" => now
      }

      assert {:ok, token} = JWT.sign(claims, rsa_key)

      assert {:ok, decoded} =
               JWT.verify_and_validate(token, rsa_key,
                 iss: "test-issuer",
                 sub: "user123",
                 aud: "my-audience"
               )

      assert decoded["iss"] == "test-issuer"
    end

    test "rejects token with wrong issuer", %{rsa_key: rsa_key} do
      claims = %{"iss" => "wrong", "exp" => System.system_time(:second) + 300}
      assert {:ok, token} = JWT.sign(claims, rsa_key)

      assert {:error, {:invalid_issuer, "wrong"}} =
               JWT.verify_and_validate(token, rsa_key, iss: "expected")
    end

    test "rejects a correctly signed token that has no exp", %{rsa_key: rsa_key} do
      assert {:ok, token} = JWT.sign(%{"sub" => "user123"}, rsa_key)

      # The signature is good, so verify/2 succeeds ...
      assert {:ok, _} = JWT.verify(token, rsa_key)
      # ... but verify_and_validate/3 requires an expiry.
      assert {:error, :missing_exp} = JWT.verify_and_validate(token, rsa_key)
    end

    test "rejects a correctly signed token that has expired", %{rsa_key: rsa_key} do
      now = System.system_time(:second)
      assert {:ok, token} = JWT.sign(%{"sub" => "user123", "exp" => now - 600}, rsa_key)

      assert {:ok, _} = JWT.verify(token, rsa_key)
      assert {:error, :token_expired} = JWT.verify_and_validate(token, rsa_key)
    end

    test "rejects a correctly signed token that is not yet valid", %{rsa_key: rsa_key} do
      now = System.system_time(:second)
      claims = %{"sub" => "user123", "exp" => now + 900, "nbf" => now + 600}
      assert {:ok, token} = JWT.sign(claims, rsa_key)

      assert {:error, :token_not_yet_valid} = JWT.verify_and_validate(token, rsa_key)
    end
  end

  describe "generate_jti/0" do
    test "generates unique values" do
      jtis = for _ <- 1..100, do: JWT.generate_jti()
      assert length(Enum.uniq(jtis)) == 100
    end

    test "generates non-empty strings" do
      jti = JWT.generate_jti()
      assert is_binary(jti)
      assert byte_size(jti) > 0
    end
  end

  describe "fetch_jwks/2" do
    test "fetches keys through the pinned metadata boundary", %{rsa_key: rsa_key} do
      public_key = rsa_key |> JWT.to_public_key() |> JWT.to_map()
      parent = self()

      client = fn uri, address, opts ->
        send(parent, {:jwks_request, uri, address, opts[:request_headers]})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"keys" => [public_key]})
         }}
      end

      assert {:ok, [_jwk]} =
               JWT.fetch_jwks("https://auth.example/jwks",
                 dns_resolver: public_dns(),
                 http_client: client
               )

      assert_received {:jwks_request, uri, {93, 184, 216, 34}, headers}
      assert uri.host == "auth.example"
      refute Enum.any?(headers, fn {name, _value} -> name in ["authorization", "cookie"] end)
    end

    test "rejects insecure and private JWKS targets" do
      assert {:error, {:metadata_fetch_error, :https_required}} =
               JWT.fetch_jwks("http://auth.example/jwks")

      dns = fn _host, _timeout -> {:ok, [{127, 0, 0, 1}]} end
      client = fn _uri, _address, _opts -> flunk("request must not be made") end

      assert {:error, {:metadata_fetch_error, :non_public_address}} =
               JWT.fetch_jwks("https://auth.example/jwks",
                 dns_resolver: dns,
                 http_client: client
               )
    end

    test "rejects malformed key sets without raising" do
      client = fn _uri, _address, _opts ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"keys" => [%{"not" => "a key"}]})
         }}
      end

      assert {:error, :invalid_jwks_format} =
               JWT.fetch_jwks("https://auth.example/jwks",
                 dns_resolver: public_dns(),
                 http_client: client
               )
    end
  end

  describe "peek_header/1" do
    test "reads header from token", %{rsa_key: rsa_key} do
      claims = %{"sub" => "test"}
      assert {:ok, token} = JWT.sign(claims, rsa_key, alg: "RS256", kid: "test-kid")
      assert {:ok, header} = JWT.peek_header(token)
      assert header["alg"] == "RS256"
      assert header["kid"] == "test-kid"
      assert header["typ"] == "JWT"
    end

    test "returns error for invalid token" do
      assert {:error, _} = JWT.peek_header("not-a-token")
    end
  end

  defp public_dns do
    fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end
  end
end
