defmodule Arbor.MCP.Server.Stdio.Writer do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Initialization, OutputController}
  alias Arbor.RPC.StdioFraming

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
    {:ok, %{table: table, device: Keyword.fetch!(opts, :stdio_output)}}
  end

  @impl true
  def handle_info({:stdio_write, ticket}, state) do
    case OutputController.write_payload(state.table, ticket) do
      {:ok, wire, deadline} ->
        # One persistent blocking writer; Controller retains the cutoff.
        result =
          if System.monotonic_time(:millisecond) < deadline,
            do: StdioFraming.write_frame(state.device, wire),
            else: {:error, :output_expired}

        OutputController.write_complete(state.table, ticket, result)
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}
end
