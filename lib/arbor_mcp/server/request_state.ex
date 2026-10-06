defmodule Arbor.MCP.Server.RequestState do
  @moduledoc """
  Seals and verifies opaque MCP multi-round-trip request state.

  State is encoded as bounded JSON and authenticated with AES-256-GCM. The
  key ring is runtime configuration; ArborMCP never provides or persists a
  fallback secret.
  """

  alias Arbor.MCP.Server.RequestContext

  @prefix "mcp-rs1"
  @algorithm "A256GCM"
  @nonce_bytes 12
  @tag_bytes 16
  @default_ttl 300
  @default_max_ttl 900
  @default_clock_skew 30
  @default_max_token_bytes 65_536
  @default_max_json_bytes 32_768

  @type error ::
          :request_state_not_configured
          | :invalid_request_state_configuration
          | :invalid_request_state
          | :request_state_expired
          | :request_state_not_yet_valid
          | :request_state_key_revoked
          | :request_state_key_unknown
          | :request_state_too_large
          | :request_state_binding_mismatch
          | :input_response_ids_mismatch
          | :request_state_not_json

  @doc "Validates that an active 256-bit key is present in the runtime key ring."
  @spec validate_configuration(keyword()) :: :ok | {:error, error()}
  def validate_configuration(opts \\ []) do
    with {:ok, config} <- configuration(opts),
         {:ok, _key} <- active_key(config) do
      :ok
    end
  end

  @spec seal(term(), map(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def seal(application_state, binding, opts \\ []) when is_map(binding) do
    with {:ok, config} <- configuration(opts),
         {:ok, key} <- active_key(config),
         {:ok, payload_json} <- encode_payload(application_state, binding, config),
         {:ok, header_json} <-
           Jason.encode(%{"alg" => @algorithm, "kid" => config.active, "v" => 1}) do
      header = encode64(header_json)
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = @prefix <> "." <> header

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, payload_json, aad, true)

      token =
        Enum.join([@prefix, header, encode64(nonce), encode64(ciphertext), encode64(tag)], ".")

      if byte_size(token) <= config.max_token_bytes,
        do: {:ok, token},
        else: {:error, :request_state_too_large}
    end
  end

  @spec unseal(String.t(), RequestContext.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def unseal(token, context, params, input_responses, opts \\ [])

  def unseal(token, context, params, input_responses, opts)
      when is_binary(token) and is_map(params) and is_map(input_responses) do
    with {:ok, config} <- configuration(opts),
         :ok <- validate_token_size(token, config),
         {:ok, header_segment, nonce, ciphertext, tag} <- decode_envelope(token),
         {:ok, header} <- decode_json(header_segment, config),
         :ok <- validate_header(header, nonce, tag, config),
         {:ok, key} <- decryption_key(config, header["kid"]),
         {:ok, plaintext} <- decrypt(key, header_segment, nonce, ciphertext, tag),
         {:ok, payload} <- decode_json_payload(plaintext, config),
         :ok <- validate_times(payload, config),
         :ok <- validate_binding(payload, context, params, input_responses, opts) do
      {:ok, payload}
    end
  end

  def unseal(_token, _context, _params, _input_responses, _opts),
    do: {:error, :invalid_request_state}

  @doc false
  @spec binding(RequestContext.t(), map(), [String.t()], non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def binding(context, params, expected_input_ids, round, opts \\ []) do
    immutable_params = immutable_params(params)

    with {:ok, params_digest} <- digest(immutable_params),
         {:ok, capability_digest} <- digest(context.client_capabilities || %{}) do
      {:ok,
       %{
         "capabilityDigest" => capability_digest,
         "endpoint" => context.endpoint || Keyword.get(opts, :endpoint),
         "expectedInputIds" => Enum.sort(expected_input_ids),
         "method" => context.method,
         "paramsDigest" => params_digest,
         "principalId" => context.principal_id || Keyword.get(opts, :principal_id),
         "protocolVersion" => context.protocol_version,
         "round" => round,
         "tenantId" => context.tenant_id || Keyword.get(opts, :tenant_id)
       }}
    else
      {:error, _reason} -> {:error, :request_state_not_json}
    end
  end

  defp immutable_params(params) do
    params = Map.drop(params, ["inputResponses", "requestState", :inputResponses, :requestState])

    Enum.reduce(["arguments", :arguments], params, fn key, acc ->
      case Map.get(acc, key) do
        arguments when is_map(arguments) ->
          Map.put(acc, key, Map.drop(arguments, ["_request_id", :_request_id]))

        _other ->
          acc
      end
    end)
  end

  @doc false
  @spec canonical_json(term()) :: {:ok, binary()} | {:error, :not_json}
  def canonical_json(value) do
    case canonical_iodata(value) do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
      {:error, :not_json} = error -> error
    end
  end

  defp configuration(opts) do
    configured =
      Keyword.get(opts, :request_state) ||
        Application.get_env(:arbor_mcp, :request_state, [])

    with true <- is_list(configured),
         active when is_binary(active) and byte_size(active) > 0 <-
           Keyword.get(configured, :active_key_id),
         {:ok, keys} <- normalize_keys(Keyword.get(configured, :keys, %{})),
         true <- map_size(keys) > 0,
         max_ttl when is_integer(max_ttl) and max_ttl > 0 <-
           Keyword.get(configured, :max_ttl_seconds, @default_max_ttl),
         configured_ttl when is_integer(configured_ttl) and configured_ttl > 0 <-
           Keyword.get(configured, :ttl_seconds, @default_ttl),
         clock_skew when is_integer(clock_skew) and clock_skew >= 0 <-
           Keyword.get(configured, :clock_skew_seconds, @default_clock_skew),
         max_token_bytes when is_integer(max_token_bytes) and max_token_bytes > 0 <-
           Keyword.get(configured, :max_token_bytes, @default_max_token_bytes),
         max_json_bytes when is_integer(max_json_bytes) and max_json_bytes > 0 <-
           Keyword.get(configured, :max_json_bytes, @default_max_json_bytes),
         now when is_integer(now) <-
           Keyword.get(opts, :request_state_now, System.system_time(:second)) do
      ttl = min(configured_ttl, max_ttl)

      {:ok,
       %{
         active: active,
         keys: keys,
         revoked: configured |> Keyword.get(:revoked_key_ids, []) |> MapSet.new(),
         ttl: ttl,
         max_ttl: max_ttl,
         clock_skew: clock_skew,
         max_token_bytes: max_token_bytes,
         max_json_bytes: max_json_bytes,
         now: now
       }}
    else
      nil -> {:error, :request_state_not_configured}
      false -> {:error, :invalid_request_state_configuration}
      _other -> {:error, :invalid_request_state_configuration}
    end
  end

  defp normalize_keys(keys) when is_map(keys) or is_list(keys) do
    keys
    |> Enum.reduce_while({:ok, %{}}, fn {id, value}, {:ok, acc} ->
      case normalize_key(value) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, to_string(id), key)}}
        :error -> {:halt, {:error, :invalid_request_state_configuration}}
      end
    end)
  end

  defp normalize_keys(_keys), do: {:error, :invalid_request_state_configuration}

  defp normalize_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}

  defp normalize_key({:base64, encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _other -> :error
    end
  end

  defp normalize_key(_key), do: :error

  defp active_key(config) do
    if MapSet.member?(config.revoked, config.active) do
      {:error, :invalid_request_state_configuration}
    else
      case Map.fetch(config.keys, config.active) do
        {:ok, key} -> {:ok, key}
        :error -> {:error, :invalid_request_state_configuration}
      end
    end
  end

  defp encode_payload(application_state, binding, config) do
    payload = %{
      "applicationState" => application_state,
      "binding" => binding,
      "codec" => "json-v1",
      "exp" => config.now + config.ttl,
      "iat" => config.now,
      "jti" => encode64(:crypto.strong_rand_bytes(16)),
      "v" => 1
    }

    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= config.max_json_bytes -> {:ok, encoded}
      {:ok, _encoded} -> {:error, :request_state_too_large}
      {:error, _reason} -> {:error, :request_state_not_json}
    end
  end

  defp validate_token_size(token, config) do
    if byte_size(token) <= config.max_token_bytes,
      do: :ok,
      else: {:error, :request_state_too_large}
  end

  defp decode_envelope(token) do
    case String.split(token, ".", parts: 5) do
      [@prefix, header, nonce, ciphertext, tag] ->
        with {:ok, nonce} <- decode64(nonce),
             {:ok, ciphertext} <- decode64(ciphertext),
             {:ok, tag} <- decode64(tag) do
          {:ok, header, nonce, ciphertext, tag}
        else
          _other -> {:error, :invalid_request_state}
        end

      _other ->
        {:error, :invalid_request_state}
    end
  end

  defp decode_json(header_segment, config) do
    with {:ok, encoded} <- decode64(header_segment),
         true <- byte_size(encoded) <= config.max_json_bytes,
         {:ok, value} when is_map(value) <- Jason.decode(encoded) do
      {:ok, value}
    else
      _other -> {:error, :invalid_request_state}
    end
  end

  defp decode_json_payload(encoded, config) do
    if byte_size(encoded) <= config.max_json_bytes do
      case Jason.decode(encoded) do
        {:ok, %{"binding" => binding} = payload} when is_map(binding) -> {:ok, payload}
        _other -> {:error, :invalid_request_state}
      end
    else
      {:error, :request_state_too_large}
    end
  end

  defp validate_header(%{"alg" => @algorithm, "kid" => kid, "v" => 1}, nonce, tag, config)
       when is_binary(kid) do
    cond do
      byte_size(nonce) != @nonce_bytes -> {:error, :invalid_request_state}
      byte_size(tag) != @tag_bytes -> {:error, :invalid_request_state}
      MapSet.member?(config.revoked, kid) -> {:error, :request_state_key_revoked}
      true -> :ok
    end
  end

  defp validate_header(_header, _nonce, _tag, _config),
    do: {:error, :invalid_request_state}

  defp decryption_key(config, kid) do
    case Map.fetch(config.keys, kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :request_state_key_unknown}
    end
  end

  defp decrypt(key, header_segment, nonce, ciphertext, tag) do
    aad = @prefix <> "." <> header_segment

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
      :error -> {:error, :invalid_request_state}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  rescue
    _error -> {:error, :invalid_request_state}
  end

  defp validate_times(%{"iat" => iat, "exp" => exp}, config)
       when is_integer(iat) and is_integer(exp) do
    cond do
      iat > config.now + config.clock_skew -> {:error, :request_state_not_yet_valid}
      exp < config.now - config.clock_skew -> {:error, :request_state_expired}
      exp <= iat -> {:error, :invalid_request_state}
      exp - iat > config.max_ttl -> {:error, :invalid_request_state}
      true -> :ok
    end
  end

  defp validate_times(_payload, _config), do: {:error, :invalid_request_state}

  defp validate_binding(%{"binding" => sealed}, context, params, responses, opts) do
    expected_ids = sealed["expectedInputIds"]
    round = sealed["round"]

    with true <- is_list(expected_ids) and Enum.all?(expected_ids, &is_binary/1),
         true <- is_integer(round) and round > 0,
         true <- Enum.sort(Map.keys(responses)) == Enum.sort(expected_ids),
         {:ok, current} <- binding(context, params, expected_ids, round, opts),
         true <- current == sealed do
      :ok
    else
      false ->
        if is_list(expected_ids) and Enum.sort(Map.keys(responses)) != Enum.sort(expected_ids),
          do: {:error, :input_response_ids_mismatch},
          else: {:error, :request_state_binding_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_binding(_payload, _context, _params, _responses, _opts),
    do: {:error, :invalid_request_state}

  defp digest(value) do
    case canonical_json(value) do
      {:ok, encoded} -> {:ok, encode64(:crypto.hash(:sha256, encoded))}
      {:error, :not_json} -> {:error, :not_json}
    end
  end

  defp canonical_iodata(nil), do: {:ok, "null"}
  defp canonical_iodata(true), do: {:ok, "true"}
  defp canonical_iodata(false), do: {:ok, "false"}

  defp canonical_iodata(value) when is_binary(value) or is_number(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  defp canonical_iodata(values) when is_list(values) do
    with {:ok, encoded} <- map_canonical(values) do
      {:ok, ["[", Enum.intersperse(encoded, ","), "]"]}
    end
  end

  defp canonical_iodata(map) when is_map(map) do
    with {:ok, pairs} <- canonical_pairs(map),
         {:ok, encoded} <- map_canonical_pairs(pairs) do
      {:ok, ["{", Enum.intersperse(encoded, ","), "}"]}
    end
  end

  defp canonical_iodata(_value), do: {:error, :not_json}

  defp canonical_pairs(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case json_key(key) do
        {:ok, key} when not is_map_key(acc, key) -> {:cont, {:ok, Map.put(acc, key, value)}}
        _other -> {:halt, {:error, :not_json}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, &elem(&1, 0))}
      error -> error
    end
  end

  defp map_canonical(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case canonical_iodata(value) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp map_canonical_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case canonical_iodata(value) do
        {:ok, encoded} -> {:cont, {:ok, [[Jason.encode!(key), ":", encoded] | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(_key), do: {:error, :not_json}

  defp encode64(value), do: Base.url_encode64(value, padding: false)
  defp decode64(value), do: Base.url_decode64(value, padding: false)
end
