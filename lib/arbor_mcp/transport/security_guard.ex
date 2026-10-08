defmodule Arbor.MCP.Transport.SecurityGuard do
  @moduledoc """
  Transport-layer security interceptor that enforces MCP security policies.

  This module provides consistent security enforcement across all transports
  by intercepting outbound requests and applying token passthrough prevention
  and user consent validation.

  ## The trust boundary

  Every outbound URL is classified as `:internal` or `:external` by comparing
  its exact `(scheme, host, effective port)` origin against `:trusted_origins`.
  Deliberately broad host-only matching lives in `:trusted_hosts`. External requests

    1. have their credential headers removed (token passthrough prevention), and
    2. must be approved by the configured `:consent_handler`.

  `:trusted_origins` defaults to empty, `:trusted_hosts` defaults to loopback,
  and `:consent_handler` defaults to `Arbor.MCP.ConsentHandler.Deny`, so **a remote
  MCP server is blocked until its exact origin is added to `:trusted_origins`**:

      config :arbor_mcp, :security,
        trusted_origins: ["https://mcp.example.com"]

  That single setting covers both checks — a trusted origin is never stripped
  and never prompts for consent. Consent then applies only to origins the
  application did not declare. See `docs/SECURITY.md`.

  Both checks can be switched off individually with
  `:enable_token_passthrough_prevention` and `:enable_user_consent_validation`;
  prefer declaring `:trusted_origins` over disabling a control.
  """

  alias Arbor.MCP.Internal.Security
  alias Arbor.MCP.Transport.SecurityError
  alias Arbor.RPC.LogSummary

  require Logger

  @type request :: %{
          url: String.t(),
          headers: list({String.t(), String.t()}),
          method: String.t(),
          transport: atom(),
          user_id: String.t()
        }

  @type security_result ::
          {:ok, sanitized_request :: map()}
          | {:error, security_violation :: map()}

  @doc """
  Validates a request against security policies.

  This function enforces both token passthrough prevention and user consent
  validation for external resource access.

  ## Parameters

  - `request` - Standardized request structure
  - `config` - Security configuration (optional, uses defaults if not provided)

  ## Returns

  - `{:ok, sanitized_request}` - Request is allowed with potentially sanitized headers
  - `{:error, security_violation}` - Request blocked by security policy

  ## Examples

      request = %{
        url: "https://api.example.com/data",
        headers: [{"Authorization", "Bearer token"}],
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      case SecurityGuard.validate_request(request, config) do
        {:ok, sanitized_request} ->
          # Proceed with sanitized request
          perform_request(sanitized_request)

        {:error, violation} ->
          # Handle security violation
          {:error, violation}
      end
  """
  @spec validate_request(request(), map()) :: security_result()
  def validate_request(request, config \\ %{}) do
    Logger.debug("SecurityGuard validating request", transport: request.transport)

    with {:ok, headers_after_token_check} <- check_token_passthrough(request, config),
         {:ok, :consent_granted} <- check_user_consent(request, config) do
      sanitized_request = %{request | headers: headers_after_token_check}
      Logger.debug("SecurityGuard: Request approved", transport: request.transport)
      {:ok, sanitized_request}
    else
      {:error, :consent_required} ->
        error =
          SecurityError.new(
            :consent_required,
            "User consent required for external resource access",
            %{url: request.url, user_id: request.user_id, transport: request.transport}
          )

        Logger.info("SecurityGuard: Consent required. " <> remediation_hint())

        {:error, error}

      {:error, :consent_denied} ->
        error =
          SecurityError.new(
            :consent_denied,
            "User denied consent for external resource access",
            %{url: request.url, user_id: request.user_id, transport: request.transport}
          )

        Logger.warning("SecurityGuard: Consent denied. " <> remediation_hint())

        {:error, error}

      {:error, :consent_error} ->
        error =
          SecurityError.new(
            :consent_error,
            "Error processing user consent for external resource access",
            %{url: request.url, user_id: request.user_id, transport: request.transport}
          )

        Logger.error("SecurityGuard: Consent processing error")

        {:error, error}
    end
  end

  @doc """
  Gets the security configuration, merging provided config with defaults.
  """
  @spec get_security_config(map()) :: map()
  def get_security_config(config \\ %{}) do
    default_config = %{
      trusted_origins: [],
      trusted_hosts: ["localhost", "127.0.0.1", "::1"],
      consent_handler: Arbor.MCP.ConsentHandler.Deny,
      log_security_actions: true,
      enable_token_passthrough_prevention: true,
      enable_user_consent_validation: true
    }

    Map.merge(default_config, config)
  end

  # Private helper functions

  defp check_token_passthrough(request, config) do
    security_config = get_security_config(config)

    if Map.get(security_config, :enable_token_passthrough_prevention, true) do
      {:ok, headers} =
        Security.check_token_passthrough(request.url, request.headers, security_config)

      warn_if_credentials_stripped(request, headers)
      {:ok, headers}
    else
      {:ok, request.headers}
    end
  end

  defp check_user_consent(request, config) do
    security_config = get_security_config(config)

    if Map.get(security_config, :enable_user_consent_validation, true) do
      do_check_user_consent(request, security_config)
    else
      {:ok, :consent_granted}
    end
  end

  defp do_check_user_consent(request, security_config) do
    consent_handler = Map.get(security_config, :consent_handler, Arbor.MCP.ConsentHandler.Deny)

    result =
      Security.ensure_user_consent(
        request.user_id,
        request.url,
        request.transport,
        consent_handler,
        security_config
      )

    case result do
      :ok ->
        # `ensure_user_consent` returns `:ok` for internal URLs where consent is not needed.
        # We map this to `{:ok, :consent_granted}` to satisfy the `with` clause in `validate_request`.
        {:ok, :consent_granted}

      {:error, :consent_denied} = error ->
        error

      {:error, :consent_required} = error ->
        error

      {:error, :consent_error} = error ->
        error

      other ->
        # Log unexpected values for debugging and treat as consent error
        # This is a defensive pattern for robustness against malformed consent handlers
        Logger.warning("SecurityGuard: Unexpected consent result: #{LogSummary.describe(other)}")

        {:error, :consent_error}
    end
  end

  # Credential headers are only removed for origins that are not trusted. When
  # that origin is in fact the MCP server the client was pointed at, the
  # request silently loses its Authorization header and comes back 401, so say
  # so rather than letting it look like a server-side auth bug.
  defp warn_if_credentials_stripped(request, sanitized_headers) do
    if sanitized_headers != request.headers do
      Logger.warning(
        "SecurityGuard: removed credential headers from a request to an untrusted origin. " <>
          remediation_hint(),
        transport: request.transport
      )
    end

    :ok
  end

  defp remediation_hint do
    "Declare the exact origins this application is meant to talk to in " <>
      "config :arbor_mcp, :security, trusted_origins: [...]"
  end
end
