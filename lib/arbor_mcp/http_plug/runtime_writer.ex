defmodule Arbor.MCP.HttpPlug.RuntimeWriter do
  @moduledoc false
  import Kernel, except: [binding: 0, binding: 1]

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    HTTPWriteTicket
  }

  defmodule AdmissionError do
    @moduledoc false
    defexception message: "MCP HTTP response capacity unavailable"
  end

  def capture(_conn, nil), do: raise(ArgumentError, "MCP HTTP requires an explicit runtime")

  def capture(conn, runtime) do
    with {:ok, runtime} <- Arbor.MCP.Server.Runtime.ref(runtime),
         {:ok, binding} <- HTTPWriterProxy.capture(runtime) do
      conn
      |> Plug.Conn.put_private(:arbor_mcp_runtime, runtime)
      |> Plug.Conn.put_private(:arbor_mcp_http_binding, binding)
    else
      _failure -> raise AdmissionError
    end
  end

  def binding(conn), do: conn.private[:arbor_mcp_http_binding]
  def runtime(conn), do: conn.private[:arbor_mcp_runtime]

  def current(conn) do
    case HTTPWriterBinding.validate(binding(conn), runtime(conn)) do
      {:ok, _proof} -> :ok
      _closed -> {:error, :http_invocation_closed}
    end
  end

  # Validation responses and headers are charged before touching a borrowed
  # adapter. Callback responses already carry an admitted IO companion.
  def send_resp(conn, status, body),
    do: admitted(conn, IO.iodata_to_binary(body), &Plug.Conn.send_resp(&1, status, &2))

  def send_chunked(conn, status),
    do: admitted(conn, "", fn conn, _wire -> Plug.Conn.send_chunked(conn, status) end)

  def chunk(conn, body),
    do: admitted(conn, IO.iodata_to_binary(body), &Plug.Conn.chunk/2)

  defp admitted(%{private: %{arbor_mcp_http_binding: binding}} = conn, wire, write) do
    with {:ok, effect} <- HTTPWriterRegistry.prepare(binding, wire),
         :ok <- HTTPWriterRegistry.publish(effect),
         {:ok, effect, wire} <- HTTPWriterRegistry.peek(binding) do
      perform(conn, effect, wire, write)
    else
      _failure -> raise AdmissionError
    end
  end

  defp admitted(conn, wire, write), do: write.(conn, wire)

  # chunk/2 for a listener stream. A frame refused before IO because the exact
  # listener has entered its completion tail, where only that completion can
  # still be written, is returned as a value. Every other refusal, and any
  # failed or uncertain write, raises exactly as chunk/2 does.
  def listener_chunk(conn, listener, body) do
    binding = binding(conn)

    with {:ok, effect} <- HTTPWriterRegistry.prepare(binding, IO.iodata_to_binary(body)),
         :ok <- HTTPWriterRegistry.publish(effect),
         {:ok, effect, wire} <- HTTPWriterRegistry.peek(binding),
         {:ok, conn} <- perform_if_ready(conn, effect, wire, &Plug.Conn.chunk/2) do
      {:ok, conn}
    else
      _refused ->
        if HTTPWriterRegistry.listener_tail?(listener, runtime(conn)),
          do: {:error, :http_listener_tail},
          else: raise(AdmissionError)
    end
  end

  def await(conn, idle_timeout \\ :infinity) do
    binding = binding(conn)

    idle_deadline =
      if idle_timeout == :infinity, do: :infinity, else: Deadline.now() + idle_timeout

    with {:ok, deadline} <- HTTPWriterRegistry.wait_deadline(binding),
         {:ok, {domain, _token}} <- HTTPWriterBinding.address(binding) do
      await(binding, domain, deadline, idle_deadline)
    end
  end

  defp await(binding, domain, deadline, idle_deadline) do
    case HTTPWriterRegistry.listener_setup(binding) do
      {:listener, _cap, _pid, _token} = listener -> listener
      :empty -> await_output(binding, domain, deadline, idle_deadline)
    end
  end

  defp await_output(binding, domain, deadline, idle_deadline) do
    case HTTPWriterRegistry.peek(binding) do
      {:ok, _ticket, _wire} = ready ->
        ready

      waiting
      when waiting in [:empty, {:error, :http_invocation_closed}, {:error, :http_write_in_flight}] ->
        remaining = Deadline.remaining(deadline)
        idle_remaining = Deadline.remaining(idle_deadline)

        cond do
          remaining == 0 ->
            {:error, :http_invocation_closed}

          idle_remaining == 0 ->
            :idle

          true ->
            receive do
              {:mcp_http_output_wake, ^domain, nonce} ->
                HTTPWriterRegistry.acknowledge_wake(domain, nonce)
            after
              min(min(remaining, idle_remaining), 10) -> :ok
            end

            await(binding, domain, deadline, idle_deadline)
        end

      error ->
        error
    end
  end

  # A request keepalive enters IO atomically or not at all. A comment that was
  # not admitted (pending output, a failure tail, contention or expiry) is not
  # evidence that the client left, so the caller keeps waiting for its output.
  def request_keepalive(conn) do
    case HTTPWriterRegistry.enter_request_keepalive(binding(conn)) do
      {:ok, effect, wire} -> write_request_keepalive(conn, effect, wire)
      {:error, _not_entered} -> {:not_entered, conn}
    end
  end

  # The first comment also sends the SSE headers. When its chunk then fails,
  # the closure carries the chunked conn: returning the earlier unsent conn
  # would make the adapter treat the request as never answered. Only this one
  # write is guarded, so the caller's wait loop stays tail-recursive. A raised
  # write is returned for the caller to cancel the request and re-raise.
  defp write_request_keepalive(conn, effect, wire) do
    result =
      try do
        conn = if conn.state == :chunked, do: conn, else: Plug.Conn.send_chunked(conn, 200)

        case Plug.Conn.chunk(conn, wire) do
          {:ok, conn} -> {:ok, conn}
          {:error, _reason} -> {:closed, conn}
        end
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    HTTPWriterRegistry.complete(effect, keepalive_outcome(result))
    result
  end

  defp keepalive_outcome({:ok, _conn}), do: :ok
  defp keepalive_outcome({:closed, _conn}), do: {:error, :http_write_failed}
  defp keepalive_outcome(_raised), do: {:error, :http_write_uncertain}

  def perform(conn, effect, wire, write) do
    case perform_if_ready(conn, effect, wire, write) do
      {:error, :http_io_not_entered} -> raise AdmissionError
      result -> result
    end
  end

  # Distinguish a proof rejected before IO from an actual borrowed write failure.
  # The latter still raises and cannot be treated as a retryable stale source.
  def perform_if_ready(conn, effect, wire, write) do
    {:ok, expected} = HTTPWriteTicket.address(effect)

    case HTTPWriterRegistry.checkout(binding(conn)) do
      {:ok, actual, actual_wire} ->
        if HTTPWriteTicket.address(actual) == {:ok, expected} and actual_wire == wire do
          write_checked_out(conn, actual, actual_wire, write)
        else
          HTTPWriterRegistry.complete(actual, {:error, :http_output_mismatch})
          {:error, :http_io_not_entered}
        end

      _closed ->
        {:error, :http_io_not_entered}
    end
  end

  defp write_checked_out(conn, effect, wire, write) do
    result = write.(conn, wire)
    outcome = if match?({:error, _}, result), do: {:error, :http_write_failed}, else: :ok
    HTTPWriterRegistry.complete(effect, outcome)
    if outcome == :ok, do: result, else: raise(AdmissionError)
  rescue
    _exception ->
      HTTPWriterRegistry.complete(effect, {:error, :http_write_uncertain})
      raise AdmissionError
  catch
    _kind, _reason ->
      HTTPWriterRegistry.complete(effect, {:error, :http_write_uncertain})
      raise AdmissionError
  end

  def retire(%{private: %{arbor_mcp_http_binding: binding}}),
    do: HTTPWriterRegistry.retire(binding, :http_socket_returned)

  def retire(_conn), do: :ok
end
