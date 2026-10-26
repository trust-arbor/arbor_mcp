defmodule ExMCP.Transport.HTTP.PostStream do
  @moduledoc false
  # A legacy-era POST answered with an event stream carries the request's
  # notifications, such as progress, and the server's own requests ahead of
  # its response. Each is handed to the client process as it arrives, as the
  # other SDKs do, so progress is seen while the request runs and a request
  # the server waits on can be answered. The response, and the ids and retry
  # fields of the other events, stay in the body for the transport.
  #
  # The client acknowledges each message before the next is read, as with a
  # modern request stream, so a fast stream can't fill its mailbox. It may
  # take until the response's deadline to do so.

  alias ExMCP.Internal.SSE

  @type input :: {:data, binary(), integer()} | :done
  @type t :: {map(), (input(), map() -> {:ok, term()} | {:error, term()})}

  @doc false
  # Options: `:max_buffer_bytes` limits each event, complete or not, and
  # `:max_kept_bytes` what's kept for the transport.
  @spec consumer(pid(), keyword()) :: t()
  def consumer(parent, opts) do
    limits = %{
      parent: parent,
      max_buffer: Keyword.fetch!(opts, :max_buffer_bytes),
      max_kept: Keyword.fetch!(opts, :max_kept_bytes)
    }

    acc = %{rest: "", after_cr: false, kept: [], kept_bytes: 0}
    {acc, &consume(&1, &2, limits)}
  end

  defp consume(:done, acc, limits) do
    blocks = Enum.map(acc.kept, &render/1)
    body = Enum.join(Enum.reverse([acc.rest | blocks]), "\n\n")

    if byte_size(body) > limits.max_kept,
      do: {:error, :response_too_large},
      else: {:ok, body}
  end

  defp consume({:data, "", _deadline}, acc, _limits), do: {:ok, acc}

  defp consume({:data, chunk, deadline}, acc, limits) do
    # A CR ends a line at once; an LF right after it is the rest of a CRLF.
    chunk =
      case {acc.after_cr, chunk} do
        {true, "\n" <> rest} -> rest
        _other -> chunk
      end

    {blocks, rest} = split_blocks(acc.rest <> chunk)
    acc = %{acc | rest: rest, after_cr: String.ends_with?(chunk, "\r")}

    if byte_size(rest) > limits.max_buffer,
      do: {:error, :stream_buffer_limit_exceeded},
      else: take_blocks(blocks, acc, Map.put(limits, :deadline, deadline))
  end

  defp split_blocks(raw) do
    parts =
      raw
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split("\n\n")

    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  # Each event is checked before it's read, and what's kept as it grows.
  defp take_blocks(blocks, acc, limits) do
    Enum.reduce_while(blocks, {:ok, acc}, fn block, {:ok, acc} ->
      with :ok <- within(byte_size(block), limits.max_buffer, :stream_buffer_limit_exceeded),
           {:ok, acc} <- take_block(block, acc, limits),
           :ok <- within(acc.kept_bytes, limits.max_kept, :response_too_large) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp within(size, limit, _reason) when size <= limit, do: :ok
  defp within(_size, _limit, reason), do: {:error, reason}

  defp take_block(block, acc, limits) do
    case SSE.parse_complete(block) do
      [%{data: data}] when data != "" ->
        case Jason.decode(data) do
          {:ok, %{"method" => method}} when is_binary(method) ->
            with :ok <- deliver(data, limits), do: {:ok, keep_metadata(acc, metadata(block))}

          _response_or_invalid ->
            {:ok, keep(acc, block)}
        end

      # A priming event, a keepalive comment: only an id or retry matters.
      _no_data ->
        {:ok, keep_metadata(acc, metadata(block))}
    end
  end

  defp deliver(data, %{parent: parent, deadline: deadline}) do
    ref = make_ref()
    monitor = Process.monitor(parent)
    send(parent, {:http_post_stream_message, self(), ref, data})

    receive do
      {:http_post_stream_ack, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :stream_consumer_closed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.demonitor(monitor, [:flush])
        {:error, :stream_consumer_timeout}
    end
  end

  defp keep(acc, entry),
    do: %{acc | kept: [entry | acc.kept], kept_bytes: acc.kept_bytes + size(entry)}

  # The transport applies each event's id and retry in turn, so a run of
  # events without a response needs only the last of each, in its place.
  defp keep_metadata(acc, fields) when fields == %{}, do: acc

  defp keep_metadata(%{kept: [{:metadata, earlier} = previous | kept]} = acc, fields) do
    merged = {:metadata, Map.merge(earlier, fields)}
    %{acc | kept: [merged | kept], kept_bytes: acc.kept_bytes - size(previous) + size(merged)}
  end

  defp keep_metadata(acc, fields), do: keep(acc, {:metadata, fields})

  defp metadata(block) do
    block
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, fields ->
      cond do
        String.starts_with?(line, "id:") -> Map.put(fields, :id, line)
        String.starts_with?(line, "retry:") -> Map.put(fields, :retry, line)
        true -> fields
      end
    end)
  end

  defp render({:metadata, fields}), do: fields |> Map.values() |> Enum.join("\n")
  defp render(block), do: block

  # With the blank line that ends it.
  defp size(entry), do: byte_size(render(entry)) + 2
end
