defmodule Arbor.MCP.Authorization.TokenManagerRefreshTest do
  @moduledoc """
  Tests for JWT-authenticated refresh token flow in TokenManager.

  Verifies that `refresh_with_jwt_auth/1` uses grant_type "refresh_token"
  (not "client_credentials"), includes the refresh_token parameter,
  and passes client_assertion + client_assertion_type via ClientAssertion.
  """
  use ExUnit.Case, async: true

  @moduletag :oauth

  alias Arbor.MCP.Authorization.TokenManager

  describe "refresh_with_jwt_auth via refresh_now/1" do
    setup do
      # We use Bypass to intercept the HTTP call made by HTTPClient.make_token_request
      bypass = Bypass.open()

      {:ok, bypass: bypass, token_endpoint: "http://localhost:#{bypass.port}/token"}
    end

    test "sends grant_type=refresh_token with JWT client assertion", %{
      bypass: bypass,
      token_endpoint: token_endpoint
    } do
      # Generate an RSA key pair for signing
      private_key = generate_test_rsa_key()

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        # Verify grant_type is "refresh_token", not "client_credentials"
        assert params["grant_type"] == "refresh_token"

        # Verify refresh_token is included
        assert params["refresh_token"] == "test_refresh_token_abc"

        # Verify JWT client assertion params are present
        assert params["client_assertion_type"] ==
                 "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

        assert is_binary(params["client_assertion"])
        assert String.length(params["client_assertion"]) > 0

        # Verify client_id is included
        assert params["client_id"] == "test_client"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_access_token",
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "refresh_token" => "new_refresh_token"
          })
        )
      end)

      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            client_id: "test_client",
            token_endpoint: token_endpoint,
            private_key: private_key
          },
          auth_method: :private_key_jwt,
          initial_token: %{
            "access_token" => "old_access",
            "refresh_token" => "test_refresh_token_abc",
            "expires_in" => 3600
          }
        )

      assert {:ok, _token_data} = TokenManager.refresh_now(manager)

      GenServer.stop(manager)
    end

    test "includes scope parameter when scope is set on state", %{
      bypass: bypass,
      token_endpoint: token_endpoint
    } do
      private_key = generate_test_rsa_key()

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "refresh_token"
        assert params["scope"] == "read write"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "scoped_token",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            client_id: "test_client",
            token_endpoint: token_endpoint,
            private_key: private_key
          },
          auth_method: :private_key_jwt,
          initial_token: %{
            "access_token" => "old_access",
            "refresh_token" => "refresh_with_scope",
            "expires_in" => 3600,
            "scope" => "read write"
          }
        )

      assert {:ok, _} = TokenManager.refresh_now(manager)

      GenServer.stop(manager)
    end

    test "returns error when no refresh token is available", %{token_endpoint: token_endpoint} do
      private_key = generate_test_rsa_key()

      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            client_id: "test_client",
            token_endpoint: token_endpoint,
            private_key: private_key
          },
          auth_method: :private_key_jwt,
          initial_token: %{
            "access_token" => "access_only",
            "expires_in" => 3600
            # No refresh_token
          }
        )

      assert {:error, :no_refresh_token} = TokenManager.refresh_now(manager)

      GenServer.stop(manager)
    end

    test "returns error when client assertion build fails", %{
      bypass: bypass,
      token_endpoint: token_endpoint
    } do
      # Pass an invalid private key to trigger assertion build failure.
      # Use stub (not expect) since the request should never arrive.
      Bypass.stub(bypass, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 500, "unexpected")
      end)

      {:ok, manager} =
        TokenManager.start_link(
          auth_config: %{
            client_id: "test_client",
            token_endpoint: token_endpoint,
            private_key: "not_a_valid_key"
          },
          auth_method: :private_key_jwt,
          initial_token: %{
            "access_token" => "old_access",
            "refresh_token" => "some_refresh",
            "expires_in" => 3600
          }
        )

      # The refresh should fail due to invalid key
      result = TokenManager.refresh_now(manager)
      assert {:error, _reason} = result

      GenServer.stop(manager)
    end
  end

  # Generate a test RSA private key in JWK format
  defp generate_test_rsa_key do
    if Code.ensure_loaded?(JOSE.JWK) do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      {_, map} = JOSE.JWK.to_map(jwk)
      map
    else
      # Fallback: generate via Erlang crypto and convert
      {pub, priv} = :crypto.generate_key(:rsa, {2048, 65537})
      # Return raw key — tests may fail if JOSE is not available
      %{"kty" => "RSA", "n" => Base.url_encode64(pub), "d" => Base.url_encode64(priv)}
    end
  end
end
