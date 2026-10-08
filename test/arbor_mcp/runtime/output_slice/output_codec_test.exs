defmodule Arbor.MCP.Server.Runtime.OutputCodecTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime.{OutputCodec, OutputLedger}

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

  test "valid UTF8 and escaped controls keep exact JSON, charges and frame boundaries" do
    for codec <- [:json, :protocol],
        value <- valid_utf8_values(),
        term <- [value, [value], %{"value" => value}, %{value => value}] do
      wire = Jason.encode!(term, maps: :strict)
      frame_bytes = byte_size(wire) + 1
      opts = [codec: codec, max_term_bytes: 1_048_576, max_frame_bytes: frame_bytes]

      assert {:ok, prepared} = OutputCodec.prepare(term, opts)
      assert prepared.term == term
      assert prepared.wire == wire
      assert prepared.term_bytes == :erlang.external_size(term)
      assert prepared.wire_bytes == frame_bytes
      assert prepared.bytes == prepared.term_bytes + frame_bytes

      assert {:error, :output_frame_too_large} =
               OutputCodec.prepare(term, Keyword.put(opts, :max_frame_bytes, frame_bytes - 1))
    end

    assert {:ok, %{wire: "\"\\u0000\"", wire_bytes: 9}} = OutputCodec.prepare(<<0>>)
  end

  test "encoder rejects invalid UTF8 values and keys in both JSON policies" do
    for codec <- [:json, :protocol],
        value <- invalid_utf8_values(),
        term <- [value, [value], %{"value" => value}, %{value => "value"}] do
      assert {:error, :invalid_output} = OutputCodec.prepare(term, codec: codec)
    end
  end

  test "protocol atom normalization and ambiguous key rejection stay distinct" do
    term = %{"kind" => :text, "value" => "héllo"}
    assert {:error, :invalid_output} = OutputCodec.prepare(term, codec: :json)
    assert {:ok, prepared} = OutputCodec.prepare(term, codec: :protocol)
    assert prepared.term == term
    assert prepared.wire == Jason.encode!(%{"kind" => "text", "value" => "héllo"})

    for codec <- [:json, :protocol],
        ambiguous <- [%{"a" => 1, a: 2}, %{"a\n" => 1, :"a\n" => 2}] do
      assert {:error, :invalid_output} = OutputCodec.prepare(ambiguous, codec: codec)
    end
  end

  test "plain JSON checks reject unsupported terms before encoder effects" do
    marker = make_ref()
    caller = self()

    fragment =
      Jason.Fragment.new(fn _opts ->
        send(caller, {:encoder_effect, marker})
        "null"
      end)

    assert {:ok, "null"} = Jason.encode(fragment)
    assert_receive {:encoder_effect, ^marker}

    for codec <- [:json, :protocol],
        term <- [%Custom{value: "a"}, fragment, self(), make_ref(), {1, 2}, [1 | 2], %{1 => 2}] do
      assert {:error, :invalid_output} = OutputCodec.prepare(term, codec: codec)
    end

    refute_receive {:encoder_effect, ^marker}, 0
  end

  test "recursive nil values stay null while protocol atoms remain strings" do
    plain = %{"nested" => [nil, %{nil => [nil, true, false]}]}
    expected = %{"nested" => [nil, %{"nil" => [nil, true, false]}]}

    for codec <- [:json, :protocol] do
      assert {:ok, prepared} = OutputCodec.prepare(plain, codec: codec)
      assert prepared.term === plain
      assert Jason.decode!(prepared.wire) === expected
    end

    protocol = %{"nested" => [nil, %{nil => [nil, :null, :text]}]}
    assert {:error, :invalid_output} = OutputCodec.prepare(protocol, codec: :json)
    assert {:ok, prepared} = OutputCodec.prepare(protocol, codec: :protocol)
    assert prepared.term === protocol

    assert Jason.decode!(prepared.wire) ===
             %{"nested" => [nil, %{"nil" => [nil, "null", "text"]}]}
  end

  test "escapes and UTF8 around eight-byte boundaries preserve finite frame limits" do
    for codec <- [:json, :protocol],
        length <- [7, 8, 15, 16],
        suffix <- ["\"", "\\", <<0>>, "é", "€", "😀"] do
      value = String.duplicate("a", length) <> suffix <> "tail"
      term = %{value => [value, nil]}
      frame_bytes = byte_size(Jason.encode!(term, maps: :strict)) + 1
      opts = [codec: codec, max_term_bytes: 1_048_576, max_frame_bytes: frame_bytes]

      assert {:ok, prepared} = OutputCodec.prepare(term, opts)
      assert prepared.term === term
      assert Jason.decode!(prepared.wire) === term
      assert prepared.wire_bytes == frame_bytes
      assert byte_size(prepared.wire) + 1 == frame_bytes

      assert {:error, :output_frame_too_large} =
               OutputCodec.prepare(term, Keyword.put(opts, :max_frame_bytes, frame_bytes - 1))
    end
  end

  test "invalid UTF8 after complete ASCII chunks is rejected in values and keys" do
    for codec <- [:json, :protocol],
        length <- [7, 8, 15, 16],
        suffix <- [<<0x80>>, <<0xC2>>, <<0xE2, 0x82>>, <<0xF0, 0x9F, 0x98>>, <<0xED, 0xA0, 0x80>>] do
      value = String.duplicate("a", length) <> suffix

      for term <- [value, %{value => "value"}] do
        assert {:error, :invalid_output} = OutputCodec.prepare(term, codec: codec)
      end
    end
  end

  test "objects larger than 32 entries preserve values without requiring member order" do
    term = Map.new(1..64, fn index -> {"entry-#{index}", [index, nil, true, false]} end)

    for codec <- [:json, :protocol] do
      assert {:ok, prepared} = OutputCodec.prepare(term, codec: codec)
      assert prepared.term === term
      assert Jason.decode!(prepared.wire) === term
    end
  end

  test "original deadline rejection and native term policy remain unchanged" do
    expired = System.monotonic_time(:millisecond) - 1

    for codec <- [:json, :protocol], term <- ["valid", <<255>>, %{<<255>> => "value"}] do
      assert {:error, :output_expired} =
               OutputCodec.prepare(term, codec: codec, deadline: expired)
    end

    assert {:error, :invalid_output_deadline} =
             OutputCodec.prepare("valid", deadline: :invalid)

    term = {self(), make_ref(), %Custom{value: <<255>>}, [<<255>> | <<128>>]}
    assert {:ok, prepared} = OutputCodec.prepare(term, codec: :term)
    assert prepared.term == term
    assert prepared.wire == nil
    assert prepared.wire_bytes == 0
    assert prepared.bytes == prepared.term_bytes
  end

  test "invalid JSON and expired preparation create no ledger ticket or ready output" do
    ledger = start_supervised!({OutputLedger, owner: self()})
    assert {:ok, ref} = OutputLedger.ref(ledger)
    assert :ok = OutputLedger.open_scope(ref, :utf8)
    assert :ok = OutputLedger.subscribe(ref, :utf8, self())
    deadline = System.monotonic_time(:millisecond) + 5_000

    for codec <- [:json, :protocol], term <- [<<255>>, %{<<255>> => "value"}] do
      assert {:error, :invalid_output} =
               OutputLedger.prepare(ref, term, scope: :utf8, deadline: deadline, codec: codec)
    end

    assert {:error, :invalid_output_deadline} =
             OutputLedger.prepare(ref, "valid",
               scope: :utf8,
               deadline: System.monotonic_time(:millisecond) - 1
             )

    assert :empty = OutputLedger.checkout(ref, :utf8)

    assert %{frames: 0, bytes: 0, prepared: 0, queued: 0, in_flight: 0, pending_controls: 0} =
             OutputLedger.stats(ref)

    refute_receive {:arbor_mcp_output, _, :utf8, :ready}, 0
  end

  test "prepared valid subbinary keys and values detach their backing storage" do
    backing = String.duplicate("a", 8_192)
    value = binary_part(backing, 128, 128)
    assert :binary.referenced_byte_size(value) > byte_size(value)
    term = %{value => [value]}

    for codec <- [:json, :protocol] do
      assert {:ok, prepared} = OutputCodec.prepare(term, codec: codec)
      assert [{key, [item]}] = Map.to_list(prepared.term)
      assert key == value and item == value
      assert :binary.referenced_byte_size(key) == byte_size(key)
      assert :binary.referenced_byte_size(item) == byte_size(item)
      assert prepared.wire == Jason.encode!(term, maps: :strict)
      assert prepared.bytes == prepared.term_bytes + prepared.wire_bytes
    end
  end

  defp valid_utf8_values do
    [
      "",
      "plain",
      "héllo",
      "€",
      "😀",
      <<0x7F>>,
      "quote\"slash\\",
      <<0xE2, 0x80, 0xA8, 0xE2, 0x80, 0xA9>>,
      :erlang.list_to_binary(Enum.to_list(0..31))
    ]
  end

  defp invalid_utf8_values do
    [
      <<0x80>>,
      <<0xBF>>,
      <<0xFF>>,
      <<0xC0, 0xAF>>,
      <<0xC1, 0xBF>>,
      <<0xE0, 0x80, 0xAF>>,
      <<0xF0, 0x80, 0x80, 0xAF>>,
      <<0xED, 0xA0, 0x80>>,
      <<0xF4, 0x90, 0x80, 0x80>>,
      <<0xC2>>,
      <<0xE2, 0x82>>,
      <<0xF0, 0x9F, 0x98>>,
      <<0xC2, 0x20>>,
      <<0xE2, 0x28, 0xA1>>,
      <<0xF0, 0x28, 0x8C, 0xBC>>,
      <<0x61, 0xFF, 0x62>>
    ]
  end
end
