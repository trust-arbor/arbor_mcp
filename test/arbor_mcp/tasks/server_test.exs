defmodule Arbor.MCP.Tasks.ServerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Protocol.RequestProcessor
  alias Arbor.MCP.Server.Dispatch
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Store.ETS

  @store __MODULE__.Store
  @identity [principal_id: "alice", tenant_id: "acme", endpoint: "https://mcp.example"]
  @owner %{principal_id: "alice", tenant_id: "acme", audience: "https://mcp.example"}

  defmodule StoredHandler do
    alias Arbor.MCP.Tasks.Server, as: TaskServer
    alias Arbor.MCP.Tasks.ServerTest.Store

    use Arbor.MCP.Server.Handler,
      tasks: :store,
      task_store_opts: [server: Store]

    @impl true
    def handle_call_tool("background", arguments, state) do
      TaskServer.create("background", arguments, state, __task_store_options__())
    end
  end

  defmodule NoTasksHandler do
    use Arbor.MCP.Server.Handler
  end

  setup do
    start_supervised!({ETS, name: @store})
    :ok
  end

  test "opt-in handler persists before create result and serves the modern lifecycle" do
    create = modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}})

    assert {:response, %{"result" => created}, state} =
             Dispatch.dispatch(create, StoredHandler, %{}, @identity)

    task_id = created["taskId"]
    assert created["resultType"] == "task"

    assert {:ok, %{"taskId" => ^task_id}} =
             Tasks.get(task_id, store: ETS, server: @store, owner: @owner)

    get = modern_request(2, "tasks/get", %{"taskId" => task_id})

    assert {:response, %{"result" => current}, state} =
             Dispatch.dispatch(get, StoredHandler, state, @identity)

    assert current["resultType"] == "complete"
    assert current["status"] == "working"

    assert {:ok, _waiting} =
             Tasks.require_input(
               task_id,
               %{"approval" => %{"method" => "elicitation/create"}},
               store: ETS,
               server: @store,
               owner: @owner
             )

    update =
      modern_request(3, "tasks/update", %{
        "taskId" => task_id,
        "inputResponses" => %{"approval" => %{"action" => "accept"}}
      })

    assert {:response, %{"result" => %{"resultType" => "complete"}}, state} =
             Dispatch.dispatch(update, StoredHandler, state, @identity)

    assert {:ok, %{"approval" => %{"action" => "accept"}}} =
             Tasks.take_input_responses(task_id,
               store: ETS,
               server: @store,
               owner: @owner
             )

    cancel = modern_request(4, "tasks/cancel", %{"taskId" => task_id})

    assert {:response, %{"result" => %{"resultType" => "complete"}}, _state} =
             Dispatch.dispatch(cancel, StoredHandler, state, @identity)

    assert {:ok, true} =
             Tasks.cancellation_requested?(task_id,
               store: ETS,
               server: @store,
               owner: @owner
             )
  end

  test "does not create tasks for undeclared modern or legacy requests" do
    undeclared =
      modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}}, %{})

    assert {:response, %{"error" => error}, _state} =
             Dispatch.dispatch(undeclared, StoredHandler, %{}, @identity)

    assert error["code"] == -32021

    legacy = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "background", "arguments" => %{}}
    }

    assert {:response, %{"error" => legacy_error}, _state} =
             Dispatch.dispatch(legacy, StoredHandler, %{}, @identity)

    assert legacy_error["code"] != -32021
  end

  test "advertises the extension only for an explicitly task-enabled handler" do
    discover = modern_request(1, "server/discover", %{}, %{})

    assert {:response, %{"result" => stored}, _state} =
             Dispatch.dispatch(discover, StoredHandler, %{}, protocol_mode: :modern_only)

    assert get_in(stored, ["capabilities", "extensions", "io.modelcontextprotocol/tasks"]) ==
             %{}

    assert {:response, %{"result" => plain}, _state} =
             Dispatch.dispatch(discover, NoTasksHandler, %{}, protocol_mode: :modern_only)

    refute get_in(plain, ["capabilities", "extensions", "io.modelcontextprotocol/tasks"])

    stored_http =
      discover
      |> MessageProcessor.new()
      |> MessageProcessor.process(%{handler: StoredHandler, protocol_mode: :modern_only})

    assert get_in(stored_http.response, [
             "result",
             "capabilities",
             "extensions",
             "io.modelcontextprotocol/tasks"
           ]) ==
             %{}

    plain_http =
      discover
      |> MessageProcessor.new()
      |> MessageProcessor.process(%{handler: NoTasksHandler, protocol_mode: :modern_only})

    refute get_in(plain_http.response, [
             "result",
             "capabilities",
             "extensions",
             "io.modelcontextprotocol/tasks"
           ])
  end

  test "uses request identity for every handler-backed task operation" do
    create = modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}})

    assert {:response, %{"result" => created}, state} =
             Dispatch.dispatch(create, StoredHandler, %{}, @identity)

    get = modern_request(2, "tasks/get", %{"taskId" => created["taskId"]})

    assert {:response, %{"error" => error}, _state} =
             Dispatch.dispatch(get, StoredHandler, state,
               principal_id: "bob",
               tenant_id: "acme",
               endpoint: "https://mcp.example"
             )

    assert error["message"] =~ "not found or not authorized"
  end

  test "retains scoped ownership through the request-processor path" do
    state = %{
      __module__: StoredHandler,
      principal_id: "alice",
      tenant_id: "acme",
      endpoint: "https://mcp.example"
    }

    create = modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}})

    assert {:response, %{"result" => created}, state} =
             RequestProcessor.process(create, state)

    get = modern_request(2, "tasks/get", %{"taskId" => created["taskId"]})

    assert {:response, %{"result" => current}, _state} =
             RequestProcessor.process(get, state)

    assert current["taskId"] == created["taskId"]
  end

  test "retains tasks across independent HTTP handler invocations" do
    opts = %{
      handler: StoredHandler,
      protocol_mode: :modern_only,
      principal_id: "alice",
      tenant_id: "acme",
      endpoint: "https://mcp.example"
    }

    create = modern_request(1, "tools/call", %{"name" => "background", "arguments" => %{}})
    create_conn = create |> MessageProcessor.new() |> MessageProcessor.process(opts)
    task_id = create_conn.response["result"]["taskId"]

    get = modern_request(2, "tasks/get", %{"taskId" => task_id})
    get_conn = get |> MessageProcessor.new() |> MessageProcessor.process(opts)

    assert get_conn.response["result"]["taskId"] == task_id
    assert get_conn.response["result"]["status"] == "working"
  end

  defp modern_request(id, method, params, capabilities \\ task_capabilities()) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => capabilities
    }

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp task_capabilities do
    %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}
  end
end
