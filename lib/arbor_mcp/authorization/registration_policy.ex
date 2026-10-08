defmodule Arbor.MCP.Authorization.RegistrationPolicy do
  @moduledoc """
  Selects the OAuth client registration mechanism for an authorization server.

  The modern priority is pre-registration, configured Client ID Metadata
  Document, deprecated Dynamic Client Registration, then an actionable error.
  A metadata URL is never invented and `application_type` is never inferred.

  For modern MCP, pre-registered credentials also require a
  `:credential_issuer` configuration value. It is compared exactly with the
  discovered authorization-server issuer before any secret reference is
  resolved. Client ID Metadata Document identifiers remain portable across
  authorization servers.

  Existing `client_id`, `client_secret`, and `client_metadata_url` keys remain
  accepted as compatibility aliases for the explicit `:client_registration`
  option.
  """

  alias Arbor.MCP.Authorization.{ClientIdMetadata, Issuer}
  alias Arbor.MCP.Internal.VersionRegistry

  @type application_type :: :native | :web
  @type secret_ref ::
          nil
          | String.t()
          | {:env, String.t()}
          | (-> String.t() | nil | {:ok, String.t() | nil} | {:error, term()})

  @type configured_strategy ::
          :auto
          | {:pre_registered, String.t(), secret_ref()}
          | {:cimd, String.t()}

  @type selection ::
          {:pre_registered, map()}
          | {:cimd, map()}
          | {:dynamic, map()}

  @doc "Selects and validates a registration mechanism without network calls."
  @spec select(map(), map()) :: {:ok, selection()} | {:error, term()}
  def select(as_metadata, config) when is_map(as_metadata) and is_map(config) do
    strategy = configured_strategy(config)

    case strategy do
      {:pre_registered, client_id, secret_ref} ->
        select_pre_registered(client_id, secret_ref, as_metadata, config)

      {:cimd, client_id_url} ->
        select_cimd(client_id_url, as_metadata, config)

      :auto ->
        select_auto(as_metadata, config)

      invalid ->
        {:error, {:invalid_client_registration, invalid}}
    end
  end

  def select(_as_metadata, _config), do: {:error, :invalid_client_registration_config}

  defp configured_strategy(%{client_registration: strategy}), do: strategy

  defp configured_strategy(%{client_id: client_id} = config)
       when is_binary(client_id) and client_id != "" do
    {:pre_registered, client_id, Map.get(config, :client_secret)}
  end

  defp configured_strategy(_config), do: :auto

  defp select_pre_registered(client_id, secret_ref, as_metadata, config)
       when is_binary(client_id) and client_id != "" do
    discovered_issuer = as_metadata["issuer"]

    with :ok <- validate_pre_registered_issuer(discovered_issuer, config),
         {:ok, client_secret} <- resolve_secret(secret_ref) do
      {:ok,
       {:pre_registered,
        %{
          issuer: discovered_issuer,
          client_id: client_id,
          client_secret: client_secret,
          registration_method: :pre_registered
        }}}
    end
  end

  defp select_pre_registered(_client_id, _secret_ref, _as_metadata, _config),
    do: {:error, :invalid_pre_registered_client_id}

  defp validate_pre_registered_issuer(discovered_issuer, %{credential_issuer: expected_issuer}) do
    case Issuer.compare(expected_issuer, discovered_issuer) do
      :ok ->
        :ok

      {:error, {:issuer_mismatch, details}} ->
        {:error, {:pre_registered_credential_issuer_mismatch, details}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_pre_registered_issuer(discovered_issuer, config) do
    if explicit_pre_registration?(config) or VersionRegistry.modern?(config[:protocol_version]) do
      {:error, {:pre_registered_credential_issuer_required, discovered_issuer}}
    else
      :ok
    end
  end

  defp explicit_pre_registration?(%{
         client_registration: {:pre_registered, _client_id, _secret_ref}
       }),
       do: true

  defp explicit_pre_registration?(_config), do: false

  defp select_cimd(client_id_url, as_metadata, config) do
    with true <- ClientIdMetadata.supported?(as_metadata),
         :ok <- ClientIdMetadata.validate_url(client_id_url) do
      {:ok,
       {:cimd,
        %{
          client_id: client_id_url,
          private_key: Map.get(config, :private_key),
          signing_algorithm: Map.get(config, :signing_algorithm),
          key_id: Map.get(config, :key_id),
          registration_method: :cimd
        }}}
    else
      false -> {:error, :cimd_not_supported}
      {:error, _reason} = error -> error
    end
  end

  defp select_auto(as_metadata, config) do
    cond do
      is_binary(config[:client_id]) and config[:client_id] != "" ->
        select_pre_registered(config.client_id, config[:client_secret], as_metadata, config)

      is_binary(config[:client_metadata_url]) and ClientIdMetadata.supported?(as_metadata) ->
        select_cimd(config.client_metadata_url, as_metadata, config)

      is_binary(as_metadata["registration_endpoint"]) ->
        select_dynamic(as_metadata["registration_endpoint"], config)

      ClientIdMetadata.supported?(as_metadata) ->
        {:error, {:client_registration_required, :configure_cimd_url}}

      true ->
        {:error, {:client_registration_required, :pre_register_client}}
    end
  end

  defp select_dynamic(registration_endpoint, config) do
    with {:ok, application_type} <- application_type(config),
         :ok <- validate_redirect_port(config) do
      {:ok,
       {:dynamic,
        %{
          registration_endpoint: registration_endpoint,
          application_type: application_type,
          registration_method: :dynamic
        }}}
    end
  end

  defp application_type(%{application_type: type}) when type in [:native, :web], do: {:ok, type}

  defp application_type(%{application_type: type}),
    do: {:error, {:invalid_application_type, type}}

  defp application_type(_config), do: {:error, :application_type_required}

  defp validate_redirect_port(%{redirect_port: port})
       when is_integer(port) and port in 1..65_535,
       do: :ok

  defp validate_redirect_port(_config), do: {:error, :redirect_port_required}

  defp resolve_secret(nil), do: {:ok, nil}
  defp resolve_secret(secret) when is_binary(secret), do: {:ok, secret}

  defp resolve_secret({:env, variable}) when is_binary(variable) and variable != "" do
    case System.fetch_env(variable) do
      {:ok, secret} when secret != "" -> {:ok, secret}
      _missing -> {:error, :client_secret_unavailable}
    end
  end

  defp resolve_secret(resolver) when is_function(resolver, 0) do
    resolve_secret_result(resolver)
  rescue
    _exception -> {:error, :client_secret_resolver_failed}
  catch
    _kind, _reason -> {:error, :client_secret_resolver_failed}
  end

  defp resolve_secret(_secret_ref), do: {:error, :invalid_client_secret_reference}

  defp resolve_secret_result(resolver) do
    case resolver.() do
      {:ok, secret} when is_binary(secret) or is_nil(secret) -> {:ok, secret}
      {:error, _reason} = error -> error
      secret when is_binary(secret) or is_nil(secret) -> {:ok, secret}
      _invalid -> {:error, :invalid_client_secret}
    end
  end
end
