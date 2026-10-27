defmodule ExMCP.Transport.Stdio do
  @moduledoc """
  This module implements the standard MCP specification.

  stdio transport implementation for MCP.

  This transport communicates with MCP servers over standard input/output,
  typically by spawning a subprocess. This is one of the two official MCP
  transports defined in the specification.

  ## Options

  - `:command` - Command and arguments to spawn (required)
  - `:cd` - Working directory for the process
  - `:env` - Environment variables as a list of `{"KEY", "VALUE"}` tuples;
    use `{"KEY", false}` to remove an inherited variable from the child
  - `:environment_policy` - `:isolated` (default) passes only a small runtime
    allowlist plus explicit `:env`; `:inherit` preserves the parent environment
    for explicitly trusted deployments
  - `:max_frame_bytes` - maximum inbound or outbound JSON-RPC frame size
    (default: 1 MiB)
  - `:process_group` - when `true`, stopping the server signals its whole
    process group rather than the one process the port started (default:
    `false`). See "Process groups" below.
  - `:eof_grace` - time in milliseconds to wait for the server to exit after
    stdin closes before sending SIGTERM (default: 2_000)
  - `:term_grace` - time in milliseconds to wait after SIGTERM before sending
    SIGKILL (default: 100)
  - `:cleanup_timeout` - subprocess shutdown budget, defaulting to
    `eof_grace + term_grace + 400` (default: 2_500). SIGKILL goes out within
    it, the graces shortened if they don't fit, and `close/1` returns within
    it plus 500 ms. The shutdown is run by a process started with the
    connection, which acts when the port closes, so it completes even if the
    process that owns the connection dies first, before or during `close/1`.
    It signals only the process (or process group) the connection started:
    a server that exited on its own is left alone. On Windows, which has no
    cheap way to confirm a pid, `taskkill` runs only from `close/1`, while
    the port still holds the server's process handle. A server whose
    connection owner dies before closing it may therefore be left running
    on Windows, and a warning is logged.

  The command is resolved against the `PATH` the child will see (an explicit
  `PATH` in `:env`, else the inherited one), not the VM's own. When the VM
  runs as an OTP release, the release's own directories are dropped from the
  inherited `PATH` (see `RELEASE_ROOT`), so a server that is itself an Erlang
  or Elixir program does not pick up the release's `erl`.

  ## Process groups

  ERTS starts every port program as the leader of a new process group. By
  default `close/1` sends SIGTERM, then SIGKILL, to that one process, so
  processes the server started (a launcher's or shell script's children),
  and a child that ignores SIGTERM, can outlive the connection.
  With `process_group: true`, `close/1` signals the whole group instead, and
  when the server exits on its own, whatever it left running in its group is
  signalled too. A descendant that leaves the group on purpose (`setsid`) is
  not reached. Process groups are a Unix feature; on Windows the option has
  no effect and `taskkill /T` already stops the tree.

  ## Example

      {:ok, client} = ExMCP.Client.start_link(
        transport: :stdio,
        command: ["node", "my-mcp-server.js"],
        cd: "/path/to/server",
        env: [{"NODE_ENV", "production"}]
      )
  """

  @behaviour ExMCP.Transport

  require Logger

  alias ExMCP.Internal.{LineBuffer, LogSummary, Options, PortEnvironment, SecurityConfig}
  alias ExMCP.Transport.{Error, SecurityGuard}
  alias ExMCP.Transport.Stdio.Reaper

  @eof_grace 2_000
  @term_grace 100
  @shutdown_slack 400
  # Kept back from the cleanup budget for sending SIGKILL.
  @kill_allowance 50
  # What close/1 allows past the budget for the shutdown to be confirmed.
  @reply_allowance 500
  @default_max_frame_bytes 1_048_576
  defstruct [
    :port,
    :os_pid,
    :line_buffer,
    :subscriber,
    :reader_pid,
    # Stops the server when the connection ends (see Stdio.Reaper).
    :reaper,
    max_frame_bytes: @default_max_frame_bytes,
    process_group: false,
    eof_grace: @eof_grace,
    term_grace: @term_grace,
    cleanup_timeout: @eof_grace + @term_grace + @shutdown_slack
  ]

  @impl true
  def connect(opts) do
    opts = shutdown_options(opts)

    with :ok <- PortEnvironment.validate_policy(opts),
         :ok <- validate_process_group(opts),
         :ok <- validate_shutdown_options(opts) do
      do_connect(opts)
    end
  end

  @doc false
  # Subprocess shutdown options for an MCP server. Explicit values win; a
  # caller-chosen budget keeps whatever EOF grace still fits inside it.
  def shutdown_options(opts) do
    term_grace = Keyword.get(opts, :term_grace, @term_grace)

    case {Keyword.fetch(opts, :eof_grace), Keyword.fetch(opts, :cleanup_timeout)} do
      _ when not is_integer(term_grace) ->
        opts

      {:error, :error} ->
        opts
        |> Keyword.put(:eof_grace, @eof_grace)
        |> Keyword.put(:cleanup_timeout, @eof_grace + term_grace + @shutdown_slack)

      {{:ok, eof_grace}, :error} when is_integer(eof_grace) ->
        Keyword.put(opts, :cleanup_timeout, eof_grace + term_grace + @shutdown_slack)

      {:error, {:ok, budget}} when is_integer(budget) ->
        Keyword.put(opts, :eof_grace, min(@eof_grace, max(0, budget - term_grace - 50)))

      _explicit_or_invalid ->
        opts
    end
  end

  @doc false
  # How long the client must allow `close/1`: the subprocess budget plus the
  # helper's reply allowance.
  def close_budget(opts) do
    case Keyword.get(shutdown_options(opts), :cleanup_timeout) do
      budget when is_integer(budget) and budget > 0 -> budget + @reply_allowance
      _invalid -> nil
    end
  end

  defp validate_process_group(opts) do
    case Keyword.get(opts, :process_group, false) do
      flag when is_boolean(flag) -> :ok
      invalid -> {:error, {:invalid_process_group, invalid}}
    end
  end

  # Every shutdown option given, nil included, must be usable before the
  # server is started: the reaper's schedule is built from them.
  defp validate_shutdown_options(opts) do
    Enum.reduce_while([eof_grace: 0, term_grace: 0, cleanup_timeout: 1], :ok, fn
      {name, min}, :ok ->
        case Keyword.fetch(opts, name) do
          :error -> {:cont, :ok}
          {:ok, value} when is_integer(value) and value >= min -> {:cont, :ok}
          {:ok, invalid} -> {:halt, {:error, {:invalid_shutdown_option, name, invalid}}}
        end
    end)
  end

  @doc false
  # The EOF and SIGTERM graces close/1 waits, shortened if need be so that
  # SIGKILL goes out within the cleanup budget.
  def shutdown_schedule(%__MODULE__{} = state) do
    available = max(state.cleanup_timeout - @kill_allowance, 0)
    eof_grace = min(state.eof_grace, available)
    {eof_grace, min(state.term_grace, available - eof_grace)}
  end

  defp do_connect(opts) do
    command = Keyword.fetch!(opts, :command)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      :stream,
      line: 1_000_000,
      args: tl(command),
      env: safe_env(opts)
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        dir -> [{:cd, to_charlist(dir)} | port_opts]
      end

    executable = hd(command)

    # Try to find the executable in common locations if it's not a full path
    executable_path =
      if Path.type(executable) == :absolute do
        executable
      else
        case find_executable(executable, PortEnvironment.child_path(opts)) do
          nil ->
            # Try common locations for node/npm/npx on macOS
            common_paths = [
              "/opt/homebrew/bin/#{executable}",
              "/usr/local/bin/#{executable}",
              "/usr/bin/#{executable}",
              "#{System.get_env("HOME")}/.nvm/versions/node/#{System.get_env("NODE_VERSION", "*")}/bin/#{executable}"
            ]

            Enum.find(common_paths, executable, &File.exists?/1)

          path ->
            path
        end
      end

    try do
      Port.open({:spawn_executable, to_charlist(executable_path)}, port_opts)
    catch
      :error, reason -> Error.connection_error({:spawn_failed, reason})
    else
      port -> connected(port, executable_path, opts)
    end
  end

  # Once the port is open, a failure closes it again rather than leaving a
  # server running without a reaper.
  defp connected(port, executable_path, opts) do
    state = %__MODULE__{
      port: port,
      os_pid: port_os_pid(port),
      line_buffer: "",
      max_frame_bytes: Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes),
      process_group: Keyword.get(opts, :process_group, false),
      eof_grace: Keyword.get(opts, :eof_grace, @eof_grace),
      term_grace: Keyword.get(opts, :term_grace, @term_grace),
      cleanup_timeout:
        Keyword.get(opts, :cleanup_timeout, @eof_grace + @term_grace + @shutdown_slack)
    }

    state = %{state | reaper: start_reaper(state)}

    :telemetry.execute([:ex_mcp, :transport, :connection, :opened], %{}, %{
      transport: :stdio,
      command_basename: Path.basename(executable_path),
      command_hash: LogSummary.fingerprint(executable_path)
    })

    {:ok, state}
  catch
    kind, reason ->
      close_port(port)
      Error.connection_error({:spawn_failed, {kind, reason}})
  end

  @impl true
  def send_message(message, %__MODULE__{port: port} = state) do
    # Check if message contains external resource requests that need security validation
    case request_within_limit(message, state.max_frame_bytes) do
      {:error, :frame_too_large} = error ->
        error

      :ok ->
        do_send_message(message, port, state)
    end
  end

  defp do_send_message(message, port, state) do
    case validate_stdio_message(message, state) do
      {:ok, validated_message} ->
        # MCP uses newline-delimited JSON
        data = validated_message <> "\n"

        :telemetry.execute([:ex_mcp, :transport, :message, :sent], %{size: byte_size(message)}, %{
          transport: :stdio
        })

        try do
          Port.command(port, data)
          {:ok, state}
        catch
          :error, reason ->
            Error.transport_error({:send_failed, reason})
        end

      {:error, security_error} ->
        Logger.warning("Stdio message blocked by security policy",
          error: security_error
        )

        Error.security_violation(security_error)
    end
  end

  defp validate_stdio_message(message, state) do
    # Step 1: Validate that message does not contain embedded newlines
    # MCP specification: "Messages are delimited by newlines, and MUST NOT contain embedded newlines"
    case validate_no_embedded_newlines(message) do
      :ok ->
        # Step 2: Validate that message is valid JSON
        case validate_json_format(message) do
          {:ok, parsed_message} ->
            # Step 3: Validate JSON-RPC 2.0 structure
            case validate_jsonrpc_structure(parsed_message) do
              :ok ->
                # Step 4: Check for external resource requests that need security validation
                validate_security_requirements(parsed_message, message, state)

              {:error, validation_error} ->
                Error.validation_error({:invalid_jsonrpc, validation_error})
            end

          {:error, json_error} ->
            Error.validation_error({:invalid_json, json_error})
        end

      {:error, newline_error} ->
        Error.validation_error({:embedded_newline, newline_error})
    end
  end

  defp validate_no_embedded_newlines(message) do
    if String.contains?(message, "\n") do
      {:error,
       "Message contains embedded newlines which violate MCP stdio transport requirements"}
    else
      :ok
    end
  end

  defp validate_json_format(message) do
    case Jason.decode(message) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, error} ->
        {:error, "Invalid JSON format: #{inspect(error)}"}
    end
  end

  defp validate_jsonrpc_structure(parsed_message) when is_map(parsed_message) do
    # Validate JSON-RPC 2.0 structure according to specification
    cond do
      not Map.has_key?(parsed_message, "jsonrpc") ->
        {:error, "Missing required 'jsonrpc' field"}

      parsed_message["jsonrpc"] != "2.0" ->
        {:error, "Invalid jsonrpc version, must be '2.0'"}

      # For requests, must have method and optionally id
      Map.has_key?(parsed_message, "method") ->
        validate_jsonrpc_request(parsed_message)

      # For responses, must have id and either result or error
      Map.has_key?(parsed_message, "id") ->
        validate_jsonrpc_response(parsed_message)

      true ->
        {:error, "Invalid JSON-RPC structure: must be request, response, or notification"}
    end
  end

  defp validate_jsonrpc_structure(parsed_message) when is_list(parsed_message) do
    # JSON-RPC batch request - validate each item
    if parsed_message == [] do
      {:error, "Empty batch requests are not allowed"}
    else
      Enum.reduce_while(parsed_message, :ok, fn item, _acc ->
        case validate_jsonrpc_structure(item) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, "Batch item invalid: #{error}"}}
        end
      end)
    end
  end

  defp validate_jsonrpc_structure(_parsed_message) do
    {:error, "JSON-RPC message must be an object or array"}
  end

  defp validate_jsonrpc_request(request) do
    cond do
      not is_binary(request["method"]) ->
        {:error, "Method must be a string"}

      String.starts_with?(request["method"], "rpc.") ->
        {:error, "Methods starting with 'rpc.' are reserved"}

      Map.has_key?(request, "id") and is_nil(request["id"]) ->
        {:error, "Request id cannot be null"}

      true ->
        :ok
    end
  end

  defp validate_jsonrpc_response(response) do
    has_result = Map.has_key?(response, "result")
    has_error = Map.has_key?(response, "error")

    cond do
      has_result and has_error ->
        {:error, "Response cannot have both result and error"}

      not has_result and not has_error ->
        {:error, "Response must have either result or error"}

      true ->
        :ok
    end
  end

  defp validate_security_requirements(parsed_message, original_message, state) do
    # Check for external resource requests that need security validation
    case parsed_message do
      %{"method" => "resources/read", "params" => %{"uri" => uri}} ->
        validate_resource_access(uri, original_message, state)

      %{"method" => "resources/list", "params" => %{"uri" => uri}} when is_binary(uri) ->
        validate_resource_access(uri, original_message, state)

      _ ->
        # Non-resource request, allow through
        {:ok, original_message}
    end
  end

  defp validate_resource_access(uri, message, state) do
    # Only validate if URI appears to be external (has scheme and host)
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        # This is an external resource, validate with SecurityGuard
        security_request = %{
          url: uri,
          headers: [],
          method: "GET",
          transport: :stdio,
          user_id: extract_stdio_user_id(state)
        }

        config = SecurityConfig.get_transport_config(:stdio)

        case SecurityGuard.validate_request(security_request, config) do
          {:ok, _sanitized_request} ->
            {:ok, message}

          {:error, security_error} ->
            {:error, security_error}
        end

      _ ->
        # Local/relative URI, allow through
        {:ok, message}
    end
  end

  defp extract_stdio_user_id(_state) do
    # Use system user as default for stdio transport
    System.get_env("USER") || System.get_env("USERNAME") || "stdio_user"
  end

  @impl true
  def receive_message(%__MODULE__{} = state) do
    receive_message(state, :infinity)
  end

  @doc """
  Receives a single message, waiting at most `timeout` milliseconds.

  Callers must run this in the process that owns the port (or in one that may
  take ownership): port ownership is transferred to the caller, and an OTP port
  is closed when its owner exits. Running it in a short-lived helper process
  would therefore kill the spawned program — which is why the handshake path
  uses this timeout-aware clause in-process instead of wrapping
  `receive_message/1` in a task.
  """
  @spec receive_message(%__MODULE__{}, timeout()) ::
          {:ok, binary(), %__MODULE__{}} | {:error, any()}
  def receive_message(%__MODULE__{port: port} = state, timeout) do
    take_ownership(port)
    receive_loop(state, timeout)
  end

  # Transfer port ownership to this process if needed. A port that has
  # already closed cannot be connected; its last messages (the exit status
  # among them) are already in the owner's mailbox for receive_loop/2.
  defp take_ownership(port) do
    case Port.info(port, :connected) do
      {:connected, owner} when owner == self() -> :ok
      {:connected, _other} -> Port.connect(port, self())
      nil -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def close(%__MODULE__{port: port, reader_pid: reader_pid} = state) do
    :telemetry.execute([:ex_mcp, :transport, :connection, :closed], %{}, %{transport: :stdio})

    # A state built without connect/1 has no reaper yet.
    reaper = state.reaper || start_reaper(state)

    # The reaper sends SIGKILL (or runs taskkill) within the cleanup budget;
    # close/1 allows it a little more to confirm, and returns either way.
    deadline = System.monotonic_time(:millisecond) + state.cleanup_timeout + @reply_allowance

    # Close the port before killing the reader: port_close exits the port
    # with reason :normal, which linked processes ignore, whereas killing
    # the port's owner (the reader, in push mode) first would cascade a
    # :killed exit through the port to its other linked processes.
    close_port_through(reaper, port, deadline)

    if is_pid(reader_pid) and Process.alive?(reader_pid) do
      # The reader is a plain spawn_link receive loop that does not trap
      # exits, so an exit signal with reason :normal would be silently
      # ignored and leak the process. Unlink first so the kill cannot
      # cascade to the caller, then terminate it unconditionally.
      Process.unlink(reader_pid)
      Process.exit(reader_pid, :kill)
    end

    await_reaper(reaper, time_left(deadline))
    :ok
  end

  # Port.close/1 tears down the Erlang port, but it does not guarantee that
  # the spawned OS process exits. The reaper, started with the connection
  # and linked to nothing, stops the server when the connection ends: on
  # close/1, or when the port's owner dies (a client killed by its
  # supervisor before or during close/1, say). Repeated stdio connections
  # therefore cannot leak servers and exhaust the runner's process/thread
  # budget. See ExMCP.Transport.Stdio.Reaper.
  defp start_reaper(%__MODULE__{port: port, os_pid: os_pid} = state)
       when is_port(port) and is_integer(os_pid) do
    {eof_grace, term_grace} = shutdown_schedule(state)

    Reaper.start(port, os_pid,
      process_group: state.process_group,
      eof_grace: eof_grace,
      term_grace: term_grace,
      budget: state.cleanup_timeout
    )
  end

  defp start_reaper(_state), do: nil

  # The reaper closes the port itself, so it knows the close was asked for.
  # On Windows it runs taskkill first, while the open port still holds the
  # server's process handle, so close/1 leaves the port open until then.
  defp close_port_through(nil, port, _deadline), do: close_port(port)

  defp close_port_through(reaper, port, deadline) when is_port(port) do
    monitor = :erlang.monitor(:port, port)
    Reaper.close(reaper)

    receive do
      {:DOWN, ^monitor, :port, _port, _reason} -> :ok
    after
      time_left(deadline) ->
        :erlang.demonitor(monitor, [:flush])
        close_port(port)
    end
  end

  defp close_port_through(_reaper, _no_port, _deadline), do: :ok

  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await_reaper(nil, _budget), do: :ok

  defp await_reaper(reaper, budget) do
    monitor = Process.monitor(reaper)

    receive do
      {:DOWN, ^monitor, :process, ^reaper, _reason} -> :ok
    after
      budget ->
        Process.demonitor(monitor, [:flush])
        :ok
    end
  end

  # A server that exits on its own is not signalled by anyone, so what it
  # left running in its group would outlive the connection. The group keeps
  # the leader's pid as its id after the leader is gone; a pid is not reused
  # while a group with that id still has members, so the risk accepted here
  # is only a group that emptied and whose id was handed to a new group
  # leader within the grace period. Runs in its own process so neither the
  # client nor the reader waits for it.
  defp reap_group(%__MODULE__{process_group: true, os_pid: os_pid, eof_grace: eg, term_grace: tg})
       when is_integer(os_pid) do
    spawn(fn -> Reaper.stop_group(os_pid, eg, tg) end)
    :ok
  end

  defp reap_group(%__MODULE__{}), do: :ok

  defp reap_group(os_pid) when is_integer(os_pid) do
    spawn(fn -> Reaper.stop_group(os_pid, @eof_grace, @term_grace) end)
    :ok
  end

  defp reap_group(_other), do: :ok

  # Tolerate a port that is nil or already closed (e.g. the spawned process
  # exited on its own before close/1 was called).
  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _other -> nil
    end
  end

  defp find_executable(name, nil), do: System.find_executable(name)

  # :os.find_executable/2 searches an explicit path with the platform's own
  # rules: its path separator, the execute bit on Unix, and the executable
  # extensions on Windows. A name with a directory is not searched for.
  defp find_executable(name, path) do
    if String.contains?(name, ["/", "\\"]) do
      System.find_executable(name)
    else
      case :os.find_executable(String.to_charlist(name), String.to_charlist(path)) do
        false -> nil
        found -> List.to_string(found)
      end
    end
  end

  @impl true
  def connected?(%__MODULE__{port: port}) do
    Port.info(port) != nil
  end

  # The port is linked to the process that opened it, and stays linked to it
  # after subscribe/2 hands ownership to the reader, which is spawn_linked.
  @impl true
  def linked_processes(%__MODULE__{port: port, reader_pid: reader_pid}) do
    Enum.filter([port, reader_pid], &(is_port(&1) or is_pid(&1)))
  end

  @doc """
  Subscribe to receive transport events (push model).

  Spawns an internal reader process that takes over port ownership,
  reads and parses JSON messages, and pushes them to the subscriber.
  """
  @impl true
  def subscribe(pid, %__MODULE__{port: port} = state) when is_pid(pid) do
    # Spawn the reader first, then transfer port ownership from the caller
    # (the current port owner). Transferring from the caller instead of from
    # inside the reader avoids a race where the port dies before the reader
    # is scheduled, which would crash the subscriber through the link.
    # What the reader needs once the server exits: its group, if it leads
    # one, and its reaper.
    exit_info = {if(state.process_group, do: state.os_pid), state.reaper}

    reader =
      spawn_link(fn ->
        receive do
          :port_transferred -> stdio_reader_loop(port, "", pid, state.max_frame_bytes, exit_info)
        end
      end)

    try do
      Port.connect(port, reader)
      send(reader, :port_transferred)
      {:ok, %{state | subscriber: pid, reader_pid: reader}}
    rescue
      ArgumentError ->
        Process.unlink(reader)
        Process.exit(reader, :kill)
        {:error, :port_closed}
    end
  end

  @impl true
  def capabilities(%__MODULE__{}), do: [:push]

  # Testing support - expose process_data for unit tests
  @doc false
  def process_data(data, state), do: do_process_data(data, state)

  # Private functions

  # `timeout` bounds the wait for a *complete* line: each partial chunk resets
  # the remaining budget only by the time already spent, so a slow-drip server
  # cannot extend the deadline indefinitely.
  defp receive_loop(state, timeout) do
    started = System.monotonic_time(:millisecond)

    receive do
      {port, {:data, data}} when port == state.port ->
        do_process_data(data, state, remaining(timeout, started))

      {port, {:exit_status, status}} when port == state.port ->
        Reaper.server_exited(state.reaper)
        reap_group(state)
        Error.connection_error({:process_exited, status})

      {port, :eof} when port == state.port ->
        Error.connection_error(:eof)
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp remaining(:infinity, _started), do: :infinity

  defp remaining(timeout, started) do
    max(timeout - (System.monotonic_time(:millisecond) - started), 0)
  end

  defp do_process_data(data, state, timeout \\ :infinity) do
    # Handle both binary and :eol tuple format from port
    binary_data =
      case data do
        {:eol, line} -> line <> "\n"
        {:noeol, line} -> line
        binary when is_binary(binary) -> binary
        _ -> ""
      end

    # Accumulate data until we have a complete line, but never retain an
    # attacker-controlled delimiter-free frame beyond the configured bound.
    with {:ok, new_buffer} <- append_frame(state.line_buffer, binary_data, state.max_frame_bytes) do
      process_received_buffer(new_buffer, state, timeout)
    end
  end

  defp process_received_buffer(new_buffer, state, timeout) do
    case String.split(new_buffer, "\n", parts: 2) do
      [line, rest] ->
        # We have a complete line
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            # Empty line, continue
            receive_loop(%{state | line_buffer: rest}, timeout)

          # Skip non-JSON output like "Secure MCP Filesystem Server..."
          not String.starts_with?(trimmed, "{") and not String.starts_with?(trimmed, "[") ->
            Logger.debug("Skipping non-JSON output", line_shape: LogSummary.describe(trimmed))
            receive_loop(%{state | line_buffer: rest}, timeout)

          true ->
            # Return the JSON line and update state
            :telemetry.execute(
              [:ex_mcp, :transport, :message, :received],
              %{size: byte_size(trimmed)},
              %{transport: :stdio}
            )

            {:ok, trimmed, %{state | line_buffer: rest}}
        end

      [partial] ->
        # No complete line yet, keep buffering
        receive_loop(%{state | line_buffer: partial}, timeout)
    end
  end

  # Internal reader process for push mode.
  # Reads port data, buffers lines, parses JSON, pushes to subscriber.
  defp stdio_reader_loop(port, line_buffer, subscriber, max_frame_bytes, exit_info) do
    receive do
      {^port, {:data, data}} ->
        binary_data =
          case data do
            {:eol, line} -> line <> "\n"
            {:noeol, line} -> line
            binary when is_binary(binary) -> binary
            _ -> ""
          end

        case append_frame(line_buffer, binary_data, max_frame_bytes) do
          {:ok, new_buffer} ->
            remaining = process_buffer(new_buffer, subscriber, max_frame_bytes)
            stdio_reader_loop(port, remaining, subscriber, max_frame_bytes, exit_info)

          {:error, :frame_too_large} ->
            Kernel.send(subscriber, {:transport_closed, :frame_too_large})
            close_port(port)
        end

      {^port, {:exit_status, status}} ->
        {group, reaper} = exit_info
        Reaper.server_exited(reaper)
        Kernel.send(subscriber, {:transport_closed, {:process_exited, status}})
        reap_group(group)

      {^port, :eof} ->
        Kernel.send(subscriber, {:transport_closed, :eof})
    end
  end

  # Process buffered data, sending complete JSON messages to subscriber.
  # Returns remaining incomplete buffer.
  defp process_buffer(buffer, subscriber, max_frame_bytes) do
    {messages, invalid_lines, partial} = LineBuffer.drain_json(buffer)

    Enum.each(messages, fn message ->
      Kernel.send(subscriber, {:transport_event, message})
    end)

    Enum.each(invalid_lines, fn {:invalid_json, line} ->
      Logger.debug("Skipping invalid JSON", line_shape: LogSummary.describe(line))
    end)

    if byte_size(partial) <= max_frame_bytes, do: partial, else: ""
  end

  @doc false
  @spec append_frame(binary(), iodata(), pos_integer()) ::
          {:ok, binary()} | {:error, :frame_too_large}
  def append_frame(buffer, data, limit)
      when is_binary(buffer) and is_integer(limit) and limit > 0 do
    data = IO.iodata_to_binary(data)

    if byte_size(buffer) + byte_size(data) <= limit,
      do: {:ok, buffer <> data},
      else: {:error, :frame_too_large}
  end

  defp request_within_limit(message, limit) when byte_size(message) <= limit, do: :ok
  defp request_within_limit(_message, _limit), do: {:error, :frame_too_large}

  defp safe_env(opts) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(PortEnvironment.normalize(Keyword.get(opts, :env, [])))
    |> PortEnvironment.to_port()
  end
end
