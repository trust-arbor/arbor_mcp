defmodule Arbor.MCP.Compliance.TasksTest do
  @moduledoc """
  Test suite for MCP 2025-11-25 Tasks protocol compliance.

  Tests the following:
  - Protocol encoders create correct JSON-RPC messages for task methods
  - Method availability across protocol versions
  - Feature availability across protocol versions
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.Capabilities

  describe "protocol encoders" do
    test "encode_task_get creates correct JSON-RPC message" do
      message = Protocol.encode_task_get("task-123")

      assert message["jsonrpc"] == "2.0"
      assert message["method"] == "tasks/get"
      assert message["params"]["taskId"] == "task-123"
      assert is_integer(message["id"])
    end

    test "encode_task_result creates correct JSON-RPC message" do
      message = Protocol.encode_task_result("task-123")

      assert message["jsonrpc"] == "2.0"
      assert message["method"] == "tasks/result"
      assert message["params"]["taskId"] == "task-123"
      assert is_integer(message["id"])
    end

    test "encode_task_list creates correct JSON-RPC message without cursor" do
      message = Protocol.encode_task_list()

      assert message["jsonrpc"] == "2.0"
      assert message["method"] == "tasks/list"
      assert message["params"] == %{}
      assert is_integer(message["id"])
    end

    test "encode_task_list creates correct JSON-RPC message with cursor" do
      message = Protocol.encode_task_list("abc")

      assert message["jsonrpc"] == "2.0"
      assert message["method"] == "tasks/list"
      assert message["params"]["cursor"] == "abc"
      assert is_integer(message["id"])
    end

    test "encode_task_cancel creates correct JSON-RPC message" do
      message = Protocol.encode_task_cancel("task-123")

      assert message["jsonrpc"] == "2.0"
      assert message["method"] == "tasks/cancel"
      assert message["params"]["taskId"] == "task-123"
      assert is_integer(message["id"])
    end

    test "encode_task_status_notification creates notification with metadata" do
      notification =
        Protocol.encode_task_status_notification("task-123", "working", %{"progress" => 50})

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/tasks/status"
      assert notification["params"]["taskId"] == "task-123"
      assert notification["params"]["status"] == "working"
      assert notification["params"]["metadata"] == %{"progress" => 50}
      # Notifications do not have an id field
      refute Map.has_key?(notification, "id")
    end

    test "encode_task_status_notification creates notification without metadata" do
      notification = Protocol.encode_task_status_notification("task-456", "completed")

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/tasks/status"
      assert notification["params"]["taskId"] == "task-456"
      assert notification["params"]["status"] == "completed"
      refute Map.has_key?(notification["params"], "metadata")
      refute Map.has_key?(notification, "id")
    end

    test "encode_task_status_notification with nil metadata omits metadata field" do
      notification = Protocol.encode_task_status_notification("task-789", "failed", nil)

      assert notification["params"]["taskId"] == "task-789"
      assert notification["params"]["status"] == "failed"
      refute Map.has_key?(notification["params"], "metadata")
    end

    test "each encode call generates a unique id" do
      msg1 = Protocol.encode_task_get("task-1")
      msg2 = Protocol.encode_task_get("task-2")

      assert msg1["id"] != msg2["id"]
    end
  end

  describe "method availability" do
    test "tasks/get is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/get", "2025-11-25")
    end

    test "tasks/list is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/list", "2025-11-25")
    end

    test "tasks/result is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/result", "2025-11-25")
    end

    test "tasks/cancel is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/cancel", "2025-11-25")
    end

    test "notifications/tasks/status is available in 2025-11-25" do
      assert Protocol.method_available?("notifications/tasks/status", "2025-11-25")
    end

    test "modern extension exposes only the redesigned method surface" do
      for method <- ["tasks/get", "tasks/update", "tasks/cancel", "notifications/tasks"] do
        assert Protocol.method_available?(method, "2026-07-28")
      end

      for method <- ["tasks/list", "tasks/result", "notifications/tasks/status"] do
        refute Protocol.method_available?(method, "2026-07-28")
      end
    end

    test "tasks/get is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/get", "2025-06-18")
    end

    test "tasks/list is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/list", "2025-06-18")
    end

    test "tasks/result is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/result", "2025-06-18")
    end

    test "tasks/cancel is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/cancel", "2025-06-18")
    end

    test "notifications/tasks/status is NOT available in 2025-06-18" do
      refute Protocol.method_available?("notifications/tasks/status", "2025-06-18")
    end

    test "tasks methods are NOT available in 2025-03-26" do
      for method <- ["tasks/get", "tasks/list", "tasks/result", "tasks/cancel"] do
        refute Protocol.method_available?(method, "2025-03-26"),
               "expected #{method} to be unavailable in 2025-03-26"
      end
    end

    test "tasks methods are NOT available in 2024-11-05" do
      for method <- ["tasks/get", "tasks/list", "tasks/result", "tasks/cancel"] do
        refute Protocol.method_available?(method, "2024-11-05"),
               "expected #{method} to be unavailable in 2024-11-05"
      end
    end
  end

  describe "feature availability via VersionRegistry" do
    test ":tasks feature is available in 2025-11-25" do
      assert VersionRegistry.feature_available?("2025-11-25", :tasks)
    end

    test ":tasks feature is NOT available in 2025-06-18" do
      refute VersionRegistry.feature_available?("2025-06-18", :tasks)
    end

    test ":tasks feature is NOT available in 2025-03-26" do
      refute VersionRegistry.feature_available?("2025-03-26", :tasks)
    end

    test ":tasks feature is NOT available in 2024-11-05" do
      refute VersionRegistry.feature_available?("2024-11-05", :tasks)
    end

    test ":icons feature is available in 2025-11-25" do
      assert VersionRegistry.feature_available?("2025-11-25", :icons)
    end

    test ":icons feature is NOT available in 2025-06-18" do
      refute VersionRegistry.feature_available?("2025-06-18", :icons)
    end
  end

  describe "version capabilities include tasks" do
    test "2025-11-25 capabilities include tasks key" do
      caps = VersionRegistry.capabilities_for_version("2025-11-25")
      assert Map.has_key?(caps, :tasks)
      assert Capabilities.build_capabilities(nil, "2025-11-25")["tasks"] == %{}
    end

    test "2025-06-18 capabilities do NOT include tasks key" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      refute Map.has_key?(caps, :tasks)
    end
  end

  describe "message version validation" do
    test "tasks/get passes validation for 2025-11-25" do
      message = Protocol.encode_task_get("task-123")
      assert :ok == Protocol.validate_message_version(message, "2025-11-25")
    end

    test "tasks/get fails validation for 2025-06-18" do
      message = Protocol.encode_task_get("task-123")
      assert {:error, _reason} = Protocol.validate_message_version(message, "2025-06-18")
    end

    test "tasks/cancel fails validation for 2025-06-18" do
      message = Protocol.encode_task_cancel("task-123")
      assert {:error, _reason} = Protocol.validate_message_version(message, "2025-06-18")
    end

    test "task status notification passes validation for 2025-11-25" do
      notification = Protocol.encode_task_status_notification("task-123", "working", %{})
      assert :ok == Protocol.validate_message_version(notification, "2025-11-25")
    end

    test "task status notification fails validation for 2025-06-18" do
      notification = Protocol.encode_task_status_notification("task-123", "working", %{})
      assert {:error, _reason} = Protocol.validate_message_version(notification, "2025-06-18")
    end
  end

  describe "message format registry" do
    test "2025-11-25 message format lists task notification methods" do
      format = VersionRegistry.message_format("2025-11-25")
      assert "notifications/tasks/status" in format.notification_methods
    end

    test "2025-11-25 message format lists task request methods" do
      format = VersionRegistry.message_format("2025-11-25")
      assert "tasks/get" in format.request_methods
      assert "tasks/list" in format.request_methods
      assert "tasks/result" in format.request_methods
      assert "tasks/cancel" in format.request_methods
    end

    test "2025-06-18 message format does NOT list task notification methods" do
      format = VersionRegistry.message_format("2025-06-18")
      refute "notifications/tasks/status" in format.notification_methods
    end
  end
end
