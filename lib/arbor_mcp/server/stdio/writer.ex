defmodule Arbor.MCP.Server.Stdio.Writer do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Initialization, OutputController}
  alias Arbor.MCP.Server.Stdio.OutputAuthority

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(opts[:table]))

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: Keyword.fetch!(opts, :stdio_config).shutdown_timeout_ms
    }

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    :ok = Initialization.watch(table, self())
    :ets.insert(table, {:stdio_writer, self()})
    {:ok, initialization} = Initialization.current(table)
    lease = Keyword.fetch!(opts, :stdio_output_lease)
    :ok = OutputAuthority.bind(lease, Keyword.fetch!(opts, :runtime), initialization.deadline)
    :ets.insert(table, {:stdio_output_lease, lease})
    {:ok, %{table: table, lease: lease}}
  end

  @impl true
  def handle_info({:stdio_write, ticket}, state) do
    with {:ok, initialization} <- Initialization.current(state.table),
         {:ok, wire, deadline} <- OutputController.write_payload(state.table, ticket) do
      # Runtime proxy waits for the endpoint authority's actual physical IO result.
      # Proxy death never releases the authority's retained IO liability.
      result =
        if System.monotonic_time(:millisecond) < deadline,
          do: OutputAuthority.write(state.lease, wire, deadline, initialization.epoch),
          else: {:error, :output_expired}

      OutputController.write_complete(state.table, ticket, result)
      {:noreply, state}
    else
      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}
end
