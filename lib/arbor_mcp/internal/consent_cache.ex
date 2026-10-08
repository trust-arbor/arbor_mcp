defmodule Arbor.MCP.Internal.ConsentCache do
  @moduledoc """
  A GenServer and ETS-based cache for user consent decisions.
  """
  use GenServer

  alias Arbor.MCP.ConsentHandler

  @table __MODULE__
  # Cleanup every 5 minutes
  @cleanup_interval 300_000

  # --- Client API ---

  @doc """
  Starts the ConsentCache GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a consent decision in the cache.

  `expires_at` is a monotonic time in seconds.
  """
  @spec store_consent(
          ConsentHandler.user_id(),
          ConsentHandler.resource_origin(),
          expires_at :: non_neg_integer()
        ) :: :ok
  def store_consent(user_id, resource_origin, expires_at) do
    GenServer.cast(__MODULE__, {:store, user_id, resource_origin, expires_at})
  end

  @doc """
  Checks for an existing, valid consent in the cache.

  This performs a direct ETS lookup for performance.
  """
  @spec check_consent(ConsentHandler.user_id(), ConsentHandler.resource_origin()) ::
          {:ok, expires_at :: non_neg_integer()} | {:not_found} | {:expired}
  def check_consent(user_id, resource_origin) do
    # Ensure table exists - handle race condition during startup
    case :ets.whereis(@table) do
      :undefined ->
        # Table doesn't exist yet, treat as not found
        {:not_found}

      _tid ->
        case :ets.lookup(@table, {user_id, resource_origin}) do
          [{_key, expires_at}] ->
            if System.monotonic_time(:second) < expires_at do
              {:ok, expires_at}
            else
              {:expired}
            end

          [] ->
            {:not_found}
        end
    end
  end

  @doc """
  Revokes a consent decision from the cache.
  """
  @spec revoke_consent(ConsentHandler.user_id(), ConsentHandler.resource_origin()) :: :ok
  def revoke_consent(user_id, resource_origin) do
    GenServer.cast(__MODULE__, {:revoke, user_id, resource_origin})
  end

  @doc """
  Triggers a manual cleanup of expired consent entries.
  """
  def cleanup_expired do
    GenServer.cast(__MODULE__, :cleanup)
  end

  @doc """
  Clears all consent decisions from the cache.

  This is primarily intended for testing purposes to ensure test isolation.
  """
  def clear do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :clear)
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:store, user_id, resource_origin, expires_at}, state) do
    :ets.insert(@table, {{user_id, resource_origin}, expires_at})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:revoke, user_id, resource_origin}, state) do
    :ets.delete(@table, {user_id, resource_origin})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:cleanup, state) do
    perform_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    # Only clear if table exists (defensive programming)
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(@table)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    perform_cleanup()
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  defp perform_cleanup do
    now = System.monotonic_time(:second)
    match_spec = [{{{:_, :_}, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  end
end
