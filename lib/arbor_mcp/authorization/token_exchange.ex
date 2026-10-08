defmodule Arbor.MCP.Authorization.TokenExchange do
  @moduledoc """
  RFC 8693 Token Exchange implementation.

  Supports exchanging one token for another, used in the enterprise-managed
  authorization flow to exchange an OIDC ID token for an ID-JAG.
  """

  alias Arbor.MCP.Authorization.{HTTPClient, Validator}

  @grant_type "urn:ietf:params:oauth:grant-type:token-exchange"

  # Standard token type identifiers
  @token_type_access "urn:ietf:params:oauth:token-type:access_token"
  @token_type_id "urn:ietf:params:oauth:token-type:id_token"
  @token_type_id_jag "urn:ietf:params:oauth:token-type:id-jag"

  @doc """
  Performs a generic RFC 8693 token exchange.

  ## Options
    - `:token_endpoint` (required) - The token endpoint URL
    - `:subject_token` (required) - The token to exchange
    - `:subject_token_type` (required) - Type URI of the subject token
    - `:requested_token_type` - Type URI of the desired token
    - `:audience` - Target audience for the exchanged token
    - `:scope` - Requested scope
    - `:resource` - Target resource URI
    - `:actor_token` - Token representing the acting party
    - `:actor_token_type` - Type URI of the actor token
    - `:client_id` - Client identifier
    - `:client_secret` - Client secret for authentication
  """
  @spec exchange(keyword()) :: {:ok, map()} | {:error, term()}
  def exchange(opts) do
    token_endpoint = Keyword.fetch!(opts, :token_endpoint)
    subject_token = Keyword.fetch!(opts, :subject_token)
    subject_token_type = Keyword.fetch!(opts, :subject_token_type)

    with :ok <- Validator.validate_https_endpoint(token_endpoint) do
      body =
        [
          {"grant_type", @grant_type},
          {"subject_token", subject_token},
          {"subject_token_type", subject_token_type}
        ]
        |> maybe_add(opts, :requested_token_type)
        |> maybe_add(opts, :audience)
        |> maybe_add(opts, :scope)
        |> maybe_add(opts, :resource)
        |> maybe_add(opts, :actor_token)
        |> maybe_add(opts, :actor_token_type)
        |> maybe_add(opts, :client_id)
        |> maybe_add(opts, :client_secret)

      HTTPClient.make_token_request(token_endpoint, body)
    end
  end

  @doc """
  Exchanges an OIDC ID token for an ID-JAG at the IdP's token endpoint.

  This is Step 2 in the enterprise-managed authorization flow.

  ## Options
    - `:token_endpoint` (required) - The IdP's token endpoint
    - `:id_token` (required) - The OIDC ID token to exchange
    - `:audience` (required) - The authorization server's issuer URI
    - `:resource` - The MCP server resource URI
    - `:client_id` - Client identifier at the IdP
    - `:scope` - Requested scope for the ID-JAG
  """
  @spec exchange_id_token_for_id_jag(keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_id_token_for_id_jag(opts) do
    id_token = Keyword.fetch!(opts, :id_token)
    audience = Keyword.fetch!(opts, :audience)

    exchange_opts =
      opts
      |> Keyword.delete(:id_token)
      |> Keyword.put(:subject_token, id_token)
      |> Keyword.put(:subject_token_type, @token_type_id)
      |> Keyword.put(:requested_token_type, @token_type_id_jag)
      |> Keyword.put(:audience, audience)

    exchange(exchange_opts)
  end

  @doc "Returns the token exchange grant type URI."
  def grant_type, do: @grant_type

  @doc "Returns the access token type URI."
  def token_type_access, do: @token_type_access

  @doc "Returns the ID token type URI."
  def token_type_id, do: @token_type_id

  @doc "Returns the ID-JAG token type URI."
  def token_type_id_jag, do: @token_type_id_jag

  # Private helpers

  defp maybe_add(body, opts, key) do
    case Keyword.get(opts, key) do
      nil -> body
      value -> body ++ [{to_string(key), to_string(value)}]
    end
  end
end
