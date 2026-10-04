defmodule Arbor.MCP.SubscriptionRegistry do
  @moduledoc """
  Tracks streamable-HTTP resource subscriptions by MCP session.

  The owning process only provides a supervised lifetime for the ETS indexes.
  Subscription writes and broadcast lookups operate directly on ETS so one
  registry mailbox does not become the notification hot path.
  """

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{ServiceOperation, ServiceRef}
  alias Arbor.MCP.SessionManager.SessionLease

  @by_uri_table :ex_mcp_subscriptions_by_uri
  @by_session_table :ex_mcp_subscriptions_by_session

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(String.t(), String.t()) :: :ok | {:error, atom()}
  def subscribe(session_id, uri) when is_binary(session_id) and is_binary(uri) do
    :ets.insert(@by_uri_table, {uri, session_id})
    :ets.insert(@by_session_table, {session_id, uri})
    :ok
  rescue
    ArgumentError -> {:error, :registry_not_started}
  end

  def subscribe(_session_id, _uri), do: {:error, :session_and_uri_required}

  @spec unsubscribe(String.t(), String.t()) :: :ok
  def unsubscribe(session_id, uri) when is_binary(session_id) and is_binary(uri) do
    :ets.delete_object(@by_uri_table, {uri, session_id})
    :ets.delete_object(@by_session_table, {session_id, uri})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def unsubscribe(_session_id, _uri), do: :ok

  @doc "Removes every subscription owned by a terminated or expired session."
  @spec remove_session(String.t()) :: :ok
  def remove_session(session_id) when is_binary(session_id) do
    @by_session_table
    |> :ets.lookup(session_id)
    |> Enum.each(fn {^session_id, uri} ->
      :ets.delete_object(@by_uri_table, {uri, session_id})
    end)

    :ets.delete(@by_session_table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec sessions(String.t()) :: [String.t()]
  def sessions(uri) when is_binary(uri) do
    @by_uri_table
    |> :ets.lookup(uri)
    |> Enum.map(fn {^uri, session_id} -> session_id end)
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @spec subscriptions(String.t()) :: [String.t()]
  def subscriptions(session_id) when is_binary(session_id) do
    @by_session_table
    |> :ets.lookup(session_id)
    |> Enum.map(fn {^session_id, uri} -> uri end)
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @doc "Subscribes one addressed runtime session epoch to a bounded resource URI."
  def subscribe(%ServiceRef{} = service, lease, uri, opts),
    do:
      ServiceOperation.call(
        service,
        :resource_subscriptions,
        :subscribe,
        [service, lease, uri],
        opts
      )

  @doc "Removes an addressed session's resource subscription."
  def unsubscribe(%ServiceRef{} = service, lease, uri, opts),
    do:
      ServiceOperation.call(
        service,
        :resource_subscriptions,
        :unsubscribe,
        [service, lease, uri],
        opts
      )

  @doc "Lists a bounded set of addressed session-epoch keys for a resource URI."
  def sessions(%ServiceRef{} = service, uri, opts),
    do: ServiceOperation.call(service, :resource_subscriptions, :sessions, [uri], opts)

  @doc "Lists bounded resource subscriptions for an addressed session lease."
  def subscriptions(%ServiceRef{} = service, lease, opts),
    do:
      ServiceOperation.call(
        service,
        :resource_subscriptions,
        :subscriptions,
        [service, lease],
        opts
      )

  @doc "Removes resource entries for one validated addressed session epoch."
  def remove_session(%ServiceRef{} = service, lease, opts) do
    with {:ok, key} <- SessionLease.validate(lease, service, :resource_subscriptions),
         do: ServiceOperation.call(service, :resource_subscriptions, :remove_session, [key], opts)
  end

  @doc "Reads aggregate addressed resource-subscription accounting."
  def get_stats(%ServiceRef{} = service, opts),
    do: ServiceOperation.call(service, :resource_subscriptions, :stats, [], opts)

  @impl true
  def init(_opts) do
    by_uri =
      :ets.new(@by_uri_table, [
        :named_table,
        :public,
        :bag,
        read_concurrency: true,
        write_concurrency: true
      ])

    by_session =
      :ets.new(@by_session_table, [
        :named_table,
        :public,
        :bag,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, {by_uri, by_session}}
  end
end
