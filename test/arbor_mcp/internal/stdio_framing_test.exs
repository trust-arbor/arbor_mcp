defmodule Arbor.RPC.StdioFramingTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Test.I18nCorpus
  alias Arbor.RPC.StdioFraming

  for mode <- [:unicode, :latin1] do
    describe "on a device opened in #{mode} mode" do
      @mode mode

      test "detects the device's mode" do
        {:ok, device} = StringIO.open("", encoding: @mode)
        assert StdioFraming.mode(device) == @mode
      end

      test "writes every corpus frame byte-exact" do
        for {label, text} <- I18nCorpus.strings() do
          {:ok, device} = StringIO.open("", encoding: @mode)
          frame = Jason.encode!(%{"t" => text})

          assert :ok = StdioFraming.write_frame(device, frame)
          {_input, output} = StringIO.contents(device)
          assert output == frame <> "\n", label
        end
      end

      test "reads every corpus frame byte-exact, by line and by unit" do
        for {label, text} <- I18nCorpus.strings() do
          frame = Jason.encode!(%{"t" => text})

          {:ok, device} = StringIO.open(frame <> "\n", encoding: @mode)
          assert {:ok, line} = StdioFraming.read_line(device)
          assert line == frame <> "\n", label
          assert :eof = StdioFraming.read_line(device)

          {:ok, device} = StringIO.open(frame <> "\n", encoding: @mode)
          assert read_all_units(device, @mode) == frame <> "\n", label
        end
      end
    end
  end

  test "a byte write on a unicode device is not byte-exact, which is why the mode is consulted" do
    frame = Jason.encode!(%{"t" => "café"})

    {:ok, unicode_device} = StringIO.open("", encoding: :unicode)
    :ok = :file.write(unicode_device, [frame, ?\n])
    {_input, output} = StringIO.contents(unicode_device)
    refute output == frame <> "\n"
  end

  test "follows a device whose mode changes between operations" do
    # OTP flips a unicode-mode stdio to latin1 when it meets input it cannot
    # decode. Every read and write must use the mode current at that moment.
    frame = Jason.encode!(%{"t" => "café 日本語"})
    {:ok, device} = StringIO.open("", encoding: :unicode)

    assert :ok = StdioFraming.write_frame(device, frame)
    :ok = :io.setopts(device, encoding: :latin1)
    assert :ok = StdioFraming.write_frame(device, frame)

    {_input, output} = StringIO.contents(device)
    assert output == frame <> "\n" <> frame <> "\n"
  end

  test "a unicode device hands back whole characters per unit" do
    {:ok, device} = StringIO.open("🪁x\n", encoding: :unicode)
    assert {:ok, "🪁"} = StdioFraming.read_unit(device, :unicode)
    assert {:ok, "x"} = StdioFraming.read_unit(device, :unicode)
    assert {:ok, "\n"} = StdioFraming.read_unit(device, :unicode)
    assert :eof = StdioFraming.read_unit(device, :unicode)
  end

  test "treats an unqueryable device as a byte device" do
    assert StdioFraming.mode(spawn(fn -> :ok end)) == :latin1
  end

  test "strips a byte-order mark only from the start of a frame" do
    frame = ~S({"a":1})
    assert StdioFraming.strip_bom(I18nCorpus.bom() <> frame) == frame
    assert StdioFraming.strip_bom(frame) == frame
    assert StdioFraming.strip_bom("") == ""
    assert StdioFraming.strip_bom(frame <> I18nCorpus.bom()) == frame <> I18nCorpus.bom()
  end

  defp read_all_units(device, mode, acc \\ []) do
    case StdioFraming.read_unit(device, mode) do
      {:ok, unit} -> read_all_units(device, mode, [unit | acc])
      :eof -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
