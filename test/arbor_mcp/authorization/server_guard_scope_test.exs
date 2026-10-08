defmodule Arbor.MCP.Authorization.ServerGuardScopeTest do
  @moduledoc """
  Tests for ServerGuard scope information in 403 WWW-Authenticate headers.

  Verifies that insufficient_scope errors include the required scope
  in the WWW-Authenticate header per RFC 6750 Section 3.
  """
  use ExUnit.Case, async: false

  @moduletag :oauth

  alias Arbor.MCP.Authorization.ServerGuard

  setup do
    # Enable OAuth for these tests
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      Application.delete_env(:arbor_mcp, :oauth2_enabled)
    end)
  end

  describe "insufficient_scope 403 response" do
    setup do
      bypass = Bypass.open()

      config = %{
        introspection_endpoint: "http://localhost:#{bypass.port}/introspect",
        realm: "test-server",
        legacy_unbound_tokens: true
      }

      {:ok, bypass: bypass, config: config}
    end

    test "includes scope in WWW-Authenticate header for single required scope", %{
      bypass: bypass,
      config: config
    } do
      # Introspection returns active token with limited scopes
      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "active" => true,
            "scope" => "mcp:tools:list"
          })
        )
      end)

      headers = [{"authorization", "Bearer valid_token"}]
      required_scopes = ["mcp:tools:execute"]

      {:error, {status, www_auth, _body}} =
        ServerGuard.authorize(headers, required_scopes, config)

      assert status == 403
      assert www_auth =~ ~s(scope="mcp:tools:execute")
      assert www_auth =~ ~s(error="insufficient_scope")
      assert www_auth =~ ~s(realm="test-server")
    end

    test "includes all required scopes space-separated in WWW-Authenticate", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "active" => true,
            "scope" => "mcp:tools:list"
          })
        )
      end)

      headers = [{"authorization", "Bearer valid_token"}]
      required_scopes = ["mcp:tools:execute", "mcp:resources:get"]

      {:error, {status, www_auth, _body}} =
        ServerGuard.authorize(headers, required_scopes, config)

      assert status == 403
      assert www_auth =~ ~s(scope="mcp:tools:execute mcp:resources:get")
    end

    test "different scope requirements produce different header values", %{
      bypass: bypass,
      config: config
    } do
      # Token has no scopes
      Bypass.stub(bypass, "POST", "/introspect", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "active" => true,
            "scope" => ""
          })
        )
      end)

      headers = [{"authorization", "Bearer valid_token"}]

      # First request requires "read" scope
      {:error, {403, www_auth_1, _}} =
        ServerGuard.authorize(headers, ["read"], config)

      # Second request requires "write" scope
      {:error, {403, www_auth_2, _}} =
        ServerGuard.authorize(headers, ["write"], config)

      assert www_auth_1 =~ ~s(scope="read")
      assert www_auth_2 =~ ~s(scope="write")
      refute www_auth_1 == www_auth_2
    end

    test "passes when token has all required scopes", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "active" => true,
            "scope" => "mcp:tools:list mcp:tools:execute"
          })
        )
      end)

      headers = [{"authorization", "Bearer valid_token"}]
      required_scopes = ["mcp:tools:list"]

      assert {:ok, token_info} = ServerGuard.authorize(headers, required_scopes, config)
      assert token_info[:scope] == "mcp:tools:list mcp:tools:execute"
    end

    test "403 response body includes error details as JSON", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/introspect", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "active" => true,
            "scope" => "basic"
          })
        )
      end)

      headers = [{"authorization", "Bearer valid_token"}]
      required_scopes = ["admin"]

      {:error, {403, _www_auth, body}} =
        ServerGuard.authorize(headers, required_scopes, config)

      body_map = Jason.decode!(body)
      assert body_map["error"] == "insufficient_scope"
      assert is_binary(body_map["error_description"])
    end
  end
end
