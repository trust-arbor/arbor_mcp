defmodule ExMCP.Transport.Stdio.Reaper do
  @moduledoc false
  # Stops a stdio server when its connection ends, in the MCP shutdown order:
  # EOF (the port closing), then SIGTERM after the EOF grace, then SIGKILL
  # after the TERM grace.
  #
  # A reaper is started with each connection and linked to nothing, so it
  # outlives whoever owns the connection: a client killed by its supervisor
  # before or during ExMCP.Transport.Stdio.close/1 still has its server
  # stopped. It acts once, on the first of:
  #
  #   * :close - close/1 asked; the reaper closes the port itself, so it
  #     knows the close was asked for
  #   * the port's :DOWN - its owner died, or the server exited
  #   * :server_exited - the port reported the server's exit status
  #
  # A pid names the server only while the server runs: once it exits, the
  # pid can be handed to an unrelated process. So on Unix every signal is
  # sent only after checking that the pid still names the child started for
  # this connection, by its start time recorded at connect, and when that
  # can't be checked nothing is sent. A group is ours while its leader is,
  # or, once the leader is gone, while the group has members: a pid isn't
  # handed out while a process group with that id exists.
  #
  # Windows has no cheap check, but a pid isn't reused there while a handle
  # to the process is open, and the open port holds one. So taskkill runs
  # only on close/1, before the reaper closes the port. When the port has
  # already closed because its owner died, the server is left running, with
  # a warning: its pid may already name another process tree.

  require Logger

  @poll_ms 10
  @max_poll_ms 100

  @type event :: :close | :server_exited | {:port_down, term()}
  @type step :: :close_port | :shutdown | :taskkill | :warn_left_running

  @doc """
  Starts the reaper of the server `os_pid` behind `port`. Options:
  `:process_group`, `:eof_grace`, `:term_grace` (already fitted to the
  budget) and `:budget` (the bound on taskkill); `:identity` stands in for
  the one read at start, for tests.
  """
  @spec start(port(), pos_integer(), keyword()) :: pid()
  def start(port, os_pid, opts) when is_integer(os_pid) do
    # Read here, while the connection is new: a server that already exited
    # gets nil, and nil is never signalled.
    identity = Keyword.get_lazy(opts, :identity, fn -> identity(os_pid) end)
    spawn(fn -> run(port, os_pid, identity, opts) end)
  end

  @doc "Asks the reaper to close the port and stop the server."
  @spec close(pid()) :: :ok
  def close(reaper) when is_pid(reaper) do
    send(reaper, :close)
    :ok
  end

  @doc "Tells the reaper the server exited on its own: nothing to stop."
  @spec server_exited(pid() | nil) :: :ok
  def server_exited(reaper) when is_pid(reaper) do
    send(reaper, :server_exited)
    :ok
  end

  def server_exited(_no_reaper), do: :ok

  @doc """
  The steps a reaper takes, in order, when `event` ends the connection on
  `os_family` (`:unix` or `:win32`). `:shutdown` signals only a server or
  group it can confirm as its own.
  """
  @spec steps(:unix | :win32, event()) :: [step()]
  def steps(_os_family, :server_exited), do: []
  def steps(:unix, :close), do: [:close_port, :shutdown]
  def steps(:unix, {:port_down, _reason}), do: [:shutdown]
  # The open port holds the process handle, so the pid is still the server's.
  def steps(:win32, :close), do: [:taskkill, :close_port]
  # The server exited, or its owner did normally: nothing to stop.
  def steps(:win32, {:port_down, :normal}), do: []
  def steps(:win32, {:port_down, _abnormal}), do: [:warn_left_running]

  defp run(port, os_pid, identity, opts) do
    monitor = monitor_port(port)

    event =
      receive do
        :close -> :close
        :server_exited -> :server_exited
        {:DOWN, ^monitor, :port, _port, reason} -> {:port_down, reason}
      end

    os_family()
    |> steps(event)
    |> Enum.each(&step(&1, port, os_pid, identity, opts))
  end

  defp step(:close_port, port, _os_pid, _identity, _opts), do: close_port(port)
  defp step(:shutdown, _port, os_pid, identity, opts), do: shutdown(os_pid, identity, opts)

  defp step(:taskkill, _port, os_pid, _identity, opts),
    do: taskkill(os_pid, Keyword.fetch!(opts, :budget))

  defp step(:warn_left_running, _port, os_pid, _identity, _opts) do
    Logger.warning(
      "stdio server #{os_pid} may be left running: its connection's owner died before " <>
        "closing it, and on Windows its pid can no longer be confirmed"
    )
  end

  defp shutdown(os_pid, identity, opts) do
    group? = Keyword.get(opts, :process_group, false)

    if ours?(os_pid, identity, group?) do
      target = if group?, do: {:group, os_pid}, else: os_pid

      unless exited_within?(target, Keyword.fetch!(opts, :eof_grace)) do
        signal(target, identity, "TERM")

        unless exited_within?(target, Keyword.fetch!(opts, :term_grace)) do
          signal(target, identity, "KILL")
        end
      end
    end

    :ok
  end

  # The server is ours while the pid's start time still matches. Its group
  # is ours while its leader is, and once the leader is gone (exited, with
  # children left), while the group has members: a pid isn't handed out
  # while a process group with that id exists.
  defp ours?(os_pid, identity, false), do: same_child?(os_pid, identity)

  defp ours?(os_pid, identity, true),
    do: same_child?(os_pid, identity) or (not alive?(os_pid) and alive?({:group, os_pid}))

  # The group was confirmed when the shutdown began, and its id isn't reused
  # while it has members.
  defp signal({:group, _os_pid} = target, _identity, signal), do: kill(signal, target)

  defp signal(os_pid, identity, signal) do
    if same_child?(os_pid, identity), do: kill(signal, os_pid)
  end

  @doc false
  # Signals what a server left in its group after exiting on its own (see
  # Stdio's process_group option). The group id can't be handed to a new
  # group while the group has members.
  @spec stop_group(pos_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def stop_group(os_pid, eof_grace, term_grace) do
    target = {:group, os_pid}

    unless exited_within?(target, eof_grace) do
      kill("TERM", target)
      unless exited_within?(target, term_grace), do: kill("KILL", target)
    end

    :ok
  end

  @doc false
  # Runs `command`, giving up after `timeout_ms`.
  @spec run_bounded(String.t(), [String.t()], non_neg_integer()) ::
          {String.t(), non_neg_integer()} | :timeout
  def run_bounded(command, args, timeout_ms) do
    task = Task.async(fn -> run_command(command, args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout -> :timeout
    end
  end

  defp taskkill(os_pid, budget) do
    run_bounded("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"], budget)
    :ok
  end

  @doc false
  # Identifies the process `os_pid` names, so a pid handed on to another
  # process isn't taken for the server: its start time, from /proc on Linux
  # and from ps elsewhere. nil when it can't be read (or no such process).
  @spec identity(pos_integer()) :: term() | nil
  def identity(os_pid) do
    case :os.type() do
      {:unix, :linux} -> linux_start_time(os_pid)
      {:unix, _other} -> ps_start_time(os_pid)
      {:win32, _name} -> nil
    end
  end

  defp same_child?(_os_pid, nil), do: false
  defp same_child?(os_pid, identity), do: identity(os_pid) == identity

  defp linux_start_time(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> parse_linux_stat(stat)
      {:error, _reason} -> nil
    end
  end

  @doc false
  # Field 22 of /proc/<pid>/stat, the start time in clock ticks after boot.
  # The command name (field 2, in parentheses) may hold spaces and
  # parentheses, so fields are counted after its last ")".
  @spec parse_linux_stat(String.t()) :: {:linux, String.t()} | nil
  def parse_linux_stat(stat) do
    with [_pid_and_comm, rest] <- :binary.split(stat, ")", [:global]) |> split_last(),
         fields = String.split(rest, " ", trim: true),
         start when is_binary(start) <- Enum.at(fields, 19) do
      {:linux, start}
    else
      _unparsable -> nil
    end
  end

  defp split_last([_only]), do: :error
  defp split_last(parts), do: [Enum.join(Enum.drop(parts, -1), ")"), List.last(parts)]

  defp ps_start_time(os_pid) do
    case run_command("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)]) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          start -> {:ps, start}
        end

      _gone ->
        nil
    end
  end

  # Each check runs `kill`, so checks grow sparser over a long grace.
  defp exited_within?(target, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    wait_for_exit(target, deadline, @poll_ms)
  end

  defp wait_for_exit(target, deadline, interval) do
    if alive?(target) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(remaining, interval))
        wait_for_exit(target, deadline, min(interval * 2, @max_poll_ms))
      else
        false
      end
    else
      true
    end
  end

  # For a group, true while any member is left.
  defp alive?(target), do: match?({_output, 0}, run_command("kill", kill_args("0", target)))

  defp kill(signal, target) do
    run_command("kill", kill_args(signal, target))
    :ok
  end

  # `kill` addresses a process group by the negated group id; `--` keeps the
  # negative number from being read as an option.
  defp kill_args(signal, {:group, os_pid}), do: ["-#{signal}", "--", "-#{os_pid}"]
  defp kill_args(signal, os_pid), do: ["-#{signal}", Integer.to_string(os_pid)]

  defp os_family do
    case :os.type() do
      {:win32, _name} -> :win32
      {:unix, _name} -> :unix
    end
  end

  # A port that is already closed reports :DOWN at once.
  defp monitor_port(port) when is_port(port), do: :erlang.monitor(:port, port)

  defp monitor_port(_no_port) do
    monitor = make_ref()
    send(self(), {:DOWN, monitor, :port, nil, :noproc})
    monitor
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp close_port(_no_port), do: :ok

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil -> {"", 127}
      executable -> System.cmd(executable, args, stderr_to_stdout: true)
    end
  rescue
    _error -> {"", 1}
  end
end
