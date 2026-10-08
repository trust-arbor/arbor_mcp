defmodule Arbor.MCP.Content.ValidatorRegistry do
  @moduledoc """
  GenServer-based validator registry that replaces Process dictionary usage.

  This module provides a thread-safe registry for content validators
  that eliminates the concurrency issues with Process.put/2.
  """

  use GenServer

  @type validator_name :: atom()
  @type validator_function :: (any() -> :ok | {:error, String.t()})

  # Client API

  @doc """
  Starts the validator registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Registers a validator function.
  """
  @spec register_validator(GenServer.server(), validator_name(), validator_function()) :: :ok
  def register_validator(registry \\ __MODULE__, name, validator_fun) do
    GenServer.call(registry, {:register_validator, name, validator_fun})
  end

  @doc """
  Gets a registered validator function.
  """
  @spec get_validator(GenServer.server(), validator_name()) ::
          {:ok, validator_function()} | {:error, :not_found}
  def get_validator(registry \\ __MODULE__, name) do
    GenServer.call(registry, {:get_validator, name})
  end

  @doc """
  Lists all registered validators.
  """
  @spec list_validators(GenServer.server()) :: [validator_name()]
  def list_validators(registry \\ __MODULE__) do
    GenServer.call(registry, :list_validators)
  end

  @doc """
  Unregisters a validator.
  """
  @spec unregister_validator(GenServer.server(), validator_name()) :: :ok
  def unregister_validator(registry \\ __MODULE__, name) do
    GenServer.call(registry, {:unregister_validator, name})
  end

  @doc """
  Checks if a validator is registered.
  """
  @spec validator_registered?(GenServer.server(), validator_name()) :: boolean()
  def validator_registered?(registry \\ __MODULE__, name) do
    GenServer.call(registry, {:validator_registered?, name})
  end

  # Server callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{validators: %{}}}
  end

  @impl GenServer
  def handle_call({:register_validator, name, validator_fun}, _from, state) do
    new_validators = Map.put(state.validators, name, validator_fun)
    {:reply, :ok, %{state | validators: new_validators}}
  end

  def handle_call({:get_validator, name}, _from, state) do
    case Map.get(state.validators, name) do
      nil -> {:reply, {:error, :not_found}, state}
      validator_fun -> {:reply, {:ok, validator_fun}, state}
    end
  end

  def handle_call(:list_validators, _from, state) do
    validators = Map.keys(state.validators)
    {:reply, validators, state}
  end

  def handle_call({:unregister_validator, name}, _from, state) do
    new_validators = Map.delete(state.validators, name)
    {:reply, :ok, %{state | validators: new_validators}}
  end

  def handle_call({:validator_registered?, name}, _from, state) do
    exists = Map.has_key?(state.validators, name)
    {:reply, exists, state}
  end
end
