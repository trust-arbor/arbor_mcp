defmodule Arbor.MCP.Authorization.Provider.OAuth do
  @moduledoc """
  OAuth 2.1 authorization provider with PKCE, PRM discovery, and scope step-up.

  This is the default provider when OAuth configuration is provided to the transport.
  It handles the complete lifecycle:

  1. On 401 — discovers PRM and AS metadata, selects configured client registration, runs PKCE
  2. On 403 with insufficient_scope — re-authorizes with broader scopes
  3. Prevents auth loops via `auth_completed` flag

  ## Configuration

      # Client ID Metadata Document
      {Arbor.MCP.Authorization.Provider.OAuth, %{
        resource_url: "http://localhost:3000/mcp",
        client_registration: {:cimd, "https://client.example/oauth/metadata.json"}
      }}

      # Pre-registered credentials; the secret is resolved only when needed
      {Arbor.MCP.Authorization.Provider.OAuth, %{
        resource_url: "http://localhost:3000/mcp",
        client_registration: {:pre_registered, "my-client", {:env, "MCP_CLIENT_SECRET"}},
        credential_issuer: "https://auth.example.com"
      }}

      # Deprecated DCR fallback (requires explicit application type and stable callback port)
      {Arbor.MCP.Authorization.Provider.OAuth, %{
        resource_url: "http://localhost:3000/mcp",
        client_registration: :auto,
        application_type: :native,
        redirect_port: 8080
      }}
  """

  @behaviour Arbor.MCP.Authorization.Provider

  require Logger

  alias Arbor.MCP.Authorization.{FullOAuthFlow, LogSanitizer}

  defstruct [
    :access_token,
    :resource_url,
    :protocol_version,
    :auth_config,
    :authorization_server_issuer,
    :last_rejected_issuer,
    granted_scopes: [],
    auth_completed: false
  ]

  @impl true
  def init(config) do
    config = if is_list(config), do: Map.new(config), else: config

    state = %__MODULE__{
      resource_url: config[:resource_url],
      protocol_version: config[:protocol_version],
      auth_config: config
    }

    {:ok, state}
  end

  @impl true
  def get_token(%__MODULE__{access_token: token} = state) do
    {:ok, token, state}
  end

  @impl true
  def handle_unauthorized(www_authenticate, scopes, %__MODULE__{} = state) do
    if state.auth_completed && state.access_token do
      reauthenticate_after_rejection(www_authenticate, scopes, state)
    else
      do_authenticate(www_authenticate, scopes, state)
    end
  end

  @impl true
  def handle_forbidden(www_authenticate, scopes, %__MODULE__{} = state) do
    if www_authenticate && String.contains?(to_string(www_authenticate), "insufficient_scope") do
      step_up_scopes(www_authenticate, scopes, state)
    else
      {:error, :forbidden, state}
    end
  end

  defp do_authenticate(www_authenticate, scopes, state) do
    config =
      (state.auth_config || %{})
      |> Map.put(:resource_url, state.resource_url)
      |> Map.put(:www_authenticate, www_authenticate)
      |> Map.put(:protocol_version, state.protocol_version)

    config =
      if scopes != [] do
        Map.put(config, :scopes, scopes)
      else
        config
      end

    case FullOAuthFlow.execute(config) do
      {:ok, token_result} ->
        access_token = token_result[:access_token] || token_result["access_token"]
        Logger.info("OAuth token obtained")

        :telemetry.execute(
          [:arbor_mcp, :auth, :provider, :token_obtained],
          %{system_time: System.system_time()},
          %{}
        )

        issuer =
          token_result[:authorization_server_issuer] ||
            token_result["authorization_server_issuer"]

        granted_scopes = token_scopes(token_result, scopes)

        new_state = %{
          state
          | access_token: access_token,
            auth_completed: true,
            authorization_server_issuer: issuer,
            granted_scopes: granted_scopes
        }

        {:ok, access_token, new_state}

      {:error, reason} ->
        Logger.warning("OAuth flow failed: #{LogSanitizer.format(reason)}")
        {:error, {:oauth_failed, reason}, state}
    end
  end

  defp step_up_scopes(www_authenticate, scopes, state) do
    challenged_scopes = normalize_scopes(scopes)
    granted_scopes = normalize_scopes(state.granted_scopes)

    cond do
      challenged_scopes == [] ->
        Logger.warning("Scope step-up challenge did not identify any additional scopes")
        {:error, :scope_step_up_exhausted, state}

      Enum.all?(challenged_scopes, &(&1 in granted_scopes)) ->
        Logger.warning("Scope step-up repeated scopes already granted, not retrying")
        {:error, :scope_step_up_exhausted, state}

      true ->
        combined_scopes = Enum.uniq(granted_scopes ++ challenged_scopes)
        Logger.info("Scope step-up required, re-authorizing")

        :telemetry.execute(
          [:arbor_mcp, :auth, :provider, :scope_stepup],
          %{system_time: System.system_time()},
          %{scopes: combined_scopes}
        )

        cleared = %{state | access_token: nil, auth_completed: false}
        do_authenticate(www_authenticate, combined_scopes, cleared)
    end
  end

  # A protected resource can migrate to a different authorization server. A
  # fresh 401 is therefore allowed to trigger discovery again, but only once
  # for a given rejected issuer. Successful migration records the new issuer;
  # rediscovering the same issuer is treated as an auth loop.
  defp reauthenticate_after_rejection(www_authenticate, scopes, state) do
    if state.last_rejected_issuer == state.authorization_server_issuer do
      Logger.warning("Auth failed repeatedly for the same authorization server, not retrying")
      {:error, :auth_loop_detected, state}
    else
      previous_issuer = state.authorization_server_issuer
      retry_state = %{state | access_token: nil, auth_completed: false}

      case do_authenticate(www_authenticate, scopes, retry_state) do
        {:ok, _token, %{authorization_server_issuer: ^previous_issuer} = new_state}
        when not is_nil(previous_issuer) ->
          Logger.warning("Auth retry rediscovered the same authorization server, not retrying")

          {:error, :auth_loop_detected,
           %{new_state | last_rejected_issuer: previous_issuer, access_token: nil}}

        {:ok, token, new_state} ->
          {:ok, token, %{new_state | last_rejected_issuer: nil}}

        {:error, reason, failed_state} ->
          {:error, reason, %{failed_state | last_rejected_issuer: previous_issuer}}
      end
    end
  end

  defp token_scopes(token_result, requested_scopes) do
    case token_result[:scope] || token_result["scope"] do
      scopes when is_binary(scopes) -> normalize_scopes(scopes)
      scopes when is_list(scopes) -> normalize_scopes(scopes)
      _missing -> normalize_scopes(requested_scopes)
    end
  end

  defp normalize_scopes(scopes) when is_binary(scopes),
    do: String.split(scopes, " ", trim: true)

  defp normalize_scopes(scopes) when is_list(scopes),
    do: Enum.filter(scopes, &(is_binary(&1) and &1 != ""))

  defp normalize_scopes(_scopes), do: []
end
