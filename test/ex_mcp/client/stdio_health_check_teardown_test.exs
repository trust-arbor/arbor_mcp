defmodule ExMCP.Client.StdioHealthCheckTeardownTest do
  @moduledoc """
  Each stdio connection runs its own server process, so reconnecting starts
  a new one. A health check that gives up on a hung server must stop that
  server before the reconnect, or the two run side by side.
  """

  use ExUnit.Case, async: true

  import ExMCP.Test.ScriptedStdioServer,
    only: [kill_all: 1, pids: 1, reaper_of: 1, start_client: 4, starts: 1]

  alias ExMCP.Client

  @moduletag :tmp_dir

  setup do
    Process.flag(:trap_exit, true)
    test_pid = self()
    handler_id = "stdio-health-check-teardown-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ex_mcp, :client, :reconnect, :success],
        [:ex_mcp, :client, :reconnect, :cleanup_unconfirmed]
      ],
      fn
        [_, _, _, :success], _measurements, metadata, _config ->
          send(test_pid, {:reconnected, metadata.pid})

        [_, _, _, :cleanup_unconfirmed], _measurements, metadata, _config ->
          send(test_pid, {:cleanup_unconfirmed, metadata.pid, metadata.reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "stops a hung server before reconnecting", %{tmp_dir: tmp_dir} do
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
    assert_receive {:reconnected, ^client}, 10_000
    refute os_process_alive?(hung), "the hung server outlived its connection"
    assert starts(log) >= 2
  end

  test "does not reconnect beside a hung server it cannot confirm stopped",
       %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "unconfirmed.log")
    on_exit(fn -> kill_all(log) end)

    {:ok, client} =
      start_client(:once, :modern_only, log,
        health_check_interval: 200,
        cleanup_timeout: 300,
        reconnect: true,
        reconnect_backoff: [initial: 10, max: 40]
      )

    on_exit(fn -> stop(client) end)

    # The server's reaper is kept from acting, so when the health check
    # gives up and closes the connection, the server can't be confirmed
    # stopped.
    [hung] = pids(log)
    reaper = reaper_of(hung) || flunk("no reaper is watching server #{hung}")
    true = :erlang.suspend_process(reaper)

    try do
      assert_receive {:cleanup_unconfirmed, ^client, reason}, 10_000
      assert reason == {:server_stop_unconfirmed, :reaper_timeout}
      refute_received {:reconnected, ^client}
      assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
      assert starts(log) == 1
    after
      :erlang.resume_process(reaper)
      Process.exit(reaper, :kill)
    end
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
