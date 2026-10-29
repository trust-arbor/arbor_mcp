defmodule ExMCP.Transport.StdioShutdownTest do
  @moduledoc """
  The stdio transport follows the MCP shutdown order: close the server's stdin,
  wait `:eof_grace` (2 s, as in the reference SDKs), then SIGTERM and SIGKILL.
  The client's close limit grows to cover that budget.
  """

  use ExUnit.Case, async: true

  import ExMCP.TestHelpers, only: [wait_until: 1, wait_until: 2]

  alias ExMCP.Client
  alias ExMCP.Client.Deadline
  alias ExMCP.Transport.Stdio
  alias ExMCP.Transport.Stdio.Reaper

  # Answers initialize, then ignores EOF and SIGTERM: only SIGKILL stops it.
  @stubborn_server ~S"""
  trap '' TERM
  IFS= read -r line
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stubborn","version":"1.0.0"}}}\n' "$id"
  exec sleep 30
  """

  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp kill_on_exit(os_pid) do
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true) end)
  end

  describe "shutdown_options/1" do
    test "defaults give the server 2 s after EOF within a 2.5 s budget" do
      opts = Stdio.shutdown_options(command: ["true"])
      assert opts[:eof_grace] == 2_000
      assert opts[:cleanup_timeout] == 2_500
    end

    test "an explicit EOF grace sets the budget around it" do
      assert Stdio.shutdown_options(eof_grace: 5_000)[:cleanup_timeout] == 5_500
      assert Stdio.shutdown_options(eof_grace: 0, term_grace: 200)[:cleanup_timeout] == 600
    end

    test "an explicit budget keeps the EOF grace that fits inside it" do
      assert Stdio.shutdown_options(cleanup_timeout: 500)[:eof_grace] == 350
      assert Stdio.shutdown_options(cleanup_timeout: 100)[:eof_grace] == 0
      assert Stdio.shutdown_options(cleanup_timeout: 10_000)[:eof_grace] == 2_000
    end

    test "explicit and invalid values pass through for the subprocess to validate" do
      opts = [eof_grace: 10, cleanup_timeout: 400]
      assert Stdio.shutdown_options(opts) == opts
      assert Stdio.shutdown_options(term_grace: :bad) == [term_grace: :bad]
    end
  end

  describe "shutdown_schedule/1" do
    test "keeps the graces that fit the budget, with time left for checks and SIGKILL" do
      assert Stdio.shutdown_schedule(%Stdio{}) == {2_000, 100}

      # 250 ms are kept back: 100 ms to check before each of the two
      # signals, and 50 ms for SIGKILL.
      assert Stdio.shutdown_schedule(%Stdio{eof_grace: 5_000, cleanup_timeout: 600}) ==
               {350, 0}

      assert Stdio.shutdown_schedule(%Stdio{eof_grace: 200, cleanup_timeout: 500}) == {200, 50}
    end

    test "connect rejects unusable shutdown options" do
      assert {:error, {:invalid_shutdown_option, :eof_grace, -1}} =
               Stdio.connect(command: ["true"], eof_grace: -1)

      assert {:error, {:invalid_shutdown_option, :term_grace, :bad}} =
               Stdio.connect(command: ["true"], term_grace: :bad)

      assert {:error, {:invalid_shutdown_option, :cleanup_timeout, 0}} =
               Stdio.connect(command: ["true"], cleanup_timeout: 0)
    end
  end

  describe "client close limit" do
    test "covers a stdio server's shutdown budget" do
      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"]) == 3_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], eof_grace: 5_000) ==
               6_000

      assert Deadline.cleanup_timeout(transports: [{:stdio, command: ["true"]}]) == 3_000
    end

    test "stays at the default for other transports and unusable options" do
      assert Deadline.cleanup_timeout(transport: :http, url: "http://localhost:1/mcp") == 1_000
      assert Deadline.cleanup_timeout([]) == 1_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], cleanup_timeout: 100) ==
               1_000
    end
  end

  @tag :tmp_dir
  test "close lets a server that exits on EOF do so without a signal", %{tmp_dir: tmp_dir} do
    status_file = Path.join(tmp_dir, "exit_status.txt")
    # Exits 0 on stdin EOF; a SIGTERM delivered first would make it write "143" and exit 143.
    script =
      "trap 'echo 143 > \"" <>
        status_file <>
        "\"; exit 143' TERM; while read -r _; do :; done; echo 0 > \"" <>
        status_file <> "\"; exit 0"

    {:ok, state} = Stdio.connect(command: ["/bin/sh", "-c", script])

    assert :ok = Stdio.close(state)

    wait_until(fn ->
      case File.read(status_file) do
        {:ok, content} -> String.trim(content) == "0"
        _ -> false
      end
    end)
  end

  @tag :tmp_dir
  test "close sends SIGTERM if server does not exit on EOF within eof_grace", %{tmp_dir: tmp_dir} do
    status_file = Path.join(tmp_dir, "term_status.txt")
    # Ignores EOF (sleeps indefinitely); traps TERM to write 143 and exit.
    script = "trap 'echo 143 > \"" <> status_file <> "\"; exit 143' TERM; sleep 30 & wait $!"

    {:ok, state} =
      Stdio.connect(command: ["/bin/sh", "-c", script], eof_grace: 50, term_grace: 500)

    assert :ok = Stdio.close(state)

    wait_until(fn ->
      case File.read(status_file) do
        {:ok, content} -> String.trim(content) == "143"
        _ -> false
      end
    end)
  end

  test "a client killed during the EOF grace still leaves no server process" do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    opts = [
      transport: :stdio,
      command: ["/bin/sh", "-c", @stubborn_server],
      protocol_mode: :legacy_only,
      eof_grace: 400,
      term_grace: 100,
      health_check_interval: nil,
      reconnect: false
    ]

    # Its supervisor allows the client 100 ms to stop, less than the grace.
    {:ok, client} =
      DynamicSupervisor.start_child(
        supervisor,
        Supervisor.child_spec({Client, opts}, shutdown: 100)
      )

    os_pid = :sys.get_state(client).transport_state.os_pid
    kill_on_exit(os_pid)
    assert os_alive?(os_pid)

    monitor = Process.monitor(client)
    :ok = DynamicSupervisor.terminate_child(supervisor, client)
    assert_receive {:DOWN, ^monitor, :process, ^client, :killed}

    # Without the fix the server outlives the client for its full 30 s.
    wait_until(fn -> not os_alive?(os_pid) end, timeout: 5_000)
  end

  test "a client killed before it closes the connection leaves no server process" do
    Process.flag(:trap_exit, true)

    {:ok, client} =
      Client.start_link(
        transport: :stdio,
        command: ["/bin/sh", "-c", @stubborn_server],
        protocol_mode: :legacy_only,
        eof_grace: 200,
        term_grace: 100,
        health_check_interval: nil,
        reconnect: false
      )

    os_pid = :sys.get_state(client).transport_state.os_pid
    kill_on_exit(os_pid)

    # No terminate/2, so no close/1: only the port closing with its owner.
    Process.exit(client, :kill)
    assert_receive {:EXIT, ^client, :killed}

    wait_until(fn -> not os_alive?(os_pid) end, timeout: 5_000)
  end

  test "close/1 stops a server that ignores EOF and SIGTERM within its cleanup budget" do
    {:ok, state} =
      Stdio.connect(
        command: ["/bin/sh", "-c", "trap '' TERM; exec sleep 30"],
        eof_grace: 5_000,
        cleanup_timeout: 600
      )

    kill_on_exit(state.os_pid)

    started = System.monotonic_time(:millisecond)
    assert :ok = Stdio.close(state)
    # At most the 600 ms budget plus 500 ms to confirm; without the fix
    # close/1 took the 5 s EOF grace.
    assert System.monotonic_time(:millisecond) - started < 1_500

    wait_until(fn -> not os_alive?(state.os_pid) end, timeout: 5_000)
  end

  describe "the reaper" do
    defp sleeper do
      port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["30"])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      kill_on_exit(os_pid)
      {port, os_pid}
    end

    defp await_exit(pid) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end

    test "never signals a pid that now names another process" do
      # The connection's server exited, and its pid was handed to `victim`.
      {victim_port, victim} = sleeper()
      {server_port, _server} = sleeper()

      reaper =
        Reaper.start(server_port, victim,
          identity: {:ps, "the server's start time"},
          eof_grace: 0,
          term_grace: 0,
          budget: 1_000
        )

      Reaper.close(reaper)
      await_exit(reaper)

      assert os_alive?(victim)
      Port.close(victim_port)
    end

    test "stops its own server, which it identifies" do
      {port, os_pid} = sleeper()
      refute Reaper.identity(os_pid) == nil

      reaper = Reaper.start(port, os_pid, eof_grace: 0, term_grace: 100, budget: 1_000)
      Reaper.close(reaper)
      await_exit(reaper)

      wait_until(fn -> not os_alive?(os_pid) end, timeout: 5_000)
    end

    test "stands down when the port reported the server's exit" do
      {port, os_pid} = sleeper()
      reaper = Reaper.start(port, os_pid, eof_grace: 0, term_grace: 0, budget: 1_000)

      Reaper.server_exited(reaper)
      await_exit(reaper)
      Port.close(port)

      assert os_alive?(os_pid)
    end

    test "records that its server is gone once it has seen it go" do
      {port, os_pid} = sleeper()
      outcome = Reaper.new_outcome()

      reaper =
        Reaper.start(port, os_pid, eof_grace: 0, term_grace: 100, budget: 1_000, outcome: outcome)

      assert Reaper.outcome(outcome) == :pending
      Reaper.close(reaper)
      await_exit(reaper)

      assert Reaper.outcome(outcome) == :confirmed
      refute os_alive?(os_pid)
    end

    test "records that it could not confirm a server it could not identify" do
      {port, os_pid} = sleeper()
      outcome = Reaper.new_outcome()

      # The server runs, but its start time can't be read before a signal.
      reaper =
        Reaper.start(port, os_pid,
          eof_grace: 0,
          term_grace: 0,
          budget: 1_000,
          outcome: outcome,
          start_time: fn _pid -> nil end
        )

      Reaper.close(reaper)
      await_exit(reaper)

      assert Reaper.outcome(outcome) == {:unconfirmed, :identity_unreadable}
      assert os_alive?(os_pid)
    end

    # A connection as connect/1 builds it, around a reaper with `opts`.
    defp connection(opts) do
      {port, os_pid} = sleeper()
      outcome = Reaper.new_outcome()
      opts = Keyword.merge([eof_grace: 0, term_grace: 100, budget: 1_000, outcome: outcome], opts)

      %Stdio{
        port: port,
        os_pid: os_pid,
        line_buffer: "",
        cleanup_timeout: Keyword.fetch!(opts, :budget),
        reaper: Reaper.start(port, os_pid, opts),
        reaper_outcome: outcome
      }
    end

    test "close_confirmed/1 says whether the server was seen gone; close/1 returns :ok" do
      assert Stdio.close_confirmed(connection([])) == :ok

      unidentified = [start_time: fn _pid -> nil end]

      assert Stdio.close_confirmed(connection(unidentified)) ==
               {:error, {:server_stop_unconfirmed, :identity_unreadable}}

      state = connection(unidentified)
      assert Stdio.close(state) == :ok
      assert Reaper.outcome(state.reaper_outcome) == {:unconfirmed, :identity_unreadable}
    end

    test "close_confirmed/1 confirms nothing when the reaper does not finish in time" do
      state = connection(budget: 200)
      true = :erlang.suspend_process(state.reaper)
      started = System.monotonic_time(:millisecond)

      try do
        assert Stdio.close_confirmed(state) ==
                 {:error, {:server_stop_unconfirmed, :reaper_timeout}}

        # The 200 ms budget plus 500 ms for the reaper to report.
        assert System.monotonic_time(:millisecond) - started < 1_500
      after
        :erlang.resume_process(state.reaper)
        Process.exit(state.reaper, :kill)
      end
    end

    test "close_confirmed/1 confirms a server whose exit the port reported" do
      {:ok, state} = Stdio.connect(command: ["/bin/sh", "-c", "exit 0"])

      assert {:error, {:connection_error, {:process_exited, 0}}} =
               Stdio.receive_message(state, 5_000)

      assert Stdio.close_confirmed(state) == :ok
    end

    # The lookup says the pid is the server's at first, then that another
    # process has it: the server exited and its pid was handed on.
    defp reused_after_first_check do
      checks = :counters.new(1, [])

      fn _pid ->
        :counters.add(checks, 1, 1)
        if :counters.get(checks, 1) == 1, do: :the_server, else: :another_process
      end
    end

    for group? <- [false, true] do
      test "checks its target again just before each signal (process_group: #{group?})" do
        {port, os_pid} = sleeper()
        deadline = System.monotonic_time(:millisecond) + 2_000

        opts = [
          process_group: unquote(group?),
          eof_grace: 50,
          term_grace: 50,
          start_time: reused_after_first_check()
        ]

        assert Reaper.shutdown(os_pid, :the_server, opts, deadline) == :exited
        assert os_alive?(os_pid)
        Port.close(port)
      end
    end

    test "sends nothing when a check can't finish before the deadline" do
      {port, os_pid} = sleeper()
      started = System.monotonic_time(:millisecond)

      slow = fn _pid ->
        Process.sleep(5_000)
        :the_server
      end

      opts = [eof_grace: 50, term_grace: 50, start_time: slow]

      assert {:unconfirmed, :identity_timeout} =
               Reaper.shutdown(os_pid, :the_server, opts, started + 300)

      assert System.monotonic_time(:millisecond) - started < 1_500
      assert os_alive?(os_pid)
      Port.close(port)
    end

    # A `ps` that hangs: it records its pid, then waits.
    defp hanging_ps(tmp_dir) do
      ps = Path.join(tmp_dir, "ps")
      File.write!(ps, "#!/bin/sh\necho $$ > \"$(dirname \"$0\")/ps.pid\"\nexec sleep 30\n")
      File.chmod!(ps, 0o755)
      [{"PATH", "#{tmp_dir}:/usr/bin:/bin"}]
    end

    defp hanging_ps_pid(tmp_dir) do
      pid_file = Path.join(tmp_dir, "ps.pid")
      wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(pid_file)) end, timeout: 2_000)
      pid = pid_file |> File.read!() |> String.trim()
      kill_on_exit(pid)
      pid
    end

    test "kills a helper that stops answering, so a signal it holds never runs" do
      {port, os_pid} = sleeper()
      {:ok, helper} = Reaper.open_helper()
      kill_on_exit(helper.os_pid)

      # The check before SIGTERM succeeds without the helper (as /proc does
      # on Linux), and meanwhile the helper stalls, as a starved one would:
      # SIGTERM is sent to a helper that can't run it yet.
      checks = :counters.new(1, [])

      lookup = fn _pid ->
        :counters.add(checks, 1, 1)

        if :counters.get(checks, 1) == 2,
          do: {_output, 0} = System.cmd("kill", ["-STOP", "#{helper.os_pid}"])

        :the_server
      end

      opts = [helper: {:ok, helper}, eof_grace: 0, term_grace: 50, start_time: lookup]

      deadline = System.monotonic_time(:millisecond) + 300
      assert {:unconfirmed, _reason} = Reaper.shutdown(os_pid, :the_server, opts, deadline)

      # Resumed, a helper still alive would run the signal it was sent.
      System.cmd("kill", ["-CONT", "#{helper.os_pid}"], stderr_to_stdout: true)
      wait_until(fn -> not os_alive?(helper.os_pid) end, timeout: 5_000)

      assert_raise ExUnit.AssertionError, fn ->
        wait_until(fn -> not os_alive?(os_pid) end, timeout: 500)
      end

      Port.close(port)
    end

    test "cleans up a stalled helper only slightly past an exhausted budget" do
      {port, os_pid} = sleeper()
      {:ok, helper} = Reaper.open_helper()
      kill_on_exit(helper.os_pid)
      {_output, 0} = System.cmd("kill", ["-STOP", "#{helper.os_pid}"])

      # Neither its answers nor its exit reach the reaper: it looks stalled
      # for good, and its kill can't be confirmed.
      elsewhere = spawn(fn -> receive(do: (:never -> :ok)) end)
      on_exit(fn -> Process.exit(elsewhere, :kill) end)
      Port.connect(helper.port, elsewhere)

      opts = [
        helper: {:ok, helper},
        eof_grace: 0,
        term_grace: 0,
        start_time: fn _pid -> :the_server end
      ]

      started = System.monotonic_time(:millisecond)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:unconfirmed, _reason} =
                   Reaper.shutdown(os_pid, :the_server, opts, started + 50)
        end)

      # The 50 ms budget, then at most 100 ms for each of the three kill
      # steps, and slack for a busy machine.
      assert System.monotonic_time(:millisecond) - started < 50 + 300 + 250
      assert log =~ "did not exit when killed"
      wait_until(fn -> not os_alive?(helper.os_pid) end, timeout: 2_000)
      Port.close(port)
    end

    @tag :tmp_dir
    test "kills a helper stuck in a ps that hangs, with the ps", %{tmp_dir: tmp_dir} do
      {port, os_pid} = sleeper()
      {:ok, helper} = Reaper.open_helper(hanging_ps(tmp_dir))
      kill_on_exit(helper.os_pid)

      opts = [helper: {:ok, helper}, start_source: :ps, eof_grace: 0, term_grace: 0]
      deadline = System.monotonic_time(:millisecond) + 300

      assert {:unconfirmed, :identity_timeout} =
               Reaper.shutdown(os_pid, :the_server, opts, deadline)

      ps = hanging_ps_pid(tmp_dir)
      wait_until(fn -> not os_alive?(helper.os_pid) and not os_alive?(ps) end, timeout: 2_000)
      assert os_alive?(os_pid)
      Port.close(port)
    end

    @tag :tmp_dir
    test "kills its helper when reading the start time at connect hangs", %{tmp_dir: tmp_dir} do
      {port, os_pid} = sleeper()

      reaper =
        Reaper.start(port, os_pid,
          helper_env: hanging_ps(tmp_dir),
          start_source: :ps,
          identity_read_ms: 300,
          eof_grace: 0,
          term_grace: 0,
          budget: 1_000
        )

      ps = hanging_ps_pid(tmp_dir)
      wait_until(fn -> not os_alive?(ps) end, timeout: 2_000)

      # The reaper closes the port.
      Reaper.close(reaper)
      await_exit(reaper)
      refute Port.info(port)
    end

    @tag :tmp_dir
    test "starts the TERM grace when TERM goes out, after a slow check", %{tmp_dir: tmp_dir} do
      status = Path.join(tmp_dir, "status")
      # Takes 150 ms to clean up after SIGTERM, then exits 0.
      script =
        "trap 'kill $c; sleep 0.15; echo clean > \"$1\"; exit 0' TERM; sleep 30 & c=$!; wait $c"

      port = Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", script, "sh", status])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      kill_on_exit(os_pid)

      # The check before SIGTERM takes 800 ms, longer than the 600 ms TERM grace.
      checks = :counters.new(1, [])

      lookup = fn _pid ->
        :counters.add(checks, 1, 1)
        if :counters.get(checks, 1) == 2, do: Process.sleep(800)
        :the_server
      end

      opts = [eof_grace: 0, term_grace: 600, start_time: lookup]
      deadline = System.monotonic_time(:millisecond) + 3_000

      assert Reaper.shutdown(os_pid, :the_server, opts, deadline) == :stopped
      assert File.read!(status) == "clean\n"
    end

    test "reads a Linux start time past a command name with spaces and parentheses" do
      stat =
        "4242 (my (odd) server) S 1 4242 4242 0 -1 4194560 120 0 0 0 1 2 0 0 20 0 1 0 " <>
          "987654 12345678 300 18446744073709551615\n"

      assert Reaper.parse_linux_stat(stat) == {:linux, "987654"}
      assert Reaper.parse_linux_stat("garbage") == nil
    end

    # Windows can't be run here, so its decisions are tested as logic.
    test "decides what each end of the connection calls for" do
      assert Reaper.steps(:unix, :close) == [:close_port, :shutdown]
      assert Reaper.steps(:unix, {:port_down, :normal}) == [:shutdown]
      assert Reaper.steps(:unix, {:port_down, :killed}) == [:shutdown]
      # What the server left in its group, with process_group: true.
      assert Reaper.steps(:unix, :server_exited) == [:stop_group]

      # taskkill only while the open port still holds the process handle,
      # so the pid can't have been handed on yet.
      assert Reaper.steps(:win32, :close) == [:taskkill, :close_port]
      assert Reaper.steps(:win32, {:port_down, :killed}) == [:warn_left_running]
      assert Reaper.steps(:win32, {:port_down, :shutdown}) == [:warn_left_running]
      assert Reaper.steps(:win32, {:port_down, :normal}) == []
      assert Reaper.steps(:win32, :server_exited) == []
    end

    test "gives up on a command that outlasts its bound" do
      started = System.monotonic_time(:millisecond)
      assert Reaper.run_bounded("sleep", ["5"], 200) == :timeout
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert {_output, 0} = Reaper.run_bounded("true", [], 2_000)
    end
  end

  test "connect rejects an explicit nil shutdown option before starting the server" do
    # A port connect/1 opened is linked to the caller, this test.
    linked_ports = fn ->
      {:links, links} = Process.info(self(), :links)
      Enum.count(links, &is_port/1)
    end

    ports = linked_ports.()

    for name <- [:eof_grace, :term_grace, :cleanup_timeout] do
      assert {:error, {:invalid_shutdown_option, ^name, nil}} =
               Stdio.connect([{name, nil}, command: ["/bin/sh", "-c", "exec sleep 30"]])
    end

    assert linked_ports.() == ports
  end
end
