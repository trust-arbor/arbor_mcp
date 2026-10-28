defmodule ExMCP.Transport.StdioReaperPathTest do
  @moduledoc """
  The stdio reaper kills a helper that stopped answering without depending
  on `PATH`, so a signal the helper holds can't run after the reaper has
  decided.
  """

  # It changes the VM's PATH, so it runs on its own.
  use ExUnit.Case, async: false

  import ExMCP.TestHelpers, only: [wait_until: 2]

  alias ExMCP.Transport.Stdio.Reaper

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  @tag :tmp_dir
  test "kills a stalled helper even when PATH has no kill", %{tmp_dir: tmp_dir} do
    sleeper = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["30"])
    {:os_pid, server} = Port.info(sleeper, :os_pid)
    {:ok, helper} = Reaper.open_helper()

    on_exit(fn ->
      for pid <- [server, helper.os_pid],
          do: System.cmd("/bin/kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end)

    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    # The check before SIGTERM succeeds without the helper, and meanwhile
    # the helper stalls: SIGTERM is sent to a helper that can't run it yet.
    checks = :counters.new(1, [])

    lookup = fn _pid ->
      :counters.add(checks, 1, 1)

      if :counters.get(checks, 1) == 2,
        do: {_output, 0} = System.cmd("/bin/kill", ["-STOP", "#{helper.os_pid}"])

      :the_server
    end

    opts = [helper: {:ok, helper}, eof_grace: 0, term_grace: 50, start_time: lookup]

    # An empty directory: no `kill` (nor anything else) on PATH.
    System.put_env("PATH", tmp_dir)
    deadline = System.monotonic_time(:millisecond) + 300
    result = Reaper.shutdown(server, :the_server, opts, deadline)
    System.put_env("PATH", path)

    assert {:unconfirmed, _reason} = result

    # Resumed, a helper still alive would run the SIGTERM it was sent.
    System.cmd("/bin/kill", ["-CONT", "#{helper.os_pid}"], stderr_to_stdout: true)
    wait_until(fn -> not alive?(helper.os_pid) end, timeout: 5_000)

    assert_raise ExUnit.AssertionError, fn ->
      wait_until(fn -> not alive?(server) end, timeout: 500)
    end

    Port.close(sleeper)
  end
end
