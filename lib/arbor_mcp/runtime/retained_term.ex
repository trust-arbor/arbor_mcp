defmodule Arbor.MCP.Server.Runtime.RetainedTerm do
  @moduledoc false

  # Call after the managed logical/retained charge is accepted. Native maps
  # include structs; improper lists and opaque capabilities retain their shape.
  # Host functions keep their original identity. Their captured backing bytes
  # are charged by bytes/1 rather than rebuilding a function environment.
  def materialize(value) when is_binary(value) do
    if :binary.referenced_byte_size(value) > byte_size(value),
      do: :binary.copy(value),
      else: value
  end

  def materialize(value) when is_bitstring(value),
    do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  def materialize(value) when is_map(value) do
    :maps.fold(
      fn key, item, acc -> Map.put(acc, materialize(key), materialize(item)) end,
      %{},
      value
    )
  end

  def materialize([head | tail]), do: [materialize(head) | materialize(tail)]

  def materialize(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> materialize() |> List.to_tuple()

  def materialize(value), do: value

  def bytes(value, limit \\ :infinity) do
    logical = :erlang.external_size(value)

    if limit != :infinity and logical > limit do
      logical
    else
      {extra, _seen} = closure_bytes(value, false, MapSet.new())
      logical + extra
    end
  end

  defp closure_bytes(value, captured, seen) when is_bitstring(value) do
    extra =
      if captured, do: :binary.referenced_byte_size(value) - div(bit_size(value) + 7, 8), else: 0

    {max(0, extra), seen}
  end

  defp closure_bytes(value, _captured, seen) when is_function(value) do
    if MapSet.member?(seen, value) do
      {0, seen}
    else
      {:env, environment} = :erlang.fun_info(value, :env)
      closure_bytes(environment, true, MapSet.put(seen, value))
    end
  end

  defp closure_bytes(value, captured, seen) when is_map(value) do
    :maps.fold(
      fn key, item, {bytes, seen} ->
        {key_bytes, seen} = closure_bytes(key, captured, seen)
        {item_bytes, seen} = closure_bytes(item, captured, seen)
        {bytes + key_bytes + item_bytes, seen}
      end,
      {0, seen},
      value
    )
  end

  defp closure_bytes([head | tail], captured, seen) do
    {head_bytes, seen} = closure_bytes(head, captured, seen)
    {tail_bytes, seen} = closure_bytes(tail, captured, seen)
    {head_bytes + tail_bytes, seen}
  end

  defp closure_bytes(value, captured, seen) when is_tuple(value),
    do: closure_bytes(Tuple.to_list(value), captured, seen)

  defp closure_bytes(_value, _captured, seen), do: {0, seen}
end
