defmodule Arbor.MCP.Authorization.ClientRegistrationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.ClientRegistration

  @tag assurance: ["oauth.dcr.type"]

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

  for operation <- [:register, :get, :update] do
    @operation operation
    @tag :registration_response
    @tag assurance: ["oauth.dcr.response.#{operation}"]
    test "#{@operation} rejects malformed registration success responses" do
      for response <- [%{}, %{"client_id" => nil}, %{"client_id" => 42}, [], nil] do
        bypass = Bypass.open()

        Bypass.expect_once(bypass, fn conn ->
          Plug.Conn.resp(
            conn,
            if(@operation == :register, do: 201, else: 200),
            Jason.encode!(response)
          )
        end)

        endpoint = "http://localhost:#{bypass.port}/register"

        result =
          case @operation do
            :register ->
              ClientRegistration.register_client(
                Map.put(request(), :registration_endpoint, endpoint)
              )

            :get ->
              ClientRegistration.get_client_information(endpoint, "fixture-registration-token")

            :update ->
              ClientRegistration.update_client_information(
                endpoint,
                "fixture-registration-token",
                %{}
              )
          end

        assert {:error, :invalid_registration_response} = result
      end
    end
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
