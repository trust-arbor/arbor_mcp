defmodule Mix.Tasks.Test.Tags do
  @moduledoc """
  List and describe test tags used in Arbor.MCP.

  ## Usage

      mix test.tags

  This will display all available test tags and their descriptions.
  """
  use Mix.Task

  @shortdoc "List available test tags"

  @tags %{
    # Test categories
    unit: "Fast unit tests with mocked dependencies",
    integration: "Integration tests with real components",
    compliance: "MCP specification compliance tests",
    security: "Security-related tests",
    performance: "Performance benchmarks and stress tests",

    # Test requirements
    requires_http: "Tests requiring HTTP server",
    requires_stdio: "Tests requiring stdio transport",
    requires_beam: "Tests requiring BEAM transport",
    external: "Tests requiring external services",

    # Test characteristics
    slow: "Tests that take significant time",
    stress: "Stress tests with high load",
    flaky: "Tests that may fail intermittently",
    capture_log: "Tests that capture log output",

    # Transport-specific
    transport: "General transport tests",
    stdio: "stdio transport specific tests",
    http: "Streamable HTTP transport tests",
    beam: "BEAM/Erlang process transport tests",

    # Development tags
    wip: "Work in progress tests",
    skip: "Tests to skip",
    manual_only: "Tests requiring manual intervention",

    # Feature-specific
    protocol: "Protocol-level tests",
    batch: "Batch request tests",
    progress: "Progress notification tests",
    cancellation: "Request cancellation tests",
    roots: "Roots functionality tests",
    resources: "Resource management tests",
    tools: "Tools functionality tests",
    prompts: "Prompts functionality tests",
    logging: "Logging functionality tests",
    completion: "Completion functionality tests"
  }

  @impl Mix.Task
  def run(_args) do
    IO.puts("\n📋 Arbor.MCP Test Tags\n")
    IO.puts("Use these tags with mix test:\n")
    IO.puts("  mix test --only <tag>     # Run only tests with this tag")
    IO.puts("  mix test --include <tag>  # Include excluded tests with this tag")
    IO.puts("  mix test --exclude <tag>  # Exclude tests with this tag\n")

    IO.puts("Or use the test.suite task:")
    IO.puts("  mix test.suite compliance  # Run compliance suite")
    IO.puts("  mix test.suite unit       # Run unit tests only\n")

    IO.puts(String.duplicate("─", 80))

    # Group tags by category
    categories = [
      {"Test Categories", [:unit, :integration, :compliance, :security, :performance]},
      {"Test Requirements", [:requires_http, :requires_stdio, :requires_beam, :external]},
      {"Test Characteristics", [:slow, :stress, :flaky, :capture_log]},
      {"Transport Tests", [:transport, :stdio, :http, :beam]},
      {"Feature Tests",
       [
         :protocol,
         :batch,
         :progress,
         :cancellation,
         :roots,
         :resources,
         :tools,
         :prompts,
         :logging,
         :completion
       ]},
      {"Development", [:wip, :skip, :manual_only]}
    ]

    for {category, tags} <- categories do
      IO.puts("\n#{category}:")

      for tag <- tags, desc = @tags[tag] do
        IO.puts("  #{String.pad_trailing(":#{tag}", 20)} - #{desc}")
      end
    end

    IO.puts("\n")
  end
end
