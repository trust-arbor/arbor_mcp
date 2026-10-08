#!/usr/bin/env elixir

# BEAM-local MCP server. This transport is for client and server processes that
# run in the same BEAM VM and communicate with MCP-shaped Elixir terms.

Mix.install(
  [
    {:arbor_mcp, path: Path.expand("../..", __DIR__)}
  ],
  verbose: false
)

Logger.configure(level: :info)

defmodule BeamHelloServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "beam-hello-server", version: "1.0.0"

  @impl true
  def init(_args), do: {:ok, %{messages: []}}

  tool "beam_hello", "Returns a greeting from the local BEAM server" do
    title("BEAM Hello")
    param(:message, :string, default: "Hello from the BEAM.")

    run(fn %{message: message}, state ->
      new_state = %{state | messages: [message | state.messages]}

      {:ok, ToolResult.structured(message, %{messages_seen: length(new_state.messages)}),
       new_state}
    end)
  end

  resource "beam://system/info", "Current BEAM VM information" do
    title("BEAM System Information")
    mime_type("application/json")

    read(fn %{uri: uri}, state ->
      info = %{
        node: inspect(Node.self()),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        process_count: :erlang.system_info(:process_count)
      }

      {:ok, %{uri: uri, text: Jason.encode!(info)}, state}
    end)
  end

  prompt "beam_expert", "Creates a BEAM/OTP discussion prompt" do
    title("BEAM Expert")
    arg(:topic, required: true)

    render(fn %{topic: topic}, state ->
      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{type: "text", text: "Explain this BEAM/OTP topic: #{topic}"}
           }
         ]
       }, state}
    end)
  end
end

if System.get_env("MCP_ENV") != "test" do
  IO.puts("Starting BEAM-local MCP server.")
  IO.puts("Start a client in the same VM with transport: :beam and server: pid.")

  {:ok, _server} = BeamHelloServer.start_link(transport: :beam)
  Process.sleep(:infinity)
end
