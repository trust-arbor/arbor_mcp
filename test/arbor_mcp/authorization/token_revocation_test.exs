defmodule Arbor.MCP.Authorization.TokenRevocationTest do
  @moduledoc """
  Tests for OAuth 2.0 Token Revocation (RFC 7009).

  Verifies request body construction, successful revocation handling,
  error response handling, and token_type_hint support.
  """
  use ExUnit.Case, async: true

  @moduletag :oauth

  alias Arbor.MCP.Authorization.TokenRevocation

  describe "revoke/3 successful revocation" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, endpoint: "http://localhost:#{bypass.port}/revoke"}
    end

    test "sends correct POST body with token and token_type_hint=access_token", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["token"] == "my_access_token_123"
        assert params["token_type_hint"] == "access_token"

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} =
               TokenRevocation.revoke("my_access_token_123", endpoint,
                 token_type_hint: "access_token"
               )
    end

    test "sends correct POST body with token_type_hint=refresh_token", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["token"] == "my_refresh_token_456"
        assert params["token_type_hint"] == "refresh_token"

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} =
               TokenRevocation.revoke("my_refresh_token_456", endpoint,
                 token_type_hint: "refresh_token"
               )
    end

    test "includes client_id and client_secret in body for client_secret_post", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["token"] == "token_to_revoke"
        assert params["client_id"] == "my_client"
        assert params["client_secret"] == "my_secret"

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} =
               TokenRevocation.revoke("token_to_revoke", endpoint,
                 client_id: "my_client",
                 client_secret: "my_secret",
                 auth_method: :client_secret_post
               )
    end

    test "uses Basic auth header for client_secret_basic", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        # Check Authorization header
        auth_header =
          Enum.find_value(conn.req_headers, fn
            {"authorization", val} -> val
            _ -> nil
          end)

        expected = "Basic " <> Base.encode64("my_client:my_secret")
        assert auth_header == expected

        # client_secret should NOT be in body for basic auth
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["token"] == "token_basic"
        # client_id is still in body per implementation
        assert params["client_id"] == "my_client"
        refute Map.has_key?(params, "client_secret")

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} =
               TokenRevocation.revoke("token_basic", endpoint,
                 client_id: "my_client",
                 client_secret: "my_secret",
                 auth_method: :client_secret_basic
               )
    end

    test "handles 204 No Content as successful revocation", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, :revoked} = TokenRevocation.revoke("any_token", endpoint)
    end

    test "revokes without token_type_hint when not provided", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["token"] == "bare_token"
        refute Map.has_key?(params, "token_type_hint")

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} = TokenRevocation.revoke("bare_token", endpoint)
    end
  end

  describe "revoke/3 error handling" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, endpoint: "http://localhost:#{bypass.port}/revoke"}
    end

    test "returns error for OAuth error response", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_request",
            "error_description" => "Token parameter required"
          })
        )
      end)

      assert {:error, {:revocation_error, 400, "invalid_request", "Token parameter required"}} =
               TokenRevocation.revoke("bad_token", endpoint)
    end

    test "returns error for non-JSON error response", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500, _body}} =
               TokenRevocation.revoke("some_token", endpoint)
    end

    test "returns error for connection failure", %{bypass: bypass, endpoint: endpoint} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _reason}} =
               TokenRevocation.revoke("some_token", endpoint)
    end
  end

  describe "revoke/3 endpoint validation" do
    test "rejects non-HTTPS endpoints (except localhost)" do
      assert {:error, :https_required} =
               TokenRevocation.revoke("token", "http://evil.example.com/revoke")
    end

    test "allows http://localhost via Bypass" do
      # Use Bypass to prove localhost passes validation and reaches HTTP layer
      bypass = Bypass.open()
      endpoint = "http://localhost:#{bypass.port}/revoke"

      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} = TokenRevocation.revoke("token", endpoint)
    end

    test "allows http://127.0.0.1 via Bypass" do
      bypass = Bypass.open()
      endpoint = "http://127.0.0.1:#{bypass.port}/revoke"

      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, :revoked} = TokenRevocation.revoke("token", endpoint)
    end
  end
end
