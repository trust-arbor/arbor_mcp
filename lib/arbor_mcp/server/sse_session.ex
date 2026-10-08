defmodule Arbor.MCP.Server.SSESession do
  @moduledoc """
  Server-side SSE session manager for bidirectional MCP communication.

  Manages the lifecycle of SSE sessions where the server needs to send
  requests to the client (elicitation, sampling) and receive responses.

  ## Architecture

  Each MCP session has:
  - A POST endpoint for client→server requests
  - A GET SSE stream for server→client messages (notifications, requests)
  - A pending request tracker for correlating server requests with client responses

  ## Usage

      # Initialize session state (call once at server startup)
      SSESession.init()

      # Register a GET SSE stream for a session
      SSESession.register_sse_stream(session_id)

      # Send a request to the client and wait for response
      {:ok, result} = SSESession.send_request(session_id, "elicitation/create", params)

      # Route a client response to the waiting request handler
      SSESession.handle_response(request_id, {:ok, result})
  """

  alias Arbor.RPC.JSONRPC

  @ets_table :ex_mcp_sse_sessions
  @default_timeout 10_000
  @default_wait_for_stream 3_000
  @wait_poll_ms 25

  @doc """
  Initialize the session ETS table.

  Idempotent and safe to call concurrently: the first caller creates the table
  and every other caller, including one that races the creator, is a no-op.
  The table is owned by the process that creates it, so call this once from a
  long-lived process such as the server's startup code, not from a
  per-request process whose exit would drop the table.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@ets_table) == :undefined do
      try do
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        error in ArgumentError ->
          # Another process created the table between the check and
          # `:ets.new/2`. Anything else is a real error.
          if :ets.whereis(@ets_table) == :undefined do
            reraise error, __STACKTRACE__
          end
      end
    end

    :ok
  end

  @doc """
  Register the calling process as the SSE stream for a session.

  Replaces any previous registration for the same session id (including dead pids).
  """
  @spec register_sse_stream(String.t()) :: :ok
  def register_sse_stream(session_id) when is_binary(session_id) do
    key = sse_key(session_id)

    case :ets.lookup(@ets_table, key) do
      [{^key, old_pid}] when old_pid != self() ->
        # Drop stale registration; do not kill other processes.
        :ets.delete(@ets_table, key)

      _ ->
        :ok
    end

    :ets.insert(@ets_table, {key, self()})
    :ok
  end

  @doc """
  Wait until a live SSE stream is registered for `session_id`.

  Returns `:ok` when ready, or `{:error, :timeout}` if not registered within
  `timeout_ms` (default #{@default_wait_for_stream}ms).
  """
  @spec await_sse_stream(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def await_sse_stream(session_id, timeout_ms \\ @default_wait_for_stream)
      when is_binary(session_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_sse_stream(session_id, deadline)
  end

  @doc """
  Send a JSON-RPC request to the client via the GET SSE stream.

  Options:
  - `:timeout` — wait for client response (default #{@default_timeout}ms)
  - `:wait_for_stream` — wait for SSE registration before send (default #{@default_wait_for_stream}ms)

  Blocks until the client responds or timeout is reached.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec send_request(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_request(session_id, method, params, opts \\ [])
      when is_binary(session_id) and is_binary(method) and is_map(params) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    wait_for_stream = Keyword.get(opts, :wait_for_stream, @default_wait_for_stream)
    request_id = System.unique_integer([:positive])

    case await_live_sse_pid(session_id, wait_for_stream) do
      {:ok, sse_pid} ->
        register_pending(request_id, self())

        request = JSONRPC.request(method, params, request_id)

        if Process.alive?(sse_pid) do
          send(sse_pid, {:sse_send, request})

          receive do
            {:client_response, ^request_id, result} ->
              clear_pending(request_id)
              result
          after
            timeout ->
              clear_pending(request_id)
              {:error, :timeout}
          end
        else
          clear_pending(request_id)
          drop_sse_if_pid(session_id, sse_pid)
          {:error, {:no_sse_stream, session_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Route a client response back to the waiting request handler.

  Called when the server receives a POST with a JSON-RPC response
  (has `id` + `result`/`error`, no `method`).

  Accepts integer or string request ids (JSON number vs string echo).
  """
  @spec handle_response(integer() | String.t(), {:ok, map()} | {:error, map()}) :: boolean()
  def handle_response(request_id, result) do
    candidates =
      [request_id, normalize_request_id(request_id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.find_value(candidates, false, fn candidate ->
      key = pending_key(candidate)

      case :ets.lookup(@ets_table, key) do
        [{^key, {pid, original_id}}] ->
          clear_pending(original_id)
          send(pid, {:client_response, original_id, result})
          true

        [{^key, pid}] when is_pid(pid) ->
          # Backward-compatible shape
          clear_pending(candidate)
          send(pid, {:client_response, candidate, result})
          true

        _ ->
          false
      end
    end) || false
  end

  @doc """
  If exactly one live SSE stream is registered, return its session id.

  Used as a last-resort session resolution for bidirectional tools when the
  client omits `mcp-session-id` on tools/call.
  """
  @spec sole_live_session_id() :: {:ok, String.t()} | :error
  def sole_live_session_id do
    case live_session_ids() do
      [sid] -> {:ok, sid}
      _ -> :error
    end
  end

  @doc """
  Wait until exactly one live SSE stream exists, then return its session id.

  Handles the race where `tools/call` POST arrives slightly before the client's
  GET SSE stream is registered (and the POST may omit `mcp-session-id`).
  """
  @spec await_sole_live_session_id(non_neg_integer()) ::
          {:ok, String.t()} | {:error, :timeout | :ambiguous}
  def await_sole_live_session_id(timeout_ms \\ @default_wait_for_stream)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_sole_live_session_id(deadline, false)
  end

  @doc """
  Run the SSE event loop for a GET connection.

  Forwards `{:sse_send, data}` messages as SSE events.
  Returns when `:sse_close` is received or timeout expires.
  Always clears this process's registration for `session_id` on exit.
  """
  @spec run_sse_loop(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def run_sse_loop(conn, session_id, opts \\ []) do
    timeout = Keyword.get(opts, :idle_timeout, 60_000)

    try do
      do_sse_loop(conn, session_id, timeout, opts)
    after
      drop_sse_if_pid(session_id, self())
    end
  end

  @doc "Check if a session has an active (live) SSE stream."
  @spec has_sse_stream?(String.t()) :: boolean()
  def has_sse_stream?(session_id) do
    match?({:ok, _}, lookup_live_sse_pid(session_id))
  end

  @doc "Clean up session state for an SSE stream registration."
  @spec cleanup(String.t()) :: :ok
  def cleanup(session_id) do
    :ets.delete(@ets_table, sse_key(session_id))
    :ok
  rescue
    _ -> :ok
  end

  # --- private ---

  defp do_sse_loop(conn, session_id, timeout, opts) do
    receive do
      {:sse_send, data} ->
        case Plug.Conn.chunk(conn, "event: message\ndata: #{Jason.encode!(data)}\n\n") do
          {:ok, conn} ->
            do_sse_loop(conn, session_id, timeout, opts)

          {:error, _} ->
            conn
        end

      :sse_close ->
        conn
    after
      timeout ->
        conn
    end
  end

  defp do_await_sse_stream(session_id, deadline) do
    case lookup_live_sse_pid(session_id) do
      {:ok, _pid} ->
        :ok

      :error ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(min(@wait_poll_ms, deadline - now))
          do_await_sse_stream(session_id, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  defp await_live_sse_pid(session_id, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    do_await_live_sse_pid(session_id, deadline)
  end

  defp do_await_live_sse_pid(session_id, deadline) do
    case lookup_live_sse_pid(session_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(min(@wait_poll_ms, deadline - now))
          do_await_live_sse_pid(session_id, deadline)
        else
          {:error, {:no_sse_stream, session_id}}
        end
    end
  end

  defp lookup_live_sse_pid(session_id) do
    key = sse_key(session_id)

    case :ets.lookup(@ets_table, key) do
      [{^key, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :ets.delete(@ets_table, key)
          :error
        end

      _ ->
        :error
    end
  end

  defp drop_sse_if_pid(session_id, pid) do
    key = sse_key(session_id)

    case :ets.lookup(@ets_table, key) do
      [{^key, ^pid}] -> :ets.delete(@ets_table, key)
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp do_await_sole_live_session_id(deadline, saw_multiple?) do
    case live_session_ids() do
      [sid] ->
        {:ok, sid}

      ids when is_list(ids) and length(ids) > 1 ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(min(@wait_poll_ms, deadline - now))
          do_await_sole_live_session_id(deadline, true)
        else
          {:error, :ambiguous}
        end

      _ ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(min(@wait_poll_ms, deadline - now))
          do_await_sole_live_session_id(deadline, saw_multiple?)
        else
          if saw_multiple?, do: {:error, :ambiguous}, else: {:error, :timeout}
        end
    end
  end

  defp live_session_ids do
    :ets.tab2list(@ets_table)
    |> Enum.flat_map(fn
      {"sse_pid:" <> sid, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          [sid]
        else
          :ets.delete(@ets_table, sse_key(sid))
          []
        end

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp register_pending(request_id, pid) do
    entry = {pid, request_id}
    :ets.insert(@ets_table, {pending_key(request_id), entry})

    # Alias string/int forms so client id echo cannot miss the waiter.
    case normalize_request_id(request_id) do
      nil -> :ok
      other -> :ets.insert(@ets_table, {pending_key(other), entry})
    end
  end

  defp clear_pending(request_id) do
    :ets.delete(@ets_table, pending_key(request_id))

    case normalize_request_id(request_id) do
      nil -> :ok
      other -> :ets.delete(@ets_table, pending_key(other))
    end
  end

  defp sse_key(session_id), do: "sse_pid:#{session_id}"
  defp pending_key(request_id), do: "pending:#{request_id}"

  defp normalize_request_id(id) when is_integer(id), do: Integer.to_string(id)

  defp normalize_request_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_request_id(_), do: nil
end
