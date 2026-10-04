defmodule Arbor.MCP.Server.Stdio.Reader do
  @moduledoc false
  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Server.Runtime.{Admission, Deadline, Initialization, ShutdownGuard}
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
    {:ok, initialization} = Initialization.current(table)
    config = Keyword.fetch!(opts, :stdio_config)

    {:ok,
     %{
       table: table,
       initialization: initialization,
       runtime: Keyword.fetch!(opts, :runtime),
       device: Keyword.fetch!(opts, :stdio_input),
       limit: config.max_request_bytes,
       timeout: config.request_timeout_ms,
       eof_timeout: Keyword.fetch!(opts, :stdio_eof_timeout_ms),
       delay: Keyword.fetch!(opts, :stdio_startup_delay)
     }, {:continue, :read}}
  end

  @impl true
  def handle_continue(:read, state) do
    case await_ready(state.table, state.initialization) do
      :ok ->
        Process.sleep(state.delay)
        [{:edge, edge}] = :ets.lookup(state.table, :edge)
        [{:edge_connection, ^edge, connection}] = :ets.lookup(state.table, :edge_connection)
        read_loop(state, edge, connection, true)
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp await_ready(table, %{epoch: epoch, deadline: deadline} = initialization) do
    case Initialization.current(table) do
      {:ok, %{epoch: ^epoch, status: :ready}} ->
        :ok

      {:ok, %{epoch: ^epoch, status: :starting}} ->
        if Deadline.now() < deadline do
          Process.sleep(min(5, Deadline.remaining(deadline)))
          await_ready(table, initialization)
        else
          {:error, :runtime_init_timeout}
        end

      _unavailable ->
        {:error, :runtime_init_timeout}
    end
  end

  defp read_loop(state, edge, connection, first?) do
    mode = StdioFraming.mode(state.device)

    case read_frame(state.device, mode, state.limit, [], 0) do
      {:ok, line, eof?} ->
        line = if first?, do: StdioFraming.strip_bom(line), else: line

        case admit(line, state, edge, connection) do
          :ok when eof? -> finish(state, edge, connection, :eof)
          :ok -> read_loop(state, edge, connection, false)
          {:error, reason} -> finish(state, edge, connection, reason)
        end

      :eof ->
        finish(state, edge, connection, :eof)

      {:error, reason} ->
        finish(state, edge, connection, reason)
    end
  end

  defp read_frame(device, mode, limit, parts, bytes) do
    case StdioFraming.read_unit(device, mode) do
      {:ok, unit} when bytes + byte_size(unit) > limit -> {:error, :request_too_large}
      {:ok, "\n"} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary(), false}
      {:ok, unit} -> read_frame(device, mode, limit, [unit | parts], bytes + byte_size(unit))
      :eof when bytes == 0 -> :eof
      :eof -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary(), true}
      {:error, _reason} -> {:error, :stdin_error}
    end
  end

  defp admit(line, state, edge, connection) do
    case Jason.decode(String.trim(line)) do
      {:ok, request} ->
        retry_admit(request, state, edge, connection, Deadline.after_ms(state.timeout))

      {:error, _} ->
        :ok
    end
  end

  defp retry_admit(request, state, edge, connection, deadline) do
    remaining = Deadline.remaining(deadline)

    if remaining == 0 do
      {:error, :stdio_admission_timeout}
    else
      case HandlerServer.ingress(state.runtime, edge, connection, request,
             timeout: remaining,
             admission_deadline: deadline
           ) do
        {:error, :server_busy} ->
          Process.sleep(min(20, remaining))
          retry_admit(request, state, edge, connection, deadline)

        result ->
          result
      end
    end
  end

  defp finish(state, edge, connection, reason) do
    # Final confirmation/publication precedes this fence in the same reader.
    deadline = Deadline.after_ms(state.eof_timeout)
    ShutdownGuard.begin_drain(state.table, edge, connection, deadline)

    case Admission.seal_input(state.table, edge, connection) do
      :ok ->
        send(edge, {:stdio_input_closed, connection, reason, deadline})

      error ->
        send(edge, {:stdio_input_closed, connection, {:input_seal_failed, error}, deadline})
    end
  end
end
