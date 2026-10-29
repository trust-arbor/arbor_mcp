defmodule Arbor.MCP.Client.StdioReconnectCleanupTest do
  @moduledoc """
  Each stdio connection runs its own server process, so reconnecting starts
  a new one. That must never happen while a server an earlier connection or
  attempt opened may still be running (it could hold the port or lock the
  new one needs): the old one is closed first, and when that close cannot
  be confirmed the client stops reconnecting, settles in `:disconnected`
  and reports why.

  A close is made unconfirmable by suspending the server's stdio actor, so
  closing it times out.
  """

  use ExUnit.Case, async: true

  import Arbor.MCP.Test.ScriptedStdioServer, only: [methods: 1, start_client: 4, starts: 1]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.ConnectionManager
  alias Arbor.MCP.TestHelpers

  @moduletag :tmp_dir

  setup do
    Process.flag(:trap_exit, true)
    test_pid = self()
    handler_id = "stdio-reconnect-cleanup-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:arbor_mcp, :client, :reconnect, :success],
        [:arbor_mcp, :client, :reconnect, :cleanup_unconfirmed]
      ],
      fn [_, _, _, outcome], _measurements, metadata, _config ->
        send(test_pid, {:reconnect, outcome, metadata.pid, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "a health check that gives up on a hung server" do
    test "stops that server before reconnecting", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "hung.log")

      {:ok, client} =
        start_client(:once, :modern_only, log,
          health_check_interval: 200,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop(client) end)
      %{transport_state: %{os_pid: hung}} = :sys.get_state(client)

      # The server answers only its probe, so a ping goes unanswered and the
      # next tick tears the connection down and reconnects.
      assert_receive {:reconnect, :success, ^client, _metadata}, 10_000
      refute os_process_alive?(hung), "the hung server outlived its connection"
      assert starts(log) >= 2
    end

    test "does not reconnect when that server cannot be confirmed stopped",
         %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "hung-unconfirmed.log")

      {:ok, client} =
        start_client(:once, :modern_only, log,
          health_check_interval: 300,
          cleanup_timeout: 600,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop(client) end)

      # Once the first ping has been read, keep the server's actor from
      # answering anything, closing included.
      TestHelpers.wait_until(fn -> length(methods(log)) >= 2 end, timeout: 5_000)
      [actor] = stdio_actors(client)
      true = :erlang.suspend_process(actor)

      assert_receive {:reconnect, :cleanup_unconfirmed, ^client, metadata}, 10_000
      assert {:server_stop_unconfirmed, {:error, _cleanup}} = metadata.reason
      refute_received {:reconnect, :success, ^client, _metadata}

      assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
      assert starts(log) == 1
      assert {:error, _cleanup} = Client.stop(client)
    end
  end

  describe "a cleanup failure that is not the server's" do
    # Only the server process's own stop decides: a worker or a reliability
    # component that failed to stop leaves no server running.
    test "does not stop the reconnect", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "auxiliary.log")

      {:ok, client} =
        start_client(:once, :modern_only, log,
          health_check_interval: 200,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop(client) end)
      :sys.replace_state(client, &%{&1 | cleanup_result: {:error, :auxiliary_cleanup_failed}})

      assert_receive {:reconnect, :success, ^client, _metadata}, 10_000
      refute_received {:reconnect, :cleanup_unconfirmed, ^client, _metadata}
    end

    test "is told apart from the server's in a close result" do
      assert ConnectionManager.server_stop_result(:ok) == :ok
      # The reliability wrapper tags a component that would not stop.
      assert ConnectionManager.server_stop_result({:error, {:reliability_cleanup, :timeout}}) ==
               :ok

      assert ConnectionManager.server_stop_result({:error, :timeout}) == {:error, :timeout}
    end

    test "inside the reliability wrapper, the server's own stop still decides",
         %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "wrapped-unconfirmed.log")

      {:ok, client} =
        start_client(:once, :modern_only, log,
          reliability: [circuit_breaker: [failure_threshold: 5]],
          health_check_interval: 300,
          cleanup_timeout: 600,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop(client) end)
      TestHelpers.wait_until(fn -> length(methods(log)) >= 2 end, timeout: 5_000)
      [actor] = stdio_actors(client)
      true = :erlang.suspend_process(actor)

      assert_receive {:reconnect, :cleanup_unconfirmed, ^client, _metadata}, 10_000
      refute_received {:reconnect, :success, ^client, _metadata}
      assert starts(log) == 1
    end
  end

  describe "a health check in a connection scope" do
    # There the native close runs in the client's own process; a teardown
    # the client starts itself is still bounded by its cleanup budget, and
    # running out of it counts as unconfirmed.
    test "gives up on an unconfirmed close within the cleanup budget", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "scoped.log")
      command = Arbor.MCP.Test.ScriptedStdioServer.command(:once, log)

      result =
        Client.with_connection(
          {:stdio, command: command},
          [
            protocol_mode: :modern_only,
            health_check_interval: 300,
            reconnect: true,
            reconnect_backoff: [initial: 10, max: 40],
            # The client's own cleanup budget, well short of the 3.5 s the
            # stdio close of a stuck server takes.
            client_cleanup_timeout: 1_000
          ],
          fn client ->
            TestHelpers.wait_until(fn -> length(methods(log)) >= 2 end, timeout: 5_000)
            [actor] = stdio_actors(client)
            true = :erlang.suspend_process(actor)
            suspended = System.monotonic_time(:millisecond)

            assert_receive {:reconnect, :cleanup_unconfirmed, ^client, metadata}, 10_000
            elapsed = System.monotonic_time(:millisecond) - suspended

            # One 300 ms health-check interval, then a close cut off at the
            # 1 s budget; the stdio close itself would take 3.5 s.
            assert elapsed < 3_000, "the client was held for #{elapsed} ms"
            assert {:server_stop_unconfirmed, {:error, _cleanup}} = metadata.reason
            assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
            :done
          end
        )

      assert result in [{:ok, :done}] or match?({:error, {:cleanup_failed, _, :done}}, result)
      assert starts(log) == 1
    end
  end

  describe "a stuck reliability component" do
    # The wrapper closes the server first and then waits up to 500 ms for
    # each component, longer than the client's cleanup budget here, so the
    # client cuts that close off. The client then stops its own components
    # itself, and the stuck one is killed: it used to outlive the client.
    test "doesn't keep the server from being stopped", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "stuck-component.log")

      {:ok, client} =
        start_client(:modern, :modern_only, log,
          reliability: [circuit_breaker: [failure_threshold: 5]],
          client_cleanup_timeout: 300
        )

      on_exit(fn -> stop(client) end)

      %{transport_state: %{circuit_breaker_pid: breaker, wrapped_state: %{os_pid: os_pid}}} =
        :sys.get_state(client)

      stick(breaker)
      breaker_ref = Process.monitor(breaker)

      # The wrapper's own wait for the breaker outlasts the budget, so the
      # client gives up on the close; the server's stop came first.
      assert Client.disconnect(client) in [:ok, {:error, :client_cleanup_timeout}]

      assert_receive {:DOWN, ^breaker_ref, :process, ^breaker, :killed}
      TestHelpers.wait_until(fn -> not os_process_alive?(os_pid) end, timeout: 2_000)
    end

    # With 20 ms there is no time for a graceful stop at all. (Whether the
    # server's own stop is reached within 20 ms is up to the scheduler.)
    test "is killed at once when too little of the budget is left to wait",
         %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "stuck-component-short.log")

      {:ok, client} =
        start_client(:modern, :modern_only, log,
          reliability: [circuit_breaker: [failure_threshold: 5]],
          client_cleanup_timeout: 20
        )

      on_exit(fn -> stop(client) end)

      %{transport_state: %{circuit_breaker_pid: breaker, wrapped_state: %{os_pid: os_pid}}} =
        :sys.get_state(client)

      stick(breaker)
      breaker_ref = Process.monitor(breaker)

      _result = Client.disconnect(client)
      assert_receive {:DOWN, ^breaker_ref, :process, ^breaker, :killed}

      client_ref = Process.monitor(client)
      Client.stop(client)
      assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}
      TestHelpers.wait_until(fn -> not os_process_alive?(os_pid) end, timeout: 5_000)
      assert stdio_actors(client) == []
    end
  end

  describe "a reconnect attempt" do
    test "whose probed server cannot be confirmed stopped is the last", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "reconnect-unconfirmed.log")

      # The first server is modern; every later one never answers, so the
      # reconnect's probe times out and :prefer_modern would start another.
      {:ok, client} =
        start_client(:flaky, :prefer_modern, log,
          first_start: Path.join(tmp_dir, "first-start"),
          handshake_timeout: 1_000,
          cleanup_timeout: 600,
          health_check_interval: nil,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop(client) end)
      [first_actor] = stdio_actors(client)
      %{transport_state: %{os_pid: first}} = :sys.get_state(client)
      assert {_output, 0} = System.cmd("kill", ["-KILL", "#{first}"])

      # Once the reconnect's probe has reached the new server, keep its actor
      # from answering, so closing that server cannot be confirmed.
      TestHelpers.wait_until(fn -> length(methods(log)) >= 2 end, timeout: 5_000)
      [actor] = stdio_actors(client) -- [first_actor]
      true = :erlang.suspend_process(actor)

      assert_receive {:reconnect, :cleanup_unconfirmed, ^client, metadata}, 15_000
      assert {:probed_server_stop_unconfirmed, _details} = metadata.reason
      refute_received {:reconnect, :success, ^client, _metadata}

      assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
      assert starts(log) == 2
      assert {:error, _cleanup} = Client.stop(client)
    end
  end

  # Holds `component` inside a call of its own, so it can't answer a stop.
  defp stick(component) do
    test_pid = self()

    spawn(fn ->
      :sys.replace_state(component, fn state ->
        send(test_pid, :stuck)
        receive do: (:never -> state)
      end)
    end)

    assert_receive :stuck
  end

  # The live stdio actors `client` owns.
  defp stdio_actors(client) do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          :proplists.get_value({Arbor.RPC.Subprocess.Actor, :owner}, dictionary, nil) == client

        nil ->
          false
      end
    end)
  end

  defp os_process_alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
    status == 0
  end

  defp stop(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end
end
