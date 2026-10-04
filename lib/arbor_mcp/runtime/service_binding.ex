defmodule Arbor.MCP.Server.Runtime.ServiceBinding do
  @moduledoc false

  use GenServer

  alias Arbor.MCP.Server.Runtime.ShutdownGuard

  def start_link(%{ownership: :owned} = descriptor, opts) do
    table = Keyword.fetch!(opts, :table)
    remaining = max(1, Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond))

    adapter_opts =
      Keyword.merge(descriptor.options,
        name: nil,
        runtime_table: table,
        init_timeout_ms: remaining
      )

    adapter_opts =
      if descriptor.kind == :subscriptions do
        [{:service_listeners, listeners}] = :ets.lookup(table, :service_listeners)
        Keyword.put(adapter_opts, :listener_supervisor, listeners)
      else
        adapter_opts
      end

    case descriptor.adapter.start_link(adapter_opts) do
      {:ok, pid} = result ->
        if :ets.member(table, {:service_owner, pid}) do
          :ets.delete(table, {:service_owner, pid})
          publish(descriptor, pid, opts)
          result
        else
          Process.exit(pid, :kill)
          {:error, :owned_start_contract_violated}
        end

      error ->
        error
    end
  end

  def start_link(%{ownership: :borrowed} = descriptor, opts) do
    remaining = max(1, Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond))
    GenServer.start_link(__MODULE__, {descriptor, opts}, timeout: remaining)
  end

  @impl true
  def init({descriptor, opts}) do
    :ok = ShutdownGuard.watch(Keyword.fetch!(opts, :table), self())

    with pid when is_pid(pid) <- GenServer.whereis(descriptor.server),
         true <- node(pid) == node() and Process.alive?(pid) do
      monitor = Process.monitor(pid)
      publish(descriptor, pid, opts)
      {:ok, %{monitor: monitor}}
    else
      _invalid -> {:stop, :borrowed_service_unavailable}
    end
  rescue
    ArgumentError -> {:stop, :invalid_borrowed_address}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state),
    do: {:stop, {:borrowed_service_down, reason}, state}

  defp publish(descriptor, pid, opts) do
    binding = Map.merge(descriptor, %{server: pid, generation: Keyword.fetch!(opts, :generation)})
    :ets.insert(Keyword.fetch!(opts, :table), {{:service, descriptor.kind}, binding})
  end
end
