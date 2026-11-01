defmodule Arbor.MCP.Tasks.ExtensionContractTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.Headers
  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Protocol.RequestProcessor
  alias Arbor.MCP.Server.Dispatch
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Extension
  alias Arbor.MCP.Tasks.Store.ETS
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  @store __MODULE__.Store
  @owner %{principal_id: "alice", tenant_id: "audit", audience: "https://mcp.example"}

  defmodule Handler do
    use Arbor.MCP.Server.Handler,
      tasks: :store,
      task_store_opts: [server: Arbor.MCP.Tasks.ExtensionContractTest.Store]
  end

  defmodule UpdateObserver do
    use Arbor.MCP.Server.Handler, tasks: :store

    @impl true
    def handle_task_update(_id, _responses, state) do
      send(state.observer, :task_update_callback_called)
      {:ok, %{}, state}
    end
  end

  setup do
    store = start_supervised!({ETS, name: @store})
    {:ok, opts: [store: ETS, server: store, owner: @owner, notify: false]}
  end

  test "published nullable ttlMs is accepted in a valid task result" do
    task = %{
      "taskId" => "remote-unlimited",
      "status" => "working",
      "ttlMs" => nil,
      "createdAt" => "2026-10-31T00:00:00Z",
      "lastUpdatedAt" => "2026-10-31T00:00:00Z"
    }

    assert :ok = Extension.validate_task_result(task)
  end

  test "all three task HTTP methods mirror taskId in Mcp-Name" do
    state = %HTTP{protocol_version: "2026-07-28", headers: []}

    actual =
      for method <- ~w(tasks/get tasks/update tasks/cancel) do
        headers =
          RequestHeaders.build(Jason.encode!(request(method, %{"taskId" => "task-audit"})), state)

        {method, Headers.get(headers, "mcp-name")}
      end

    assert actual ==
             for(method <- ~w(tasks/get tasks/update tasks/cancel), do: {method, "task-audit"})
  end

  test "unknown task IDs produce invalid-params through dispatch" do
    codes =
      for method <- ~w(tasks/get tasks/update tasks/cancel) do
        params = %{"taskId" => "missing-task"}

        params =
          if method == "tasks/update", do: Map.put(params, "inputResponses", %{}), else: params

        {:response, %{"error" => error}, _state} =
          Dispatch.dispatch(request(method, params), Handler, %{},
            principal_id: "alice",
            tenant_id: "audit",
            endpoint: "https://mcp.example"
          )

        {method, error["code"]}
      end

    assert codes == for(method <- ~w(tasks/get tasks/update tasks/cancel), do: {method, -32602})
  end

  test "unknown task IDs produce invalid-params through the HTTP processor" do
    codes =
      for method <- ~w(tasks/get tasks/update tasks/cancel) do
        params = %{"taskId" => "missing-task"}

        params =
          if method == "tasks/update", do: Map.put(params, "inputResponses", %{}), else: params

        conn =
          request(method, params)
          |> MessageProcessor.new()
          |> MessageProcessor.process(%{
            handler: Handler,
            protocol_mode: :modern_only,
            principal_id: "alice",
            tenant_id: "audit",
            endpoint: "https://mcp.example"
          })

        {method, get_in(conn.response, ["error", "code"])}
      end

    assert codes == for(method <- ~w(tasks/get tasks/update tasks/cancel), do: {method, -32602})
  end

  test "request-processor task errors preserve invalid-params without exposing ownership", %{
    opts: opts
  } do
    bob = Map.put(@owner, :principal_id, "bob")
    {:ok, created} = Tasks.create("private-background", %{}, Keyword.put(opts, :owner, bob))

    state = %{
      __module__: Handler,
      principal_id: "alice",
      tenant_id: "audit",
      endpoint: "https://mcp.example"
    }

    errors =
      for method <- ~w(tasks/get tasks/update tasks/cancel),
          id <- ["unknown", created["taskId"]] do
        params = %{"taskId" => id}

        params =
          if method == "tasks/update", do: Map.put(params, "inputResponses", %{}), else: params

        assert {:response, %{"error" => error}, _state} =
                 RequestProcessor.process(request(method, params), state)

        assert error["code"] == -32602
        error
      end

    assert length(Enum.uniq(errors)) == 1
  end

  test "malformed task IDs are invalid-params on every adapter" do
    state = %{
      __module__: Handler,
      principal_id: "alice",
      tenant_id: "audit",
      endpoint: "https://mcp.example"
    }

    http_opts = %{
      handler: Handler,
      protocol_mode: :modern_only,
      principal_id: "alice",
      tenant_id: "audit",
      endpoint: "https://mcp.example"
    }

    for method <- ~w(tasks/get tasks/update tasks/cancel), id <- [:omitted, nil, "", 42, []] do
      params = if id == :omitted, do: %{}, else: %{"taskId" => id}

      params =
        if method == "tasks/update", do: Map.put(params, "inputResponses", %{}), else: params

      message = request(method, params)
      {:response, dispatch, _} = Dispatch.dispatch(message, Handler, %{})
      {:response, processed, _} = RequestProcessor.process(message, state)
      http = message |> MessageProcessor.new() |> MessageProcessor.process(http_opts)

      for response <- [dispatch, processed, http.response] do
        assert response["error"]["code"] == -32602
      end
    end
  end

  test "malformed update input is invalid-params on every adapter", %{opts: opts} do
    {:ok, created} = Tasks.create("update-params", %{}, opts)

    state = %{
      __module__: Handler,
      principal_id: "alice",
      tenant_id: "audit",
      endpoint: "https://mcp.example"
    }

    http_opts = %{
      handler: Handler,
      protocol_mode: :modern_only,
      principal_id: "alice",
      tenant_id: "audit",
      endpoint: "https://mcp.example"
    }

    for id <- [created["taskId"], "unknown"], value <- [:omitted, nil, [], "invalid", 42, true] do
      params = %{"taskId" => id}
      params = if value == :omitted, do: params, else: Map.put(params, "inputResponses", value)
      message = request("tasks/update", params)

      {:response, dispatch, _} =
        Dispatch.dispatch(message, Handler, %{},
          principal_id: "alice",
          tenant_id: "audit",
          endpoint: "https://mcp.example"
        )

      {:response, processed, _} = RequestProcessor.process(message, state)
      http = message |> MessageProcessor.new() |> MessageProcessor.process(http_opts)

      for response <- [dispatch, processed, http.response] do
        assert response["error"]["code"] == -32602
      end
    end

    assert {:ok, %{"status" => "working"}} = Tasks.get(created["taskId"], opts)
  end

  test "request processor rejects malformed updates before invoking a custom callback" do
    state = %{__module__: UpdateObserver, observer: self()}
    bad = request("tasks/update", %{"taskId" => "any-id"})
    assert {:response, %{"error" => error}, _} = RequestProcessor.process(bad, state)
    assert error["code"] == -32602
    refute_received :task_update_callback_called

    valid = request("tasks/update", %{"taskId" => "any-id", "inputResponses" => %{}})
    assert {:response, %{"result" => _}, _} = RequestProcessor.process(valid, state)
    assert_received :task_update_callback_called
  end

  test "a task input key cannot be reused for a later logical request", %{opts: opts} do
    {:ok, created} = Tasks.create("background", %{}, opts)
    id = created["taskId"]
    {:ok, _} = Tasks.require_input(id, input("First question"), opts)

    :ok =
      Tasks.update(
        id,
        %{"answer" => %{"result" => %{"action" => "accept", "content" => %{}}}},
        opts
      )

    {:ok, _} = Tasks.take_input_responses(id, opts)
    assert {:error, _reason} = Tasks.require_input(id, input("Different question"), opts)
  end

  test "a task can record a protocol failure while awaiting input", %{opts: opts} do
    {:ok, created} = Tasks.create("background", %{}, opts)
    id = created["taskId"]
    {:ok, _} = Tasks.require_input(id, input("Pending question"), opts)

    assert {:ok, %{state: :failed}} =
             Tasks.fail(id, %{"code" => -32603, "message" => "Worker failed"}, opts)
  end

  defp input(message) do
    %{
      "answer" => %{
        "method" => "elicitation/create",
        "params" => %{
          "mode" => "form",
          "message" => message,
          "requestedSchema" => %{"type" => "object", "properties" => %{}}
        }
      }
    }
  end

  defp request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => Extension.required_capabilities()
        })
    }
  end
end
