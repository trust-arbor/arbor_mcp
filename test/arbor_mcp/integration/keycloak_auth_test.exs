defmodule Arbor.MCP.Integration.KeycloakAuthTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.{DiscoveryFlow, FullOAuthFlow, JWT}
  alias Arbor.MCP.Client
  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.KeycloakFixture
  alias Arbor.MCP.Server.Runtime

  @moduletag :interop
  @moduletag :interop_real_provider
  @moduletag timeout: 180_000

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  defmodule HostPlug do
    @behaviour Plug
    import Plug.Conn

    alias Arbor.MCP.Authorization.ServerGuard

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{request_path: "/.well-known/oauth-protected-resource/mcp"} = conn, opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{resource: opts.resource, authorization_servers: [opts.issuer]})
      )
    end

    def call(conn, opts) do
      # Application-owned authentication before the mounted library plug. HTTP
      # is confined to loopback; production metadata/TLS policy is not qualified.
      case ServerGuard.authorize(conn.req_headers, [], opts.auth) do
        {:ok, _claims} ->
          HttpPlug.call(conn, opts.plug)

        {:error, {status, challenge, body}} ->
          metadata =
            String.replace_suffix(
              opts.resource,
              "/mcp",
              "/.well-known/oauth-protected-resource/mcp"
            )

          conn
          |> put_resp_header(
            "www-authenticate",
            challenge <> ~s(, resource_metadata="#{metadata}")
          )
          |> send_resp(status, body)
      end
    end
  end

  setup_all do
    previous = Application.fetch_env(:arbor_mcp, :oauth2_enabled)
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :oauth2_enabled, value)
        :error -> Application.delete_env(:arbor_mcp, :oauth2_enabled)
      end
    end)

    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    resource = "http://127.0.0.1:#{port}/mcp"
    ctx = KeycloakFixture.start!(resource)
    on_exit(fn -> KeycloakFixture.stop(ctx) end)

    runtime = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
    ref = {:keycloak_mcp, make_ref()}

    {:ok, _pid} =
      Plug.Cowboy.http(
        HostPlug,
        %{
          resource: resource,
          issuer: ctx.issuer,
          plug:
            HttpPlug.init(
              runtime: runtime,
              endpoint: "/mcp",
              protocol_mode: :modern_only,
              server_info: %{name: "keycloak-mcp", version: "1.0"},
              allowed_origins: ["http://127.0.0.1:#{port}"],
              oauth_enabled: false
            ),
          auth: %{
            expected_issuer: ctx.issuer,
            expected_audience: resource,
            introspection_endpoint: ctx.issuer <> "/protocol/openid-connect/token/introspect",
            client_id: "mcp-resource",
            client_secret: "fixture-resource-secret",
            oauth_http: [allow_insecure_loopback: true]
          }
        },
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    ctx
  end

  for method <- [:basic, :jwt] do
    @method method
    @tag assurance: ["keycloak.cc.#{method}.mcp"]
    test "real Keycloak #{@method} credentials authorize an Arbor MCP client and server", ctx do
      config = auth_config(ctx, @method)

      assert {:ok, :pinged} =
               Client.with_connection(
                 {:http, url: ctx.resource, protocol_mode: :modern_only, auth: config},
                 fn client ->
                   assert {:ok, _result} = Client.ping(client)
                   :pinged
                 end
               )
    end

    for {flow, label} <- [{FullOAuthFlow, "full"}, {DiscoveryFlow, "dedicated"}] do
      @flow flow
      @tag assurance: ["keycloak.cc.#{label}.#{method}"]
      test "#{inspect(flow)} obtains a resource-bound token from real Keycloak using #{@method}",
           ctx do
        assert {:ok, token} = @flow.execute(auth_config(ctx, @method))

        assert {:ok, {{_, 200, _}, _, key_body}} =
                 :httpc.request(
                   :get,
                   {String.to_charlist(ctx.issuer <> "/protocol/openid-connect/certs"), []},
                   [],
                   body_format: :binary
                 )

        assert {:ok, header} = JWT.peek_header(token.access_token)
        key = Enum.find(Jason.decode!(key_body)["keys"], &(&1["kid"] == header["kid"]))

        assert {:ok, claims} =
                 JWT.verify_and_validate(token.access_token, key,
                   iss: ctx.issuer,
                   aud: ctx.resource
                 )

        assert claims["iss"] == ctx.issuer
        assert ctx.resource in List.wrap(claims["aud"])
        assert claims["exp"] > System.system_time(:second)

        assert {:ok, {{_, 200, _}, _, body}} =
                 :httpc.request(
                   :post,
                   {String.to_charlist(ctx.issuer <> "/protocol/openid-connect/token/introspect"),
                    [
                      {~c"authorization",
                       ~c"Basic " ++
                         String.to_charlist(Base.encode64("mcp-resource:fixture-resource-secret"))}
                    ], ~c"application/x-www-form-urlencoded",
                    URI.encode_query(token: token.access_token)},
                   [],
                   body_format: :binary
                 )

        assert %{"active" => true} = Jason.decode!(body)
      end
    end
  end

  @tag assurance: ["keycloak.cc.bad_secret"]
  test "real Keycloak rejects a wrong client secret", ctx do
    config = auth_config(ctx, :basic) |> Map.put(:client_secret, "wrong-fixture-secret")
    assert {:error, _reason} = FullOAuthFlow.execute(config)
  end

  @tag assurance: ["keycloak.mcp.unauthorized"]
  test "the mounted resource rejects missing and invalid bearer credentials", ctx do
    for headers <- [[], [{~c"authorization", ~c"Bearer invalid-fixture-token"}]] do
      assert {:ok, {{_, 401, _}, _, _body}} =
               :httpc.request(
                 :post,
                 {String.to_charlist(ctx.resource), headers, ~c"application/json",
                  ~s({"jsonrpc":"2.0","id":1,"method":"ping"})},
                 [],
                 []
               )
    end
  end

  defp auth_config(ctx, method) do
    common = %{
      resource_url: ctx.resource,
      credential_issuer: ctx.issuer,
      metadata_fetch: [allow_insecure_loopback: true],
      oauth_http: [allow_insecure_loopback: true]
    }

    case method do
      :basic ->
        Map.merge(common, %{
          client_id: "basic-client",
          client_secret: "fixture-basic-secret",
          auth_method: :client_secret
        })

      :jwt ->
        Map.merge(common, %{
          client_id: "jwt-client",
          private_key: ctx.key,
          auth_method: :private_key_jwt,
          signing_algorithm: "RS256",
          alg: "RS256"
        })
    end
  end
end
