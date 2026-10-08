defmodule Arbor.MCP.Authorization.TokenManager do
  @moduledoc """
  Manages OAuth tokens with automatic refresh and expiration tracking.

  This GenServer maintains tokens, monitors their expiration, and automatically
  refreshes them before they expire, following MCP authorization best practices.

  ## Features

  - Automatic token refresh before expiration
  - Thread-safe token storage
  - Configurable refresh window
  - Token rotation support
  """

  use GenServer
  require Logger

  alias Arbor.MCP.Authorization
  alias Arbor.MCP.Authorization.LogSanitizer

  # Refresh tokens 5 minutes before expiration by default
  @default_refresh_window 300

  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :token_type,
    :scope,
    :auth_config,
    :auth_method,
    :refresh_timer,
    :subscribers
  ]

  @type auth_method :: :client_secret | :private_key_jwt | :enterprise_idjag

  @type t :: %__MODULE__{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          token_type: String.t(),
          scope: String.t() | nil,
          auth_config: map(),
          auth_method: auth_method() | nil,
          refresh_timer: reference() | nil,
          subscribers: MapSet.t(pid())
        }

  # Client API

  @doc """
  Starts a token manager process.

  Options:
  - `:auth_config` - Authorization configuration (client_id, client_secret, token_endpoint, etc.)
  - `:refresh_window` - Seconds before expiration to refresh (default: 300)
  - `:name` - Optional process name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, init_opts} =
      case Keyword.pop(opts, :name) do
        {nil, opts} -> {[], opts}
        {name, opts} -> {[name: name], opts}
      end

    GenServer.start_link(__MODULE__, init_opts, name_opts)
  end

  @doc """
  Sets a new token in the manager.
  """
  @spec set_token(GenServer.server(), map()) :: :ok
  def set_token(manager, token_response) do
    GenServer.call(manager, {:set_token, token_response})
  end

  @doc """
  Gets the current valid access token.

  Returns `{:ok, token}` or `{:error, reason}` if token is expired/missing.
  """
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def get_token(manager) do
    GenServer.call(manager, :get_token)
  end

  @doc """
  Gets full token information including metadata.
  """
  @spec get_token_info(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def get_token_info(manager) do
    GenServer.call(manager, :get_token_info)
  end

  @doc """
  Forces an immediate token refresh.
  """
  @spec refresh_now(GenServer.server()) :: {:ok, map()} | {:error, any()}
  def refresh_now(manager) do
    GenServer.call(manager, :refresh_now, 30_000)
  end

  @doc """
  Subscribes to token update notifications.

  Subscribers receive `{:token_updated, manager, token_info}` messages.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(manager) do
    GenServer.call(manager, {:subscribe, self()})
  end

  @doc """
  Unsubscribes from token update notifications.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(manager) do
    GenServer.call(manager, {:unsubscribe, self()})
  end

  @doc """
  Upgrades the token's scopes by merging additional scopes with the current ones.

  If a refresh token is available, attempts to refresh with the expanded scope set.
  If no refresh token is available, returns `{:error, :reauthorization_required}`
  with the combined scope list so the caller can initiate a full re-authorization.

  ## Options

  - `:timeout` - Call timeout in milliseconds (default: 30_000)
  """
  @spec upgrade_scopes(GenServer.server(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), [String.t()]}}
  def upgrade_scopes(manager, additional_scopes, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(manager, {:upgrade_scopes, additional_scopes}, timeout)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    auth_config = Keyword.fetch!(opts, :auth_config)
    refresh_window = Keyword.get(opts, :refresh_window, @default_refresh_window)
    auth_method = Keyword.get(opts, :auth_method)

    state = %__MODULE__{
      auth_config: Map.put(auth_config, :refresh_window, refresh_window),
      auth_method: auth_method,
      token_type: "Bearer",
      subscribers: MapSet.new()
    }

    # If initial token provided, set it
    case Keyword.get(opts, :initial_token) do
      nil ->
        {:ok, state}

      token ->
        {:ok, state, {:continue, {:set_token, token}}}
    end
  end

  @impl true
  def handle_continue({:set_token, token}, state) do
    {:noreply, process_token_response(token, state)}
  end

  @impl true
  def handle_call({:set_token, token_response}, _from, state) do
    new_state = process_token_response(token_response, state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_token, _from, state) do
    case validate_token(state) do
      :valid ->
        {:reply, {:ok, state.access_token}, state}

      :expired ->
        {:reply, {:error, :token_expired}, state}

      :missing ->
        {:reply, {:error, :no_token}, state}
    end
  end

  def handle_call(:get_token_info, _from, state) do
    case validate_token(state) do
      :valid ->
        info = %{
          access_token: state.access_token,
          token_type: state.token_type,
          expires_at: state.expires_at,
          scope: state.scope
        }

        {:reply, {:ok, info}, state}

      status ->
        {:reply, {:error, status}, state}
    end
  end

  def handle_call(:refresh_now, from, state) do
    if state.refresh_token do
      # Spawn refresh task to avoid blocking
      Task.start(fn ->
        result = refresh_token(state)
        GenServer.reply(from, result)
      end)

      {:noreply, state}
    else
      {:reply, {:error, :no_refresh_token}, state}
    end
  end

  def handle_call({:upgrade_scopes, additional_scopes}, from, state) do
    current_scopes =
      case state.scope do
        nil -> []
        s when is_binary(s) -> String.split(s, " ", trim: true)
      end

    combined_scopes = Enum.uniq(current_scopes ++ additional_scopes)

    if state.refresh_token do
      manager = self()

      # Attempt refresh with expanded scope set
      Task.start(fn ->
        result = refresh_token_with_scopes(state, combined_scopes)

        case result do
          {:ok, new_token} ->
            # Update state in manager with new token
            send(manager, {:token_refreshed, new_token})
            GenServer.reply(from, {:ok, new_token})

          error ->
            GenServer.reply(from, error)
        end
      end)

      {:noreply, state}
    else
      {:reply, {:error, {:reauthorization_required, combined_scopes}}, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_state = %{state | subscribers: MapSet.put(state.subscribers, pid)}
    {:reply, :ok, new_state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    new_state = %{state | subscribers: MapSet.delete(state.subscribers, pid)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:refresh_token, state) do
    case refresh_token(state) do
      {:ok, new_token} ->
        new_state = process_token_response(new_token, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Token refresh failed: #{LogSanitizer.format(reason)}")
        # Schedule retry in 30 seconds
        Process.send_after(self(), :refresh_token, 30_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state = %{state | subscribers: MapSet.delete(state.subscribers, pid)}
    {:noreply, new_state}
  end

  def handle_info({:token_refreshed, new_token}, state) do
    new_state = process_token_response(new_token, state)
    {:noreply, new_state}
  end

  # Private functions

  defp process_token_response(token_response, state) do
    # Cancel existing timer
    if state.refresh_timer do
      Process.cancel_timer(state.refresh_timer)
    end

    # Calculate expiration
    expires_at = calculate_expiration(token_response)

    # Schedule refresh only if we have a refresh token
    refresh_timer =
      if token_response["refresh_token"] || state.refresh_token do
        schedule_refresh(expires_at, state.auth_config.refresh_window)
      else
        nil
      end

    new_state = %{
      state
      | access_token: token_response["access_token"],
        refresh_token: token_response["refresh_token"] || state.refresh_token,
        expires_at: expires_at,
        scope: token_response["scope"] || state.scope,
        refresh_timer: refresh_timer
    }

    # Notify subscribers
    notify_subscribers(new_state)

    new_state
  end

  defp calculate_expiration(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
  end

  defp calculate_expiration(_) do
    # Default to 1 hour if not specified
    DateTime.utc_now()
    |> DateTime.add(3600, :second)
  end

  defp schedule_refresh(expires_at, refresh_window) do
    now = DateTime.utc_now()
    diff = DateTime.diff(expires_at, now, :second)

    # Schedule refresh before expiration
    refresh_in = max(diff - refresh_window, 1)

    Logger.debug("Scheduling token refresh in #{refresh_in} seconds")
    Process.send_after(self(), :refresh_token, refresh_in * 1000)
  end

  defp validate_token(%{access_token: nil}), do: :missing
  # No expiration info
  defp validate_token(%{expires_at: nil}), do: :valid

  defp validate_token(%{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :valid
    else
      :expired
    end
  end

  defp refresh_token(state) do
    Logger.info("Refreshing access token (method: #{inspect(state.auth_method)})")

    case state.auth_method do
      :private_key_jwt ->
        refresh_with_jwt_auth(state)

      :enterprise_idjag ->
        refresh_with_enterprise(state)

      _other ->
        refresh_with_client_secret(state)
    end
  end

  defp refresh_with_client_secret(state) do
    config =
      Map.merge(state.auth_config, %{
        grant_type: "refresh_token",
        refresh_token: state.refresh_token
      })

    Authorization.token_request(config)
  end

  defp refresh_with_jwt_auth(state) do
    alias Arbor.MCP.Authorization.{ClientAssertion, HTTPClient}

    token_endpoint = state.auth_config[:token_endpoint]

    case ClientAssertion.build_assertion_params(
           client_id: state.auth_config[:client_id],
           token_endpoint: token_endpoint,
           private_key: state.auth_config[:private_key]
         ) do
      {:ok, assertion_params} ->
        body =
          [
            {"grant_type", "refresh_token"},
            {"refresh_token", state.refresh_token}
          ] ++ assertion_params

        body =
          case state.scope do
            nil -> body
            scope -> body ++ [{"scope", scope}]
          end

        HTTPClient.make_token_request(token_endpoint, body)

      {:error, _} = error ->
        error
    end
  end

  defp refresh_with_enterprise(state) do
    # Enterprise flow requires re-authentication; we can only attempt
    # a refresh if we have a refresh token from the original grant
    if state.refresh_token do
      refresh_with_client_secret(state)
    else
      {:error, :enterprise_reauthorization_required}
    end
  end

  defp refresh_token_with_scopes(state, scopes) do
    Logger.info("Refreshing access token with expanded scopes: #{Enum.join(scopes, " ")}")

    config =
      Map.merge(state.auth_config, %{
        grant_type: "refresh_token",
        refresh_token: state.refresh_token,
        scope: Enum.join(scopes, " ")
      })

    Authorization.token_request(config)
  end

  defp notify_subscribers(state) do
    token_info = %{
      access_token: state.access_token,
      token_type: state.token_type,
      expires_at: state.expires_at,
      scope: state.scope
    }

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:token_updated, self(), token_info})
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if state.refresh_timer do
      Process.cancel_timer(state.refresh_timer)
    end

    :ok
  end
end
