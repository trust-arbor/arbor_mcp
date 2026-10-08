defmodule Arbor.MCP.Authorization.JWTBearerAssertion do
  @moduledoc """
  RFC 7523 Section 2.1 — JWT Bearer Grant.

  Uses a JWT assertion as an authorization grant to obtain an access token.
  This is used in the enterprise-managed authorization flow (Step 3) where
  the ID-JAG is presented to the authorization server as a JWT bearer grant.
  """

  alias Arbor.MCP.Authorization.{HTTPClient, Validator}

  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"

  @doc """
  Performs a JWT bearer grant at the token endpoint.

  ## Options
    - `:token_endpoint` (required) - The authorization server's token endpoint
    - `:assertion` (required) - The JWT assertion (e.g., an ID-JAG)
    - `:client_id` - Client identifier (optional, may be implicit in assertion)
    - `:scope` - Requested scope
    - `:resource` - Target resource URI (RFC 8707)
  """
  @spec grant(keyword()) :: {:ok, map()} | {:error, term()}
  def grant(opts) do
    token_endpoint = Keyword.fetch!(opts, :token_endpoint)
    assertion = Keyword.fetch!(opts, :assertion)

    with :ok <- Validator.validate_https_endpoint(token_endpoint) do
      body =
        [
          {"grant_type", @grant_type},
          {"assertion", assertion}
        ]
        |> maybe_add(opts, :client_id)
        |> maybe_add(opts, :scope)
        |> maybe_add(opts, :resource)

      HTTPClient.make_token_request(token_endpoint, body)
    end
  end

  @doc "Returns the JWT bearer grant type URI."
  def grant_type, do: @grant_type

  defp maybe_add(body, opts, key) do
    case Keyword.get(opts, key) do
      nil -> body
      value -> body ++ [{to_string(key), to_string(value)}]
    end
  end
end
