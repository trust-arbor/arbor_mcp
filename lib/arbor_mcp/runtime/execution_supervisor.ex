defmodule Arbor.MCP.Server.Runtime.ExecutionSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.MCP.Server.Runtime.ShutdownGuard

  def start_link(opts) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts) do
      :ok = ShutdownGuard.watch(Keyword.fetch!(opts, :table), pid, :supervisor)
      {:ok, pid}
    end
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: config.shutdown_timeout_ms
    }
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    config = Keyword.fetch!(opts, :config)
    :ok = ShutdownGuard.watch(table, self())

    children = [
      %{
        id: :callback_tasks,
        start: {__MODULE__, :start_tasks, [table, config]},
        type: :supervisor,
        shutdown: config.shutdown_timeout_ms
      },
      {Arbor.MCP.Server.Runtime.OutputController, opts},
      {Arbor.MCP.Server.Runtime.Scheduler, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  def start_tasks(table, config) do
    case Task.Supervisor.start_link(max_children: config.max_concurrency) do
      {:ok, supervisor} = result ->
        :ok = ShutdownGuard.watch(table, supervisor, :supervisor)
        :ets.insert(table, {:callback_tasks, supervisor})
        result

      error ->
        error
    end
  end
end
