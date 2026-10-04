defmodule Arbor.MCP.Server.Runtime.ServiceStore do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceOperation}

  @turn_entries 32

  def start_link(domain, opts) do
    server_opts = [timeout: Keyword.get(opts, :init_timeout_ms, 1_000)]

    server_opts =
      if opts[:name], do: Keyword.put(server_opts, :name, opts[:name]), else: server_opts

    GenServer.start_link(__MODULE__, {domain, opts}, server_opts)
  end

  def binding(server, timeout), do: GenServer.call(server, :service_binding, timeout)

  @impl true
  def init({domain, opts}) do
    with :ok <- ServiceAdapter.watch_owned(opts),
         {:ok, address} <- ServiceOperation.new(opts),
         {:ok, model} <- domain.open(opts) do
      Process.send_after(self(), :service_reap, 25)

      {:ok,
       %{domain: domain, model: model, address: address, operation_offset: 0, reap_offset: 0}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:service_binding, _from, state) do
    {:reply, %{address: state.address, read_address: state.domain.read_address(state.model)},
     state}
  end

  @impl true
  def handle_info(:service_operations, state) do
    ServiceOperation.ready(state.address)
    deadline = ServiceOperation.maintenance_deadline()
    {entries, offset} = turn_entries(state.address, state.operation_offset)

    state =
      Enum.reduce_while(entries, state, fn entry, state ->
        if ServiceOperation.now() < deadline,
          do: {:cont, run_entry(entry, state, deadline)},
          else: {:halt, state}
      end)

    {:noreply, %{state | operation_offset: offset}}
  end

  def handle_info(:service_reap, state) do
    deadline = ServiceOperation.maintenance_deadline()
    cleanup_deadline = min(deadline, ServiceOperation.now() + 2)
    {entries, offset} = turn_entries(state.address, state.reap_offset)

    _cleanup_result =
      Enum.reduce_while(entries, :ok, fn {_token, entry}, :ok ->
        if ServiceOperation.now() < cleanup_deadline do
          if not ServiceOperation.current?(entry),
            do:
              ServiceOperation.finish(
                state.address,
                entry,
                {:error, :operation_timeout},
                cleanup_deadline
              )

          {:cont, :ok}
        else
          {:halt, :ok}
        end
      end)

    state = %{state | model: state.domain.expire(state.model, deadline), reap_offset: offset}
    Process.send_after(self(), :service_reap, 25)

    if Enum.any?(ServiceOperation.entries(state.address), fn {_token, entry} ->
         :atomics.get(entry.phase, 1) == 0 and ServiceOperation.current?(entry)
       end),
       do: send(self(), :service_operations)

    {:noreply, state}
  end

  def handle_info(message, state) do
    {:noreply, %{state | model: state.domain.info(message, state.model)}}
  end

  @impl true
  def terminate(_reason, state), do: state.domain.close(state.model)

  defp run_entry({_token, entry}, state, cleanup_deadline) do
    if ServiceOperation.begin(entry) do
      {operation, args, context} = entry.payload
      {reply, model} = state.domain.apply(operation, args, context, state.model)
      ServiceOperation.finish(state.address, entry, reply, min(cleanup_deadline, entry.deadline))
      %{state | model: model}
    else
      ServiceOperation.finish(
        state.address,
        entry,
        {:error, :operation_timeout},
        cleanup_deadline
      )

      state
    end
  end

  defp turn_entries(address, offset) do
    entries = ServiceOperation.entries(address)
    offset = if entries == [], do: 0, else: rem(offset, length(entries))
    selected = entries |> Enum.drop(offset) |> Enum.take(@turn_entries)
    {selected, offset + length(selected)}
  end
end
