defmodule Arbor.MCP.Authorization.Interceptor do
  @moduledoc """
  Request interceptor that automatically adds authorization headers.

  This module provides middleware functionality to ensure all MCP requests
  include proper authorization headers when tokens are available.
  """

  alias Arbor.MCP.Authorization.ErrorHandler
  alias Arbor.MCP.Authorization.TokenManager

  @doc """
  Adds authorization headers to a request if a token is available.

  Options:
  - `:token_manager` - PID or name of TokenManager process
  - `:token` - Static token to use (alternative to token_manager)
  - `:auth_type` - Authorization type (default: "Bearer")
  """
  @spec add_auth_headers(map() | keyword(), keyword()) ::
          {:ok, map() | keyword()} | {:error, any()}
  def add_auth_headers(request, opts) do
    case get_auth_token(opts) do
      {:ok, token, type} ->
        {:ok, add_authorization_header(request, token, type)}

      {:error, :no_token} ->
        # No token available, return request as-is
        {:ok, request}

      error ->
        error
    end
  end

  @doc """
  Processes a response and handles authorization errors.

  Returns:
  - `{:ok, response}` - Response is fine, continue processing
  - `{:retry, auth_params}` - Need to retry with authentication
  - `{:error, reason}` - Unrecoverable error
  """
  @spec handle_response({:ok, any()} | {:error, any()}, map()) ::
          {:ok, any()} | {:retry, map()} | {:error, any()}
  def handle_response({:ok, {{_, status, _}, headers, body}} = _response, state)
      when status in [401, 403] do
    case ErrorHandler.handle_auth_error(status, headers, body, state) do
      {:retry, auth_params} ->
        {:retry, auth_params}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_response(response, _opts), do: {:ok, response}

  @doc """
  Creates an authorization-aware request function.

  This wraps a request function to automatically add auth headers and
  handle authorization errors with retry logic.
  """
  @spec wrap_request_fn(
          (map() -> {:ok, any()} | {:error, any()}),
          keyword()
        ) :: (map() -> {:ok, any()} | {:error, any()})
  def wrap_request_fn(request_fn, opts) do
    fn request ->
      with {:ok, auth_request} <- add_auth_headers(request, opts),
           response <- request_fn.(auth_request),
           {:ok, _} = ok_response <- handle_response(response, %{}) do
        ok_response
      else
        error ->
          error
      end
    end
  end

  # Private functions

  defp get_auth_token(opts) do
    cond do
      # Use token manager if provided
      opts[:token_manager] ->
        case TokenManager.get_token(opts[:token_manager]) do
          {:ok, token} ->
            {:ok, token, opts[:auth_type] || "Bearer"}

          error ->
            error
        end

      # Use static token if provided
      opts[:token] ->
        {:ok, opts[:token], opts[:auth_type] || "Bearer"}

      # No auth configured
      true ->
        {:error, :no_token}
    end
  end

  defp add_authorization_header(headers, token, type) when is_list(headers) do
    [{"Authorization", "#{type} #{token}"} | headers]
  end

  defp add_authorization_header(%{headers: headers} = request, token, type) do
    %{request | headers: add_authorization_header(headers, token, type)}
  end

  defp add_authorization_header(request, token, type) when is_map(request) do
    Map.put(request, :headers, [{"Authorization", "#{type} #{token}"}])
  end
end
