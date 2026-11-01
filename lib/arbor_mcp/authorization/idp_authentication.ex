defmodule Arbor.MCP.Authorization.IdPAuthentication do
  @moduledoc false

  alias Arbor.MCP.Authorization.{ClientAssertion, HTTPClient, OIDCDiscovery}

  @config_keys ~w(issuer client_id auth_method client_secret private_key signing_algorithm key_id)a
  @asymmetric_algorithms ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)
  @credential_keys [
    :client_id,
    :client_secret,
    :client_assertion,
    :client_assertion_type,
    "client_id",
    "client_secret",
    "client_assertion",
    "client_assertion_type"
  ]

  @spec exchange(list(), map()) :: {:ok, map()} | {:error, term()}
  def exchange(body, config), do: exchange(body, config, &HTTPClient.make_token_request/3)

  def exchange(body, config, request) do
    with {:ok, auth} <- validate_config(config[:idp_auth]),
         :ok <- match_legacy(config, :idp_issuer, auth.issuer),
         :ok <- match_legacy(config, :idp_client_id, auth.client_id),
         {:ok, metadata} <- discover(auth.issuer, config),
         endpoint = metadata["token_endpoint"],
         :ok <- match_legacy(config, :idp_token_endpoint, endpoint),
         :ok <- validate_method(metadata, auth.auth_method),
         {:ok, credentials} <-
           credentials(auth, metadata, config[:client_assertion_audience] || endpoint),
         {:ok, options} <- request_options(config, auth.auth_method) do
      body = Enum.reject(body, fn {key, _value} -> key in @credential_keys end)
      request.(endpoint, body ++ credentials, options)
    end
  end

  def validate_config(auth) when is_map(auth) do
    cond do
      Map.keys(auth) -- @config_keys != [] -> invalid(:unknown_option)
      not nonempty_string?(auth[:issuer]) -> invalid(:issuer)
      not nonempty_string?(auth[:client_id]) -> invalid(:client_id)
      true -> validate_credentials(auth)
    end
  end

  def validate_config(_auth), do: invalid(:config)

  defp validate_credentials(%{auth_method: method} = auth)
       when method in [:client_secret_basic, :client_secret_post] do
    if nonempty_string?(auth[:client_secret]), do: {:ok, auth}, else: invalid(:client_secret)
  end

  defp validate_credentials(%{auth_method: :private_key_jwt} = auth) do
    cond do
      is_nil(auth[:private_key]) ->
        invalid(:private_key)

      Map.get(auth, :signing_algorithm, "RS256") not in @asymmetric_algorithms ->
        invalid(:signing_algorithm)

      not is_nil(auth[:key_id]) and not nonempty_string?(auth[:key_id]) ->
        invalid(:key_id)

      true ->
        {:ok, auth}
    end
  end

  defp validate_credentials(_auth), do: invalid(:auth_method)

  defp nonempty_string?(value),
    do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp invalid(field), do: {:error, {:invalid_idp_auth, field}}

  defp match_legacy(config, field, expected) do
    case Map.get(config, field) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, {:idp_auth_config_mismatch, field}}
    end
  end

  defp discover(issuer, config) do
    options = config[:metadata_fetch] || []

    options =
      if config[:http_client],
        do: Keyword.put(options, :http_client, config.http_client),
        else: options

    case OIDCDiscovery.discover(issuer, options) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, {:idp_discovery_failed, reason}}
    end
  end

  defp validate_method(metadata, method) do
    supported =
      Map.get(metadata, "token_endpoint_auth_methods_supported", ["client_secret_basic"])

    if is_list(supported) and Enum.all?(supported, &is_binary/1) and
         Atom.to_string(method) in supported do
      :ok
    else
      {:error, :idp_auth_method_not_supported}
    end
  end

  defp credentials(%{auth_method: :private_key_jwt} = auth, metadata, endpoint) do
    algorithm = Map.get(auth, :signing_algorithm, "RS256")

    with :ok <- validate_signing_algorithm(metadata, algorithm) do
      # OIDC client authentication targets the discovered IdP token endpoint;
      # the separate token-exchange audience identifies the resource AS.
      case ClientAssertion.build_assertion_params(
             client_id: auth.client_id,
             token_endpoint: endpoint,
             private_key: auth.private_key,
             alg: algorithm,
             kid: auth[:key_id]
           ) do
        {:ok, params} -> {:ok, params}
        {:error, _reason} -> {:error, :idp_client_assertion_failed}
      end
    end
  end

  defp credentials(auth, _metadata, _endpoint),
    do: {:ok, [{"client_id", auth.client_id}, {"client_secret", auth.client_secret}]}

  defp validate_signing_algorithm(metadata, algorithm) do
    case Map.fetch(metadata, "token_endpoint_auth_signing_alg_values_supported") do
      :error ->
        :ok

      {:ok, supported} when is_list(supported) ->
        if Enum.all?(supported, &is_binary/1) and algorithm in supported,
          do: :ok,
          else: {:error, :idp_signing_algorithm_not_supported}

      _other ->
        {:error, :idp_signing_algorithm_not_supported}
    end
  end

  defp request_options(config, method) do
    options = config[:oauth_http] || []

    if Keyword.keyword?(options),
      do: {:ok, Keyword.put(options, :auth_method, method)},
      else: invalid(:oauth_http)
  end
end
