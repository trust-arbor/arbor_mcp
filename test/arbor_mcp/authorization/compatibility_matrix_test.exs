defmodule Arbor.MCP.Authorization.CompatibilityMatrixTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{CredentialStore, OAuthFlow, RegistrationPolicy}
  alias Arbor.MCP.Authorization.Provider.OAuth, as: OAuthProvider
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Transport.HTTP

  @issuer "https://auth.example"
  @cimd_url "https://client.example/oauth/metadata.json"
  @protocol_modes [:legacy_only, :prefer_legacy, :prefer_modern, :modern_only]

  test "registration strategies remain deterministic across every enabled protocol mode" do
    metadata = authorization_server_metadata()

    strategies = [
      {:pre_registered,
       %{
         client_registration: {:pre_registered, "client-1", nil},
         credential_issuer: @issuer
       }},
      {:cimd, %{client_registration: {:cimd, @cimd_url}}},
      {:dynamic, %{client_registration: :auto, application_type: :native, redirect_port: 8_080}},
      {:dynamic, %{client_registration: :auto, application_type: :web, redirect_port: 8_080}}
    ]

    for {mode, version} <- enabled_mode_versions(), {expected, config} <- strategies do
      config = Map.merge(config, %{protocol_mode: mode, protocol_version: version})

      assert {:ok, {^expected, selection}} = RegistrationPolicy.select(metadata, config)

      if expected == :dynamic do
        assert selection.application_type == config.application_type
      end
    end
  end

  test "legacy credential aliases are issuer-bound whenever the settled HTTP era is modern" do
    metadata = authorization_server_metadata()

    for {_mode, version} <- enabled_mode_versions() do
      config = %{
        client_id: "legacy-client",
        client_secret: "legacy-secret",
        protocol_version: version
      }

      if VersionRegistry.modern?(version) do
        assert {:error, {:pre_registered_credential_issuer_required, @issuer}} =
                 RegistrationPolicy.select(metadata, config)
      else
        assert {:ok, {:pre_registered, selection}} =
                 RegistrationPolicy.select(metadata, config)

        assert selection.client_id == "legacy-client"
      end

      assert {:ok, {:pre_registered, bound}} =
               RegistrationPolicy.select(metadata, Map.put(config, :credential_issuer, @issuer))

      assert bound.issuer == @issuer
    end
  end

  test "RFC 9207 issuer validation is identical for every legacy and modern version" do
    for {_mode, version} <- enabled_mode_versions() do
      transaction = %{
        state_param: "state-1",
        issuer: @issuer,
        protocol_version: version
      }

      assert {:ok, "code-1"} =
               OAuthFlow.validate_authorization_response(
                 %{"code" => "code-1", "state" => "state-1", "iss" => @issuer},
                 transaction
               )

      assert {:ok, "code-1"} =
               OAuthFlow.validate_authorization_response(
                 %{"code" => "code-1", "state" => "state-1"},
                 transaction
               )

      assert {:error, {:issuer_mismatch, expected: @issuer, actual: "https://other.example"}} =
               OAuthFlow.validate_authorization_response(
                 %{
                   "code" => "code-1",
                   "state" => "state-1",
                   "iss" => "https://other.example"
                 },
                 transaction
               )
    end
  end

  test "HTTP auth receives the exact settled version in synchronous and SSE modes" do
    auth = %{
      client_registration: {:pre_registered, "client-1", nil},
      credential_issuer: @issuer
    }

    for {mode, version} <- enabled_mode_versions(), use_sse <- [false, true] do
      assert {:ok, state} =
               HTTP.connect(
                 url: "https://resource.example/mcp",
                 protocol_version: version,
                 protocol_mode: mode,
                 use_sse: use_sse,
                 auth: auth
               )

      assert state.protocol_version == version
      assert state.use_sse == use_sse
      assert state.auth_provider == OAuthProvider

      assert %OAuthProvider{protocol_version: ^version, auth_config: provider_config} =
               state.auth_provider_state

      assert provider_config.protocol_version == version
      assert provider_config.resource_url == state.base_url <> state.endpoint
      assert provider_config.client_registration == auth.client_registration
      assert provider_config.credential_issuer == @issuer
    end
  end

  test "issuer and authorization dimensions produce distinct credential partitions" do
    assert {:ok, registration_key} =
             CredentialStore.registration_key(@issuer, "client-1")

    for {issuer, client_id} <- [
          {"https://other.example", "client-1"},
          {@issuer, "client-2"}
        ] do
      assert {:ok, changed_key} = CredentialStore.registration_key(issuer, client_id)
      refute changed_key == registration_key
    end

    binding = token_binding()
    assert {:ok, token_key} = CredentialStore.token_key(binding)

    changes = [
      issuer: "https://other.example",
      client_id: "client-2",
      resource: "https://resource.example/other",
      audience: "api-2",
      subject: "subject-2",
      granted_scopes: ["tools:read"]
    ]

    for {field, value} <- changes do
      assert {:ok, changed_key} = CredentialStore.token_key(Map.put(binding, field, value))
      refute changed_key == token_key
    end

    client_binding = %{binding | subject: nil}
    assert {:ok, client_key} = CredentialStore.token_key(client_binding)

    assert {:ok, changed_client_key} =
             CredentialStore.token_key(%{client_binding | client_identity: "workload-2"})

    refute changed_client_key == client_key

    assert {:ok, ^token_key} =
             CredentialStore.token_key(%{
               binding
               | granted_scopes: ["tools:write", "tools:read", "tools:read"]
             })
  end

  defp enabled_mode_versions do
    for mode <- @protocol_modes,
        version <- VersionRegistry.enabled_versions(mode),
        do: {mode, version}
  end

  defp authorization_server_metadata do
    %{
      "issuer" => @issuer,
      "client_id_metadata_document_supported" => true,
      "registration_endpoint" => "https://auth.example/register"
    }
  end

  defp token_binding do
    %{
      issuer: @issuer,
      client_id: "client-1",
      resource: "https://resource.example/mcp",
      audience: "api-1",
      subject: "subject-1",
      client_identity: "workload-1",
      granted_scopes: ["tools:read", "tools:write"]
    }
  end
end
