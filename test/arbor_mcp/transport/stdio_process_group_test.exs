defmodule Arbor.MCP.Transport.StdioProcessGroupTest do
  @moduledoc """
  ERTS starts every port program as the leader of its own process group.
  With `process_group: true` the stdio transport signals that whole group, so
  a server's own children stop with it; by default only the server process is
  signalled. The command is resolved against the child's `PATH`.
  """

  use ExUnit.Case, async: true

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Transport.Stdio

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    if match?({:win32, _}, :os.type()), do: raise("process groups are a Unix feature")
    %{pid_file: Path.join(tmp_dir, "child.pid")}
  end

  describe "close/1" do
    test "by default signals the server only, and its child outlives it", %{pid_file: pid_file} do
      {:ok, state} = Stdio.connect(command: server_with_child(pid_file))
      child = await_pid(pid_file)
      on_exit(fn -> kill(child) end)

      :ok = Stdio.close(state)

      refute alive?(state.os_pid)
      assert alive?(child)
    end

    test "with process_group: true stops the server's children too", %{pid_file: pid_file} do
      {:ok, state} = Stdio.connect(command: server_with_child(pid_file), process_group: true)
      child = await_pid(pid_file)
      on_exit(fn -> kill(child) end)

      :ok = Stdio.close(state)

      refute alive?(state.os_pid)
      refute alive?(child)
    end

    test "with process_group: true kills a child that ignores SIGTERM", %{pid_file: pid_file} do
      command = sh("(trap '' TERM; exec sleep 30) & echo $! > \"$1\"; wait", pid_file)
      {:ok, state} = Stdio.connect(command: command, process_group: true)
      child = await_pid(pid_file)
      on_exit(fn -> kill(child) end)

      :ok = Stdio.close(state)

      refute alive?(child)
    end
  end

  describe "a server that exits on its own with process_group: true" do
    test "has the children it left behind stopped (push)", %{pid_file: pid_file} do
      command = sh(orphaning_server(), pid_file)
      {:ok, state} = Stdio.connect(command: command, process_group: true)
      {:ok, state} = Stdio.subscribe(self(), state)
      child = await_pid(pid_file)
      on_exit(fn -> kill(child) end)

      tell_server_to_exit(state)

      generation = Stdio.identity(state)
      assert_receive {:arbor_rpc, ^generation, {:closed, {:exit_status, 0}, ""}}, 10_000
      assert_stopped(child, state.os_pid)
    end

    test "has the children it left behind stopped (pull)", %{pid_file: pid_file} do
      command = sh(orphaning_server(), pid_file)
      {:ok, state} = Stdio.connect(command: command, process_group: true)
      child = await_pid(pid_file)
      on_exit(fn -> kill(child) end)

      tell_server_to_exit(state)

      # The exit is what triggers the reaping, so wait for that exact error
      # (allowing for a loaded host) rather than any timeout.
      assert {:error, {:connection_error, {:process_exited, 0}}} =
               Stdio.receive_message(state, 10_000)

      assert_stopped(child, state.os_pid)
    end
  end

  test "rejects a non-boolean process_group" do
    assert {:error, {:invalid_process_group, :yes}} =
             Stdio.connect(command: ["true"], process_group: :yes)
  end

  test "resolves the command against the child's PATH", %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    tool = Path.join(bin, "ex-mcp-path-probe")
    File.write!(tool, "#!/bin/sh\nexit 7\n")
    File.chmod!(tool, 0o755)

    # Not on the VM's PATH, only on the child's.
    assert System.find_executable("ex-mcp-path-probe") == nil

    assert {:ok, state} =
             Stdio.connect(
               command: ["ex-mcp-path-probe"],
               env: [{"PATH", "#{bin}:/usr/bin:/bin"}]
             )

    assert {:error, {:connection_error, {:process_exited, 7}}} =
             Stdio.receive_message(state, 2_000)
  end

  defp server_with_child(pid_file), do: sh("sleep 30 & echo $! > \"$1\"; wait", pid_file)

  # Starts a child and exits once it reads a line, so the test decides when:
  # exiting at once could close the port before the test has subscribed to
  # it. The child lets go of the server's stdout: ERTS reports the server's
  # exit only once that pipe reaches EOF, so a child still holding it keeps
  # the connection open (and is then, in effect, the server).
  defp orphaning_server,
    do: "sleep 30 </dev/null >/dev/null 2>&1 & echo $! > \"$1\"; read _line; exit 0"

  defp tell_server_to_exit(state) do
    {:ok, _state} = Stdio.send_message(~s({"jsonrpc":"2.0","method":"exit"}), state)
  end

  # The pid file's path (derived from the test name) goes in as $1, not into
  # the script text, so no character in it can change the script.
  defp sh(script, pid_file), do: ["sh", "-c", script, "sh", pid_file]

  defp await_pid(pid_file) do
    wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(pid_file)) end, timeout: 2_000)
    pid_file |> File.read!() |> String.trim() |> String.to_integer()
  end

  # Waits for `child` to stop; if it does not, the failure says where it is
  # (its parent, group and state) and what is left in the server's group.
  defp assert_stopped(child, group) do
    wait_until(fn -> not alive?(child) end, timeout: 5_000)
  rescue
    ExUnit.AssertionError ->
      table = ps(["-eo", "pid,ppid,pgid,stat,args"])
      group_id = Integer.to_string(group)

      in_group =
        table
        |> String.split("\n")
        |> Enum.filter(&match?([_pid, _ppid, ^group_id | _rest], String.split(&1)))

      flunk("""
      child #{child} of the server whose group is #{group} is still running.
      child: #{ps(["-o", "pid,ppid,pgid,stat,args", "-p", "#{child}"])}
      members of group #{group}:
      #{Enum.join(in_group, "\n")}
      """)
  end

  defp ps(args) do
    {output, _status} = System.cmd("ps", args, stderr_to_stdout: true)
    output
  end

  # A killed process whose parent has already exited stays a zombie until
  # init reaps it, and `kill -0` still succeeds on a zombie: count it as gone.
  defp alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_output, _not_found} -> false
    end
  end

  defp kill(os_pid), do: System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
end
