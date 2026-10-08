defmodule Arbor.MCP.Content.SchemaPolicy.Instance do
  @moduledoc false

  @spec check(term(), keyword(), boolean()) :: :ok | {:error, term()}
  def check(value, opts, compatible? \\ false) do
    opts = Keyword.put(opts, :compatible?, compatible?)

    case walk(value, 0, opts[:max_instance_bytes], Map.new(opts)) do
      {:ok, _remaining} -> :ok
      error -> error
    end
  end

  defp walk(_value, depth, _remaining, opts) when depth > opts.max_instance_depth,
    do: {:error, {:schema_limit_exceeded, :max_instance_depth, depth}}

  defp walk(_value, _depth, remaining, opts) when remaining < 0,
    do: {:error, {:schema_limit_exceeded, :max_instance_bytes, opts.max_instance_bytes + 1}}

  defp walk(value, depth, remaining, opts) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, remaining - 2, MapSet.new()}, fn {key, item},
                                                                    {:ok, remaining, keys} ->
      with {:ok, key} <- key(key),
           false <- MapSet.member?(keys, key),
           {:ok, remaining} <- walk(key, depth + 1, remaining - 3, opts),
           {:ok, remaining} <- walk(item, depth + 1, remaining, opts) do
        {:cont, {:ok, remaining, MapSet.put(keys, key)}}
      else
        {:error, _reason} = error -> {:halt, error}
        true -> {:halt, invalid()}
      end
    end)
    |> map_result(opts)
  end

  defp walk(value, depth, remaining, opts) when is_list(value),
    do: walk_list(value, depth, remaining - 2, opts)

  defp walk(value, _depth, remaining, opts) when is_binary(value) do
    case remaining - byte_size(value) - 2 do
      remaining when remaining < 0 -> finish(remaining, opts)
      remaining -> if String.valid?(value), do: {:ok, remaining}, else: invalid()
    end
  end

  defp walk(value, _depth, remaining, opts) when is_number(value),
    do: finish(remaining - :erlang.external_size(value), opts)

  defp walk(value, _depth, remaining, opts) when value in [true, false, nil],
    do: finish(remaining - 5, opts)

  defp walk(value, depth, remaining, %{compatible?: true} = opts) when is_atom(value),
    do: walk(Atom.to_string(value), depth, remaining, opts)

  defp walk(_value, _depth, _remaining, _opts), do: invalid()

  defp walk_list([], _depth, remaining, opts), do: finish(remaining, opts)

  defp walk_list([item | rest], depth, remaining, opts) do
    with {:ok, remaining} <- walk(item, depth + 1, remaining - 1, opts),
         do: walk_list(rest, depth, remaining, opts)
  end

  defp walk_list(_invalid, _depth, _remaining, _opts), do: invalid()

  defp key(key) when is_binary(key), do: {:ok, key}
  defp key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key(_key), do: invalid()

  defp map_result({:ok, remaining, _keys}, opts), do: finish(remaining, opts)
  defp map_result(error, _opts), do: error

  defp finish(remaining, opts) when remaining < 0,
    do: {:error, {:schema_limit_exceeded, :max_instance_bytes, opts.max_instance_bytes + 1}}

  defp finish(remaining, _opts), do: {:ok, remaining}

  defp invalid,
    do: {:error, {:schema_validation_failed, "instance must contain plain JSON values"}}
end
