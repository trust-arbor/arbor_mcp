defmodule Arbor.MCP.Authorization.HTTPClient do
  @moduledoc """
  HTTP client functionality for OAuth 2.1 requests.

  This module handles the HTTP communication with OAuth authorization servers,
  including token requests, introspection, and metadata discovery.
  """

  alias Arbor.MCP.Authorization.{EndpointPolicy, Issuer, SecureHTTP}

  @doc """
  Makes a token request to the authorization server.

  Handles both token exchange and refresh token requests with proper
  error handling and response parsing.
  """
  @spec make_token_request(String.t(), keyword() | [{String.t(), String.t()}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def make_token_request(endpoint, body, opts \\ [])

  def make_token_request(endpoint, body, opts) do
    auth_method = Keyword.get(opts, :auth_method, :client_secret_post)

    {headers, body} = apply_token_auth_method(auth_method, body)

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
      | headers
    ]

    encoded_body = URI.encode_query(body)

    case make_http_request(:post, endpoint, headers, encoded_body, opts) do
      {:ok, {{_, 200, _}, _response_headers, response_body}} ->
        case Jason.decode(response_body) do
          {:ok, token_data} ->
            parse_token_response(token_data)

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, {{_, status, _}, _headers, error_body}} ->
        case Jason.decode(error_body) do
          {:ok, error_data} ->
            {:error, {:oauth_error, status, error_data}}

          {:error, _} ->
            {:error, {:http_error, status, error_body}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Makes a token introspection request.

  Used for validating access tokens with the authorization server.
  """
  @spec make_introspection_request(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def make_introspection_request(endpoint, body, opts \\ []) do
    auth_method = Keyword.get(opts, :auth_method, :none)
    {auth_headers, body} = apply_token_auth_method(auth_method, body)

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
      | auth_headers
    ]

    encoded_body = URI.encode_query(body)

    case make_http_request(:post, endpoint, headers, encoded_body, opts) do
      {:ok, {{_, 200, _}, _response_headers, response_body}} ->
        case Jason.decode(response_body) do
          {:ok, introspection_data} ->
            parse_introspection_response(introspection_data)

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, {{_, status, _}, _headers, error_body}} ->
        case Jason.decode(error_body) do
          {:ok, error_data} ->
            {:error, {:oauth_error, status, error_data}}

          {:error, _} ->
            {:error, {:http_error, status, error_body}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Fetches server metadata from the well-known endpoint.

  Implements RFC 8414 OAuth 2.0 Authorization Server Metadata discovery.
  """
  @spec fetch_server_metadata(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_server_metadata(metadata_url, opts \\ []) do
    case make_http_request(:get, metadata_url, [{"accept", "application/json"}], "", opts) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"issuer" => issuer} = metadata} when is_binary(issuer) ->
            with :ok <- validate_expected_issuer(issuer, opts),
                 :ok <- EndpointPolicy.validate_metadata(metadata, issuer, opts) do
              parse_server_metadata(metadata)
            end

          {:ok, _metadata} ->
            {:error, :invalid_server_metadata}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Private HTTP request implementation

  # Apply token endpoint authentication method per RFC 8414.
  # Returns {extra_headers, modified_body}.
  defp apply_token_auth_method(:client_secret_basic, body) do
    # Extract client_id and client_secret from body, put in Authorization header
    body_map = Map.new(body)
    client_id = body_map[:client_id] || body_map["client_id"] || ""
    client_secret = body_map[:client_secret] || body_map["client_secret"] || ""

    # Remove credentials from body
    filtered_body =
      Enum.reject(body, fn {k, _} ->
        k in [:client_id, :client_secret, "client_id", "client_secret"]
      end)

    # Add Basic auth header
    credentials =
      Base.encode64(
        "#{URI.encode_www_form(to_string(client_id))}:#{URI.encode_www_form(to_string(client_secret))}"
      )

    {[{"authorization", "Basic #{credentials}"}], filtered_body}
  end

  defp apply_token_auth_method(:private_key_jwt, body) do
    # JWT assertion is already in the body (client_assertion + client_assertion_type).
    # Remove client_secret if present (not used with JWT auth).
    filtered_body =
      Enum.reject(body, fn {k, _} ->
        k in [:client_secret, "client_secret"]
      end)

    {[], filtered_body}
  end

  defp apply_token_auth_method(:none, body) do
    # No auth — just remove client_secret from body, keep client_id
    filtered_body =
      Enum.reject(body, fn {k, _} ->
        k in [:client_secret, "client_secret"]
      end)

    {[], filtered_body}
  end

  defp apply_token_auth_method(_method, body) do
    # Default: client_secret_post — credentials in body (no extra headers)
    {[], body}
  end

  defp make_http_request(method, url, headers, body, opts),
    do: SecureHTTP.request(method, url, headers, body, opts)

  # Response parsing helpers

  defp parse_token_response(%{"access_token" => access_token} = data)
       when is_binary(access_token) do
    token = %{
      access_token: access_token,
      token_type: Map.get(data, "token_type", "Bearer"),
      expires_in: Map.get(data, "expires_in"),
      refresh_token: Map.get(data, "refresh_token"),
      scope: Map.get(data, "scope")
    }

    token =
      case Map.get(data, "issued_token_type") do
        nil -> token
        issued_type -> Map.put(token, :issued_token_type, issued_type)
      end

    {:ok, token}
  end

  defp parse_token_response(_data), do: {:error, :invalid_token_response}

  defp parse_introspection_response(%{"active" => active} = data) when is_boolean(active) do
    {:ok,
     %{
       active: Map.get(data, "active", false),
       scope: Map.get(data, "scope"),
       client_id: Map.get(data, "client_id"),
       username: Map.get(data, "username"),
       token_type: Map.get(data, "token_type"),
       exp: Map.get(data, "exp"),
       iat: Map.get(data, "iat"),
       nbf: Map.get(data, "nbf"),
       sub: Map.get(data, "sub"),
       aud: Map.get(data, "aud"),
       iss: Map.get(data, "iss"),
       jti: Map.get(data, "jti")
     }}
  end

  defp parse_introspection_response(_data), do: {:error, :invalid_introspection_response}

  defp parse_server_metadata(
         %{"authorization_endpoint" => authorization_endpoint, "token_endpoint" => token_endpoint} =
           data
       )
       when is_binary(authorization_endpoint) and is_binary(token_endpoint) do
    {:ok,
     %{
       authorization_endpoint: authorization_endpoint,
       token_endpoint: token_endpoint,
       registration_endpoint: Map.get(data, "registration_endpoint"),
       scopes_supported: Map.get(data, "scopes_supported", []),
       response_types_supported: Map.get(data, "response_types_supported", ["code"]),
       grant_types_supported:
         Map.get(data, "grant_types_supported", ["authorization_code", "client_credentials"]),
       code_challenge_methods_supported:
         Map.get(data, "code_challenge_methods_supported", ["S256"]),
       token_endpoint_auth_methods_supported:
         Map.get(data, "token_endpoint_auth_methods_supported", ["client_secret_post"]),
       token_endpoint_auth_signing_alg_values_supported:
         Map.get(data, "token_endpoint_auth_signing_alg_values_supported"),
       issuer: Map.get(data, "issuer"),
       jwks_uri: Map.get(data, "jwks_uri")
     }}
  end

  defp parse_server_metadata(_data), do: {:error, :invalid_server_metadata}

  defp validate_expected_issuer(actual, opts) do
    case Keyword.get(opts, :expected_issuer) do
      nil -> :ok
      expected -> Issuer.compare(expected, actual)
    end
  end
end
