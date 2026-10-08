defmodule Arbor.MCP.Authorization.JWT do
  @moduledoc """
  General-purpose JWT module wrapping JOSE for MCP authorization.

  Provides key loading, JWT signing, verification, and claims validation
  used by OAuth client assertions, ID-JAG tokens, and JWT bearer grants.
  """

  alias Arbor.MCP.Authorization.MetadataFetcher

  # Clock skew allowance, in seconds, applied to exp/nbf/iat comparisons.
  @default_leeway_seconds 30

  @doc """
  Loads a JWK from a PEM string, JWK map, or file path.

  ## Examples

      {:ok, jwk} = JWT.load_key(%{"kty" => "RSA", ...})
      {:ok, jwk} = JWT.load_key("-----BEGIN RSA PRIVATE KEY-----\\n...")
      {:ok, jwk} = JWT.load_key({:pem_file, "/path/to/key.pem"})
  """
  @spec load_key(map() | String.t() | {:pem_file, String.t()}) ::
          {:ok, JOSE.JWK.t()} | {:error, term()}
  def load_key(%{"kty" => _} = jwk_map) do
    {:ok, JOSE.JWK.from_map(jwk_map)}
  rescue
    e -> {:error, {:invalid_jwk, Exception.message(e)}}
  end

  def load_key(%{kty: _} = jwk_map) do
    string_map = Map.new(jwk_map, fn {k, v} -> {to_string(k), v} end)
    load_key(string_map)
  end

  def load_key(pem) when is_binary(pem) do
    if String.starts_with?(String.trim(pem), "-----BEGIN") do
      {:ok, JOSE.JWK.from_pem(pem)}
    else
      {:error, :invalid_key_format}
    end
  rescue
    e -> {:error, {:invalid_pem, Exception.message(e)}}
  end

  def load_key({:pem_file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, pem} -> load_key(pem)
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  def load_key(_), do: {:error, :invalid_key_format}

  @doc """
  Generates an RSA key pair for development/testing.

  ## Options
    - `:size` - Key size in bits (default: 2048)
  """
  @spec generate_rsa_key(keyword()) :: JOSE.JWK.t()
  def generate_rsa_key(opts \\ []) do
    size = Keyword.get(opts, :size, 2048)
    JOSE.JWK.generate_key({:rsa, size})
  end

  @doc """
  Generates an EC key pair for development/testing.

  ## Options
    - `:curve` - EC curve name (default: "P-256")
  """
  @spec generate_ec_key(keyword()) :: JOSE.JWK.t()
  def generate_ec_key(opts \\ []) do
    curve = Keyword.get(opts, :curve, "P-256")
    JOSE.JWK.generate_key({:ec, curve})
  end

  @doc """
  Extracts the public key from a JWK.
  """
  @spec to_public_key(JOSE.JWK.t()) :: JOSE.JWK.t()
  def to_public_key(jwk) do
    JOSE.JWK.to_public(jwk)
  end

  @doc """
  Converts a JWK to a map representation (for JWKS publishing).
  """
  @spec to_map(JOSE.JWK.t()) :: map()
  def to_map(jwk) do
    {_modules, map} = JOSE.JWK.to_map(jwk)
    map
  end

  @doc """
  Signs a claims map into a compact JWS string.

  ## Options
    - `:alg` - Signing algorithm (default: "RS256")
    - `:kid` - Key ID to include in header
    - `:typ` - Token type header (default: "JWT")
  """
  @spec sign(map(), JOSE.JWK.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sign(claims, jwk, opts \\ []) do
    alg = Keyword.get(opts, :alg, "RS256")
    kid = Keyword.get(opts, :kid)
    typ = Keyword.get(opts, :typ, "JWT")

    header = %{"alg" => alg, "typ" => typ}
    header = if kid, do: Map.put(header, "kid", kid), else: header

    # Auto-load key from PEM string or JWK map if needed
    jwk = ensure_jwk(jwk)

    jws = JOSE.JWS.from_map(header)
    payload = Jason.encode!(claims)

    {_modules, signed} = JOSE.JWK.sign(payload, jws, jwk)
    {_modules, compact} = JOSE.JWS.compact(signed)
    {:ok, compact}
  rescue
    e -> {:error, {:signing_error, Exception.message(e)}}
  end

  @doc """
  Verifies the *signature* of a JWS string and returns the decoded claims.

  Accepts a single JWK or a list of JWKs (JWKS).

  > #### Signature verification only {: .warning}
  >
  > This function performs **no claims validation**: an expired token, a
  > token that is not yet valid, or a token issued for another audience all
  > verify successfully as long as the signature is good. Use
  > `verify_and_validate/3` (or `validate_claims/2` on the result) for
  > anything that makes an authorization decision.
  """
  @spec verify(String.t(), JOSE.JWK.t() | [JOSE.JWK.t()]) ::
          {:ok, map()} | {:error, term()}
  def verify(token, jwk_or_jwks) when is_binary(token) do
    jwks = List.wrap(jwk_or_jwks)

    result =
      Enum.find_value(jwks, {:error, :verification_failed}, fn jwk ->
        case JOSE.JWK.verify_strict(token, allowed_algorithms(), jwk) do
          {true, payload, _jws} ->
            case Jason.decode(payload) do
              {:ok, claims} -> {:ok, claims}
              {:error, _} -> nil
            end

          {false, _payload, _jws} ->
            nil
        end
      end)

    result
  rescue
    e -> {:error, {:verification_error, Exception.message(e)}}
  end

  @doc """
  Verifies a JWS string and validates claims against expected values.

  Takes the same options as `validate_claims/2`. Note that `exp` is required
  by default; pass `require_exp: false` for the rare token profile that
  legitimately omits it.
  """
  @spec verify_and_validate(String.t(), JOSE.JWK.t() | [JOSE.JWK.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_and_validate(token, jwk_or_jwks, expected \\ []) do
    with {:ok, claims} <- verify(token, jwk_or_jwks) do
      validate_claims(claims, expected)
    end
  end

  @doc """
  Validates standard JWT claims against expected values.

  ## Time-based claims

  `exp` is **required by default** and must be a number: a token without an
  expiry, or with a non-numeric expiry, is rejected. `nbf` and `iat` are
  optional, but when present they must be numeric — a non-numeric value is
  rejected rather than ignored.

  All time comparisons allow `:leeway` seconds of clock skew (default
  `#{@default_leeway_seconds}`).

  ## Options
    - `:leeway` - Clock skew allowance in seconds (default: `#{@default_leeway_seconds}`)
    - `:require_exp` - Require an `exp` claim (default: `true`)
    - `:iss` - Expected issuer
    - `:aud` - Expected audience (string or list)
    - `:sub` - Expected subject
    - `:max_age` - Maximum token age in seconds
    - `:required` - List of required claim keys (as strings)

  ## Errors

    - `{:error, :missing_exp}` - no `exp` claim and `require_exp` is true
    - `{:error, {:invalid_claim_type, "exp" | "nbf" | "iat"}}` - claim present but not a number
    - `{:error, :token_expired}` / `{:error, :token_not_yet_valid}` / `{:error, :invalid_iat}`
  """
  @spec validate_claims(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_claims(claims, expected \\ []) do
    now = System.system_time(:second)
    leeway = Keyword.get(expected, :leeway, @default_leeway_seconds)
    # Anything other than an explicit `false` keeps exp required (fail closed).
    require_exp = Keyword.get(expected, :require_exp, true) != false

    validations = [
      fn -> validate_exp(claims, now, leeway, require_exp) end,
      fn -> validate_iat(claims, now, leeway) end,
      fn -> validate_nbf(claims, now, leeway) end,
      fn -> validate_iss(claims, expected[:iss]) end,
      fn -> validate_aud(claims, expected[:aud]) end,
      fn -> validate_sub(claims, expected[:sub]) end,
      fn -> validate_max_age(claims, now, expected[:max_age]) end,
      fn -> validate_required(claims, expected[:required]) end
    ]

    case Enum.find_value(validations, fn v -> error_or_nil(v.()) end) do
      nil -> {:ok, claims}
      error -> error
    end
  end

  @doc """
  Generates a unique JWT ID (jti).
  """
  @spec generate_jti() :: String.t()
  def generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  @doc """
  Fetches a JWKS (JSON Web Key Set) from a URL.

  Uses the same HTTPS-only, public-address, pinned and bounded fetch policy as
  authorization-server and client metadata discovery. Custom HTTP clients must
  implement `get(uri, approved_address, opts)`.
  """
  @spec fetch_jwks(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def fetch_jwks(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case MetadataFetcher.fetch(url, opts) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"keys" => keys}} when is_list(keys) ->
            load_jwks(keys)

          {:ok, _} ->
            {:error, :invalid_jwks_format}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_jwks(keys) do
    {:ok, Enum.map(keys, &JOSE.JWK.from_map/1)}
  rescue
    _exception -> {:error, :invalid_jwks_format}
  end

  @doc """
  Reads the unverified header from a JWS token (for typ checking).
  """
  @spec peek_header(String.t()) :: {:ok, map()} | {:error, term()}
  def peek_header(token) when is_binary(token) do
    case String.split(token, ".") do
      [header_b64 | _] ->
        case Base.url_decode64(header_b64, padding: false) do
          {:ok, header_json} ->
            Jason.decode(header_json)

          :error ->
            {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  # Private helpers

  defp allowed_algorithms do
    ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"]
  end

  defp error_or_nil(:ok), do: nil
  defp error_or_nil({:error, _} = err), do: err

  defp validate_exp(%{"exp" => exp}, now, leeway, _require_exp) when is_number(exp) do
    if now <= exp + leeway, do: :ok, else: {:error, :token_expired}
  end

  # An `exp` claim that is present but not a number is always a rejection:
  # silently ignoring it would let `{"exp": "whenever"}` pass as unexpiring.
  defp validate_exp(%{"exp" => _}, _now, _leeway, _require_exp) do
    {:error, {:invalid_claim_type, "exp"}}
  end

  defp validate_exp(_claims, _now, _leeway, true), do: {:error, :missing_exp}
  defp validate_exp(_claims, _now, _leeway, false), do: :ok

  defp validate_iat(%{"iat" => iat}, now, leeway) when is_number(iat) do
    # iat must not be in the future (beyond the allowed clock skew)
    if iat <= now + leeway, do: :ok, else: {:error, :invalid_iat}
  end

  defp validate_iat(%{"iat" => _}, _now, _leeway), do: {:error, {:invalid_claim_type, "iat"}}
  defp validate_iat(_claims, _now, _leeway), do: :ok

  defp validate_nbf(%{"nbf" => nbf}, now, leeway) when is_number(nbf) do
    if now >= nbf - leeway, do: :ok, else: {:error, :token_not_yet_valid}
  end

  defp validate_nbf(%{"nbf" => _}, _now, _leeway), do: {:error, {:invalid_claim_type, "nbf"}}
  defp validate_nbf(_claims, _now, _leeway), do: :ok

  defp validate_iss(_, nil), do: :ok

  defp validate_iss(%{"iss" => iss}, expected_iss) do
    if iss == expected_iss, do: :ok, else: {:error, {:invalid_issuer, iss}}
  end

  defp validate_iss(_, _expected), do: {:error, :missing_issuer}

  defp validate_aud(_, nil), do: :ok

  defp validate_aud(%{"aud" => aud}, expected_aud) when is_binary(expected_aud) do
    aud_list = List.wrap(aud)
    if expected_aud in aud_list, do: :ok, else: {:error, {:invalid_audience, aud}}
  end

  defp validate_aud(%{"aud" => aud}, expected_auds) when is_list(expected_auds) do
    aud_list = List.wrap(aud)

    if Enum.any?(expected_auds, &(&1 in aud_list)),
      do: :ok,
      else: {:error, {:invalid_audience, aud}}
  end

  defp validate_aud(_, _expected), do: {:error, :missing_audience}

  defp validate_sub(_, nil), do: :ok

  defp validate_sub(%{"sub" => sub}, expected_sub) do
    if sub == expected_sub, do: :ok, else: {:error, {:invalid_subject, sub}}
  end

  defp validate_sub(_, _expected), do: {:error, :missing_subject}

  defp validate_max_age(_, _, nil), do: :ok

  defp validate_max_age(%{"iat" => iat}, now, max_age) when is_number(iat) do
    if now - iat <= max_age, do: :ok, else: {:error, :token_too_old}
  end

  defp validate_max_age(_, _, _max_age), do: {:error, :missing_iat_for_max_age}

  defp validate_required(_, nil), do: :ok

  defp validate_required(claims, required) when is_list(required) do
    missing = Enum.filter(required, fn key -> not Map.has_key?(claims, key) end)

    if Enum.empty?(missing),
      do: :ok,
      else: {:error, {:missing_required_claims, missing}}
  end

  # Convert various key formats to JOSE.JWK
  defp ensure_jwk(%JOSE.JWK{} = jwk), do: jwk

  defp ensure_jwk(pem) when is_binary(pem) do
    if String.contains?(pem, "BEGIN") do
      JOSE.JWK.from_pem(pem)
    else
      pem
    end
  end

  defp ensure_jwk(%{"kty" => _} = map), do: JOSE.JWK.from_map(map)
  defp ensure_jwk(other), do: other
end
