defmodule Arbor.MCP.Server.Runtime.OwnedChild do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{ServiceStartup, ShutdownGuard}

  def specification(descriptor, opts) do
    deadline = Keyword.fetch!(opts, :deadline)

    adapter_opts =
      Keyword.merge(descriptor.options,
        name: nil,
        runtime_table: opts[:table],
        runtime_service_starter: self(),
        runtime_init_deadline: deadline,
        init_timeout_ms: ServiceStartup.remaining(deadline)
      )

    specification = Supervisor.child_spec({descriptor.adapter, adapter_opts}, [])

    specification
    |> Map.put(:id, descriptor.id)
    |> Map.put(:restart, :permanent)
    |> Map.put(:shutdown, opts[:config].shutdown_timeout_ms)
    |> Map.put(
      :start,
      {__MODULE__, :start_link,
       [specification.start, Map.get(specification, :type, :worker), opts]}
    )
  end

  def start_link({module, function, args}, type, opts) do
    table = Keyword.fetch!(opts, :table)
    generation = Keyword.fetch!(opts, :generation)
    deadline = Keyword.fetch!(opts, :deadline)

    if ServiceStartup.current?(table, generation, deadline) do
      result = apply(module, function, args)
      finish_start(result, type, opts)
    else
      {:error, :service_start_timeout}
    end
  end

  defp finish_start({:ok, pid} = result, type, opts), do: validate_start(result, pid, type, opts)

  defp finish_start({:ok, pid, _extra} = result, type, opts),
    do: validate_start(result, pid, type, opts)

  defp finish_start(error, _type, _opts), do: error

  defp validate_start(result, pid, type, opts) do
    table = opts[:table]

    with [{{:service_owner, ^pid}, %{starter: starter}}] <-
           :ets.lookup(table, {:service_owner, pid}),
         true <- starter == self(),
         true <- ServiceStartup.current?(table, opts[:generation], opts[:deadline]),
         :ok <- ShutdownGuard.watch(table, pid, type, opts[:deadline]) do
      :ets.delete(table, {:service_owner, pid})
      result
    else
      false -> {:error, :service_start_timeout}
      [] -> {:error, :owned_start_contract_violated}
      error -> error
    end
  end
end
