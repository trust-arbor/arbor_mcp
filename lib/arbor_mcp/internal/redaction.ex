defmodule Arbor.MCP.Internal.Redaction do
  @moduledoc false
  # What a client's state may show when it is inspected, returned by
  # :sys.get_status/1, or written to a crash report.
  #
  # Credentials do not come with a fixed name: an API key travels in a header
  # its service chose, a stdio server's secrets in environment variables of
  # any name, an OAuth provider keeps tokens in state of its own shape. So
  # this fails closed: header names stay visible but no header value does, and
  # of the client's start options only a known-safe set is shown as given.

  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper}
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  @redacted "[REDACTED]"

  # Start options that never carry a credential.
  @safe_options [
    :transport,
    :transports,
    :url,
    :endpoint,
    :name,
    :protocol_mode,
    :protocol_version,
    :use_sse,
    :legacy_http_sse,
    :handshake_timeout,
    :era_probe_timeout,
    :establish_timeout,
    :timeout,
    :request_timeout,
    :stream_handshake_timeout,
    :stream_idle_timeout,
    :health_check_interval,
    :reconnect,
    :max_reconnect_attempts,
    :reconnect_backoff,
    :retry_policy,
    :process_group,
    :environment_policy,
    :cd,
    :max_frame_bytes,
    :max_request_bytes,
    :max_response_bytes,
    :max_stream_buffer_bytes,
    :conformance_mode,
    :era_cache_legacy_ttl,
    :reset_era_cache,
    :type
  ]

  # Keys of an HTTP `security:` map that never carry a credential.
  @safe_security_keys [:validate_origin, :allowed_origins, :trusted_origins, :cors, :origin]

  @doc "The value printed in place of a secret."
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  @doc "Header names with every value replaced."
  @spec headers(term()) :: term()
  def headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {name, _value} -> {name, @redacted}
      _other -> @redacted
    end)
  end

  def headers(nil), do: nil
  def headers(_other), do: @redacted

  @doc "nil stays nil; anything else is replaced."
  @spec secret(term()) :: term()
  def secret(nil), do: nil
  def secret(_value), do: @redacted

  @doc "A URL without its user info, query or fragment."
  @spec url(term()) :: term()
  def url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _not_absolute ->
        value
    end
  end

  def url(value), do: value

  @doc "A client's start options, with anything not known to be safe replaced."
  @spec options(term()) :: term()
  def options(opts) when is_list(opts) do
    Enum.map(opts, fn
      {key, value} when key in [:url, :endpoint] -> {key, url(value)}
      {key, value} when key in [:transport, :transports] -> {key, transport_spec(value)}
      {key, value} when key in @safe_options -> {key, value}
      {key, _value} when is_atom(key) -> {key, @redacted}
      other -> transport_spec(other)
    end)
  end

  def options(opts), do: secret(opts)

  defp transport_spec({transport, opts}) when is_atom(transport) and is_list(opts),
    do: {transport, options(opts)}

  defp transport_spec(specs) when is_list(specs) do
    if Keyword.keyword?(specs), do: options(specs), else: Enum.map(specs, &transport_spec/1)
  end

  defp transport_spec(transport) when is_atom(transport), do: transport
  defp transport_spec(_other), do: @redacted

  @doc "An HTTP `security:` map with its credentials replaced."
  @spec security(term()) :: term()
  def security(%{} = security) do
    Map.new(security, fn
      {key, value} when key in @safe_security_keys -> {key, value}
      {key, _value} -> {key, @redacted}
    end)
  end

  def security(security), do: secret(security)

  @doc "A transport state with its credentials replaced."
  @spec transport_state(module() | nil, term()) :: term()
  def transport_state(_transport_mod, %HTTP{} = state), do: http(state)
  def transport_state(_transport_mod, %LegacySSE{} = state), do: legacy_sse(state)

  def transport_state(_transport_mod, %ReliabilityWrapper{} = state),
    do: %{state | wrapped_state: transport_state(state.wrapped_module, state.wrapped_state)}

  def transport_state(_transport_mod, state), do: state

  @spec http(HTTP.t()) :: HTTP.t()
  def http(%HTTP{} = state) do
    %{
      state
      | headers: headers(state.headers),
        access_token: secret(state.access_token),
        session_id: secret(state.session_id),
        auth_config: secret(state.auth_config),
        auth_provider_state: secret(state.auth_provider_state),
        security: security(state.security)
    }
  end

  @spec legacy_sse(LegacySSE.t()) :: LegacySSE.t()
  def legacy_sse(%LegacySSE{} = state) do
    %{
      state
      | headers: headers(state.headers),
        session_id: secret(state.session_id),
        sse_url: url(state.sse_url),
        post_url: url(state.post_url)
    }
  end

  @doc "An `Arbor.MCP.Client` state with its credentials replaced."
  @spec client(struct()) :: struct()
  def client(%{transport_opts: _opts, transport_state: _state} = client) do
    %{
      client
      | transport_opts: options(client.transport_opts),
        transport_state: transport_state(client.transport_mod, client.transport_state)
    }
  end

  @doc """
  A GenServer `format_status/1` result with `redact` applied to its state, for
  crash reports and `:sys.get_status/1`.
  """
  @spec status(map(), (term() -> term())) :: map()
  def status(%{state: state} = status, redact), do: %{status | state: redact.(state)}
  def status(status, _redact), do: status
end
