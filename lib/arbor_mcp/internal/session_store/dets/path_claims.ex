defmodule Arbor.MCP.Internal.SessionStore.DETS.PathClaims do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Internal.SessionStore.DETS.ClaimIngress
  alias Arbor.MCP.Server.Runtime.Diagnostics

  @latch {__MODULE__, :identity}
  @default_max_stores 128
  @cleanup_timeout_ms 5_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [fn -> opts end]},
      modules: [__MODULE__],
      shutdown: @cleanup_timeout_ms + 100
    }
  end

  def start_link(constructor) when is_function(constructor, 0),
    do: GenServer.start_link(__MODULE__, constructor, name: __MODULE__)

  def start_link(opts), do: start_link(fn -> opts end)

  def claim(path, owner, caller, token, gate, deadline) do
    if bounded_request?(path, owner, caller, token, gate, deadline) do
      claim_bounded(:binary.copy(path), owner, caller, token, gate, deadline)
    else
      {:error, :storage_owner_unavailable}
    end
  end

  defp bounded_request?(path, owner, caller, token, gate, deadline) do
    is_binary(path) and byte_size(path) <= 4_096 and caller == self() and
      is_pid(owner) and node(owner) == node() and is_reference(token) and is_reference(gate) and
      is_integer(deadline) and deadline - System.monotonic_time(:millisecond) <= 4_294_967_295 and
      valid_owner?(owner, caller, token, gate)
  end

  defp claim_bounded(path, owner, caller, token, gate, deadline) do
    pid = Process.whereis(__MODULE__)

    case :persistent_term.get(@latch, nil) do
      %{pid: ^pid} = route when is_pid(pid) ->
        ClaimIngress.request(
          route,
          %{path: path, owner: owner, caller: caller, token: token, gate: gate},
          deadline
        )

      _missing ->
        {:error, :storage_claims_unavailable}
    end
  end

  def release(claims, owner, token), do: send(claims, {:closed, owner, token})

  @impl true
  def init(constructor) do
    Process.flag(:trap_exit, true)
    opts = constructor.()
    max_stores = Keyword.get(opts, :max_stores, @default_max_stores)

    cond do
      not (is_integer(max_stores) and max_stores > 0) ->
        {:stop, :invalid_storage_claim_limit}

      :persistent_term.get(@latch, nil) != nil ->
        {:stop, :storage_claims_identity_lost}

      true ->
        route = ClaimIngress.new()
        :persistent_term.put(@latch, route)
        Process.send_after(self(), :claim_tick, 25)
        {:ok, %{claims: %{}, monitors: %{}, max_stores: max_stores, route: route, cursor: 0}}
    end
  end

  defp process_claim(data, state) do
    if System.monotonic_time(:millisecond) < data.deadline do
      result =
        case Map.get(state.claims, data.path) do
          nil -> admit(data.path, data.owner, data.caller, data.token, data.gate, state)
          claim -> existing(claim, state)
        end

      {:reply, reply, state} = result
      {reply, state}
    else
      {{:error, :storage_io_timeout}, state}
    end
  end

  defp admit(path, owner, caller, token, gate, state) do
    cond do
      map_size(state.claims) >= state.max_stores ->
        {:reply, {:error, :storage_claim_limit}, state}

      not valid_owner?(owner, caller, token, gate) or not Process.alive?(caller) or
          :atomics.get(gate, 1) != 0 ->
        {:reply, {:error, :storage_owner_unavailable}, state}

      true ->
        owner_monitor = Process.monitor(owner)
        caller_monitor = Process.monitor(caller)

        claim = %{
          owner: owner,
          caller: caller,
          token: token,
          gate: gate,
          owner_monitor: owner_monitor,
          caller_monitor: caller_monitor
        }

        state = %{
          state
          | claims: Map.put(state.claims, path, claim),
            monitors:
              state.monitors
              |> Map.put(owner_monitor, {path, :owner})
              |> Map.put(caller_monitor, {path, :caller})
        }

        {:reply, {:ok, self()}, state}
    end
  end

  defp existing(claim, state) do
    if not Process.alive?(claim.caller) do
      if seal(claim.gate) == :changed, do: send(claim.owner, {:retire, claim.token})
    end

    case :atomics.get(claim.gate, 1) do
      2 -> {:reply, {:wait, claim.gate}, state}
      3 -> {:reply, {:wait, claim.gate}, state}
      4 -> {:reply, {:error, :storage_cleanup_unconfirmed}, state}
      _active -> {:reply, {:error, :storage_in_use}, state}
    end
  end

  defp valid_owner?(owner, caller, token, gate) do
    case Process.info(owner, :dictionary) do
      {:dictionary, dictionary} ->
        Keyword.get(dictionary, :arbor_dets_owner) == {token, gate, caller} and
          Keyword.get(dictionary, :"$initial_call") ==
            {Arbor.MCP.Internal.SessionStore.DETS.Owner, :init, 1}

      _missing ->
        false
    end
  end

  @impl true
  def handle_info({:claim_ready, token}, %{route: %{token: token}} = state) do
    :atomics.put(state.route.control, 2, 0)
    {:noreply, consume_claims(state)}
  end

  def handle_info(:claim_tick, state) do
    Process.send_after(self(), :claim_tick, 25)
    {:noreply, consume_claims(state)}
  end

  def handle_info({:closed, owner, token}, state) do
    match =
      Enum.find(state.claims, fn {_path, claim} ->
        claim.owner == owner and claim.token == token
      end)

    case match do
      {path, claim} ->
        if :atomics.get(claim.gate, 1) == 3 do
          {:noreply, remove_claim(path, claim, state)}
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} -> {:noreply, state}
      {{path, :caller}, monitors} -> retire_caller(path, %{state | monitors: monitors})
      {{path, :owner}, monitors} -> retire_owner(path, %{state | monitors: monitors})
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp consume_claims(state) do
    {state, cursor} = ClaimIngress.consume(state.route, state.cursor, state, &process_claim/2)
    if ClaimIngress.pending?(state.route), do: ClaimIngress.wake(state.route)
    %{state | cursor: cursor}
  end

  defp retire_caller(path, state) do
    claim = Map.fetch!(state.claims, path)
    if seal(claim.gate) == :changed, do: send(claim.owner, {:retire, claim.token})
    {:noreply, state}
  end

  defp retire_owner(path, state) do
    claim = Map.fetch!(state.claims, path)

    if :atomics.get(claim.gate, 1) == 3 do
      {:noreply, remove_claim(path, claim, state)}
    else
      :atomics.put(claim.gate, 1, 4)
      {:noreply, state}
    end
  end

  def seal(gate) do
    # Opening has only one forward transition, 0 -> 1. If it wins the first
    # CAS, seal that active phase once without reopening any terminal phase.
    result =
      case :atomics.compare_exchange(gate, 1, 0, 2) do
        :ok -> :ok
        1 -> :atomics.compare_exchange(gate, 1, 1, 2)
        _terminal -> :unchanged
      end

    if result == :ok, do: :changed, else: :unchanged
  end

  defp remove_claim(path, claim, state) do
    Process.demonitor(claim.owner_monitor, [:flush])
    Process.demonitor(claim.caller_monitor, [:flush])

    %{
      state
      | claims: Map.delete(state.claims, path),
        monitors:
          state.monitors
          |> Map.delete(claim.owner_monitor)
          |> Map.delete(claim.caller_monitor)
    }
  end

  @impl true
  def terminate(_reason, state) do
    ClaimIngress.seal(state.route)
    deadline = System.monotonic_time(:millisecond) + @cleanup_timeout_ms

    Enum.each(state.claims, fn {_path, claim} ->
      if seal(claim.gate) == :changed, do: send(claim.owner, {:retire, claim.token})
    end)

    if await_closed(state.claims, deadline), do: :persistent_term.erase(@latch)
    :ok
  end

  defp await_closed(claims, deadline) do
    cond do
      Enum.all?(claims, fn {_path, claim} -> :atomics.get(claim.gate, 1) == 3 end) ->
        true

      Enum.any?(claims, fn {_path, claim} -> :atomics.get(claim.gate, 1) == 4 end) ->
        false

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          min(max(deadline - System.monotonic_time(:millisecond), 0), 5) ->
            await_closed(claims, deadline)
        end
    end
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, :dets_path_claims)
end
