defmodule Arbor.MCP.Internal.SessionStore do
  @moduledoc false

  # Unpublished 1.x session/event/request-id store seam.
  # SessionManager remains the public facade. Hex extras must not link this
  # module. Initialization claims, identity binding, and protocol-version
  # immutability stay SessionManager policy.

  @type table :: :sessions | :events | :request_ids
  @type t :: %{
          :__struct__ => module(),
          :backend => :ets | :dets,
          :sessions => term(),
          :events => term(),
          :request_ids => term(),
          optional(atom()) => term()
        }

  @callback open(map()) :: {:ok, t()} | {:error, term()}
  @callback close(t()) :: :ok | {:error, term()}
  @callback lookup(t(), table(), term()) :: [tuple()]
  @callback insert(t(), table(), tuple()) :: true
  @callback insert_new(t(), table(), tuple()) :: boolean()
  @callback delete(t(), table(), term()) :: true
  @callback member(t(), table(), term()) :: boolean()
  @callback match(t(), table(), term()) :: [list()]
  @callback match_delete(t(), table(), term()) :: true
  @callback all(t(), table()) :: [tuple()]
  @callback info(t(), table(), atom()) :: term()
  @callback event_clock(t()) :: non_neg_integer()
  @callback put_event_clock(t(), non_neg_integer()) :: t()

  # Backend selection lives in `Arbor.MCP.Internal.SessionStore.Factory` so this
  # behaviour does not depend on the implementations that adopt it.

  @spec close(t()) :: :ok | {:error, term()}
  def close(%mod{} = store), do: mod.close(store)

  @spec lookup(t(), table(), term()) :: [tuple()]
  def lookup(%mod{} = store, table, key), do: mod.lookup(store, table, key)

  @spec insert(t(), table(), tuple()) :: true
  def insert(%mod{} = store, table, object), do: mod.insert(store, table, object)

  @spec insert_new(t(), table(), tuple()) :: boolean()
  def insert_new(%mod{} = store, table, object), do: mod.insert_new(store, table, object)

  @spec delete(t(), table(), term()) :: true
  def delete(%mod{} = store, table, key), do: mod.delete(store, table, key)

  @spec member(t(), table(), term()) :: boolean()
  def member(%mod{} = store, table, key), do: mod.member(store, table, key)

  @spec match(t(), table(), term()) :: [list()]
  def match(%mod{} = store, table, pattern), do: mod.match(store, table, pattern)

  @spec match_delete(t(), table(), term()) :: true
  def match_delete(%mod{} = store, table, pattern), do: mod.match_delete(store, table, pattern)

  @spec all(t(), table()) :: [tuple()]
  def all(%mod{} = store, table), do: mod.all(store, table)

  @spec info(t(), table(), atom()) :: term()
  def info(%mod{} = store, table, item), do: mod.info(store, table, item)

  @spec event_clock(t()) :: non_neg_integer()
  def event_clock(%mod{} = store), do: mod.event_clock(store)

  @spec put_event_clock(t(), non_neg_integer()) :: t()
  def put_event_clock(%mod{} = store, clock), do: mod.put_event_clock(store, clock)
end
