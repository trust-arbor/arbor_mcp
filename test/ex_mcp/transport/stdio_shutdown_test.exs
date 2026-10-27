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
    test "keeps the graces that fit the budget, with time left for SIGKILL" do
      assert Stdio.shutdown_schedule(%Stdio{}) == {2_000, 100}

      assert Stdio.shutdown_schedule(%Stdio{eof_grace: 5_000, cleanup_timeout: 600}) ==
               {550, 0}

      assert Stdio.shutdown_schedule(%Stdio{eof_grace: 400, cleanup_timeout: 500}) == {400, 50}
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

  test "connect rejects an explicit nil shutdown option before starting the server" do
    ports = length(Port.list())

    for name <- [:eof_grace, :term_grace, :cleanup_timeout] do
      assert {:error, {:invalid_shutdown_option, ^name, nil}} =
               Stdio.connect([{name, nil}, command: ["/bin/sh", "-c", "exec sleep 30"]])
    end

    assert length(Port.list()) == ports
  end
end
