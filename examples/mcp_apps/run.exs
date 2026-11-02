# Run from the repository root, after npm run build and mix compile.
Code.require_file("server.exs", __DIR__)

# This host owns the stdio stream. Keep application logs off the JSON-RPC pipe.
{:ok, %{module: :logger_std_h} = logger} = :logger.get_handler_config(:default)

config =
  logger |> Map.drop([:id, :module]) |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

:ok = :logger.remove_handler(:default)
:ok = :logger.add_handler(:default, :logger_std_h, config)

opts =
  case Enum.drop_while(System.argv(), &(&1 == "--")) do
    ["--stdio"] ->
      [transport: :stdio]

    ["--http", port] ->
      [
        transport: :http,
        host: "127.0.0.1",
        port: String.to_integer(port),
        allowed_origins: ["http://127.0.0.1:#{port}"]
      ]

    _ ->
      raise "Usage: mix run --no-compile examples/mcp_apps/run.exs -- --stdio | --http 8080"
  end

{:ok, server} =
  Arbor.MCP.Server.start_link(
    Keyword.merge(opts, handler: Arbor.MCP.Examples.McpApps, execution: :stateful)
  )

ref = Process.monitor(server)

receive do
  {:DOWN, ^ref, :process, ^server, reason} when reason in [:normal, :shutdown] -> :ok
  {:DOWN, ^ref, :process, ^server, reason} -> raise "Example server stopped: #{inspect(reason)}"
end
