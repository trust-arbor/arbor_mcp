defmodule Arbor.MCP.Protocol.RequestTrackerTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.RequestTracker

  describe "init/0" do
    test "creates empty tracker state" do
      state = RequestTracker.init()

      assert state.pending_requests == %{}
      assert state.cancelled_requests == MapSet.new()
    end
  end

  describe "init_state/1" do
    test "adds tracker fields to existing state" do
      existing = %{foo: "bar", baz: 42}
      state = RequestTracker.init_state(existing)

      assert state.foo == "bar"
      assert state.baz == 42
      assert state.pending_requests == %{}
      assert state.cancelled_requests == MapSet.new()
    end

    test "does not overwrite existing tracker fields" do
      existing = %{
        pending_requests: %{"req-1" => {self(), :tag}},
        cancelled_requests: MapSet.new(["req-2"])
      }

      state = RequestTracker.init_state(existing)

      assert Map.has_key?(state.pending_requests, "req-1")
      assert MapSet.member?(state.cancelled_requests, "req-2")
    end
  end

  describe "track_request/3" do
    test "adds request to pending_requests" do
      state = RequestTracker.init()
      from = {self(), make_ref()}

      new_state = RequestTracker.track_request("req-123", from, state)

      assert new_state.pending_requests["req-123"] == from
    end

    test "overwrites existing request with same ID" do
      state = RequestTracker.init()
      from1 = {self(), make_ref()}
      from2 = {self(), make_ref()}

      state = RequestTracker.track_request("req-123", from1, state)
      new_state = RequestTracker.track_request("req-123", from2, state)

      assert new_state.pending_requests["req-123"] == from2
    end
  end

  describe "complete_request/2" do
    test "removes request from pending_requests" do
      from = {self(), make_ref()}
      state = RequestTracker.init()
      state = RequestTracker.track_request("req-123", from, state)

      new_state = RequestTracker.complete_request("req-123", state)

      refute Map.has_key?(new_state.pending_requests, "req-123")
    end

    test "handles non-existent request gracefully" do
      state = RequestTracker.init()
      new_state = RequestTracker.complete_request("req-123", state)

      assert new_state.pending_requests == %{}
    end
  end

  describe "cancel_request/2" do
    test "adds request to cancelled_requests" do
      state = RequestTracker.init()
      new_state = RequestTracker.cancel_request("req-123", state)

      assert MapSet.member?(new_state.cancelled_requests, "req-123")
    end

    test "handles duplicate cancellations" do
      state = RequestTracker.init()
      state = RequestTracker.cancel_request("req-123", state)
      state = RequestTracker.cancel_request("req-123", state)

      # Should still only have one entry
      assert MapSet.size(state.cancelled_requests) == 1
    end
  end

  describe "cancelled?/2" do
    test "returns true for cancelled requests" do
      state = RequestTracker.init()
      state = RequestTracker.cancel_request("req-123", state)

      assert RequestTracker.cancelled?("req-123", state)
    end

    test "returns false for non-cancelled requests" do
      state = RequestTracker.init()

      refute RequestTracker.cancelled?("req-123", state)
    end
  end

  describe "get_pending_request/2" do
    test "returns {:ok, from} for pending request" do
      from = {self(), make_ref()}
      state = RequestTracker.init()
      state = RequestTracker.track_request("req-123", from, state)

      assert {:ok, ^from} = RequestTracker.get_pending_request("req-123", state)
    end

    test "returns :error for non-existent request" do
      state = RequestTracker.init()

      assert :error = RequestTracker.get_pending_request("req-123", state)
    end
  end

  describe "get_pending_request_ids/1" do
    test "returns all pending request IDs" do
      state = RequestTracker.init()
      state = RequestTracker.track_request("req-1", {self(), :tag1}, state)
      state = RequestTracker.track_request("req-2", {self(), :tag2}, state)
      state = RequestTracker.track_request("req-3", {self(), :tag3}, state)

      ids = RequestTracker.get_pending_request_ids(state) |> Enum.sort()

      assert ids == ["req-1", "req-2", "req-3"]
    end

    test "returns empty list when no pending requests" do
      state = RequestTracker.init()

      assert RequestTracker.get_pending_request_ids(state) == []
    end
  end

  describe "handle_cancellation/2" do
    test "returns {:reply, from, state} for pending request" do
      from = {self(), make_ref()}
      state = RequestTracker.init()
      state = RequestTracker.track_request("req-123", from, state)

      {:reply, returned_from, new_state} = RequestTracker.handle_cancellation("req-123", state)

      assert returned_from == from
      assert RequestTracker.cancelled?("req-123", new_state)
      refute Map.has_key?(new_state.pending_requests, "req-123")
    end

    test "returns {:noreply, state} for non-pending request" do
      state = RequestTracker.init()

      {:noreply, new_state} = RequestTracker.handle_cancellation("req-123", state)

      assert RequestTracker.cancelled?("req-123", new_state)
    end

    test "handles already cancelled request" do
      state = RequestTracker.init()
      state = RequestTracker.cancel_request("req-123", state)

      {:noreply, new_state} = RequestTracker.handle_cancellation("req-123", state)

      assert RequestTracker.cancelled?("req-123", new_state)
    end
  end

  describe "process_if_not_cancelled/3" do
    test "returns {:ok, state} and tracks request when not cancelled" do
      state = RequestTracker.init()
      from = {self(), make_ref()}

      {:ok, new_state} = RequestTracker.process_if_not_cancelled("req-123", from, state)

      assert {:ok, ^from} = RequestTracker.get_pending_request("req-123", new_state)
    end

    test "returns {:cancelled, state} when request is already cancelled" do
      state = RequestTracker.init()
      state = RequestTracker.cancel_request("req-123", state)
      from = {self(), make_ref()}

      {:cancelled, unchanged_state} =
        RequestTracker.process_if_not_cancelled("req-123", from, state)

      assert unchanged_state == state
      refute Map.has_key?(unchanged_state.pending_requests, "req-123")
    end
  end

  describe "integration scenarios" do
    test "full request lifecycle - successful completion" do
      state = RequestTracker.init()
      from = {self(), make_ref()}

      # 1. Check if cancelled and track
      {:ok, state} = RequestTracker.process_if_not_cancelled("req-123", from, state)

      # 2. Verify it's tracked
      assert {:ok, ^from} = RequestTracker.get_pending_request("req-123", state)

      # 3. Complete the request
      state = RequestTracker.complete_request("req-123", state)

      # 4. Verify it's no longer pending
      assert :error = RequestTracker.get_pending_request("req-123", state)
    end

    test "full request lifecycle - cancelled while pending" do
      state = RequestTracker.init()
      from = {self(), make_ref()}

      # 1. Track the request
      state = RequestTracker.track_request("req-123", from, state)

      # 2. Cancel it while pending
      {:reply, returned_from, state} = RequestTracker.handle_cancellation("req-123", state)

      # 3. Verify correct from was returned for reply
      assert returned_from == from

      # 4. Verify it's marked as cancelled and not pending
      assert RequestTracker.cancelled?("req-123", state)
      assert :error = RequestTracker.get_pending_request("req-123", state)
    end

    test "multiple concurrent requests" do
      state = RequestTracker.init()

      # Track multiple requests
      state = state
      state = RequestTracker.track_request("req-1", {self(), :tag1}, state)
      state = RequestTracker.track_request("req-2", {self(), :tag2}, state)
      state = RequestTracker.track_request("req-3", {self(), :tag3}, state)

      # Cancel one
      state = RequestTracker.cancel_request("req-2", state)

      # Complete another
      state = RequestTracker.complete_request("req-1", state)

      # Check final state
      # Completed, so removed
      assert :error = RequestTracker.get_pending_request("req-1", state)
      # Cancelled but still pending
      assert {:ok, {_, :tag2}} = RequestTracker.get_pending_request("req-2", state)
      # Still pending
      assert {:ok, {_, :tag3}} = RequestTracker.get_pending_request("req-3", state)

      assert RequestTracker.cancelled?("req-2", state)
      refute RequestTracker.cancelled?("req-1", state)
      refute RequestTracker.cancelled?("req-3", state)

      assert RequestTracker.get_pending_request_ids(state) |> Enum.sort() == ["req-2", "req-3"]
    end
  end
end
