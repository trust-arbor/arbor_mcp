defmodule Arbor.MCP.Server.Cancellation do
  @moduledoc false

  # Supervised owner of the cancelled-request ETS table used by
  # `Arbor.MCP.Server.Context.cancelled?/0`.
  #
  # Handler callbacks on HandlerServer and StdioServer run inside the server
  # GenServer, so a `notifications/cancelled` cast or stdin line cannot update
  # GenServer state until the handler returns. This table is written by the
  # process that *accepts* the notification (HTTP plug, stdio reader, test/BEAM
  # client send) and read from inside the running handler.

  use GenServer

  @table :ex_mcp_cancelled_requests

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec mark_cancelled(term()) :: :ok
  def mark_cancelled(nil), do: :ok

  def mark_cancelled(request_id) do
    :ets.insert(@table, {request_id, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec cancelled?(term()) :: boolean()
  def cancelled?(nil), do: false

  def cancelled?(request_id) do
    :ets.member(@table, request_id)
  rescue
    ArgumentError -> false
  end

  @spec clear(term()) :: :ok
  def clear(nil), do: :ok

  def clear(request_id) do
    :ets.delete(@table, request_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec mark_from_message(term()) :: :ok
  def mark_from_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} -> mark_from_message(decoded)
      {:error, _} -> :ok
    end
  end

  def mark_from_message(%{"method" => "notifications/cancelled", "params" => params})
      when is_map(params) do
    mark_cancelled(Map.get(params, "requestId"))
  end

  def mark_from_message(_message), do: :ok

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
