defmodule Arbor.MCP.Authorization.AuthorizationServerMetadata do
  @moduledoc """
  OAuth 2.1 Authorization Server Metadata Discovery (RFC 8414).

  This module implements the authorization server metadata discovery mechanism
  as specified in RFC 8414. It provides the /.well-known/oauth-authorization-server
  endpoint that returns authorization server capabilities and configuration.

  ## Example

      # Generate metadata from application configuration
      metadata = AuthorizationServerMetadata.build_metadata()

      # Metadata includes required fields like issuer, endpoints, and capabilities
      %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token",
        "scopes_supported" => ["mcp:read", "mcp:write"],
        "response_types_supported" => ["code"],
        "grant_types_supported" => ["authorization_code"]
      }
  """

  @type metadata :: %{String.t() => term()}

  @doc """
  Builds the authorization server metadata from application configuration.

  Returns a map containing the authorization server metadata as specified
  in RFC 8414. The metadata includes both required and optional fields
  based on the application's OAuth configuration.

  ## Required Fields (RFC 8414)
  - `issuer`: The authorization server issuer identifier
  - `authorization_endpoint`: URL of the authorization endpoint
  - `token_endpoint`: URL of the token endpoint

  ## Optional Fields
  - `jwks_uri`: URL of the JWK Set document
  - `scopes_supported`: List of supported OAuth 2.0 scopes
  - `response_types_supported`: List of supported response types
  - `grant_types_supported`: List of supported grant types
  - `code_challenge_methods_supported`: List of supported PKCE methods
  - `introspection_endpoint`: URL of the token introspection endpoint
  - `revocation_endpoint`: URL of the token revocation endpoint

  ## Examples

      iex> AuthorizationServerMetadata.build_metadata()
      %{
        "issuer" => "https://auth.example.com",
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token",
        "scopes_supported" => ["mcp:read", "mcp:write"],
        "response_types_supported" => ["code"],
        "grant_types_supported" => ["authorization_code"]
      }
  """
  @spec build_metadata() :: metadata()
  def build_metadata do
    config = Application.get_env(:arbor_mcp, :oauth2_authorization_server_metadata, [])

    # Build required fields - these must be present
    required_metadata = %{
      "issuer" => get_required_field(config, :issuer),
      "authorization_endpoint" => get_required_field(config, :authorization_endpoint),
      "token_endpoint" => get_required_field(config, :token_endpoint)
    }

    # Add optional fields if they are configured
    optional_metadata = build_optional_fields(config)

    Map.merge(required_metadata, optional_metadata)
  end

  @doc """
  Validates that the authorization server metadata configuration is complete.

  Checks that all required fields are present in the application configuration
  and returns :ok if valid, or {:error, reason} if configuration is missing
  or invalid.

  ## Examples

      iex> AuthorizationServerMetadata.validate_config()
      :ok

      iex> AuthorizationServerMetadata.validate_config()
      {:error, {:missing_required_field, :issuer}}
  """
  @spec validate_config() :: :ok | {:error, term()}
  def validate_config do
    config = Application.get_env(:arbor_mcp, :oauth2_authorization_server_metadata, [])

    required_fields = [:issuer, :authorization_endpoint, :token_endpoint]

    with :ok <- validate_required_fields(config, required_fields) do
      validate_https_endpoints(config)
    end
  end

  # Private functions

  defp get_required_field(config, field) do
    case Keyword.get(config, field) do
      nil ->
        raise ArgumentError,
              "Required OAuth authorization server metadata field #{field} is not configured. " <>
                "Please set :arbor_mcp, :oauth2_authorization_server_metadata, #{field}: \"...\""

      value when is_binary(value) ->
        value

      value ->
        raise ArgumentError,
              "OAuth authorization server metadata field #{field} must be a string, got: #{inspect(value)}"
    end
  end

  defp build_optional_fields(config) do
    optional_fields = [
      :jwks_uri,
      :scopes_supported,
      :response_types_supported,
      :grant_types_supported,
      :code_challenge_methods_supported,
      :introspection_endpoint,
      :revocation_endpoint,
      :token_endpoint_auth_methods_supported,
      :token_endpoint_auth_signing_alg_values_supported
    ]

    optional_fields
    |> Enum.map(fn field ->
      case Keyword.get(config, field) do
        nil -> nil
        value -> {to_string(field), value}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp validate_required_fields(config, required_fields) do
    missing_fields =
      required_fields
      |> Enum.reject(fn field -> Keyword.has_key?(config, field) end)

    case missing_fields do
      [] -> :ok
      [field | _] -> {:error, {:missing_required_field, field}}
    end
  end

  defp validate_https_endpoints(config) do
    endpoints_to_validate = [
      :issuer,
      :authorization_endpoint,
      :token_endpoint,
      :jwks_uri,
      :introspection_endpoint,
      :revocation_endpoint
    ]

    endpoints_to_validate
    |> Enum.map(fn field ->
      case Keyword.get(config, field) do
        nil -> :ok
        url when is_binary(url) -> validate_https_url(url, field)
        _ -> {:error, {:invalid_url, field}}
      end
    end)
    |> Enum.find({:ok}, fn
      :ok -> false
      {:error, _} -> true
    end)
    |> case do
      {:ok} -> :ok
      error -> error
    end
  end

  defp validate_https_url(url, field) do
    case URI.parse(url) do
      %URI{scheme: "https"} ->
        :ok

      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] ->
        :ok

      %URI{scheme: scheme} ->
        {:error, {:https_required, field, scheme}}
    end
  end
end
