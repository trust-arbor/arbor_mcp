defmodule Arbor.MCP.AuthExtensionInteropTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.{
    ClientAssertion,
    DiscoveryFlow,
    EnterpriseFlow,
    FullOAuthFlow,
    IdJag,
    IdJagHandler,
    JWT
  }

  @moduletag :interop
  @moduletag :interop_auth_extensions

  setup do
    node = System.find_executable("node") || raise "Node.js is required for Auth interop"
    fixture = Path.expand("../../interop/auth_peer.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [fixture]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    ready = read_json(port)

    {:ok,
     port: port,
     origin: ready["origin"],
     key: ready["privateKey"],
     idp_key: ready["idpPrivateKey"]}
  end

  for {flow, label} <- [{FullOAuthFlow, "full"}, {DiscoveryFlow, "dedicated"}] do
    @flow flow
    @tag assurance: ["peer.cc.#{label}.jwt"]
    test "#{inspect(flow)} authenticates JWT client credentials to an independent OAuth peer",
         ctx do
      config =
        config(ctx)
        |> Map.merge(%{
          private_key: ctx.key,
          signing_algorithm: "ES256",
          alg: "ES256",
          auth_method: :private_key_jwt
        })

      assert {:ok, token} = @flow.execute(config)
      assert_resource(token, ctx)
    end
  end

  for {flow, label} <- [{EnterpriseFlow, "explicit"}, {FullOAuthFlow, "discovery"}] do
    @flow flow
    for type <- [:id_token, :refresh_token, :saml2] do
      @subject_type type
      @tag assurance: ["peer.ema.#{label}.#{type}"]
      test "#{inspect(flow)} completes #{type} enterprise flow against a verifying IdP and AS",
           ctx do
        subject =
          case @subject_type do
            :id_token -> "fixture-id-token"
            :refresh_token -> "fixture-refresh"
            :saml2 -> "fixture-saml"
          end

        config =
          config(ctx)
          |> Map.merge(%{
            as_issuer: ctx.origin <> "/as",
            idp_subject: %{type: @subject_type, token: subject},
            idp_auth: auth(ctx, :idp),
            as_auth: auth(ctx, :as)
          })

        assert {:ok, token} = @flow.execute(config)
        assert_resource(token, ctx)
        Port.command(ctx.port, "counts\n")
        counts = read_json(ctx.port)
        assert counts["idp"] == if(@subject_type == :saml2, do: 2, else: 1)
        assert counts["as"] == 1
        assert counts["resource"] == 1
      end
    end
  end

  @tag assurance: ["peer.ema.key_separation"]
  test "the independent AS rejects an assertion signed using the IdP registration key", ctx do
    config =
      config(ctx)
      |> Map.merge(%{
        as_issuer: ctx.origin <> "/as",
        idp_subject: %{type: :id_token, token: "fixture-id-token"},
        idp_auth: auth(ctx, :idp),
        as_auth: auth(ctx, :as) |> Map.put(:private_key, ctx.idp_key)
      })

    assert {:error, _reason} = EnterpriseFlow.execute(config)
    Port.command(ctx.port, "counts\n")
    assert %{"idp" => 1, "as" => 0, "resource" => 0} = read_json(ctx.port)
  end

  @tag assurance: ["peer.cc.bad_key"]
  test "the independent AS rejects client credentials signed by an unrelated key", ctx do
    config = config(ctx) |> Map.merge(%{private_key: ctx.idp_key, signing_algorithm: "ES256"})
    assert {:error, _reason} = FullOAuthFlow.execute(config)
    Port.command(ctx.port, "counts\n")
    assert %{"idp" => 0, "as" => 0, "resource" => 0} = read_json(ctx.port)
  end

  for mode <- ["jwt", "basic", "enterprise"] do
    @sdk_mode mode
    @tag assurance: ["sdk.auth.#{mode}"]
    test "pinned TypeScript SDK #{mode} helpers interoperate with Arbor validation and ID-JAG issuance" do
      bypass = Bypass.open()
      origin = "http://127.0.0.1:#{bypass.port}"
      key = JWT.generate_ec_key()

      {_kty, private_jwk} = JOSE.JWK.to_map(key)
      parent = self()

      Bypass.expect(bypass, "POST", "/as/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["resource"] == "https://resource-sdk.example/mcp"
        assert params["scope"] == "mcp:read"

        if @sdk_mode == "jwt" do
          assert {:ok, claims} =
                   ClientAssertion.verify_assertion(params["client_assertion"], "as-client",
                     token_endpoint: "https://as-sdk.example",
                     client_jwks: JWT.to_public_key(key)
                   )

          assert claims["sub"] == "as-client"
          assert params["client_assertion_type"] == ClientAssertion.assertion_type()
          assert params["grant_type"] == "client_credentials"
          refute Map.has_key?(params, "client_secret")
        else
          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Basic " <> Base.encode64("as-client:fake-as-secret")
                 ]

          refute Map.has_key?(params, "client_secret")
        end

        if @sdk_mode == "enterprise" do
          assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"

          assert {:ok, result} =
                   IdJagHandler.handle_grant(
                     assertion: params["assertion"],
                     expected_audience: "https://as-sdk.example",
                     expected_resource: "https://resource-sdk.example/mcp",
                     trusted_idps: %{
                       "https://idp-sdk.example" => %{jwks: [JWT.to_public_key(key)]}
                     }
                   )

          assert result.client_id == "as-client"
          assert result.subject == "fixture-user"
        end

        send(parent, :sdk_as_validated)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            access_token: "host-issued-access",
            token_type: "Bearer",
            expires_in: 300
          })
        )
      end)

      if @sdk_mode == "enterprise" do
        Bypass.expect(bypass, "POST", "/idp/token", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          assert params["client_id"] == "idp-client"
          assert params["client_secret"] == "fake-idp-secret"
          assert params["subject_token"] == "fixture-id-token"
          assert params["subject_token_type"] == "urn:ietf:params:oauth:token-type:id_token"
          assert params["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag"
          assert params["audience"] == "https://as-sdk.example"
          assert params["resource"] == "https://resource-sdk.example/mcp"

          assert {:ok, token} =
                   IdJag.create(
                     private_key: key,
                     alg: "ES256",
                     issuer: "https://idp-sdk.example",
                     subject: "fixture-user",
                     client_id: "as-client",
                     audience: "https://as-sdk.example",
                     resource: "https://resource-sdk.example/mcp"
                   )

          send(parent, :sdk_idp_validated)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              access_token: token,
              issued_token_type: "urn:ietf:params:oauth:token-type:id-jag",
              token_type: "N_A",
              expires_in: 300
            })
          )
        end)
      end

      node = System.find_executable("node") || raise "Node.js is required for SDK Auth interop"
      fixture = Path.expand("../../interop/auth_sdk_client.mjs", __DIR__)

      port =
        Port.open({:spawn_executable, node}, [
          :binary,
          :exit_status,
          {:line, 65_536},
          args: [fixture]
        ])

      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      Port.command(
        port,
        Jason.encode!(%{mode: @sdk_mode, origin: origin, key: private_jwk}) <> "\n"
      )

      assert %{"access_token" => "host-issued-access"} = read_json(port)
      assert_received :sdk_as_validated
      if @sdk_mode == "enterprise", do: assert_received(:sdk_idp_validated)
    end
  end

  defp auth(ctx, leg),
    do: %{
      issuer: ctx.origin <> "/#{leg}",
      client_id: "#{leg}-client",
      auth_method: :private_key_jwt,
      private_key: if(leg == :idp, do: ctx.idp_key, else: ctx.key),
      signing_algorithm: "ES256"
    }

  defp config(ctx) do
    %{
      resource_url: ctx.origin <> "/mcp",
      client_id: "as-client",
      credential_issuer: ctx.origin <> "/as",
      metadata_fetch: [allow_insecure_loopback: true]
    }
  end

  defp assert_resource(token, ctx) do
    request =
      {String.to_charlist(ctx.origin <> "/mcp"),
       [{~c"authorization", String.to_charlist("Bearer " <> token.access_token)}],
       ~c"application/json", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})}

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)

    assert %{"result" => %{"resultType" => "ping"}} = Jason.decode!(body)
  end

  defp read_json(port) do
    receive do
      {^port, {:data, {:eol, data}}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("Auth peer exited: #{status}")
    after
      10_000 -> flunk("Auth peer did not reply")
    end
  end
end
