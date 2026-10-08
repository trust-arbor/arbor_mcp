import Config

# Arbor.MCP Configuration
config :arbor_mcp,
  # Legacy protocol revision used by initialize-based compatibility helpers.
  # Options: "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
  # Default: "2025-11-25" (newest legacy revision). MCP 2026-07-28 is the
  # latest stable revision and is selected through :protocol_mode.
  protocol_version: "2025-11-25",
  # New connections try MCP 2026-07-28 first and fall back only after positive
  # legacy evidence. Use :legacy_only for the exact rc.5 connection policy.
  protocol_mode: :prefer_modern,
  # Feature flags for phased rollout of new MCP features.
  # These flags allow for enabling new functionality in a controlled manner.
  #
  # When `protocol_version_required` is true, legacy HTTP servers require the
  # `mcp-protocol-version` header on requests after initialization. The
  # initialize request negotiates its version in params.protocolVersion and
  # never requires the HTTP header. Explicit headers are always validated.
  protocol_version_required: false,
  # When `structured_output_enabled` is true, tools can return structured
  # content alongside the standard content blocks.
  structured_output_enabled: false,
  # When `oauth2_enabled` is true, the server will enforce OAuth 2.1
  # for authorization.
  oauth2_enabled: false

# OAuth 2.1 Server (Resource Server) Configuration
# This configuration is used when the server needs to validate OAuth 2.1 tokens.
# There is intentionally no default: the values below are illustrative
# placeholders, not endpoints anyone should point at. Configure the real
# authorization server in YOUR application's config. The key actually read at
# runtime is `Arbor.MCP.Authorization.ServerConfig`:
#
#     config :arbor_mcp, Arbor.MCP.Authorization.ServerConfig,
#       default_server: :auth_server,
#       servers: %{
#         auth_server: %{
#           # (Required) URL of the token introspection endpoint (RFC 7662).
#           # Must be HTTPS unless it is localhost.
#           introspection_endpoint: "https://auth.example.com/introspect",
#           # (Optional) OAuth realm name for WWW-Authenticate headers.
#           realm: "mcp-service",
#           client_id: "mcp-server-id",
#           # Load secrets from the environment in config/runtime.exs, never
#           # from a checked-in config file.
#           client_secret: "server-secret"
#         }
#       }

# OAuth 2.1 Authorization Server Metadata (RFC 8414)
# Defines the metadata returned by /.well-known/oauth-authorization-server.
# Also intentionally left unset; example:
#
#     config :arbor_mcp, :oauth2_authorization_server_metadata,
#       # (Required) The authorization server issuer identifier.
#       issuer: "https://auth.example.com",
#       # (Required) URL of the authorization endpoint.
#       authorization_endpoint: "https://auth.example.com/authorize",
#       # (Required) URL of the token endpoint.
#       token_endpoint: "https://auth.example.com/token",
#       # (Optional) URL of the JWK Set document.
#       jwks_uri: "https://auth.example.com/.well-known/jwks.json",
#       # (Optional) Supported scopes / response types / grant types / PKCE methods.
#       scopes_supported: ["mcp:read", "mcp:write"],
#       response_types_supported: ["code"],
#       grant_types_supported: ["authorization_code", "client_credentials", "refresh_token"],
#       code_challenge_methods_supported: ["S256"],
#       # (Optional) Introspection / revocation endpoints.
#       introspection_endpoint: "https://auth.example.com/introspect",
#       revocation_endpoint: "https://auth.example.com/revoke"

# Security Configuration
#
# These are Arbor.MCP's own defaults, restated here for visibility. A library's
# config is not loaded by dependent applications: to change any of this, copy
# the setting into YOUR application's config.
#
# The defaults are fail-closed. `Arbor.MCP.Transport.SecurityGuard` classifies
# every outbound URL against exact :trusted_origins and explicit broad
# :trusted_hosts; anything else has its
# credential headers stripped and must be approved by :consent_handler, which
# denies by default. A client pointed at a non-localhost MCP server therefore
# needs that server's origin declared:
#
#     config :arbor_mcp, :security,
#       trusted_origins: ["https://mcp.example.com"]
#
# A trusted origin is exempt from both stripping and consent. See
# docs/SECURITY.md.
config :arbor_mcp, :security,
  # Exact origins treated as the same security domain. Scheme and effective
  # port are part of the match. Add the MCP servers this application connects to.
  trusted_origins: [],
  # Explicitly broad compatibility policy across schemes and ports. Wildcards
  # such as "*.example.com" match subdomains but not the apex. Prefer exact
  # origins for remote services.
  trusted_hosts: ["localhost", "127.0.0.1", "::1"],
  additional_sensitive_headers: [],

  # Consent management. Asked to approve access to origins that are NOT
  # trusted. Arbor.MCP.ConsentHandler.CLI prompts interactively;
  # Arbor.MCP.ConsentHandler.Web defers to an out-of-band web flow.
  consent_handler: Arbor.MCP.ConsentHandler.Deny,
  # Milliseconds. Handlers receive this as :consent_ttl in seconds.
  consent_ttl: :timer.hours(24),
  consent_cache_cleanup_interval: :timer.minutes(5),

  # Security logging
  log_security_actions: true,
  audit_log_level: :info,

  # Enforcement switches, read by Arbor.MCP.Transport.SecurityGuard. Setting either
  # to false disables that control for every transport; prefer declaring
  # :trusted_origins instead.
  enable_token_passthrough_prevention: true,
  enable_user_consent_validation: true

# Logger Configuration
# Configure metadata fields to avoid warnings
# Note: :file and :line are performance-intensive and should only be used in dev/test
config :logger, :console,
  metadata: [
    :request_id,
    :request_id_hash,
    :progress_id,
    :session_id_hash,
    :event_id_hash,
    :endpoint_hash,
    :issuer_hash,
    :resource_hash,
    :registration_endpoint_hash,
    :duration_ms,
    :status,
    :server_hash,
    :metadata_keys,
    :uptime_seconds,
    :batch_id_hash,
    :method_hash,
    :reason_shape,
    :error_shape,
    :message_shape,
    :line_shape,
    :reply_shape,
    :detail_shape,
    :error_class,
    :handler,
    :handler_kind,
    :return_shape,
    :size,
    :limit,
    :tag,
    :audit,
    :client_id,
    :reason,
    :registration_type,
    :service_id,
    :event_type,
    :data_size,
    :use_sse,
    :storage_backend,
    :storage_path,
    :max_sessions,
    :max_request_ids,
    :session_ttl_seconds,
    :max_events_per_session,
    :max_event_bytes,
    :max_replay_bytes_per_session,
    :cleanup_interval_ms,
    :method,
    :module,
    :function,
    :error,
    :transport
  ]

# Environment-specific configuration
if Mix.env() in [:dev, :test] do
  # Note: This configuration overwrites the default metadata for dev/test environments,
  # adding :file and :line for detailed logging (performance-intensive operations).
  config :logger, :console,
    metadata: [
      :request_id,
      :request_id_hash,
      :progress_id,
      :session_id_hash,
      :event_id_hash,
      :endpoint_hash,
      :issuer_hash,
      :resource_hash,
      :registration_endpoint_hash,
      :duration_ms,
      :status,
      :server_hash,
      :metadata_keys,
      :uptime_seconds,
      :batch_id_hash,
      :method_hash,
      :reason_shape,
      :error_shape,
      :message_shape,
      :line_shape,
      :reply_shape,
      :detail_shape,
      :error_class,
      :handler,
      :handler_kind,
      :return_shape,
      :size,
      :limit,
      :tag,
      :audit,
      :client_id,
      :reason,
      :registration_type,
      :service_id,
      :event_type,
      :data_size,
      :use_sse,
      :storage_backend,
      :storage_path,
      :max_sessions,
      :max_request_ids,
      :session_ttl_seconds,
      :max_events_per_session,
      :max_event_bytes,
      :max_replay_bytes_per_session,
      :cleanup_interval_ms,
      :method,
      :module,
      :function,
      :error,
      :transport,
      :file,
      :line
    ]
end

if Mix.env() == :dev do
  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      pre_commit: [
        tasks: [
          {:cmd, "mix format --check-formatted"},
          {:cmd, "mix compile --warnings-as-errors"},
          {:cmd, "mix credo"},
          {:cmd, "mix dialyzer"},
          {:cmd, "./scripts/check_skip_tags.sh staged"}
          # To enable unit tests in pre-commit, uncomment the following line:
          # {:cmd, "mix test --exclude oauth_integration --exclude streaming --max-cases 4 --seed 0"}
        ]
      ],
      pre_push: [
        tasks: []
      ]
    ]
end
