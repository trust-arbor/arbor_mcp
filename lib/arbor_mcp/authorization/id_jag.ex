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
    - `:resource` - MCP server resource URI; required under the default policy
    - `:resource_policy` - `:required` (default) or `:if_present`. The latter
      permits omission; the issuing host must still restrict access tokens.
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
    resource_policy = Keyword.get(opts, :resource_policy, :required)

    resource =
      if resource_policy == :required, do: Keyword.fetch!(opts, :resource), else: opts[:resource]

    client_id = Keyword.fetch!(opts, :client_id)
    alg = Keyword.get(opts, :alg, "RS256")
    kid = Keyword.get(opts, :kid)
    lifetime = Keyword.get(opts, :lifetime, @default_lifetime)
    additional_claims = Keyword.get(opts, :additional_claims, %{})

    now = System.system_time(:second)

    claims =
      Map.merge(Map.delete(additional_claims, "resource"), %{
        "iss" => issuer,
        "sub" => subject,
        "aud" => audience,
        "client_id" => client_id,
        "jti" => JWT.generate_jti(),
        "exp" => now + lifetime,
        "iat" => now
      })

    claims = if is_nil(resource), do: claims, else: Map.put(claims, "resource", resource)

    claims =
      case Keyword.get(opts, :scope) do
        nil -> claims
        scope -> Map.put(claims, "scope", scope)
      end

    sign_opts = [alg: alg, typ: @typ]
    sign_opts = if kid, do: Keyword.put(sign_opts, :kid, kid), else: sign_opts

    with :ok <- validate_resource_policy(resource_policy),
         :ok <- validate_resource_value(resource, resource_policy),
         :ok <- validate_identity_claim_types(claims) do
      JWT.sign(claims, private_key, sign_opts)
    end
  end

  @doc """
  Validates an ID-JAG JWT.

  ## Options
    - `:idp_keys` (required) - JWK or list of JWKs from the IdP
    - `:expected_audience` (required) - Expected audience (AS issuer)
    - `:expected_resource` (required) - Expected resource (MCP server URI)
    - `:resource_policy` - `:required` (default) or `:if_present`; the latter
      accepts an absent claim but still compares a present claim exactly.
    - `:max_lifetime` - Maximum allowed lifetime in seconds (default: 600)
  """
  @spec validate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(token, opts) do
    idp_keys = Keyword.fetch!(opts, :idp_keys)
    expected_audience = Keyword.fetch!(opts, :expected_audience)
    expected_resource = Keyword.fetch!(opts, :expected_resource)
    max_lifetime = Keyword.get(opts, :max_lifetime, 600)
    resource_policy = Keyword.get(opts, :resource_policy, :required)
    required = ["iss", "sub", "aud", "client_id", "jti", "exp", "iat"]
    required = if resource_policy == :required, do: ["resource" | required], else: required

    with :ok <- validate_resource_policy(resource_policy),
         :ok <- validate_resource_value(expected_resource, :required),
         :ok <- validate_typ_header(token),
         {:ok, claims} <-
           JWT.verify_and_validate(token, List.wrap(idp_keys),
             aud: expected_audience,
             max_age: max_lifetime,
             required: required
           ),
         :ok <- validate_identity_claim_types(claims),
         :ok <- validate_resource_claim(claims, expected_resource, resource_policy) do
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

  # These are wire types, not issuer/subject/client authorization policy.
  defp validate_identity_claim_types(claims) do
    fields =
      ~w(iss sub aud client_id jti) ++ if(Map.has_key?(claims, "scope"), do: ["scope"], else: [])

    case Enum.find(fields, fn field ->
           value = claims[field]
           not (is_binary(value) and String.valid?(value) and byte_size(value) > 0)
         end) do
      nil -> :ok
      field -> {:error, {:invalid_claim_type, field}}
    end
  end

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

  defp validate_resource_policy(policy) when policy in [:required, :if_present], do: :ok
  defp validate_resource_policy(_policy), do: {:error, :invalid_resource_policy}

  defp validate_resource_value(nil, :if_present), do: :ok

  defp validate_resource_value(resource, _policy)
       when is_binary(resource) and byte_size(resource) > 0,
       do: :ok

  defp validate_resource_value(_resource, _policy), do: {:error, :invalid_expected_resource}

  defp validate_resource_claim(%{"resource" => resource}, expected_resource, _policy) do
    if resource == expected_resource do
      :ok
    else
      {:error, {:invalid_resource, expected: expected_resource, got: resource}}
    end
  end

  defp validate_resource_claim(claims, _expected, :if_present)
       when not is_map_key(claims, "resource"),
       do: :ok

  defp validate_resource_claim(_, _, _), do: {:error, :missing_resource_claim}
end
