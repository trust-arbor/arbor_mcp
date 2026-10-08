defmodule Arbor.MCP.TestSupport do
  @moduledoc """
  Test support utilities for Arbor.MCP tests.

  Provides helpers for:
  - Safe network resource cleanup (ports, listeners)
  - Isolated test supervision
  - Test process management following OTP patterns
  """

  require Logger

  @doc """
  Safely cleanup network resources that might block new tests.

  This focuses only on network resources (ports, listeners) and avoids
  aggressive process killing that violates OTP supervision patterns.
  """
  def safe_cleanup_network_resources do
    cleanup_cowboy_listeners()
    cleanup_test_ports()
  end

  @doc """
  Start an isolated MCP server for testing with proper supervision.

  This creates a supervised server instance that will be automatically
  cleaned up when the test exits, following ExUnit best practices.
  """
  def start_isolated_mcp_server(opts \\ []) do
    server_opts =
      Keyword.merge(
        [
          name: :"test_server_#{System.unique_integer([:positive])}"
        ],
        opts
      )

    ExUnit.Callbacks.start_supervised!({Arbor.MCP.Server, server_opts})
  end

  @doc """
  Start an isolated MCP client for testing with proper supervision.
  """
  def start_isolated_mcp_client(opts \\ []) do
    client_opts =
      Keyword.merge(
        [
          name: :"test_client_#{System.unique_integer([:positive])}"
        ],
        opts
      )

    ExUnit.Callbacks.start_supervised!({Arbor.MCP.Client, client_opts})
  end

  @doc """
  Cleanup orphaned processes after test suite completion.

  This is a safety net for truly orphaned processes and should rarely
  be needed if tests use proper supervision.
  """
  def cleanup_orphans do
    Logger.info("Running post-suite orphan cleanup...")

    orphaned_test_processes = find_orphaned_test_processes()

    if length(orphaned_test_processes) > 0 do
      Logger.warning("Found #{length(orphaned_test_processes)} orphaned test processes")

      Enum.each(orphaned_test_processes, fn {name, pid} ->
        if Process.alive?(pid) do
          Logger.info("Cleaning up orphaned process: #{inspect(name)} (#{inspect(pid)})")
          Process.exit(pid, :shutdown)
          Process.sleep(10)
        end
      end)
    else
      Logger.info("No orphaned test processes found")
    end
  end

  # Private functions

  defp cleanup_cowboy_listeners do
    test_listeners = [
      :test_http_server,
      :test_sse_server,
      :test_http_listener,
      :test_sse_listener,
      Arbor.MCP.TestHTTPServer.HTTP,
      Arbor.MCP.TestSSEServer.HTTP
    ]

    Enum.each(test_listeners, fn listener ->
      case :cowboy.stop_listener(listener) do
        :ok ->
          Logger.debug("Stopped listener: #{inspect(listener)}")

        {:error, :not_found} ->
          # Already stopped
          :ok
      end
    end)
  end

  defp cleanup_test_ports do
    test_ports = [8080, 8081, 8082, 8083, 8084, 8085, 9000, 9001, 9002]

    Enum.each(test_ports, fn port ->
      case find_process_using_port(port) do
        nil ->
          # Port is free
          :ok

        pids ->
          Logger.warning("Found processes using test port #{port}: #{inspect(pids)}")
          # Log but don't kill - let them finish gracefully
      end
    end)
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

  defp find_orphaned_test_processes do
    test_process_patterns = [
      "test_server",
      "test_client",
      "test_http",
      "test_sse",
      "Arbor.MCP.Test"
    ]

    Process.registered()
    |> Enum.filter(fn name ->
      name_str = Atom.to_string(name)
      Enum.any?(test_process_patterns, &String.contains?(name_str, &1))
    end)
    |> Enum.map(fn name -> {name, Process.whereis(name)} end)
    |> Enum.filter(fn {_name, pid} -> is_pid(pid) and Process.alive?(pid) end)
  end
end
