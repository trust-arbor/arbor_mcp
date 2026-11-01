defmodule Arbor.MCP.Authorization.JWTVerifierTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{JWT, JWTVerifier}

  # Serves the keys the test sets, counting fetches.
  setup do
    bypass = Bypass.open()
    test = self()
    keys = :ets.new(:keys, [:public])
    :ets.insert(keys, {:jwks, []})

    Bypass.stub(bypass, "GET", "/jwks", fn conn ->
      send(test, :jwks_fetched)
      [{:jwks, published}] = :ets.lookup(keys, :jwks)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"keys" => published}))
    end)

    publish = fn jwks ->
      :ets.insert(keys, {:jwks, Enum.map(jwks, fn {kid, jwk} -> public(jwk, kid) end)})
    end

    opts = [
      jwks_uri: fixture_jwks_uri(bypass),
      oauth_http: [allow_insecure_loopback: true]
    ]

    %{bypass: bypass, publish: publish, opts: opts}
  end

  defp public(jwk, kid) do
    jwk |> JWT.to_public_key() |> JWT.to_map() |> Map.merge(%{"kid" => kid, "use" => "sig"})
  end

  defp token(jwk, kid, claims \\ %{}, opts \\ []) do
    claims =
      Map.merge(
        %{"iss" => "https://auth.example.com", "sub" => "u1", "exp" => now() + 300},
        claims
      )

    {:ok, token} = JWT.sign(claims, jwk, Keyword.merge([kid: kid, typ: "at+jwt"], opts))
    token
  end

  defp now, do: System.system_time(:second)

  # Bypass ports can be reused while cached keys are still live. Keep every
  # fixture distinct without changing caching between requests in one test.
  defp fixture_jwks_uri(bypass),
    do: "http://localhost:#{bypass.port}/jwks?fixture=#{System.unique_integer([:positive])}"

  test "a token signed with a published key gives its claims", %{publish: publish, opts: opts} do
    key = JWT.generate_rsa_key()
    publish.([{"k1", key}])

    assert {:ok, %{"sub" => "u1", "scope" => "read write"}} =
             JWTVerifier.verify_access_token(
               token(key, "k1", %{"scp" => ["read", "write"]}),
               opts
             )
  end

  test "a token signed with another key is refused", %{publish: publish, opts: opts} do
    publish.([{"k1", JWT.generate_rsa_key()}])
    forged = token(JWT.generate_rsa_key(), "k1")

    assert {:error, :invalid_token} = JWTVerifier.verify_access_token(forged, opts)
  end

  test "an unsigned or symmetrically signed token is refused", %{publish: publish, opts: opts} do
    key = JWT.generate_rsa_key()
    publish.([{"k1", key}])
    [_header, payload, _signature] = String.split(token(key, "k1"), ".")

    none =
      Base.url_encode64(~s({"alg":"none","kid":"k1"}), padding: false) <> "." <> payload <> "."

    assert {:error, :invalid_token} = JWTVerifier.verify_access_token(none, opts)

    hmac = JOSE.JWK.from_oct("secret")
    {:ok, hs256} = JWT.sign(%{"exp" => now() + 300}, hmac, alg: "HS256", kid: "k1")
    assert {:error, :invalid_token} = JWTVerifier.verify_access_token(hs256, opts)
  end

  test "a typ other than at+jwt or JWT is refused, and JWT too if asked",
       %{publish: publish, opts: opts} do
    key = JWT.generate_rsa_key()
    publish.([{"k1", key}])

    assert {:error, :invalid_token} =
             JWTVerifier.verify_access_token(token(key, "k1", %{}, typ: "id+jwt"), opts)

    plain = token(key, "k1", %{}, typ: "JWT")
    assert {:ok, _} = JWTVerifier.verify_access_token(plain, opts)

    assert {:error, :invalid_token} =
             JWTVerifier.verify_access_token(plain, [require_at_jwt_typ: true] ++ opts)
  end

  test "a rotated key is fetched, but made-up key ids don't fetch again",
       %{publish: publish, opts: opts} do
    old = JWT.generate_rsa_key()
    publish.([{"old", old}])
    assert {:ok, _} = JWTVerifier.verify_access_token(token(old, "old"), opts)
    assert_received :jwks_fetched

    # Past the minimum time between fetches, a new key id fetches again.
    new = JWT.generate_rsa_key()
    publish.([{"old", old}, {"new", new}])
    rotated = [jwks_min_refresh_ms: 0] ++ opts
    assert {:ok, _} = JWTVerifier.verify_access_token(token(new, "new"), rotated)
    assert_received :jwks_fetched

    # Within it, an unknown key id doesn't.
    stranger = token(JWT.generate_rsa_key(), "nobody")
    assert {:error, :invalid_token} = JWTVerifier.verify_access_token(stranger, opts)
    refute_received :jwks_fetched
  end

  test "while fetching fails, it isn't tried again for every request" do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "GET", "/jwks", fn conn ->
      send(test, :jwks_fetched)
      Plug.Conn.resp(conn, 500, "")
    end)

    opts = [
      jwks_uri: fixture_jwks_uri(bypass),
      oauth_http: [allow_insecure_loopback: true]
    ]

    token = token(JWT.generate_rsa_key(), "k1")

    for _attempt <- 1..3 do
      assert {:error, {:jwks_unavailable, _}} = JWTVerifier.verify_access_token(token, opts)
    end

    assert_received :jwks_fetched
    refute_received :jwks_fetched
  end

  test "the keys are kept, and kept a while longer if fetching them fails",
       %{bypass: bypass, publish: publish, opts: opts} do
    key = JWT.generate_rsa_key()
    publish.([{"k1", key}])
    assert {:ok, _} = JWTVerifier.verify_access_token(token(key, "k1"), opts)
    assert {:ok, _} = JWTVerifier.verify_access_token(token(key, "k1"), opts)
    assert_received :jwks_fetched
    refute_received :jwks_fetched

    # Expired, and fetching again fails: the keys held still answer while
    # they're not too old, and not after.
    Bypass.down(bypass)
    expired = [jwks_cache_ttl_ms: 0, jwks_min_refresh_ms: 0] ++ opts
    assert {:ok, _} = JWTVerifier.verify_access_token(token(key, "k1"), expired)

    assert {:error, {:jwks_unavailable, _reason}} =
             JWTVerifier.verify_access_token(token(key, "k1"), [jwks_max_stale_ms: 0] ++ expired)
  end

  test "a token that isn't a JWT, or is too long, is refused", %{opts: opts} do
    assert {:error, :invalid_token} = JWTVerifier.verify_access_token("not-a-jwt", opts)

    assert {:error, :invalid_token} =
             JWTVerifier.verify_access_token(String.duplicate("a", 20_000), opts)
  end
end
