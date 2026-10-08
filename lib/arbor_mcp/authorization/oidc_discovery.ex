defmodule Arbor.MCP.Authorization.OIDCDiscovery do
  @moduledoc """
  OpenID Connect Discovery support for MCP authorization.

  Implements OIDC Discovery (OpenID Connect Discovery 1.0) which allows
  fetching and parsing `.well-known/openid-configuration` documents.

  This extends the OAuth 2.1 authorization server metadata discovery
  with OIDC-specific fields like `userinfo_endpoint` and
  `id_token_signing_alg_values_supported`.

  Available in protocol version 2025-11-25.
  """

  alias Arbor.MCP.Authorization.{
    AuthorizationServerMetadata,
    EndpointPolicy,
    Issuer,
    MetadataFetcher
  }

  @type oidc_metadata :: %{String.t() => term()}

  @oidc_well_known_path "/.well-known/openid-configuration"
  @oauth_well_known_path "/.well-known/oauth-authorization-server"
  @max_document_bytes 262_144

  @doc """
  Discovers authorization server metadata using OIDC Discovery with
  fallback to OAuth 2.0 Authorization Server Metadata (RFC 8414).

  Tries `.well-known/openid-configuration` first, then falls back to
  `.well-known/oauth-authorization-server`.

  ## Parameters
  - `issuer` - The issuer URL to discover metadata for
  - `opts` - Hardened metadata-fetch options. Custom clients use
    `get(uri, approved_address, opts)` so DNS validation cannot be bypassed by
    re-resolving the hostname.

  ## Returns
  - `{:ok, metadata}` - Successfully fetched metadata
  - `{:error, reason}` - Failed to fetch metadata

  Discovery metadata is HTTPS-only, bounded, address-pinned, and issuer-checked
  before it is returned. A document whose `issuer` is missing or is not
  byte-for-byte the requested issuer is not used (RFC 8414 §3.3): discovery
  moves on to the next well-known URL, and reports the mismatch only when no
  document names the issuer.
  """
  @spec discover(String.t(), keyword()) :: {:ok, oidc_metadata()} | {:error, term()}
  def discover(issuer, opts \\ []) do
    with :ok <- validate_issuer_url(issuer, opts),
         urls <- build_discovery_urls(issuer),
         {:ok, metadata} <- try_urls(urls, issuer, metadata_options(opts), nil),
         :ok <- validate_metadata(metadata, issuer, opts) do
      {:ok, metadata}
    end
  end

  defp build_discovery_urls(issuer) do
    trimmed = String.trim_trailing(issuer, "/")
    uri = URI.parse(trimmed)
    path = uri.path || ""

    base = origin(uri)

    oidc_appended = trimmed <> @oidc_well_known_path
    oauth_appended = trimmed <> @oauth_well_known_path

    urls = [oidc_appended, oauth_appended]

    # Add RFC 8414 style if issuer has a path component
    if path != "" and path != "/" do
      oauth_rfc8414 = base <> @oauth_well_known_path <> path
      oidc_rfc8414 = base <> @oidc_well_known_path <> path
      urls ++ [oauth_rfc8414, oidc_rfc8414]
    else
      urls
    end
  end

  defp try_urls([], _issuer, _opts, nil), do: {:error, :discovery_failed}
  defp try_urls([], _issuer, _opts, last_error), do: last_error

  defp try_urls([url | rest], issuer, opts, last_error) do
    case fetch_metadata(url, opts) do
      {:ok, metadata} ->
        # A document for another issuer MUST NOT be used; skip it rather than
        # letting it stop discovery before the issuer's own document is tried.
        case validate_issuer(metadata, issuer) do
          :ok -> {:ok, metadata}
          {:error, _reason} = mismatch -> try_urls(rest, issuer, opts, mismatch)
        end

      {:error, {:metadata_fetch_error, _reason}} = error ->
        error

      {:error, _reason} = error ->
        try_urls(rest, issuer, opts, keep_issuer_error(last_error, error))
    end
  end

  # An issuer mismatch says more than a later 404, so it survives as the
  # reported reason once every URL has been tried.
  defp keep_issuer_error({:error, reason} = issuer_error, _error)
       when reason in [:missing_issuer, :invalid_authorization_server_issuer],
       do: issuer_error

  defp keep_issuer_error({:error, {:issuer_mismatch, _details}} = issuer_error, _error),
    do: issuer_error

  defp keep_issuer_error(_last_error, error), do: error

  @doc """
  Validates that the discovered metadata contains required OIDC fields.

  ## Required Fields
  - `issuer` - Must match the expected issuer
  - `authorization_endpoint` - URL of the authorization endpoint
  - `token_endpoint` - URL of the token endpoint

  ## OIDC-specific Fields (optional but recommended)
  - `userinfo_endpoint`
  - `jwks_uri`
  - `id_token_signing_alg_values_supported`
  - `subject_types_supported`
  """
  @spec validate_metadata(oidc_metadata(), String.t(), keyword()) :: :ok | {:error, term()}
  def validate_metadata(metadata, expected_issuer, opts \\ []) do
    with :ok <- validate_issuer(metadata, expected_issuer),
         :ok <- validate_required_endpoints(metadata) do
      EndpointPolicy.validate_metadata(metadata, expected_issuer, opts)
    end
  end

  @doc """
  Checks if the metadata is OIDC-compliant (vs plain OAuth 2.0).

  Returns true if the metadata contains OIDC-specific fields.
  """
  @spec oidc_compliant?(oidc_metadata()) :: boolean()
  def oidc_compliant?(metadata) do
    Map.has_key?(metadata, "userinfo_endpoint") or
      Map.has_key?(metadata, "id_token_signing_alg_values_supported") or
      Map.has_key?(metadata, "subject_types_supported")
  end

  @doc """
  Builds local OIDC-compatible metadata from application configuration.

  Extends the base OAuth metadata from `AuthorizationServerMetadata.build_metadata/0`
  with OIDC-specific fields.
  """
  @spec build_metadata() :: oidc_metadata()
  def build_metadata do
    base = AuthorizationServerMetadata.build_metadata()
    config = Application.get_env(:arbor_mcp, :oidc_discovery, [])

    oidc_fields =
      [
        :userinfo_endpoint,
        :jwks_uri,
        :id_token_signing_alg_values_supported,
        :subject_types_supported,
        :claims_supported,
        :scopes_supported
      ]
      |> Enum.map(fn field ->
        case Keyword.get(config, field) do
          nil -> nil
          value -> {to_string(field), value}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    Map.merge(base, oidc_fields)
  end

  # Private helpers

  defp fetch_metadata(url, opts) do
    case MetadataFetcher.fetch(url, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _ -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp metadata_options(opts) do
    limit = Keyword.get(opts, :max_response_bytes, @max_document_bytes)
    limit = if is_integer(limit) and limit >= 0, do: min(limit, @max_document_bytes), else: limit
    Keyword.put(opts, :max_response_bytes, limit)
  end

  defp validate_issuer_url(issuer, opts) do
    with :ok <- MetadataFetcher.validate_url(issuer, opts),
         %URI{query: nil} <- URI.parse(issuer) do
      :ok
    else
      %URI{} -> {:error, :invalid_issuer}
      {:error, _reason} = error -> error
    end
  end

  defp origin(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    port = if uri.port, do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{host}#{port}"
  end

  defp validate_issuer(metadata, expected_issuer) do
    case Issuer.compare(expected_issuer, Map.get(metadata, "issuer")) do
      {:error, :missing_authorization_server_issuer} -> {:error, :missing_issuer}
      result -> result
    end
  end

  defp validate_required_endpoints(metadata) do
    required = ["authorization_endpoint", "token_endpoint"]

    missing = Enum.reject(required, &Map.has_key?(metadata, &1))

    case missing do
      [] -> :ok
      [field | _] -> {:error, {:missing_required_field, field}}
    end
  end
end
