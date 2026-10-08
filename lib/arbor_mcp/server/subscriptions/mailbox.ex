defmodule Arbor.MCP.Server.Subscriptions.Mailbox do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Deadline, OutputCodec}

  @attempts 512
  @cleanup_ms 5
  @pending 1
  @processing 2
  @queued 3
  @offered 4
  @released 5
  @checked_out 6

  defstruct [:table, :owner, :identity]
  @opaque t :: %__MODULE__{}

  def new(opts) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    identity = make_ref()
    owner = self()

    :ets.insert(table, {
      :state,
      %{
        owner: owner,
        identity: identity,
        max_count: Keyword.fetch!(opts, :max_count),
        max_bytes: Keyword.fetch!(opts, :max_bytes),
        max_message_bytes: Keyword.fetch!(opts, :max_message_bytes),
        max_term_bytes:
          Keyword.get(opts, :max_term_bytes, Keyword.fetch!(opts, :max_message_bytes)),
        bytes: 0,
        entries: %{}
      }
    })

    %__MODULE__{table: table, owner: owner, identity: identity}
  end

  # Payloads enter the shared bounded row before any control message is sent.
  # Phase cells are allocated once per offer, never once per failed CAS retry.
  def offer(ref, payload, origin, deadline, mode) do
    with {:ok, state} <- state(ref),
         :ok <- open(deadline),
         {:ok, prepared} <-
           OutputCodec.prepare(payload,
             max_frame_bytes: state.max_message_bytes,
             max_term_bytes: state.max_term_bytes,
             deadline: deadline,
             codec: :protocol
           ) do
      id = make_ref()
      phase = :atomics.new(2, signed: false)
      :atomics.put(phase, 1, @pending)

      entry = %{
        id: id,
        producer: self(),
        payload: prepared.term,
        origin: origin,
        deadline: deadline,
        mode: mode,
        order: System.unique_integer([:positive, :monotonic]),
        phase: phase
      }

      bytes = :erlang.external_size(entry) + 128
      entry = Map.put(entry, :bytes, bytes)

      with :ok <- insert(ref, entry, @attempts), do: {:ok, id}
    end
  end

  def wake(ref) do
    with {:ok, _state} <- state(ref) do
      if :ets.insert_new(ref.table, {:wake, ref.identity}),
        do: send(ref.owner, {:subscription_mailbox_ready, ref.identity})

      :ok
    end
  rescue
    ArgumentError -> {:error, :subscription_unavailable}
  end

  def clear_wake(ref), do: :ets.delete(ref.table, :wake)

  def pending(ref, mode) do
    case owned_state(ref) do
      {:ok, state} ->
        state.entries
        |> Map.values()
        |> Enum.filter(&(mode?(&1.mode, mode) and phase(&1) == @pending))
        |> Enum.sort_by(& &1.order)
        |> Enum.map(& &1.id)

      _ ->
        []
    end
  end

  def take(ref, id), do: transition(ref, id, @pending, @processing)
  def queue(ref, id), do: transition(ref, id, @processing, @queued)
  def offer_delivery(ref, id), do: transition(ref, id, @queued, @offered)
  def checkout(ref, id), do: transition(ref, id, @offered, @checked_out)

  def entry(ref, id) do
    with {:ok, state} <- owned_state(ref),
         %{id: ^id} = entry <- state.entries[id],
         false <- phase(entry) == @released,
         do: {:ok, entry},
         else: (_ -> {:error, :subscription_expired})
  end

  def active?(ref, id) do
    case entry(ref, id) do
      {:ok, entry} -> Deadline.remaining(entry.deadline) > 0 and :atomics.get(entry.phase, 2) == 0
      _ -> false
    end
  end

  def finish(ref, id) do
    with {:ok, entry} <- entry(ref, id) do
      :atomics.put(entry.phase, 1, @released)
      clean(ref, Deadline.after_ms(@cleanup_ms), @attempts)
    end

    :ok
  end

  # A timed-out producer can retract only an unclaimed record. Once the owner
  # holds a payload, its charge survives until actual completion or owner DOWN.
  def abort(ref, id) do
    with {:ok, state} <- state(ref),
         %{producer: producer} = entry <- state.entries[id],
         true <- producer == self() do
      :atomics.put(entry.phase, 2, 1)
      :atomics.compare_exchange(entry.phase, 1, @pending, @released)
      wake(ref)
    else
      _ -> :ok
    end
  end

  def reap(ref) do
    with {:ok, state} <- owned_state(ref) do
      for entry <- Map.values(state.entries), Deadline.remaining(entry.deadline) == 0 do
        :atomics.put(entry.phase, 2, 1)

        for expected <- [@pending, @queued, @offered],
            do: :atomics.compare_exchange(entry.phase, 1, expected, @released)
      end

      clean(ref, Deadline.after_ms(@cleanup_ms), @attempts)
    end

    :ok
  end

  def stats(ref) do
    case state(ref) do
      {:ok, state} -> %{count: map_size(state.entries), bytes: state.bytes}
      _ -> %{count: 0, bytes: 0}
    end
  end

  def identity(%__MODULE__{identity: identity}), do: identity

  defp insert(_ref, _entry, 0), do: {:error, :subscription_busy}

  defp insert(ref, entry, attempts) do
    with :ok <- open(entry.deadline),
         {:ok, state} <- state(ref) do
      cond do
        map_size(state.entries) >= state.max_count -> {:error, :subscription_busy}
        state.bytes + entry.bytes > state.max_bytes -> {:error, :subscription_busy}
        true -> insert_open(ref, entry, state, attempts)
      end
    end
  end

  defp insert_open(ref, entry, state, attempts) do
    next = %{
      state
      | entries: Map.put(state.entries, entry.id, entry),
        bytes: state.bytes + entry.bytes
    }

    if replace(ref, state, next), do: :ok, else: insert(ref, entry, attempts - 1)
  end

  defp transition(ref, id, expected, next) do
    with {:ok, entry} <- entry(ref, id),
         true <- active?(ref, id),
         :ok <- :atomics.compare_exchange(entry.phase, 1, expected, next),
         do: {:ok, entry},
         else: (_ -> {:error, :subscription_expired})
  end

  defp clean(_ref, _deadline, 0), do: :pending

  defp clean(ref, deadline, attempts) do
    with {:ok, state} <- owned_state(ref) do
      entries = Map.reject(state.entries, fn {_id, entry} -> phase(entry) == @released end)

      cond do
        map_size(entries) == map_size(state.entries) -> :ok
        Deadline.remaining(deadline) == 0 -> :pending
        true -> clean_open(ref, state, entries, deadline, attempts)
      end
    end
  end

  defp clean_open(ref, state, entries, deadline, attempts) do
    bytes = Enum.reduce(entries, 0, fn {_id, entry}, sum -> sum + entry.bytes end)
    next = %{state | entries: entries, bytes: bytes}
    if replace(ref, state, next), do: :ok, else: clean(ref, deadline, attempts - 1)
  end

  defp owned_state(%__MODULE__{owner: owner} = ref) when owner == self(), do: state(ref)
  defp owned_state(_ref), do: {:error, :invalid_subscription_owner}

  defp state(%__MODULE__{table: table, owner: owner, identity: identity}) do
    case :ets.lookup(table, :state) do
      [{:state, %{owner: ^owner, identity: ^identity} = state}] ->
        if Process.alive?(owner), do: {:ok, state}, else: {:error, :subscription_unavailable}

      _ ->
        {:error, :subscription_unavailable}
    end
  rescue
    ArgumentError -> {:error, :subscription_unavailable}
  end

  defp state(_ref), do: {:error, :subscription_unavailable}
  defp phase(entry), do: :atomics.get(entry.phase, 1)
  defp mode?({kind, _target}, kind), do: true
  defp mode?(mode, mode), do: true
  defp mode?(_mode, _expected), do: false

  defp replace(ref, previous, next) do
    :ets.select_replace(ref.table, [
      {{:state, :"$1"}, [{:"=:=", :"$1", {:const, previous}}], [{{:state, {:const, next}}}]}
    ]) == 1
  end

  defp open(deadline) when is_integer(deadline) do
    if Deadline.remaining(deadline) > 0,
      do: :ok,
      else: {:error, :subscription_expired}
  end

  defp open(_), do: {:error, :invalid_subscription_deadline}
end
