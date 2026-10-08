defmodule Arbor.MCP.StdioStdoutHygieneTest do
  @moduledoc """
  A stdio server's protocol stream is stdout, and the `:arbor_mcp` application
  boots before the stdio transport can suppress logging. Nothing Arbor.MCP starts
  at boot may write to stdout under a default logger configuration.

  Runs in a fresh VM with the default logger (info level, stdout handler) and
  no `:stdio_mode` configuration, which is the release case the docs warn
  about, and asserts that starting the application's supervision tree leaves
  stdout empty.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  test "booting the application under the default logger writes nothing to stdout" do
    dir =
      Path.join(System.tmp_dir!(), "ex-mcp-stdout-hygiene-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    script = Path.join(dir, "boot.exs")

    File.write!(script, """
    # The release case: default logger, info level, stdout handler, and no
    # stdio_mode configured before boot.
    Logger.configure(level: :info)
    false = Application.get_env(:arbor_mcp, :stdio_mode, false)

    # Start the application's own children, as the application would, without
    # dragging in every test-only application on the code path.
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:plug)
    {:ok, _pid} = Arbor.MCP.Application.start(:normal, [])

    # Let any asynchronous boot logging flush.
    :ok = :logger.update_primary_config(%{})
    Process.sleep(200)
    """)

    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    stderr_path = Path.join(dir, "stderr")

    {stdout, code} =
      System.cmd(
        "sh",
        ["-c", ~s(exec "$@" 2> "$HYGIENE_STDERR"), "hygiene", System.find_executable("elixir")] ++
          paths ++ [script],
        env: [{"MIX_ENV", "test"}, {"HYGIENE_STDERR", stderr_path}]
      )

    stderr = File.read!(stderr_path)
    assert code == 0, "exit #{code}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
    assert stdout == "", "stdout must stay empty during boot, got:\n#{stdout}"
  end
end
