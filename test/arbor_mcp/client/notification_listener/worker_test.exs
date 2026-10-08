defmodule Arbor.MCP.Client.NotificationListener.WorkerTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.NotificationListener.Worker

  defmodule FakeClient do
    @moduledoc """
    Stands in for `Arbor.MCP.Client` on the worker's request path: records every
    request to the observer and fails `resources/subscribe` for URIs in
    `:failing`. `:failing` can be changed with `set_failing/2`.
    """

    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    def set_failing(client, uris), do: GenServer.call(client, {:set_failing, uris})

    @impl true
    def init(observer), do: {:ok, %{observer: observer, failing: []}}

    @impl true
    def handle_call({:set_failing, uris}, _from, state),
      do: {:reply, :ok, %{state | failing: uris}}

    # make_request consults these after a failed request before giving up.
    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:get_default_timeout, _from, state), do: {:reply, {:ok, 1_000}, state}

    def handle_call({:request, method, %{"uri" => uri} = params, _meta}, _from, state) do
      send(state.observer, {:request, method, params})

      if method == "resources/subscribe" and uri in state.failing,
        do: {:reply, {:error, :refused}, state},
        else: {:reply, {:ok, %{}}, state}
    end

    # The worker reports resubscribe results to its client with a cast.
    @impl true
    def handle_cast(message, state) do
      send(state.observer, {:client_cast, message})
      {:noreply, state}
    end
  end

  setup do
    {:ok, client} = FakeClient.start_link(self())
    {:ok, worker} = Worker.start(client)
    %{client: client, worker: worker}
  end

  test "a release that arrives before the acquisition makes the acquisition refuse",
       %{worker: worker} do
    id = make_ref()

    Worker.release_async(worker, id, 1_000)
    assert {:error, :listener_removed} = Worker.acquire(worker, id, ["test://a"], 1_000)
    refute_received {:request, _method, _params}

    # The tombstone is consumed: the same id can be acquired afterwards.
    assert :ok = Worker.acquire(worker, id, ["test://a"], 1_000)
    assert_received {:request, "resources/subscribe", %{"uri" => "test://a"}}
  end

  test "a URI lost on resubscribe goes back to the wire on the next acquisition",
       %{client: client, worker: worker} do
    first = make_ref()
    second = make_ref()

    assert :ok = Worker.acquire(worker, first, ["test://x"], 1_000)
    assert_received {:request, "resources/subscribe", %{"uri" => "test://x"}}

    FakeClient.set_failing(client, ["test://x"])
    Worker.resubscribe(worker, [first], 1, 1_000)
    assert_receive {:request, "resources/subscribe", %{"uri" => "test://x"}}

    assert_receive {:client_cast,
                    {:notification_listeners_resubscribed, %{"test://x" => {:error, :refused}},
                     [^first], 1}}

    # Still refused: the second listener's acquisition must try the wire and
    # fail, rather than trusting the count the first listener holds.
    assert {:error, "test://x", :refused} = Worker.acquire(worker, second, ["test://x"], 1_000)
    assert_received {:request, "resources/subscribe", %{"uri" => "test://x"}}

    # Once the server accepts again, the acquisition restores the
    # subscription for every holder and the URI is no longer lost.
    FakeClient.set_failing(client, [])
    assert :ok = Worker.acquire(worker, second, ["test://x"], 1_000)
    assert_received {:request, "resources/subscribe", %{"uri" => "test://x"}}

    assert :ok = Worker.release(worker, first, 1_000)
    refute_received {:request, "resources/unsubscribe", _params}

    assert :ok = Worker.release(worker, second, 1_000)
    assert_received {:request, "resources/unsubscribe", %{"uri" => "test://x"}}
  end

  test "releasing the last holder of a lost URI sends no unsubscribe",
       %{client: client, worker: worker} do
    id = make_ref()

    assert :ok = Worker.acquire(worker, id, ["test://gone"], 1_000)
    assert_received {:request, "resources/subscribe", %{"uri" => "test://gone"}}

    FakeClient.set_failing(client, ["test://gone"])
    Worker.resubscribe(worker, [id], 1, 1_000)
    assert_receive {:client_cast, {:notification_listeners_resubscribed, _results, [^id], 1}}

    assert :ok = Worker.release(worker, id, 1_000)
    refute_received {:request, "resources/unsubscribe", _params}

    # A fresh acquisition after that starts from zero and subscribes.
    FakeClient.set_failing(client, [])
    assert :ok = Worker.acquire(worker, make_ref(), ["test://gone"], 1_000)
    assert_receive {:request, "resources/subscribe", %{"uri" => "test://gone"}}
  end

  test "the worker stops when its client stops", %{client: client, worker: worker} do
    monitor = Process.monitor(worker)
    GenServer.stop(client)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end
end
