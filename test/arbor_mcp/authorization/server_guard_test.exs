defmodule Arbor.MCP.Authorization.ServerGuardTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.ServerGuard

  setup do
    # Set feature flag to true for most tests
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      # Reset feature flag
      Application.delete_env(:arbor_mcp, :oauth2_enabled)
    end)
  end

  @base_config %{
    realm: "test-realm",
    legacy_unbound_tokens: true
  }

  describe "authorize/3" do
    test "returns :ok when :oauth2_auth feature flag is disabled" do
      Application.put_env(:arbor_mcp, :oauth2_enabled, false)

      config =
        Map.put(@base_config, :introspection_endpoint, "https://auth.example.com/introspect")

      assert ServerGuard.authorize([], [], config) == :ok
    end

    test "returns error for missing token" do
      headers = []

      config =
        Map.put(@base_config, :introspection_endpoint, "https://auth.example.com/introspect")

      {:error, {status, www_auth, body}} = ServerGuard.authorize(headers, [], config)

      assert status == 401

      assert www_auth ==
               ~s(Bearer realm="test-realm", error="invalid_request", error_description="Authorization header is missing or malformed.")

      assert Jason.decode!(body) == %{
               "error" => "invalid_request",
               "error_description" => "Authorization header is missing or malformed."
             }
    end

    test "returns error for malformed Authorization header" do
      headers = [{"authorization", "Basic some-token"}]

      config =
        Map.put(@base_config, :introspection_endpoint, "https://auth.example.com/introspect")

      {:error, {401, _, _}} = ServerGuard.authorize(headers, [], config)
    end
  end

  describe "authorize/3 with mock introspection endpoint" do
    @describetag :requires_bypass
    setup do
      bypass = Bypass.open()

      # Most tests can use a localhost http endpoint
      config =
        @base_config
        |> Map.put(:introspection_endpoint, "http://localhost:#{bypass.port}/introspect")

      {:ok, bypass: bypass, config: config}
    end

    test "successfully authorizes with valid token and sufficient scopes", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "token=valid-token"
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true, scope: "read write"}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      required_scopes = ["read"]

      assert {:ok, token_info} = ServerGuard.authorize(headers, required_scopes, config)
      assert token_info.active == true
      assert token_info.scope == "read write"
    end

    test "returns error for invalid token", %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: false}))
      end)

      headers = [{"authorization", "Bearer invalid-token"}]
      {:error, {status, www_auth, body}} = ServerGuard.authorize(headers, [], config)

      assert status == 401

      assert www_auth ==
               ~s(Bearer realm="test-realm", error="invalid_token", error_description="The access token is expired, revoked, or malformed.")

      assert Jason.decode!(body) == %{
               "error" => "invalid_token",
               "error_description" => "The access token is expired, revoked, or malformed."
             }
    end

    test "returns error for insufficient scope", %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true, scope: "read"}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      required_scopes = ["write"]

      {:error, {status, www_auth, body}} =
        ServerGuard.authorize(headers, required_scopes, config)

      assert status == 403

      assert www_auth ==
               ~s(Bearer realm="test-realm", error="insufficient_scope", error_description="The request requires higher privileges.", scope="write")

      assert Jason.decode!(body) == %{
               "error" => "insufficient_scope",
               "error_description" => "The request requires higher privileges."
             }
    end

    test "handles token with no scope when scopes are required", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      required_scopes = ["read"]
      {:error, {status, _, _}} = ServerGuard.authorize(headers, required_scopes, config)
      assert status == 403
    end

    test "handles token with nil scope when scopes are required", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true, scope: nil}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      required_scopes = ["read"]
      {:error, {status, _, _}} = ServerGuard.authorize(headers, required_scopes, config)
      assert status == 403
    end

    test "succeeds when no scopes are required", %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true, scope: "read"}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      assert {:ok, token_info} = ServerGuard.authorize(headers, [], config)
      assert token_info.active == true
    end

    test "allows http for localhost introspection endpoint", %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{active: true}))
      end)

      headers = [{"authorization", "Bearer valid-token"}]
      # The config from setup already uses http://localhost
      assert {:ok, token_info} = ServerGuard.authorize(headers, [], config)
      assert token_info.active == true
    end
  end

  describe "bound token validation and introspection authentication" do
    @describetag :requires_bypass

    setup do
      bypass = Bypass.open()
      now = System.system_time(:second)

      config = %{
        introspection_endpoint: "http://localhost:#{bypass.port}/introspect",
        realm: "bound-resource",
        client_id: "resource-client",
        client_secret: "resource-secret",
        introspection_auth_method: :client_secret_basic,
        expected_issuer: "https://issuer.example",
        expected_audience: "https://mcp.example",
        clock_skew_seconds: 0
      }

      {:ok, bypass: bypass, config: config, now: now}
    end

    test "authenticates introspection and accepts a correctly bound active token", %{
      bypass: bypass,
      config: config,
      now: now
    } do
      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Basic " <> Base.encode64("resource-client:resource-secret")
               ]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "token=bound-token"
        refute body =~ "client_secret"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            active: true,
            scope: "read",
            iss: "https://issuer.example",
            aud: ["another-audience", "https://mcp.example"],
            exp: now + 60,
            nbf: now - 60
          })
        )
      end)

      assert {:ok, %{active: true}} =
               ServerGuard.authorize(
                 [{"authorization", "Bearer bound-token"}],
                 ["read"],
                 config
               )
    end

    test "rejects missing and wrong issuer or audience claims", %{
      bypass: bypass,
      config: config,
      now: now
    } do
      responses = %{
        "missing-aud" => %{iss: "https://issuer.example"},
        "wrong-aud" => %{iss: "https://issuer.example", aud: "https://wrong.example"},
        "missing-iss" => %{aud: "https://mcp.example"},
        "wrong-iss" => %{iss: "https://wrong.example", aud: "https://mcp.example"}
      }

      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        claims =
          responses
          |> Map.fetch!(params["token"])
          |> Map.merge(%{active: true, exp: now + 60})

        Plug.Conn.resp(conn, 200, Jason.encode!(claims))
      end)

      for token <- Map.keys(responses) do
        assert {:error, {401, www_auth, body}} =
                 ServerGuard.authorize(
                   [{"authorization", "Bearer #{token}"}],
                   [],
                   config
                 )

        assert www_auth =~ ~s(error="invalid_token")

        assert Jason.decode!(body)["error_description"] ==
                 "The access token is not valid for this resource server."
      end
    end

    test "rejects missing or expired exp and future nbf", %{
      bypass: bypass,
      config: config,
      now: now
    } do
      times = %{
        "missing-exp" => %{},
        "expired" => %{exp: now - 1},
        "not-yet-valid" => %{exp: now + 60, nbf: now + 60}
      }

      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        claims =
          times
          |> Map.fetch!(params["token"])
          |> Map.merge(%{
            active: true,
            iss: "https://issuer.example",
            aud: "https://mcp.example"
          })

        Plug.Conn.resp(conn, 200, Jason.encode!(claims))
      end)

      for token <- Map.keys(times) do
        assert {:error, {401, _, _}} =
                 ServerGuard.authorize(
                   [{"authorization", "Bearer #{token}"}],
                   [],
                   config
                 )
      end
    end

    test "fails closed when secure binding or introspection credentials are absent", %{
      config: config
    } do
      headers = [{"authorization", "Bearer token"}]

      for missing <- [:expected_audience, :expected_issuer, :client_id, :client_secret] do
        assert {:error, {500, _, body}} =
                 ServerGuard.authorize(headers, [], Map.delete(config, missing))

        assert Jason.decode!(body)["error_description"] == "Authorization check failed."
      end
    end

    test "supports client_secret_post when explicitly configured", %{
      bypass: bypass,
      config: config,
      now: now
    } do
      config = %{config | introspection_auth_method: :client_secret_post}

      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["client_id"] == "resource-client"
        assert params["client_secret"] == "resource-secret"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            active: true,
            iss: "https://issuer.example",
            aud: "https://mcp.example",
            exp: now + 60
          })
        )
      end)

      assert {:ok, _token_info} =
               ServerGuard.authorize([{"authorization", "Bearer token"}], [], config)
    end
  end

  describe "configuration validation" do
    test "returns error for invalid config (non-https introspection endpoint)" do
      bad_config =
        @base_config
        |> Map.put(:introspection_endpoint, "http://insecure.com/introspect")

      headers = [{"authorization", "Bearer some-token"}]

      {:error, {status, _, _}} = ServerGuard.authorize(headers, [], bad_config)
      assert status == 500
    end
  end

  describe "extract_bearer_token/1" do
    test "extracts token from valid header (list of tuples)" do
      headers = [{"authorization", "Bearer my-secret-token"}]
      assert ServerGuard.extract_bearer_token(headers) == {:ok, "my-secret-token"}
    end

    test "extracts token from valid header (map)" do
      headers = %{"authorization" => "Bearer my-secret-token"}
      assert ServerGuard.extract_bearer_token(headers) == {:ok, "my-secret-token"}
    end

    test "is case-insensitive to header key" do
      headers = [{"Authorization", "Bearer my-secret-token"}]
      assert ServerGuard.extract_bearer_token(headers) == {:ok, "my-secret-token"}
    end

    test "extracts token from charlist header key and value" do
      headers = [{~c"authorization", ~c"Bearer my-secret-token"}]
      assert ServerGuard.extract_bearer_token(headers) == {:ok, "my-secret-token"}
    end

    test "extracts token from atom-keyed map" do
      headers = %{authorization: "Bearer my-secret-token"}
      assert ServerGuard.extract_bearer_token(headers) == {:ok, "my-secret-token"}
    end

    test "returns error for missing header" do
      headers = []
      assert ServerGuard.extract_bearer_token(headers) == {:error, :missing_token}
    end

    test "returns error for wrong scheme" do
      headers = [{"authorization", "Basic my-secret-token"}]
      assert ServerGuard.extract_bearer_token(headers) == {:error, :missing_token}
    end

    test "returns error for missing token value" do
      headers = [{"authorization", "Bearer "}]
      assert ServerGuard.extract_bearer_token(headers) == {:error, :missing_token}
    end
  end
end
