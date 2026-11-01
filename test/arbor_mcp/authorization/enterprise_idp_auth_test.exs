defmodule Arbor.MCP.Authorization.EnterpriseIdPAuthTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{ClientAssertion, EnterpriseFlow, FullOAuthFlow, JWT}

  setup_all do
    {:ok, key: JWT.generate_ec_key(), rsa_key: JWT.generate_rsa_key()}
  end

  for flow <- [EnterpriseFlow, FullOAuthFlow] do
    @flow flow

    for method <- [:client_secret_basic, :client_secret_post, :private_key_jwt] do
      @method method
      test "#{inspect(flow)} authenticates to the IdP with #{method} and separate AS credentials",
           %{key: key} do
        config = fixture()
        auth = auth(@method, key)

        assert {:ok, %{access_token: "resource-token"}} =
                 @flow.execute(Map.put(config, :idp_auth, auth))

        assert_receive {:idp_request, headers, body}
        assert body["audience"] == config.as_issuer
        assert body["subject_token"] == "id-token"
        assert body["resource"] == config.resource_url
        assert body["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag"

        case @method do
          :client_secret_basic ->
            assert headers == ["Basic " <> Base.encode64("idp-app:fake-idp-secret")]
            refute Map.has_key?(body, "client_id")
            refute Map.has_key?(body, "client_secret")

          :client_secret_post ->
            assert headers == []
            assert body["client_id"] == "idp-app"
            assert body["client_secret"] == "fake-idp-secret"

          :private_key_jwt ->
            assert headers == []
            assert body["client_id"] == "idp-app"
            refute Map.has_key?(body, "client_secret")
            assert body["client_assertion_type"] == ClientAssertion.assertion_type()

            assert {:ok, claims} =
                     ClientAssertion.verify_assertion(body["client_assertion"], "idp-app",
                       token_endpoint: config.idp_token_endpoint,
                       client_jwks: JWT.to_public_key(key)
                     )

            assert claims["iss"] == "idp-app"
            assert claims["sub"] == "idp-app"
            assert claims["aud"] == config.idp_token_endpoint

            assert {:ok, %{"alg" => "ES256", "kid" => "idp-key"}} =
                     JWT.peek_header(body["client_assertion"])
        end

        refute inspect({headers, body}) =~ "fake-as-secret"
        assert_receive {:as_request, as_headers, as_body}
        assert as_body["assertion"] == "id-jag-token"
        refute inspect({as_headers, as_body}) =~ "fake-idp-secret"
        refute Map.has_key?(as_body, "client_assertion")

        if @flow == FullOAuthFlow do
          assert as_headers == ["Basic " <> Base.encode64("as-app:fake-as-secret")]
          refute Map.has_key?(as_body, "client_id")
        else
          assert as_headers == []
          assert as_body["client_id"] == "as-app"
        end
      end
    end

    test "#{inspect(flow)} retains its public-client exchange when idp_auth is absent or nil" do
      for value <- [:absent, nil] do
        config = fixture()
        config = if value == :absent, do: config, else: Map.put(config, :idp_auth, value)
        assert {:ok, %{access_token: "resource-token"}} = @flow.execute(config)
        assert_receive {:idp_request, [], body}
        assert body["client_id"] == if(@flow == FullOAuthFlow, do: "idp-app", else: "as-app")
        refute Map.has_key?(body, "client_secret")
        assert_receive {:as_request, _headers, _body}
      end
    end

    test "#{inspect(flow)} discovers the token endpoint when only idp_auth supplies the IdP" do
      config = fixture() |> Map.delete(:idp_token_endpoint) |> Map.delete(:idp_issuer)
      config = Map.put(config, :idp_auth, auth(:client_secret_basic, nil))
      assert {:ok, %{access_token: "resource-token"}} = @flow.execute(config)
      assert_receive {:idp_request, [_basic], _body}
      assert_receive {:as_request, _headers, _body}
    end

    test "#{inspect(flow)} rejects issuer and endpoint conflicts before posting any token" do
      for changes <- [
            [idp_issuer: "https://other-idp.example"],
            [idp_client_id: "other-idp-client"],
            [idp_token_endpoint: "http://localhost:1/wrong-token"]
          ] do
        config = fixture() |> Map.merge(Map.new(changes))

        assert {:error, _reason} =
                 @flow.execute(Map.put(config, :idp_auth, auth(:client_secret_basic, nil)))

        refute_received {:idp_request, _headers, _body}
        refute_received {:as_request, _headers, _body}
      end
    end

    test "#{inspect(flow)} rejects discovery for another issuer before sending credentials" do
      config = fixture(issuer: "https://other-idp.example")

      assert {:error, _reason} =
               @flow.execute(Map.put(config, :idp_auth, auth(:client_secret_basic, nil)))

      refute_received {:idp_request, _headers, _body}
      refute_received {:as_request, _headers, _body}
    end

    test "#{inspect(flow)} requires an advertised method and defaults absent metadata to Basic" do
      for methods <- [["none"], [], nil, "client_secret_basic"] do
        config = fixture(methods: methods)

        assert {:error, _reason} =
                 @flow.execute(Map.put(config, :idp_auth, auth(:client_secret_basic, nil)))

        refute_received {:idp_request, _headers, _body}
        refute_received {:as_request, _headers, _body}
      end

      config = fixture(methods: :omitted)

      assert {:ok, _token} =
               @flow.execute(Map.put(config, :idp_auth, auth(:client_secret_basic, nil)))

      assert_receive {:idp_request, [_basic], _body}
      assert_receive {:as_request, _headers, _body}
    end

    test "#{inspect(flow)} rejects malformed config without falling back to AS credentials",
         %{key: key} do
      base = auth(:client_secret_basic, nil)

      for invalid <- [
            false,
            %{},
            Map.delete(base, :client_secret),
            Map.put(base, :client_secret, ""),
            Map.put(base, :client_id, nil),
            Map.put(base, :issuer, nil),
            Map.delete(base, :auth_method),
            Map.put(base, :auth_method, :none),
            Map.put(base, :unknown_option, "private-config-marker"),
            auth(:private_key_jwt, JWT.to_public_key(key)),
            auth(:private_key_jwt, "private-config-marker"),
            auth(:private_key_jwt, key) |> Map.put(:signing_algorithm, "HS256")
          ] do
        config = fixture() |> Map.put(:idp_auth, invalid)
        assert {:error, _reason} = result = @flow.execute(config)
        refute inspect(result) =~ "private-config-marker"
        refute inspect(result) =~ "fake-as-secret"
        refute inspect(result) =~ "fake-idp-secret"
        refute_received {:idp_request, _headers, _body}
        refute_received {:as_request, _headers, _body}
      end
    end

    test "#{inspect(flow)} rejects incompatible JWT signing metadata", %{key: key} do
      for algorithms <- [["RS256"], [], nil, "ES256"] do
        config =
          fixture(algorithms: algorithms) |> Map.put(:idp_auth, auth(:private_key_jwt, key))

        assert {:error, _reason} = @flow.execute(config)
        refute_received {:idp_request, _headers, _body}
        refute_received {:as_request, _headers, _body}
      end
    end
  end

  for flow <- [EnterpriseFlow, FullOAuthFlow] do
    @flow flow

    test "#{inspect(flow)} defaults JWT signing to RS256 when signing metadata is absent",
         %{rsa_key: key} do
      config = fixture(algorithms: :omitted)
      auth = auth(:private_key_jwt, key) |> Map.delete(:signing_algorithm)
      assert {:ok, _token} = @flow.execute(Map.put(config, :idp_auth, auth))
      assert_receive {:idp_request, [], body}

      assert {:ok, _claims} =
               ClientAssertion.verify_assertion(body["client_assertion"], "idp-app",
                 token_endpoint: config.idp_token_endpoint,
                 client_jwks: JWT.to_public_key(key)
               )

      assert {:ok, %{"alg" => "RS256"}} = JWT.peek_header(body["client_assertion"])
      assert_receive {:as_request, _headers, _body}
    end

    test "#{inspect(flow)} does not retry rejected IdP authentication with AS credentials" do
      config = fixture(idp_status: 401) |> Map.put(:idp_auth, auth(:client_secret_basic, nil))
      assert {:error, _reason} = @flow.execute(config)
      assert_receive {:idp_request, ["Basic " <> encoded], _body}
      assert Base.decode64!(encoded) == "idp-app:fake-idp-secret"
      refute_received {:idp_request, _headers, _body}
      refute_received {:as_request, _headers, _body}
    end
  end

  defp auth(method, key) do
    base = %{issuer: "https://idp.example", client_id: "idp-app", auth_method: method}

    if method == :private_key_jwt,
      do: Map.merge(base, %{private_key: key, signing_algorithm: "ES256", key_id: "idp-key"}),
      else: Map.put(base, :client_secret, "fake-idp-secret")
  end

  defp fixture(opts \\ []) do
    parent = self()
    idp = Bypass.open()
    as = Bypass.open()
    idp_origin = "http://localhost:#{idp.port}"
    as_origin = "http://localhost:#{as.port}"
    as_issuer = "https://resource-as.example"
    resource = "https://resource.example/mcp"

    for {bypass, tag, token} <- [
          {idp, :idp_request, "id-jag-token"},
          {as, :as_request, "resource-token"}
        ] do
      Bypass.stub(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {tag, Plug.Conn.get_req_header(conn, "authorization"), URI.decode_query(body)}
        )

        respond_with_token(conn, tag, token, opts)
      end)
    end

    metadata = fn uri, _address, _fetch_opts ->
      data =
        case uri.host do
          "resource.example" ->
            %{"resource" => resource, "authorization_servers" => [as_issuer]}

          "resource-as.example" ->
            %{
              "issuer" => as_issuer,
              "authorization_endpoint" => as_origin <> "/authorize",
              "token_endpoint" => as_origin <> "/token",
              "grant_types_supported" => ["urn:ietf:params:oauth:grant-type:jwt-bearer"],
              "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
            }

          "idp.example" ->
            %{
              "issuer" => Keyword.get(opts, :issuer, "https://idp.example"),
              "authorization_endpoint" => idp_origin <> "/authorize",
              "token_endpoint" => idp_origin <> "/token",
              "token_endpoint_auth_methods_supported" =>
                Keyword.get(opts, :methods, [
                  "client_secret_basic",
                  "client_secret_post",
                  "private_key_jwt"
                ]),
              "token_endpoint_auth_signing_alg_values_supported" =>
                Keyword.get(opts, :algorithms, ["ES256"])
            }

          _ ->
            nil
        end

      data =
        if data && opts[:methods] == :omitted,
          do: Map.delete(data, "token_endpoint_auth_methods_supported"),
          else: data

      data =
        if data && opts[:algorithms] == :omitted,
          do: Map.delete(data, "token_endpoint_auth_signing_alg_values_supported"),
          else: data

      if data,
        do: {:ok, %{status: 200, headers: [], body: Jason.encode!(data)}},
        else: {:ok, %{status: 404, headers: [], body: ""}}
    end

    %{
      id_token: "id-token",
      idp_id_token: "id-token",
      idp_issuer: "https://idp.example",
      idp_token_endpoint: idp_origin <> "/token",
      idp_client_id: "idp-app",
      as_issuer: as_issuer,
      as_token_endpoint: as_origin <> "/token",
      resource_url: resource,
      client_id: "as-app",
      client_secret: "fake-as-secret",
      credential_issuer: as_issuer,
      metadata_fetch: [
        http_client: metadata,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [idp_origin, as_origin],
        allow_insecure_loopback: true
      ]
    }
  end

  defp respond_with_token(conn, tag, token, opts) do
    if tag == :idp_request and opts[:idp_status] == 401,
      do: json(conn, %{"error" => "invalid_client"}, 401),
      else: json(conn, %{"access_token" => token, "token_type" => "Bearer"})
  end

  defp json(conn, data, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(data))
  end
end
