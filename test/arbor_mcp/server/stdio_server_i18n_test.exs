defmodule Arbor.MCP.Server.StdioServerI18nTest do
  @moduledoc """
  Launches a real stdio server in a subprocess under several locales and
  drives it with non-ASCII traffic.

  The locale is the only place the environment reaches the transport, and it
  only reaches the stdio transport, so this is the one test that carries a
  locale matrix. Every run uses a tool that generates its own non-ASCII text:
  an echo tool cannot catch the defect, because the write reverses the read's
  corruption exactly.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Test.I18nCorpus

  @moduletag :integration
  @moduletag timeout: 120_000

  @locales [
    {"unset", nil},
    {"C", "C"},
    {"en_US.UTF-8", "en_US.UTF-8"},
    {"ja_JP.eucJP", "ja_JP.eucJP"}
  ]

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ex-mcp-stdio-i18n-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    script = Path.join(dir, "server.exs")
    File.write!(script, server_script())

    input = Path.join(dir, "input.jsonl")
    File.write!(input, input_bytes())

    %{script: script, input: input}
  end

  for {label, locale} <- @locales do
    test "moves non-ASCII frames byte-exact under LANG=#{label}", %{script: script, input: input} do
      {output, stderr, code} = run_server(script, input, unquote(locale))

      # Failure output may contain bytes that are not valid UTF-8, which would
      # crash the ExUnit formatter and hide the failure; keep it printable.
      diagnostics =
        "exit #{code}\nstdout:\n#{printable(output)}\nstderr:\n#{printable(stderr)}"

      assert code == 0, diagnostics

      responses =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} ->
              decoded

            {:error, _} ->
              flunk("undecodable line #{inspect(line, binaries: :as_binaries)}\n" <> diagnostics)
          end
        end)

      assert Enum.map(responses, & &1["id"]) == [1, 2, 3, 4], diagnostics

      generated = text_of(Enum.at(responses, 1))
      assert generated == "generated=" <> I18nCorpus.all_text()

      echoed = text_of(Enum.at(responses, 2))

      assert echoed ==
               "echoed=" <>
                 I18nCorpus.all_text() <>
                 " bytes=" <> Integer.to_string(byte_size(I18nCorpus.all_text()))

      assert %{"id" => 4, "result" => %{}} = Enum.at(responses, 3)
    end
  end

  # The input stream starts with a byte-order mark, carries the corpus both as
  # a request argument and as a `\u`-escaped surrogate pair, includes one line
  # that is not valid UTF-8, and ends with a ping that proves the server
  # survived all of it.
  #
  # The invalid line is sent only on OTP 28 and newer. On OTP 27, input that
  # is already buffered when the io server meets an undecodable byte is left
  # half decoded as unicode and half held as raw bytes while the device
  # reports latin1 for all of it; no read strategy recovers that, so the
  # session ends. That is an OTP 27 io-server defect, not something the
  # transport can fix, and it was equally fatal before this transport change.
  defp input_bytes do
    all = I18nCorpus.all_text()

    requests = [
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "i18n", "version" => "1"}
        }
      }),
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "generate", "arguments" => %{}}
      }),
      I18nCorpus.surrogate_escaped_json(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"text" => all}}
      })
    ]

    invalid_line =
      if String.to_integer(System.otp_release()) >= 28,
        do: I18nCorpus.invalid_utf8_frame(),
        else: []

    IO.iodata_to_binary([
      I18nCorpus.bom(),
      Enum.map(requests, &[&1, "\n"]),
      invalid_line,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 4, "method" => "ping"}),
      "\n"
    ])
  end

  defp run_server(script, input, locale) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    locale_env =
      case locale do
        nil -> [{"LANG", nil}, {"LC_ALL", nil}, {"LC_CTYPE", nil}]
        value -> [{"LANG", value}, {"LC_ALL", value}]
      end

    stderr_path = input <> ".stderr"

    {output, code} =
      System.cmd(
        "sh",
        [
          "-c",
          # Feed stdin through a pipe, as MCP hosts do. A redirected file lets
          # the io server pre-read and decode the whole input at VM start,
          # which is not how a host behaves and, on OTP 27, changes the
          # device's state before the first frame is read.
          ~s(cat "$I18N_INPUT" | "$@" 2> "$I18N_STDERR"),
          "stdio-i18n",
          System.find_executable("elixir")
        ] ++ paths ++ [script],
        env:
          locale_env ++ [{"MIX_ENV", "test"}, {"I18N_INPUT", input}, {"I18N_STDERR", stderr_path}]
      )

    {output, File.read!(stderr_path), code}
  end

  defp text_of(%{"result" => %{"content" => [%{"type" => "text", "text" => text}]}}), do: text

  defp printable(binary) do
    if String.valid?(binary),
      do: binary,
      else: inspect(binary, binaries: :as_binaries, limit: :infinity, printable_limit: :infinity)
  end

  # The corpus is read from the support module at runtime rather than embedded
  # as a literal: `inspect/1` on Elixir 1.17 writes bidi control characters
  # raw, and the compiler rejects them in source.
  defp server_script do
    ~s"""
    # A bare `elixir` VM with the test code path: start only what the stdio
    # server itself needs, not every application on the path.
    Logger.configure(level: :error)
    {:ok, _apps} = Application.ensure_all_started(:jason)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    defmodule I18nStdioServer do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, name: "i18n", version: "1"

      tool "generate", "Generates non-ASCII text of its own" do
        run(fn _args, state -> {:ok, "generated=" <> Arbor.MCP.Test.I18nCorpus.all_text(), state} end)
      end

      tool "echo", "Echoes text and reports its byte length" do
        param(:text, :string, required: true)

        run(fn args, state ->
          {:ok, "echoed=" <> args.text <> " bytes=" <> Integer.to_string(byte_size(args.text)), state}
        end)
      end
    end

    {:ok, pid} = I18nStdioServer.start_link(transport: :stdio)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> exit({:server_down, reason})
    after
      30_000 -> exit(:eof_did_not_stop_server)
    end
    """
  end
end
