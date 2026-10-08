defmodule Arbor.MCP.Server.Subscriptions.ETS do
  @moduledoc """
  Node-local subscription adapter backed by a private ETS table.

  The table is owned by `Arbor.MCP.Server.Subscriptions`; callers interact through
  the registry so limit checks and registration remain atomic on one node.
  """

  @behaviour Arbor.MCP.Server.Subscriptions.Adapter

  alias Arbor.MCP.Server.Subscriptions.Entry

  @impl true
  def init(_opts) do
    table =
      :ets.new(__MODULE__, [
        :set,
        :private,
        read_concurrency: true
      ])

    {:ok, table}
  end

  @impl true
  def put(%Entry{token: token} = entry, table) do
    if :ets.insert_new(table, {token, entry}) do
      {:ok, table}
    else
      {:error, :duplicate_internal_token, table}
    end
  end

  @impl true
  def delete(token, table) do
    :ets.delete(table, token)
    {:ok, table}
  end

  @impl true
  def all(table) do
    entries = :ets.foldl(fn {_token, entry}, acc -> [entry | acc] end, [], table)
    {entries, table}
  end
end
