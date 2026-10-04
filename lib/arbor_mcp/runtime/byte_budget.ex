defmodule Arbor.MCP.Server.Runtime.ByteBudget do
  @moduledoc false

  @lanes [:data, :outgoing, :incoming]

  def reset(table, generation, config) do
    for lane <- @lanes do
      limit = if lane == :data, do: config.max_pending_bytes, else: config.max_control_bytes

      :ets.insert(
        table,
        {{:byte_budget, lane}, %{generation: generation, limit: limit, used: 0, claims: %{}}}
      )
    end

    :ok
  end

  def clear(table) do
    for lane <- @lanes, do: clear_lane(table, {:byte_budget, lane})
    :ok
  end

  # One CAS records both bytes and token ownership. Killing a producer between
  # this operation and candidate publication leaves a reapable slot/token, not
  # an orphaned counter increment. No payload metadata precedes this claim.
  def claim(table, generation, reservation) do
    token = reservation.token
    bytes = reservation.bytes
    key = {:byte_budget, lane(reservation.kind)}

    case :ets.lookup(table, key) do
      [{^key, %{generation: ^generation} = budget}] ->
        cond do
          Map.has_key?(budget.claims, token) ->
            :ok

          budget.used + bytes > budget.limit ->
            {:error, :server_busy}

          true ->
            next = %{
              budget
              | used: budget.used + bytes,
                claims: Map.put(budget.claims, token, %{bytes: bytes, candidate: reservation})
            }

            if replace(table, key, budget, next),
              do: :ok,
              else: claim(table, generation, reservation)
        end

      _ ->
        {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def candidate(table, token) do
    Enum.find_value(@lanes, fn lane ->
      case :ets.lookup(table, {:byte_budget, lane}) do
        [{_key, budget}] ->
          case budget.claims[token] do
            %{candidate: candidate} -> candidate
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  def confirm(table, token) do
    for lane <- @lanes, do: trim_candidate(table, {:byte_budget, lane}, token)
    :ok
  end

  def release(table, token) do
    for lane <- @lanes, do: release_lane(table, {:byte_budget, lane}, token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def used(table) do
    Map.new(@lanes, fn lane ->
      value =
        case :ets.lookup(table, {:byte_budget, lane}) do
          [{_key, budget}] -> budget.used
          _ -> 0
        end

      {lane, value}
    end)
  end

  defp release_lane(table, key, token) do
    case :ets.lookup(table, key) do
      [{^key, budget}] ->
        case Map.pop(budget.claims, token) do
          {nil, _claims} ->
            :ok

          {%{bytes: bytes}, claims} ->
            next = %{budget | used: budget.used - bytes, claims: claims}

            if replace(table, key, budget, next),
              do: :ok,
              else: release_lane(table, key, token)
        end

      _ ->
        :ok
    end
  end

  defp trim_candidate(table, key, token) do
    case :ets.lookup(table, key) do
      [{^key, budget}] ->
        case budget.claims[token] do
          %{candidate: candidate} = claim when not is_nil(candidate) ->
            next = %{budget | claims: Map.put(budget.claims, token, %{claim | candidate: nil})}
            if replace(table, key, budget, next), do: :ok, else: trim_candidate(table, key, token)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp clear_lane(table, key) do
    case :ets.lookup(table, key) do
      [{^key, budget}] ->
        next = %{budget | generation: nil, used: 0, claims: %{}}
        if replace(table, key, budget, next), do: :ok, else: clear_lane(table, key)

      _ ->
        :ok
    end
  end

  defp replace(table, key, previous, next) do
    match =
      {{key, :"$1"}, [{:"=:=", :"$1", {:const, previous}}], [{{{:const, key}, {:const, next}}}]}

    :ets.select_replace(table, [match]) == 1
  end

  defp lane(:edge_control), do: :outgoing
  defp lane(:edge_response), do: :incoming
  defp lane(_kind), do: :data
end
