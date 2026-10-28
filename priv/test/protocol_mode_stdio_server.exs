# A stdio server running the protocol mode named by the first argument
# (`legacy_only`, `prefer_legacy`, `prefer_modern` or `modern_only`).
# Run with `mix run --no-compile --no-start`.
Application.put_env(:arbor_mcp, :stdio_mode, true)
Application.put_env(:arbor_mcp, :stdio_startup_delay, 0)
Logger.configure(level: :emergency)

{:ok, _supervisor} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: Arbor.MCP.DynamicSupervisor)

defmodule Arbor.MCP.Test.ProtocolModeStdioServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "protocol-mode-stdio-server", version: "1.0.0"
end

modes = Map.new([:legacy_only, :prefer_legacy, :prefer_modern, :modern_only], &{to_string(&1), &1})

mode =
  case System.argv() do
    [name | _rest] when is_map_key(modes, name) -> Map.fetch!(modes, name)
    other -> raise ArgumentError, "expected a protocol mode, got #{inspect(other)}"
  end

{:ok, server} =
  Arbor.MCP.Test.ProtocolModeStdioServer.start_link(transport: :stdio, protocol_mode: mode)

server_ref = Process.monitor(server)

receive do
  {:DOWN, ^server_ref, :process, ^server, _reason} -> :ok
end
