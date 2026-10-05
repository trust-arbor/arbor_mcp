defmodule Arbor.MCP.Server.HTTP.Bandit.ConnectionSlots do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, Ref}
  @limit 1_024
  @opaque reservation :: {:ets.tid(), tuple(), reference(), pid(), reference()}
  @spec reserve(Ref.t(), integer()) :: {:ok, reservation()} | {:error, :max_children}

  def reserve(runtime, deadline) do
    table = Ref.table(runtime)

    with {:ok, %{status: :ready, epoch: epoch}} <- Initialization.current(table),
         true <- Deadline.now() < deadline do
      reap(table)
      claim(table, epoch, deadline, :erlang.phash2(make_ref(), @limit), 64)
    else
      _ -> {:error, :max_children}
    end
  rescue
    ArgumentError -> {:error, :max_children}
  end

  @spec bind(reservation()) :: {:ok, reservation()} | {:error, :max_children}
  def bind({table, key, token, producer, epoch} = reservation) do
    pending = {key, token, producer, nil, epoch}
    active = {key, token, producer, self(), epoch}

    with true <- Process.alive?(producer),
         {:ok, %{status: :ready, epoch: ^epoch}} <- Initialization.current(table),
         1 <- :ets.select_replace(table, [{pending, [], [{:const, active}]}]) do
      {:ok, reservation}
    else
      _ -> {:error, :max_children}
    end
  rescue
    ArgumentError -> {:error, :max_children}
  end

  @spec release(reservation()) :: :ok
  def release({table, key, token, producer, epoch}) do
    # Parent may retire only an unbound construction. A bound actual child
    # retains credit until observed physical DOWN.
    delete_exact(table, {key, token, producer, nil, epoch})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec accepted?(reservation(), pid(), integer()) :: boolean()
  def accepted?({table, key, token, producer, epoch}, pid, deadline) do
    Deadline.now() < deadline and Process.alive?(pid) and
      :ets.lookup(table, key) == [{key, token, producer, pid, epoch}] and
      match?({:ok, %{status: :ready, epoch: ^epoch}}, Initialization.current(table))
  rescue
    ArgumentError -> false
  end

  def stats(runtime) do
    table = Ref.table(runtime)
    reap(table)

    %{
      limit: @limit,
      retained: length(:ets.match_object(table, {{:bandit_connection, :_}, :_, :_, :_, :_}))
    }
  end

  defp claim(_table, _epoch, _deadline, _index, 0), do: {:error, :max_children}

  defp claim(table, epoch, deadline, index, attempts) do
    key = {:bandit_connection, index}
    token = make_ref()
    producer = self()

    cond do
      Deadline.now() >= deadline ->
        {:error, :max_children}

      :ets.insert_new(table, {key, token, producer, nil, epoch}) ->
        if Deadline.now() < deadline do
          {:ok, {table, key, token, producer, epoch}}
        else
          delete_exact(table, {key, token, producer, nil, epoch})
          {:error, :max_children}
        end

      true ->
        claim(table, epoch, deadline, rem(index + 1, @limit), attempts - 1)
    end
  end

  defp reap(table) do
    for {_key, _token, producer, child, _epoch} = row <-
          :ets.match_object(table, {{:bandit_connection, :_}, :_, :_, :_, :_}),
        not Process.alive?(child || producer),
        do: delete_exact(table, row)

    :ok
  end

  defp delete_exact(table, row), do: :ets.select_delete(table, [{row, [], [true]}])
end
