#!/usr/bin/env elixir

# Basic Arbor.MCP client example. It starts an in-process BEAM server so the
# example is self-contained.

Mix.install([
  {:arbor_mcp, path: Path.expand("..", __DIR__)}
])

defmodule BasicClientServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "basic-client-server", version: "1.0.0"

  tool "echo", "Echoes the provided message" do
    title("Echo")
    param(:message, :string, required: true)

    run(fn %{message: message}, state ->
      {:ok, "Echo: #{message}", state}
    end)
  end

  resource "demo://readme", "Demo resource" do
    title("Demo Readme")
    mime_type("text/plain")

    read(fn %{uri: uri}, state ->
      {:ok, %{uri: uri, text: "This resource came from a BEAM-local MCP server."}, state}
    end)
  end
end

{:ok, server} = BasicClientServer.start_link(transport: :beam)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: server)

field = fn map, key -> Map.get(map, Atom.to_string(key)) || Map.get(map, key) end

{:ok, %{"tools" => tools}} = Arbor.MCP.Client.list_tools(client, format: :map)
IO.puts("Tools: #{Enum.map_join(tools, ", ", &field.(&1, :name))}")

{:ok, result} =
  Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "Hello from Arbor.MCP."},
    format: :map
  )

[%{"text" => tool_text} | _] = result["content"]
IO.puts("Tool result: #{tool_text}")

{:ok, %{"resources" => resources}} = Arbor.MCP.Client.list_resources(client, format: :map)
IO.puts("Resources: #{Enum.map_join(resources, ", ", &field.(&1, :uri))}")

{:ok, %{"contents" => [resource]}} =
  Arbor.MCP.Client.read_resource(client, "demo://readme", format: :map)

IO.puts("Resource text: #{field.(resource, :text)}")

Arbor.MCP.Client.stop(client)
GenServer.stop(server)
