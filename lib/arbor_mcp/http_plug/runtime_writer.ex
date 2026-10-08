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

  def await(conn) do
    binding = binding(conn)

    with {:ok, deadline} <- HTTPWriterRegistry.wait_deadline(binding),
         {:ok, {domain, _token}} <- HTTPWriterBinding.address(binding) do
      await(binding, domain, deadline)
    end
  end

  defp await(binding, domain, deadline) do
    case HTTPWriterRegistry.listener_setup(binding) do
      {:listener, _cap, _pid, _token} = listener -> listener
      :empty -> await_output(binding, domain, deadline)
    end
  end

  defp await_output(binding, domain, deadline) do
    case HTTPWriterRegistry.peek(binding) do
      {:ok, _ticket, _wire} = ready ->
        ready

      waiting
      when waiting in [:empty, {:error, :http_invocation_closed}, {:error, :http_write_in_flight}] ->
        remaining = Deadline.remaining(deadline)

        if remaining == 0 do
          {:error, :http_invocation_closed}
        else
          receive do
            {:mcp_http_output_wake, ^domain, nonce} ->
              HTTPWriterRegistry.acknowledge_wake(domain, nonce)
          after
            min(remaining, 10) -> :ok
          end

          await(binding, domain, deadline)
        end

      error ->
        error
    end
  end

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
