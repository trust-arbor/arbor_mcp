defmodule Arbor.MCP.Transport.Stdio do
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

  The command is resolved against the `PATH` the child will see (an explicit
  `PATH` in `:env`, else the inherited one), not the VM's own. When the VM
  runs as an OTP release, the release's own directories are dropped from the
  inherited `PATH` (see `RELEASE_ROOT`), so a server that is itself an Erlang
  or Elixir program does not pick up the release's `erl`.

  ## Process groups

  Shared cleanup verifies that the owned child leads its process group. By
  default `close/1` sends SIGTERM, then SIGKILL, to that one process. Processes
  the server started (a launcher's or shell script's children) can outlive
  the connection when group cleanup is disabled.
  With `process_group: true`, `close/1` signals the whole group instead, and
  when the server exits on its own, whatever it left running in its group is
  signalled too. A descendant that leaves the group on purpose (`setsid`) is
  not reached. Process groups are a Unix feature; enabling this option on
  Windows returns `:process_group_unsupported`. Shared Windows tree cleanup
  uses `taskkill /T` and remains a release qualification gate.

  ## Example

      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :stdio,
        command: ["node", "my-mcp-server.js"],
        cd: "/path/to/server",
        env: [{"NODE_ENV", "production"}]
      )
  """

  @behaviour Arbor.MCP.Transport

  alias Arbor.MCP.Internal.{Options, SecurityConfig}
  alias Arbor.MCP.Transport.{Error, SecurityGuard}
  alias Arbor.RPC.{FramedStream, LogSummary, PortEnvironment, StdioFraming, Subprocess}

  @default_max_frame_bytes 1_048_576
  defstruct [
    :subprocess,
    :os_pid,
    :subscriber,
    :monitor,
    :reader_pid,
    :port,
    line_buffer: "",
    max_frame_bytes: @default_max_frame_bytes,
    process_group: false
  ]

  @impl true
  def connect(opts) do
    with :ok <- PortEnvironment.validate_policy(opts),
         :ok <- validate_process_group(opts) do
      limit = Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes)

      child_opts =
        opts
        |> Keyword.put(:max_frame_bytes, limit)
        |> Keyword.put_new(:max_write_bytes, limit + 1)

      case Subprocess.open(Keyword.fetch!(opts, :command), child_opts) do
        {:ok, handle} ->
          [actor] = Subprocess.linked_processes(handle)
          command = hd(opts[:command])

          :telemetry.execute([:arbor_mcp, :transport, :connection, :opened], %{}, %{
            transport: :stdio,
            command_basename: Path.basename(command),
            command_hash: LogSummary.fingerprint(command)
          })

          {:ok,
           %__MODULE__{
             subprocess: handle,
             os_pid: Subprocess.os_pid(handle),
             reader_pid: actor,
             max_frame_bytes: limit,
             process_group: Keyword.get(opts, :process_group, false)
           }}

        {:error, reason} ->
          Error.connection_error(reason)
      end
    end
  end

  defp validate_process_group(opts) do
    case Keyword.get(opts, :process_group, false) do
      flag when is_boolean(flag) -> :ok
      invalid -> {:error, {:invalid_process_group, invalid}}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{} = state) do
    with :ok <- request_within_limit(message, state.max_frame_bytes),
         {:ok, validated} <- validate_stdio_message(message, state) do
      case write(state.subprocess, validated <> "\n") do
        :ok ->
          :telemetry.execute(
            [:arbor_mcp, :transport, :message, :sent],
            %{size: byte_size(message)},
            %{transport: :stdio}
          )

          {:ok, state}

        {:error, reason} ->
          Error.transport_error({:send_failed, reason})
      end
    else
      {:error, :frame_too_large} = error -> error
      {:error, reason} -> Error.security_violation(reason)
    end
  end

  defp write(nil, _data), do: {:error, :closed}
  defp write(handle, data), do: Subprocess.write(handle, data)

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
  def receive_message(%__MODULE__{} = state), do: receive_message(state, :infinity)

  @doc """
  Receives one newline-terminated MCP frame within an absolute timeout.

  The stable shared actor owns the child throughout pull and push delivery.
  Temporary readers cannot transfer ownership or reset the timeout by consuming
  banners or partial data. MCP rejects an unfinished final frame at EOF.
  """
  @spec receive_message(%__MODULE__{}, timeout()) ::
          {:ok, binary(), %__MODULE__{}} | {:error, term()}
  def receive_message(%__MODULE__{} = state, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    deadline =
      if timeout == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + timeout

    receive_frame(state, deadline, if(timeout == 0, do: [buffered_only: true], else: []))
  end

  def receive_message(_state, _timeout), do: {:error, :invalid_timeout}

  defp receive_frame(state, deadline, opts) do
    case FramedStream.next_until(state.subprocess, deadline, opts) do
      {:ok, bytes} ->
        case frame(bytes) do
          {:ok, json} ->
            received(json)
            {:ok, json, state}

          :ignore ->
            receive_frame(state, deadline, opts)
        end

      {:closed, reason, _unfinished} ->
        Error.connection_error(closed_reason(reason))

      {:error, :timeout} ->
        {:error, :handshake_timeout}

      {:error, reason} ->
        Error.connection_error(reason)
    end
  end

  @impl true
  def close(%__MODULE__{} = state) do
    if state.monitor, do: Process.demonitor(elem(state.monitor, 0), [:flush])
    :telemetry.execute([:arbor_mcp, :transport, :connection, :closed], %{}, %{transport: :stdio})
    Subprocess.close(state.subprocess)
  end

  @impl true
  def connected?(%__MODULE__{subprocess: nil}), do: false
  def connected?(%__MODULE__{subprocess: handle}), do: Subprocess.connected?(handle)

  @impl true
  def linked_processes(%__MODULE__{}), do: []

  @doc """
  Subscribes directly to generation-tagged shared RPC events with one frame of credit.

  Process a `{:arbor_rpc, generation, {:frame, token, bytes}}` event through
  `event/2`, then call `ack/2` after processing. Forwarding followed by an
  immediate acknowledgment would remove the bound on the destination mailbox.
  The MCP Client performs this acknowledgment after its protocol processing.
  """
  @impl true
  def subscribe(pid, %__MODULE__{} = state) do
    case FramedStream.subscribe(state.subprocess, pid, window: 1) do
      :ok ->
        [actor] = Subprocess.linked_processes(state.subprocess)
        monitor = if pid == self(), do: {Process.monitor(actor), actor}, else: nil
        {:ok, %{state | subscriber: pid, monitor: monitor}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def capabilities(%__MODULE__{}), do: [:push]

  @doc false
  def event(%__MODULE__{subprocess: nil}, _message), do: :ignore

  def event(%__MODULE__{subprocess: handle}, {:arbor_rpc, generation, event}) do
    if generation == Subprocess.identity(handle), do: event, else: :ignore
  end

  def event(_state, _message), do: :ignore

  @doc false
  def ack(%__MODULE__{subprocess: handle}, token), do: FramedStream.ack(handle, token)

  @doc false
  def identity(%__MODULE__{subprocess: handle}), do: Subprocess.identity(handle)

  @doc false
  def frame(bytes) do
    trimmed = bytes |> StdioFraming.strip_bom() |> String.trim()
    if String.starts_with?(trimmed, ["{", "["]), do: {:ok, trimmed}, else: :ignore
  end

  @doc false
  def received(json),
    do:
      :telemetry.execute(
        [:arbor_mcp, :transport, :message, :received],
        %{size: byte_size(json)},
        %{transport: :stdio}
      )

  @doc false
  def closed_reason({:exit_status, status}), do: {:process_exited, status}
  def closed_reason(reason), do: reason

  # Retained repository-test helper; live decoding belongs exclusively to RPC.
  @doc false
  def append_frame(buffer, data, limit)
      when is_binary(buffer) and is_integer(limit) and limit > 0 do
    data = IO.iodata_to_binary(data)

    if byte_size(buffer) + byte_size(data) <= limit,
      do: {:ok, buffer <> data},
      else: {:error, :frame_too_large}
  end

  defp request_within_limit(message, limit) when byte_size(message) <= limit, do: :ok
  defp request_within_limit(_message, _limit), do: {:error, :frame_too_large}
end
