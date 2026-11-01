defmodule Arbor.MCP.Authorization.DiscoveryFlowAuthMethodsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.DiscoveryFlow

  for {label, methods, expected} <- [
        {"Basic-only", ["client_secret_basic"], :basic},
        {"Post-only", ["client_secret_post"], :post},
        {"Basic before Post", ["client_secret_post", "client_secret_basic"], :basic},
        {"omitted metadata defaults to Basic", :omitted, :basic}
      ] do
    @methods methods
    @expected expected
    test "honors #{label} token endpoint metadata" do
      config = token_server(@methods)
      assert {:ok, %{access_token: "audit-token"}} = DiscoveryFlow.execute(config)
      assert_receive {:token_request, auth, body}
      assert body["grant_type"] == "client_credentials"
      assert body["scope"] == "audit.read"
      assert body["resource"] == config.resource

      if @expected == :basic do
        assert auth == ["Basic " <> Base.encode64("audit-client:fake-audit-secret")]
        refute Map.has_key?(body, "client_secret")
        refute Map.has_key?(body, "client_id")
      else
        assert auth == []
        assert body["client_id"] == "audit-client"
        assert body["client_secret"] == "fake-audit-secret"
      end
    end
  end

  test "rejects unsupported or malformed metadata before posting credentials" do
    for methods <- [["private_key_jwt"], ["none"], [], nil, "client_secret_basic"] do
      config = token_server(methods)

      assert {:error, {:auth_method_not_supported, :client_secret, ^methods}} =
               DiscoveryFlow.execute(config)

      refute_received {:token_request, _auth, _body}
    end
  end

  defp token_server(methods) do
    bypass = Bypass.open()
    parent = self()
    origin = "http://localhost:#{bypass.port}"
    issuer = "https://audit-auth.example"
    resource = "https://audit-resource.example/mcp"

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:token_request, Plug.Conn.get_req_header(conn, "authorization"), URI.decode_query(body)}
      )

      json(conn, 200, %{"access_token" => "audit-token", "token_type" => "Bearer"})
    end)

    metadata = fn uri, _address, _opts ->
      data =
        case {uri.host, uri.path} do
          {"audit-resource.example", "/.well-known/oauth-protected-resource/mcp"} ->
            %{"resource" => resource, "authorization_servers" => [issuer]}

          {"audit-auth.example", "/.well-known/openid-configuration"} ->
            base = %{
              "issuer" => issuer,
              "authorization_endpoint" => origin <> "/authorize",
              "token_endpoint" => origin <> "/token",
              "grant_types_supported" => ["client_credentials"]
            }

            if methods == :omitted,
              do: base,
              else: Map.put(base, "token_endpoint_auth_methods_supported", methods)

          _ ->
            nil
        end

      if data,
        do: {:ok, %{status: 200, headers: [], body: Jason.encode!(data)}},
        else: {:ok, %{status: 404, headers: [], body: ""}}
    end

    %{
      resource_url: resource,
      client_id: "audit-client",
      auth_method: :client_secret,
      client_secret: "fake-audit-secret",
      credential_issuer: issuer,
      scopes: ["audit.read"],
      resource: resource,
      metadata_fetch: [
        http_client: metadata,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [origin],
        allow_insecure_loopback: true
      ]
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
