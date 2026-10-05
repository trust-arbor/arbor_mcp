defmodule Arbor.MCP.HttpPlug.SessionRegistry do
  @moduledoc """
  Supervised owner of the SSE session table used by `Arbor.MCP.HttpPlug`.

  The retained standalone SSEHandler runs inside short-lived HTTP request processes, so the ETS
  table mapping session ids to SSE handler pids must be owned by a long-lived
  process — otherwise every registration would vanish as soon as the request
  process that happened to create the table exits. This GenServer creates the
  named public table in `init/1`. Hosts using the standalone SSEHandler must
  explicitly supervise this owner. Application startup does not start server
  state owners. Runtime mounts use their addressed runtime session service and
  do not use this registry.
  """

  use GenServer

  @table :http_plug_sessions

  @doc """
  Returns the name of the ETS table holding session registrations.
  """
  @spec table() :: atom()
  def table, do: @table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers the SSE handler pid for a session id.

  Returns `{:error, :registry_not_started}` when the owning process (and thus
  the table) is not running. Starting `:arbor_mcp` does not start this owner;
  supervise this module explicitly for retained standalone SSEHandler use.
  """
  @spec register(String.t(), pid()) :: :ok | {:error, :registry_not_started}
  def register(session_id, handler_pid) when is_binary(session_id) and is_pid(handler_pid) do
    :ets.insert(@table, {session_id, handler_pid})
    :ok
  rescue
    ArgumentError -> {:error, :registry_not_started}
  end

  @doc """
  Looks up the SSE handler pid registered for a session id.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found | :registry_not_started}
  def lookup(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, handler_pid}] -> {:ok, handler_pid}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :registry_not_started}
  end

  @doc """
  Removes the registration for a session id.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(session_id) when is_binary(session_id) do
    :ets.delete(@table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Removes the registration for a session id only if it still points at
  `handler_pid`.

  Used by handlers cleaning up after themselves in `terminate/2` without
  clobbering a newer registration made for the same session id.
  """
  @spec unregister(String.t(), pid()) :: :ok
  def unregister(session_id, handler_pid) when is_binary(session_id) and is_pid(handler_pid) do
    :ets.delete_object(@table, {session_id, handler_pid})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
