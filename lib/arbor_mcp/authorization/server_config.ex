defmodule Arbor.MCP.Authorization.ServerConfig do
  @moduledoc """
  Centralized configuration management for OAuth 2.1 authorization server settings.

  This module provides a unified interface for managing OAuth authorization server
  configurations including validation, runtime updates, and environment-based settings.
  It supports multiple authorization servers and provides validation for security
  requirements (HTTPS enforcement, etc.).

  ## Configuration Format

  The configuration can be specified in multiple ways:

  ### Application Environment

      config :arbor_mcp, Arbor.MCP.Authorization.ServerConfig,
        default_server: :auth_server,
        servers: %{
          auth_server: %{
            introspection_endpoint: "https://auth.example.com/introspect",
            realm: "mcp-server",
            client_id: "mcp-server-id",
            client_secret: "server-secret"
          },
          backup_server: %{
            introspection_endpoint: "https://backup-auth.example.com/introspect",
            realm: "mcp-backup"
          }
        }

  ### Runtime Configuration

      Arbor.MCP.Authorization.ServerConfig.put_server(:my_server, %{
        introspection_endpoint: "https://new-auth.example.com/introspect",
        realm: "my-realm"
      })

  ## Usage

      # Get default server config
      {:ok, config} = Arbor.MCP.Authorization.ServerConfig.get_server()

      # Get specific server config
      {:ok, config} = Arbor.MCP.Authorization.ServerConfig.get_server(:backup_server)

      # Validate configuration
      :ok = Arbor.MCP.Authorization.ServerConfig.validate_config(config)

      # List all configured servers
      servers = Arbor.MCP.Authorization.ServerConfig.list_servers()
  """

  use GenServer
  require Logger

  @type server_id :: atom() | String.t()
  @type server_config :: %{
          required(:introspection_endpoint) => String.t(),
          optional(:realm) => String.t(),
          optional(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          optional(:timeout) => pos_integer(),
          optional(:retries) => non_neg_integer()
        }
  @type config_error :: :not_found | :invalid_config | :https_required

  ## Public API

  @doc """
  Starts the ServerConfig GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the configuration for the default authorization server.
  """
  @spec get_server() :: {:ok, server_config()} | {:error, config_error()}
  def get_server do
    GenServer.call(__MODULE__, :get_default_server)
  end

  @doc """
  Gets the configuration for a specific authorization server.
  """
  @spec get_server(server_id()) :: {:ok, server_config()} | {:error, config_error()}
  def get_server(server_id) do
    GenServer.call(__MODULE__, {:get_server, server_id})
  end

  @doc """
  Sets the configuration for a specific authorization server.

  The configuration is validated before being stored.
  """
  @spec put_server(server_id(), server_config()) :: :ok | {:error, config_error()}
  def put_server(server_id, config) do
    with :ok <- validate_config(config) do
      GenServer.call(__MODULE__, {:put_server, server_id, config})
    end
  end

  @doc """
  Removes a server configuration.
  """
  @spec delete_server(server_id()) :: :ok
  def delete_server(server_id) do
    GenServer.call(__MODULE__, {:delete_server, server_id})
  end

  @doc """
  Lists all configured server IDs.
  """
  @spec list_servers() :: [server_id()]
  def list_servers do
    GenServer.call(__MODULE__, :list_servers)
  end

  @doc """
  Gets the default server ID.
  """
  @spec get_default_server_id() :: server_id()
  def get_default_server_id do
    Application.get_env(:arbor_mcp, __MODULE__, [])
    |> Keyword.get(:default_server, :default)
  end

  @doc """
  Sets the default server ID.
  """
  @spec set_default_server_id(server_id()) :: :ok
  def set_default_server_id(server_id) do
    GenServer.call(__MODULE__, {:set_default_server, server_id})
  end

  @doc """
  Validates a server configuration.

  ## Validation Rules

  - `introspection_endpoint` must be a valid HTTPS URL (HTTP allowed for localhost/127.0.0.1)
  - `realm` must be a non-empty string if provided
  - `timeout` must be a positive integer if provided
  - `retries` must be a non-negative integer if provided
  """
  @spec validate_config(server_config()) :: :ok | {:error, config_error()}
  def validate_config(%{introspection_endpoint: endpoint} = config)
      when is_binary(endpoint) do
    with :ok <- validate_endpoint(endpoint) do
      validate_optional_fields(config)
    end
  end

  def validate_config(_), do: {:error, :invalid_config}

  @doc """
  Reloads configuration from application environment.

  This is useful when configuration has been updated at runtime.
  """
  @spec reload_from_env() :: :ok
  def reload_from_env do
    GenServer.call(__MODULE__, :reload_from_env)
  end

  ## GenServer Implementation

  @impl GenServer
  def init(_opts) do
    state = %{
      servers: %{},
      default_server: get_default_server_id()
    }

    # Load initial configuration from application environment
    {:ok, load_from_env(state)}
  end

  @impl GenServer
  def handle_call({:get_server, server_id}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil -> {:reply, {:error, :not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  def handle_call(:get_default_server, _from, state) do
    case Map.get(state.servers, state.default_server) do
      nil -> {:reply, {:error, :not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  def handle_call({:put_server, server_id, config}, _from, state) do
    new_servers = Map.put(state.servers, server_id, config)
    new_state = %{state | servers: new_servers}
    {:reply, :ok, new_state}
  end

  def handle_call({:delete_server, server_id}, _from, state) do
    new_servers = Map.delete(state.servers, server_id)
    new_state = %{state | servers: new_servers}
    {:reply, :ok, new_state}
  end

  def handle_call(:list_servers, _from, state) do
    server_ids = Map.keys(state.servers)
    {:reply, server_ids, state}
  end

  def handle_call({:set_default_server, server_id}, _from, state) do
    new_state = %{state | default_server: server_id}
    {:reply, :ok, new_state}
  end

  def handle_call(:reload_from_env, _from, state) do
    new_state = load_from_env(state)
    {:reply, :ok, new_state}
  end

  ## Private Functions

  defp load_from_env(state) do
    env_config = Application.get_env(:arbor_mcp, __MODULE__, [])

    servers =
      case Keyword.get(env_config, :servers) do
        servers when is_map(servers) ->
          servers
          |> Enum.reduce(%{}, fn {id, config}, acc ->
            case validate_config(config) do
              :ok ->
                Map.put(acc, id, config)

              {:error, reason} ->
                Logger.warning("Invalid server config for #{id}: #{inspect(reason)}")
                acc
            end
          end)

        _ ->
          %{}
      end

    default_server = Keyword.get(env_config, :default_server, state.default_server)

    %{state | servers: servers, default_server: default_server}
  end

  defp validate_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https"} ->
        :ok

      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] ->
        :ok

      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        {:error, :https_required}

      _ ->
        {:error, :invalid_config}
    end
  end

  defp validate_optional_fields(config) do
    with :ok <- validate_realm(Map.get(config, :realm)),
         :ok <- validate_timeout(Map.get(config, :timeout)) do
      validate_retries(Map.get(config, :retries))
    end
  end

  defp validate_realm(nil), do: :ok
  defp validate_realm(realm) when is_binary(realm) and byte_size(realm) > 0, do: :ok
  defp validate_realm(_), do: {:error, :invalid_config}

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_config}

  defp validate_retries(nil), do: :ok
  defp validate_retries(retries) when is_integer(retries) and retries >= 0, do: :ok
  defp validate_retries(_), do: {:error, :invalid_config}
end
