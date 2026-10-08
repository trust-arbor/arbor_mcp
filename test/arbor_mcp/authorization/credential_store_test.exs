defmodule Arbor.MCP.Authorization.CredentialStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.CredentialStore
  alias Arbor.MCP.Authorization.CredentialStore.{Registration, Token}
  alias Arbor.MCP.Authorization.Issuer

  defmodule AgentAdapter do
    @behaviour CredentialStore

    @impl true
    def fetch_registration(context, issuer, agent) do
      Agent.get(agent, fn state ->
        case state.registration_index[{context, issuer}] do
          nil -> :not_found
          key -> {:ok, key, state.registrations[key]}
        end
      end)
    end

    @impl true
    def put_registration(context, key, registration, agent) do
      Agent.update(agent, fn state ->
        issuer = elem(key, 3)

        state
        |> put_in([:registration_index, {context, issuer}], key)
        |> put_in([:registrations, key], registration)
      end)
    end

    @impl true
    def fetch_token(key, agent) do
      Agent.get(agent, fn state ->
        case state.tokens[key] do
          nil -> :not_found
          token -> {:ok, token}
        end
      end)
    end

    @impl true
    def put_token(key, token, agent) do
      Agent.update(agent, &put_in(&1, [:tokens, key], token))
    end
  end

  setup do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{registration_index: %{}, registrations: %{}, tokens: %{}}
      end)

    %{store: {AgentAdapter, agent}, agent: agent}
  end

  test "registrations are reused only for the exact issuer", %{store: store, agent: agent} do
    registration = %{
      issuer: "https://as.example",
      client_id: "client-1",
      client_secret: "secret",
      registration_method: :dynamic
    }

    assert :ok = CredentialStore.put_registration(store, "resource-1", registration)

    assert {:ok, %Registration{issuer: "https://as.example", client_id: "client-1"}} =
             CredentialStore.fetch_registration(store, "resource-1", "https://as.example")

    assert :not_found =
             CredentialStore.fetch_registration(store, "resource-1", "https://other.example")

    {:ok, old_key} = CredentialStore.registration_key("https://as.example", "client-1")

    Agent.update(agent, fn state ->
      put_in(
        state,
        [:registration_index, {"resource-1", "https://other.example"}],
        old_key
      )
    end)

    assert {:error,
            {:issuer_mismatch, expected: "https://other.example", actual: "https://as.example"}} =
             CredentialStore.fetch_registration(store, "resource-1", "https://other.example")
  end

  test "issuer keys use exact identifier comparison", %{store: store} do
    assert :ok = Issuer.compare("https://as.example", "https://as.example")

    assert {:error, {:issuer_mismatch, _details}} =
             Issuer.compare("https://as.example", "https://as.example/")

    assert {:ok, key_without_slash} =
             CredentialStore.registration_key("https://as.example", "client-1")

    assert {:ok, key_with_slash} =
             CredentialStore.registration_key("https://as.example/", "client-1")

    refute key_without_slash == key_with_slash

    assert :ok =
             CredentialStore.put_registration(store, "resource-1", %{
               issuer: "https://as.example/",
               client_id: "client-1",
               registration_method: :dynamic
             })

    assert :not_found =
             CredentialStore.fetch_registration(store, "resource-1", "https://as.example")
  end

  test "token keys cover the complete authorization partition and never token material", %{
    store: store
  } do
    token = token_fixture()

    assert :ok = CredentialStore.put_token(store, token)

    binding = Map.drop(token, [:access_token, :refresh_token, :token_type, :expires_at])
    binding = %{binding | granted_scopes: ["tools:write", "tools:read"]}

    assert {:ok, %Token{access_token: "access-secret", granted_scopes: scopes}} =
             CredentialStore.fetch_token(store, binding)

    assert scopes == ["tools:read", "tools:write"]

    assert {:ok, key} = CredentialStore.token_key(token)
    key_text = inspect(key)
    refute key_text =~ "access-secret"
    refute key_text =~ "refresh-secret"

    for changed <- [
          %{binding | issuer: "https://other.example"},
          %{binding | client_id: "client-2"},
          %{binding | resource: "https://resource.example/other"},
          %{binding | audience: "api-2"},
          %{binding | subject: "subject-2"},
          %{binding | granted_scopes: ["tools:read"]}
        ] do
      assert :not_found = CredentialStore.fetch_token(store, changed)
    end
  end

  test "unkeyed records require an explicit migration", %{store: store, agent: agent} do
    {:ok, registration_key} =
      CredentialStore.registration_key("https://as.example", "legacy-client")

    Agent.update(agent, fn state ->
      state
      |> put_in(
        [:registration_index, {"resource-1", "https://as.example"}],
        registration_key
      )
      |> put_in([:registrations, registration_key], %{
        client_id: "legacy-client",
        client_secret: "legacy-secret"
      })
    end)

    assert {:error, {:credential_migration_required, :registration}} =
             CredentialStore.fetch_registration(store, "resource-1", "https://as.example")

    assert {:ok, %Registration{issuer: "https://verified.example"}} =
             CredentialStore.bind_legacy_registration(
               %{client_id: "legacy-client", client_secret: "legacy-secret"},
               "https://verified.example"
             )

    binding = token_binding()
    {:ok, token_key} = CredentialStore.token_key(binding)

    Agent.update(agent, fn state ->
      put_in(state, [:tokens, token_key], %{
        client_id: "client-1",
        resource: binding.resource,
        client_identity: "client-1",
        granted_scopes: [],
        access_token: "legacy-access"
      })
    end)

    assert {:error, {:credential_migration_required, :token}} =
             CredentialStore.fetch_token(store, binding)

    assert {:ok, %Token{issuer: "https://as.example"}} =
             CredentialStore.bind_legacy_token(
               %{access_token: "legacy-access"},
               binding
             )
  end

  test "credential structs redact secrets from Inspect output" do
    {:ok, registration} =
      CredentialStore.bind_legacy_registration(
        %{client_id: "client-1", client_secret: "registration-secret"},
        "https://as.example"
      )

    {:ok, token} =
      CredentialStore.bind_legacy_token(%{access_token: "access-secret"}, token_binding())

    refute inspect(registration) =~ "registration-secret"
    refute inspect(token) =~ "access-secret"
  end

  defp token_fixture do
    token_binding()
    |> Map.merge(%{
      granted_scopes: ["tools:write", "tools:read", "tools:read"],
      access_token: "access-secret",
      refresh_token: "refresh-secret",
      token_type: "Bearer",
      expires_at: 2_000_000_000
    })
  end

  defp token_binding do
    %{
      issuer: "https://as.example",
      client_id: "client-1",
      resource: "https://resource.example/mcp",
      audience: "api-1",
      subject: "subject-1",
      client_identity: "client-1",
      granted_scopes: []
    }
  end
end
