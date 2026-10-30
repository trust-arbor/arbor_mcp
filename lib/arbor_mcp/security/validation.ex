defmodule Arbor.MCP.Security.Validation do
  @moduledoc """
  Handles request and response validation, including transport layer security configurations.

  This module is responsible for various validation tasks to ensure that
  incoming requests and security configurations meet the required policies.
  """

  alias Arbor.MCP.Internal.Headers
  alias Arbor.MCP.Security.TokenHandler

  require Logger

  # Binding values that keep a listener on the loopback interface.
  @localhost_bindings ["127.0.0.1", "localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1"]

  @typedoc """
  Security configuration map for transport-level security.

  Supports bearer tokens, API keys, basic auth, OAuth 2.1, custom headers,
  origin validation, CORS, and TLS configuration.

  `:trusted_origins` lists exact HTTP(S) origins this one connection may send
  credentials to without consent, in addition to the VM-wide
  `config :arbor_mcp, :security, trusted_origins: [...]` (see
  `Arbor.MCP.Transport.SecurityGuard`).
  """
  @type security_config :: %{
          optional(:auth) => auth_method(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:validate_origin) => boolean(),
          optional(:allowed_origins) => [String.t()],
          optional(:cors) => map(),
          optional(:tls) => map(),
          optional(:trusted_origins) => [String.t()]
        }

  @type auth_method ::
          {:bearer, token :: String.t()}
          | {:api_key, key :: String.t(), opts :: keyword()}
          | {:basic, username :: String.t(), password :: String.t()}
          | {:custom, headers :: [{String.t(), String.t()}]}
          | {:oauth2, map()}

  @doc """
  Validates that a server binding is localhost-only for security.

  Accepts the shapes `:gen_tcp`/`:inet` understand: binaries (`"127.0.0.1"`),
  charlists (`~c"127.0.0.1"`), address tuples (`{127, 0, 0, 1}`,
  `{0, 0, 0, 0, 0, 0, 0, 1}`) and the `:loopback` atom. A configured binding
  of any other shape is rejected rather than silently accepted — a
  `{0, 0, 0, 0}` tuple binds every interface just as `"0.0.0.0"` does.

  A config with no `:binding` key at all is not a binding decision and passes.

  ## Examples

      iex> Arbor.MCP.Security.Validation.validate_localhost_binding(%{binding: "127.0.0.1"})
      :ok

      iex> Arbor.MCP.Security.Validation.validate_localhost_binding(%{binding: "localhost"})
      :ok

      iex> Arbor.MCP.Security.Validation.validate_localhost_binding(%{binding: {127, 0, 0, 1}})
      :ok

      iex> Arbor.MCP.Security.Validation.validate_localhost_binding(%{binding: "0.0.0.0"})
      {:error, :public_binding_requires_security}

      iex> Arbor.MCP.Security.Validation.validate_localhost_binding(%{binding: {0, 0, 0, 0}})
      {:error, :public_binding_requires_security}
  """
  @spec validate_localhost_binding(map()) :: :ok | {:error, :public_binding_requires_security}
  def validate_localhost_binding(%{binding: binding}) when is_binary(binding) do
    if binding in @localhost_bindings do
      :ok
    else
      {:error, :public_binding_requires_security}
    end
  end

  def validate_localhost_binding(%{binding: :loopback}), do: :ok

  def validate_localhost_binding(%{binding: binding}) when is_tuple(binding) do
    if loopback_address?(binding) do
      :ok
    else
      {:error, :public_binding_requires_security}
    end
  end

  def validate_localhost_binding(%{binding: binding}) when is_list(binding) do
    if List.ascii_printable?(binding) do
      validate_localhost_binding(%{binding: List.to_string(binding)})
    else
      {:error, :public_binding_requires_security}
    end
  end

  # A binding was configured but is not a shape we can recognise as loopback
  # (`:any`, `nil`, a port number, ...). Fail closed.
  def validate_localhost_binding(%{binding: _unrecognized}) do
    {:error, :public_binding_requires_security}
  end

  def validate_localhost_binding(_config), do: :ok

  # IPv4 loopback is the whole 127.0.0.0/8 block; IPv6 loopback is ::1.
  # IPv4-mapped IPv6 loopback is ::ffff:127.0.0.0/8.
  defp loopback_address?({127, _b, _c, _d}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp loopback_address?({0, 0, 0, 0, 0, 0xFFFF, hi, _lo})
       when hi >= 0x7F00 and hi <= 0x7FFF,
       do: true

  defp loopback_address?(_other), do: false

  @doc """
  Validates origin header against allowed origins.

  ## Examples

      iex> Arbor.MCP.Security.Validation.validate_origin("https://example.com", ["https://example.com"])
      :ok

      iex> Arbor.MCP.Security.Validation.validate_origin("https://evil.com", ["https://example.com"])
      {:error, :origin_not_allowed}
  """
  @spec validate_origin(String.t() | nil, [String.t()] | :any) ::
          :ok | {:error, :origin_not_allowed}
  def validate_origin(_origin, :any), do: :ok
  def validate_origin(nil, _allowed), do: {:error, :origin_not_allowed}

  def validate_origin(origin, allowed_origins) when is_list(allowed_origins) do
    if origin in allowed_origins do
      :ok
    else
      {:error, :origin_not_allowed}
    end
  end

  @doc """
  Validates an HTTP request for security compliance.

  This function implements comprehensive security validation including:
  - Origin header validation (DNS rebinding protection)
  - Required security headers validation
  - HTTPS enforcement for non-localhost

  ## Examples

      headers = [{"origin", "https://example.com"}, {"host", "api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      :ok = Arbor.MCP.Security.Validation.validate_request(headers, config)
  """
  @spec validate_request([{String.t(), String.t()}], security_config()) ::
          :ok | {:error, atom()}
  def validate_request(headers, config \\ %{}) do
    with :ok <- validate_request_origin_header(headers, config),
         :ok <- validate_host_header(headers, config) do
      validate_https_requirement(headers, config)
    end
  end

  defp validate_request_origin_header(headers, %{validate_origin: true} = config) do
    case Headers.get(headers, "origin") do
      nil ->
        # Origin header is required when origin validation is enabled
        {:error, :origin_header_required}

      origin ->
        allowed = Map.get(config, :allowed_origins, [])
        validate_origin(origin, allowed)
    end
  end

  defp validate_request_origin_header(_headers, _config), do: :ok

  defp validate_host_header(headers, config) do
    case Headers.get(headers, "host") do
      nil ->
        {:error, :host_header_required}

      host ->
        validate_host_against_policy(host, config)
    end
  end

  defp validate_host_against_policy(host, config) do
    case parse_request_host(host) do
      {:ok, hostname} ->
        if loopback_hostname?(hostname) do
          :ok
        else
          allowed_hosts = Map.get(config, :allowed_hosts, [])

          if allowed_hosts == [] or hostname_allowed?(hostname, allowed_hosts) do
            :ok
          else
            {:error, :host_not_allowed}
          end
        end

      :error ->
        {:error, :host_not_allowed}
    end
  end

  # Host headers are `name`, `name:port`, `[ipv6]`, or `[ipv6]:port`. An http
  # or https URL is accepted so a request-target still compares its host.
  # Any other scheme is rejected: `evil.com://allowed.example` parses with
  # the allowed host while the raw value is not that host. Trailing garbage
  # after the port or bracketed address is rejected.
  defp parse_request_host(host) when is_binary(host) do
    if String.contains?(host, "://") do
      parse_url_host(host)
    else
      parse_host_header(host)
    end
  rescue
    _exception -> :error
  end

  defp parse_request_host(_host), do: :error

  defp parse_host_header(host) do
    uri = URI.parse("//" <> host)

    case uri.host do
      hostname when is_binary(hostname) and hostname != "" ->
        if is_nil(uri.userinfo) and valid_port?(uri.port) and
             host == format_authority(hostname, uri.port),
           do: {:ok, hostname},
           else: :error

      _missing ->
        :error
    end
  end

  defp parse_url_host(url) do
    uri = URI.parse(url)

    case uri.host do
      hostname when is_binary(hostname) and hostname != "" ->
        authority = url_authority(url)

        if uri.scheme in ["http", "https"] and is_nil(uri.userinfo) and valid_port?(uri.port) and
             is_binary(authority) and
             (authority == format_authority(hostname, uri.port) or
                authority == format_authority(hostname, nil)) do
          {:ok, hostname}
        else
          :error
        end

      _missing ->
        :error
    end
  end

  defp url_authority(url) do
    case String.split(url, "://", parts: 2) do
      [_scheme, rest] ->
        rest
        |> String.split(["/", "?", "#"], parts: 2)
        |> hd()

      _missing ->
        nil
    end
  end

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port), do: port in 1..65_535

  defp format_authority(host, port) do
    name = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host

    if is_integer(port), do: name <> ":" <> Integer.to_string(port), else: name
  end

  defp hostname_allowed?(hostname, allowed_hosts) do
    normalized = normalize_hostname(hostname)

    Enum.any?(allowed_hosts, fn allowed ->
      case parse_request_host(allowed) do
        {:ok, allowed_hostname} -> normalize_hostname(allowed_hostname) == normalized
        :error -> false
      end
    end)
  end

  defp loopback_hostname?(hostname) do
    normalized = normalize_hostname(hostname)

    normalized == "localhost" or loopback_ip?(normalized)
  end

  defp loopback_ip?(hostname) do
    case :inet.parse_address(String.to_charlist(hostname)) do
      {:ok, address} ->
        loopback_address?(address) and canonical_loopback_spelling?(hostname, address)

      {:error, _reason} ->
        false
    end
  end

  # inet accepts `127.1`, `0x7f.0.0.1`, `0177.0.0.1`, and `2130706433` as
  # 127.0.0.1. Only the canonical spelling may skip the allowlist.
  defp canonical_loopback_spelling?(hostname, address) do
    canonical = address |> :inet.ntoa() |> List.to_string() |> String.downcase()
    hostname == canonical
  end

  defp normalize_hostname(hostname) do
    hostname
    |> strip_ipv6_brackets()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp strip_ipv6_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_ipv6_brackets(hostname), do: hostname

  defp validate_https_requirement(headers, %{enforce_https: true}) do
    # Check if this is an HTTPS request
    case Headers.get(headers, "x-forwarded-proto") do
      "https" ->
        :ok

      nil ->
        # If no x-forwarded-proto, check if this is localhost
        case Headers.get(headers, "host") do
          host when host in ["localhost", "127.0.0.1", "[::1]"] -> :ok
          _ -> {:error, :https_required}
        end

      _ ->
        {:error, :https_required}
    end
  end

  defp validate_https_requirement(_headers, _config), do: :ok

  @doc """
  Validates TLS/SSL configuration.

  ## Examples

      config = %{
        verify: :verify_peer,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        ciphers: ["ECDHE-RSA-AES256-GCM-SHA384"]
      }

      :ok = Arbor.MCP.Security.Validation.validate_tls_config(config)
  """
  @spec validate_tls_config(map()) :: :ok | {:error, atom()}
  def validate_tls_config(config) when is_map(config) do
    with :ok <- validate_verify_mode(Map.get(config, :verify)),
         :ok <- validate_tls_versions(Map.get(config, :versions)),
         :ok <- validate_cipher_suites(Map.get(config, :ciphers)) do
      validate_certificates(config)
    end
  end

  def validate_tls_config(_), do: {:error, :invalid_tls_config}

  defp validate_verify_mode(nil), do: :ok
  defp validate_verify_mode(:verify_peer), do: :ok

  defp validate_verify_mode(:verify_none) do
    # Accepted (it is occasionally needed against a dev server with a
    # self-signed certificate) but never silently: with verify_none the
    # connection is encrypted yet unauthenticated, so an active
    # man-in-the-middle is undetectable.
    Logger.warning(
      "TLS configuration sets verify: :verify_none. Server certificates will not " <>
        "be validated and the connection is not protected against " <>
        "man-in-the-middle attacks. Use verify: :verify_peer outside local development."
    )

    :ok
  end

  defp validate_verify_mode(_), do: {:error, :invalid_verify_mode}

  defp validate_tls_versions(nil), do: :ok

  defp validate_tls_versions(versions) when is_list(versions) do
    insecure_versions = [:"tlsv1.0", :"tlsv1.1", :sslv3, :sslv2]

    if Enum.any?(versions, &(&1 in insecure_versions)) do
      {:error, :insecure_tls_versions}
    else
      :ok
    end
  end

  defp validate_tls_versions(_), do: {:error, :invalid_tls_versions}

  @doc """
  Validates cipher suite configuration.
  """
  @spec validate_cipher_suites(map() | nil) :: :ok | {:error, atom()}
  def validate_cipher_suites(nil), do: :ok
  def validate_cipher_suites(%{ciphers: ciphers}), do: validate_cipher_suites(ciphers)

  def validate_cipher_suites(ciphers) when is_list(ciphers) do
    weak_ciphers = [
      # 3DES
      "DES-CBC3-SHA",
      # RC4
      "RC4-SHA",
      # NULL encryption
      "NULL-SHA",
      # Anonymous DH
      "ADH-",
      # Anonymous ECDH
      "AECDH-",
      # MD5 hash
      "MD5"
    ]

    has_weak =
      Enum.any?(ciphers, fn cipher ->
        Enum.any?(weak_ciphers, &String.contains?(cipher, &1))
      end)

    if has_weak do
      {:error, :weak_cipher_suites}
    else
      :ok
    end
  end

  def validate_cipher_suites(_), do: {:error, :invalid_cipher_config}

  defp validate_certificates(config) do
    # Basic validation - could be enhanced
    case {Map.get(config, :cert), Map.get(config, :key)} do
      {nil, nil} -> :ok
      {cert, key} when is_binary(cert) and is_binary(key) -> :ok
      {cert, nil} when is_binary(cert) -> {:error, :cert_without_key}
      {nil, key} when is_binary(key) -> {:error, :key_without_cert}
      _ -> {:error, :invalid_certificate_config}
    end
  end

  @doc """
  Validates mutual TLS configuration.
  """
  @spec validate_mtls_config(map()) :: :ok | {:error, atom()}
  def validate_mtls_config(config) do
    required_fields = [:cert, :key, :cacerts]

    missing_fields = Enum.reject(required_fields, &Map.has_key?(config, &1))

    if missing_fields == [] do
      :ok
    else
      {:error, :incomplete_mtls_config}
    end
  end

  @doc """
  Validates certificate pinning configuration.
  """
  @spec validate_certificate_pinning_config(map()) :: :ok | {:error, atom()}
  def validate_certificate_pinning_config(%{certificate_pinning: pins}) when is_list(pins) do
    valid_pins =
      Enum.all?(pins, fn pin ->
        String.starts_with?(pin, "sha256:") and byte_size(pin) > 7
      end)

    if valid_pins do
      :ok
    else
      {:error, :invalid_certificate_pins}
    end
  end

  def validate_certificate_pinning_config(_), do: :ok

  @doc """
  Validates transport security configuration.
  """
  @spec validate_transport_security(map()) :: :ok | {:error, atom()}
  def validate_transport_security(config) do
    url = Map.get(config, :url, "")
    security = Map.get(config, :security, %{})

    with :ok <- validate_url_security(url, security) do
      validate_tls_config(Map.get(security, :tls, %{}))
    end
  end

  defp validate_url_security(url, %{enforce_https: true}) do
    enforce_https_requirement(url)
  end

  defp validate_url_security(_url, _security), do: :ok

  @doc """
  Validates security configuration.
  """
  @spec validate_config(security_config()) :: :ok | {:error, term()}
  def validate_config(config) do
    with :ok <- validate_auth(Map.get(config, :auth)),
         :ok <- validate_cors(Map.get(config, :cors)),
         :ok <- validate_tls(Map.get(config, :tls)),
         :ok <- validate_trusted_origins(Map.get(config, :trusted_origins)) do
      validate_security_requirements(config)
    end
  end

  defp validate_trusted_origins(nil), do: :ok

  defp validate_trusted_origins(origins) when is_list(origins) do
    if Enum.all?(origins, &TokenHandler.valid_trusted_origin?/1),
      do: :ok,
      else: {:error, :invalid_trusted_origins}
  end

  defp validate_trusted_origins(_origins), do: {:error, :invalid_trusted_origins}

  defp validate_auth(nil), do: :ok
  defp validate_auth({:bearer, token}) when is_binary(token), do: :ok
  defp validate_auth({:api_key, key, _opts}) when is_binary(key), do: :ok
  defp validate_auth({:basic, user, pass}) when is_binary(user) and is_binary(pass), do: :ok
  defp validate_auth({:custom, headers}) when is_list(headers), do: :ok
  defp validate_auth({:node_cookie, cookie}) when is_atom(cookie), do: :ok
  defp validate_auth({:oauth2, %{access_token: token}}) when is_binary(token), do: :ok
  defp validate_auth(_), do: {:error, :invalid_auth_config}

  defp validate_cors(nil), do: :ok
  defp validate_cors(%{} = _cors), do: :ok
  defp validate_cors(_), do: {:error, :invalid_cors_config}

  defp validate_tls(nil), do: :ok
  defp validate_tls(%{} = _tls), do: :ok
  defp validate_tls(_), do: {:error, :invalid_tls_config}

  # MCP Specification Security Requirements

  @doc """
  Validates that security configuration meets MCP specification requirements.
  """
  @spec validate_security_requirements(security_config()) ::
          :ok | {:error, term()}
  def validate_security_requirements(config) do
    with :ok <- validate_origin_requirements(config) do
      validate_localhost_binding(config)
    end
  end

  defp validate_origin_requirements(%{validate_origin: true, allowed_origins: origins})
       when is_list(origins) and origins != [] do
    if proper_list_of_strings?(origins), do: :ok, else: {:error, :invalid_allowed_origins}
  end

  defp validate_origin_requirements(%{validate_origin: true}) do
    {:error, :allowed_origins_required_when_origin_validation_enabled}
  end

  defp validate_origin_requirements(_), do: :ok

  defp proper_list_of_strings?([]), do: true

  defp proper_list_of_strings?([item | rest]) when is_binary(item) do
    proper_list_of_strings?(rest)
  end

  defp proper_list_of_strings?(_other), do: false

  @doc """
  Enforces HTTPS requirement for non-localhost URLs.
  """
  @spec enforce_https_requirement(String.t()) :: :ok | {:error, :https_required}
  def enforce_https_requirement(url) do
    uri = URI.parse(url)

    case {uri.scheme, uri.host} do
      {"http", "localhost"} -> :ok
      {"http", "127.0.0.1"} -> :ok
      # IPv6 localhost without brackets
      {"http", "::1"} -> :ok
      # IPv6 localhost with brackets
      {"http", "[::1]"} -> :ok
      {"http", _} -> {:error, :https_required}
      {"https", _} -> :ok
      # Other schemes like ws/wss handled elsewhere
      _ -> :ok
    end
  end
end
