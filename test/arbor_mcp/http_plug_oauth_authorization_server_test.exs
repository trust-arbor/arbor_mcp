defmodule Arbor.MCP.HttpPlugOAuthAuthorizationServerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Arbor.MCP.HttpPlug

  @moduletag :oauth

  setup do
    runtime = Arbor.MCP.Test.RuntimeHTTPFixture.start()
    Process.put(:oauth_runtime, runtime)
    :ok
  end

  describe "/.well-known/oauth-authorization-server endpoint" do
    setup do
      on_exit(fn ->
        Application.delete_env(:arbor_mcp, :oauth2_authorization_server_metadata)
      end)

      # Set up valid OAuth configuration for tests
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://auth.test.com",
        authorization_endpoint: "https://auth.test.com/authorize",
        token_endpoint: "https://auth.test.com/token",
        jwks_uri: "https://auth.test.com/.well-known/jwks.json",
        scopes_supported: ["mcp:read", "mcp:write"],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code"],
        code_challenge_methods_supported: ["S256"],
        introspection_endpoint: "https://auth.test.com/introspect"
      )

      opts =
        HttpPlug.init(
          runtime: Process.get(:oauth_runtime),
          endpoint: "/mcp",
          server_info: %{name: "test-server", version: "1.0.0"},
          oauth_enabled: true,
          resource: "https://mcp.test/mcp",
          authorization_servers: ["https://auth.test.com"],
          cors_enabled: true,
          allowed_origins: :any
        )

      {:ok, opts: opts}
    end

    test "returns authorization server metadata when OAuth is enabled", %{opts: opts} do
      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200
      assert {"content-type", "application/json; charset=utf-8"} in result_conn.resp_headers
      assert {"cache-control", "public, max-age=3600"} in result_conn.resp_headers

      # Parse and verify response body
      {:ok, metadata} = Jason.decode(result_conn.resp_body)

      # Verify required RFC 8414 fields
      assert metadata["issuer"] == "https://auth.test.com"
      assert metadata["authorization_endpoint"] == "https://auth.test.com/authorize"
      assert metadata["token_endpoint"] == "https://auth.test.com/token"

      # Verify optional fields
      assert metadata["jwks_uri"] == "https://auth.test.com/.well-known/jwks.json"
      assert metadata["scopes_supported"] == ["mcp:read", "mcp:write"]
      assert metadata["response_types_supported"] == ["code"]
      assert metadata["grant_types_supported"] == ["authorization_code"]
      assert metadata["code_challenge_methods_supported"] == ["S256"]
      assert metadata["introspection_endpoint"] == "https://auth.test.com/introspect"
    end

    test "serves canonical RFC 9728 protected-resource metadata", %{opts: opts} do
      conn = conn(:get, "/.well-known/oauth-protected-resource/mcp")
      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200
      metadata = Jason.decode!(result_conn.resp_body)
      assert metadata["resource"] == "https://mcp.test/mcp"
      assert metadata["authorization_servers"] == ["https://auth.test.com"]
      assert metadata["bearer_methods_supported"] == ["header"]
      refute "mcp:unknown" in metadata["scopes_supported"]
    end

    test "includes CORS headers when CORS is enabled", %{opts: opts} do
      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200
      assert {"access-control-allow-origin", "*"} in result_conn.resp_headers

      assert {"access-control-allow-methods", "GET, POST, DELETE, OPTIONS"} in result_conn.resp_headers
    end

    test "returns 404 when OAuth is disabled" do
      opts =
        HttpPlug.init(
          runtime: Process.get(:oauth_runtime),
          endpoint: "/mcp",
          server_info: %{name: "test-server"},
          # OAuth disabled
          oauth_enabled: false
        )

      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 404
      assert result_conn.resp_body == "Not Found"
    end

    test "returns 500 error when configuration is invalid" do
      # Set up invalid configuration (missing required field)
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        authorization_endpoint: "https://auth.test.com/authorize",
        token_endpoint: "https://auth.test.com/token"
        # Missing required issuer field
      )

      opts =
        HttpPlug.init(
          runtime: Process.get(:oauth_runtime),
          endpoint: "/mcp",
          server_info: %{name: "test-server"},
          oauth_enabled: true,
          resource: "https://mcp.test/mcp",
          authorization_servers: ["https://auth.test.com"]
        )

      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 500
      assert {"content-type", "application/json; charset=utf-8"} in result_conn.resp_headers

      # Parse and verify error response
      {:ok, error_response} = Jason.decode(result_conn.resp_body)
      assert error_response["error"] == "server_error"

      assert error_response["error_description"] ==
               "Authorization server metadata is not properly configured"
    end

    test "handles different request methods correctly", %{opts: opts} do
      # POST should not match the route
      post_conn = conn(:post, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(post_conn, opts)
      # Should fall through to the catch-all and return 404
      assert result_conn.status == 404

      # OPTIONS should be handled by CORS preflight
      options_conn = conn(:options, "/.well-known/oauth-authorization-server")

      cors_opts = %{opts | cors_enabled: true}
      result_conn = HttpPlug.call(options_conn, cors_opts)
      # CORS preflight response
      assert result_conn.status == 200
    end

    test "validates response format against RFC 8414", %{opts: opts} do
      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200

      {:ok, metadata} = Jason.decode(result_conn.resp_body)

      # RFC 8414 Section 2 - All values must be strings or arrays
      Enum.each(metadata, fn {key, value} ->
        assert is_binary(key), "Metadata key #{inspect(key)} must be a string"

        assert is_binary(value) or is_list(value),
               "Metadata value for #{key} must be string or array, got #{inspect(value)}"
      end)

      # Verify required fields are URLs
      required_url_fields = ["issuer", "authorization_endpoint", "token_endpoint"]

      Enum.each(required_url_fields, fn field ->
        assert String.starts_with?(metadata[field], "https://"),
               "Field #{field} should be HTTPS URL: #{metadata[field]}"
      end)

      # Verify array fields contain strings
      array_fields = ["scopes_supported", "response_types_supported", "grant_types_supported"]

      Enum.each(array_fields, fn field ->
        if Map.has_key?(metadata, field) do
          assert is_list(metadata[field]), "Field #{field} should be an array"

          Enum.each(metadata[field], fn item ->
            assert is_binary(item), "All items in #{field} should be strings"
          end)
        end
      end)
    end

    test "caches responses appropriately", %{opts: opts} do
      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200

      # Verify cache control header is set for 1 hour (3600 seconds)
      cache_header =
        Enum.find(result_conn.resp_headers, fn {name, _} -> name == "cache-control" end)

      assert cache_header == {"cache-control", "public, max-age=3600"}
    end

    test "supports minimal configuration", %{opts: opts} do
      # Set up minimal configuration with only required fields
      Application.put_env(:arbor_mcp, :oauth2_authorization_server_metadata,
        issuer: "https://minimal.test.com",
        authorization_endpoint: "https://minimal.test.com/auth",
        token_endpoint: "https://minimal.test.com/token"
      )

      conn = conn(:get, "/.well-known/oauth-authorization-server")

      result_conn = HttpPlug.call(conn, opts)

      assert result_conn.status == 200

      {:ok, metadata} = Jason.decode(result_conn.resp_body)

      # Only required fields should be present
      assert map_size(metadata) == 3
      assert metadata["issuer"] == "https://minimal.test.com"
      assert metadata["authorization_endpoint"] == "https://minimal.test.com/auth"
      assert metadata["token_endpoint"] == "https://minimal.test.com/token"
    end

    test "rejects OAuth configuration without protected-resource metadata" do
      assert_raise ArgumentError, ~r/requires.*authorization_servers/, fn ->
        HttpPlug.init(
          runtime: Process.get(:oauth_runtime),
          oauth_enabled: true,
          resource: "https://mcp.test/mcp"
        )
      end
    end
  end
end
