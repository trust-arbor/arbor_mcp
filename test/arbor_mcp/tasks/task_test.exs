defmodule Arbor.MCP.Tasks.TaskTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Tasks.Task

  describe "new/3" do
    test "creates a task with default values" do
      task = Task.new("my-tool", %{"key" => "value"})

      assert task.tool_name == "my-tool"
      assert task.arguments == %{"key" => "value"}
      assert task.state == :working
      assert is_binary(task.id)
      assert String.starts_with?(task.id, "task_")
      assert is_binary(task.created_at)
      assert task.ttl == nil
      assert task.metadata == %{}
      assert task.result == nil
      assert task.input_requests == nil
      assert task.error == nil
    end

    test "creates a task with default empty arguments" do
      task = Task.new("my-tool")

      assert task.tool_name == "my-tool"
      assert task.arguments == %{}
    end

    test "creates a task with custom id" do
      task = Task.new("my-tool", %{}, id: "custom-id-123")

      assert task.id == "custom-id-123"
    end

    test "creates a task with custom ttl" do
      task = Task.new("my-tool", %{}, ttl: 60_000)

      assert task.ttl == 60_000
    end

    test "creates a task with custom metadata" do
      metadata = %{"priority" => "high", "source" => "test"}
      task = Task.new("my-tool", %{}, metadata: metadata)

      assert task.metadata == metadata
    end

    test "creates a task with all custom options" do
      task =
        Task.new("my-tool", %{"arg" => 1},
          id: "my-id",
          ttl: 30_000,
          metadata: %{"env" => "test"}
        )

      assert task.id == "my-id"
      assert task.tool_name == "my-tool"
      assert task.arguments == %{"arg" => 1}
      assert task.state == :working
      assert task.ttl == 30_000
      assert task.metadata == %{"env" => "test"}
    end

    test "created_at is a valid ISO 8601 timestamp" do
      task = Task.new("my-tool")

      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(task.created_at)
    end

    test "generates unique ids for different tasks" do
      task1 = Task.new("tool-a")
      task2 = Task.new("tool-b")

      assert task1.id != task2.id
    end
  end

  describe "transition/2" do
    test "working -> input_required is valid" do
      task = Task.new("my-tool")
      assert {:ok, updated} = Task.transition(task, :input_required)
      assert updated.state == :input_required
    end

    test "working -> completed is valid" do
      task = Task.new("my-tool")
      assert {:ok, updated} = Task.transition(task, :completed)
      assert updated.state == :completed
    end

    test "working -> failed is valid" do
      task = Task.new("my-tool")
      assert {:ok, updated} = Task.transition(task, :failed)
      assert updated.state == :failed
    end

    test "working -> cancelled is valid" do
      task = Task.new("my-tool")
      assert {:ok, updated} = Task.transition(task, :cancelled)
      assert updated.state == :cancelled
    end

    test "input_required -> working is valid" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      assert {:ok, updated} = Task.transition(task, :working)
      assert updated.state == :working
    end

    test "input_required -> cancelled is valid" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      assert {:ok, updated} = Task.transition(task, :cancelled)
      assert updated.state == :cancelled
    end

    test "completed is terminal and cannot transition" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :completed)

      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        assert {:error, msg} = Task.transition(task, target)
        assert msg =~ "Invalid transition from completed to #{target}"
      end
    end

    test "failed is terminal and cannot transition" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :failed)

      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        assert {:error, msg} = Task.transition(task, target)
        assert msg =~ "Invalid transition from failed to #{target}"
      end
    end

    test "cancelled is terminal and cannot transition" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :cancelled)

      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        assert {:error, msg} = Task.transition(task, target)
        assert msg =~ "Invalid transition from cancelled to #{target}"
      end
    end

    test "working -> working is invalid" do
      task = Task.new("my-tool")
      assert {:error, _msg} = Task.transition(task, :working)
    end

    test "input_required -> input_required is invalid" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      assert {:error, _msg} = Task.transition(task, :input_required)
    end

    test "input_required -> completed is invalid" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      assert {:error, _msg} = Task.transition(task, :completed)
    end

    test "input_required -> failed is invalid" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      assert {:error, _msg} = Task.transition(task, :failed)
    end

    test "preserves other task fields on transition" do
      task = Task.new("my-tool", %{"key" => "val"}, id: "test-id", ttl: 5000)
      {:ok, updated} = Task.transition(task, :input_required)

      assert updated.id == "test-id"
      assert updated.tool_name == "my-tool"
      assert updated.arguments == %{"key" => "val"}
      assert updated.ttl == 5000
      assert updated.created_at == task.created_at
    end
  end

  describe "modern task state" do
    test "retains legacy fields while emitting the 2026-07-28 wire keys" do
      task = Task.new("deploy", %{"environment" => "production"}, ttl: 60_000)

      legacy = Task.to_map(task)
      modern = Task.to_map(task, "2026-07-28")

      assert legacy["ttl"] == 60_000
      assert legacy["toolName"] == "deploy"
      refute Map.has_key?(legacy, "ttlMs")

      assert modern["ttlMs"] == 60_000
      assert modern["taskId"] == task.id
      refute Map.has_key?(modern, "ttl")
      refute Map.has_key?(modern, "toolName")
      refute Map.has_key?(modern, "arguments")
    end

    test "carries outstanding inputs and uses error instead of result for failures" do
      task = Task.new("deploy", %{}, ttl: 60_000)
      assert {:ok, waiting} = Task.require_input(task, %{"approval" => %{"method" => "x"}})

      assert Task.to_map(waiting, :modern)["inputRequests"] == %{
               "approval" => %{"method" => "x"}
             }

      assert {:ok, working} = Task.transition(waiting, :working)
      assert {:ok, failed} = Task.fail(working, %{"code" => -32603, "message" => "failed"})

      modern = Task.to_map(failed, :modern)
      assert modern["error"]["code"] == -32603
      refute Map.has_key?(modern, "result")
      assert failed.result == failed.error
    end
  end

  describe "complete/2" do
    test "transitions to completed with result" do
      task = Task.new("my-tool")
      result = %{"output" => "done", "data" => [1, 2, 3]}

      assert {:ok, completed} = Task.complete(task, result)
      assert completed.state == :completed
      assert completed.result == result
    end

    test "returns error when task is not in working state" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)

      assert {:error, _msg} = Task.complete(task, %{"output" => "done"})
    end

    test "returns error when task is already completed" do
      task = Task.new("my-tool")
      {:ok, task} = Task.complete(task, %{"first" => true})

      assert {:error, _msg} = Task.complete(task, %{"second" => true})
    end

    test "returns error when task is failed" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :failed)

      assert {:error, _msg} = Task.complete(task, %{"output" => "done"})
    end

    test "returns error when task is cancelled" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :cancelled)

      assert {:error, _msg} = Task.complete(task, %{"output" => "done"})
    end
  end

  describe "fail/2" do
    test "transitions to failed with error result" do
      task = Task.new("my-tool")
      error = %{"code" => "TIMEOUT", "message" => "Operation timed out"}

      assert {:ok, failed} = Task.fail(task, error)
      assert failed.state == :failed
      assert failed.result == error
    end

    test "returns error when task is not in working state" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)

      assert {:error, _msg} = Task.fail(task, %{"code" => "ERR"})
    end

    test "returns error when task is already completed" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :completed)

      assert {:error, _msg} = Task.fail(task, %{"code" => "ERR"})
    end

    test "returns error when task is already failed" do
      task = Task.new("my-tool")
      {:ok, task} = Task.fail(task, %{"code" => "FIRST"})

      assert {:error, _msg} = Task.fail(task, %{"code" => "SECOND"})
    end

    test "returns error when task is cancelled" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :cancelled)

      assert {:error, _msg} = Task.fail(task, %{"code" => "ERR"})
    end
  end

  describe "valid_transition?/2" do
    test "returns true for all valid transitions from working" do
      assert Task.valid_transition?(:working, :input_required)
      assert Task.valid_transition?(:working, :completed)
      assert Task.valid_transition?(:working, :failed)
      assert Task.valid_transition?(:working, :cancelled)
    end

    test "returns true for all valid transitions from input_required" do
      assert Task.valid_transition?(:input_required, :working)
      assert Task.valid_transition?(:input_required, :cancelled)
    end

    test "returns false for invalid transitions from working" do
      refute Task.valid_transition?(:working, :working)
    end

    test "returns false for invalid transitions from input_required" do
      refute Task.valid_transition?(:input_required, :input_required)
      refute Task.valid_transition?(:input_required, :completed)
      refute Task.valid_transition?(:input_required, :failed)
    end

    test "returns false for all transitions from completed" do
      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        refute Task.valid_transition?(:completed, target)
      end
    end

    test "returns false for all transitions from failed" do
      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        refute Task.valid_transition?(:failed, target)
      end
    end

    test "returns false for all transitions from cancelled" do
      for target <- [:working, :input_required, :completed, :failed, :cancelled] do
        refute Task.valid_transition?(:cancelled, target)
      end
    end
  end

  describe "terminal?/1" do
    test "returns true for completed task" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :completed)
      assert Task.terminal?(task)
    end

    test "returns true for failed task" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :failed)
      assert Task.terminal?(task)
    end

    test "returns true for cancelled task" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :cancelled)
      assert Task.terminal?(task)
    end

    test "returns false for working task" do
      task = Task.new("my-tool")
      refute Task.terminal?(task)
    end

    test "returns false for input_required task" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      refute Task.terminal?(task)
    end
  end

  describe "states/0" do
    test "returns all valid states" do
      states = Task.states()

      assert :working in states
      assert :input_required in states
      assert :completed in states
      assert :failed in states
      assert :cancelled in states
      assert length(states) == 5
    end
  end

  describe "terminal_states/0" do
    test "returns all terminal states" do
      terminal = Task.terminal_states()

      assert :completed in terminal
      assert :failed in terminal
      assert :cancelled in terminal
      assert length(terminal) == 3
    end

    test "does not include non-terminal states" do
      terminal = Task.terminal_states()

      refute :working in terminal
      refute :input_required in terminal
    end
  end

  describe "to_map/1" do
    test "maps required fields correctly" do
      task = Task.new("my-tool", %{}, id: "test-123")
      map = Task.to_map(task)

      assert map["taskId"] == "test-123"
      assert map["status"] == "working"
      assert map["toolName"] == "my-tool"
    end

    test "includes createdAt" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      assert is_binary(map["createdAt"])
    end

    test "includes arguments when non-empty" do
      task = Task.new("my-tool", %{"key" => "value"})
      map = Task.to_map(task)

      assert map["arguments"] == %{"key" => "value"}
    end

    test "omits arguments when empty map" do
      task = Task.new("my-tool", %{})
      map = Task.to_map(task)

      refute Map.has_key?(map, "arguments")
    end

    test "includes ttl when set" do
      task = Task.new("my-tool", %{}, ttl: 30_000)
      map = Task.to_map(task)

      assert map["ttl"] == 30_000
    end

    test "omits ttl when nil" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      refute Map.has_key?(map, "ttl")
    end

    test "includes result when set" do
      task = Task.new("my-tool")
      {:ok, task} = Task.complete(task, %{"output" => "done"})
      map = Task.to_map(task)

      assert map["result"] == %{"output" => "done"}
    end

    test "omits result when nil" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      refute Map.has_key?(map, "result")
    end

    test "includes metadata when non-empty" do
      task = Task.new("my-tool", %{}, metadata: %{"env" => "test"})
      map = Task.to_map(task)

      assert map["metadata"] == %{"env" => "test"}
    end

    test "omits metadata when empty map" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      refute Map.has_key?(map, "metadata")
    end

    test "serializes state as status string" do
      task = Task.new("my-tool")
      {:ok, task} = Task.transition(task, :input_required)
      map = Task.to_map(task)

      assert map["status"] == "input_required"
    end

    test "maps all fields for a fully populated task" do
      task =
        Task.new("my-tool", %{"a" => 1},
          id: "full-task",
          ttl: 60_000,
          metadata: %{"m" => true},
          status_message: "Almost done",
          poll_interval: 5000
        )

      {:ok, task} = Task.complete(task, %{"output" => "success"})
      map = Task.to_map(task)

      assert map["taskId"] == "full-task"
      assert map["status"] == "completed"
      assert map["toolName"] == "my-tool"
      assert map["arguments"] == %{"a" => 1}
      assert map["ttl"] == 60_000
      assert map["result"] == %{"output" => "success"}
      assert map["metadata"] == %{"m" => true}
      assert is_binary(map["createdAt"])
      assert is_binary(map["lastUpdatedAt"])
      assert map["statusMessage"] == "Almost done"
      assert map["pollInterval"] == 5000
    end

    test "to_map includes lastUpdatedAt" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      assert is_binary(map["lastUpdatedAt"])
      # lastUpdatedAt should be a valid ISO 8601 timestamp
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(map["lastUpdatedAt"])
    end

    test "to_map supports statusMessage" do
      task = Task.new("my-tool", %{}, status_message: "Processing step 2 of 5")
      map = Task.to_map(task)

      assert map["statusMessage"] == "Processing step 2 of 5"
    end

    test "to_map omits statusMessage when nil" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      refute Map.has_key?(map, "statusMessage")
    end

    test "to_map supports pollInterval" do
      task = Task.new("my-tool", %{}, poll_interval: 2000)
      map = Task.to_map(task)

      assert map["pollInterval"] == 2000
    end

    test "to_map omits pollInterval when nil" do
      task = Task.new("my-tool")
      map = Task.to_map(task)

      refute Map.has_key?(map, "pollInterval")
    end
  end

  describe "parse_state/1" do
    test "parses 'working' to :working" do
      assert {:ok, :working} = Task.parse_state("working")
    end

    test "parses 'input_required' to :input_required" do
      assert {:ok, :input_required} = Task.parse_state("input_required")
    end

    test "parses 'completed' to :completed" do
      assert {:ok, :completed} = Task.parse_state("completed")
    end

    test "parses 'failed' to :failed" do
      assert {:ok, :failed} = Task.parse_state("failed")
    end

    test "parses 'cancelled' to :cancelled" do
      assert {:ok, :cancelled} = Task.parse_state("cancelled")
    end

    test "returns error for unknown state string" do
      assert {:error, msg} = Task.parse_state("unknown")
      assert msg =~ "Unknown task state"
      assert msg =~ "unknown"
    end

    test "returns error for empty string" do
      assert {:error, _msg} = Task.parse_state("")
    end

    test "returns error for similar but incorrect strings" do
      assert {:error, _msg} = Task.parse_state("WORKING")
      assert {:error, _msg} = Task.parse_state("Complete")
      assert {:error, _msg} = Task.parse_state("input-required")
    end
  end
end
