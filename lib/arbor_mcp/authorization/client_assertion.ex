defmodule Arbor.MCP.Authorization.ClientAssertion do
  @moduledoc """
  RFC 7523 Section 2.2 — JWT client assertions for `private_key_jwt` authentication.

  Used to authenticate confidential clients at the token endpoint using
  a JWT signed with the client's private key instead of a client secret.
  """

  alias Arbor.MCP.Authorization.JWT

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @default_lifetime 300

  @doc """
  Builds a JWT client assertion for token endpoint authentication.

  ## Options
    - `:client_id` (required) - The client identifier
    - `:token_endpoint` (required) - The token endpoint URL (used as audience)
    - `:private_key` (required) - JWK private key for signing
    - `:alg` - Signing algorithm (default: "RS256")
    - `:kid` - Key ID to include in header
    - `:lifetime` - Assertion lifetime in seconds (default: 300)
    - `:additional_claims` - Extra claims to include
  """
  @spec build_assertion(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_assertion(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    token_endpoint = Keyword.fetch!(opts, :token_endpoint)
    private_key = Keyword.fetch!(opts, :private_key)
    alg = Keyword.get(opts, :alg, "RS256")
    kid = Keyword.get(opts, :kid)
    lifetime = Keyword.get(opts, :lifetime, @default_lifetime)
    additional_claims = Keyword.get(opts, :additional_claims, %{})

    now = System.system_time(:second)

    claims =
      Map.merge(additional_claims, %{
        "iss" => client_id,
        "sub" => client_id,
        "aud" => token_endpoint,
        "exp" => now + lifetime,
        "iat" => now,
        "jti" => JWT.generate_jti()
      })

    sign_opts = [alg: alg, typ: "JWT"]
    sign_opts = if kid, do: Keyword.put(sign_opts, :kid, kid), else: sign_opts

    JWT.sign(claims, private_key, sign_opts)
  end

  @doc """
  Builds form parameters for JWT client authentication at the token endpoint.

  Returns a keyword list with `client_assertion_type`, `client_assertion`, and `client_id`
  ready to be merged into the token request body.

  Accepts the same options as `build_assertion/1`.
  """
  @spec build_assertion_params(keyword()) :: {:ok, keyword()} | {:error, term()}
  def build_assertion_params(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    case build_assertion(opts) do
      {:ok, assertion} ->
        params = [
          {"client_assertion_type", @assertion_type},
          {"client_assertion", assertion},
          {"client_id", client_id}
        ]

        {:ok, params}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Server-side: Verifies an incoming client assertion.

  ## Parameters
    - `assertion` - The JWT assertion string
    - `expected_client_id` - The expected client ID (must match iss and sub)
    - `opts` - Verification options:
      - `:token_endpoint` (required) - The token endpoint URL (expected audience)
      - `:client_jwks` - List of JWKs for the client, or a single JWK
      - `:jwks_uri` - URL to fetch client JWKS from
      - `:max_lifetime` - Maximum allowed assertion lifetime (default: 600)
  """
  @spec verify_assertion(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_assertion(assertion, expected_client_id, opts) do
    token_endpoint = Keyword.fetch!(opts, :token_endpoint)
    max_lifetime = Keyword.get(opts, :max_lifetime, 600)

    with {:ok, jwks} <- resolve_client_keys(opts) do
      JWT.verify_and_validate(assertion, jwks,
        iss: expected_client_id,
        sub: expected_client_id,
        aud: token_endpoint,
        max_age: max_lifetime,
        required: ["iss", "sub", "aud", "exp", "iat", "jti"]
      )
    end
  end

  @doc """
  Returns the client assertion type URI.
  """
  @spec assertion_type() :: String.t()
  def assertion_type, do: @assertion_type

  # Private helpers

  defp resolve_client_keys(opts) do
    cond do
      keys = Keyword.get(opts, :client_jwks) ->
        {:ok, List.wrap(keys)}

      uri = Keyword.get(opts, :jwks_uri) ->
        JWT.fetch_jwks(uri)

      true ->
        {:error, :no_client_keys_configured}
    end
  end
end
