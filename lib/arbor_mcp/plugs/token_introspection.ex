defmodule Arbor.MCP.Plugs.TokenIntrospection do
  @moduledoc """
  Server-side token introspection endpoint (RFC 7662).

  This plug handles incoming token introspection requests from resource servers
  or other authorized parties. It validates the token using a configured callback
  and returns the token's metadata.

  ## Usage

      plug Arbor.MCP.Plugs.TokenIntrospection,
        introspect_fn: fn token, token_type_hint ->
          case MyApp.TokenStore.lookup(token) do
            {:ok, token_data} ->
              {:ok, %{
                active: true,
                scope: token_data.scope,
                client_id: token_data.client_id,
                exp: token_data.expires_at,
                sub: token_data.subject
              }}
            :error ->
              {:ok, %{active: false}}
          end
        end

  ## Options

  - `:introspect_fn` (required) - A function `(token, token_type_hint) -> {:ok, map()} | {:error, term()}`.
    Must return a map with at least an `:active` or `"active"` boolean field.
    When the token is invalid or unknown, return `{:ok, %{active: false}}`.
  - `:authenticate_client_fn` - Optional function `(conn) -> {:ok, client_id} | {:error, term()}`.
    If provided, the requesting client is authenticated before introspection proceeds.
    Per RFC 7662, the introspection endpoint SHOULD require authentication.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts) do
    introspect_fn = Keyword.get(opts, :introspect_fn)

    unless introspect_fn do
      raise ArgumentError, "Arbor.MCP.Plugs.TokenIntrospection requires :introspect_fn option"
    end

    %{
      introspect_fn: introspect_fn,
      authenticate_client_fn: Keyword.get(opts, :authenticate_client_fn)
    }
  end

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    with {:ok, conn} <- ensure_body_read(conn),
         {:ok, _client_id} <- authenticate_client(conn, opts),
         {:ok, token, token_type_hint} <- extract_token_params(conn) do
      case opts.introspect_fn.(token, token_type_hint) do
        {:ok, token_info} ->
          response = normalize_introspection_response(token_info)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response))

        {:error, reason} ->
          Logger.warning("Token introspection callback error: #{inspect(reason)}")

          # Per RFC 7662, if the token is invalid or the server cannot
          # determine its state, respond with active: false
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"active" => false}))
      end
    else
      {:error, :missing_token} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_request",
            "error_description" => "The 'token' parameter is required."
          })
        )

      {:error, :client_authentication_failed} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            "error" => "invalid_client",
            "error_description" => "Client authentication failed."
          })
        )

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_request",
            "error_description" => "Unable to process introspection request."
          })
        )
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      405,
      Jason.encode!(%{
        "error" => "invalid_request",
        "error_description" => "Method not allowed. Use POST."
      })
    )
  end

  defp ensure_body_read(conn) do
    if conn.body_params && conn.body_params != %Plug.Conn.Unfetched{aspect: :body_params} do
      {:ok, conn}
    else
      case Plug.Conn.read_body(conn) do
        {:ok, body, conn} ->
          params = URI.decode_query(body)
          {:ok, %{conn | body_params: params}}

        {:error, reason} ->
          {:error, {:body_read_error, reason}}
      end
    end
  end

  defp authenticate_client(_conn, %{authenticate_client_fn: nil}), do: {:ok, nil}

  defp authenticate_client(conn, %{authenticate_client_fn: auth_fn})
       when is_function(auth_fn, 1) do
    case auth_fn.(conn) do
      {:ok, client_id} -> {:ok, client_id}
      {:error, _} -> {:error, :client_authentication_failed}
    end
  end

  defp authenticate_client(_conn, _opts), do: {:ok, nil}

  defp extract_token_params(conn) do
    params = conn.body_params

    case Map.get(params, "token") do
      nil ->
        {:error, :missing_token}

      "" ->
        {:error, :missing_token}

      token ->
        token_type_hint = Map.get(params, "token_type_hint")
        {:ok, token, token_type_hint}
    end
  end

  # Normalize the introspection response to use string keys per RFC 7662.
  defp normalize_introspection_response(token_info) do
    # Standard RFC 7662 fields
    standard_fields = [
      :active,
      :scope,
      :client_id,
      :username,
      :token_type,
      :exp,
      :iat,
      :nbf,
      :sub,
      :aud,
      :iss,
      :jti
    ]

    token_info
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_atom(key) ->
        if key in standard_fields or not Map.has_key?(acc, Atom.to_string(key)) do
          Map.put(acc, Atom.to_string(key), value)
        else
          acc
        end

      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
    |> ensure_active_field()
  end

  defp ensure_active_field(%{"active" => _} = response), do: response
  defp ensure_active_field(response), do: Map.put(response, "active", false)
end
