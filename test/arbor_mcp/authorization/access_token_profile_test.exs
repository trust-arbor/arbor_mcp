defmodule Arbor.MCP.Authorization.AccessTokenProfileTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.AuthExtensionFixture
  alias Arbor.MCP.Authorization.FullOAuthFlow

  for profile <- [:client_credentials, :enterprise] do
    @profile profile
    for {type, label} <- [{"MAC", "mac"}, {nil, "null"}, {42, "number"}] do
      @token_type type
      @tag :bearer_profile
      @tag assurance: ["access.#{profile}.reject.#{label}"]
      test "#{@profile} cannot supply an unsupported #{@token_type} token to the Bearer transport" do
        config =
          config(@profile, %{"access_token" => "unexpected-token", "token_type" => @token_type})

        assert {:error, :invalid_token_response} = FullOAuthFlow.execute(config)
      end
    end

    @tag :bearer_profile
    @tag assurance: ["access.#{profile}.empty"]
    test "#{@profile} rejects an empty AS access token" do
      assert {:error, :invalid_token_response} =
               FullOAuthFlow.execute(
                 config(
                   @profile,
                   %{"access_token" => "", "token_type" => "Bearer"}
                 )
               )
    end

    @tag :bearer_profile
    @tag assurance: ["access.#{profile}.case_insensitive"]
    test "#{@profile} accepts case-insensitive Bearer token types" do
      assert {:ok, %{access_token: "accepted-token"}} =
               FullOAuthFlow.execute(
                 config(
                   @profile,
                   %{"access_token" => "accepted-token", "token_type" => "bEaReR"}
                 )
               )
    end
  end

  defp config(profile, response) do
    grants =
      if profile == :client_credentials,
        do: ["client_credentials"],
        else: ["urn:ietf:params:oauth:grant-type:jwt-bearer"]

    config = AuthExtensionFixture.config(grants: grants, as_response: response)

    if profile == :client_credentials do
      config
      |> Map.drop([:id_token, :idp_id_token, :idp_auth, :idp_token_endpoint])
      |> Map.merge(%{client_secret: "fake-as-secret", auth_method: :client_secret})
    else
      Map.put(config, :as_auth, %{
        issuer: config.as_issuer,
        client_id: "as-client",
        auth_method: :client_secret_basic,
        client_secret: "fake-as-secret"
      })
    end
  end
end
