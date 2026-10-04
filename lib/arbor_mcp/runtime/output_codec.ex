defmodule Arbor.MCP.Server.Runtime.OutputCodec do
  @moduledoc false

  @default_limit 1_048_576

  @type prepared :: %{
          term: term(),
          wire: binary(),
          term_bytes: non_neg_integer(),
          wire_bytes: non_neg_integer(),
          bytes: pos_integer()
        }

  # The producer's bounded term is checked before JSON encoding. Only plain
  # JSON values are accepted: user-defined encoders cannot expand a small
  # struct into unbounded output or perform effects during preparation.
  @spec prepare(term(), keyword()) :: {:ok, prepared()} | {:error, atom()}
  def prepare(term, opts \\ []) do
    frame_limit = Keyword.get(opts, :max_frame_bytes, @default_limit)
    term_limit = Keyword.get(opts, :max_term_bytes, frame_limit)

    with :ok <- positive_limits(frame_limit, term_limit),
         term_bytes = :erlang.external_size(term),
         true <- term_bytes <= term_limit || {:error, :output_term_too_large},
         :ok <- json_value(term),
         {:ok, wire} <- encode(term),
         wire_bytes = byte_size(wire) + 1,
         true <- wire_bytes <= frame_limit || {:error, :output_frame_too_large} do
      {:ok,
       %{
         term: term,
         wire: wire,
         term_bytes: term_bytes,
         wire_bytes: wire_bytes,
         bytes: term_bytes + wire_bytes
       }}
    end
  rescue
    ArgumentError -> {:error, :invalid_output}
  end

  defp positive_limits(frame, term)
       when is_integer(frame) and frame > 0 and is_integer(term) and term > 0,
       do: :ok

  defp positive_limits(_, _), do: {:error, :invalid_output_limits}

  defp json_value(value) when value in [nil, true, false], do: :ok
  defp json_value(value) when is_number(value), do: :ok

  defp json_value(value) when is_binary(value),
    do: if(String.valid?(value), do: :ok, else: {:error, :invalid_output})

  defp json_value(value) when is_list(value), do: json_list(value)

  defp json_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, MapSet.new(), fn {key, item}, seen ->
      with {:ok, key} <- json_key(key),
           false <- MapSet.member?(seen, key),
           :ok <- json_value(item) do
        {:cont, MapSet.put(seen, key)}
      else
        _ -> {:halt, {:error, :invalid_output}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp json_value(_), do: {:error, :invalid_output}
  defp json_list([]), do: :ok
  defp json_list([head | tail]), do: with(:ok <- json_value(head), do: json_list(tail))
  defp json_list(_), do: {:error, :invalid_output}
  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp json_key(key) when is_binary(key),
    do: if(String.valid?(key), do: {:ok, key}, else: {:error, :invalid_output})

  defp json_key(_), do: {:error, :invalid_output}

  defp encode(term) do
    case Jason.encode(term, maps: :strict) do
      {:ok, wire} -> {:ok, wire}
      {:error, _} -> {:error, :invalid_output}
    end
  end
end
