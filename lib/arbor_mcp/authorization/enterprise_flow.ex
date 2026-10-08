defmodule Arbor.MCP.Authorization.EnterpriseFlow do
  @moduledoc """
  Client-side enterprise SSO orchestrator for MCP.

  Implements the enterprise-managed authorization flow using ID-JAG:
  1. (Pre-step) User authenticates with IdP via OIDC → obtains ID token
  2. Token Exchange at IdP: exchange ID token for ID-JAG
  3. JWT Bearer Grant at AS: present ID-JAG to get access token
  """

  alias Arbor.MCP.Authorization.{
    JWTBearerAssertion,
    OIDCDiscovery,
    TokenExchange
  }

  @type config :: %{
          required(:id_token) => String.t(),
          required(:idp_token_endpoint) => String.t(),
          required(:as_issuer) => String.t(),
          optional(:as_token_endpoint) => String.t(),
          optional(:resource_url) => String.t(),
          optional(:client_id) => String.t(),
          optional(:scope) => String.t(),
          optional(:http_client) => module() | function(),
          optional(:metadata_fetch) => keyword()
        }

  @doc """
  Executes the enterprise-managed authorization flow.

  Takes an OIDC ID token (from a prior authentication step) and:
  1. Discovers the AS token endpoint if not provided
  2. Exchanges the ID token for an ID-JAG at the IdP
  3. Presents the ID-JAG to the AS via JWT bearer grant to get an access token

  ## Config
    - `:id_token` (required) - OIDC ID token from prior authentication
    - `:idp_token_endpoint` (required) - IdP's token endpoint for token exchange
    - `:as_issuer` (required) - Authorization server's issuer URI
    - `:as_token_endpoint` - AS token endpoint (discovered if not provided)
    - `:resource_url` - MCP server resource URL
    - `:client_id` - OAuth client identifier
    - `:scope` - Requested scope
    - `:http_client` - Custom pinned-address HTTP client for discovery
    - `:metadata_fetch` - Metadata timeout, size, DNS and redirect-policy options
  """
  @spec execute(config()) :: {:ok, map()} | {:error, term()}
  def execute(config) do
    with {:ok, as_token_endpoint} <- resolve_as_token_endpoint(config),
         {:ok, exchange_result} <- exchange_for_id_jag(config) do
      present_id_jag_to_as(exchange_result, as_token_endpoint, config)
    end
  end

  @doc """
  Discovers the IdP's OIDC endpoints and builds an authorization URL for Step 1.

  This is a helper for initiating the OIDC authentication step before
  the enterprise flow can proceed.

  ## Options
    - `:idp_issuer` (required) - The IdP's issuer URI
    - `:client_id` (required) - OAuth client identifier at the IdP
    - `:redirect_uri` (required) - Callback URI for OIDC code flow
    - `:scope` - Requested OIDC scopes (default: "openid")
    - `:state` - CSRF state parameter
    - `:nonce` - OIDC nonce parameter
    - `:http_client` - Custom HTTP client module
  """
  @spec prepare_oidc_auth(keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_oidc_auth(opts) do
    idp_issuer = Keyword.fetch!(opts, :idp_issuer)
    client_id = Keyword.fetch!(opts, :client_id)
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    scope = Keyword.get(opts, :scope, "openid")
    state = Keyword.get(opts, :state, generate_state())
    nonce = Keyword.get(opts, :nonce, generate_nonce())

    case OIDCDiscovery.discover(idp_issuer, metadata_fetch_options(opts)) do
      {:ok, metadata} ->
        auth_endpoint = Map.fetch!(metadata, "authorization_endpoint")

        query_params =
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id,
            "redirect_uri" => redirect_uri,
            "scope" => scope,
            "state" => state,
            "nonce" => nonce
          })

        auth_url = "#{auth_endpoint}?#{query_params}"

        {:ok,
         %{
           authorization_url: auth_url,
           state: state,
           nonce: nonce,
           token_endpoint: Map.get(metadata, "token_endpoint"),
           idp_metadata: metadata
         }}

      {:error, reason} ->
        {:error, {:idp_discovery_failed, reason}}
    end
  end

  # Private helpers

  defp resolve_as_token_endpoint(%{as_token_endpoint: endpoint}) when is_binary(endpoint) do
    {:ok, endpoint}
  end

  defp resolve_as_token_endpoint(%{as_issuer: as_issuer} = config) do
    case OIDCDiscovery.discover(as_issuer, metadata_fetch_options(config)) do
      {:ok, metadata} ->
        case Map.get(metadata, "token_endpoint") do
          nil -> {:error, :missing_token_endpoint}
          endpoint -> {:ok, endpoint}
        end

      {:error, reason} ->
        {:error, {:as_discovery_failed, reason}}
    end
  end

  defp resolve_as_token_endpoint(_) do
    {:error, :missing_as_issuer}
  end

  # Step 2: Exchange ID token for ID-JAG at IdP
  defp exchange_for_id_jag(config) do
    exchange_opts = [
      token_endpoint: config.idp_token_endpoint,
      id_token: config.id_token,
      audience: config.as_issuer
    ]

    exchange_opts =
      exchange_opts
      |> maybe_add_opt(config, :resource_url, :resource)
      |> maybe_add_opt(config, :client_id, :client_id)
      |> maybe_add_opt(config, :scope, :scope)

    TokenExchange.exchange_id_token_for_id_jag(exchange_opts)
  end

  # Step 3: Present ID-JAG to AS via JWT bearer grant
  defp present_id_jag_to_as(exchange_result, as_token_endpoint, config) do
    # The exchange result should contain the ID-JAG as the access_token
    id_jag = exchange_result.access_token

    grant_opts = [
      token_endpoint: as_token_endpoint,
      assertion: id_jag
    ]

    grant_opts =
      grant_opts
      |> maybe_add_opt(config, :client_id, :client_id)
      |> maybe_add_opt(config, :scope, :scope)
      |> maybe_add_opt(config, :resource_url, :resource)

    JWTBearerAssertion.grant(grant_opts)
  end

  defp maybe_add_opt(opts, config, config_key, opt_key) do
    case Map.get(config, config_key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, value)
    end
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

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
