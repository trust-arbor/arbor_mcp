defmodule Arbor.MCP.Plugs.TokenRevocation do
  @moduledoc """
  Server-side token revocation endpoint (RFC 7009).

  This plug handles incoming token revocation requests. When a client sends
  a POST with a `token` parameter, the plug calls the configured revocation
  callback to invalidate the token.

  Per RFC 7009, the endpoint always returns 200 OK, even if the token was
  already invalid or unknown, to prevent token scanning attacks.

  ## Usage

      plug Arbor.MCP.Plugs.TokenRevocation,
        revoke_fn: fn token, token_type_hint ->
          MyApp.TokenStore.revoke(token, token_type_hint)
        end

  Or with a module callback:

      plug Arbor.MCP.Plugs.TokenRevocation,
        revoke_fn: &MyApp.TokenStore.revoke/2

  ## Options

  - `:revoke_fn` (required) - A function `(token, token_type_hint) -> :ok | {:error, term()}`.
    Called to actually revoke the token. `token_type_hint` may be `nil`,
    `"access_token"`, or `"refresh_token"`.
  - `:authenticate_client_fn` - Optional function `(conn) -> {:ok, client_id} | {:error, term()}`.
    If provided, the client is authenticated before processing the revocation.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts) do
    revoke_fn = Keyword.get(opts, :revoke_fn)

    unless revoke_fn do
      raise ArgumentError, "Arbor.MCP.Plugs.TokenRevocation requires :revoke_fn option"
    end

    %{
      revoke_fn: revoke_fn,
      authenticate_client_fn: Keyword.get(opts, :authenticate_client_fn)
    }
  end

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    with {:ok, conn} <- ensure_body_read(conn),
         {:ok, _client_id} <- authenticate_client(conn, opts),
         {:ok, token, token_type_hint} <- extract_token_params(conn) do
      # Per RFC 7009, always return 200 regardless of revocation outcome
      case opts.revoke_fn.(token, token_type_hint) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Token revocation callback returned error: #{inspect(reason)}")
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, "")
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
            "error_description" => "Unable to process revocation request."
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
end
