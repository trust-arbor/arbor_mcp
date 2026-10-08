defmodule Arbor.MCP.Authorization.ClientRegistrationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.ClientRegistration

  test "requires and emits an explicit application_type" do
    request = request()

    assert {:ok, body} = ClientRegistration.build_request(request)
    assert body.application_type == "native"

    assert {:error, {:missing_required_fields, fields}} =
             request
             |> Map.delete(:application_type)
             |> ClientRegistration.build_request()

    assert :application_type in fields

    assert {:error, {:invalid_application_type, "desktop"}} =
             request
             |> Map.put(:application_type, "desktop")
             |> ClientRegistration.build_request()
  end

  test "rejects insecure non-loopback redirect URIs" do
    assert {:error, {:invalid_redirect_uris, ["http://remote.example/callback"]}} =
             request()
             |> Map.put(:redirect_uris, ["http://remote.example/callback"])
             |> ClientRegistration.build_request()
  end

  defp request do
    %{
      registration_endpoint: "https://auth.example/register",
      client_name: "Arbor.MCP",
      application_type: "native",
      redirect_uris: ["http://127.0.0.1:8080/callback"],
      grant_types: ["authorization_code"],
      response_types: ["code"],
      scope: "mcp:read"
    }
  end
end
