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
  # pid can be handed to an unrelated process. So on Unix the reaper checks,
  # immediately before every signal, that the pid still names the child
  # started for this connection, by the start time recorded when the
  # connection started; when it can't check, nothing is sent. A group is
  # ours while its confirmed leader runs, or, once no process has the
  # leader's pid, while the group has members: a pid isn't handed out while
  # a process group with that id exists, so a group with that id can only
  # be the old one.
  #
  # A shutdown has a fixed budget, and close/1 waits no longer than that. So
  # the checks are cheap and none outlasts the budget: one helper shell per
  # shutdown answers them, polling with its builtin `kill -0` rather than a
  # new process per poll, and every wait for it ends at the deadline. A check
  # that can't be answered in time leaves the server unsignalled, with a
  # warning, rather than signalled late.
  #
  # Windows has no cheap check, but a pid isn't reused there while a handle
  # to the process is open, and the open port holds one. So taskkill runs
  # only on close/1, before the reaper closes the port. When the port has
  # already closed because its owner died, the server is left running, with
  # a warning: its pid may already name another process tree.

  require Logger

  @poll_ms 10
  # How long reading the child's start time may take when the connection
  # starts (it runs `ps` outside Linux).
  @identity_read_ms 5_000
  # How long killing a helper that stopped answering may take.
  @helper_kill_ms 1_000

  # Answers one request per line, prefixed with the request's number so a
  # late answer can't be taken for another's: `alive TARGET`, `signal SIG
  # TARGET`, `start PID`. TARGET is a pid, or a negated group id.
  @helper_script """
  while read -r seq cmd a b; do
    case $cmd in
      alive) if kill -s 0 -- "$a" 2>/dev/null; then echo "$seq yes"; else echo "$seq no"; fi ;;
      signal) kill -s "$a" -- "$b" 2>/dev/null; echo "$seq sent" ;;
      start)
        if s=$(ps -o lstart= -p "$a" 2>/dev/null) && [ -n "$s" ]; then
          echo "$seq start $s"
        else
          echo "$seq none"
        fi ;;
      *) echo "$seq error" ;;
    esac
  done
  """

  @type event :: :close | :server_exited | {:port_down, term()}
  @type step :: :close_port | :shutdown | :stop_group | :taskkill | :warn_left_running
  @type result :: :exited | :stopped | :killed | :not_ours | {:unconfirmed, term()}

  @doc """
  Starts the reaper of the server `os_pid` behind `port`. Options:
  `:process_group`, `:eof_grace`, `:term_grace` (already fitted to the
  budget) and `:budget` (the shutdown's bound). For tests, `:identity`
  stands in for the start time read at start, `:start_time` (a one-arity
  function of the pid) for the lookups before each signal, `:start_source`
  (`:ps`) makes them use the helper's `ps` on Linux too, `:helper_env`
  sets the helper's environment, and `:identity_read_ms` bounds the read
  at start.
  """
  @spec start(port(), pos_integer(), keyword()) :: pid()
  def start(port, os_pid, opts) when is_integer(os_pid) do
    ready = :erlang.alias([:reply])

    reaper =
      spawn(fn ->
        # Done while the connection is new, so that ending it waits on
        # neither: the helper the shutdown needs, and the server's start
        # time. A server that already exited gets nil, and nil is never
        # signalled.
        helper =
          if os_family() == :unix,
            do: open_helper(Keyword.get(opts, :helper_env, [])),
            else: :error

        identity =
          Keyword.get_lazy(opts, :identity, fn -> read_identity(helper, os_pid, opts) end)

        send(ready, {ready, :ready})
        run(port, os_pid, identity, Keyword.put(opts, :helper, helper))
      end)

    # connect/1 waits for that, a bounded time, so even a close/1 right
    # after it has both: a busy machine slows connecting rather than leave
    # a shutdown without them. Past the bound the reaper carries on alone,
    # and kills its helper if the read hangs.
    receive do
      {^ready, :ready} -> :ok
    after
      Keyword.get(opts, :identity_read_ms, @identity_read_ms) -> :erlang.unalias(ready)
    end

    reaper
  end

  @doc "Asks the reaper to close the port and stop the server, from now."
  @spec close(pid()) :: :ok
  def close(reaper) when is_pid(reaper) do
    send(reaper, {:close, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Tells the reaper the server exited on its own."
  @spec server_exited(pid() | nil) :: :ok
  def server_exited(reaper) when is_pid(reaper) do
    send(reaper, :server_exited)
    :ok
  end

  def server_exited(_no_reaper), do: :ok

  @doc """
  The steps a reaper takes, in order, when `event` ends the connection on
  `os_family` (`:unix` or `:win32`). `:shutdown` and `:stop_group` signal
  only a server or group they can confirm as the connection's own.
  """
  @spec steps(:unix | :win32, event()) :: [step()]
  # What the server left in its group (process_group: true) is still ours.
  def steps(:unix, :server_exited), do: [:stop_group]
  def steps(:win32, :server_exited), do: []
  def steps(:unix, :close), do: [:close_port, :shutdown]
  def steps(:unix, {:port_down, _reason}), do: [:shutdown]
  # The open port holds the process handle, so the pid is still the server's.
  def steps(:win32, :close), do: [:taskkill, :close_port]
  # The server exited, or its owner did normally: nothing to stop.
  def steps(:win32, {:port_down, :normal}), do: []
  def steps(:win32, {:port_down, _abnormal}), do: [:warn_left_running]

  defp run(port, os_pid, identity, opts) do
    monitor = monitor_port(port)

    # The budget runs from the end of the connection: for close/1, from
    # when it was called.
    {event, ended_at} =
      receive do
        {:close, closed_at} -> {:close, closed_at}
        :server_exited -> {:server_exited, now()}
        {:DOWN, ^monitor, :port, _port, reason} -> {{:port_down, reason}, now()}
      end

    deadline = ended_at + Keyword.fetch!(opts, :budget)
    opts = Keyword.put(opts, :ended_at, ended_at)

    try do
      os_family()
      |> steps(event)
      |> Enum.each(&step(&1, port, os_pid, identity, opts, deadline))
    after
      # An idle helper exits on EOF once its port closes, with the reaper;
      # one that stopped answering was killed when it did.
      with {:ok, helper} <- Keyword.get(opts, :helper), do: close_port(helper.port)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The start time when the connection starts: from /proc on Linux, else
  # from the helper's `ps`, given at most @identity_read_ms.
  defp read_identity(helper, os_pid, opts) do
    case {:os.type(), Keyword.get(opts, :start_source)} do
      {{:unix, :linux}, nil} ->
        linux_start_time(os_pid)

      {{:unix, _other}, _source} ->
        read_until = now() + Keyword.get(opts, :identity_read_ms, @identity_read_ms)

        with {:ok, helper} <- helper,
             {:ok, "start " <> start} <- ask(helper, "start #{os_pid}", read_until) do
          {:ps, String.trim(start)}
        else
          _unreadable -> nil
        end

      {{:win32, _name}, _source} ->
        nil
    end
  end

  defp step(:close_port, port, _os_pid, _identity, _opts, _deadline), do: close_port(port)

  defp step(:shutdown, _port, os_pid, identity, opts, deadline),
    do: report(os_pid, shutdown(os_pid, identity, opts, deadline))

  defp step(:stop_group, _port, os_pid, identity, opts, deadline) do
    if Keyword.get(opts, :process_group, false),
      do: report(os_pid, shutdown(os_pid, identity, opts, deadline))
  end

  defp step(:taskkill, _port, os_pid, _identity, _opts, deadline) do
    run_bounded("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"], time_left(deadline))
  end

  defp step(:warn_left_running, _port, os_pid, _identity, _opts, _deadline) do
    Logger.warning(
      "stdio server #{os_pid} may be left running: its connection's owner died before " <>
        "closing it, and on Windows its pid can no longer be confirmed"
    )
  end

  defp report(os_pid, {:unconfirmed, reason}) do
    Logger.warning(
      "stdio server #{os_pid} was not signalled: it could not be confirmed as the " <>
        "connection's process in time (#{inspect(reason)})"
    )
  end

  defp report(_os_pid, _result), do: :ok

  @doc false
  # Runs the shutdown order on the server `os_pid` (or its group) by
  # `deadline`: waits out the EOF grace, then SIGTERM, then SIGKILL after
  # the TERM grace, each signal only after confirming, just before it, that
  # the target is still the connection's own.
  @spec shutdown(pos_integer(), term() | nil, keyword(), integer()) :: result()
  def shutdown(os_pid, identity, opts, deadline) do
    # The EOF grace runs from the end of the connection, as the budget does.
    started = Keyword.get_lazy(opts, :ended_at, &now/0)
    term_at = min(started + Keyword.fetch!(opts, :eof_grace), deadline)

    case live_helper(opts) do
      {:ok, helper} ->
        target = %{
          pid: os_pid,
          group?: Keyword.get(opts, :process_group, false),
          identity: identity,
          start_time: Keyword.get(opts, :start_time),
          start_source: Keyword.get(opts, :start_source),
          term_grace: Keyword.fetch!(opts, :term_grace),
          kill_at: min(term_at + Keyword.fetch!(opts, :term_grace), deadline),
          helper: helper,
          deadline: deadline
        }

        try do
          escalate(target, term_at, deadline)
        after
          close_port(helper.port)
        end

      :error ->
        {:unconfirmed, :no_helper}
    end
  end

  # The connection's helper, unless it was killed (it stopped answering):
  # then a new one.
  defp live_helper(opts) do
    env = Keyword.get(opts, :helper_env, [])

    case Keyword.get(opts, :helper) do
      {:ok, %{port: port} = helper} ->
        if Port.info(port), do: {:ok, helper}, else: open_helper(env)

      _none ->
        open_helper(env)
    end
  end

  defp escalate(target, term_at, deadline) do
    case confirm(target, deadline) do
      :ours -> after_eof(target, term_at, deadline)
      other -> other
    end
  end

  defp after_eof(target, term_at, deadline) do
    with :running <- exited_by(target, term_at),
         :sent <- signal_if_ours(target, "TERM", deadline) do
      kill_at = target.kill_at
      after_term(target, kill_at, deadline)
    else
      # Exited during the grace, or gone (and its pid maybe reused) since.
      gone when gone in [:exited, :not_ours] -> :exited
      unconfirmed -> unconfirmed
    end
  end

  defp after_term(target, kill_at, deadline) do
    with :running <- exited_by(target, kill_at),
         :sent <- signal_if_ours(target, "KILL", deadline) do
      # A killed process stays visible (a zombie) until its parent reaps
      # it, which a busy VM can delay: close/1 returns once it is gone.
      exited_by(target, deadline)
      :killed
    else
      gone when gone in [:exited, :not_ours] -> :stopped
      unconfirmed -> unconfirmed
    end
  end

  # The target is confirmed again just before each signal: it may have
  # exited, and its pid or group id been handed on, since the last check.
  defp signal_if_ours(target, signal, deadline) do
    case confirm(target, deadline) do
      :ours ->
        case ask(target.helper, "signal #{signal} #{target_id(target)}", deadline) do
          {:ok, "sent"} -> :sent
          _late -> {:unconfirmed, :signal_timeout}
        end

      other ->
        other
    end
  end

  # Whether the target is still the connection's own, checked now. A
  # running pid that can't be confirmed is never taken for the server.
  defp confirm(%{identity: nil} = target, deadline) do
    # No start time was recorded: the server can't be told from another
    # process with its pid, but a group whose leader is gone still can.
    case {alive(target.helper, target.pid, deadline), target.group?} do
      {:yes, _group?} -> {:unconfirmed, :identity_unknown}
      {:no, true} -> group_rule(target, deadline)
      {:no, false} -> :not_ours
      {:timeout, _group?} -> {:unconfirmed, :identity_timeout}
    end
  end

  defp confirm(%{group?: false} = target, deadline) do
    case start_time(target, deadline) do
      {:ok, start} when start == target.identity -> :ours
      # Another process has the pid now.
      {:ok, _other_process} -> :not_ours
      :none -> gone_or_unconfirmed(target, deadline, fn -> :not_ours end)
      :timeout -> {:unconfirmed, :identity_timeout}
    end
  end

  defp confirm(%{group?: true} = target, deadline) do
    case start_time(target, deadline) do
      {:ok, start} when start == target.identity -> :ours
      # Another process has the leader's pid, so the leader's group is
      # gone: a group id isn't reused while the group has members.
      {:ok, _other_process} -> :not_ours
      :none -> gone_or_unconfirmed(target, deadline, fn -> group_rule(target, deadline) end)
      :timeout -> {:unconfirmed, :identity_timeout}
    end
  end

  # No process has the leader's pid, so a group with that id can only be
  # the leader's: ours while it has members.
  defp group_rule(target, deadline) do
    case alive(target.helper, -target.pid, deadline) do
      :yes -> :ours
      :no -> :not_ours
      :timeout -> {:unconfirmed, :identity_timeout}
    end
  end

  # The start time couldn't be read: the pid has gone (then `gone` decides),
  # or it runs and can't be confirmed.
  defp gone_or_unconfirmed(target, deadline, gone) do
    case alive(target.helper, target.pid, deadline) do
      :yes -> {:unconfirmed, :identity_unreadable}
      :no -> gone.()
      :timeout -> {:unconfirmed, :identity_timeout}
    end
  end

  # Polls until the target exits or `until`; `:running` at `until`. An
  # answer may come past `until`, not past the deadline: a helper that
  # doesn't answer by then is killed, and nothing is confirmed.
  defp exited_by(target, until) do
    case alive(target.helper, target_id(target), target.deadline) do
      :no ->
        :exited

      :yes ->
        if now() >= until do
          :running
        else
          Process.sleep(min(@poll_ms, time_left(until)))
          exited_by(target, until)
        end

      :timeout ->
        {:unconfirmed, :helper_timeout}
    end
  end

  defp target_id(%{group?: true, pid: pid}), do: -pid
  defp target_id(%{pid: pid}), do: pid

  defp alive(helper, id, deadline) do
    case ask(helper, "alive #{id}", deadline) do
      {:ok, "yes"} -> :yes
      {:ok, "no"} -> :no
      _late -> :timeout
    end
  end

  defp start_time(%{start_time: lookup} = target, deadline) when is_function(lookup, 1) do
    task = Task.async(fn -> lookup.(target.pid) end)

    case Task.yield(task, time_left(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, nil} -> :none
      {:ok, start} -> {:ok, start}
      _late -> :timeout
    end
  end

  defp start_time(target, deadline) do
    case {:os.type(), target.start_source} do
      {{:unix, :linux}, nil} ->
        case linux_start_time(target.pid) do
          nil -> :none
          start -> {:ok, start}
        end

      _ps ->
        case ask(target.helper, "start #{target.pid}", deadline) do
          {:ok, "start " <> start} -> {:ok, {:ps, String.trim(start)}}
          {:ok, _none} -> :none
          _late -> :timeout
        end
    end
  end

  @doc false
  # Starts a helper shell, recording its OS pid. As a port program it leads
  # its own process group, which holds the `ps` it may be waiting on.
  @spec open_helper([{String.t(), String.t()}]) :: {:ok, map()} | :error
  def open_helper(env \\ []) do
    case System.find_executable("sh") do
      nil ->
        :error

      sh ->
        port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            line: 4_096,
            args: ["-c", @helper_script],
            env: Enum.map(env, fn {name, value} -> {~c"#{name}", ~c"#{value}"} end)
          ])

        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> {:ok, %{port: port, os_pid: os_pid, seq: :counters.new(1, [])}}
          nil -> :error
        end
    end
  catch
    :error, _reason -> :error
  end

  # Sends one request and waits for its answer until `deadline`. A helper
  # that doesn't answer in time may be stalled, holding this request (a
  # signal, say) to run later: it is killed, so nothing it holds can run
  # after the reaper has decided without it.
  defp ask(%{port: port, seq: seq} = helper, request, deadline) do
    :counters.add(seq, 1, 1)
    n = Integer.to_string(:counters.get(seq, 1))
    Port.command(port, [n, " ", request, "\n"])

    case await_answer(port, n, deadline) do
      :timeout ->
        kill_helper(helper)
        :timeout

      answer ->
        answer
    end
  catch
    :error, _reason -> :error
  end

  # Kills the helper and its group (a `ps` it waits on), and waits for its
  # exit to be reported, a bounded time.
  defp kill_helper(%{port: port, os_pid: os_pid}) do
    if Port.info(port) do
      run_bounded("kill", ["-KILL", "--", "-#{os_pid}"], @helper_kill_ms)

      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        @helper_kill_ms -> :ok
      end

      close_port(port)
    end

    :ok
  end

  defp await_answer(port, n, deadline) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case :binary.split(line, " ") do
          [^n, answer] -> {:ok, answer}
          # A late answer to an earlier request.
          _other -> await_answer(port, n, deadline)
        end

      {^port, {:exit_status, _status}} ->
        :error
    after
      time_left(deadline) -> :timeout
    end
  end

  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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
    case run_bounded("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)], @identity_read_ms) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          start -> {:ps, start}
        end

      _gone_or_late ->
        nil
    end
  end

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
