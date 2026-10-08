defmodule Arbor.MCP.StdioHostLoggingTest do
  use ExUnit.Case, async: false

  test "application startup preserves every host logger surface even with the legacy flag" do
    {stdout, _stderr, 0} =
      child(~S"""
      defmodule HostCapture do
        def adding_handler(config), do: {:ok, config}
        def log(event, config), do: send(config.owner, {:host_log, event})
      end

      Logger.configure(level: :info)
      Application.put_env(:arbor_mcp, :stdio_mode, true)
      :ok = :logger.add_primary_filter(:host_filter, {fn event, _ -> event end, :host_state})
      :ok = :logger.add_handler(:host_capture, HostCapture, %{level: :all, owner: self()})
      before = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
        Application.get_env(:logger, :level), Application.get_env(:arbor_mcp, :stdio_mode)}
      {:ok, _} = Application.ensure_all_started(:jason)
      {:ok, _} = Application.ensure_all_started(:telemetry)
      {:ok, _} = Application.ensure_all_started(:plug)
      {:ok, root} = Arbor.MCP.Application.start(:normal, [])
      after_start = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
        Application.get_env(:logger, :level), Application.get_env(:arbor_mcp, :stdio_mode)}
      true = before == after_start
      :logger.log(:info, "host logging still enabled")
      receive do {:host_log, %{level: :info}} -> :ok after 1_000 -> exit(:host_log_suppressed) end
      :ok = Supervisor.stop(root)
      IO.puts("host-config-preserved")
      """)

    assert stdout =~ "host-config-preserved"
  end

  test "legacy configure remains exported and explicitly applies the old suppression policy" do
    {stdout, _stderr, 0} =
      child(~S"""
      true = Code.ensure_loaded?(Arbor.MCP.Internal.StdioLoggerConfig)
      true = function_exported?(Arbor.MCP.Internal.StdioLoggerConfig, :configure, 0)
      :ok = Arbor.MCP.Internal.StdioLoggerConfig.configure()
      true = Application.get_env(:arbor_mcp, :stdio_mode)
      :emergency = Logger.level()
      :emergency = Application.get_env(:logger, :level)
      :emergency = :logger.get_primary_config().level
      IO.puts("legacy-policy-retained")
      """)

    assert stdout == "legacy-policy-retained\n"
  end

  test "launcher preserves host configuration and forwards its delay default or caller override" do
    for {options, expected} <- [{[], 200}, {[stdio_startup_delay: 17], 17}] do
      script = """
      Mix.start()
      Logger.configure(level: :info)
      Application.put_env(:arbor_mcp, :stdio_mode, false)
      Application.put_env(:arbor_mcp, :stdio_startup_delay, 450)
      before = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
        Application.get_env(:logger, :level), Application.get_env(:arbor_mcp, :stdio_mode),
        Application.get_env(:arbor_mcp, :stdio_startup_delay)}
      Process.put(:host_config, before)
      defmodule LauncherHostProbe do
        def start_link(opts) do
          after_install = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
            Application.get_env(:logger, :level), Application.get_env(:arbor_mcp, :stdio_mode),
            Application.get_env(:arbor_mcp, :stdio_startup_delay)}
          true = after_install == Process.get(:host_config)
          #{expected} = opts[:stdio_startup_delay]
          :stdio = opts[:transport]
          IO.puts("launcher-config-preserved")
          System.halt(0)
        end
      end
      Arbor.MCP.StdioLauncher.start(LauncherHostProbe, [],
        server_opts: #{inspect(options)}, mix_install_opts: [start_applications: false])
      """

      {stdout, _stderr, 0} = child(script)
      assert stdout =~ "launcher-config-preserved"
    end
  end

  test "standalone interop host keeps info diagnostics on stderr and protocol frames on stdout" do
    input =
      Enum.map_join(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "logging-host", "version" => "1"}
            }
          },
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping", "params" => %{}}
        ],
        "",
        &(Jason.encode!(&1) <> "\n")
      )

    {stdout, stderr, 0} =
      child(
        ~S"""
        Mix.start()
        Code.require_file("mix.exs")
        Mix.Task.run("app.config", ["--no-compile", "--no-deps-check"])
        host_level = Application.get_env(:logger, :level, Logger.level())
        Mix.Tasks.InteropServer.run(["--no-compile"])
        ^host_level = Logger.level()
        require Logger
        Logger.info("host-info-after-stdio")
        Logger.flush()
        """,
        input
      )

    frames = stdout |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(frames, & &1["id"]) == [1, 2]
    assert Enum.all?(frames, &Map.has_key?(&1, "result"))
    assert stderr =~ "host-info-after-stdio"
    refute stdout =~ "host-info-after-stdio"
  end

  defp child(script, input \\ "") do
    directory =
      Path.join(System.tmp_dir!(), "arbor-stdio-host-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    script_path = Path.join(directory, "host.exs")
    input_path = Path.join(directory, "input")
    error_path = Path.join(directory, "stderr")
    File.write!(script_path, script)
    File.write!(input_path, input)
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    {stdout, code} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(exec "$@" < "$HOST_INPUT" 2> "$HOST_STDERR"),
          "host",
          System.find_executable("elixir")
        ] ++ paths ++ [script_path],
        env: [
          {"MIX_ENV", "test"},
          {"HOST_INPUT", input_path},
          {"HOST_STDERR", error_path},
          {"MIX_INSTALL_DIR", Path.join(directory, "mix-install")}
        ]
      )

    stderr = File.read!(error_path)
    assert code == 0, "host exit #{code}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
    {stdout, stderr, code}
  end
end
