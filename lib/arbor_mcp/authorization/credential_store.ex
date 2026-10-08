defmodule Arbor.MCP.Authorization.CredentialStore.Registration do
  @moduledoc """
  An OAuth client registration bound to one authorization-server issuer.

  The custom `Inspect` implementation redacts the client secret so routine
  logging and crash reports do not disclose it.
  """

  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:issuer, :client_id, :registration_method]
  defstruct [:issuer, :client_id, :client_secret, :registration_method]

  @type t :: %__MODULE__{
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t() | nil,
          registration_method: :dynamic | :pre_registered
        }
end

defmodule Arbor.MCP.Authorization.CredentialStore.Token do
  @moduledoc """
  OAuth tokens together with their complete, non-secret authorization binding.

  Access and refresh tokens are redacted by `Inspect`.
  """

  @derive {Inspect, except: [:access_token, :refresh_token]}
  @enforce_keys [:issuer, :client_id, :granted_scopes, :access_token]
  defstruct [
    :issuer,
    :client_id,
    :resource,
    :audience,
    :subject,
    :client_identity,
    :granted_scopes,
    :access_token,
    :refresh_token,
    :token_type,
    :expires_at
  ]

  @type t :: %__MODULE__{
          issuer: String.t(),
          client_id: String.t(),
          resource: String.t() | [String.t()] | nil,
          audience: String.t() | [String.t()] | nil,
          subject: String.t() | nil,
          client_identity: String.t() | nil,
          granted_scopes: [String.t()],
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t(),
          expires_at: integer() | nil
        }
end

defmodule Arbor.MCP.Authorization.CredentialStore do
  @moduledoc """
  Pluggable persistence boundary for issuer-bound OAuth credentials.

  ArborMCP deliberately does not ship a file-backed secret store. Applications
  can provide an OS keychain, encrypted database, or other appropriate adapter
  as either `AdapterModule` or `{AdapterModule, adapter_state}`.

  Registration records are stored under a versioned key containing the exact
  authorization-server issuer and client ID. Adapters may maintain a separate
  index from a non-secret local context (normally the MCP resource URL) to that
  key, but `fetch_registration/3` validates both the returned key and record
  before credentials can be reused.

  Token keys include the exact issuer and client ID plus resource, audience,
  subject/client identity, and granted scopes. Raw access and refresh tokens
  are never part of a key.

  Legacy records without an issuer are rejected with
  `{:credential_migration_required, kind}`. Call `bind_legacy_registration/2`
  or `bind_legacy_token/2` only after independently establishing the issuer;
  ArborMCP never attaches an unkeyed record to the currently discovered issuer.

  ## Adapter contract

  An adapter implements this behaviour. `context` must be a stable,
  non-secret local identifier. A registration fetch returns the exact storage
  key with the record so ArborMCP can reject a corrupt or cross-issuer index.
  """

  alias Arbor.MCP.Authorization.CredentialStore.{Registration, Token}
  alias Arbor.MCP.Authorization.Issuer

  @key_namespace :ex_mcp_oauth_credential
  @key_version 1

  @type registration_key ::
          {:ex_mcp_oauth_credential, 1, :registration, String.t(), String.t()}

  @type token_key ::
          {:ex_mcp_oauth_credential, 1, :token, String.t(), String.t(), term(), term(), term(),
           [String.t()]}

  @type key :: registration_key() | token_key()
  @type store :: module() | {module(), term()}
  @type context :: term()

  @callback fetch_registration(context(), issuer :: String.t(), adapter_state :: term()) ::
              {:ok, key(), Registration.t() | map()} | :not_found | {:error, term()}

  @callback put_registration(
              context(),
              registration_key(),
              Registration.t(),
              adapter_state :: term()
            ) :: :ok | {:error, term()}

  @callback fetch_token(token_key(), adapter_state :: term()) ::
              {:ok, Token.t() | map()} | :not_found | {:error, term()}

  @callback put_token(token_key(), Token.t(), adapter_state :: term()) ::
              :ok | {:error, term()}

  @doc "Builds the versioned persistence key for a client registration."
  @spec registration_key(String.t(), String.t()) ::
          {:ok, registration_key()} | {:error, term()}
  def registration_key(issuer, client_id)
      when is_binary(issuer) and issuer != "" and is_binary(client_id) and client_id != "" do
    {:ok, {@key_namespace, @key_version, :registration, issuer, client_id}}
  end

  def registration_key(issuer, _client_id) when not is_binary(issuer) or issuer == "",
    do: {:error, :missing_authorization_server_issuer}

  def registration_key(_issuer, _client_id), do: {:error, :invalid_client_id}

  @doc "Builds a complete token partition key without including token material."
  @spec token_key(Token.t() | map()) :: {:ok, token_key()} | {:error, term()}
  def token_key(token_or_binding) do
    with {:ok, binding} <- token_binding(token_or_binding),
         {:ok, resource} <- normalize_string_set(binding.resource, :resource),
         {:ok, audience} <- normalize_string_set(binding.audience, :audience),
         {:ok, identity} <- identity_partition(binding),
         {:ok, scopes} <- normalize_scopes(binding.granted_scopes) do
      {:ok,
       {@key_namespace, @key_version, :token, binding.issuer, binding.client_id, resource,
        audience, identity, scopes}}
    end
  end

  @doc "Fetches and validates a registration for an exact issuer."
  @spec fetch_registration(store(), context(), String.t()) ::
          {:ok, Registration.t()} | :not_found | {:error, term()}
  def fetch_registration(store, context, issuer) when is_binary(issuer) and issuer != "" do
    with {:ok, adapter, adapter_state} <- adapter(store),
         result <- call_adapter(adapter, :fetch_registration, [context, issuer, adapter_state]),
         {:ok, key, stored} <- normalize_registration_fetch(result),
         {:ok, registration} <- registration_from(stored),
         :ok <- Issuer.compare(issuer, registration.issuer),
         {:ok, expected_key} <- registration_key(registration.issuer, registration.client_id),
         :ok <- compare_storage_key(:registration, expected_key, key) do
      {:ok, registration}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  def fetch_registration(_store, _context, _issuer),
    do: {:error, :missing_authorization_server_issuer}

  @doc "Persists a validated issuer-bound registration."
  @spec put_registration(store(), context(), Registration.t() | map()) ::
          :ok | {:error, term()}
  def put_registration(store, context, registration) do
    with {:ok, adapter, adapter_state} <- adapter(store),
         {:ok, registration} <- registration_from(registration),
         {:ok, key} <- registration_key(registration.issuer, registration.client_id) do
      adapter
      |> call_adapter(:put_registration, [context, key, registration, adapter_state])
      |> normalize_put(:put_registration)
    end
  end

  @doc "Fetches a token only from its complete authorization partition."
  @spec fetch_token(store(), Token.t() | map()) ::
          {:ok, Token.t()} | :not_found | {:error, term()}
  def fetch_token(store, binding) do
    with {:ok, adapter, adapter_state} <- adapter(store),
         {:ok, key} <- token_key(binding),
         result <- call_adapter(adapter, :fetch_token, [key, adapter_state]),
         {:ok, stored} <- normalize_token_fetch(result),
         {:ok, token} <- token_from(stored),
         {:ok, stored_key} <- token_key(token),
         :ok <- compare_storage_key(:token, key, stored_key) do
      {:ok, token}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc "Persists a token under its complete, non-secret authorization key."
  @spec put_token(store(), Token.t() | map()) :: :ok | {:error, term()}
  def put_token(store, token) do
    with {:ok, adapter, adapter_state} <- adapter(store),
         {:ok, token} <- token_from(token),
         {:ok, key} <- token_key(token) do
      adapter
      |> call_adapter(:put_token, [key, token, adapter_state])
      |> normalize_put(:put_token)
    end
  end

  @doc "Explicitly binds a legacy registration after its issuer is independently verified."
  @spec bind_legacy_registration(map(), String.t()) ::
          {:ok, Registration.t()} | {:error, term()}
  def bind_legacy_registration(legacy, issuer) when is_map(legacy) do
    legacy
    |> Map.put(:issuer, issuer)
    |> registration_from()
  end

  @doc "Explicitly binds a legacy token after every partition field is independently verified."
  @spec bind_legacy_token(map(), map()) :: {:ok, Token.t()} | {:error, term()}
  def bind_legacy_token(legacy, binding) when is_map(legacy) and is_map(binding) do
    legacy
    |> Map.merge(binding)
    |> token_from()
  end

  defp registration_from(%Registration{} = registration) do
    validate_registration(registration)
  end

  defp registration_from(registration) when is_map(registration) do
    issuer = field(registration, :issuer)

    if is_nil(issuer) do
      {:error, {:credential_migration_required, :registration}}
    else
      registration = %Registration{
        issuer: issuer,
        client_id: field(registration, :client_id),
        client_secret: field(registration, :client_secret),
        registration_method: field(registration, :registration_method) || :dynamic
      }

      validate_registration(registration)
    end
  end

  defp registration_from(_registration), do: {:error, :invalid_stored_registration}

  defp validate_registration(%Registration{} = registration) do
    cond do
      not is_binary(registration.issuer) or registration.issuer == "" ->
        {:error, :missing_authorization_server_issuer}

      not is_binary(registration.client_id) or registration.client_id == "" ->
        {:error, :invalid_client_id}

      registration.registration_method not in [:dynamic, :pre_registered] ->
        {:error, :invalid_registration_method}

      not (is_binary(registration.client_secret) or is_nil(registration.client_secret)) ->
        {:error, :invalid_client_secret}

      true ->
        {:ok, registration}
    end
  end

  defp token_from(%Token{} = token), do: validate_token(token)

  defp token_from(token) when is_map(token) do
    issuer = field(token, :issuer)

    if is_nil(issuer) do
      {:error, {:credential_migration_required, :token}}
    else
      with {:ok, granted_scopes} <- normalize_scopes(field(token, :granted_scopes) || []) do
        token = %Token{
          issuer: issuer,
          client_id: field(token, :client_id),
          resource: field(token, :resource),
          audience: field(token, :audience),
          subject: field(token, :subject),
          client_identity: field(token, :client_identity),
          granted_scopes: granted_scopes,
          access_token: field(token, :access_token),
          refresh_token: field(token, :refresh_token),
          token_type: field(token, :token_type) || "Bearer",
          expires_at: field(token, :expires_at)
        }

        validate_token(token)
      end
    end
  end

  defp token_from(_token), do: {:error, :invalid_stored_token}

  defp validate_token(%Token{} = token) do
    with {:ok, _key} <- token_key_fields(token),
         true <- is_binary(token.access_token) and token.access_token != "" do
      {:ok, token}
    else
      false -> {:error, :invalid_access_token}
      {:error, _reason} = error -> error
    end
  end

  defp token_binding(token_or_binding) when is_map(token_or_binding) do
    binding = %{
      issuer: field(token_or_binding, :issuer),
      client_id: field(token_or_binding, :client_id),
      resource: field(token_or_binding, :resource),
      audience: field(token_or_binding, :audience),
      subject: field(token_or_binding, :subject),
      client_identity: field(token_or_binding, :client_identity),
      granted_scopes: field(token_or_binding, :granted_scopes) || []
    }

    token_key_fields(binding)
  end

  defp token_binding(_binding), do: {:error, :invalid_token_binding}

  defp token_key_fields(binding) do
    cond do
      not is_binary(binding.issuer) or binding.issuer == "" ->
        {:error, :missing_authorization_server_issuer}

      not is_binary(binding.client_id) or binding.client_id == "" ->
        {:error, :invalid_client_id}

      is_nil(binding.resource) and is_nil(binding.audience) ->
        {:error, :token_resource_or_audience_required}

      true ->
        {:ok, binding}
    end
  end

  defp identity_partition(%{subject: subject}) when is_binary(subject) and subject != "",
    do: {:ok, {:subject, subject}}

  defp identity_partition(%{client_identity: identity})
       when is_binary(identity) and identity != "",
       do: {:ok, {:client, identity}}

  defp identity_partition(_binding), do: {:error, :token_identity_required}

  defp normalize_string_set(nil, _field), do: {:ok, nil}
  defp normalize_string_set(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp normalize_string_set(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_token_partition, field}}
    end
  end

  defp normalize_string_set(_value, field), do: {:error, {:invalid_token_partition, field}}

  defp normalize_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split(" ", trim: true)
    |> normalize_scopes()
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &(is_binary(&1) and &1 != "")) do
      {:ok, scopes |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_token_partition, :granted_scopes}}
    end
  end

  defp normalize_scopes(_scopes), do: {:error, {:invalid_token_partition, :granted_scopes}}

  defp compare_storage_key(_kind, key, key), do: :ok

  defp compare_storage_key(kind, _expected, _actual),
    do: {:error, {:credential_partition_mismatch, kind}}

  defp normalize_registration_fetch({:ok, _key, _stored} = result), do: result
  defp normalize_registration_fetch(:not_found), do: :not_found
  defp normalize_registration_fetch({:error, _reason} = error), do: error

  defp normalize_registration_fetch(_result),
    do: {:error, {:invalid_credential_store_response, :fetch_registration}}

  defp normalize_token_fetch({:ok, _stored} = result), do: result
  defp normalize_token_fetch(:not_found), do: :not_found
  defp normalize_token_fetch({:error, _reason} = error), do: error

  defp normalize_token_fetch(_result),
    do: {:error, {:invalid_credential_store_response, :fetch_token}}

  defp normalize_put(:ok, _operation), do: :ok
  defp normalize_put({:error, _reason} = error, _operation), do: error

  defp normalize_put(_result, operation),
    do: {:error, {:invalid_credential_store_response, operation}}

  defp adapter({adapter, adapter_state}) when is_atom(adapter),
    do: {:ok, adapter, adapter_state}

  defp adapter(adapter) when is_atom(adapter), do: {:ok, adapter, nil}
  defp adapter(_store), do: {:error, :invalid_credential_store}

  defp call_adapter(adapter, function, args) do
    arity = length(args)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity) do
      case apply(adapter, function, args) do
        {:error, _reason} -> {:error, {:credential_store_error, function}}
        result -> result
      end
    else
      {:error, {:credential_store_callback_missing, function, arity}}
    end
  rescue
    _exception -> {:error, {:credential_store_error, function}}
  catch
    _kind, _reason -> {:error, {:credential_store_error, function}}
  end

  defp field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
