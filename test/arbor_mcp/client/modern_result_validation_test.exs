defmodule Arbor.MCP.Client.ModernResultValidationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.RequestHandler

  defmodule SyncTransport do
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.owner, {:outbound_request, request})

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => state.result
      }

      {:ok, state, Jason.encode!(response)}
    end
  end

  defmodule AsyncTransport do
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.owner, {:outbound_request, request})
      {:ok, state}
    end
  end

  test "injects modern metadata and accepts a discriminated result" do
    state =
      modern_state(%{
        "resultType" => "complete",
        "tools" => [],
        "ttlMs" => 0,
        "cacheScope" => "private"
      })

    assert {:reply, {:ok, %{"resultType" => "complete"}}, _state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), make_ref()}, state)

    assert_receive {:outbound_request, request}
    meta = request["params"]["_meta"]
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == %{"roots" => %{}}

    refute get_in(meta, [
             "io.modelcontextprotocol/clientCapabilities",
             "extensions",
             "io.modelcontextprotocol/tasks"
           ])

    assert meta["io.modelcontextprotocol/clientInfo"]["name"] == "test-client"
  end

  test "valid cache hints are advisory and repeated requests still reach the transport" do
    state =
      modern_state(%{
        "resultType" => "complete",
        "tools" => [],
        "ttlMs" => 60_000,
        "cacheScope" => "public"
      })

    assert {:reply, {:ok, %{"ttlMs" => 60_000}}, state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), make_ref()}, state)

    assert_receive {:outbound_request, first}

    assert {:reply, {:ok, %{"ttlMs" => 60_000}}, _state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), make_ref()}, state)

    assert_receive {:outbound_request, second}
    assert first["id"] != second["id"]
    assert first["method"] == second["method"]
    assert first["params"] == second["params"]
  end

  test "rejects a modern result without resultType" do
    state = modern_state(%{"tools" => []})

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), make_ref()}, state)

    assert error.type == :protocol_error
    assert error.reason == :missing_result_type
  end

  test "rejects missing and invalid cache hints on cacheable methods" do
    for {result, expected_reason} <- [
          {%{"resultType" => "complete", "tools" => [], "cacheScope" => "private"},
           :missing_ttl_ms},
          {%{
             "resultType" => "complete",
             "tools" => [],
             "ttlMs" => -1,
             "cacheScope" => "private"
           }, {:invalid_ttl_ms, -1}},
          {%{"resultType" => "complete", "tools" => [], "ttlMs" => 0}, :missing_cache_scope},
          {%{
             "resultType" => "complete",
             "tools" => [],
             "ttlMs" => 0,
             "cacheScope" => "shared"
           }, {:invalid_cache_scope, "shared"}}
        ] do
      assert {:reply, {:error, error}, _state} =
               RequestHandler.handle_request(
                 "tools/list",
                 %{},
                 {self(), make_ref()},
                 modern_state(result)
               )

      assert error.type == :protocol_error
      assert error.reason == expected_reason
    end
  end

  test "carries the method through async response validation" do
    reply_tag = make_ref()
    state = %{modern_state(nil) | transport_mod: AsyncTransport}

    assert {:noreply, state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), reply_tag}, state)

    assert_receive {:outbound_request, %{"id" => request_id}}
    assert {_, :single, "tools/list"} = state.pending_requests[request_id]

    assert {:noreply, state} =
             RequestHandler.handle_single_response(
               {:result, %{"resultType" => "complete", "tools" => []}, request_id},
               state
             )

    assert_receive {^reply_tag, {:error, %{reason: :missing_ttl_ms}}}
    refute Map.has_key?(state.pending_requests, request_id)
  end

  test "keeps legacy missing-resultType behavior" do
    state = %{modern_state(%{"tools" => []}) | protocol_version: "2025-11-25"}

    assert {:reply, {:ok, %{"tools" => []}}, _state} =
             RequestHandler.handle_request("tools/list", %{}, {self(), make_ref()}, state)
  end

  test "uses server/discover for modern health checks" do
    state =
      modern_state(%{
        "resultType" => "complete",
        "ttlMs" => 0,
        "cacheScope" => "private"
      })

    assert {:ok, nil, _state} = RequestHandler.send_ping(state)
    assert_receive {:outbound_request, %{"method" => "server/discover"}}
  end

  test "accepts task results only when the modern extension was declared" do
    result = task_result()

    declared =
      modern_state(result,
        capabilities: %{
          extensions: %{"io.modelcontextprotocol/tasks" => %{}}
        }
      )

    assert {:reply, {:ok, %{"resultType" => "task", "taskId" => "task-1"}}, _state} =
             RequestHandler.handle_request(
               "tools/call",
               %{"name" => "background", "arguments" => %{}},
               {self(), make_ref()},
               declared
             )

    assert_receive {:outbound_request, declared_request}

    assert get_in(declared_request, [
             "params",
             "_meta",
             "io.modelcontextprotocol/clientCapabilities",
             "extensions",
             "io.modelcontextprotocol/tasks"
           ]) == %{}

    undeclared = modern_state(result, allowed_result_types: ["task"])

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request(
               "tools/call",
               %{"name" => "background", "arguments" => %{}},
               {self(), make_ref()},
               undeclared
             )

    assert error.reason == {:unknown_result_type, "task"}
  end

  test "rejects malformed task results after extension negotiation" do
    state =
      modern_state(%{"resultType" => "task", "taskId" => "task-1"},
        capabilities: %{
          extensions: %{"io.modelcontextprotocol/tasks" => %{}}
        }
      )

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request(
               "tools/call",
               %{"name" => "background", "arguments" => %{}},
               {self(), make_ref()},
               state
             )

    assert error.reason == {:invalid_task_field, "status"}
  end

  test "accepts complete detailed tasks/get results and rejects the create discriminator" do
    capabilities = %{
      extensions: %{"io.modelcontextprotocol/tasks" => %{}}
    }

    detailed = %{task_result() | "resultType" => "complete"}

    assert {:reply, {:ok, %{"resultType" => "complete", "taskId" => "task-1"}}, _state} =
             RequestHandler.handle_request(
               "tasks/get",
               %{"taskId" => "task-1"},
               {self(), make_ref()},
               modern_state(detailed, capabilities: capabilities)
             )

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request(
               "tasks/get",
               %{"taskId" => "task-1"},
               {self(), make_ref()},
               modern_state(task_result(), capabilities: capabilities)
             )

    assert error.reason == {:invalid_result_type, "task"}

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request(
               "tasks/get",
               %{"taskId" => "task-1"},
               {self(), make_ref()},
               modern_state(detailed)
             )

    assert error.reason == :undeclared_tasks_extension
  end

  test "preserves the legacy tasks/get result shape" do
    state = %{
      modern_state(%{"taskId" => "task-1", "status" => "working"})
      | protocol_version: "2025-11-25"
    }

    assert {:reply, {:ok, %{"taskId" => "task-1", "status" => "working"}}, _state} =
             RequestHandler.handle_request(
               "tasks/get",
               %{"taskId" => "task-1"},
               {self(), make_ref()},
               state
             )
  end

  defp modern_state(result, opts \\ []) do
    %Arbor.MCP.Client{
      transport_mod: SyncTransport,
      transport_state: %{owner: self(), result: result},
      transport_opts: Keyword.merge([capabilities: %{roots: %{}}], opts),
      protocol_version: "2026-07-28",
      client_info: %{"name" => "test-client", "version" => "1"},
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      default_timeout: 1_000
    }
  end

  defp task_result do
    %{
      "resultType" => "task",
      "taskId" => "task-1",
      "status" => "working",
      "createdAt" => "2026-08-04T00:00:00Z",
      "lastUpdatedAt" => "2026-08-04T00:00:00Z",
      "ttlMs" => 60_000
    }
  end
end
