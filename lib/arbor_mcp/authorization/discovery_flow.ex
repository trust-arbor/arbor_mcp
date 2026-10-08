defmodule Arbor.MCP.Authorization.DiscoveryFlow do
  @moduledoc """
  Full 401 -> discovery -> auth orchestrator for MCP OAuth.

  Coordinates the complete flow from discovering authorization server
  metadata to obtaining an access token, supporting both client_secret
  and private_key_jwt authentication methods.
  """

  alias Arbor.MCP.Authorization.{OAuthFlow, OIDCDiscovery, ProtectedResourceMetadata}

  @type auth_method :: :client_secret | :private_key_jwt

  @type config :: %{
          required(:resource_url) => String.t(),
          required(:client_id) => String.t(),
          required(:auth_method) => auth_method(),
          optional(:client_secret) => String.t(),
          optional(:private_key) => JOSE.JWK.t(),
          optional(:alg) => String.t(),
          optional(:kid) => String.t(),
          optional(:scopes) => [String.t()],
          optional(:resource) => String.t() | [String.t()],
          optional(:http_client) => module() | function(),
          optional(:metadata_fetch) => keyword()
        }

  @doc """
  Executes the full discovery-to-token flow.

  1. Discovers the authorization server via Protected Resource Metadata (RFC 9728)
  2. Fetches AS metadata via OIDC Discovery / RFC 8414
  3. Selects authentication method based on config and server capabilities
  4. Obtains an access token via client credentials flow

  ## Config
    - `:resource_url` (required) - The MCP server resource URL
    - `:client_id` (required) - OAuth client identifier
    - `:auth_method` (required) - `:client_secret` or `:private_key_jwt`
    - `:client_secret` - Required when auth_method is `:client_secret`
    - `:private_key` - Required when auth_method is `:private_key_jwt`
    - `:alg` - Signing algorithm for JWT auth (default: "RS256")
    - `:kid` - Key ID for JWT auth
    - `:scopes` - Requested scopes
    - `:resource` - RFC 8707 resource parameter(s)
    - `:http_client` - Custom pinned-address HTTP client for metadata discovery
    - `:metadata_fetch` - Metadata timeout, size, DNS and redirect-policy options
  """
  @spec execute(config()) :: {:ok, map()} | {:error, term()}
  def execute(config) do
    with {:ok, as_info} <- discover_authorization_server(config),
         {:ok, as_metadata} <- discover_as_metadata(as_info, config),
         {:ok, auth_method} <- select_auth_method(config, as_metadata),
         {:ok, token} <- obtain_token(auth_method, as_metadata, config) do
      {:ok, Map.put(token, :authorization_server, as_info)}
    end
  end

  # Step 1: Discover which AS protects the resource
  defp discover_authorization_server(%{resource_url: resource_url} = config) do
    case ProtectedResourceMetadata.discover(resource_url, metadata_fetch_options(config)) do
      {:ok, %{authorization_servers: [first | _]}} ->
        {:ok, first}

      {:ok, %{authorization_servers: []}} ->
        {:error, :no_authorization_servers}

      {:error, reason} ->
        {:error, {:discovery_failed, reason}}
    end
  end

  # Step 2: Fetch AS metadata (token_endpoint, supported auth methods, etc.)
  defp discover_as_metadata(as_info, config) do
    case OIDCDiscovery.discover(as_info.issuer, metadata_fetch_options(config)) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, reason} ->
        {:error, {:as_metadata_discovery_failed, reason}}
    end
  end

  # Step 3: Select auth method based on config preference and server capabilities
  defp select_auth_method(%{auth_method: :private_key_jwt} = config, as_metadata) do
    supported = Map.get(as_metadata, "token_endpoint_auth_methods_supported", [])

    if supported == [] or "private_key_jwt" in supported do
      if Map.has_key?(config, :private_key) do
        {:ok, :private_key_jwt}
      else
        {:error, :missing_private_key}
      end
    else
      {:error, {:auth_method_not_supported, :private_key_jwt, supported}}
    end
  end

  defp select_auth_method(%{auth_method: :client_secret} = config, _as_metadata) do
    if Map.has_key?(config, :client_secret) do
      {:ok, :client_secret}
    else
      {:error, :missing_client_secret}
    end
  end

  defp select_auth_method(%{auth_method: method}, _) do
    {:error, {:invalid_auth_method, method}}
  end

  # Step 4: Obtain token using selected method
  defp obtain_token(:client_secret, as_metadata, config) do
    token_endpoint = Map.fetch!(as_metadata, "token_endpoint")

    params = %{
      client_id: config.client_id,
      client_secret: config.client_secret,
      token_endpoint: token_endpoint
    }

    params = maybe_add_optional(params, config, [:scopes, :resource])
    OAuthFlow.client_credentials_flow(params)
  end

  defp obtain_token(:private_key_jwt, as_metadata, config) do
    token_endpoint = Map.fetch!(as_metadata, "token_endpoint")

    params = %{
      client_id: config.client_id,
      private_key: config.private_key,
      token_endpoint: token_endpoint
    }

    params = maybe_add_optional(params, config, [:scopes, :resource, :alg, :kid])
    OAuthFlow.client_credentials_jwt_flow(params)
  end

  defp maybe_add_optional(params, config, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(config, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp metadata_fetch_options(config) do
    options =
      case config[:metadata_fetch] do
        configured when is_list(configured) -> configured
        _other -> []
      end

    case config[:http_client] do
      nil -> options
      client -> Keyword.put(options, :http_client, client)
    end
  end
end
