defmodule Arbor.MCP.Server.Runtime.Initialization.Barrier do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.Initialization

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)

    with {:ok, pid} <-
           GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(table)),
         :ok <- complete(opts),
         :ok <- Initialization.publish_ready(table, opts[:kind]) do
      {:ok, pid}
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:kind]},
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }
  end

  @impl true
  def init(opts) do
    case Initialization.watch(opts[:table], self()) do
      :ok -> {:ok, opts}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp complete(opts) do
    if opts[:kind] == :execution,
      do: Initialization.complete(opts[:table], :execution, opts[:execution_supervisor]),
      else: :ok
  end
end
