defmodule Arbor.MCP.Server.Stdio.OutputAuthority.Control do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime.Deadline
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Ref
  @slots 128

  def initialize(table) do
    Enum.each(0..(@slots - 1), &:ets.insert(table, {{:slot, &1}, :free}))
    :ok
  end

  # Fixed slots contain bounded private commands. Payload wakes never carry a
  # frame. A dead or suspended producer cannot leave an unbounded mailbox or a
  # counter increment that lacks an independently reapable record.
  def call(ref, command, deadline) do
    alias_ref = :erlang.alias([:reply])

    try do
      with {:ok, _} <- Ref.validate(ref),
           :ok <- cutoff(deadline),
           {:ok, _slot, entry} <- reserve(Ref.table(ref), command, deadline, alias_ref) do
        monitor = Process.monitor(Ref.pid(ref))

        try do
          published = :atomics.compare_exchange(entry.phase, 1, 0, 1) == :ok
          wake(ref)
          if not published, do: throw(:stdio_output_timeout)

          receive do
            {:stdio_output_reply, token, result} when token == entry.token ->
              if Deadline.now() < deadline, do: result, else: {:error, :stdio_output_timeout}

            {:DOWN, ^monitor, :process, _pid, _reason} ->
              {:error, :stdio_output_unavailable}
          after
            Deadline.remaining(deadline) -> {:error, :stdio_output_timeout}
          end
        after
          :atomics.put(entry.phase, 1, 4)
          :erlang.unalias(alias_ref)
          Process.demonitor(monitor, [:flush])
          flush(entry.token)
          wake(ref)
        end
      end
    after
      :erlang.unalias(alias_ref)
    end
  rescue
    ArgumentError -> {:error, :stdio_output_unavailable}
  catch
    :stdio_output_timeout -> {:error, :stdio_output_timeout}
  end

  def entries(table),
    do: for({{:slot, slot}, entry} <- :ets.tab2list(table), is_map(entry), do: {slot, entry})

  def active?(entry),
    do:
      Deadline.now() < entry.deadline and Process.alive?(entry.caller) and
        :atomics.get(entry.phase, 1) in [1, 2]

  def waiting?(entry), do: :atomics.get(entry.phase, 1) == 2

  def claim(entry), do: :atomics.compare_exchange(entry.phase, 1, 1, 2) == :ok

  def finish(table, slot, entry, result) do
    if active?(entry) and :atomics.compare_exchange(entry.phase, 1, 2, 3) == :ok do
      try do
        send(entry.reply, {:stdio_output_reply, entry.token, result})
      rescue
        ArgumentError -> :ok
      end
    end

    release(table, slot, entry.token)
  end

  def release(table, slot, token) do
    case :ets.lookup(table, {:slot, slot}) do
      [{{:slot, ^slot}, %{token: ^token}}] -> :ets.insert(table, {{:slot, slot}, :free})
      _ -> :ok
    end
  end

  def wake(ref) do
    if :ets.insert_new(Ref.table(ref), {:wake, true}), do: send(Ref.pid(ref), :stdio_output_wake)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp reserve(table, command, deadline, alias_ref) do
    token = make_ref()

    entry = %{
      token: token,
      phase: :atomics.new(1, []),
      caller: self(),
      command: command,
      deadline: deadline,
      reply: alias_ref
    }

    first = :erlang.phash2(token, @slots)

    Enum.reduce_while(0..(@slots - 1), {:error, :stdio_output_busy}, fn offset, error ->
      slot = rem(first + offset, @slots)

      cond do
        Deadline.now() >= deadline ->
          {:halt, {:error, :stdio_output_timeout}}

        :ets.select_replace(table, [
          {{{:slot, slot}, :free}, [], [{:const, {{:slot, slot}, entry}}]}
        ]) == 1 ->
          {:halt, {:ok, slot, entry}}

        true ->
          {:cont, error}
      end
    end)
  end

  defp cutoff(deadline) when is_integer(deadline) do
    if Deadline.remaining(deadline) in 1..4_294_967_295,
      do: :ok,
      else: {:error, :stdio_output_timeout}
  end

  defp cutoff(_), do: {:error, :stdio_output_timeout}

  defp flush(token) do
    receive do
      {:stdio_output_reply, ^token, _} -> flush(token)
    after
      0 -> :ok
    end
  end
end
