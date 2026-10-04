defmodule Arbor.MCP.Server.Stdio.Supervisor do
  @moduledoc false
  use Supervisor

  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Server.Runtime.{Initialization, Ref}
  alias Arbor.MCP.Server.Stdio.{Reader, Writer}

  def start_link(opts) do
    table = Ref.table(Keyword.fetch!(opts, :runtime))

    with {:ok, context} <- Initialization.current(table) do
      Initialization.start_supervisor(__MODULE__, opts, context.deadline)
    end
  end

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: Keyword.fetch!(opts, :stdio_config).shutdown_timeout_ms
    }

  @impl true
  def init(opts) do
    table = Ref.table(Keyword.fetch!(opts, :runtime))
    :ok = Initialization.watch(table, self())
    opts = Keyword.put(opts, :table, table)

    Supervisor.init([{Writer, opts}, {HandlerServer, opts}, {Reader, opts}],
      strategy: :one_for_all
    )
  end
end
