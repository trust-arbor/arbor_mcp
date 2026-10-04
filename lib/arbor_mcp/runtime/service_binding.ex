defmodule Arbor.MCP.Server.Runtime.ServiceBinding do
  @moduledoc false

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceStartup}

  def start_link(%{ownership: :owned} = descriptor, opts) do
    if ServiceStartup.current?(opts[:table], opts[:generation], opts[:deadline]),
      do: start_owned(descriptor, opts),
      else: {:error, :service_start_timeout}
  end

  def start_link(%{ownership: :borrowed} = descriptor, opts) do
    table = Keyword.fetch!(opts, :table)
    deadline = Keyword.fetch!(opts, :deadline)

    if ServiceStartup.current?(table, opts[:generation], deadline) do
      registration_opts =
        Keyword.merge(opts,
          runtime_table: table,
          runtime_service_starter: self(),
          runtime_init_deadline: deadline
        )

      case GenServer.start_link(__MODULE__, {descriptor, registration_opts},
             timeout: ServiceStartup.remaining(deadline)
           ) do
        {:ok, pid} = result ->
          :ets.delete(table, {:service_owner, pid})

          if ServiceStartup.current?(table, opts[:generation], deadline),
            do: result,
            else: {:error, :service_start_timeout}

        error ->
          error
      end
    else
      {:error, :service_start_timeout}
    end
  end

  defp start_owned(descriptor, opts) do
    table = Keyword.fetch!(opts, :table)
    deadline = Keyword.fetch!(opts, :deadline)

    adapter_opts =
      Keyword.merge(descriptor.options,
        name: nil,
        runtime_table: table,
        init_timeout_ms: ServiceStartup.remaining(deadline),
        runtime_init_deadline: deadline
      )

    adapter_opts =
      if descriptor.kind == :subscriptions do
        [{:service_listeners, listeners}] = :ets.lookup(table, :service_listeners)
        Keyword.put(adapter_opts, :listener_supervisor, listeners)
      else
        adapter_opts
      end

    result =
      if ServiceStartup.current?(table, opts[:generation], deadline),
        do:
          descriptor.adapter.start_link(
            Keyword.put(adapter_opts, :runtime_service_starter, self())
          ),
        else: {:error, :service_start_timeout}

    case result do
      {:ok, pid} = result ->
        case :ets.lookup(table, {:service_owner, pid}) do
          [{{:service_owner, ^pid}, %{starter: starter}}] when starter == self() ->
            case publish(descriptor, pid, opts) do
              :ok ->
                :ets.delete(table, {:service_owner, pid})
                result

              {:error, reason} ->
                Process.exit(pid, :kill)
                {:error, reason}
            end

          _unregistered ->
            {:error, :owned_start_contract_violated}
        end

      error ->
        error
    end
  end

  @impl true
  def init({descriptor, opts}) do
    :ok = ServiceAdapter.watch_owned(opts)

    with pid when is_pid(pid) <- GenServer.whereis(descriptor.server),
         true <- node(pid) == node() and Process.alive?(pid) do
      monitor = Process.monitor(pid)

      case publish(descriptor, pid, opts) do
        :ok -> {:ok, %{monitor: monitor}}
        {:error, reason} -> {:stop, reason}
      end
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
    table = Keyword.fetch!(opts, :table)
    generation = Keyword.fetch!(opts, :generation)
    deadline = Keyword.fetch!(opts, :deadline)
    binding = Map.merge(descriptor, %{server: pid, generation: Keyword.fetch!(opts, :generation)})

    native_result =
      if descriptor.kind in [:sessions, :resource_subscriptions] do
        if ServiceStartup.current?(table, generation, deadline),
          do:
            {:ok,
             descriptor.adapter.runtime_service_binding(pid, ServiceStartup.remaining(deadline))},
          else: {:error, :service_start_timeout}
      else
        {:ok, %{}}
      end

    with {:ok, native} <- native_result,
         {:ok, published} <- native_binding(binding, native),
         true <- ServiceStartup.current?(table, generation, deadline) do
      :ets.insert(table, {{:service, descriptor.kind}, published})

      if ServiceStartup.current?(table, generation, deadline) do
        :ok
      else
        :ets.delete(table, {:service, descriptor.kind})
        {:error, :service_start_timeout}
      end
    else
      false -> {:error, :service_start_timeout}
      error -> error
    end
  catch
    :exit, _reason -> {:error, :service_start_timeout}
  end

  defp native_binding(binding, %{address: address, read_address: _read_address} = native)
       when is_map(address) do
    {:ok, Map.merge(binding, native)}
  end

  defp native_binding(binding, native) when is_map(native) and map_size(native) == 0,
    do: {:ok, binding}

  defp native_binding(_binding, _invalid), do: {:error, :invalid_service_address}
end
