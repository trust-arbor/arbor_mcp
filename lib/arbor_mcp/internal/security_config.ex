defmodule Arbor.MCP.Internal.SecurityConfig do
  @moduledoc """
  Centralized security configuration management with validation.

  This module provides secure defaults and configuration validation
  for the ArborMCP security system.

  ## Defaults are fail-closed

  `:trusted_origins` defaults to empty, `:trusted_hosts` contains loopback
  compatibility entries, and `:consent_handler` defaults to
  `Arbor.MCP.ConsentHandler.Deny`. `Arbor.MCP.Transport.SecurityGuard` runs on every
  outbound request, so a client pointed at a non-loopback server has its
  credential headers stripped and is then denied until the application
  declares that exact origin:

      config :arbor_mcp, :security,
        trusted_origins: ["https://mcp.example.com"]

  A trusted origin is exempt from both header stripping and consent prompts;
  consent then only gates origins the application never declared. The
  SecurityGuard logs this remediation whenever it strips or blocks, so the
  failure is not silent.

  ## Settings

    * `:trusted_origins` - exact HTTP(S) origins. Scheme, normalized host, and
      effective port must all match.
    * `:trusted_hosts` - deliberately broad host-only trust across schemes and
      ports. `"*.example.com"` matches subdomains but not the apex. This exists
      for loopback compatibility; prefer exact origins for remote services.
    * `:consent_handler` - module implementing `Arbor.MCP.ConsentHandler`, asked to
      approve access to origins that are *not* trusted.
    * `:consent_ttl` - lifetime of a cached consent decision, **in
      milliseconds** (handlers receive it in seconds as `:consent_ttl` in the
      request context).
    * `:enable_token_passthrough_prevention` - when `false`, credential headers
      are forwarded to untrusted origins. Off by default only in the sense that
      the protection is on; disabling it removes confused-deputy protection.
    * `:enable_user_consent_validation` - when `false`, the consent handler is
      never consulted and every origin is allowed.

  Prefer declaring `:trusted_origins` over disabling either control.
  """

  require Logger

  alias Arbor.MCP.Security.TokenHandler

  @default_config %{
    # Token passthrough prevention
    trusted_origins: [],
    trusted_hosts: ["localhost", "127.0.0.1", "::1"],
    additional_sensitive_headers: [],

    # Consent management
    consent_handler: Arbor.MCP.ConsentHandler.Deny,
    consent_ttl: :timer.hours(24),
    consent_cache_cleanup_interval: :timer.minutes(5),

    # User identification resolvers for different transports
    user_id_resolvers: %{
      http: &__MODULE__.default_http_user_resolver/1,
      stdio: &__MODULE__.default_stdio_user_resolver/1,
      beam: &__MODULE__.default_beam_user_resolver/1
    },

    # Security logging
    log_security_actions: true,
    audit_log_level: :info,

    # Enforcement switches. Both are read by Arbor.MCP.Transport.SecurityGuard;
    # setting either to false disables that control for every transport.
    enable_token_passthrough_prevention: true,
    enable_user_consent_validation: true
  }

  @doc """
  Gets the current security configuration.

  Merges application configuration with secure defaults and validates the result.
  """
  @spec get_security_config() :: map()
  def get_security_config do
    app_config = Application.get_env(:arbor_mcp, :security, %{})
    # Convert keyword list to map if needed
    app_config_map = if is_list(app_config), do: Enum.into(app_config, %{}), else: app_config
    config = Map.merge(@default_config, app_config_map)

    case validate_config(config) do
      {:ok, validated_config} ->
        validated_config

      {:error, reason} ->
        Logger.error("Invalid security configuration: #{reason}")
        Logger.error("Falling back to secure defaults")
        @default_config
    end
  end

  @doc """
  Validates security configuration.

  Ensures all required fields are present and have valid values.
  """
  @spec validate_config(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_config(config) do
    with :ok <- validate_trusted_origins(config.trusted_origins),
         :ok <- validate_trusted_hosts(Map.get(config, :trusted_hosts, [])),
         :ok <- validate_consent_handler(config.consent_handler),
         :ok <- validate_ttl_values(config),
         :ok <- validate_enforcement_switches(config),
         :ok <- validate_user_resolvers(config.user_id_resolvers) do
      {:ok, config}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets security configuration for a specific transport.

  Includes transport-specific settings and user ID resolution.

  `base_config` is merged over the application configuration. A transport that
  knows the origin it was explicitly configured to talk to can declare it here,
  which exempts that origin from header stripping and consent:

      SecurityConfig.get_transport_config(:http, %{trusted_origins: [origin | configured]})
  """
  @spec get_transport_config(atom(), map()) :: map()
  def get_transport_config(transport, base_config \\ %{}) do
    security_config = get_security_config()
    transport_config = Map.merge(security_config, base_config)

    # Add transport-specific user ID resolver
    user_resolver = get_in(transport_config, [:user_id_resolvers, transport])
    Map.put(transport_config, :user_id_resolver, user_resolver)
  end

  # Default user ID resolvers for different transports

  @doc """
  Default user ID resolver for HTTP transport.

  Extracts user ID from request context, headers, or session.
  """
  def default_http_user_resolver(request_context) do
    Map.get(request_context, :user_id, "anonymous")
  end

  @doc """
  Default user ID resolver for stdio transport.

  Uses system user or process-based identification.
  """
  def default_stdio_user_resolver(_request_context) do
    System.get_env("USER") || "stdio_user"
  end

  @doc """
  Default user ID resolver for BEAM transport.

  Uses node-based identification for distributed systems.
  """
  def default_beam_user_resolver(_request_context) do
    "#{node()}_beam_user"
  end

  # Private validation functions

  defp validate_trusted_origins(origins) when is_list(origins) do
    if Enum.all?(origins, &TokenHandler.valid_trusted_origin?/1) do
      :ok
    else
      {:error, "trusted_origins must contain exact HTTP(S) origins"}
    end
  end

  defp validate_trusted_origins(_), do: {:error, "trusted_origins must be a list"}

  defp validate_trusted_hosts(hosts) when is_list(hosts) do
    if Enum.all?(hosts, &TokenHandler.valid_trusted_host?/1),
      do: :ok,
      else: {:error, "trusted_hosts must contain host names or explicit *.example.com patterns"}
  end

  defp validate_trusted_hosts(_hosts), do: {:error, "trusted_hosts must be a list"}

  defp validate_consent_handler(handler) when is_atom(handler) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :request_consent, 3) do
      :ok
    else
      {:error, "consent_handler must implement Arbor.MCP.ConsentHandler behavior"}
    end
  end

  defp validate_consent_handler(_), do: {:error, "consent_handler must be a module"}

  defp validate_ttl_values(config) do
    if is_integer(config.consent_ttl) and config.consent_ttl > 0 do
      :ok
    else
      {:error, "consent_ttl must be a positive integer (milliseconds)"}
    end
  end

  defp validate_enforcement_switches(config) do
    switches = [:enable_token_passthrough_prevention, :enable_user_consent_validation]

    invalid = Enum.reject(switches, fn key -> is_boolean(Map.get(config, key, true)) end)

    if invalid == [] do
      :ok
    else
      {:error, "#{Enum.join(invalid, ", ")} must be true or false"}
    end
  end

  defp validate_user_resolvers(resolvers) when is_map(resolvers) do
    required_transports = [:http, :stdio, :beam]

    if Enum.all?(required_transports, &Map.has_key?(resolvers, &1)) do
      :ok
    else
      {:error, "user_id_resolvers must include resolvers for http, stdio, and beam transports"}
    end
  end

  defp validate_user_resolvers(_), do: {:error, "user_id_resolvers must be a map"}
end
