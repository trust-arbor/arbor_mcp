defmodule ExMCP.Client.StdioReconnectCleanupTest do
  @moduledoc """
  Each stdio connection runs its own server process, so a reconnect starts a
  new one. However the old connection ended, even with a server that simply
  exited, the client reconnects only once the old server, and with
  `process_group: true` whatever it left in its group, is confirmed gone,
  and not at all when that cannot be confirmed.
  """

  use ExUnit.Case, async: true

  import ExMCP.Test.ScriptedStdioServer,
    only: [
      kill_all: 1,
      overlaps: 1,
      pids: 1,
      reaper_of: 1,
      start_client: 4,
      starts: 1,
      stop_client: 1
    ]

  alias ExMCP.Client

  @moduletag :tmp_dir

  setup do
    Process.flag(:trap_exit, true)
    test_pid = self()
    handler_id = "stdio-reconnect-cleanup-#{System.unique_integer([:positive])}"

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

  # A legacy server that, once initialized, exits on its next request,
  # leaving a process in its group that ignores EOF and SIGTERM. The
  # reconnect is scheduled almost at once, well inside the shutdown's grace.
  defp start_departing(log, opts \\ []) do
    on_exit(fn -> kill_all(log) end)

    {:ok, client} =
      start_client(
        :departs,
        :legacy_only,
        log,
        Keyword.merge(
          [
            process_group: true,
            eof_grace: 300,
            term_grace: 100,
            reconnect: true,
            reconnect_backoff: [initial: 10, max: 40]
          ],
          opts
        )
      )

    on_exit(fn -> stop_client(client) end)
    client
  end

  test "a server that exits is replaced once what it left behind is gone", %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "departs.log")
    client = start_departing(log)

    # The ping makes the server exit; its answer is the closed connection.
    assert {:error, _closed} = Client.ping(client)

    assert_receive {:reconnected, ^client}, 15_000
    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert starts(log) == 2
    assert [first, left_behind, _second] = pids(log)
    assert overlaps(log) == [], "the second server started beside #{inspect(overlaps(log))}"
    refute os_alive?(first)
    refute os_alive?(left_behind)
  end

  test "a server whose group cannot be confirmed stopped is not replaced", %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "departs-unconfirmed.log")
    client = start_departing(log, cleanup_timeout: 300)

    # The server's reaper is kept from acting, so once the server exits, what
    # it left in its group can't be confirmed stopped.
    [server] = pids(log)
    reaper = reaper_of(server) || flunk("no reaper is watching server #{server}")
    true = :erlang.suspend_process(reaper)

    try do
      assert {:error, _closed} = Client.ping(client)

      assert_receive {:cleanup_unconfirmed, ^client, reason}, 10_000
      assert reason == {:server_stop_unconfirmed, :reaper_timeout}
      refute_received {:reconnected, ^client}
      assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
      assert starts(log) == 1
      assert [_server, left_behind] = pids(log)
      assert os_alive?(left_behind)
    after
      :erlang.resume_process(reaper)
      Process.exit(reaper, :kill)
    end
  end

  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))
end
