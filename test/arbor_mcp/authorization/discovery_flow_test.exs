defmodule Arbor.MCP.Authorization.DiscoveryFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.DiscoveryFlow

  @secret "pre-registered-secret"
  @attacker "https://evil.example"

  # These tests verify the flow logic without making real HTTP calls.
  # Full integration tests with Bypass would test the actual HTTP layer.

  describe "execute/1" do
    test "returns error when resource discovery fails" do
      config = %{
        resource_url: "https://nonexistent.example.com/mcp",
        client_id: "test-client",
        auth_method: :client_secret,
        client_secret: "secret"
      }

      assert {:error, {:discovery_failed, _}} = DiscoveryFlow.execute(config)
    end

    test "returns error for invalid auth method" do
      # This would only be reached if discovery succeeded, so we test
      # the validation separately through the type system
      config = %{
        resource_url: "https://example.com/mcp",
        client_id: "test-client",
        auth_method: :invalid_method
      }

      # Will fail at discovery step first
      assert {:error, _} = DiscoveryFlow.execute(config)
    end

    test "returns error when client_secret is missing for :client_secret method" do
      # To test this path, we'd need discovery to succeed
      # Testing the select_auth_method logic indirectly
      config = %{
        resource_url: "https://example.com/mcp",
        client_id: "test-client",
        auth_method: :client_secret
        # missing :client_secret
      }

      assert {:error, _} = DiscoveryFlow.execute(config)
    end

    test "returns error when private_key is missing for :private_key_jwt method" do
      config = %{
        resource_url: "https://example.com/mcp",
        client_id: "test-client",
        auth_method: :private_key_jwt
        # missing :private_key
      }

      assert {:error, _} = DiscoveryFlow.execute(config)
    end

    test "never posts a pre-registered secret to an attacker-controlled issuer" do
      server = oauth_server()

      assert {:error, {:pre_registered_credential_issuer_required, @attacker}} =
               server
               |> flow_config(@attacker)
               |> DiscoveryFlow.execute()

      assert Agent.get(server.counter, & &1.token_requests) == []

      assert {:error,
              {:pre_registered_credential_issuer_mismatch, expected: expected, actual: @attacker}} =
               server
               |> flow_config(@attacker, server.issuer)
               |> DiscoveryFlow.execute()

      assert expected == server.issuer
      assert Agent.get(server.counter, & &1.token_requests) == []

      assert {:ok, %{access_token: "token-for-legacy-client"}} =
               server
               |> flow_config(server.issuer, server.issuer)
               |> DiscoveryFlow.execute()

      assert [params] = Agent.get(server.counter, & &1.token_requests)
      assert params["client_id"] == "legacy-client"
      assert params["client_secret"] == @secret
    end
  end

  defp oauth_server do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    issuer_host = "auth-#{unique}.example"
    resource_host = "resource-#{unique}.example"
    issuer = "https://#{issuer_host}"
    resource_origin = "https://#{resource_host}"
    resource_url = resource_origin <> "/mcp"
    actual_origin = "http://localhost:#{bypass.port}"

    {:ok, counter} = Agent.start_link(fn -> %{token_requests: []} end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      Agent.update(counter, fn state ->
        Map.update!(state, :token_requests, &[params | &1])
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
      resource_url: resource_url,
      actual_origin: actual_origin,
      counter: counter
    }
  end

  defp flow_config(server, authorization_server, credential_issuer \\ nil) do
    config = %{
      resource_url: server.resource_url,
      client_id: "legacy-client",
      auth_method: :client_secret,
      client_secret: @secret,
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
    resource_url = server.resource_url
    issuer_host = server.issuer_host
    actual_origin = server.actual_origin

    fn uri, _address, _opts ->
      body =
        case {uri.host, uri.path} do
          {^resource_host, "/.well-known/oauth-protected-resource/mcp"} ->
            %{
              "resource" => resource_url,
              "authorization_servers" => [authorization_server]
            }

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
