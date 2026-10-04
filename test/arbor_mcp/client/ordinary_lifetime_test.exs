defmodule Arbor.MCP.Client.OrdinaryLifetimeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{Lifetime, RequestHandler}

  defmodule HeldHandler do
    @behaviour Arbor.MCP.Client.Handler
    def init(opts), do: {:ok, %{test: opts[:test], count: 0}}
    def handle_ping(state), do: {:ok, %{}, state}
    def handle_list_roots(state), do: {:ok, [], state}

    def handle_create_message(_params, state) do
      Process.flag(:trap_exit, true)
      send(state.test, {:held_callback, self()})

      receive do
        :release -> {:ok, %{}, %{state | count: state.count + 1}}
      end
    end
  end

  defmodule ConcurrentHandler do
    @behaviour Arbor.MCP.Client.Handler
    def init(opts), do: HeldHandler.init(opts)
    def handle_ping(state), do: HeldHandler.handle_ping(state)
    def handle_list_roots(state), do: HeldHandler.handle_list_roots(state)
    def handle_create_message(params, state), do: HeldHandler.handle_create_message(params, state)
    def mrtr_input_concurrency, do: 2
  end

  defmodule HeldProbeTransport do
    @behaviour Arbor.MCP.Transport
    def connect(opts), do: {:ok, %{test: opts[:test], native_owner: self()}}
    def send_message(_message, state), do: {:ok, state}

    def receive_message(state) do
      Process.flag(:trap_exit, true)
      {observer, _token, _epoch} = Lifetime.current()
      true = Map.has_key?(:sys.get_state(observer).workers, self())
      send(state.test, {:held_probe, state.native_owner, self(), observer})

      receive do
        :release -> {:error, :fixture_released}
      end
    end

    def close(_state), do: :ok
    def connected?(_state), do: true
  end

  defmodule HeldConstructionTransport do
    @behaviour Arbor.MCP.Transport

    def connect(opts) do
      {observer, _token, _epoch} = Lifetime.current()
      send(opts[:test], {:held_construction, self(), observer})

      receive do
        :release -> {:error, :fixture_released}
      end
    end

    def send_message(_message, state), do: {:ok, state}
    def receive_message(_state), do: {:error, :closed}
    def close(_state), do: :ok
    def connected?(_state), do: false
  end

  defmodule HeldCloseTransport do
    def close(state) do
      Process.flag(:trap_exit, true)
      send(state.test, {:held_close, self()})

      receive do
        :release_close -> :ok
      end
    end
  end

  defmodule Transport do
    @behaviour Arbor.MCP.Transport
    def connect(opts), do: {:ok, %{test: opts[:test]}}

    def send_message(message, state) do
      send(state.test, {:native_wire, message})
      {:ok, state}
    end

    def receive_message(_state), do: {:error, :closed}
    def close(_state), do: :ok
    def connected?(_state), do: true
  end

  test "the discovery receive fallback is registered before effects and dies with its native owner" do
    test = self()

    parent =
      spawn(fn ->
        Client.start_link(
          transport: HeldProbeTransport,
          test: test,
          protocol_mode: :modern_only,
          client_cleanup_timeout: 100
        )
      end)

    assert_receive {:held_probe, client, worker, observer}, 1_000
    client_monitor = Process.monitor(client)
    worker_monitor = Process.monitor(worker)
    observer_monitor = Process.monitor(observer)
    Process.exit(parent, :parent_gone)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 500
    assert_receive {:DOWN, ^client_monitor, :process, ^client, _reason}, 500
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, _reason}, 500
  end

  test "native parent death bounds blocked construction even if its observer is suspended" do
    test = self()

    parent =
      spawn(fn ->
        Client.start_link(
          transport: HeldConstructionTransport,
          test: test,
          client_cleanup_timeout: 80
        )
      end)

    assert_receive {:held_construction, client, observer}, 1_000
    client_monitor = Process.monitor(client)
    observer_monitor = Process.monitor(observer)
    :erlang.suspend_process(observer)
    Process.exit(parent, :parent_gone)
    assert_receive {:DOWN, ^client_monitor, :process, ^client, :killed}, 500
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :killed}, 500
    assert Process.alive?(self())
  end

  test "ordinary stop confirms a held reverse callback has stopped" do
    client = start_native()
    worker = hold_reverse(client)
    :ok = Client.stop(client)
    assert_down(worker)
  end

  test "hard native client death cannot leave a held reverse callback alive" do
    client = start_native()
    Process.unlink(client)
    worker = hold_reverse(client)
    Process.exit(client, :kill)
    assert_down(worker)
  end

  test "disconnect retires reverse callback maps and cannot accept its late handler state" do
    client = start_native()
    worker = hold_reverse(client)
    assert :ok = Client.disconnect(client)
    assert :sys.get_state(client).server_request_tasks == %{}
    assert_down(worker)
    send(worker, :release)
    refute_receive {:native_wire, _late_response}, 30
    assert {HeldHandler, %{count: 0}} = :sys.get_state(client).client_handler
    Client.stop(client)
  end

  test "disconnect settles a held ordinary MRTR caller and stops its callback" do
    client = start_native()

    :sys.replace_state(client, fn state ->
      %{
        state
        | protocol_version: "2026-07-28",
          transport_opts: Keyword.put(state.transport_opts, :capabilities, %{"sampling" => %{}})
      }
    end)

    task =
      Task.async(fn ->
        GenServer.call(
          client,
          {:fulfill_mrtr, %{"input" => %{"method" => "sampling/createMessage", "params" => %{}}},
           [], make_ref()},
          2_000
        )
      end)

    assert_receive {:held_callback, worker}, 1_000
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert :ok = Client.disconnect(client)
    assert {:error, :client_disconnected} = Task.await(task)
    assert :sys.get_state(client).mrtr_tasks == %{}
    assert_down(worker)
    Client.stop(client)
  end

  test "observer loss force-stops its held owned callback without adopting the client parent" do
    client = start_native()
    Process.unlink(client)
    client_monitor = Process.monitor(client)
    worker = hold_reverse(client)
    {observer, _token, _epoch} = Lifetime.from_client(client)
    Process.exit(observer, :kill)
    assert_down(worker)
    assert_receive {:DOWN, ^client_monitor, :process, ^client, :killed}, 1_000
    assert Process.alive?(self())
  end

  test "concurrent MRTR descendants cannot survive hard ordinary client death" do
    client = start_native()
    test = self()

    :sys.replace_state(client, fn state ->
      %{
        state
        | protocol_version: "2026-07-28",
          client_handler: {ConcurrentHandler, %{test: test, count: 0}},
          transport_opts: Keyword.put(state.transport_opts, :capabilities, %{"sampling" => %{}})
      }
    end)

    caller =
      spawn(fn ->
        send(
          test,
          {:mrtr_outcome,
           catch_exit_call(
             client,
             {:fulfill_mrtr,
              Map.new(
                ["a", "b"],
                &{&1, %{"method" => "sampling/createMessage", "params" => %{}}}
              ), [], make_ref()}
           )}
        )
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:held_callback, first}, 1_000
    assert_receive {:held_callback, second}, 1_000

    for worker <- [first, second],
        do: on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    Process.unlink(client)
    Process.exit(client, :kill)
    assert_down(first)
    assert_down(second)
  end

  test "resource replacement and its opening subscription retire on disconnect" do
    client = start_native()
    test = self()

    subscriber =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(subscriber), do: Process.exit(subscriber, :kill) end)

    :sys.replace_state(client, fn state ->
      ref = Process.monitor(subscriber)

      %{
        state
        | connection_status: :ready,
          protocol_version: "2026-07-28",
          resource_subscriptions: %{
            desired: %{"file:///a" => %{subscriber => 1}, "file:///b" => %{test => 1}},
            active: nil,
            generation: 1
          },
          resource_subscriber_monitors: %{ref => subscriber}
      }
    end)

    Process.exit(subscriber, :kill)
    assert_receive {:native_wire, wire}, 1_000
    assert Jason.decode!(wire)["method"] == "subscriptions/listen"
    {observer, _token, _epoch} = Lifetime.from_client(client)
    owned = :sys.get_state(observer).workers |> Map.keys()
    assert length(owned) >= 2
    assert :ok = Client.disconnect(client)
    for worker <- owned, do: assert_down(worker)
    assert :sys.get_state(client).resource_subscriptions.desired == %{}
    Client.stop(client)
  end

  test "blocked custom close is finite and never reported as successful cleanup" do
    client = start_native()
    :sys.replace_state(client, &%{&1 | transport_mod: HeldCloseTransport})
    task = Task.async(fn -> Client.disconnect(client) end)
    assert_receive {:held_close, closer}, 1_000
    started = System.monotonic_time(:millisecond)
    assert {:error, :client_cleanup_timeout} = Task.await(task, 2_000)
    assert System.monotonic_time(:millisecond) - started < 1_300
    assert_down(closer)
    assert {:error, :client_cleanup_timeout} = Client.stop(client)
  end

  test "queued old-generation library events cannot update current handler state" do
    client = start_native()
    {_observer, _token, epoch} = Lifetime.from_client(client)
    worker = hold_reverse(client)
    assert :ok = Client.disconnect(client)

    send(
      client,
      {:client_lifetime_event, epoch,
       {:server_request_result, worker, {:ok, {:ok, %{}, %{test: self(), count: 99}}}}}
    )

    refute_receive {:native_wire, _late_response}, 30
    assert {HeldHandler, %{count: 0}} = :sys.get_state(client).client_handler
    Client.stop(client)
  end

  test "worker capacity rejects effects before the second callback starts" do
    client = start_native(max_client_workers: 1)
    first = hold_reverse(client)

    :sys.replace_state(client, fn state ->
      {:noreply, next} =
        RequestHandler.handle_server_request("sampling/createMessage", %{}, 8, state)

      next
    end)

    assert_receive {:native_wire, response}, 1_000
    assert Jason.decode!(response)["error"]["code"] == -32603
    refute_receive {:held_callback, _second}, 30
    {observer, _token, _epoch} = Lifetime.from_client(client)
    assert map_size(:sys.get_state(observer).workers) == 1
    assert :ok = Client.stop(client)
    assert_down(first)
  end

  test "ordinary native parent and link stay unchanged and parent death reaps work" do
    test = self()

    parent =
      spawn(fn ->
        {:ok, client} =
          Client.start_link(_skip_connect: true, handler: {HeldHandler, [test: test]})

        send(test, {:native_parent_client, client})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(parent), do: Process.exit(parent, :kill) end)
    assert_receive {:native_parent_client, client}, 1_000
    {:dictionary, dictionary} = Process.info(client, :dictionary)
    assert hd(:proplists.get_value(:"$ancestors", dictionary)) == parent
    assert parent in elem(Process.info(client, :links), 1)
    worker = hold_reverse(client)
    Process.exit(parent, :kill)
    assert_down(client)
    assert_down(worker)
  end

  test "acknowledged internal resource subscription transfers from worker to client lifetime" do
    client = start_native()
    test = self()

    subscriber =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    :sys.replace_state(client, fn state ->
      ref = Process.monitor(subscriber)

      %{
        state
        | connection_status: :ready,
          protocol_version: "2026-07-28",
          resource_subscriptions: %{
            desired: %{"file:///a" => %{subscriber => 1}, "file:///b" => %{test => 1}},
            active: nil,
            generation: 1
          },
          resource_subscriber_monitors: %{ref => subscriber}
      }
    end)

    Process.exit(subscriber, :kill)
    assert_receive {:native_wire, wire}, 1_000
    id = Jason.decode!(wire)["id"]

    send(
      client,
      {:transport_message,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "notifications/subscriptions/acknowledged",
         "params" => %{
           "notifications" => %{"resourceSubscriptions" => ["file:///b"]},
           "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
         }
       })}
    )

    active = wait_active(client)
    {observer, _token, _epoch} = Lifetime.from_client(client)
    assert :sys.get_state(observer).workers[active.pid].persistent?
    assert Process.alive?(active.pid)
    # A transport loss retains the acknowledged logical actor for resubscription;
    # explicit disconnect still confirms its actual DOWN.
    send(client, {:transport_closed, :fixture_loss})
    assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
    assert Process.alive?(active.pid)
    assert :ok = Client.disconnect(client)
    assert_down(active.pid)
    assert :ok = Client.stop(client)
  end

  defp wait_active(client, attempts \\ 100)
  defp wait_active(_client, 0), do: flunk("resource subscription was not committed")

  defp wait_active(client, attempts) do
    case :sys.get_state(client).resource_subscriptions.active do
      nil ->
        Process.sleep(5)
        wait_active(client, attempts - 1)

      active ->
        active
    end
  end

  defp catch_exit_call(client, message) do
    GenServer.call(client, message, 2_000)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp start_native(opts \\ []) do
    test = self()

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [_skip_connect: true, reconnect: false, handler: {HeldHandler, [test: test]}],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: Transport,
          transport_state: %{test: test},
          connection_status: :connected
      }
    end)

    client
  end

  defp hold_reverse(client) do
    :sys.replace_state(client, fn state ->
      {:noreply, next} =
        RequestHandler.handle_server_request("sampling/createMessage", %{}, 7, state)

      next
    end)

    assert_receive {:held_callback, worker}, 1_000
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    worker
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 150
  end
end
