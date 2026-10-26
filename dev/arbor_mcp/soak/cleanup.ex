defmodule Arbor.MCP.Soak.Cleanup do
  @moduledoc false

  alias Arbor.MCP.Server
  alias Arbor.RPC.Subprocess
  alias Arbor.RPC.Subprocess.Receipt

  @address {127, 0, 0, 1}

  def track_child(subprocess, previous \\ %{}, overrides \\ %{}) do
    ops = Map.merge(default_ops(), overrides)
    observed_pid = safe(fn -> ops.get_os_pid.(subprocess) end)

    pid =
      cond do
        is_integer(observed_pid) and observed_pid > 0 -> observed_pid
        Map.get(previous, :subprocess) == subprocess -> Map.get(previous, :os_pid)
        true -> nil
      end

    identity =
      if Map.get(previous, :subprocess) == subprocess and Map.get(previous, :os_pid) == pid and
           match?({:ok, _}, Map.get(previous, :os_identity)) do
        previous.os_identity
      else
        ops.os_identity.(pid)
      end

    %{subprocess: subprocess, os_pid: pid, os_identity: identity}
  end

  def child_receipt(%{subprocess: nil}), do: :not_applicable

  def child_receipt(%{subprocess: handle}) do
    case safe(fn -> Subprocess.cleanup_receipt(handle) end) do
      {:ok, %Receipt{} = receipt} ->
        case Receipt.result(receipt) do
          :ok -> :reaped
          error -> error
        end

      other ->
        other
    end
  end

  def port_free?(%{port: port}) when is_integer(port) and port > 0 do
    case :gen_tcp.listen(port, [:binary, active: false, ip: @address, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  def port_free?(%{listener: listener}) when is_pid(listener), do: :unknown_port
  def port_free?(_scenario), do: :not_applicable

  def complete?(cleanup) do
    cleanup.client_stop == :ok and cleanup.client_down in [:normal, :noproc] and
      cleanup.server_stop in [:ok, :not_owned] and
      Map.get(cleanup, :server_down, :normal) in [:normal, :noproc] and
      Map.get(cleanup, :host_stop, :not_host) in [:ok, :not_host] and
      Map.get(cleanup, :listener_down, true) in [true, :not_applicable] and
      Map.get(cleanup, :port_free, :not_applicable) in [true, :not_applicable] and
      Map.get(cleanup, :stdio_receipt, :not_applicable) in [:reaped, :not_applicable] and
      not Map.has_key?(cleanup, :forced_cleanup)
  end

  def force(scenario, cleanup, overrides \\ %{}) do
    ops = Map.merge(default_ops(), overrides)

    %{
      client: force_client(scenario, cleanup, ops),
      root: force_root(scenario, cleanup, ops),
      listener: force_listener(scenario, cleanup, ops),
      port_free: await_port_free(scenario, ops),
      child: maybe_force_child(scenario, cleanup, ops)
    }
  end

  def setup_failure(server, overrides \\ %{}) do
    ops = Map.merge(default_ops(), overrides)
    host = if Map.get(server, :owned, false), do: :not_host, else: stop_setup_host(server, ops)
    root = stop_setup_root(server, ops)
    listener_force = force_setup_listener(server, ops)

    %{
      host_stop: host,
      server_stop: root,
      listener_force: listener_force,
      listener_down: listener_down?(server, ops),
      port_free: await_port_free(server, ops)
    }
  end

  defp stop_setup_host(%{listener: listener} = server, ops) when is_pid(listener) do
    result = ops.stop_host.(server)

    forced =
      if ops.process_alive?.(listener), do: force_setup_listener(server, ops), else: :not_needed

    %{stop: result, forced: forced, down: not ops.process_alive?.(listener)}
  end

  defp stop_setup_host(_server, _ops), do: :not_started

  defp stop_setup_root(%{root: root}, ops) when is_pid(root) do
    result = ops.stop_root.(root)
    forced = if ops.process_alive?.(root), do: ops.kill_process.(root), else: :not_needed
    %{stop: result, forced: forced, down: not ops.process_alive?.(root)}
  end

  defp stop_setup_root(_server, _ops), do: :not_started

  defp force_setup_listener(%{listener: listener} = server, ops) when is_pid(listener) do
    if ops.process_alive?.(listener) or ops.port_free?.(server) != true do
      stop_ranch =
        if server.adapter == :cowboy and server.listener_ref != nil,
          do: ops.stop_ranch.(server.listener_ref),
          else: :not_applicable

      %{stop_ranch: stop_ranch, kill: ops.kill_process.(listener)}
    else
      :not_needed
    end
  end

  defp force_setup_listener(_server, _ops), do: :not_needed

  defp listener_down?(%{listener: listener}, ops) when is_pid(listener),
    do: not ops.process_alive?.(listener)

  defp listener_down?(_server, _ops), do: :not_applicable

  defp force_client(scenario, cleanup, ops) do
    if Map.get(cleanup, :client_stop) != :ok or
         Map.get(cleanup, :client_down) not in [:normal, :noproc],
       do: ops.kill_process.(scenario.client),
       else: :not_needed
  end

  defp force_root(scenario, cleanup, ops) do
    if is_pid(scenario.root) and
         (Map.get(cleanup, :server_stop) != :ok or
            Map.get(cleanup, :server_down) not in [:normal, :noproc]),
       do: ops.kill_process.(scenario.root),
       else: :not_needed
  end

  defp force_listener(scenario, cleanup, ops) do
    if is_pid(scenario.listener) and
         (Map.get(cleanup, :listener_down) != true or Map.get(cleanup, :port_free) != true or
            Map.get(cleanup, :host_stop) not in [:ok, :not_host]) do
      stop_ranch =
        if scenario.adapter == :cowboy and scenario.listener_ref != nil,
          do: ops.stop_ranch.(scenario.listener_ref),
          else: :not_applicable

      %{stop_ranch: stop_ranch, kill: ops.kill_process.(scenario.listener)}
    else
      :not_needed
    end
  end

  defp maybe_force_child(scenario, cleanup, ops) do
    if Map.get(cleanup, :stdio_receipt) not in [:not_applicable, :reaped] and
         scenario.subprocess != nil,
       do: force_child(scenario, ops),
       else: :not_needed
  end

  defp await_port_free(scenario, ops) do
    deadline = System.monotonic_time(:millisecond) + ops.wait_ms
    poll_port_free(scenario, ops, deadline)
  end

  defp poll_port_free(scenario, ops, deadline) do
    free = ops.port_free?.(scenario)

    if free in [true, :not_applicable, :unknown_port] or
         System.monotonic_time(:millisecond) >= deadline do
      free
    else
      Process.sleep(25)
      poll_port_free(scenario, ops, deadline)
    end
  end

  def force_child(scenario, overrides \\ %{}) do
    ops = Map.merge(default_ops(), overrides)
    close = ops.close_child.(scenario.subprocess)
    receipt = ops.child_receipt.(scenario)

    if receipt == :reaped do
      %{os_pid: scenario.os_pid, close: close, receipt: receipt, os_gone: true}
    else
      observed_identity = ops.os_identity.(scenario.os_pid)

      signal =
        cond do
          ops.os_gone?.(scenario.os_pid) ->
            :already_gone

          not match?({:ok, _}, Map.get(scenario, :os_identity)) or
              observed_identity != scenario.os_identity ->
            {:error, {:unverified_os_identity, scenario.os_identity, observed_identity}}

          true ->
            ops.kill_os_pid.(scenario.os_pid, scenario.os_identity)
        end

      {final_receipt, os_gone} = await_child_gone(scenario, ops)

      %{
        os_pid: scenario.os_pid,
        close: close,
        identity_check: observed_identity,
        signal: signal,
        receipt: final_receipt,
        os_gone: os_gone
      }
    end
  end

  defp await_child_gone(scenario, ops) do
    deadline = System.monotonic_time(:millisecond) + ops.wait_ms
    poll_child_gone(scenario, ops, deadline)
  end

  defp poll_child_gone(scenario, ops, deadline) do
    receipt = ops.child_receipt.(scenario)
    gone = receipt == :reaped or ops.os_gone?.(scenario.os_pid)

    if gone or System.monotonic_time(:millisecond) >= deadline do
      {receipt, gone}
    else
      Process.sleep(25)
      poll_child_gone(scenario, ops, deadline)
    end
  end

  defp default_ops do
    %{
      kill_process: &kill_process/1,
      process_alive?: &Process.alive?/1,
      stop_ranch: fn ref -> safe(fn -> :ranch.stop_listener(ref) end) end,
      stop_host: &stop_host/1,
      stop_root: fn root -> safe(fn -> Server.stop(root) end) end,
      port_free?: &port_free?/1,
      close_child: fn handle -> safe(fn -> Subprocess.close(handle) end) end,
      child_receipt: &child_receipt/1,
      get_os_pid: &Subprocess.os_pid/1,
      os_identity: &os_identity/1,
      kill_os_pid: &kill_os_pid/2,
      os_gone?: &os_gone?/1,
      wait_ms: 1_000
    }
  end

  defp stop_host(%{adapter: :cowboy, listener_ref: ref}),
    do: safe(fn -> Plug.Cowboy.shutdown(ref) end)

  defp stop_host(%{adapter: :bandit, listener: listener}),
    do: safe(fn -> Supervisor.stop(listener) end)

  defp kill_process(pid) do
    ref = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
    after
      1_000 -> :timeout
    end
  end

  defp kill_os_pid(pid, expected) when is_integer(pid) and pid > 0 do
    if os_identity(pid) == expected do
      case System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_, 0} -> :signalled
        {output, status} -> {:error, {status, String.trim(output)}}
      end
    else
      {:error, :os_identity_changed_before_signal}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp kill_os_pid(_pid, _expected), do: {:error, :missing_os_pid}

  def os_identity(pid) when is_integer(pid) and pid > 0 do
    with {start, 0} <-
           System.cmd("/bin/ps", ["-ww", "-o", "lstart=", "-p", Integer.to_string(pid)]),
         {command, 0} <-
           System.cmd("/bin/ps", ["-ww", "-o", "command=", "-p", Integer.to_string(pid)]),
         start when start != "" <- String.trim(start),
         command when command != "" <- String.trim(command) do
      {:ok, %{start: start, command: command}}
    else
      _ -> {:error, :os_identity_unavailable}
    end
  rescue
    _error -> {:error, :os_identity_unavailable}
  end

  def os_identity(_pid), do: {:error, :missing_os_pid}

  defp os_gone?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> false
      {output, _status} -> String.contains?(String.downcase(output), "no such process")
    end
  rescue
    _error -> false
  end

  defp os_gone?(_pid), do: false

  defp safe(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {kind, inspect(reason)}
  end
end
