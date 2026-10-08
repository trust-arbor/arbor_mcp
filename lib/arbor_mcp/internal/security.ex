defmodule Arbor.MCP.Internal.Security do
  @moduledoc false

  alias Arbor.MCP.Security.Consent
  alias Arbor.MCP.Security.CORS
  alias Arbor.MCP.Security.TokenHandler
  alias Arbor.MCP.Security.Validation

  # Provides authentication and security headers across all MCP transports.
  #
  # ## Security Configuration
  #
  # Security can be configured at the transport level:
  #
  #     # Bearer token authentication
  #     {:ok, client} = Arbor.MCP.Client.start_link(
  #       transport: :http,
  #       url: "https://api.example.com",
  #       security: %{
  #         auth: {:bearer, "your-token-here"},
  #         validate_origin: true,
  #         allowed_origins: ["https://trusted.example.com"]
  #       }
  #     )
  #
  #     # API key authentication
  #     {:ok, client} = Arbor.MCP.Client.start_link(
  #       transport: :http,
  #       url: "https://api.example.com",
  #       security: %{
  #         auth: {:api_key, "your-api-key", header: "X-API-Key"}
  #       }
  #     )
  #
  #     # OAuth 2.1 authentication
  #     {:ok, token_response} = Arbor.MCP.Authorization.client_credentials_flow(%{
  #       client_id: "my-client",
  #       client_secret: "my-secret",
  #       token_endpoint: "https://auth.example.com/token"
  #     })
  #
  #     {:ok, client} = Arbor.MCP.Client.start_link(
  #       transport: :http,
  #       url: "https://api.example.com",
  #       security: %{
  #         auth: {:oauth2, token_response}
  #       }
  #     )
  #
  #     # Custom headers
  #     {:ok, client} = Arbor.MCP.Client.start_link(
  #       transport: :http,
  #       url: "https://api.example.com",
  #       security: %{
  #         headers: [
  #           {"X-Custom-Header", "value"},
  #           {"X-Request-ID", "uuid"}
  #         ]
  #       }
  #     )
  #
  # ## Security Features by Transport
  #
  # | Feature | HTTP | BEAM | stdio |
  # |---------|------|------|-------|
  # | Bearer Auth | ✓ | ✓ | - |
  # | OAuth 2.1 | ✓ | ✓ | - |
  # | API Key | ✓ | ✓ | ✓ | - |
  # | Custom Headers | ✓ | ✓ | - | - |
  # | Origin Validation | ✓ | ✓ | - | - |
  # | CORS Headers | ✓ | - | - | - |
  # | TLS/SSL | ✓ | ✓ | ✓* | - |
  # | Mutual TLS | ✓ | ✓ | - | - |
  #
  # *BEAM transport uses Erlang distribution security

  @type auth_method ::
          {:bearer, token :: String.t()}
          | {:api_key, key :: String.t(), opts :: keyword()}
          | {:basic, username :: String.t(), password :: String.t()}
          | {:custom, headers :: [{String.t(), String.t()}]}
          | {:oauth2, Arbor.MCP.Authorization.token_response()}

  @type security_config :: %{
          optional(:auth) => auth_method(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:validate_origin) => boolean(),
          optional(:allowed_origins) => [String.t()],
          optional(:cors) => cors_config(),
          optional(:tls) => tls_config()
        }

  @type cors_config :: %{
          optional(:allowed_origins) => [String.t()] | :any,
          optional(:allowed_methods) => [String.t()],
          optional(:allowed_headers) => [String.t()],
          optional(:expose_headers) => [String.t()],
          optional(:max_age) => integer(),
          optional(:allow_credentials) => boolean()
        }

  @type tls_config :: %{
          optional(:verify) => :verify_peer | :verify_none,
          optional(:cacerts) => [binary()],
          optional(:cert) => binary(),
          optional(:key) => binary(),
          optional(:versions) => [atom()],
          optional(:ciphers) => [String.t()]
        }

  @doc """
  Builds authentication headers from security configuration.

  ## Examples

      iex> Arbor.MCP.Internal.Security.build_auth_headers(%{auth: {:bearer, "token123"}})
      [{"Authorization", "Bearer token123"}]

      iex> Arbor.MCP.Internal.Security.build_auth_headers(%{auth: {:api_key, "key123", header: "X-API-Key"}})
      [{"X-API-Key", "key123"}]
  """
  @spec build_auth_headers(security_config()) :: [{String.t(), String.t()}]
  def build_auth_headers(%{auth: auth_method} = _config) do
    case auth_method do
      {:bearer, token} ->
        [{"Authorization", "Bearer #{token}"}]

      {:api_key, key, opts} ->
        header_name = Keyword.get(opts, :header, "X-API-Key")
        [{header_name, key}]

      {:basic, username, password} ->
        credentials = Base.encode64("#{username}:#{password}")
        [{"Authorization", "Basic #{credentials}"}]

      {:custom, headers} ->
        headers

      {:oauth2, %{access_token: token, token_type: token_type}} ->
        [{"Authorization", "#{token_type} #{token}"}]

      _ ->
        []
    end
  end

  def build_auth_headers(_config), do: []

  @doc """
  Builds all security headers including auth and custom headers.
  """
  @spec build_security_headers(security_config()) :: [{String.t(), String.t()}]
  def build_security_headers(config) do
    auth_headers = build_auth_headers(config)
    custom_headers = Map.get(config, :headers, [])

    Enum.uniq_by(auth_headers ++ custom_headers, fn {name, _} -> name end)
  end

  @doc """
  Validates that a server binding is localhost-only for security.

  ## Examples

      iex> Arbor.MCP.Internal.Security.validate_localhost_binding(%{binding: "127.0.0.1"})
      :ok

      iex> Arbor.MCP.Internal.Security.validate_localhost_binding(%{binding: "localhost"})
      :ok

      iex> Arbor.MCP.Internal.Security.validate_localhost_binding(%{binding: "0.0.0.0"})
      {:error, :public_binding_requires_security}
  """
  @spec validate_localhost_binding(map()) :: :ok | {:error, :public_binding_requires_security}
  def validate_localhost_binding(config), do: Validation.validate_localhost_binding(config)

  @doc """
  Validates origin header against allowed origins.

  ## Examples

      iex> Arbor.MCP.Internal.Security.validate_origin("https://example.com", ["https://example.com"])
      :ok

      iex> Arbor.MCP.Internal.Security.validate_origin("https://evil.com", ["https://example.com"])
      {:error, :origin_not_allowed}
  """
  @spec validate_origin(String.t() | nil, [String.t()] | :any) ::
          :ok | {:error, :origin_not_allowed}
  def validate_origin(origin, allowed_origins),
    do: CORS.validate_origin(origin, allowed_origins)

  @doc """
  Builds CORS headers based on configuration.
  """
  @spec build_cors_headers(cors_config(), String.t() | nil) :: [{String.t(), String.t()}]
  def build_cors_headers(cors_config, origin \\ nil),
    do: CORS.build_cors_headers(cors_config, origin)

  @doc """
  Builds standard security headers for HTTP-based transports.
  """
  @spec build_standard_security_headers() :: [{String.t(), String.t()}]
  def build_standard_security_headers do
    [
      {"X-Content-Type-Options", "nosniff"},
      {"X-Frame-Options", "DENY"},
      {"X-XSS-Protection", "1; mode=block"},
      {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
      {"Referrer-Policy", "strict-origin-when-cross-origin"},
      {"X-Permitted-Cross-Domain-Policies", "none"}
    ]
  end

  #
  # Token Passthrough and Consent
  #

  @doc """
  Checks for and prevents token passthrough to external resources.

  It classifies the URL, and if it's external, it strips sensitive headers.
  This is a key part of preventing confused deputy attacks.
  """
  @spec check_token_passthrough(String.t(), list({String.t(), String.t()}), map()) ::
          {:ok, list({String.t(), String.t()})}
  defdelegate check_token_passthrough(url, headers, config), to: TokenHandler

  @doc """
  Classifies a URL as `:internal` or `:external` based on trusted origins.

  Exact origins match scheme, host, and effective port. Pass a security config
  map to also apply the explicitly broad `:trusted_hosts` policy.
  """
  @spec classify_url(String.t(), [String.t()] | map()) :: :internal | :external
  defdelegate classify_url(url, trusted_origins), to: TokenHandler

  @doc """
  Strips sensitive headers if the resource classification is `:external`.
  """
  @spec strip_sensitive_headers(list({String.t(), String.t()}), :internal | :external) ::
          list({String.t(), String.t()})
  defdelegate strip_sensitive_headers(headers, classification), to: TokenHandler

  @doc """
  Ensures user consent is obtained before accessing an external resource.
  """
  @spec ensure_user_consent(
          Arbor.MCP.ConsentHandler.user_id(),
          String.t(),
          atom(),
          module(),
          map()
        ) :: :ok | {:error, :consent_denied | :consent_required | :consent_error}
  defdelegate ensure_user_consent(user_id, url, transport, handler, config), to: Consent

  @doc """
  Extracts the origin (scheme://host:port) from a URL string.
  """
  @spec extract_origin(String.t()) :: {:ok, String.t()} | {:error, :invalid_uri}
  defdelegate extract_origin(url), to: TokenHandler

  @doc """
  Validates an HTTP request for security compliance.

  This function implements comprehensive security validation including:
  - Origin header validation (DNS rebinding protection)
  - Required security headers validation
  - HTTPS enforcement for non-localhost

  ## Examples

      headers = [{"origin", "https://example.com"}, {"host", "api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      :ok = Arbor.MCP.Internal.Security.validate_request(headers, config)
  """
  @spec validate_request([{String.t(), String.t()}], security_config()) ::
          :ok | {:error, atom()}
  def validate_request(headers, config \\ %{}), do: Validation.validate_request(headers, config)

  @doc """
  Validates TLS/SSL configuration.

  ## Examples

      config = %{
        verify: :verify_peer,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        ciphers: ["ECDHE-RSA-AES256-GCM-SHA384"]
      }

      :ok = Arbor.MCP.Internal.Security.validate_tls_config(config)
  """
  @spec validate_tls_config(map()) :: :ok | {:error, atom()}
  def validate_tls_config(config), do: Validation.validate_tls_config(config)

  @doc """
  Validates cipher suite configuration.
  """
  @spec validate_cipher_suites(map() | nil) :: :ok | {:error, atom()}
  def validate_cipher_suites(ciphers), do: Validation.validate_cipher_suites(ciphers)

  @doc """
  Validates mutual TLS configuration.
  """
  @spec validate_mtls_config(map()) :: :ok | {:error, atom()}
  def validate_mtls_config(config), do: Validation.validate_mtls_config(config)

  @doc """
  Validates certificate pinning configuration.
  """
  @spec validate_certificate_pinning_config(map()) :: :ok | {:error, atom()}
  def validate_certificate_pinning_config(config),
    do: Validation.validate_certificate_pinning_config(config)

  @doc """
  Returns the preferred TLS version from a list.
  """
  @spec preferred_tls_version([atom()]) :: atom()
  def preferred_tls_version(versions) do
    cond do
      :"tlsv1.3" in versions -> :"tlsv1.3"
      :"tlsv1.2" in versions -> :"tlsv1.2"
      true -> hd(versions)
    end
  end

  @doc """
  Returns recommended cipher suites in order of preference.
  """
  @spec recommended_cipher_suites() :: [String.t()]
  def recommended_cipher_suites do
    [
      # TLS 1.3 cipher suites (AEAD only)
      "TLS_AES_256_GCM_SHA384",
      "TLS_AES_128_GCM_SHA256",
      "TLS_CHACHA20_POLY1305_SHA256",

      # TLS 1.2 ECDHE cipher suites (forward secrecy)
      "ECDHE-RSA-AES256-GCM-SHA384",
      "ECDHE-RSA-AES128-GCM-SHA256",
      "ECDHE-RSA-CHACHA20-POLY1305",
      "ECDHE-RSA-AES256-SHA384",
      "ECDHE-RSA-AES128-SHA256"
    ]
  end

  @doc """
  Builds mutual TLS options.
  """
  @spec build_mtls_options(map()) :: keyword()
  def build_mtls_options(config) do
    base_opts = [
      verify: Map.get(config, :verify, :verify_peer),
      cert: Map.get(config, :cert),
      key: Map.get(config, :key),
      cacerts: Map.get(config, :cacerts),
      versions: Map.get(config, :versions, [:"tlsv1.2", :"tlsv1.3"])
    ]

    # Add fail_if_no_peer_cert for server-side mTLS
    if Map.get(config, :fail_if_no_peer_cert) do
      Keyword.put(base_opts, :fail_if_no_peer_cert, true)
    else
      base_opts
    end
  end

  # `verify_hostname/3` was removed: it unconditionally returned `:valid_peer`,
  # so wiring it in as an `:ssl` `verify_fun` silently disabled hostname
  # verification. Hostname checking is handled by `:ssl` itself through the
  # `:customize_hostname_check` option set in
  # `Arbor.MCP.Transport.HTTP.build_ssl_options/1`.

  @doc """
  Validates transport security configuration.
  """
  @spec validate_transport_security(map()) :: :ok | {:error, atom()}
  def validate_transport_security(config), do: Validation.validate_transport_security(config)

  @doc """
  Validates security configuration.
  """
  @spec validate_config(security_config()) :: :ok | {:error, term()}
  def validate_config(config), do: Validation.validate_config(config)

  @doc """
  Applies security configuration to transport options.

  This function merges security-specific options into transport configuration.
  TLS options are built by the canonical builder,
  `Arbor.MCP.Transport.HTTP.build_ssl_options/1`, so that every caller gets the
  same defaults (peer verification, OS trust store, TLS 1.2/1.3 and HTTPS
  hostname matching).
  """
  @spec apply_security(keyword(), security_config()) :: keyword()
  def apply_security(transport_opts, security_config) do
    headers = build_security_headers(security_config)

    transport_opts
    |> Keyword.update(:headers, headers, &(&1 ++ headers))
    |> maybe_add_tls_options(Map.get(security_config, :tls))
  end

  defp maybe_add_tls_options(opts, nil), do: opts

  defp maybe_add_tls_options(opts, tls_config) do
    Keyword.put(opts, :ssl_options, Arbor.MCP.Transport.HTTP.build_ssl_options(tls_config))
  end

  # MCP Specification Security Requirements

  @doc """
  Validates that security configuration meets MCP specification requirements.
  """
  @spec validate_security_requirements(security_config()) :: :ok | {:error, term()}
  def validate_security_requirements(config),
    do: Validation.validate_security_requirements(config)

  @doc """
  Enforces HTTPS requirement for non-localhost URLs.
  """
  @spec enforce_https_requirement(String.t()) :: :ok | {:error, :https_required}
  def enforce_https_requirement(url), do: Validation.enforce_https_requirement(url)

  @doc """
  Validates request origin against security policy.

  This implements DNS rebinding attack protection as required by the MCP spec.
  """
  @spec validate_request_origin(String.t() | nil, security_config()) ::
          :ok | {:error, :origin_validation_failed}
  def validate_request_origin(origin, config), do: CORS.validate_request_origin(origin, config)

  @doc """
  Builds secure default configuration based on deployment context.
  """
  @spec secure_defaults(String.t()) :: security_config()
  def secure_defaults(url) do
    uri = URI.parse(url)

    base_config = %{
      validate_origin: true,
      tls: %{
        verify: :verify_peer,
        versions: [:"tlsv1.2", :"tlsv1.3"]
      }
    }

    # Add localhost-specific relaxations
    if uri.host in ["localhost", "127.0.0.1", "[::1]"] do
      Map.put(base_config, :allowed_origins, ["http://localhost", "https://localhost"])
    else
      base_config
    end
  end
end
