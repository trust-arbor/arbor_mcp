defmodule Arbor.MCP.Authorization.Validator do
  @moduledoc """
  Validation functions for OAuth 2.1 parameters and endpoints.

  This module contains all validation logic extracted from the main
  Authorization module, focusing on security and compliance checks.
  """

  @doc """
  Validates that an endpoint URL uses HTTPS (except localhost).

  OAuth 2.1 requires HTTPS for all authorization endpoints except
  localhost for development purposes.
  """
  @spec validate_https_endpoint(String.t()) :: :ok | {:error, term()}
  def validate_https_endpoint(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{} = uri} ->
        if valid_secure_uri?(uri), do: :ok, else: {:error, :https_required}

      {:error, _reason} ->
        {:error, :https_required}
    end
  end

  def validate_https_endpoint(_url), do: {:error, :https_required}

  @doc """
  Validates that a redirect URI is properly formed and secure.

  Prevents open redirect vulnerabilities by ensuring redirect URIs
  are properly validated.
  """
  @spec validate_redirect_uri(String.t()) :: :ok | {:error, term()}
  def validate_redirect_uri(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{} = parsed} ->
        if valid_secure_uri?(parsed), do: :ok, else: {:error, :invalid_redirect_uri}

      {:error, _reason} ->
        {:error, :invalid_redirect_uri}
    end
  end

  def validate_redirect_uri(_uri), do: {:error, :invalid_redirect_uri}

  @doc """
  Validates resource parameters according to RFC 8707.

  Resource parameters must be valid URIs without fragments.
  """
  @spec validate_resource_parameters(map()) :: :ok | {:error, term()}
  def validate_resource_parameters(config) do
    case Map.get(config, :resource) do
      nil ->
        :ok

      uri when is_binary(uri) ->
        validate_resource_uri(uri)

      uris when is_list(uris) ->
        Enum.reduce_while(uris, :ok, fn uri, _acc ->
          case validate_resource_uri(uri) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :invalid_resource_parameter}
    end
  end

  @doc """
  Validates that client credentials are properly formed.

  Ensures client IDs and secrets meet security requirements.
  """
  @spec validate_client_credentials(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def validate_client_credentials(client_id, client_secret) do
    with :ok <- validate_client_id(client_id) do
      validate_client_secret(client_secret)
    end
  end

  @doc """
  Validates that scopes are properly formatted.

  Scopes must be space-separated strings according to OAuth 2.1.
  """
  @spec validate_scopes([String.t()]) :: :ok | {:error, term()}
  def validate_scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1) and Enum.all?(scopes, &valid_scope_name?/1) do
      :ok
    else
      {:error, :invalid_scopes}
    end
  end

  def validate_scopes(_), do: {:error, :invalid_scopes}

  @doc """
  Validates OAuth grant type parameters.

  Ensures all required parameters are present for the specific grant type.
  """
  @spec validate_grant_params(String.t(), map()) :: :ok | {:error, term()}
  def validate_grant_params("authorization_code", params) do
    required = [:code, :redirect_uri, :client_id, :code_verifier]
    validate_required_params(params, required)
  end

  def validate_grant_params("client_credentials", params) do
    required = [:client_id, :client_secret]
    validate_required_params(params, required)
  end

  def validate_grant_params("refresh_token", params) do
    required = [:refresh_token, :client_id]
    validate_required_params(params, required)
  end

  def validate_grant_params("urn:ietf:params:oauth:grant-type:jwt-bearer", params) do
    required = [:assertion]
    validate_required_params(params, required)
  end

  def validate_grant_params("urn:ietf:params:oauth:grant-type:token-exchange", params) do
    required = [:subject_token, :subject_token_type]
    validate_required_params(params, required)
  end

  def validate_grant_params(grant_type, _params) do
    {:error, {:unsupported_grant_type, grant_type}}
  end

  # Private validation helpers

  defp valid_secure_uri?(%URI{} = uri) do
    valid_uri_host?(uri.host) and secure_uri_scheme?(uri.scheme, uri.host) and
      is_nil(uri.userinfo) and is_nil(uri.fragment) and
      (is_nil(uri.port) or uri.port in 1..65_535)
  end

  defp valid_uri_host?(host) when is_binary(host) do
    host != "" and byte_size(host) <= 253 and not String.contains?(host, ["\r", "\n"])
  end

  defp valid_uri_host?(_host), do: false

  defp secure_uri_scheme?("https", _host), do: true

  defp secure_uri_scheme?("http", host),
    do: String.downcase(host || "") in ["localhost", "127.0.0.1", "::1"]

  defp secure_uri_scheme?(_scheme, _host), do: false

  defp validate_resource_uri(uri_string) when is_binary(uri_string) do
    if String.trim(uri_string) == "" do
      {:error, {:invalid_resource_uri, "cannot be a blank string"}}
    else
      case URI.parse(uri_string) do
        %URI{scheme: nil} ->
          {:error, {:invalid_resource_uri, "missing scheme: " <> uri_string}}

        %URI{fragment: fragment} when fragment != nil ->
          {:error, {:invalid_resource_uri, "contains fragment: " <> uri_string}}

        %URI{} ->
          :ok
      end
    end
  end

  defp validate_resource_uri(uri) do
    {:error, {:invalid_resource_uri, "must be a string, got: #{inspect(uri)}"}}
  end

  defp validate_client_id(client_id) when is_binary(client_id) do
    if String.trim(client_id) == "" do
      {:error, :invalid_client_id}
    else
      :ok
    end
  end

  defp validate_client_id(_), do: {:error, :invalid_client_id}

  # Public clients don't need secrets
  defp validate_client_secret(nil), do: :ok

  defp validate_client_secret(client_secret) when is_binary(client_secret) do
    if String.trim(client_secret) == "" do
      {:error, :invalid_client_secret}
    else
      :ok
    end
  end

  defp validate_client_secret(_), do: {:error, :invalid_client_secret}

  defp valid_scope_name?(scope) when is_binary(scope) do
    # OAuth scopes must not contain certain characters
    not String.contains?(scope, [" ", "\t", "\r", "\n"])
  end

  defp valid_scope_name?(_), do: false

  defp validate_required_params(params, required) do
    missing = Enum.filter(required, fn key -> not Map.has_key?(params, key) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required_params, missing}}
    end
  end
end
