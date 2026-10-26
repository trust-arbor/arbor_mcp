defmodule ExMCP.Transport.StdioShutdownTest do
  @moduledoc """
  The stdio transport follows the MCP shutdown order: close the server's stdin,
  wait `:eof_grace` (2 s, as in the reference SDKs), then SIGTERM and SIGKILL.
  The client's close limit grows to cover that budget.
  """

  use ExUnit.Case, async: true

  import ExMCP.TestHelpers, only: [wait_until: 1]

  alias ExMCP.Client.Deadline
  alias ExMCP.Transport.Stdio

  describe "shutdown_options/1" do
    test "defaults give the server 2 s after EOF within a 2.5 s budget" do
      opts = Stdio.shutdown_options(command: ["true"])
      assert opts[:eof_grace] == 2_000
      assert opts[:cleanup_timeout] == 2_500
    end

    test "an explicit EOF grace sets the budget around it" do
      assert Stdio.shutdown_options(eof_grace: 5_000)[:cleanup_timeout] == 5_500
      assert Stdio.shutdown_options(eof_grace: 0, term_grace: 200)[:cleanup_timeout] == 600
    end

    test "an explicit budget keeps the EOF grace that fits inside it" do
      assert Stdio.shutdown_options(cleanup_timeout: 500)[:eof_grace] == 350
      assert Stdio.shutdown_options(cleanup_timeout: 100)[:eof_grace] == 0
      assert Stdio.shutdown_options(cleanup_timeout: 10_000)[:eof_grace] == 2_000
    end

    test "explicit and invalid values pass through for the subprocess to validate" do
      opts = [eof_grace: 10, cleanup_timeout: 400]
      assert Stdio.shutdown_options(opts) == opts
      assert Stdio.shutdown_options(term_grace: :bad) == [term_grace: :bad]
    end
  end

  describe "client close limit" do
    test "covers a stdio server's shutdown budget" do
      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"]) == 3_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], eof_grace: 5_000) ==
               6_000

      assert Deadline.cleanup_timeout(transports: [{:stdio, command: ["true"]}]) == 3_000
    end

    test "stays at the default for other transports and unusable options" do
      assert Deadline.cleanup_timeout(transport: :http, url: "http://localhost:1/mcp") == 1_000
      assert Deadline.cleanup_timeout([]) == 1_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], cleanup_timeout: 100) ==
               1_000
    end
  end

  @tag :tmp_dir
  test "close lets a server that exits on EOF do so without a signal", %{tmp_dir: tmp_dir} do
    status_file = Path.join(tmp_dir, "exit_status.txt")
    # Exits 0 on stdin EOF; a SIGTERM delivered first would make it write "143" and exit 143.
    script =
      "trap 'echo 143 > \"" <>
        status_file <>
        "\"; exit 143' TERM; while read -r _; do :; done; echo 0 > \"" <>
        status_file <> "\"; exit 0"

    {:ok, state} = Stdio.connect(command: ["/bin/sh", "-c", script])

    assert :ok = Stdio.close(state)

    wait_until(fn ->
      case File.read(status_file) do
        {:ok, content} -> String.trim(content) == "0"
        _ -> false
      end
    end)
  end

  @tag :tmp_dir
  test "close sends SIGTERM if server does not exit on EOF within eof_grace", %{tmp_dir: tmp_dir} do
    status_file = Path.join(tmp_dir, "term_status.txt")
    # Ignores EOF (sleeps indefinitely); traps TERM to write 143 and exit.
    script = "trap 'echo 143 > \"" <> status_file <> "\"; exit 143' TERM; sleep 30 & wait $!"

    {:ok, state} =
      Stdio.connect(command: ["/bin/sh", "-c", script], eof_grace: 50, term_grace: 500)

    assert :ok = Stdio.close(state)

    wait_until(fn ->
      case File.read(status_file) do
        {:ok, content} -> String.trim(content) == "143"
        _ -> false
      end
    end)
  end
end
