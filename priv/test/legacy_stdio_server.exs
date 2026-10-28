# A stdio server pinned to the legacy era, as a `protocol_mode: :legacy_only`
# rollback deploys it. Run with `mix run --no-compile --no-start`.
Application.put_env(:arbor_mcp, :stdio_mode, true)
Application.put_env(:arbor_mcp, :stdio_startup_delay, 0)
Logger.configure(level: :emergency)

{:ok, _supervisor} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: Arbor.MCP.DynamicSupervisor)

defmodule Arbor.MCP.Test.LegacyStdioServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "legacy-stdio-server", version: "1.0.0"

  tool "echo", "Echo text" do
    param(:text, :string, required: true)

    run(fn %{"text" => text}, state ->
      {:ok, %{content: [%{type: "text", text: text}]}, state}
    end)
  end
end

{:ok, server} =
  Arbor.MCP.Test.LegacyStdioServer.start_link(transport: :stdio, protocol_mode: :legacy_only)

# Finish with the transport, when the client closes stdin, rather than leave
# a BEAM VM behind.
server_ref = Process.monitor(server)

receive do
  {:DOWN, ^server_ref, :process, ^server, _reason} -> :ok
end
