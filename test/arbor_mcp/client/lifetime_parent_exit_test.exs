defmodule Arbor.MCP.Client.LifetimeParentExitTest do
  @moduledoc """
  A client whose parent exits terminates and closes its transport from a
  cleanup worker (`Lifetime.close_async/1`). Its lifetime observer sees the
  parent's exit too, and retires the client's other work. That must not
  refuse or kill the client's own cleanup worker, whichever of the two the
  observer handles first, or the transport is never closed and the worker
  crashes with `:client_generation_retired`.
  """

  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{Deadline, Lifetime}

  defmodule ClosingTransport do
    @moduledoc false
    @behaviour Arbor.MCP.Transport

    def connect(opts), do: {:ok, %{test: opts[:test]}}
    def send_message(_message, state), do: {:ok, state}
    def receive_message(_state), do: {:error, :closed}
    def connected?(_state), do: true

    def close(state) do
      send(state.test, {:transport_closed, self()})
      :ok
    end
  end

  setup do
    parent = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(parent, :kill) end)

    # This test process stands in for the client, the lifetime's owner.
    :ok = Lifetime.install(_lifetime_parent: parent, client_cleanup_timeout: 10_000)
    {observer, _token, _epoch} = Lifetime.current()
    :ok = Lifetime.quiesce(Deadline.after_ms(5_000))

    {:ok, parent: parent, observer: observer}
  end

  test "a cleanup worker reserved before the parent's exit is observed still registers",
       %{parent: parent, observer: observer} do
    # Hold the observer so the owner's reservation is queued first, then the
    # parent's :DOWN, and then the worker's registration. A process can only
    # resume what it suspended, so one helper does both.
    test_pid = self()

    spawn(fn ->
      :erlang.suspend_process(observer)
      send(test_pid, :observer_suspended)
      wait_until(fn -> queued(observer) >= 1 end, timeout: 2_000)
      Process.exit(parent, :kill)
      wait_until(fn -> queued(observer) >= 2 end, timeout: 2_000)
      :erlang.resume_process(observer)
    end)

    assert_receive :observer_suspended

    task = Lifetime.close_async(fn -> :closed end)
    # As the client's bounded close does, so a refused worker is an outcome.
    Process.unlink(task.pid)
    assert {:ok, :closed} = Task.yield(task, 3_000)
  end

  test "a running cleanup worker outlives the parent's exit",
       %{parent: parent, observer: observer} do
    test_pid = self()

    task =
      Lifetime.close_async(fn ->
        send(test_pid, {:closing, self()})

        receive do
          :finish -> :closed
        end
      end)

    Process.unlink(task.pid)
    assert_receive {:closing, worker}, 2_000
    Process.exit(parent, :kill)
    wait_until(fn -> :sys.get_state(observer).parent_retiring? end, timeout: 2_000)

    send(worker, :finish)
    assert {:ok, :closed} = Task.yield(task, 3_000)
  end

  test "a client whose parent exits closes its transport" do
    test_pid = self()

    for _attempt <- 1..20 do
      parent =
        spawn(fn ->
          {:ok, client} =
            Client.start_link(_skip_connect: true, health_check_interval: nil, reconnect: false)

          :sys.replace_state(client, fn state ->
            %{
              state
              | transport_mod: ClosingTransport,
                transport_state: %{test: test_pid},
                connection_status: :ready
            }
          end)

          send(test_pid, {:started, client})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, client}, 2_000
      client_ref = Process.monitor(client)
      Process.exit(parent, :kill)

      assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 5_000
      assert_receive {:transport_closed, _worker}, 1_000
    end
  end

  defp queued(pid) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)
    length
  end
end
