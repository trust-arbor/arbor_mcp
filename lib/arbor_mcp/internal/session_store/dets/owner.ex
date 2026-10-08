defmodule Arbor.MCP.Internal.SessionStore.DETS.Owner do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Internal.SessionStore.DETS.PathClaims
  alias Arbor.MCP.Internal.SessionStore.DETS.Raw
  alias Arbor.MCP.Server.Runtime.Diagnostics

  def start(caller, token, gate, timeout) when caller == self() do
    GenServer.start(__MODULE__, fn -> {caller, token, gate} end, timeout: timeout)
  end

  def start(_caller, _token, _gate, _timeout), do: {:error, :storage_owner_unavailable}

  @impl true
  def init(constructor) do
    {caller, token, gate} = constructor.()
    Process.put(:arbor_dets_owner, {token, gate, caller})

    {:ok,
     %{
       caller: caller,
       caller_monitor: Process.monitor(caller),
       claims: nil,
       claims_monitor: nil,
       token: token,
       gate: gate,
       store: nil
     }}
  end

  @impl true
  def handle_call({token, gate, deadline, :open, config, claims}, _from, state)
      when token == state.token and gate == state.gate and state.store == nil do
    state = %{state | claims: claims, claims_monitor: Process.monitor(claims)}

    if valid_deadline?(deadline, state, 0) do
      open_result(config, deadline, state)
    else
      finish_closed({:error, :storage_io_timeout}, state)
    end
  end

  def handle_call({token, gate, deadline, operation, arguments}, _from, state)
      when token == state.token and gate == state.gate do
    cond do
      operation == :close ->
        finish_close(:ok, state)

      not valid_deadline?(deadline, state, 1) ->
        finish_close({:error, :storage_io_timeout}, state)

      true ->
        execute(operation, arguments, deadline, state)
    end
  end

  def handle_call(_message, _from, state),
    do: {:reply, {:error, :storage_owner_unavailable}, state}

  defp open_result(config, deadline, state) do
    config = Map.put(config, :dets_operation_live?, fn -> valid_deadline?(deadline, state, 0) end)

    case safely(fn -> Raw.open(config) end) do
      {:ok, {:ok, store}} ->
        state = %{state | store: store}

        if valid_deadline?(deadline, state, 0) and
             :atomics.compare_exchange(state.gate, 1, 0, 1) == :ok do
          :atomics.put(state.gate, 2, 0)
          {:reply, {:ok, store}, state}
        else
          finish_close({:error, :storage_io_timeout}, state)
        end

      {:ok, {:error, {:storage_cleanup_unconfirmed, _reason} = reason}} ->
        finish_uncertain({:error, reason}, state)

      {:ok, {:error, reason}} ->
        finish_closed({:error, reason}, state)

      {:error, _reason} ->
        finish_uncertain({:error, :storage_io_failed}, state)
    end
  end

  defp execute(operation, arguments, deadline, state) do
    case safely(fn -> apply(Raw, operation, [state.store | arguments]) end) do
      {:ok, value} ->
        if valid_deadline?(deadline, state, 1) do
          :atomics.put(state.gate, 2, 0)
          {:reply, {:ok, value}, state}
        else
          finish_close({:error, :storage_io_timeout}, state)
        end

      {:error, _reason} ->
        finish_close({:error, :storage_io_failed}, state)
    end
  end

  defp valid_deadline?(deadline, state, phase) do
    :atomics.get(state.gate, 1) == phase and
      System.monotonic_time(:millisecond) < deadline and
      Process.alive?(state.caller) and Process.alive?(state.claims)
  end

  defp safely(operation) do
    {:ok, operation.()}
  rescue
    _error -> {:error, :storage_io_failed}
  catch
    _kind, _reason -> {:error, :storage_io_failed}
  end

  defp finish_close(reply, %{store: nil} = state), do: finish_closed(reply, state)

  defp finish_close(reply, state) do
    PathClaims.seal(state.gate)

    case safely(fn -> Raw.close(state.store) end) do
      {:ok, :ok} -> finish_closed(reply, state)
      _unconfirmed -> finish_uncertain({:error, :storage_cleanup_unconfirmed}, state)
    end
  end

  defp finish_closed(reply, state) do
    :atomics.put(state.gate, 1, 3)
    if state.claims, do: PathClaims.release(state.claims, self(), state.token)
    {:stop, :normal, reply, state}
  end

  defp finish_uncertain(reply, state) do
    :atomics.put(state.gate, 1, 4)
    {:stop, :normal, reply, state}
  end

  @impl true
  def handle_info({:retire, token}, %{token: token} = state), do: stop_after_close(state)

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.caller_monitor or monitor == state.claims_monitor do
    stop_after_close(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp stop_after_close(state) do
    case finish_close(:ok, state) do
      {:stop, reason, _reply, state} -> {:stop, reason, state}
    end
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, :dets_owner)
end
