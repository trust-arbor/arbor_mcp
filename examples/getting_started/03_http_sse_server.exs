#!/usr/bin/env elixir

# HTTP MCP server with SSE enabled.

Mix.install(
  [
    {:arbor_mcp, path: Path.expand("../..", __DIR__)},
    {:plug_cowboy, "~> 2.7"},
    {:ranch, "== 1.8.1"}
  ],
  verbose: false
)

Logger.configure(level: :info)

defmodule HttpSseHelloServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "http-sse-hello-server", version: "1.0.0"

  prompt "hello_generator", "Generates a personalized greeting prompt" do
    title("Hello Generator")
    arg(:recipient, required: true)
    arg(:style)

    render(fn %{recipient: recipient} = args, state ->
      style = Map.get(args, :style, "friendly")

      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{type: "text", text: "Write a #{style} greeting for #{recipient}."}
           }
         ]
       }, state}
    end)
  end

  resource "events://greetings", "Example subscribable event resource" do
    title("Greeting Events")
    mime_type("text/event-stream")

    read(fn %{uri: uri}, state ->
      {:ok,
       %{
         uri: uri,
         text:
           "SSE is enabled for this HTTP server. Server-initiated events can use this channel."
       }, state}
    end)
  end
end

if System.get_env("MCP_ENV") != "test" do
  port = String.to_integer(System.get_env("HTTP_SSE_PORT", "8081"))

  IO.puts("Starting HTTP+SSE MCP server on port #{port}.")
  IO.puts("Prompt: hello_generator")
  IO.puts("Resource: events://greetings")

  {:ok, _server} =
    HttpSseHelloServer.start_link(
      transport: :http,
      port: port,
      legacy_http_sse: true,
      name: :http_sse_hello_server
    )

  Process.sleep(:infinity)
end
