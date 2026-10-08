defmodule Arbor.MCP.Authorization.IdJag do
  @moduledoc """
  ID-JAG (Identity JWT Authorization Grant) creation and validation.

  ID-JAG is a JWT with typ="oauth-id-jag+jwt" that carries identity information
  from an IdP to an authorization server in the enterprise-managed authorization flow.
  """

  alias Arbor.MCP.Authorization.JWT

  @typ "oauth-id-jag+jwt"
  @default_lifetime 300

  @doc """
  Creates and signs an ID-JAG JWT.

  ## Options
    - `:private_key` (required) - JWK private key for signing (IdP's key)
    - `:issuer` (required) - The IdP issuer identifier
    - `:subject` (required) - The user's subject identifier
    - `:audience` (required) - The authorization server's issuer URI
    - `:resource` (required) - The MCP server resource URI
    - `:client_id` (required) - The OAuth client identifier
    - `:scope` - Requested scope (optional)
    - `:alg` - Signing algorithm (default: "RS256")
    - `:kid` - Key ID to include in header
    - `:lifetime` - Token lifetime in seconds (default: 300)
    - `:additional_claims` - Extra claims to include
  """
  @spec create(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(opts) do
    private_key = Keyword.fetch!(opts, :private_key)
    issuer = Keyword.fetch!(opts, :issuer)
    subject = Keyword.fetch!(opts, :subject)
    audience = Keyword.fetch!(opts, :audience)
    resource = Keyword.fetch!(opts, :resource)
    client_id = Keyword.fetch!(opts, :client_id)
    alg = Keyword.get(opts, :alg, "RS256")
    kid = Keyword.get(opts, :kid)
    lifetime = Keyword.get(opts, :lifetime, @default_lifetime)
    additional_claims = Keyword.get(opts, :additional_claims, %{})

    now = System.system_time(:second)

    claims =
      Map.merge(additional_claims, %{
        "iss" => issuer,
        "sub" => subject,
        "aud" => audience,
        "resource" => resource,
        "client_id" => client_id,
        "jti" => JWT.generate_jti(),
        "exp" => now + lifetime,
        "iat" => now
      })

    claims =
      case Keyword.get(opts, :scope) do
        nil -> claims
        scope -> Map.put(claims, "scope", scope)
      end

    sign_opts = [alg: alg, typ: @typ]
    sign_opts = if kid, do: Keyword.put(sign_opts, :kid, kid), else: sign_opts

    JWT.sign(claims, private_key, sign_opts)
  end

  @doc """
  Validates an ID-JAG JWT.

  ## Options
    - `:idp_keys` (required) - JWK or list of JWKs from the IdP
    - `:expected_audience` (required) - Expected audience (AS issuer)
    - `:expected_resource` (required) - Expected resource (MCP server URI)
    - `:max_lifetime` - Maximum allowed lifetime in seconds (default: 600)
  """
  @spec validate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(token, opts) do
    idp_keys = Keyword.fetch!(opts, :idp_keys)
    expected_audience = Keyword.fetch!(opts, :expected_audience)
    expected_resource = Keyword.fetch!(opts, :expected_resource)
    max_lifetime = Keyword.get(opts, :max_lifetime, 600)

    with :ok <- validate_typ_header(token),
         {:ok, claims} <-
           JWT.verify_and_validate(token, List.wrap(idp_keys),
             aud: expected_audience,
             max_age: max_lifetime,
             required: ["iss", "sub", "aud", "resource", "client_id", "jti", "exp", "iat"]
           ),
         :ok <- validate_resource_claim(claims, expected_resource) do
      {:ok, claims}
    end
  end

  @doc """
  Checks if a JWT has the ID-JAG typ header.
  """
  @spec id_jag?(String.t()) :: boolean()
  def id_jag?(token) when is_binary(token) do
    case JWT.peek_header(token) do
      {:ok, %{"typ" => @typ}} -> true
      _ -> false
    end
  end

  @doc "Returns the ID-JAG typ header value."
  def typ, do: @typ

  # Private helpers

  defp validate_typ_header(token) do
    case JWT.peek_header(token) do
      {:ok, %{"typ" => @typ}} ->
        :ok

      {:ok, %{"typ" => other}} ->
        {:error, {:invalid_typ, expected: @typ, got: other}}

      {:ok, _} ->
        {:error, :missing_typ_header}

      {:error, _} = error ->
        error
    end
  end

  defp validate_resource_claim(%{"resource" => resource}, expected_resource) do
    if resource == expected_resource do
      :ok
    else
      {:error, {:invalid_resource, expected: expected_resource, got: resource}}
    end
  end

  defp validate_resource_claim(_, _), do: {:error, :missing_resource_claim}
end
