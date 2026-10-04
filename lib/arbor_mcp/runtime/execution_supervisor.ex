defmodule Arbor.MCP.Server.Runtime.ExecutionSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization}

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)

    with {:ok, context} <- Initialization.begin(table, opts[:config], :runtime),
         {:ok, pid} <-
           Initialization.start_supervisor(__MODULE__, fn -> opts end, context.deadline),
         :ok <- Initialization.watch(table, pid, :supervisor) do
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
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    config = Keyword.fetch!(opts, :config)
    :ok = Initialization.watch(table, self())
    opts = Keyword.put(opts, :execution_supervisor, self())

    children = [
      %{
        id: :callback_tasks,
        start: {__MODULE__, :start_tasks, [table, config]},
        type: :supervisor,
        shutdown: config.shutdown_timeout_ms
      },
      {Arbor.MCP.Server.Runtime.OutputController, opts},
      {Arbor.MCP.Server.Runtime.Scheduler, opts},
      {Initialization.Barrier, [kind: :execution] ++ opts}
    ]

    Supervisor.init(Enum.map(children, &Diagnostics.child_spec/1), strategy: :one_for_all)
  end

  @doc false
  def start_tasks(table, config) do
    with {:ok, _context} <- Initialization.begin(table, config, :execution) do
      case Task.Supervisor.start_link(
             max_children: config.max_concurrency,
             timeout: Initialization.remaining(table)
           ) do
        {:ok, supervisor} = result ->
          :ok = Initialization.watch(table, supervisor, :supervisor)
          :ets.insert(table, {:callback_tasks, supervisor})
          result

        error ->
          error
      end
    end
  end
end
