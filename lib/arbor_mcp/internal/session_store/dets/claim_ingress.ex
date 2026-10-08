defmodule Arbor.MCP.Internal.SessionStore.DETS.ClaimIngress do
  @moduledoc false

  @slots 128
  @batch 32

  def new do
    table = :ets.new(__MODULE__, [:set, :public])
    Enum.each(0..(@slots - 1), &:ets.insert(table, {&1, :free}))
    control = :atomics.new(2, signed: true)
    :atomics.put(control, 1, 1)
    %{pid: self(), table: table, control: control, token: make_ref()}
  end

  def request(route, data, deadline) do
    reply = :erlang.alias([:reply])
    tag = make_ref()
    data = Map.merge(data, %{reply: reply, tag: tag, deadline: deadline})

    try do
      case reserve(route, data) do
        {:ok, slot} -> await(route, slot, data)
        error -> error
      end
    after
      cleanup_reply(reply, tag)
    end
  end

  @doc false
  def cleanup_reply(reply, tag) do
    :erlang.unalias(reply)

    receive do
      {^tag, _reply} -> :ok
    after
      0 -> :ok
    end
  end

  defp reserve(route, data) do
    if :atomics.get(route.control, 1) == 1 do
      Enum.reduce_while(0..(@slots - 1), {:error, :storage_claim_overloaded}, fn slot, result ->
        row = {slot, {:reserved, data}}

        if replace(route.table, {slot, :free}, row) do
          wake(route)
          {:halt, {:ok, slot}}
        else
          {:cont, result}
        end
      end)
    else
      {:error, :storage_claims_unavailable}
    end
  rescue
    ArgumentError -> {:error, :storage_claims_unavailable}
  end

  defp await(route, slot, data) do
    remaining = max(data.deadline - System.monotonic_time(:millisecond), 0)

    result =
      receive do
        {tag, reply} when tag == data.tag ->
          if System.monotonic_time(:millisecond) < data.deadline,
            do: reply,
            else: {:error, :storage_io_timeout}
      after
        remaining -> {:error, :storage_io_timeout}
      end

    abandon(route, slot, data)
    result
  end

  defp abandon(route, slot, data) do
    if replace(route.table, {slot, {:reserved, data}}, {slot, {:abandoned, data}}),
      do: wake(route)
  rescue
    ArgumentError -> :ok
  end

  def wake(route) do
    if :atomics.compare_exchange(route.control, 2, 0, 1) == :ok,
      do: send(route.pid, {:claim_ready, route.token})

    :ok
  end

  def consume(route, cursor, state, operation) do
    state =
      Enum.reduce(0..(@batch - 1), state, fn offset, current ->
        consume_slot(route, rem(cursor + offset, @slots), current, operation)
      end)

    {state, rem(cursor + @batch, @slots)}
  end

  defp consume_slot(route, slot, state, operation) do
    case :ets.lookup(route.table, slot) do
      [{^slot, {:reserved, data}} = row] ->
        processing = {slot, {:processing, data}}

        if replace(route.table, row, processing) do
          {reply, state} = operation.(data, state)
          send(data.reply, {data.tag, reply})
          replace(route.table, processing, {slot, :free})
          state
        else
          state
        end

      [{^slot, {:abandoned, _data}} = row] ->
        replace(route.table, row, {slot, :free})
        state

      _free ->
        state
    end
  end

  def pending?(route),
    do: :ets.select_count(route.table, [{{:_, :free}, [], [false]}, {:_, [], [true]}]) > 0

  def seal(route), do: :atomics.put(route.control, 1, 0)

  defp replace(table, expected, replacement),
    do: :ets.select_replace(table, [{expected, [], [{:const, replacement}]}]) == 1
end
