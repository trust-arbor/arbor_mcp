defmodule Arbor.MCP.Internal.SessionStore.ETS do
  @moduledoc false

  @behaviour Arbor.MCP.Internal.SessionStore

  defstruct [:sessions, :events, :request_ids, backend: :ets]

  @sessions_table :session_manager_sessions
  @events_table :session_manager_events
  @request_ids_table :session_manager_request_ids

  @impl Arbor.MCP.Internal.SessionStore
  def open(_config) do
    # Unnamed, process-owned tables. Restarting SessionManager starts empty.
    {:ok,
     %__MODULE__{
       sessions: :ets.new(@sessions_table, [:set, :protected]),
       events: :ets.new(@events_table, [:ordered_set, :protected]),
       request_ids: :ets.new(@request_ids_table, [:set, :protected])
     }}
  end

  @impl Arbor.MCP.Internal.SessionStore
  def close(%__MODULE__{} = store) do
    :ets.delete(store.sessions)
    :ets.delete(store.events)
    :ets.delete(store.request_ids)
    :ok
  end

  @impl Arbor.MCP.Internal.SessionStore
  def lookup(store, table, key), do: :ets.lookup(table_ref(store, table), key)

  @impl Arbor.MCP.Internal.SessionStore
  def insert(store, table, object) do
    :ets.insert(table_ref(store, table), object)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def insert_new(store, table, object) do
    :ets.insert_new(table_ref(store, table), object)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def delete(store, table, key) do
    :ets.delete(table_ref(store, table), key)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def member(store, table, key), do: :ets.member(table_ref(store, table), key)

  @impl Arbor.MCP.Internal.SessionStore
  def match(store, table, pattern), do: :ets.match(table_ref(store, table), pattern)

  @impl Arbor.MCP.Internal.SessionStore
  def match_delete(store, table, pattern) do
    :ets.match_delete(table_ref(store, table), pattern)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def all(store, table), do: :ets.tab2list(table_ref(store, table))

  @impl Arbor.MCP.Internal.SessionStore
  def info(store, table, item), do: :ets.info(table_ref(store, table), item)

  @impl Arbor.MCP.Internal.SessionStore
  def event_clock(_store), do: 0

  @impl Arbor.MCP.Internal.SessionStore
  def put_event_clock(store, _clock), do: store

  defp table_ref(%__MODULE__{sessions: table}, :sessions), do: table
  defp table_ref(%__MODULE__{events: table}, :events), do: table
  defp table_ref(%__MODULE__{request_ids: table}, :request_ids), do: table
end
