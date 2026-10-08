defmodule Mix.Tasks.Test.Cleanup do
  @moduledoc """
  Cleans up stray processes and ports left over from crashed tests.

  This task will:
  - Stop any Cowboy listeners from tests
  - Kill registered test processes
  - Free up ports commonly used by tests
  - Clean up stray beam.smp processes

  ## Usage

      mix test.cleanup

  ## Options

    * `--verbose` - Show detailed output of what's being cleaned up
    * `--dry-run` - Show what would be cleaned up without actually doing it

  """
  use Mix.Task

  @shortdoc "Clean up stray test processes and ports"

  @test_ports [8080, 8081, 8082, 8083, 8084, 8085, 9000, 9001, 9002]
  @registered_names [
    :test_server,
    :test_http_server,
    :test_sse_server,
    Arbor.MCP.TestServer,
    Arbor.MCP.TestHTTPServer,
    Arbor.MCP.TestSSEServer,
    # Don't kill the main application processes - they should be managed by Application.stop/1
    # Arbor.MCP.Supervisor,
    # Arbor.MCP.Registry,
    Arbor.MCP.Testing.MockServer
  ]
  @cowboy_listeners [
    :test_http_server,
    :test_sse_server,
    :test_http_listener,
    :test_sse_listener,
    Arbor.MCP.TestHTTPServer.HTTP,
    Arbor.MCP.TestSSEServer.HTTP
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [verbose: :boolean, dry_run: :boolean])
    verbose = Keyword.get(opts, :verbose, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    Mix.shell().info("🧹 Cleaning up test processes...")

    if dry_run do
      Mix.shell().info("🔍 DRY RUN MODE - No processes will be killed")
    end

    # Ensure we have the necessary applications started
    unless dry_run do
      Application.ensure_all_started(:ranch)
      Application.ensure_all_started(:cowboy)
    end

    # Run cleanup steps
    results = [
      stop_cowboy_listeners(verbose, dry_run),
      kill_registered_processes(verbose, dry_run),
      close_test_ports(verbose, dry_run)
    ]

    # Summary
    total_cleaned = Enum.sum(results)

    if total_cleaned > 0 do
      Mix.shell().info("\n✅ Cleaned up #{total_cleaned} processes/ports")
    else
      Mix.shell().info("\n✨ No cleanup needed - all clear!")
    end
  end

  defp stop_cowboy_listeners(verbose, dry_run) do
    if verbose, do: Mix.shell().info("\n📡 Checking Cowboy listeners...")

    cleaned =
      @cowboy_listeners
      |> Enum.reduce(0, fn listener, acc ->
        if dry_run do
          try do
            case :ranch.info(listener) do
              info when is_list(info) ->
                Mix.shell().info("  Would stop listener: #{inspect(listener)}")
                acc + 1
            end
          catch
            _, _ ->
              acc
          end
        else
          case :cowboy.stop_listener(listener) do
            :ok ->
              Mix.shell().info("  ✓ Stopped listener: #{inspect(listener)}")
              acc + 1

            {:error, :not_found} ->
              if verbose, do: Mix.shell().info("  - Listener not found: #{inspect(listener)}")
              acc
          end
        end
      end)

    if cleaned == 0 and verbose do
      Mix.shell().info("  No active listeners found")
    end

    cleaned
  end

  defp kill_registered_processes(verbose, dry_run) do
    if verbose, do: Mix.shell().info("\n🔍 Checking registered processes...")

    # Check predefined names
    cleaned_predefined = kill_processes_by_names(@registered_names, dry_run, false)

    # Check for any process with "test" in its registered name
    test_processes = find_test_processes()
    cleaned_additional = kill_processes_by_names(test_processes, dry_run, true)

    total = cleaned_predefined + cleaned_additional

    if total == 0 and verbose do
      Mix.shell().info("  No registered test processes found")
    end

    total
  end

  defp find_test_processes do
    Process.registered()
    |> Enum.filter(fn name ->
      name_str = Atom.to_string(name)

      (String.contains?(name_str, "test") or String.contains?(name_str, "Test")) and
        name not in @registered_names
    end)
  end

  defp kill_processes_by_names(names, dry_run, is_additional) do
    Enum.reduce(names, 0, fn name, acc ->
      case Process.whereis(name) do
        nil ->
          acc

        pid when is_pid(pid) ->
          kill_or_report_process(name, pid, dry_run, is_additional)
          acc + 1
      end
    end)
  end

  defp kill_or_report_process(name, pid, dry_run, is_additional) do
    prefix = if is_additional, do: "test ", else: ""

    if dry_run do
      Mix.shell().info("  Would kill #{prefix}process: #{inspect(name)} (#{inspect(pid)})")
    else
      Process.exit(pid, :kill)
      Mix.shell().info("  ✓ Killed #{prefix}process: #{inspect(name)} (#{inspect(pid)})")
    end
  end

  defp close_test_ports(verbose, dry_run) do
    if verbose, do: Mix.shell().info("\n🔌 Checking test ports...")

    cleaned =
      @test_ports
      |> Enum.reduce(0, fn port, acc ->
        case find_process_using_port(port) do
          nil ->
            if verbose, do: Mix.shell().info("  - Port #{port} is free")
            acc

          pids ->
            if dry_run do
              Mix.shell().info("  Would kill processes on port #{port}: #{Enum.join(pids, ", ")}")
              acc + length(pids)
            else
              Enum.each(pids, fn pid ->
                kill_system_process(pid)
                Mix.shell().info("  ✓ Killed process using port #{port}: PID #{pid}")
              end)

              acc + length(pids)
            end
        end
      end)

    if cleaned == 0 and verbose do
      Mix.shell().info("  All test ports are free")
    end

    cleaned
  end

  defp find_process_using_port(port) do
    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {"", 0} ->
        nil

      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  defp kill_system_process(pid_str) do
    System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
  end
end
