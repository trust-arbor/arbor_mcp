defmodule Arbor.MCP.StdioLauncher do
  @moduledoc """
  Launcher module for STDIO servers that handles Mix.install output.

  This module provides a clean way to start STDIO servers that need
  to use Mix.install by handling the startup output problem.

  ## Important Note

  While this module minimizes output contamination, Mix.install may still
  produce some stdout output during dependency resolution that cannot be
  completely suppressed. Those bytes precede the protocol stream and a peer
  may reject them.

  For production use, consider using pre-compiled releases instead of Mix.install
  to eliminate all startup output.

  ## Usage

  Instead of using Mix.install directly in your script, use:

      #!/usr/bin/env elixir

      Arbor.MCP.StdioLauncher.start(MyServer, [
        {:arbor_mcp, "~> 2.0"},
        {:jason, "~> 1.4"}
      ])

  This will:
  1. Install dependencies with minimal output
  2. Preserve the host's logger configuration
  3. Start your server with STDIO transport and a 200 ms startup delay

  Configure all host log handlers to stderr or another non-protocol sink before
  calling this function. For releases, configure `:logger` `:default_handler`
  with `config: [type: :standard_error]` before application startup. This launcher
  does not reconfigure host logging or set stdio Application flags.
  `Mix.install/2` can still print dependency/compiler output to stdout; use a
  compiled release when a clean protocol stream is required from process boot.
  """

  @doc """
  Starts a STDIO server with proper dependency installation.

  ## Options

  * `:deps` - List of dependencies for Mix.install (required)
  * `:mix_install_opts` - Options to pass to Mix.install
  * `:server_opts` - Options to pass to server start_link
  """
  def start(server_module, deps, opts \\ []) do
    # Note: We can't redirect stdout as that's needed for JSON-RPC
    # Mix.install may print startup output; the host chooses how to deploy it.

    # Install dependencies with minimal output
    if function_exported?(Mix, :install, 2) do
      mix_opts = Keyword.get(opts, :mix_install_opts, [])
      Mix.install(deps, Keyword.put(mix_opts, :verbose, false))
    else
      raise "Mix.install/2 is not available. This module is intended for use in Elixir scripts."
    end

    # Start the server
    server_opts = Keyword.get(opts, :server_opts, [])

    server_opts =
      server_opts
      |> Keyword.put(:transport, :stdio)
      |> Keyword.put_new(:stdio_startup_delay, 200)

    case server_module.start_link(server_opts) do
      {:ok, pid} ->
        # Keep the process running
        Process.sleep(:infinity)
        {:ok, pid}

      error ->
        IO.puts(:stderr, "Failed to start server: #{inspect(error)}")
        System.halt(1)
    end
  end
end
