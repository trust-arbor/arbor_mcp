defmodule Arbor.MCP.Plugs.ProtectedResourceMetadataTest do
  @moduledoc """
  Tests for the Protected Resource Metadata Plug (RFC 9728).

  Verifies correct HTTP response format, required fields, and default values.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @moduletag :oauth

  alias Arbor.MCP.Plugs.ProtectedResourceMetadata

  @valid_opts [
    resource: "https://mcp.example.com",
    authorization_servers: ["https://auth.example.com"]
  ]

  describe "call/2" do
    test "returns 200 with application/json content type" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "response includes resource field" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["resource"] == "https://mcp.example.com"
    end

    test "response includes authorization_servers" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["authorization_servers"] == ["https://auth.example.com"]
    end

    test "response includes scopes_supported" do
      opts =
        ProtectedResourceMetadata.init(
          @valid_opts ++ [scopes_supported: ["mcp:tools:list", "mcp:tools:execute"]]
        )

      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert is_list(body["scopes_supported"])
      assert "mcp:tools:list" in body["scopes_supported"]
      assert "mcp:tools:execute" in body["scopes_supported"]
    end

    test "bearer_methods_supported defaults to [\"header\"]" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["bearer_methods_supported"] == ["header"]
    end

    test "includes custom bearer_methods_supported when specified" do
      opts =
        ProtectedResourceMetadata.init(
          @valid_opts ++ [bearer_methods_supported: ["header", "body"]]
        )

      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["bearer_methods_supported"] == ["header", "body"]
    end

    test "includes resource_signing_alg_values_supported when provided" do
      opts =
        ProtectedResourceMetadata.init(
          @valid_opts ++ [resource_signing_alg_values_supported: ["RS256", "ES256"]]
        )

      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["resource_signing_alg_values_supported"] == ["RS256", "ES256"]
    end

    test "omits optional fields when not provided" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      refute Map.has_key?(body, "resource_signing_alg_values_supported")
      refute Map.has_key?(body, "resource_documentation")
    end

    test "includes extra_metadata fields" do
      opts =
        ProtectedResourceMetadata.init(
          @valid_opts ++ [extra_metadata: %{"custom_field" => "custom_value"}]
        )

      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert body["custom_field"] == "custom_value"
    end

    test "includes cache-control header" do
      opts = ProtectedResourceMetadata.init(@valid_opts)
      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      cache_control = get_resp_header(conn, "cache-control") |> hd()
      assert cache_control =~ "public"
      assert cache_control =~ "max-age=3600"
    end

    test "supports multiple authorization servers" do
      opts =
        ProtectedResourceMetadata.init(
          resource: "https://mcp.example.com",
          authorization_servers: [
            "https://auth1.example.com",
            "https://auth2.example.com"
          ]
        )

      conn = conn(:get, "/.well-known/oauth-protected-resource")

      conn = ProtectedResourceMetadata.call(conn, opts)

      body = Jason.decode!(conn.resp_body)

      assert body["authorization_servers"] == [
               "https://auth1.example.com",
               "https://auth2.example.com"
             ]
    end
  end

  describe "init/1 validation" do
    test "raises when :resource is missing" do
      assert_raise ArgumentError, ~r/requires :resource/, fn ->
        ProtectedResourceMetadata.init(authorization_servers: ["https://auth.example.com"])
      end
    end

    test "raises when :authorization_servers is missing" do
      assert_raise ArgumentError, ~r/requires :authorization_servers/, fn ->
        ProtectedResourceMetadata.init(resource: "https://mcp.example.com")
      end
    end
  end
end
