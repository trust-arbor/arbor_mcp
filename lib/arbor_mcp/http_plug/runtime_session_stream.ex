defmodule Arbor.MCP.HttpPlug.RuntimeSessionStream do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.{RuntimeSession, RuntimeWriter}

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPGateway,
    HTTPSessionStreamBinding,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    OutputCodec
  }

  @poll_ms 50

  def prepare(conn, session, cursor, mode) when mode in [:oneshot, :stream] do
    with :ok <- RuntimeWriter.current(conn),
         {:ok, cursor} <- initial_cursor(session, cursor),
         {:ok, page} <- RuntimeSession.replay_page(session, cursor),
         :ok <- register(conn, mode) do
      {:ok, %{cursor: cursor, page: page, mode: mode, session: session}}
    end
  end

  def prepare(_conn, _session, _cursor, _mode), do: {:error, :invalid_sse_mode}

  def prepare_legacy(conn, session, cursor, mode, endpoint) when mode in [:oneshot, :stream] do
    with :ok <- RuntimeWriter.current(conn),
         {:ok, cursor} <- initial_cursor(session, cursor),
         {:ok, page} <- RuntimeSession.replay_page(session, cursor),
         {:ok, target} <-
           HTTPGateway.establish_session_stream(
             RuntimeWriter.runtime(conn),
             RuntimeWriter.binding(conn),
             endpoint
           ) do
      session = RuntimeSession.with_replay_target(session, target)
      {:ok, %{cursor: cursor, page: page, mode: mode, session: session, target: target}}
    end
  end

  def prepare_legacy(_conn, _session, _cursor, _mode, _endpoint),
    do: {:error, :invalid_sse_mode}

  defp initial_cursor(session, nil), do: RuntimeSession.replay_cursor(session)
  defp initial_cursor(_session, cursor), do: {:ok, cursor}

  defp register(_conn, :oneshot), do: :ok

  defp register(conn, :stream),
    do: HTTPWriterRegistry.register_session_stream(RuntimeWriter.binding(conn))

  def serve(conn, context, initial_event \\ nil) do
    conn =
      if context[:target],
        do: Plug.Conn.put_private(conn, :arbor_mcp_http_session_target, context.target),
        else: conn

    event = initial_event || {"connected", %{"session_id" => RuntimeSession.id(context.session)}}

    with {:ok, wire} <- frame(conn, elem(event, 0), elem(event, 1), nil),
         {:ok, effect} <- HTTPWriterRegistry.prepare(RuntimeWriter.binding(conn), wire),
         :ok <- HTTPWriterRegistry.publish(effect) do
      conn =
        RuntimeWriter.perform(conn, effect, wire, fn conn, wire ->
          conn = Plug.Conn.send_chunked(conn, 200)

          case Plug.Conn.chunk(conn, wire) do
            {:ok, conn} -> conn
            error -> error
          end
        end)

      drain(conn, context)
    else
      _closed -> raise RuntimeWriter.AdmissionError
    end
  end

  defp drain(conn, %{page: %{events: events} = page} = context) do
    case write_events(events, conn) do
      {:ok, conn} ->
        context = %{context | cursor: page.next_cursor || context.cursor}

        cond do
          page.more? -> next_page(conn, context)
          context.mode == :oneshot -> conn
          true -> poll(conn, context)
        end

      {:ended, conn} ->
        conn
    end
  end

  defp write_events([], conn), do: {:ok, conn}

  defp write_events([event | events], conn) do
    case write_event(event, conn) do
      {:ok, conn} -> write_events(events, conn)
      :ended -> {:ended, conn}
    end
  end

  defp next_page(conn, context) do
    case RuntimeSession.replay_page(context.session, context.cursor) do
      {:ok, page} -> drain(conn, %{context | page: page})
      _closed -> conn
    end
  end

  defp poll(conn, context) do
    case stream_proof(conn) do
      {:ok, proof} ->
        {:ok, {domain, _}} = HTTPWriterBinding.address(RuntimeWriter.binding(conn))

        receive do
          {:mcp_http_output_wake, ^domain, nonce} ->
            HTTPWriterRegistry.acknowledge_wake(domain, nonce)
        after
          min(@poll_ms, Deadline.remaining(proof.deadline)) -> :ok
        end

        if match?({:ok, _proof}, stream_proof(conn)), do: next_page(conn, context), else: conn

      _closed ->
        conn
    end
  end

  defp stream_proof(%{private: %{arbor_mcp_http_session_target: target}} = conn),
    do: HTTPSessionStreamBinding.validate(target, RuntimeWriter.runtime(conn))

  defp stream_proof(conn),
    do: HTTPWriterBinding.validate(RuntimeWriter.binding(conn), RuntimeWriter.runtime(conn))

  # A stream can end while it writes a page it has already read: its session
  # is deleted, its lease or deadline runs out, or another stream replaces
  # it. The frame is then refused before any IO, and the stream ends
  # normally, without the rest of the page, which a new stream resumes with
  # Last-Event-ID. Any other refusal, and a failed or uncertain write, still
  # raises, as RuntimeWriter.chunk/2 does.
  defp write_event(event, conn) do
    with {:ok, wire} <- frame(conn, event.type, event.data, event.id),
         {:ok, conn} <- chunk(conn, wire) do
      {:ok, conn}
    else
      :ended -> :ended
      _invalid -> raise(RuntimeWriter.AdmissionError)
    end
  end

  defp chunk(conn, wire) do
    binding = RuntimeWriter.binding(conn)

    with {:ok, effect} <- HTTPWriterRegistry.prepare(binding, wire),
         :ok <- HTTPWriterRegistry.publish(effect),
         {:ok, effect, wire} <- HTTPWriterRegistry.peek(binding),
         {:ok, conn} <- RuntimeWriter.perform_if_ready(conn, effect, wire, &Plug.Conn.chunk/2) do
      {:ok, conn}
    else
      _refused -> if ended?(conn), do: :ended, else: raise(RuntimeWriter.AdmissionError)
    end
  end

  defp ended?(conn), do: not match?({:ok, _proof}, stream_proof(conn))

  defp frame(_conn, type, {:raw, value}, nil)
       when type == "endpoint" and is_binary(value) do
    if String.contains?(value, ["\r", "\n"]),
      do: {:error, :invalid_sse_event},
      else: {:ok, "event: endpoint\ndata: " <> value <> "\n\n"}
  end

  # `:ended` when the stream is no longer current, so there is nothing to
  # frame for. Its deadline can pass after the proof, while the event is
  # encoded under it (`:output_expired`); a frame that fails while the stream
  # has meanwhile ended is put down to that too. A malformed event on a
  # current stream is `{:error, :invalid_sse_event}`.
  defp frame(conn, type, data, cursor) do
    with {:ok, proof} <- stream_proof(conn),
         {:ok, wire} <- frame_current(proof, type, data, cursor) do
      {:ok, wire}
    else
      {:error, :output_expired} -> :ended
      {:error, :invalid_sse_event} = invalid -> if ended?(conn), do: :ended, else: invalid
      _not_current -> :ended
    end
  end

  defp frame_current(proof, type, data, cursor) do
    with {:ok, %{wire: json}} <-
           OutputCodec.prepare(data, codec: :protocol, deadline: proof.deadline),
         true <-
           is_binary(type) and byte_size(type) in 1..128 and
             not String.contains?(type, ["\r", "\n"]),
         true <-
           is_nil(cursor) or
             (is_binary(cursor) and byte_size(cursor) <= 256 and
                not String.contains?(cursor, ["\r", "\n"])) do
      prefix = if cursor, do: "id: " <> cursor <> "\n", else: ""
      {:ok, prefix <> "event: " <> type <> "\ndata: " <> json <> "\n\n"}
    else
      {:error, :output_expired} = expired -> expired
      _invalid -> {:error, :invalid_sse_event}
    end
  end
end
