defmodule Arbor.MCP.Authorization.Provider.OAuth do
  @moduledoc """
  OAuth 2.1 authorization provider with PKCE, PRM discovery, and scope step-up.

  This is the default provider when OAuth configuration is provided to the transport.
  It handles the complete lifecycle:

  1. On 401 — discovers PRM and AS metadata, selects configured client registration, runs PKCE
  2. Before the access token expires, and on a 401 once it has one — renews it
     with the refresh token, without the browser, and runs the full flow only
     if that fails
  3. On 403 with insufficient_scope — re-authorizes with broader scopes
  4. Prevents auth loops via `auth_completed` flag

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

  alias Arbor.MCP.Authorization.{FullOAuthFlow, Issuer, LogSanitizer}

  # Renew this many seconds before the access token's expiry.
  @refresh_skew 30

  # auth_config can hold a client secret or an identity assertion.
  @derive {Inspect, except: [:access_token, :refresh, :auth_config, :rejection_refreshed]}
  defstruct [
    :access_token,
    :resource_url,
    :protocol_version,
    :auth_config,
    :authorization_server_issuer,
    :last_rejected_issuer,
    # When the access token expires (system seconds), if the server said.
    :expires_at,
    # FullOAuthFlow's refresh context, or nil without a refresh token.
    :refresh,
    # A fingerprint of the access token a refresh after a 401 returned. Its
    # own rejection means refreshing didn't help.
    :rejection_refreshed,
    # Authorization servers the resource was found to have moved to. Each
    # one's flow runs once, so failed ones don't start again with every 401.
    migration_issuers: [],
    # Observable acquisition evidence for transports, even when a refresh
    # repeats the bearer bytes and every other piece of token metadata.
    token_acquisitions: 0,
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
    if expiring?(state) do
      case refresh(state) do
        {:ok, token, state} -> {:ok, token, state}
        # Send the old token; a 401 then decides whether to authenticate again.
        {:error, _reason} -> {:ok, token, state}
      end
    else
      {:ok, token, state}
    end
  end

  @impl true
  # A token refreshed after a 401 and rejected in turn may mean the resource
  # moved to another authorization server. Discovery, which asks nothing of
  # the user, decides: the full flow, which may open a browser, runs only for
  # a different issuer. Otherwise the provider refreshes again.
  def handle_unauthorized(www_authenticate, scopes, %__MODULE__{} = state) do
    with true <- refreshed_token_rejected?(state),
         {:ok, issuer} <- moved_to(www_authenticate, state) do
      tried = [issuer | state.migration_issuers]
      state = %{state | rejection_refreshed: nil, migration_issuers: tried}
      migrate(www_authenticate, scopes, state)
    else
      _not_moved ->
        case refresh(state) do
          {:ok, token, state} -> {:ok, token, %{state | rejection_refreshed: fingerprint(token)}}
          {:error, _reason} -> authenticate_again(www_authenticate, scopes, state)
        end
    end
  end

  defp refreshed_token_rejected?(%{access_token: token, rejection_refreshed: print})
       when is_binary(token) and is_binary(print),
       do: fingerprint(token) == print

  defp refreshed_token_rejected?(_state), do: false

  defp fingerprint(token), do: :crypto.hash(:sha256, token)

  # The issuer the resource's metadata now names, if it is neither the current
  # one nor one already tried.
  defp moved_to(www_authenticate, %{authorization_server_issuer: current} = state) do
    with {:ok, issuer} <- FullOAuthFlow.discover_issuer(flow_config(www_authenticate, [], state)),
         true <- is_binary(current) and Issuer.compare(issuer, current) != :ok,
         false <- Enum.any?(state.migration_issuers, &(Issuer.compare(issuer, &1) == :ok)) do
      {:ok, issuer}
    end
  end

  defp migrate(www_authenticate, scopes, state) do
    if state.auth_completed && state.access_token,
      do: reauthenticate_after_rejection(www_authenticate, scopes, state),
      else: do_authenticate(www_authenticate, scopes, state)
  end

  # A flow after a rejection that already failed (last_rejected_issuer) isn't
  # started again on the next 401: that could open a browser every request.
  # A first sign-in, or a migration to a newly found server, still runs.
  defp authenticate_again(www_authenticate, scopes, state) do
    cond do
      state.auth_completed && state.access_token ->
        reauthenticate_after_rejection(www_authenticate, scopes, state)

      # Unless the resource's published metadata now names a server not
      # tried yet: then a migration may still run.
      is_binary(state.last_rejected_issuer) ->
        case moved_to(www_authenticate, state) do
          {:ok, issuer} ->
            state = %{state | migration_issuers: [issuer | state.migration_issuers]}
            do_authenticate(www_authenticate, scopes, state)

          _not_moved ->
            Logger.warning("Auth failed after a rejection; not retrying the flow")
            {:error, :auth_loop_detected, state}
        end

      true ->
        do_authenticate(www_authenticate, scopes, state)
    end
  end

  defp expiring?(%{expires_at: expires_at, refresh: refresh}),
    do:
      is_integer(expires_at) and not is_nil(refresh) and
        System.system_time(:second) >= expires_at - @refresh_skew

  defp refresh(%{refresh: nil}), do: {:error, :no_refresh_token}

  defp refresh(state) do
    case FullOAuthFlow.refresh(state.refresh, state.auth_config || %{}) do
      {:ok, token_data, next} ->
        Logger.info("OAuth token refreshed")

        :telemetry.execute(
          [:arbor_mcp, :auth, :provider, :token_refreshed],
          %{system_time: System.system_time()},
          %{}
        )

        token = token_data[:access_token]

        {:ok, token,
         %{
           state
           | access_token: token,
             token_acquisitions: state.token_acquisitions + 1,
             refresh: next,
             expires_at: expires_at(token_data),
             granted_scopes: token_scopes(token_data, state.granted_scopes),
             last_rejected_issuer: nil
         }}

      {:error, reason} ->
        Logger.info("OAuth token refresh failed: #{LogSanitizer.format(reason)}")
        {:error, reason}
    end
  end

  defp expires_at(token_data) do
    case token_data[:expires_in] || token_data["expires_in"] do
      seconds when is_integer(seconds) and seconds >= 0 -> System.system_time(:second) + seconds
      _unknown -> nil
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

  defp flow_config(www_authenticate, scopes, state) do
    config =
      (state.auth_config || %{})
      |> Map.put(:resource_url, state.resource_url)
      |> Map.put(:www_authenticate, www_authenticate)
      |> Map.put(:protocol_version, state.protocol_version)

    if scopes != [], do: Map.put(config, :scopes, scopes), else: config
  end

  defp do_authenticate(www_authenticate, scopes, state) do
    case FullOAuthFlow.execute(flow_config(www_authenticate, scopes, state)) do
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
            token_acquisitions: state.token_acquisitions + 1,
            auth_completed: true,
            authorization_server_issuer: issuer,
            granted_scopes: granted_scopes,
            expires_at: expires_at(token_result),
            refresh: token_result[:refresh_context]
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
