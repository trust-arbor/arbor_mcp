defmodule Arbor.MCP.Internal.ServerManager do
  @moduledoc false

  # This module provides Arbor.MCP extensions beyond the standard MCP specification.
  #
  # Manages multiple MCP server connections.
  #
  # The ServerManager provides a centralized way to:
  # - Start and stop multiple MCP servers
  # - Route requests to appropriate servers
  # - Monitor server health
  # - Handle server lifecycle
  #
  # > Extension Module: Multi-server management is an Arbor.MCP extension not part of the official MCP specification.
  # > Use this for complex applications that need to coordinate multiple MCP servers.

  use GenServer
  require Logger

  alias Arbor.MCP.Internal.Discovery

  defstruct servers: %{}, monitors: %{}

  @type server_spec :: %{
          name: String.t(),
          module: module(),
          config: keyword()
        }

  # Client API

  @doc """
  Starts the server manager.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new MCP server.
  """
  @spec start_server(GenServer.server(), server_spec()) :: {:ok, pid()} | {:error, any()}
  def start_server(manager \\ __MODULE__, server_spec) do
    GenServer.call(manager, {:start_server, server_spec})
  end

  @doc """
  Stops a running MCP server.
  """
  @spec stop_server(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def stop_server(manager \\ __MODULE__, name) do
    GenServer.call(manager, {:stop_server, name})
  end

  @doc """
  Lists all managed servers.
  """
  @spec list_servers(GenServer.server()) :: [%{name: String.t(), pid: pid(), status: atom()}]
  def list_servers(manager \\ __MODULE__) do
    GenServer.call(manager, :list_servers)
  end

  @doc """
  Gets information about a specific server.
  """
  @spec get_server(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_server(manager \\ __MODULE__, name) do
    GenServer.call(manager, {:get_server, name})
  end

  @doc """
  Routes a request to the appropriate server.
  """
  @spec route_request(GenServer.server(), String.t(), any()) :: {:ok, any()} | {:error, any()}
  def route_request(manager \\ __MODULE__, server_name, request) do
    GenServer.call(manager, {:route_request, server_name, request})
  end

  @doc """
  Discovers and starts servers based on configuration.
  """
  @spec discover_and_start(GenServer.server()) :: {:ok, [String.t()]} | {:error, any()}
  def discover_and_start(manager \\ __MODULE__) do
    GenServer.call(manager, :discover_and_start)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Trap exits to handle server crashes
    Process.flag(:trap_exit, true)

    state = %__MODULE__{}
    {:ok, state}
  end

  @impl true
  def handle_call({:start_server, spec}, _from, state) do
    case do_start_server(spec, state) do
      {:ok, pid, new_state} ->
        {:reply, {:ok, pid}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      server_info ->
        :ok = stop_server_process(server_info)
        new_state = remove_server(state, name)
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:list_servers, _from, state) do
    servers =
      state.servers
      |> Enum.map(fn {name, info} ->
        %{
          name: name,
          pid: info.pid,
          status: process_status(info.pid)
        }
      end)

    {:reply, servers, state}
  end

  def handle_call({:get_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      info ->
        {:reply, {:ok, info}, state}
    end
  end

  def handle_call({:route_request, server_name, request}, _from, state) do
    case Map.get(state.servers, server_name) do
      nil ->
        {:reply, {:error, :server_not_found}, state}

      %{pid: pid, module: module} ->
        # Route based on server module type
        result = route_to_server(module, pid, request)
        {:reply, result, state}
    end
  end

  def handle_call(:discover_and_start, _from, state) do
    servers = Discovery.discover_servers()

    results =
      Enum.map(servers, fn server_config ->
        spec = build_server_spec(server_config)

        case do_start_server(spec, state) do
          {:ok, _pid, _new_state} ->
            {:ok, spec.name}

          {:error, reason} ->
            Logger.warning("Failed to start server #{spec.name}: #{inspect(reason)}")
            {:error, spec.name}
        end
      end)

    started =
      results
      |> Enum.filter(fn {status, _} -> status == :ok end)
      |> Enum.map(fn {_, name} -> name end)

    {:reply, {:ok, started}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_server_by_monitor(state, ref) do
      {name, _server_info} ->
        Logger.error("Server #{name} (#{inspect(pid)}) died: #{inspect(reason)}")
        new_state = remove_server(state, name)

        # Optionally restart the server
        # You could implement restart logic here

        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case find_server_by_pid(state, pid) do
      {name, _server_info} ->
        Logger.error("Server #{name} exited: #{inspect(reason)}")
        new_state = remove_server(state, name)
        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  # Private functions

  defp do_start_server(%{name: name} = spec, state) do
    if Map.has_key?(state.servers, name) do
      {:error, :already_started}
    else
      case start_server_process(spec) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          server_info = %{
            pid: pid,
            module: spec.module,
            config: spec.config,
            started_at: DateTime.utc_now()
          }

          new_state = %{
            state
            | servers: Map.put(state.servers, name, server_info),
              monitors: Map.put(state.monitors, ref, name)
          }

          {:ok, pid, new_state}

        error ->
          error
      end
    end
  end

  defp start_server_process(%{module: Arbor.MCP.Client} = spec) do
    Arbor.MCP.Client.start_link(spec.config)
  end

  defp start_server_process(%{module: Arbor.MCP.Server} = spec) do
    Arbor.MCP.Server.HandlerServer.start_link(spec.config)
  end

  defp start_server_process(_spec) do
    {:error, :unknown_server_type}
  end

  defp stop_server_process(%{pid: pid, module: Arbor.MCP.Client}) do
    GenServer.stop(pid)
  end

  defp stop_server_process(%{pid: pid, module: Arbor.MCP.Server}) do
    GenServer.stop(pid)
  end

  defp stop_server_process(%{pid: pid}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  defp remove_server(state, name) do
    case Map.get(state.servers, name) do
      nil ->
        state

      _server_info ->
        # Find and remove monitor
        {ref, _} =
          case Enum.find(state.monitors, fn {_ref, server_name} -> server_name == name end) do
            nil -> {nil, nil}
            result -> result
          end

        new_monitors =
          if ref do
            Process.demonitor(ref, [:flush])
            Map.delete(state.monitors, ref)
          else
            state.monitors
          end

        %{
          state
          | servers: Map.delete(state.servers, name),
            monitors: new_monitors
        }
    end
  end

  defp find_server_by_monitor(state, ref) do
    case Map.get(state.monitors, ref) do
      nil ->
        nil

      name ->
        {name, Map.get(state.servers, name)}
    end
  end

  defp find_server_by_pid(state, pid) do
    Enum.find(state.servers, fn {_name, %{pid: server_pid}} ->
      server_pid == pid
    end)
  end

  defp process_status(pid) do
    if Process.alive?(pid) do
      :running
    else
      :stopped
    end
  end

  defp route_to_server(Arbor.MCP.Client, pid, request) do
    # For clients, we might send tool calls or other requests
    case request do
      {:call_tool, name, args} ->
        Arbor.MCP.Client.call_tool(pid, name, args)

      {:list_tools} ->
        Arbor.MCP.Client.list_tools(pid)

      _ ->
        {:error, :unsupported_request}
    end
  end

  defp route_to_server(_module, _pid, _request) do
    {:error, :unsupported_server_type}
  end

  defp build_server_spec(config) do
    transport = Map.get(config, :transport, "stdio")

    module =
      case transport do
        "stdio" -> Arbor.MCP.Client
        "sse" -> Arbor.MCP.Client
        _ -> nil
      end

    transport_config =
      case transport do
        "stdio" ->
          [
            transport: Arbor.MCP.Transport.Stdio,
            command: config.command,
            args: config.args,
            env: config.env
          ]

        "sse" ->
          [
            transport: Arbor.MCP.Transport.SSE,
            url: config.url,
            headers: config.headers
          ]

        _ ->
          []
      end

    %{
      name: config.name,
      module: module,
      config: transport_config
    }
  end
end
