defmodule Arbor.MCP.Internal.SessionStore.DETS do
  @moduledoc false
  @behaviour Arbor.MCP.Internal.SessionStore

  alias Arbor.MCP.Internal.SessionStore.DETS.Error
  alias Arbor.MCP.Internal.SessionStore.DETS.Owner
  alias Arbor.MCP.Internal.SessionStore.DETS.PathClaims

  @default_io_timeout_ms 5_000
  @max_timeout_ms 4_294_967_295

  defstruct [
    :sessions,
    :events,
    :request_ids,
    :meta,
    :path,
    :names,
    :owner,
    :token,
    :gate,
    :io_timeout_ms,
    backend: :dets
  ]

  @impl true
  def open(config) do
    path = Map.get(config, :storage_path) || Map.get(config, :dets_path)
    timeout = Map.get(config, :storage_io_timeout_ms, @default_io_timeout_ms)

    cond do
      not (is_binary(path) and path != "") -> {:error, :storage_path_required}
      not valid_timeout?(timeout) -> {:error, :invalid_storage_io_timeout}
      byte_size(path) > 4_096 -> {:error, :storage_path_too_large}
      true -> open_expanded(path, timeout)
    end
  end

  defp valid_timeout?(timeout),
    do: is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms

  defp open_expanded(path, timeout) do
    expanded = Path.expand(path)

    if byte_size(expanded) <= 4_096,
      do: open_owner(:binary.copy(expanded), timeout),
      else: {:error, :storage_path_too_large}
  end

  defp open_owner(path, timeout) do
    deadline = now() + timeout
    token = make_ref()
    gate = :atomics.new(2, signed: true)
    :atomics.put(gate, 2, 1)

    case Owner.start(self(), token, gate, remaining(deadline)) do
      {:ok, owner} ->
        handle = %__MODULE__{
          owner: owner,
          token: token,
          gate: gate,
          path: path,
          io_timeout_ms: timeout
        }

        case acquire(path, handle, deadline) do
          {:ok, claims} ->
            open_claimed(handle, %{storage_path: path}, claims, deadline)

          {:error, reason} ->
            retire(handle)
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :storage_owner_unavailable}
    end
  end

  defp acquire(path, handle, deadline) do
    case PathClaims.claim(path, handle.owner, self(), handle.token, handle.gate, deadline) do
      {:wait, _other_gate} ->
        if remaining(deadline) > 0 do
          receive do
          after
            min(remaining(deadline), 5) -> acquire(path, handle, deadline)
          end
        else
          {:error, :storage_io_timeout}
        end

      result ->
        result
    end
  end

  defp open_claimed(handle, config, claims, deadline) do
    message = {handle.token, handle.gate, deadline, :open, config, claims}

    case owner_call(handle, message, deadline) do
      {:ok, raw} ->
        {:ok,
         struct!(
           __MODULE__,
           Map.merge(
             Map.from_struct(handle),
             Map.take(Map.from_struct(raw), [:sessions, :events, :request_ids, :meta, :names])
           )
         )}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def close(store) do
    case :atomics.get(store.gate, 1) do
      3 -> :ok
      4 -> {:error, :storage_cleanup_unconfirmed}
      2 -> {:error, :storage_cleanup_pending}
      _active -> close_active(store)
    end
  end

  defp close_active(store) do
    PathClaims.seal(store.gate)

    case :atomics.compare_exchange(store.gate, 2, 0, 1) do
      :ok ->
        deadline = now() + store.io_timeout_ms
        owner_call(store, {store.token, store.gate, deadline, :close, []}, deadline)

      _busy ->
        retire(store)
        {:error, :storage_cleanup_pending}
    end
  end

  @impl true
  def lookup(store, table, key), do: request!(store, :lookup, [table, key])
  @impl true
  def insert(store, table, object), do: request!(store, :insert, [table, object])
  @impl true
  def insert_new(store, table, object), do: request!(store, :insert_new, [table, object])
  @impl true
  def delete(store, table, key), do: request!(store, :delete, [table, key])
  @impl true
  def member(store, table, key), do: request!(store, :member, [table, key])
  @impl true
  def match(store, table, pattern), do: request!(store, :match, [table, pattern])
  @impl true
  def match_delete(store, table, pattern), do: request!(store, :match_delete, [table, pattern])
  @impl true
  def all(store, table), do: request!(store, :all, [table])
  @impl true
  def info(store, table, item), do: request!(store, :info, [table, item])
  @impl true
  def event_clock(store), do: request!(store, :event_clock, [])

  @impl true
  def put_event_clock(store, clock) when is_integer(clock) and clock >= 0 do
    request!(store, :put_event_clock, [clock])
    store
  end

  def with_deadline(store, operation) do
    key = {__MODULE__, store.token}
    previous = Process.get(key)
    deadline = min(previous || now() + store.io_timeout_ms, now() + store.io_timeout_ms)
    Process.put(key, deadline)

    try do
      operation.()
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end

  defp request!(store, operation, arguments) do
    case request(store, operation, arguments) do
      {:ok, value} -> value
      {:error, reason} -> raise Error, operation: operation, reason: reason
    end
  end

  defp request(store, operation, arguments) do
    deadline = Process.get({__MODULE__, store.token}, now() + store.io_timeout_ms)

    cond do
      :atomics.get(store.gate, 1) != 1 ->
        {:error, :storage_closed}

      :atomics.compare_exchange(store.gate, 2, 0, 1) != :ok ->
        {:error, :storage_busy}

      true ->
        owner_call(store, {store.token, store.gate, deadline, operation, arguments}, deadline)
    end
  end

  defp owner_call(store, message, deadline) do
    result =
      try do
        GenServer.call(store.owner, message, remaining(deadline))
      catch
        :exit, {:timeout, _call} -> {:error, :storage_io_timeout}
        :exit, _reason -> {:error, :storage_cleanup_unconfirmed}
      end

    if now() >= deadline or result == {:error, :storage_io_timeout} do
      retire(store)
      {:error, :storage_io_timeout}
    else
      result
    end
  end

  defp retire(store) do
    if PathClaims.seal(store.gate) == :changed, do: send(store.owner, {:retire, store.token})
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
