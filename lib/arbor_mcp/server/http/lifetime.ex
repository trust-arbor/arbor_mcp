defmodule Arbor.MCP.Server.HTTP.Lifetime do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.HTTP.CowboyClaims
  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization, Ref, ShutdownGuard}

  def start_link(opts) do
    table = Ref.table(Keyword.fetch!(opts, :runtime))
    GenServer.start_link(__MODULE__, fn -> opts end, timeout: Initialization.remaining(table))
  end

  @impl true
  def init(constructor) do
    opts = constructor.()
    table = Ref.table(Keyword.fetch!(opts, :runtime))

    case Initialization.watch(table, self()) do
      :ok ->
        [{:http_listener, %{listener: listener}}] = :ets.lookup(table, :http_listener)
        :ets.insert(table, {:http_listener_lifetime, self()})

        authority_monitor =
          if opts[:config].http.backend == :cowboy,
            do: Process.monitor(CowboyClaims.guardian(opts[:config].http.lease)),
            else: nil

        {:ok,
         %{table: table, monitor: Process.monitor(listener), authority_monitor: authority_monitor}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    ShutdownGuard.request_stop(state.table, :http_listener_closed)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{authority_monitor: monitor} = state
      ) do
    ShutdownGuard.request_stop(state.table, :http_listener_claims_unavailable)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)
end
