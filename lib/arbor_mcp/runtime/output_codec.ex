defmodule Arbor.MCP.Server.Runtime.OutputCodec do
  @moduledoc false

  @default_limit 1_048_576

  @type prepared :: %{
          term: term(),
          wire: binary() | nil,
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
    deadline = Keyword.get(opts, :deadline, :infinity)

    with :ok <- positive_limits(frame_limit, term_limit),
         :ok <- bounded_term(term, term_limit, deadline),
         term_bytes = :erlang.external_size(term),
         true <- term_bytes <= term_limit || {:error, :output_term_too_large},
         {:ok, wire, wire_bytes} <- encode_policy(term, opts, frame_limit),
         :ok <- deadline_open(deadline) do
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

  defp encode_policy(term, opts, limit) do
    case Keyword.get(opts, :codec, :json) do
      :term ->
        {:ok, nil, 0}

      codec when codec in [:json, :protocol] ->
        with {:ok, json} <- protocol_value(term, codec),
             :ok <- json_value(json),
             {:ok, wire} <- encode(json),
             bytes = byte_size(wire) + 1,
             true <- bytes <= limit || {:error, :output_frame_too_large},
             do: {:ok, wire, bytes}

      _invalid ->
        {:error, :invalid_output_codec}
    end
  end

  # Protocol helpers use atom values (for example Content.text/1's :text).
  # Normalize only ordinary values, without invoking user-defined encoders.
  # The original term remains the BEAM payload; normalization determines wire.
  defp protocol_value(term, :json), do: {:ok, term}
  defp protocol_value(value, :protocol) when value in [nil, true, false], do: {:ok, value}
  defp protocol_value(value, :protocol) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp protocol_value(value, :protocol) when is_list(value) do
    protocol_list(value, [])
  end

  defp protocol_value(value, :protocol) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case protocol_value(item, :protocol) do
        {:ok, item} -> {:cont, {:ok, Map.put(acc, key, item)}}
        error -> {:halt, error}
      end
    end)
  end

  defp protocol_value(value, :protocol), do: {:ok, value}

  defp protocol_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp protocol_list([head | tail], acc) do
    with {:ok, head} <- protocol_value(head, :protocol), do: protocol_list(tail, [head | acc])
  end

  defp protocol_list(_invalid, _acc), do: {:error, :invalid_output}

  # Walk native Erlang terms first. No Enumerable/Jason/Inspect protocol runs.
  # The lower bound rejects a huge/deep object after finite work; external_size
  # then computes the exact charge on that bounded object without serializing it.
  defp bounded_term(term, limit, deadline), do: walk([{:value, term}], 0, limit, deadline)
  defp walk([], _used, _limit, deadline), do: deadline_open(deadline)

  defp walk(_todo, used, limit, _deadline) when used > limit,
    do: {:error, :output_term_too_large}

  defp walk([{:map_iterator, iterator} | rest], used, limit, deadline) do
    case :maps.next(iterator) do
      :none ->
        walk(rest, used, limit, deadline)

      {key, value, next} ->
        walk(
          [{:value, key}, {:value, value}, {:map_iterator, next} | rest],
          used,
          limit,
          deadline
        )
    end
  end

  defp walk([{:tuple_iterator, tuple, index} | rest], used, limit, deadline) do
    if index < tuple_size(tuple),
      do:
        walk(
          [{:value, elem(tuple, index)}, {:tuple_iterator, tuple, index + 1} | rest],
          used,
          limit,
          deadline
        ),
      else: walk(rest, used, limit, deadline)
  end

  defp walk([{:value, term} | rest], used, limit, deadline) do
    with :ok <- deadline_open(deadline) do
      cond do
        is_binary(term) ->
          walk(rest, used + byte_size(term) + 1, limit, deadline)

        term == [] ->
          walk(rest, used + 1, limit, deadline)

        is_list(term) ->
          walk([{:value, hd(term)}, {:value, tl(term)} | rest], used + 1, limit, deadline)

        is_map(term) ->
          walk([{:map_iterator, :maps.iterator(term)} | rest], used + 1, limit, deadline)

        is_tuple(term) ->
          walk([{:tuple_iterator, term, 0} | rest], used + 1, limit, deadline)

        is_function(term) ->
          {:env, env} = :erlang.fun_info(term, :env)
          walk([{:value, env} | rest], used + 1, limit, deadline)

        true ->
          walk(rest, used + 1, limit, deadline)
      end
    end
  end

  defp deadline_open(:infinity), do: :ok

  defp deadline_open(deadline) when is_integer(deadline) do
    if deadline > System.monotonic_time(:millisecond), do: :ok, else: {:error, :output_expired}
  end

  defp deadline_open(_), do: {:error, :invalid_output_deadline}

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
