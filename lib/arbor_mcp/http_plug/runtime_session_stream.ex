defmodule Arbor.MCP.HttpPlug.RuntimeSessionStream do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.{RuntimeSession, RuntimeWriter}
  alias Arbor.MCP.Server.Runtime.{Deadline, HTTPWriterBinding, HTTPWriterRegistry, OutputCodec}

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

  defp initial_cursor(session, nil), do: RuntimeSession.replay_cursor(session)
  defp initial_cursor(_session, cursor), do: {:ok, cursor}

  defp register(_conn, :oneshot), do: :ok

  defp register(conn, :stream),
    do: HTTPWriterRegistry.register_session_stream(RuntimeWriter.binding(conn))

  def serve(conn, context, initial_event \\ nil) do
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
    conn = Enum.reduce(events, conn, &write_event/2)
    context = %{context | cursor: page.next_cursor || context.cursor}

    cond do
      page.more? -> next_page(conn, context)
      context.mode == :oneshot -> conn
      true -> poll(conn, context)
    end
  end

  defp next_page(conn, context) do
    case RuntimeSession.replay_page(context.session, context.cursor) do
      {:ok, page} -> drain(conn, %{context | page: page})
      _closed -> conn
    end
  end

  defp poll(conn, context) do
    case HTTPWriterBinding.validate(RuntimeWriter.binding(conn), RuntimeWriter.runtime(conn)) do
      {:ok, proof} ->
        {:ok, {domain, _}} = HTTPWriterBinding.address(RuntimeWriter.binding(conn))

        receive do
          {:mcp_http_output_wake, ^domain, nonce} ->
            HTTPWriterRegistry.acknowledge_wake(domain, nonce)
        after
          min(@poll_ms, Deadline.remaining(proof.deadline)) -> :ok
        end

        if RuntimeWriter.current(conn) == :ok, do: next_page(conn, context), else: conn

      _closed ->
        conn
    end
  end

  defp write_event(event, conn) do
    with {:ok, wire} <- frame(conn, event.type, event.data, event.id),
         {:ok, conn} <- RuntimeWriter.chunk(conn, wire),
         do: conn,
         else: (_closed -> raise(RuntimeWriter.AdmissionError))
  end

  defp frame(_conn, type, {:raw, value}, nil)
       when type == "endpoint" and is_binary(value) do
    if String.contains?(value, ["\r", "\n"]),
      do: {:error, :invalid_sse_event},
      else: {:ok, "event: endpoint\ndata: " <> value <> "\n\n"}
  end

  defp frame(conn, type, data, cursor) do
    with {:ok, proof} <-
           HTTPWriterBinding.validate(RuntimeWriter.binding(conn), RuntimeWriter.runtime(conn)),
         {:ok, %{wire: json}} <-
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
      _invalid -> {:error, :invalid_sse_event}
    end
  end
end
