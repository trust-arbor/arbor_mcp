defmodule Arbor.MCP.Authorization.EnterpriseContractTest do
  # Each case owns multiple HTTP peers and discovery/token workers.
  use ExUnit.Case, async: false

  alias Arbor.MCP.AuthExtensionFixture
  alias Arbor.MCP.Authorization.{ClientAssertion, EnterpriseFlow, FullOAuthFlow, JWT}

  for {flow, label} <- [{EnterpriseFlow, "explicit"}, {FullOAuthFlow, "discovery"}] do
    @flow flow
    for method <- [:client_secret_basic, :client_secret_post, :private_key_jwt] do
      @method method
      @tag assurance: ["ema.as.#{label}.#{method}"]
      test "#{inspect(flow)} uses separate resource-AS #{method} credentials" do
        key = JWT.generate_ec_key()
        config = AuthExtensionFixture.config()
        auth = %{issuer: config.as_issuer, client_id: "as-client", auth_method: @method}

        auth =
          if @method == :private_key_jwt,
            do: Map.merge(auth, %{private_key: key, signing_algorithm: "ES256"}),
            else: Map.put(auth, :client_secret, "fake-as-secret")

        assert {:ok, %{access_token: "resource-token"}} =
                 @flow.execute(Map.put(config, :as_auth, auth))

        assert_received {:idp, idp_headers, exchange}
        assert idp_headers == ["Basic " <> Base.encode64("idp-client:fake-idp-secret")]
        assert exchange["audience"] == config.as_issuer
        refute inspect({idp_headers, exchange}) =~ "fake-as-secret"

        assert_received {:as, headers, grant}
        assert grant["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
        assert grant["assertion"] == "id-jag"
        assert grant["resource"] == config.resource_url
        refute inspect({headers, grant}) =~ "fake-idp-secret"

        case @method do
          :client_secret_basic ->
            assert headers == ["Basic " <> Base.encode64("as-client:fake-as-secret")]
            refute Map.has_key?(grant, "client_secret")

          :client_secret_post ->
            assert headers == []
            assert grant["client_id"] == "as-client"
            assert grant["client_secret"] == "fake-as-secret"

          :private_key_jwt ->
            assert headers == []
            refute Map.has_key?(grant, "client_secret")

            assert {:ok, claims} =
                     ClientAssertion.verify_assertion(grant["client_assertion"], "as-client",
                       token_endpoint: config.as_issuer,
                       client_jwks: JWT.to_public_key(key)
                     )

            assert claims["aud"] == config.as_issuer
        end
      end
    end

    @tag assurance: ["ema.subject.#{label}.refresh"]
    test "#{inspect(flow)} exchanges a supplied refresh token" do
      config = subject_config(:refresh_token, "host-refresh")
      assert {:ok, %{access_token: "resource-token"}} = @flow.execute(config)
      assert_received {:idp, _headers, exchange}
      assert exchange["subject_token"] == "host-refresh"
      assert exchange["subject_token_type"] == "urn:ietf:params:oauth:token-type:refresh_token"
      assert exchange["audience"] == config.as_issuer
    end

    @tag assurance: ["ema.subject.#{label}.saml"]
    test "#{inspect(flow)} exchanges SAML through a refresh token before requesting ID-JAG" do
      config = subject_config(:saml2, "host-saml")
      assert {:ok, %{access_token: "resource-token"}} = @flow.execute(config)
      assert_received {:idp, headers, first}
      assert first["subject_token"] == "host-saml"
      assert first["subject_token_type"] == "urn:ietf:params:oauth:token-type:saml2"
      assert first["requested_token_type"] == "urn:ietf:params:oauth:token-type:refresh_token"
      assert first["scope"] == "openid offline_access"
      assert_received {:idp, ^headers, second}
      assert second["subject_token"] == "refresh-from-saml"
      assert second["subject_token_type"] == "urn:ietf:params:oauth:token-type:refresh_token"
      assert second["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag"
      assert second["audience"] == config.as_issuer
    end

    @tag assurance: ["ema.subject.#{label}.conflict"]
    test "#{inspect(flow)} rejects conflicting subject inputs before token exchange" do
      config =
        AuthExtensionFixture.config()
        |> Map.put(:idp_subject, %{type: :refresh_token, token: "different"})

      assert {:error, _reason} = @flow.execute(config)
      refute_received {:idp, _, _}
      refute_received {:as, _, _}
    end

    @tag assurance: ["ema.as.#{label}.mismatch"]
    test "#{inspect(flow)} rejects mismatched AS credentials before either token leg" do
      config = AuthExtensionFixture.config()

      auth = %{
        issuer: config.as_issuer,
        client_id: "other-client",
        auth_method: :client_secret_basic,
        client_secret: "fake-as-secret"
      }

      assert {:error, _reason} = @flow.execute(Map.put(config, :as_auth, auth))
      refute_received {:idp, _, _}
      refute_received {:as, _, _}
    end
  end

  @tag assurance: ["ema.discovery.profile"]
  test "an explicit profile list without ID-JAG is not treated as support" do
    config = AuthExtensionFixture.config(profiles: [])
    assert {:error, :id_jag_profile_not_supported} = FullOAuthFlow.execute(config)
    refute_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.subject.saml_response"]
  test "SAML transition rejects an unexpected issued token type" do
    config =
      AuthExtensionFixture.config(
        saml_issued_type: "urn:ietf:params:oauth:token-type:access_token"
      )
      |> Map.drop([:id_token, :idp_id_token])
      |> Map.put(:idp_subject, %{type: :saml2, token: "host-saml"})

    assert {:error, :invalid_saml_exchange_response} = EnterpriseFlow.execute(config)
    assert_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.exchange.token_type"]
  test "an IdP access token is never forwarded as an ID-JAG" do
    config =
      AuthExtensionFixture.config(
        idp_issued_type: "urn:ietf:params:oauth:token-type:access_token"
      )

    assert {:error, :invalid_id_jag_exchange_response} = EnterpriseFlow.execute(config)
    assert_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.exchange.missing_type"]
  test "an exchange without an issued token type is rejected before the AS grant" do
    config = AuthExtensionFixture.config(idp_issued_type: :omitted)
    assert {:error, :invalid_id_jag_exchange_response} = EnterpriseFlow.execute(config)
    assert_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.exchange.bearer_type"]
  test "Bearer is not accepted as the ID-JAG token type" do
    config = AuthExtensionFixture.config(idp_token_type: "Bearer")
    assert {:error, :invalid_id_jag_exchange_response} = EnterpriseFlow.execute(config)
    assert_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.exchange.missing_token_type"]
  test "a missing token type does not qualify an ID-JAG response" do
    config = AuthExtensionFixture.config(idp_token_type: :omitted)
    assert {:error, :invalid_id_jag_exchange_response} = EnterpriseFlow.execute(config)
    assert_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  @tag assurance: ["ema.discovery.grants"]
  test "a profile indicator cannot override a contradictory grant list" do
    config = AuthExtensionFixture.config(grants: ["authorization_code"])
    assert {:error, :id_jag_profile_not_supported} = FullOAuthFlow.execute(config)
    refute_received {:idp, _, _}
    refute_received {:as, _, _}
  end

  for {options, label} <- [
        {[grants: ["authorization_code"]], "grants"},
        {[profiles: []], "profile"}
      ] do
    @metadata_options options
    @tag assurance: ["ema.explicit.#{label}"]
    test "explicit enterprise flow rejects contradictory discovered #{label} before IdP exchange" do
      config = AuthExtensionFixture.config(@metadata_options)

      config =
        Map.put(config, :as_auth, %{
          issuer: config.as_issuer,
          client_id: "as-client",
          auth_method: :client_secret_basic,
          client_secret: "fake-as-secret"
        })

      assert {:error, :id_jag_profile_not_supported} = EnterpriseFlow.execute(config)
      refute_received {:idp, _, _}
      refute_received {:as, _, _}
    end
  end

  defp subject_config(type, token) do
    AuthExtensionFixture.config()
    |> Map.drop([:id_token, :idp_id_token])
    |> Map.put(:idp_subject, %{type: type, token: token})
  end
end
