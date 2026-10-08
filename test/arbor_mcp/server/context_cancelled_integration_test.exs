defmodule Arbor.MCP.Server.ContextCancelledIntegrationTest do
  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer

  defmodule ObservingHandler do
    @behaviour Handler

    def init(args) do
      {:ok, %{test_pid: Keyword.fetch!(args, :test_pid)}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: "cancel-observe-server",
         version: "1.0.0",
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "slow_import", description: "Checks Context.cancelled? between steps"}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("slow_import", _args, state) do
      request_id =
        case Context.current() do
          %{request_id: id} -> id
          _other -> nil
        end

      send(state.test_pid, {:handler_started, request_id})

      observed =
        Enum.reduce_while(1..80, false, fn _i, _acc ->
          if Context.cancelled?() do
            {:halt, true}
          else
            Process.sleep(25)
            {:cont, false}
          end
        end)

      send(state.test_pid, {:observed_cancel, observed})

      if observed do
        {:error, "Import cancelled", state}
      else
        {:ok, %{content: [%{type: "text", text: "Import finished"}]}, state}
      end
    end

    def handle_call_tool(name, _args, state) do
      {:error, "Unknown tool: #{name}", state}
    end

    def terminate(_reason, _state), do: :ok
  end

  test "handler observes Context.cancelled? before returning" do
    {:ok, server} =
      HandlerServer.start_link(
        transport: :test,
        handler: ObservingHandler,
        handler_args: [test_pid: self()]
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

    task =
      Task.async(fn ->
        Client.call_tool(client, "slow_import", %{})
      end)

    assert_receive {:handler_started, request_id}, 2_000
    assert request_id

    wait_until(fn -> request_id in Client.get_pending_requests(client) end, timeout: 5_000)

    :ok = Client.send_cancelled(client, request_id, "User cancelled")

    assert_receive {:observed_cancel, true}, 3_000

    result = Task.await(task, 5_000)
    assert match?({:error, _}, result)

    if Process.alive?(client), do: GenServer.stop(client)
    if Process.alive?(server), do: GenServer.stop(server)
  end
end
