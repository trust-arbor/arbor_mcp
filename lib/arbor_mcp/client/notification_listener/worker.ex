defmodule Arbor.MCP.Client.NotificationListener.Worker do
  @moduledoc false

  # Owns the legacy `resources/subscribe` bookkeeping for one client.
  #
  # Every listener that names a resource URI acquires it here, and every wire
  # operation for those URIs runs in this process, one at a time. That gives
  # two guarantees the listener API relies on: a URI is never subscribed and
  # unsubscribed concurrently, and a listener releases exactly the URIs it
  # acquired, so a failed or rolled-back registration can never take away a
  # subscription another listener holds. Callers of
  # `Arbor.MCP.Client.subscribe_notifications/3` wait on this process, never on the
  # client, so the client loop stays free to serve the requests made here.
  #
  # Two more cases the bookkeeping has to survive. A URI whose re-subscribe
  # after a reconnect failed keeps its refcount, because the listeners still
  # hold it, but is marked lost so the next acquisition goes to the wire again
  # instead of trusting the count. And a listener whose subscriber died
  # between registration and acquisition is released before it ever acquired;
  # that release leaves a tombstone so the late acquisition refuses instead of
  # subscribing URIs nobody will release.
  #
  # The worker is started by the client on the first registration, monitors
  # the client, and stops when the client stops.

  use GenServer

  alias Arbor.MCP.Client.Internal.Request, as: ClientRequest

  alias Arbor.MCP.Internal.RequestParams

  @type uri :: String.t()
  @type listener_id :: reference()

  @spec start(pid()) :: GenServer.on_start()
  def start(client) when is_pid(client), do: GenServer.start(__MODULE__, client)

  @doc """
  Acquires every URI for a listener; all or nothing.

  Returns `{:error, :listener_removed}` when the listener was released before
  it acquired, which happens when its subscriber exited in between.
  """
  @spec acquire(pid(), listener_id(), [uri()], timeout()) ::
          :ok | {:error, uri(), term()} | {:error, :listener_removed}
  def acquire(worker, listener_id, uris, timeout),
    do: GenServer.call(worker, {:acquire, listener_id, uris, timeout}, :infinity)

  @doc "Releases whatever the listener acquired, waiting for any unsubscribe."
  @spec release(pid(), listener_id(), timeout()) :: :ok
  def release(worker, listener_id, timeout),
    do: GenServer.call(worker, {:release, listener_id, timeout}, :infinity)

  @doc "Releases without waiting; used from the client loop."
  @spec release_async(pid(), listener_id(), timeout()) :: :ok
  def release_async(worker, listener_id, timeout),
    do: GenServer.cast(worker, {:release, listener_id, timeout})

  @doc """
  Re-subscribes every held URI after a reconnect and reports the results to
  the client as `{:notification_listeners_resubscribed, results, listener_ids, generation}`.
  """
  @spec resubscribe(pid(), [listener_id()], non_neg_integer(), timeout()) :: :ok
  def resubscribe(worker, listener_ids, generation, timeout),
    do: GenServer.cast(worker, {:resubscribe, listener_ids, generation, timeout})

  @doc "Forgets every acquisition; the server side is gone with the session."
  @spec reset(pid()) :: :ok
  def reset(worker), do: GenServer.cast(worker, :reset)

  @impl true
  def init(client) do
    Process.monitor(client)
    {:ok, %{client: client, counts: %{}, held: %{}, lost: MapSet.new(), removed: MapSet.new()}}
  end

  @impl true
  def handle_call({:acquire, listener_id, uris, timeout}, _from, state) do
    cond do
      MapSet.member?(state.removed, listener_id) ->
        {:reply, {:error, :listener_removed},
         %{state | removed: MapSet.delete(state.removed, listener_id)}}

      uris == [] ->
        {:reply, :ok, %{state | held: Map.put(state.held, listener_id, [])}}

      true ->
        uris = Enum.uniq(uris)

        case do_acquire(state, uris, timeout, []) do
          {:ok, state} ->
            {:reply, :ok, %{state | held: Map.put(state.held, listener_id, uris)}}

          {:error, uri, reason, state, acquired} ->
            {:reply, {:error, uri, reason}, release_uris(state, acquired, timeout)}
        end
    end
  end

  def handle_call({:release, listener_id, timeout}, _from, state) do
    {:reply, :ok, release_listener(state, listener_id, timeout)}
  end

  @impl true
  def handle_cast({:release, listener_id, timeout}, state) do
    {:noreply, release_listener(state, listener_id, timeout)}
  end

  def handle_cast({:resubscribe, listener_ids, generation, timeout}, state) do
    results = Map.new(Map.keys(state.counts), &{&1, subscribe(state.client, &1, timeout)})

    lost =
      for {uri, {:error, _reason}} <- results, into: MapSet.new(), do: uri

    GenServer.cast(
      state.client,
      {:notification_listeners_resubscribed, results, listener_ids, generation}
    )

    {:noreply, %{state | lost: lost}}
  end

  def handle_cast(:reset, state),
    do: {:noreply, %{state | counts: %{}, held: %{}, lost: MapSet.new(), removed: MapSet.new()}}

  @impl true
  def handle_info({:DOWN, _ref, :process, client, _reason}, %{client: client} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp do_acquire(state, [], _timeout, _acquired), do: {:ok, state}

  defp do_acquire(state, [uri | rest], timeout, acquired) do
    count = Map.get(state.counts, uri, 0)

    if count > 0 and not MapSet.member?(state.lost, uri) do
      do_acquire(put_count(state, uri, count + 1), rest, timeout, [uri | acquired])
    else
      case subscribe(state.client, uri, timeout) do
        :ok ->
          state = %{put_count(state, uri, count + 1) | lost: MapSet.delete(state.lost, uri)}
          do_acquire(state, rest, timeout, [uri | acquired])

        {:error, reason} ->
          {:error, uri, reason, state, acquired}
      end
    end
  end

  defp release_listener(state, listener_id, timeout) do
    case Map.pop(state.held, listener_id) do
      {nil, _held} ->
        # Released before it acquired: remember, so the acquisition refuses.
        %{state | removed: MapSet.put(state.removed, listener_id)}

      {uris, held} ->
        release_uris(%{state | held: held}, uris, timeout)
    end
  end

  defp release_uris(state, uris, timeout) do
    Enum.reduce(uris, state, fn uri, acc ->
      case Map.get(acc.counts, uri, 0) do
        0 ->
          acc

        1 ->
          # A lost URI has no server-side subscription to remove.
          unless MapSet.member?(acc.lost, uri) do
            _ = request(acc.client, "resources/unsubscribe", uri, timeout)
          end

          %{acc | counts: Map.delete(acc.counts, uri), lost: MapSet.delete(acc.lost, uri)}

        count ->
          put_count(acc, uri, count - 1)
      end
    end)
  end

  defp put_count(state, uri, count), do: %{state | counts: Map.put(state.counts, uri, count)}

  defp subscribe(client, uri, timeout) do
    case request(client, "resources/subscribe", uri, timeout) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(client, method, uri, timeout) do
    ClientRequest.make_request(
      client,
      method,
      RequestParams.uri(uri),
      [timeout: timeout, format: :map],
      timeout
    )
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
