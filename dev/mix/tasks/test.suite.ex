defmodule Mix.Tasks.Test.Suite do
  @moduledoc """
  Run specific test suites for Arbor.MCP.

  ## Usage

      mix test.suite <suite_name> [options]

  ## Available Suites

    * `unit` - Fast unit tests only (default)
    * `compliance` - MCP specification compliance tests
    * `integration` - Integration tests with real transports
    * `transport` - Transport-specific tests
    * `security` - Security-related tests
    * `performance` - Performance and stress tests
    * `all` - All tests including slow ones
    * `ci` - Tests suitable for CI (excludes manual/flaky tests)

  ## Examples

      # Run only unit tests (fast)
      mix test.suite unit

      # Run compliance tests
      mix test.suite compliance

      # Run integration tests with coverage
      mix test.suite integration --cover

      # Run all tests
      mix test.suite all

  ## Options

  All standard `mix test` options are supported, including:
    * `--cover` - Run with coverage
    * `--trace` - Run with detailed trace
    * `--max-cases` - Set max concurrent test cases
  """
  use Mix.Task

  @shortdoc "Run specific test suites"

  @suites %{
    "unit" => [
      exclude: [:integration, :external, :slow, :performance, :compliance, :skip, :wip],
      include: [:unit]
    ],
    "compliance" => [
      only: [:compliance]
    ],
    "integration" => [
      include: [:integration, :requires_http, :requires_stdio, :requires_beam],
      exclude: [:skip, :wip]
    ],
    "transport" => [
      include: [:transport, :stdio, :http, :beam],
      exclude: [:skip, :wip]
    ],
    "security" => [
      include: [:security],
      exclude: [:skip, :wip]
    ],
    "performance" => [
      include: [:performance, :stress, :slow],
      exclude: [:skip, :wip]
    ],
    "all" => [
      include: [:integration, :external, :slow, :performance, :compliance],
      exclude: [:skip, :wip, :manual_only]
    ],
    "ci" => [
      include: [:integration, :compliance],
      exclude: [:skip, :wip, :manual_only, :flaky, :external]
    ]
  }

  @impl Mix.Task
  def run(args) do
    {suite_name, mix_args} = parse_args(args)

    suite_config = @suites[suite_name] || @suites["unit"]

    # Build mix test arguments
    test_args = build_test_args(suite_config, mix_args)

    # Print what we're running
    IO.puts("\n🧪 Running #{suite_name} test suite...")
    IO.puts("   Command: MIX_ENV=test mix test #{Enum.join(test_args, " ")}\n")

    # Run mix test with the appropriate arguments
    # Use System.cmd to avoid dialyzer warnings about Mix.Task.run/2
    {_output, exit_code} =
      System.cmd("mix", ["test" | test_args], env: [{"MIX_ENV", "test"}], into: IO.stream())

    if exit_code != 0, do: System.halt(exit_code)
  end

  defp parse_args([]), do: {"unit", []}
  defp parse_args([suite | rest]) when is_map_key(@suites, suite), do: {suite, rest}
  defp parse_args(args), do: {"unit", args}

  defp build_test_args(suite_config, additional_args) do
    exclude_args =
      suite_config
      |> Keyword.get(:exclude, [])
      |> Enum.flat_map(fn tag -> ["--exclude", to_string(tag)] end)

    include_args =
      suite_config
      |> Keyword.get(:include, [])
      |> Enum.flat_map(fn tag -> ["--include", to_string(tag)] end)

    only_args =
      suite_config
      |> Keyword.get(:only, [])
      |> Enum.flat_map(fn tag -> ["--only", to_string(tag)] end)

    exclude_args ++ include_args ++ only_args ++ additional_args
  end
end
