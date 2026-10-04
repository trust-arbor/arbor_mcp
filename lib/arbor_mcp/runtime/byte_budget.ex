defmodule Arbor.MCP.Server.Runtime.ByteBudget do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.Deadline

  @lanes [:data, :outgoing, :incoming]
  @attempt_limit 512
  @cleanup_budget_ms 5

  def reset(table, generation, config) do
    rows =
      for lane <- @lanes do
        limit = if lane == :data, do: config.max_pending_bytes, else: config.max_control_bytes
        {{:byte_budget, lane}, %{generation: generation, limit: limit, used: 0, claims: %{}}}
      end

    :ets.insert(table, rows)
    :ok
  end

  # Admission alone fences a retired generation, after closing its route and
  # retiring accepted work. A single atomic insert prevents old producer CAS
  # snapshots from resurrecting a lane; lifecycle retirement need not contend.
  def clear(table) do
    rows =
      for lane <- @lanes,
          [{key, budget}] <- [:ets.lookup(table, {:byte_budget, lane})],
          do: {key, %{budget | generation: nil, used: 0, claims: %{}}}

    :ets.insert(table, rows)
    :ets.delete(table, :byte_cleanup_wake)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def cleanup_record(token, producer), do: {{:byte_cleanup, token}, producer, :none}

  def cleanup_record_bytes(token, producer),
    do: :erlang.external_size({{:byte_cleanup, token}, producer, :release})

  # One CAS records bytes and token ownership, after the complete count/control
  # lease is claimed. Every retry retains the original admission cutoff.
  def claim(table, generation, reservation) do
    claim(table, generation, reservation, @attempt_limit)
  end

  defp claim(_table, _generation, _reservation, 0), do: {:error, :server_busy}

  defp claim(table, generation, reservation, attempts) do
    case Deadline.admission_error(reservation) do
      nil -> claim_open(table, generation, reservation, attempts)
      reason -> {:error, reason}
    end
  end

  defp claim_open(table, generation, reservation, attempts) do
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

            case Deadline.admission_error(reservation) do
              nil ->
                if replace(table, key, budget, next),
                  do: :ok,
                  else: claim(table, generation, reservation, attempts - 1)

              reason ->
                {:error, reason}
            end
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

  def confirm(table, token, opts \\ []), do: cleanup(table, token, :trim, opts)
  def release(table, token, opts \\ []), do: cleanup(table, token, :release, opts)

  def release_requested?(table, token) do
    match?(
      [{{:byte_cleanup, ^token}, _producer, :release}],
      :ets.lookup(table, {:byte_cleanup, token})
    )
  end

  def pending(table) do
    :ets.select(table, [
      {{{:byte_cleanup, :"$1"}, :"$2", :"$3"}, [{:"=/=", :"$3", :none}],
       [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  # One wake per owner, with bounded token records retaining the actual retry
  # work. The periodic Admission reaper covers a wake racing its flag removal.
  def reap(table, deadline) do
    :ets.delete(table, :byte_cleanup_wake)

    Enum.reduce_while(pending(table), :ok, fn {token, _producer, operation}, _result ->
      if Deadline.now() >= deadline do
        {:halt, :pending}
      else
        cleanup(table, token, operation, deadline: deadline, notify: false)
        {:cont, :ok}
      end
    end)
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

  defp cleanup(table, token, operation, opts) do
    deadline =
      min(
        Keyword.get(opts, :deadline, Deadline.now() + @cleanup_budget_ms),
        Deadline.now() + @cleanup_budget_ms
      )

    if Deadline.now() >= deadline do
      defer_result(table, token, operation, Keyword.get(opts, :notify, true))
    else
      result =
        Enum.reduce_while(@lanes, @attempt_limit, fn lane, attempts ->
          case update_claim(table, {:byte_budget, lane}, token, operation, deadline, attempts) do
            {:ok, left} -> {:cont, left}
            :pending -> {:halt, :pending}
          end
        end)

      case result do
        :pending ->
          defer_result(table, token, operation, Keyword.get(opts, :notify, true))

        _attempts ->
          finish_cleanup(table, token, operation)
          :ok
      end
    end
  rescue
    ArgumentError -> :ok
  end

  defp defer_result(table, token, operation, notify?) do
    case defer(table, token, operation, notify?) do
      :pending -> {:pending, operation}
      :done -> :ok
    end
  end

  defp update_claim(table, key, token, operation, deadline, attempts) do
    case :ets.lookup(table, key) do
      [{^key, budget}] ->
        case cleanup_claim(budget, token, operation) do
          :unchanged -> {:ok, attempts}
          next -> update_present(table, key, budget, next, token, operation, deadline, attempts)
        end

      _ ->
        {:ok, attempts}
    end
  end

  defp update_present(table, key, budget, next, token, operation, deadline, attempts) do
    cond do
      attempts == 0 or Deadline.now() >= deadline ->
        :pending

      replace(table, key, budget, next) ->
        {:ok, attempts - 1}

      true ->
        update_claim(table, key, token, operation, deadline, attempts - 1)
    end
  end

  defp cleanup_claim(budget, token, :release) do
    case Map.pop(budget.claims, token) do
      {nil, _claims} -> :unchanged
      {%{bytes: bytes}, claims} -> %{budget | used: budget.used - bytes, claims: claims}
    end
  end

  defp cleanup_claim(budget, token, :trim) do
    case budget.claims[token] do
      %{candidate: candidate} = claim when not is_nil(candidate) ->
        %{budget | claims: Map.put(budget.claims, token, %{claim | candidate: nil})}

      _ ->
        :unchanged
    end
  end

  defp defer(table, token, operation, notify?) do
    key = {:byte_cleanup, token}
    previous = if operation == :trim, do: :none, else: :_

    match =
      {{key, :"$1", previous}, [], [{{{:const, key}, :"$1", {:const, operation}}}]}

    if :ets.select_replace(table, [match]) == 1 and notify?, do: wake_owner(table)
    if :ets.member(table, key), do: :pending, else: :done
  end

  defp finish_cleanup(table, token, :release) do
    case :ets.lookup(table, {:byte_cleanup, token}) do
      [{_key, producer, _operation}] ->
        :ets.select_delete(table, [
          {{{:slot, :_}, token, producer}, [], [true]},
          {{{:byte_cleanup, token}, producer, :_}, [], [true]}
        ])

      _ ->
        :ok
    end
  end

  defp finish_cleanup(table, token, :trim) do
    key = {:byte_cleanup, token}
    :ets.select_replace(table, [{{key, :"$1", :trim}, [], [{{{:const, key}, :"$1", :none}}]}])
  end

  defp wake_owner(table) do
    case :ets.lookup(table, :admission) do
      [{:admission, admission}] ->
        if :ets.insert_new(table, {:byte_cleanup_wake, true}),
          do: send(admission, :byte_cleanup)

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
