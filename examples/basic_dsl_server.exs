#!/usr/bin/env elixir

# Basic MCP server using the modern Arbor.MCP Handler + DSL API.

Mix.install([
  {:arbor_mcp, path: Path.expand("..", __DIR__)}
])

defmodule BasicServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "basic-server", version: "1.0.0"

  tool "greet", "Greets a person by name" do
    title("Greet")
    param(:name, :string, required: true, description: "Name of the person to greet")

    # Plain strings are normalized to text tool results
    run(fn %{name: name}, state ->
      {:ok, "Hello, #{name}. Welcome to Arbor.MCP.", state}
    end)
  end

  resource "info://about", "Information about this MCP server" do
    title("About This Server")
    mime_type("text/plain")

    read(fn %{uri: uri}, state ->
      {:ok,
       %{
         uri: uri,
         text: """
         Basic MCP Server Example

         This server demonstrates a tool, resource, and prompt using the
         modern Arbor.MCP server DSL.
         """
       }, state}
    end)
  end

  prompt "motivate", "Creates a short motivational prompt" do
    title("Motivational Message")
    arg(:topic, description: "Topic for motivation")

    render(fn args, state ->
      topic = Map.get(args, :topic, "your goals")

      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{type: "text", text: "Give me one practical encouragement about #{topic}."}
           }
         ]
       }, state}
    end)
  end
end

defmodule BasicServerRunner do
  def run do
    IO.puts("Starting Basic MCP Server on stdio.")
    IO.puts("Available tool: greet")
    IO.puts("Available resource: info://about")
    IO.puts("Available prompt: motivate")

    {:ok, _server} = BasicServer.start_link(transport: :stdio)
    Process.sleep(:infinity)
  end
end

if System.get_env("MCP_ENV") != "test" do
  BasicServerRunner.run()
end
