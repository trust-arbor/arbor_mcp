defmodule Arbor.MCP.Plugs.JWKS do
  @moduledoc """
  Serves a JSON Web Key Set (JWKS) for token signature verification.

  This plug serves the `/.well-known/jwks.json` endpoint, allowing clients and
  resource servers to discover the public keys used to verify token signatures.

  ## Usage

  With static keys:

      plug Arbor.MCP.Plugs.JWKS, keys: [%{"kty" => "RSA", "n" => "...", "e" => "..."}]

  With a dynamic key provider function:

      plug Arbor.MCP.Plugs.JWKS, keys_fn: fn -> MyApp.KeyStore.get_public_keys() end

  With JOSE JWK structs (requires `:jose` dependency):

      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      plug Arbor.MCP.Plugs.JWKS, keys: [jwk]

  ## Options

  - `:keys` - A static list of key maps or JOSE.JWK structs.
  - `:keys_fn` - A zero-arity function that returns a list of key maps at call time.
    Takes precedence over `:keys` if both are provided.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts) do
    keys = Keyword.get(opts, :keys)
    keys_fn = Keyword.get(opts, :keys_fn)

    unless keys || keys_fn do
      raise ArgumentError, "Arbor.MCP.Plugs.JWKS requires either :keys or :keys_fn option"
    end

    %{
      keys: keys,
      keys_fn: keys_fn
    }
  end

  @impl true
  def call(conn, opts) do
    case get_keys(opts) do
      {:ok, keys} ->
        jwks = %{"keys" => Enum.map(keys, &to_jwk_map/1)}

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, Jason.encode!(jwks))

      {:error, reason} ->
        Logger.error("JWKS endpoint failed to retrieve keys: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"error" => "server_error"}))
    end
  end

  @doc """
  Retrieves keys from either the static list or the dynamic function.
  """
  @spec get_keys(map()) :: {:ok, [map()]} | {:error, term()}
  def get_keys(%{keys_fn: keys_fn}) when is_function(keys_fn, 0) do
    {:ok, keys_fn.()}
  rescue
    e -> {:error, {:keys_fn_error, Exception.message(e)}}
  end

  def get_keys(%{keys: keys}) when is_list(keys) do
    {:ok, keys}
  end

  def get_keys(_opts) do
    {:error, :no_keys_configured}
  end

  @doc """
  Converts a key to a JWK map suitable for inclusion in a JWKS response.

  Handles plain maps (returned as-is), JOSE.JWK structs (converted to public
  key map), and other formats.
  """
  @spec to_jwk_map(map() | struct()) :: map()
  def to_jwk_map(%{kty: _} = jose_jwk) do
    # JOSE.JWK struct - convert to public key map
    if Code.ensure_loaded?(JOSE.JWK) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {_mod, public_map} = apply(JOSE.JWK, :to_public_map, [jose_jwk])
      public_map
    else
      Logger.warning("JOSE library not loaded, cannot convert JWK struct")
      %{}
    end
  end

  def to_jwk_map(%{"kty" => _} = map) do
    # Already a JWK map with string keys - strip any private key material
    strip_private_fields(map)
  end

  def to_jwk_map(map) when is_map(map) do
    # Unknown map format, return as-is
    map
  end

  # Strip private key fields to ensure only public key material is served.
  defp strip_private_fields(map) do
    private_fields = ["d", "p", "q", "dp", "dq", "qi", "k"]
    Map.drop(map, private_fields)
  end
end
