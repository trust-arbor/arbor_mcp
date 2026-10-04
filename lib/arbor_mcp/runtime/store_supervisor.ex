defmodule Arbor.MCP.Server.Runtime.StoreSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.MCP.Server.Runtime.{Deadline, ServiceBinding, ServiceStartup}

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)
    config = Keyword.fetch!(opts, :config)
    generation = make_ref()
    deadline = Deadline.now() + config.init_timeout_ms
    :ets.delete(table, :services_generation)
    :ets.insert(table, {:services_startup, generation, deadline, :starting})

    with {:ok, observer} <- ServiceStartup.arm(table, generation, deadline) do
      try do
        startup_opts =
          [
            generation: generation,
            deadline: deadline,
            runtime_table: table,
            runtime_service_starter: self(),
            runtime_init_deadline: deadline
          ] ++ opts

        result =
          if ServiceStartup.current?(table, generation, deadline),
            do: Supervisor.start_link(__MODULE__, startup_opts),
            else: {:error, :service_start_timeout}

        case result do
          {:ok, pid} ->
            if ServiceStartup.current?(table, generation, deadline) do
              :ets.insert(table, {:services_generation, generation, pid})

              if ServiceStartup.current?(table, generation, deadline) do
                :ets.insert(table, {:services_startup, generation, deadline, :ready})

                if Deadline.now() < deadline do
                  :ets.delete(table, {:service_owner, pid})
                  {:ok, pid}
                else
                  ServiceStartup.abort_cohort(table, generation, deadline)
                  {:error, :service_start_timeout}
                end
              else
                ServiceStartup.abort_cohort(table, generation, deadline)
                {:error, :service_start_timeout}
              end
            else
              ServiceStartup.abort_cohort(table, generation, deadline)
              {:error, :service_start_timeout}
            end

          error ->
            ServiceStartup.abort_cohort(table, generation, deadline)
            if Deadline.now() >= deadline, do: {:error, :service_start_timeout}, else: error
        end
      after
        ServiceStartup.disarm(table, generation, observer)
      end
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
    :ok = ServiceStartup.register(table, self(), opts[:runtime_service_starter], opts[:deadline])
    :ets.insert(table, {{:service_cohort_pid, self()}, opts[:generation]})
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
                start: {__MODULE__, :start_listeners, [opts]},
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
  def start_listeners(opts) do
    table = Keyword.fetch!(opts, :table)
    deadline = Keyword.fetch!(opts, :deadline)
    generation = Keyword.fetch!(opts, :generation)

    with true <- ServiceStartup.current?(table, generation, deadline),
         {:ok, pid} <- DynamicSupervisor.start_link(strategy: :one_for_one),
         :ok <- ServiceStartup.register(table, pid, self(), deadline),
         true <- ServiceStartup.current?(table, generation, deadline) do
      :ets.delete(table, {:service_owner, pid})
      :ets.insert(table, {:service_listeners, pid})

      if ServiceStartup.current?(table, generation, deadline),
        do: {:ok, pid},
        else: {:error, :service_start_timeout}
    else
      false -> {:error, :service_start_timeout}
      error -> error
    end
  end
end
