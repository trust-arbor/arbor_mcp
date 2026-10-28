defmodule Arbor.MCP.Test.ScriptedStdioServer do
  @moduledoc false
  # A stdio MCP server scripted in `sh`, so a test controls how long it takes
  # to start and how it answers, and can read back what it was sent. Every
  # copy started from the same log appends to it: a `start` line when the
  # process starts, then the method of each message it reads.
  #
  # Eras:
  #
  #   modern  a 2026-07-28-only server: answers server/discover, rejects
  #           initialize with UnsupportedProtocolVersionError
  #   legacy  a 2025-11-25 server: rejects the unknown server/discover with
  #           -32601, answers initialize
  #   exits   a legacy server that exits on server/discover, as Python's
  #           `mcp` 1.8 and earlier do, and answers initialize
  #   banner  like exits, but prints a non-JSON line first, which the
  #           transport ignores as it does any banner or log line
  #   notifies like exits, but sends a valid notification first, which the
  #           probe skips while it waits for an answer
  #   silent  a legacy server that never answers server/discover
  #   broken  exits on any request
  #   mute    reads everything and answers nothing
  #   once    a modern server that answers only its first server/discover,
  #           so its health-check pings go unanswered
  #   flaky   modern for the copy started with `:first_start`, mute after
  #   garbage answers server/discover with a response for another request id
  #   oversized answers server/discover with a 20 kB line
  #   malformed answers server/discover with a line that is not JSON
  #   partial writes part of an answer to server/discover, then exits

  @script ~S"""
  printf 'start\n' >> "$3"
  if [ -n "$4" ] && [ ! -e "$4" ]; then : > "$4"; first=1; else sleep "$1"; first=0; fi
  era=$2
  log=$3
  # flaky: the first copy is modern, later ones never answer.
  if [ "$era" = flaky ]; then
    if [ "$first" = 1 ]; then era=modern; else era=mute; fi
  fi
  answered=0
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    case "$line" in
      *'"method":"server/discover"'*) method=server/discover ;;
      *'"method":"initialize"'*) method=initialize ;;
      *'"method":"notifications/initialized"'*) method=notifications/initialized ;;
      *) method=other ;;
    esac
    printf '%s\n' "$method" >> "$log"
    [ -z "$id" ] && continue
    case "$era:$method" in
      once:server/discover)
        [ "$answered" = 1 ] && continue
        answered=1
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"private"}}\n' "$id" ;;
      modern:server/discover)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"private","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"scripted-modern","version":"1"}}}}\n' "$id" ;;
      modern:initialize)
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28"],"requested":"2025-11-25"}}}\n' "$id" ;;
      legacy:server/discover)
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
      legacy:initialize|exits:initialize|banner:initialize|notifies:initialize|silent:initialize)
        sleep "$5"
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"scripted-legacy","version":"1"}}}\n' "$id" ;;
      exits:server/discover)
        exit 3 ;;
      banner:server/discover)
        printf 'legacy server: unknown request, exiting\n'
        exit 3 ;;
      notifies:server/discover)
        printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"error","data":"unknown request"}}\n'
        exit 3 ;;
      broken:*)
        exit 4 ;;
      garbage:server/discover)
        printf '{"jsonrpc":"2.0","id":0,"result":{}}\n' ;;
      oversized:server/discover)
        pad=$(head -c 20000 /dev/zero | tr '\0' x)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"pad":"%s"}}\n' "$id" "$pad" ;;
      malformed:server/discover)
        printf '{this is not JSON\n' ;;
      partial:server/discover)
        printf '{"jsonrpc":"2.0","id":%s,"res' "$id"
        exit 5 ;;
      mute:*|once:*|garbage:*|oversized:*|malformed:*|partial:*|silent:server/discover) ;;
      *)
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
    esac
  done
  """

  @doc """
  The stdio `:command` for a server of `era` that logs to `log`.

  Options: `:start_delay_s` (default 0), `:initialize_delay_s`, how long a
  legacy server takes to answer initialize (default 0), and `:first_start`, a
  path: when that file does not exist yet, the server creates it and starts
  at once, so only the copies started after it are slow.
  """
  def command(era, log, opts \\ []) do
    sh = System.find_executable("sh") || raise "sh is required"

    [
      sh,
      "-c",
      @script,
      "scripted-server",
      "#{Keyword.get(opts, :start_delay_s, 0)}",
      "#{era}",
      log,
      Keyword.get(opts, :first_start, ""),
      "#{Keyword.get(opts, :initialize_delay_s, 0)}"
    ]
  end

  @doc """
  Starts one client per mode at the same time, each against its own copy of
  a server of `era`, and returns, by mode, what its start returned, how long
  it took, how many servers it started and the methods they read. A mode may
  also be given as `{key, mode, opts}`. Options are client options, plus
  `:start_delay_s`, `:initialize_delay_s` and `:first_start` (see
  `command/3`).

  A failed start returns once its servers have exited, so their log is
  complete. A connected client's last message, notifications/initialized in
  the legacy era, may still be unread: a ping answered after it says it was
  read, and is itself left out. Connected clients are stopped on exit.
  """
  def connect_concurrently(tmp_dir, era, modes, opts \\ []) do
    owner = self()

    modes
    |> Enum.map(fn
      {key, mode, extra_opts} -> {key, mode, Keyword.merge(opts, extra_opts)}
      mode -> {mode, mode, opts}
    end)
    |> Enum.map(fn {key, mode, opts} ->
      log = Path.join(tmp_dir, "#{era}-#{key}.log")
      {key, log, spawn_link(fn -> hold_client(owner, era, mode, log, opts) end)}
    end)
    |> Map.new(fn {key, log, holder} ->
      receive do
        {:scripted_client, ^holder, result, elapsed_ms} ->
          {key,
           %{
             result: result,
             elapsed_ms: elapsed_ms,
             methods: methods_read(result, log),
             starts: starts(log)
           }}
      after
        60_000 -> raise "the #{key} client did not finish starting"
      end
    end)
  end

  # A client lives only as long as the process that started it, so this one
  # stays until the test ends.
  defp hold_client(owner, era, mode, log, opts) do
    Process.flag(:trap_exit, true)
    started = System.monotonic_time(:millisecond)
    result = start_client(era, mode, log, opts)
    send(owner, {:scripted_client, self(), result, System.monotonic_time(:millisecond) - started})

    receive do
      {:EXIT, ^owner, _reason} -> :ok
    end
  end

  @doc "Starts a client in `mode` against a server of `era` logging to `log`."
  def start_client(era, mode, log, opts) do
    File.write!(log, "")

    {server_opts, client_opts} =
      Keyword.split(opts, [:start_delay_s, :initialize_delay_s, :first_start])

    [
      transport: :stdio,
      command: command(era, log, server_opts),
      protocol_mode: mode,
      health_check_interval: nil,
      reconnect: false
    ]
    |> Keyword.merge(client_opts)
    |> Arbor.MCP.Client.start_link()
  end

  defp methods_read({:ok, client}, log) do
    ExUnit.Callbacks.on_exit(fn -> stop_client(client) end)
    {:ok, _result} = Arbor.MCP.Client.ping(client)
    log |> methods() |> Enum.drop(-1)
  end

  defp methods_read({:error, _reason}, log), do: methods(log)

  @doc "Stops `client`, whatever state it is in."
  def stop_client(client) do
    Arbor.MCP.Client.stop(client)
  catch
    :exit, _reason -> :ok
  end

  @doc "The methods the servers logging to `log` read, in order."
  def methods(log), do: log |> lines() |> Enum.reject(&(&1 == "start"))

  @doc "How many servers logging to `log` were started."
  def starts(log), do: log |> lines() |> Enum.count(&(&1 == "start"))

  defp lines(log) do
    case File.read(log) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
