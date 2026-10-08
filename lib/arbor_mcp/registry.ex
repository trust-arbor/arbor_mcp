defmodule Arbor.MCP.Registry do
  @moduledoc """
  Registry for managing tools, resources, and prompts in ArborMCP.

  The Registry provides a centralized way to register and lookup MCP capabilities.
  It supports dynamic registration and efficient lookup operations.
  """

  use GenServer

  @type capability_type :: :tool | :resource | :prompt
  @type capability :: %{
          name: String.t(),
          type: capability_type(),
          module: module(),
          metadata: map()
        }

  # Client API

  @doc """
  Starts the registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a capability.
  """
  @spec register(GenServer.server(), capability_type(), String.t(), module(), map()) :: :ok
  def register(registry \\ __MODULE__, type, name, module, metadata \\ %{}) do
    capability = %{
      name: name,
      type: type,
      module: module,
      metadata: metadata
    }

    GenServer.call(registry, {:register, capability})
  end

  @doc """
  Unregisters a capability.
  """
  @spec unregister(GenServer.server(), capability_type(), String.t()) :: :ok
  def unregister(registry \\ __MODULE__, type, name) do
    GenServer.call(registry, {:unregister, type, name})
  end

  @doc """
  Looks up a capability by type and name.
  """
  @spec lookup(GenServer.server(), capability_type(), String.t()) ::
          {:ok, capability()} | {:error, :not_found}
  def lookup(registry \\ __MODULE__, type, name) do
    GenServer.call(registry, {:lookup, type, name})
  end

  @doc """
  Lists all capabilities of a given type.
  """
  @spec list(GenServer.server(), capability_type()) :: [capability()]
  def list(registry \\ __MODULE__, type) do
    GenServer.call(registry, {:list, type})
  end

  @doc """
  Lists all capabilities.
  """
  @spec list_all(GenServer.server()) :: [capability()]
  def list_all(registry \\ __MODULE__) do
    GenServer.call(registry, :list_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      capabilities: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, capability}, _from, state) do
    key = {capability.type, capability.name}
    new_capabilities = Map.put(state.capabilities, key, capability)
    new_state = %{state | capabilities: new_capabilities}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unregister, type, name}, _from, state) do
    key = {type, name}
    new_capabilities = Map.delete(state.capabilities, key)
    new_state = %{state | capabilities: new_capabilities}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:lookup, type, name}, _from, state) do
    key = {type, name}

    case Map.get(state.capabilities, key) do
      nil -> {:reply, {:error, :not_found}, state}
      capability -> {:reply, {:ok, capability}, state}
    end
  end

  @impl true
  def handle_call({:list, type}, _from, state) do
    capabilities =
      state.capabilities
      |> Enum.filter(fn {{cap_type, _name}, _capability} -> cap_type == type end)
      |> Enum.map(fn {_key, capability} -> capability end)

    {:reply, capabilities, state}
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    capabilities =
      state.capabilities
      |> Map.values()

    {:reply, capabilities, state}
  end
end
