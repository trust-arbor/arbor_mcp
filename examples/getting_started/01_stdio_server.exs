#!/usr/bin/env elixir

# STDIO MCP server with a single hello tool.

# This standalone host routes its own default logger to stderr before loading
# the library; preserve normal levels, formatter and filters.
{:ok, %{module: :logger_std_h} = stdio_logger} = :logger.get_handler_config(:default)

stdio_logger_config =
  stdio_logger
  |> Map.drop([:id, :module])
  |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

# Mix.install may restart Logger; carry the same host routing into that boot.
stdio_logger_boot =
  stdio_logger_config
  |> Map.put(:module, :logger_std_h)
  |> Map.update!(:config, &Map.to_list/1)
  |> Map.to_list()

Application.put_env(:logger, :default_handler, stdio_logger_boot)
:ok = :logger.remove_handler(:default)
:ok = :logger.add_handler(:default, :logger_std_h, stdio_logger_config)

Mix.install(
  [
    {:arbor_mcp, path: Path.expand("../..", __DIR__)}
  ],
  verbose: false
)

defmodule StdioHelloServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "stdio-hello-server", version: "1.0.0"

  @impl true
  def init(_args), do: {:ok, %{call_count: 0}}

  tool "hello", "Says hello in a requested language" do
    title("Hello")
    param(:name, :string, required: true)
    param(:language, :string, default: "english")

    run(fn %{name: name, language: language}, state ->
      greeting =
        case language do
          "spanish" -> "Hola, #{name}."
          "french" -> "Bonjour, #{name}."
          "japanese" -> "Konnichiwa, #{name}."
          _ -> "Hello, #{name}."
        end

      new_state = %{state | call_count: state.call_count + 1}
      {:ok, "#{greeting} Greeting ##{new_state.call_count}.", new_state}
    end)
  end
end

if System.get_env("MCP_ENV") != "test" do
  IO.puts(:stderr, "Starting STDIO hello server.")
  {:ok, _server} = StdioHelloServer.start_link(transport: :stdio, stdio_startup_delay: 10)
  Process.sleep(:infinity)
end
