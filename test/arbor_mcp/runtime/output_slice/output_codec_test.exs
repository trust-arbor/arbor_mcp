defmodule Arbor.MCP.Server.Runtime.OutputCodecTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime.OutputCodec

  defmodule Custom do
    defstruct [:value]
  end

  test "prepares exact JSON and accounts the original term and line delimiter" do
    term = %{"result" => [%{text: "héllo\n"}, true, nil, 4.5]}
    assert {:ok, prepared} = OutputCodec.prepare(term)
    assert Jason.decode!(prepared.wire) == %{"result" => [%{"text" => "héllo\n"}, true, nil, 4.5]}
    assert prepared.term == term
    assert prepared.term_bytes == :erlang.external_size(term)
    assert prepared.wire_bytes == byte_size(prepared.wire) + 1
    assert prepared.bytes == prepared.term_bytes + prepared.wire_bytes
  end

  test "rejects escaped wire expansion after bounded term acceptance" do
    term = String.duplicate(<<0>>, 30)
    assert :erlang.external_size(term) < 100
    assert {:error, :output_frame_too_large} = OutputCodec.prepare(term, max_frame_bytes: 100)
  end

  test "rejects oversized original terms before JSON encoding" do
    assert {:error, :output_term_too_large} =
             OutputCodec.prepare(String.duplicate("a", 100), max_term_bytes: 30)
  end

  test "rejects custom encoders, unsupported values and ambiguous JSON keys" do
    for term <- [
          %Custom{value: "a"},
          self(),
          make_ref(),
          {1, 2},
          [1 | 2],
          :atom,
          <<255>>,
          %{"a" => 2, a: 1},
          %{1 => 2}
        ] do
      assert {:error, :invalid_output} = OutputCodec.prepare(term)
    end
  end

  test "enforces positive limits and accepts the exact encoded frame boundary" do
    assert {:error, :invalid_output_limits} = OutputCodec.prepare("a", max_frame_bytes: 0)

    assert {:ok, %{wire: "\"a\""}} =
             OutputCodec.prepare("a", max_frame_bytes: 4, max_term_bytes: 20)

    assert {:error, :output_frame_too_large} =
             OutputCodec.prepare("a", max_frame_bytes: 3, max_term_bytes: 20)
  end
end
