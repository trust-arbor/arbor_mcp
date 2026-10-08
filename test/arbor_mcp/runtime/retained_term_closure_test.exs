defmodule Arbor.MCP.Server.Runtime.RetainedTermClosureTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.RetainedTerm

  defmodule Box do
    defstruct [:value, :items]
  end

  test "ordinary binary and bitstring backing does not add closure charges" do
    {binary, bits} = slices()

    for value <- [binary, bits, {binary, bits}, [binary | bits], %{binary => bits}] do
      assert RetainedTerm.bytes(value) == :erlang.external_size(value)
    end
  end

  test "one captured binary retains its backing and function identity" do
    {binary, _bits} = slices()
    function = capture(binary)
    assert {:env, [^binary]} = :erlang.fun_info(function, :env)
    extra = backing_extra(binary)
    assert extra > 0
    assert RetainedTerm.bytes(function) == :erlang.external_size(function) + extra
    assert RetainedTerm.materialize(function) === function
    assert :binary.referenced_byte_size(function.()) == :binary.referenced_byte_size(binary)
  end

  test "a captured non-byte-aligned bitstring uses its rounded logical byte size" do
    {_binary, bits} = slices()
    function = capture(bits)
    extra = backing_extra(bits)
    assert extra > 0
    assert rem(bit_size(bits), 8) != 0
    assert RetainedTerm.bytes(function) == :erlang.external_size(function) + extra
  end

  test "shared nested closures are scanned once across maps, keys and improper tails" do
    {binary, _bits} = slices()
    inner = capture(binary)
    outer = capture({inner, binary})
    value = %Box{value: outer, items: %{inner => [outer | {inner, outer}]}}

    assert RetainedTerm.bytes(value) == :erlang.external_size(value) + 2 * backing_extra(binary)
    assert RetainedTerm.materialize(value) === value
  end

  test "distinct captured functions keep their separate backing occurrence charge" do
    {binary, _bits} = slices()
    zero = capture(binary)
    one = capture_one(binary)
    value = [zero, one, zero, one]
    refute zero === one

    assert RetainedTerm.bytes(value) == :erlang.external_size(value) + 2 * backing_extra(binary)
  end

  test "logical oversize rejection and equality preserve the original limit boundary" do
    {binary, _bits} = slices()
    value = capture(binary)
    logical = :erlang.external_size(value)

    for limit <- [-1, 0, logical - 1] do
      assert RetainedTerm.bytes(value, limit) == logical
    end

    for limit <- [logical, logical + 1, :infinity] do
      assert RetainedTerm.bytes(value, limit) == logical + backing_extra(binary)
    end
  end

  test "materialization detaches data while preserving native shapes and opaque terms" do
    {binary, bits} = slices()
    function = capture(binary)
    reference = make_ref()

    original = %Box{
      value: {binary, bits, function, self(), reference},
      items: [binary | reference]
    }

    materialized = RetainedTerm.materialize(original)

    assert materialized === original
    assert %Box{value: {detached, detached_bits, ^function, pid, ^reference}} = materialized
    assert pid == self()
    assert :binary.referenced_byte_size(detached) == byte_size(detached)
    assert :binary.referenced_byte_size(detached_bits) <= div(bit_size(detached_bits) + 7, 8)
    assert function.() === binary
  end

  test "deep iterative traversal preserves logical sizes and opaque leaves" do
    leaf = {self(), make_ref(), &Function.identity/1, nil, false, 1.5}
    tuple = Enum.reduce(1..10_000, leaf, fn _, value -> {value} end)
    improper = Enum.reduce(1..10_000, leaf, fn n, value -> [n | value] end)

    assert RetainedTerm.bytes(tuple) == :erlang.external_size(tuple)
    assert RetainedTerm.bytes(improper) == :erlang.external_size(improper)
  end

  defp slices do
    backing = :binary.copy("0123456789abcdef", 65_536)
    binary = binary_part(backing, 100, 96)
    <<_::1, bits::bitstring-size(769), _::bitstring>> = backing
    assert :binary.referenced_byte_size(binary) > byte_size(binary)
    assert :binary.referenced_byte_size(bits) > div(bit_size(bits) + 7, 8)
    {binary, bits}
  end

  defp capture(value), do: fn -> value end
  defp capture_one(value), do: fn -> {value} end

  defp backing_extra(value),
    do: max(0, :binary.referenced_byte_size(value) - div(bit_size(value) + 7, 8))
end
