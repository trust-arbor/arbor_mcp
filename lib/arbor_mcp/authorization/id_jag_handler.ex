defmodule Arbor.MCP.Authorization.IdJagHandler do
  @moduledoc """
  Server-side handler for processing ID-JAG tokens in JWT bearer grants.

  Used by MCP authorization servers to validate incoming ID-JAG assertions
  and issue access tokens in the enterprise-managed authorization flow.
  """

  alias Arbor.MCP.Authorization.{IdJag, JWT}
  alias Arbor.RPC.LogSummary
  require Logger

  @doc """
  Processes a JWT bearer grant containing an ID-JAG.

  1. Extracts and identifies the ID-JAG assertion
  2. Identifies the IdP from the `iss` claim
  3. Fetches/caches IdP JWKS
  4. Validates the ID-JAG
  5. Returns validated claims for access token issuance

  ## Options
    - `:assertion` (required) - The JWT bearer assertion (ID-JAG)
    - `:expected_audience` (required) - This AS's issuer URI
    - `:expected_resource` (required) - The MCP server resource URI
    - `:trusted_idps` (required) - Map of trusted IdP issuers to their config
      Each IdP config should have `:jwks_uri` or `:jwks` (list of JWKs)
    - `:jwks_cache` - Optional cache (map of issuer -> JWKs) for performance
    - `:max_lifetime` - Maximum ID-JAG lifetime (default: 600)
  """
  @spec handle_grant(keyword()) :: {:ok, map()} | {:error, term()}
  def handle_grant(opts) do
    assertion = Keyword.fetch!(opts, :assertion)
    expected_audience = Keyword.fetch!(opts, :expected_audience)
    expected_resource = Keyword.fetch!(opts, :expected_resource)
    trusted_idps = Keyword.fetch!(opts, :trusted_idps)
    jwks_cache = Keyword.get(opts, :jwks_cache, %{})
    max_lifetime = Keyword.get(opts, :max_lifetime, 600)

    with :ok <- verify_is_id_jag(assertion),
         {:ok, issuer} <- extract_issuer(assertion),
         {:ok, idp_config} <- lookup_trusted_idp(issuer, trusted_idps),
         {:ok, idp_keys} <- resolve_idp_keys(issuer, idp_config, jwks_cache),
         {:ok, claims} <-
           IdJag.validate(assertion,
             idp_keys: idp_keys,
             expected_audience: expected_audience,
             expected_resource: expected_resource,
             max_lifetime: max_lifetime
           ) do
      {:ok,
       %{
         claims: claims,
         issuer: issuer,
         subject: claims["sub"],
         client_id: claims["client_id"],
         scope: claims["scope"],
         resource: claims["resource"]
       }}
    end
  end

  @doc """
  Fetches JWKS from an IdP's jwks_uri endpoint.
  """
  @spec fetch_idp_keys(String.t()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def fetch_idp_keys(jwks_uri) do
    JWT.fetch_jwks(jwks_uri)
  end

  # Private helpers

  defp verify_is_id_jag(assertion) do
    if IdJag.id_jag?(assertion) do
      :ok
    else
      {:error, :not_id_jag}
    end
  end

  defp extract_issuer(assertion) do
    case JWT.peek_header(assertion) do
      {:ok, _header} ->
        # We need to peek at the payload (unverified) to get the issuer
        # so we can look up the right keys
        case peek_payload(assertion) do
          {:ok, %{"iss" => issuer}} when is_binary(issuer) ->
            {:ok, issuer}

          {:ok, _} ->
            {:error, :missing_issuer}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp peek_payload(token) do
    case String.split(token, ".") do
      [_, payload_b64 | _] ->
        case Base.url_decode64(payload_b64, padding: false) do
          {:ok, payload_json} -> Jason.decode(payload_json)
          :error -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp lookup_trusted_idp(issuer, trusted_idps) do
    case Map.get(trusted_idps, issuer) do
      nil ->
        Logger.warning("Untrusted IdP", issuer_hash: LogSummary.fingerprint(issuer))
        {:error, {:untrusted_idp, issuer}}

      config ->
        {:ok, config}
    end
  end

  defp resolve_idp_keys(issuer, idp_config, jwks_cache) do
    # Check cache first
    case Map.get(jwks_cache, issuer) do
      nil ->
        # Fetch from config
        cond do
          jwks = Map.get(idp_config, :jwks) ->
            {:ok, List.wrap(jwks)}

          jwks_uri = Map.get(idp_config, :jwks_uri) ->
            fetch_idp_keys(jwks_uri)

          true ->
            {:error, {:no_keys_for_idp, issuer}}
        end

      cached_keys ->
        {:ok, cached_keys}
    end
  end
end
