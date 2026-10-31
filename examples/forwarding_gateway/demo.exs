Code.require_file("gateway.exs", __DIR__)
Code.require_file("support.exs", __DIR__)

alias Arbor.MCP.Client
alias Arbor.MCP.Examples.ForwardingGateway.Demo

{:ok, demo} = Demo.start()

try do
  {:ok, client} = Demo.connect(demo, "alice")
  {:ok, tools} = Client.list_tools(client, format: :map)
  IO.puts("Gateway tools: " <> Enum.map_join(tools["tools"], ", ", & &1["name"]))
  {:ok, result} = Client.call_tool(client, "beta__ask", %{}, format: :map, progress_token: "demo")
  IO.puts(Jason.encode!(result["structuredContent"]))
after
  Demo.stop(demo)
end
