defmodule Arbor.MCP.Server.Runtime.StoreSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.MCP.Server.Runtime.{ServiceBinding, ShutdownGuard}

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)
    config = Keyword.fetch!(opts, :config)
    generation = make_ref()
    deadline = System.monotonic_time(:millisecond) + config.init_timeout_ms
    :ets.delete(table, :services_generation)

    with {:ok, pid} <-
           Supervisor.start_link(__MODULE__, [generation: generation, deadline: deadline] ++ opts) do
      :ok = ShutdownGuard.watch(table, pid, :supervisor)
      :ets.insert(table, {:services_generation, generation, pid})
      {:ok, pid}
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    :ok = ShutdownGuard.watch(table, self())
    config = Keyword.fetch!(opts, :config)

    for {kind, descriptor} <- config.services do
      :ets.insert(table, {{:service_configured, kind}, descriptor != nil})
    end

    for kind <- [:tasks, :replay_cache, :subscriptions, :resource_subscriptions, :sessions],
        do: :ets.delete(table, {:service, kind})

    children =
      for kind <- [:tasks, :replay_cache, :resource_subscriptions, :sessions],
          descriptor = config.services[kind],
          descriptor != nil do
        service_spec(descriptor, opts)
      end

    children =
      case config.services.subscriptions do
        %{ownership: :owned} = descriptor ->
          children ++
            [
              %{
                id: :subscription_listeners,
                start: {__MODULE__, :start_listeners, [table]},
                type: :supervisor,
                shutdown: config.shutdown_timeout_ms
              },
              service_spec(descriptor, opts)
            ]

        nil ->
          children

        descriptor ->
          children ++ [service_spec(descriptor, opts)]
      end

    # Any permanent service failure must reach Runtime's rest_for_one boundary.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  defp service_spec(descriptor, opts) do
    %{
      id: descriptor.kind,
      start: {ServiceBinding, :start_link, [descriptor, opts]},
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }
  end

  @doc false
  def start_listeners(table) do
    with {:ok, pid} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
      :ok = ShutdownGuard.watch(table, pid, :supervisor)
      :ets.insert(table, {:service_listeners, pid})
      {:ok, pid}
    end
  end
end
