defmodule Arbor.MCP.Tasks.ExtensionTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Tasks.{Extension, Task}

  test "exposes the canonical extension contract" do
    assert Extension.identifier() == "io.modelcontextprotocol/tasks"
    assert Extension.result_type() == "task"
    assert Extension.request_methods() == ["tasks/get", "tasks/update", "tasks/cancel"]
    assert Extension.notification_method() == "notifications/tasks"

    assert Extension.required_capabilities() == %{
             "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
           }
  end

  test "adds and detects the extension without confusing the legacy capability" do
    capabilities = Extension.put_capability(%{"tools" => %{}})

    assert Extension.declared?(capabilities)
    assert Extension.allowed_result_types(capabilities) == ["task"]
    assert capabilities["tools"] == %{}

    assert Extension.declared?(%{extensions: %{"io.modelcontextprotocol/tasks" => %{}}})
    refute Extension.declared?(%{"tasks" => %{}})
    refute Extension.declared?(%{"extensions" => %{"io.modelcontextprotocol/tasks" => true}})
  end

  test "encodes modern update and full-state notification messages" do
    update = Protocol.encode_task_update("task-1", %{"approval" => %{"action" => "accept"}})

    assert update["method"] == "tasks/update"

    assert update["params"] == %{
             "taskId" => "task-1",
             "inputResponses" => %{"approval" => %{"action" => "accept"}}
           }

    task = Task.new("deploy", %{}, id: "task-1", ttl: 60_000, poll_interval: 1_000)
    notification = Protocol.encode_task_notification(task)

    assert notification["method"] == "notifications/tasks"
    assert notification["params"]["taskId"] == "task-1"
    assert notification["params"]["ttlMs"] == 60_000
    assert notification["params"]["pollIntervalMs"] == 1_000
    refute Map.has_key?(notification["params"], "toolName")
  end

  test "validates task handles and status-specific detailed state" do
    base = %{
      "resultType" => "task",
      "taskId" => "task-1",
      "status" => "working",
      "createdAt" => "2026-08-04T00:00:00Z",
      "lastUpdatedAt" => "2026-08-04T00:00:01Z",
      "ttlMs" => 60_000,
      "pollIntervalMs" => 1_000
    }

    assert :ok = Extension.validate_task_result(base)
    assert :ok = Extension.validate_task_result(base, :detailed)

    completed = Map.merge(base, %{"status" => "completed", "result" => %{}})
    assert :ok = Extension.validate_task_result(completed, :detailed)

    failed =
      Map.merge(base, %{
        "status" => "failed",
        "error" => %{"code" => -32603, "message" => "failed"}
      })

    assert :ok = Extension.validate_task_result(failed, :detailed)

    assert {:error, {:invalid_task_field, "result"}} =
             Extension.validate_task_result(%{base | "status" => "completed"}, :detailed)

    assert {:error, {:invalid_task_field, "ttlMs"}} =
             Extension.validate_task_result(%{base | "ttlMs" => -1})
  end
end
