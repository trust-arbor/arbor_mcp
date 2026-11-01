defmodule Arbor.MCP.Authorization.ResourceASAuthenticationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{JWT, ResourceASAuthentication}

  @tag assurance: ["ema.cimd.supported"]
  test "explicit CIMD registration requires server support and a valid metadata URL" do
    client_id = "https://client.example/metadata.json"
    config = config(client_id)
    metadata = metadata(true)

    assert {:ok, %{client_id: ^client_id, registration_method: :cimd}} =
             ResourceASAuthentication.client_info(metadata, config)
  end

  @tag assurance: ["ema.cimd.unsupported"]
  test "explicit CIMD does not bypass the AS support check" do
    assert {:error, :cimd_not_supported} =
             ResourceASAuthentication.client_info(
               metadata(false),
               config("https://client.example/metadata.json")
             )
  end

  @tag assurance: ["ema.cimd.invalid_url"]
  test "explicit CIMD cannot use a non-URL client identifier" do
    assert {:error, _reason} =
             ResourceASAuthentication.client_info(metadata(true), config("not-a-url"))
  end

  defp metadata(supported),
    do: %{
      "issuer" => "https://as.example",
      "token_endpoint" => "https://as.example/token",
      "client_id_metadata_document_supported" => supported
    }

  defp config(client_id) do
    %{
      client_registration: {:cimd, client_id},
      as_auth: %{
        issuer: "https://as.example",
        client_id: client_id,
        auth_method: :private_key_jwt,
        private_key: JWT.generate_ec_key(),
        signing_algorithm: "ES256"
      }
    }
  end
end
