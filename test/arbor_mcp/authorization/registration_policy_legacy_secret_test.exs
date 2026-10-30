defmodule Arbor.MCP.Authorization.RegistrationPolicyLegacySecretTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.FullOAuthFlow

  @secret "pre-registered-secret"
  @attacker "https://evil.example"

  test "a legacy pre-registered secret is never posted to an attacker-controlled issuer" do
    server = oauth_server()

    assert {:error, {:pre_registered_credential_issuer_required, @attacker}} =
             server
             |> flow_config(@attacker)
             |> FullOAuthFlow.execute()

    assert Agent.get(server.counter, & &1.tokens) == 0
    assert Agent.get(server.counter, & &1.token_requests) == []

    assert {:ok, %{access_token: "token-for-legacy-client"}} =
             server
             |> flow_config(server.issuer, server.issuer)
             |> FullOAuthFlow.execute()

    assert [params] = Agent.get(server.counter, & &1.token_requests)
    assert params["client_id"] == "legacy-client"
    assert params["client_secret"] == @secret
  end

  defp oauth_server do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    issuer_host = "auth-#{unique}.example"
    resource_host = "resource-#{unique}.example"
    issuer = "https://#{issuer_host}"
    resource_origin = "https://#{resource_host}"
    actual_origin = "http://localhost:#{bypass.port}"

    {:ok, counter} = Agent.start_link(fn -> %{tokens: 0, token_requests: []} end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      Agent.update(counter, fn state ->
        state
        |> Map.update!(:tokens, &(&1 + 1))
        |> Map.update!(:token_requests, &[params | &1])
      end)

      json(conn, 200, %{
        "access_token" => "token-for-legacy-client",
        "token_type" => "Bearer",
        "expires_in" => 3_600
      })
    end)

    %{
      bypass: bypass,
      issuer: issuer,
      issuer_host: issuer_host,
      resource_host: resource_host,
      resource_origin: resource_origin,
      actual_origin: actual_origin,
      counter: counter
    }
  end

  defp flow_config(server, authorization_server, credential_issuer \\ nil) do
    config = %{
      resource_url: server.resource_origin <> "/mcp",
      www_authenticate: ~s(Bearer resource_metadata="#{server.resource_origin}/prm"),
      client_id: "legacy-client",
      client_secret: @secret,
      protocol_version: "2025-11-25",
      scopes: ["tools:read"],
      metadata_fetch: [
        http_client: metadata_client(server, authorization_server),
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [server.actual_origin],
        allow_insecure_loopback: true
      ]
    }

    if is_binary(credential_issuer) do
      Map.put(config, :credential_issuer, credential_issuer)
    else
      config
    end
  end

  defp metadata_client(server, authorization_server) do
    resource_host = server.resource_host
    issuer_host = server.issuer_host
    actual_origin = server.actual_origin

    fn uri, _address, _opts ->
      body =
        case {uri.host, uri.path} do
          {^resource_host, "/prm"} ->
            %{"authorization_servers" => [authorization_server]}

          {host, "/.well-known/openid-configuration"}
          when host in [issuer_host, "evil.example"] ->
            %{
              "issuer" => "https://#{host}",
              "authorization_endpoint" => actual_origin <> "/authorize",
              "token_endpoint" => actual_origin <> "/token",
              "grant_types_supported" => ["client_credentials"],
              "token_endpoint_auth_methods_supported" => ["client_secret_post"]
            }

          _other ->
            nil
        end

      if body,
        do: {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}},
        else: {:ok, %{status: 404, headers: [], body: ""}}
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
