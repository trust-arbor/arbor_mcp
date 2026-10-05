defmodule Arbor.MCP.ProgressTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.ProgressTracker

  @valid_token "test-progress-123"
  @valid_integer_token 456

  setup do
    start_supervised!(ProgressTracker)
    ProgressTracker.clear_all()
    :ok
  end

  describe "start_progress/2" do
    test "successfully starts tracking with string token" do
      sender_pid = self()

      {:ok, state} = ProgressTracker.start_progress(@valid_token, sender_pid)

      assert state.progress_token == @valid_token
      assert state.sender_pid == sender_pid
      assert state.current_progress == 0
      assert state.total == nil
      assert state.last_message == nil
      assert state.notification_count == 0
      assert is_integer(state.start_time)
    end

    test "successfully starts tracking with integer token" do
      sender_pid = self()

      {:ok, state} = ProgressTracker.start_progress(@valid_integer_token, sender_pid)

      assert state.progress_token == @valid_integer_token
      assert state.sender_pid == sender_pid
      assert state.current_progress == 0
    end

    test "rejects invalid token types" do
      sender_pid = self()

      assert {:error, :invalid_token} = ProgressTracker.start_progress(:atom_token, sender_pid)
      assert {:error, :invalid_token} = ProgressTracker.start_progress(123.45, sender_pid)
      assert {:error, :invalid_token} = ProgressTracker.start_progress(nil, sender_pid)
      assert {:error, :invalid_token} = ProgressTracker.start_progress([], sender_pid)
    end

    test "rejects duplicate tokens" do
      sender_pid = self()

      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      assert {:error, :token_exists} = ProgressTracker.start_progress(@valid_token, sender_pid)
    end

    test "allows same token after completion" do
      sender_pid = self()

      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      :ok = ProgressTracker.complete_progress(@valid_token)
      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
    end
  end

  describe "owner isolation" do
    test "the same client token is isolated across sessions" do
      assert {:ok, _} =
               ProgressTracker.start_progress("shared", self(), owner: {:session, "session-a"})

      assert {:ok, _} =
               ProgressTracker.start_progress("shared", self(), owner: {:session, "session-b"})

      assert :ok =
               ProgressTracker.update_progress("shared", 1, nil, "a",
                 owner: {:session, "session-a"}
               )

      assert {:ok, session_a} =
               ProgressTracker.get_progress_state("shared", owner: {:session, "session-a"})

      assert {:ok, session_b} =
               ProgressTracker.get_progress_state("shared", owner: {:session, "session-b"})

      assert session_a.current_progress == 1
      assert session_b.current_progress == 0

      assert :ok =
               ProgressTracker.complete_progress("shared", owner: {:session, "session-a"})

      assert {:error, :not_found} =
               ProgressTracker.get_progress_state("shared", owner: {:session, "session-a"})

      assert {:ok, _} =
               ProgressTracker.get_progress_state("shared", owner: {:session, "session-b"})
    end
  end

  describe "update_progress/4" do
    setup do
      sender_pid = self()
      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      %{sender_pid: sender_pid}
    end

    test "successfully updates progress", %{sender_pid: _sender_pid} do
      assert :ok = ProgressTracker.update_progress(@valid_token, 25, 100, "Quarter done")

      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.current_progress == 25
      assert state.total == 100
      assert state.last_message == "Quarter done"
      assert state.notification_count == 1
    end

    test "sends progress notification to sender process" do
      :ok = ProgressTracker.update_progress(@valid_token, 50, 100, "Half way")

      assert_receive {:progress_notification, notification}
      assert notification.progressToken == @valid_token
      assert notification.progress == 50
      assert notification.total == 100
      assert notification.message == "Half way"
    end

    test "allows progress without total and message" do
      assert :ok = ProgressTracker.update_progress(@valid_token, 25)

      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.current_progress == 25
      assert state.total == nil
      assert state.last_message == nil

      assert_receive {:progress_notification, notification}
      assert notification.progressToken == @valid_token
      assert notification.progress == 25
      assert not Map.has_key?(notification, :total)
      assert not Map.has_key?(notification, :message)
    end

    test "preserves total from previous updates when not provided" do
      :ok = ProgressTracker.update_progress(@valid_token, 25, 100, "First update")
      :ok = ProgressTracker.update_progress(@valid_token, 50, nil, "Second update")

      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.current_progress == 50
      # Preserved from first update
      assert state.total == 100
      assert state.last_message == "Second update"
    end

    test "enforces monotonic progress values" do
      :ok = ProgressTracker.update_progress(@valid_token, 50)

      assert {:error, :not_increasing} = ProgressTracker.update_progress(@valid_token, 50)
      assert {:error, :not_increasing} = ProgressTracker.update_progress(@valid_token, 25)

      # Should still work with higher values
      assert :ok = ProgressTracker.update_progress(@valid_token, 75)
    end

    test "supports floating point progress values" do
      assert :ok = ProgressTracker.update_progress(@valid_token, 25.5, 100.0, "Float progress")

      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.current_progress == 25.5
      assert state.total == 100.0

      assert_receive {:progress_notification, notification}
      assert notification.progress == 25.5
      assert notification.total == 100.0
    end

    test "returns error for non-existent token" do
      assert {:error, :not_found} = ProgressTracker.update_progress("nonexistent", 50)
    end

    test "implements rate limiting" do
      # Send many updates quickly
      updates = 1..15

      results =
        Enum.map(updates, fn i ->
          ProgressTracker.update_progress(@valid_token, i)
        end)

      # Some should succeed, some should be rate limited
      successes = Enum.count(results, &(&1 == :ok))
      rate_limited = Enum.count(results, &(&1 == {:error, :rate_limited}))

      assert successes > 0
      assert rate_limited > 0
      assert successes + rate_limited == 15
    end

    test "does not send notification to dead process" do
      # Start with a different process
      {:ok, other_pid} = Task.start(fn -> Process.sleep(1000) end)
      {:ok, _state} = ProgressTracker.start_progress("dead_test", other_pid)

      # Kill the process
      Process.exit(other_pid, :kill)
      # Give it time to die
      Process.sleep(10)

      # Update should still succeed but not crash
      assert :ok = ProgressTracker.update_progress("dead_test", 50)

      # No notification should be received by current process
      refute_receive {:progress_notification, _}
    end
  end

  describe "complete_progress/1" do
    setup do
      sender_pid = self()
      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      %{sender_pid: sender_pid}
    end

    test "successfully completes and removes tracking state" do
      assert :ok = ProgressTracker.complete_progress(@valid_token)
      assert {:error, :not_found} = ProgressTracker.get_progress_state(@valid_token)
    end

    test "returns error for non-existent token" do
      assert {:error, :not_found} = ProgressTracker.complete_progress("nonexistent")
    end

    test "allows starting new tracking with same token after completion" do
      :ok = ProgressTracker.complete_progress(@valid_token)
      {:ok, _state} = ProgressTracker.start_progress(@valid_token, self())
    end
  end

  describe "get_progress_state/1" do
    setup do
      sender_pid = self()
      {:ok, state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      %{sender_pid: sender_pid, initial_state: state}
    end

    test "returns current state for existing token", %{initial_state: initial_state} do
      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.progress_token == initial_state.progress_token
      assert state.sender_pid == initial_state.sender_pid
      assert state.current_progress == initial_state.current_progress
    end

    test "returns updated state after progress update" do
      :ok = ProgressTracker.update_progress(@valid_token, 75, 200, "Updated message")

      {:ok, state} = ProgressTracker.get_progress_state(@valid_token)
      assert state.current_progress == 75
      assert state.total == 200
      assert state.last_message == "Updated message"
      assert state.notification_count == 1
    end

    test "returns error for non-existent token" do
      assert {:error, :not_found} = ProgressTracker.get_progress_state("nonexistent")
    end
  end

  describe "list_active_tokens/0" do
    test "returns empty list when no tokens are active" do
      assert ProgressTracker.list_active_tokens() == []
    end

    test "returns list of active tokens" do
      sender_pid = self()
      {:ok, _} = ProgressTracker.start_progress("token1", sender_pid)
      {:ok, _} = ProgressTracker.start_progress("token2", sender_pid)
      {:ok, _} = ProgressTracker.start_progress(123, sender_pid)

      tokens = ProgressTracker.list_active_tokens()
      assert length(tokens) == 3
      assert "token1" in tokens
      assert "token2" in tokens
      assert 123 in tokens
    end

    test "list updates when tokens are completed" do
      sender_pid = self()
      {:ok, _} = ProgressTracker.start_progress("token1", sender_pid)
      {:ok, _} = ProgressTracker.start_progress("token2", sender_pid)

      assert length(ProgressTracker.list_active_tokens()) == 2

      :ok = ProgressTracker.complete_progress("token1")

      tokens = ProgressTracker.list_active_tokens()
      assert length(tokens) == 1
      assert "token2" in tokens
      assert "token1" not in tokens
    end
  end

  describe "clear_all/0" do
    test "removes all active progress tracking" do
      sender_pid = self()
      {:ok, _} = ProgressTracker.start_progress("token1", sender_pid)
      {:ok, _} = ProgressTracker.start_progress("token2", sender_pid)

      assert length(ProgressTracker.list_active_tokens()) == 2

      :ok = ProgressTracker.clear_all()

      assert ProgressTracker.list_active_tokens() == []
      assert {:error, :not_found} = ProgressTracker.get_progress_state("token1")
      assert {:error, :not_found} = ProgressTracker.get_progress_state("token2")
    end
  end

  describe "MCP 2025-06-18 specification compliance" do
    setup do
      sender_pid = self()
      {:ok, _state} = ProgressTracker.start_progress(@valid_token, sender_pid)
      %{sender_pid: sender_pid}
    end

    test "progress tokens can be string or integer" do
      # String token already tested in setup
      sender_pid = self()
      {:ok, _} = ProgressTracker.start_progress(789, sender_pid)

      assert :ok = ProgressTracker.update_progress(789, 50)
      assert_receive {:progress_notification, notification}
      assert notification.progressToken == 789
    end

    test "progress values must increase" do
      :ok = ProgressTracker.update_progress(@valid_token, 10)
      :ok = ProgressTracker.update_progress(@valid_token, 20)
      :ok = ProgressTracker.update_progress(@valid_token, 30)

      # These should fail
      assert {:error, :not_increasing} = ProgressTracker.update_progress(@valid_token, 30)
      assert {:error, :not_increasing} = ProgressTracker.update_progress(@valid_token, 25)
    end

    test "progress and total values can be floating point" do
      :ok = ProgressTracker.update_progress(@valid_token, 33.33, 100.0)
      :ok = ProgressTracker.update_progress(@valid_token, 66.67, 100.0)

      assert_receive {:progress_notification, notification1}
      assert_receive {:progress_notification, notification2}

      assert notification1.progress == 33.33
      assert notification2.progress == 66.67
      assert notification1.total == 100.0
      assert notification2.total == 100.0
    end

    test "total value can be omitted" do
      :ok = ProgressTracker.update_progress(@valid_token, 25)

      assert_receive {:progress_notification, notification}
      assert notification.progress == 25
      assert not Map.has_key?(notification, :total)
    end

    test "message field provides human readable information" do
      :ok = ProgressTracker.update_progress(@valid_token, 25, 100, "Processing files...")
      :ok = ProgressTracker.update_progress(@valid_token, 50, 100, "Halfway complete")

      assert_receive {:progress_notification, notification1}
      assert_receive {:progress_notification, notification2}

      assert notification1.message == "Processing files..."
      assert notification2.message == "Halfway complete"
    end

    test "implements rate limiting to prevent flooding" do
      # The rate limit is 10 notifications per second
      # Send 15 rapid updates
      results = for i <- 1..15, do: ProgressTracker.update_progress(@valid_token, i)

      rate_limited_count = Enum.count(results, &(&1 == {:error, :rate_limited}))
      assert rate_limited_count > 0, "Rate limiting should prevent some notifications"
    end

    test "notification format matches MCP specification" do
      :ok = ProgressTracker.update_progress(@valid_token, 42, 100, "Test message")

      assert_receive {:progress_notification, notification}

      # Required fields
      assert Map.has_key?(notification, :progressToken)
      assert Map.has_key?(notification, :progress)

      # Optional fields when provided
      assert Map.has_key?(notification, :total)
      assert Map.has_key?(notification, :message)

      # Values match specification
      assert notification.progressToken == @valid_token
      assert notification.progress == 42
      assert notification.total == 100
      assert notification.message == "Test message"
    end

    test "notification format excludes optional fields when not provided" do
      :ok = ProgressTracker.update_progress(@valid_token, 25)

      assert_receive {:progress_notification, notification}

      # Required fields present
      assert Map.has_key?(notification, :progressToken)
      assert Map.has_key?(notification, :progress)

      # Optional fields not present
      assert not Map.has_key?(notification, :total)
      assert not Map.has_key?(notification, :message)
    end
  end
end
