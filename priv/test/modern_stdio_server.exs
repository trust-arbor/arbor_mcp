Application.put_env(:arbor_mcp, :stdio_mode, true)
Application.put_env(:arbor_mcp, :stdio_startup_delay, 0)
Logger.configure(level: :emergency)

{:ok, _supervisor} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: Arbor.MCP.DynamicSupervisor)

{:ok, _task_store} = Arbor.MCP.Tasks.Store.ETS.start_link()
{:ok, _subscriptions} = Arbor.MCP.Server.Subscriptions.start_link()

defmodule Arbor.MCP.Test.ModernStdioServer do
  use Arbor.MCP.Server.Handler, tasks: :store
  use Arbor.MCP.Server.DSL, name: "modern-stdio-server", version: "1.0.0"

  alias Arbor.MCP.Server.Context

  tool "echo", "Echo text" do
    param(:text, :string, required: true)

    run(fn %{"text" => text}, state ->
      {:ok, %{content: [%{type: "text", text: text}]}, state}
    end)
  end

  tool "onboard", "Collect a display name through MRTR" do
    run(fn _arguments, state ->
      case Context.input_responses() do
        nil ->
          input_requests = %{
            "profile" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "Choose a stdio display name",
                "requestedSchema" => %{"type" => "object"}
              }
            }
          }

          {:ok, ToolResult.input_required(input_requests, %{"transport" => "stdio"}), state}

        %{"profile" => %{"content" => %{"name" => name}}} ->
          request_state = Context.request_state()
          {:ok, ToolResult.text("#{name}:#{request_state["transport"]}"), state}
      end
    end)
  end

  tool "publish_resource_update", "Publish a resource subscription event" do
    param(:uri, :string, required: true)

    run(fn %{"uri" => uri}, state ->
      Arbor.MCP.Server.notify_resource_update(self(), uri)
      {:ok, ToolResult.text("published"), state}
    end)
  end

  tool "publish_tools_changed", "Publish a tools list-changed event" do
    run(fn _arguments, state ->
      Arbor.MCP.Server.notify_tools_changed(self())
      {:ok, ToolResult.text("published"), state}
    end)
  end

  tool "complete_task", "Complete the fixed stdio task" do
    run(fn _arguments, state ->
      {:ok, _task} =
        Arbor.MCP.Tasks.complete(
          "stdio-task",
          %{"content" => [%{"type" => "text", "text" => "stdio task complete"}]}
        )

      {:ok, ToolResult.text("completed"), state}
    end)
  end
end

{:ok, server} =
  Arbor.MCP.Test.ModernStdioServer.start_link(
    transport: :stdio,
    protocol_mode: :modern_only,
    mrtr: true,
    request_state: [
      active_key_id: "stdio-test",
      keys: %{"stdio-test" => :binary.copy(<<73>>, 32)}
    ]
  )

{:ok, task_service} = Arbor.MCP.Server.Runtime.service(server, :tasks)

{:ok, _task} =
  Arbor.MCP.Tasks.create(
    "stdio_task",
    %{},
    id: "stdio-task",
    owner: %{principal_id: nil, tenant_id: nil, audience: "stdio"},
    service: task_service,
    notify: false
  )

# StdioServer stops normally when the parent closes stdin. A linked process does
# not terminate on a normal exit, so sleeping forever here leaked one BEAM VM
# per client/test run. Monitor the server explicitly and let the script finish
# as soon as the transport closes.
server_ref = Process.monitor(server)

receive do
  {:DOWN, ^server_ref, :process, ^server, _reason} -> :ok
end
