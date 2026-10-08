defmodule Arbor.MCP.Authorization.ErrorHandler do
  @moduledoc """
  Handles authorization-related errors and triggers appropriate OAuth flows.

  This module implements the MCP specification requirements for handling
  401 Unauthorized and 403 Forbidden responses, automatically initiating
  OAuth flows when needed.
  """

  require Logger

  alias Arbor.MCP.Authorization.LogSanitizer
  alias Arbor.MCP.Internal.Headers

  @doc """
  Handles HTTP authorization errors according to MCP specification.

  - 401 Unauthorized: Token is invalid or required
  - 403 Forbidden: Insufficient permissions

  Returns {:error, reason} or {:retry, auth_params} to trigger OAuth flow.
  """
  @spec handle_auth_error(integer(), list(), binary(), map()) ::
          {:error, atom() | {atom(), any()}}
          | {:retry, map()}
  def handle_auth_error(401, headers, _body, state) do
    Logger.debug("Received 401 Unauthorized response")

    # Extract WWW-Authenticate header for OAuth discovery
    case extract_www_authenticate(headers) do
      {:ok, auth_info} ->
        handle_unauthorized(auth_info, state)

      :error ->
        {:error, :unauthorized_no_auth_info}
    end
  end

  def handle_auth_error(403, headers, body, state) do
    Logger.warning("Received 403 Forbidden response")

    # Check WWW-Authenticate header for scope requirements (incremental scope)
    case extract_www_authenticate(headers) do
      {:ok, auth_info} when is_map_key(auth_info, "scope") ->
        build_scope_upgrade_retry(auth_info["scope"], state)

      _ ->
        handle_forbidden_body(body, state)
    end
  end

  def handle_auth_error(status, _headers, _body, _state) when status in 400..499 do
    {:error, {:auth_error, status}}
  end

  def handle_auth_error(_status, _headers, _body, _state) do
    :ok
  end

  @doc """
  Processes an OAuth error response according to RFC 6749.
  """
  @spec handle_oauth_error(map()) :: {:error, {atom(), String.t()}}
  def handle_oauth_error(%{"error" => error} = response) do
    description = Map.get(response, "error_description", "")
    uri = Map.get(response, "error_uri")

    Logger.error(
      "OAuth error: #{LogSanitizer.format(%{error: error, error_description: description})}"
    )

    if uri do
      Logger.debug("OAuth error details: #{LogSanitizer.format(uri)}")
    end

    # Keep error as string to avoid atom exhaustion
    {:error, {error, description}}
  end

  def handle_oauth_error(response) do
    {:error, {:invalid_oauth_response, response}}
  end

  # Private functions

  defp handle_forbidden_body(body, state) do
    error_details = parse_error_body(body)

    case error_details do
      %{error: "insufficient_scope"} ->
        scope_string = parse_json_body(body)["scope"]
        build_scope_upgrade_retry(scope_string, state)

      _ ->
        {:error, {:forbidden, error_details}}
    end
  end

  defp build_scope_upgrade_retry(scope_string, state) do
    required_scopes = parse_scope_string(scope_string)
    current_scopes = extract_current_scopes(state)

    {:retry,
     %{
       action: :scope_upgrade,
       required_scopes: required_scopes,
       current_scopes: current_scopes
     }}
  end

  defp parse_scope_string(nil), do: []
  defp parse_scope_string(s) when is_binary(s), do: String.split(s, " ", trim: true)
  defp parse_scope_string(_), do: []

  defp extract_current_scopes(state) do
    case state[:scopes] do
      nil -> []
      s when is_binary(s) -> String.split(s, " ", trim: true)
      s when is_list(s) -> s
    end
  end

  defp handle_unauthorized(auth_info, state) do
    cond do
      # Token might be expired, try refresh
      state[:refresh_token] && auth_info[:error] == "invalid_token" ->
        {:retry, %{action: :refresh_token, refresh_token: state.refresh_token}}

      # Need new authorization
      auth_info[:realm] ->
        case discover_auth_server(auth_info[:realm]) do
          {:ok, metadata} ->
            {:retry,
             %{
               action: :authorize,
               auth_server: metadata,
               scope: auth_info[:scope]
             }}

          {:error, reason} ->
            {:error, {:discovery_failed, reason}}
        end

      # Can't determine how to authenticate
      true ->
        {:error, :unauthorized_no_realm}
    end
  end

  defp extract_www_authenticate(headers) do
    case Headers.get(headers, "www-authenticate") do
      value when is_binary(value) ->
        parse_www_authenticate(value)

      nil ->
        :error

      _ ->
        :error
    end
  end

  defp parse_www_authenticate(value) do
    # Parse Bearer realm="...", error="...", scope="..."
    case Regex.scan(~r/(\w+)="([^"]+)"/, value) do
      matches when matches != [] ->
        params =
          Enum.map(matches, fn [_, key, val] -> {key, val} end)
          |> Enum.into(%{})

        {:ok, params}

      _ ->
        :error
    end
  end

  defp discover_auth_server(realm) do
    # Use the discovery module to find authorization server metadata
    # In a full implementation, this would use the Discovery module
    # For now, return a simple structure
    if String.starts_with?(realm, "http") do
      {:ok,
       %{
         authorization_endpoint: "#{realm}/authorize",
         token_endpoint: "#{realm}/token"
       }}
    else
      {:error, :invalid_realm}
    end
  end

  defp parse_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} ->
        %{
          error: Map.get(json, "error"),
          description: Map.get(json, "error_description"),
          details: Map.get(json, "details")
        }

      _ ->
        %{raw: body}
    end
  end

  defp parse_error_body(body), do: %{raw: inspect(body)}

  defp parse_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) -> json
      _ -> %{}
    end
  end

  defp parse_json_body(_body), do: %{}
end
