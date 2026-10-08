defmodule Arbor.MCP.Internal.SSE do
  @moduledoc false

  @type complete_event :: %{
          optional(:data) => String.t(),
          optional(:id) => String.t(),
          optional(:retry) => non_neg_integer(),
          optional(:event) => String.t()
        }

  @type stream_event :: %{optional(String.t()) => String.t()}

  @spec parse_complete(String.t()) :: [complete_event()]
  def parse_complete(body) when is_binary(body) do
    body
    |> normalize_line_endings()
    |> String.split("\n\n")
    |> Enum.map(&parse_complete_block/1)
    |> Enum.reject(&(&1 == %{}))
  end

  def parse_complete(_body), do: []

  @spec parse_stream(String.t()) :: {[stream_event()], String.t()}
  def parse_stream(buffer) when is_binary(buffer) do
    buffer
    |> normalize_line_endings()
    |> String.split("\n")
    |> parse_stream_lines([], %{}, [])
  end

  def parse_stream(_buffer), do: {[], ""}

  defp parse_complete_block(block) do
    block
    |> String.split("\n")
    |> Enum.reduce(%{}, &parse_complete_line/2)
  end

  defp parse_complete_line(line, acc) do
    cond do
      String.starts_with?(line, "data: ") ->
        data = String.trim_leading(line, "data: ")
        Map.update(acc, :data, data, fn existing -> existing <> data end)

      String.starts_with?(line, "data:") ->
        data = String.trim_leading(line, "data:")
        Map.update(acc, :data, data, fn existing -> existing <> data end)

      String.starts_with?(line, "id: ") ->
        Map.put(acc, :id, String.trim_leading(line, "id: "))

      String.starts_with?(line, "retry: ") ->
        case Integer.parse(String.trim_leading(line, "retry: ")) do
          {ms, ""} when ms >= 0 -> Map.put(acc, :retry, ms)
          _ -> acc
        end

      String.starts_with?(line, "event: ") ->
        Map.put(acc, :event, String.trim_leading(line, "event: "))

      true ->
        acc
    end
  end

  defp parse_stream_lines([], events, current_event, acc) do
    buffer =
      if map_size(current_event) > 0 do
        current_event
        |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)
      else
        Enum.join(acc, "\n")
      end

    {Enum.reverse(events), buffer}
  end

  defp parse_stream_lines(["" | rest], events, current_event, _acc)
       when map_size(current_event) > 0 do
    parse_stream_lines(rest, [current_event | events], %{}, [])
  end

  defp parse_stream_lines([line | rest], events, current_event, acc) do
    case parse_stream_field(line) do
      {:ok, key, value} ->
        updated_event =
          Map.update(current_event, key, value, fn existing ->
            existing <> "\n" <> value
          end)

        parse_stream_lines(rest, events, updated_event, [])

      :ignore ->
        parse_stream_lines(rest, events, current_event, [])

      :incomplete ->
        parse_stream_lines(rest, events, current_event, [line | acc])
    end
  end

  defp parse_stream_field(":" <> _comment), do: :ignore
  defp parse_stream_field(""), do: :ignore

  defp parse_stream_field(line) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        value = String.trim_leading(value)
        {:ok, field, value}

      _ ->
        :incomplete
    end
  end

  defp normalize_line_endings(data) do
    data
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end
end
