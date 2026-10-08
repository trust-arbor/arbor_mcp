defmodule Arbor.MCP.ProgressTrackerMinimalTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.ProgressTracker

  setup do
    start_supervised!(ProgressTracker)
    :ok
  end

  test "basic progress tracker functionality" do
    # This is a minimal test to verify the ProgressTracker works
    # with explicit host supervision

    sender_pid = self()

    # Test that we can call functions without errors
    tokens = ProgressTracker.list_active_tokens()
    assert is_list(tokens)

    # Test basic start/complete cycle
    result = ProgressTracker.start_progress("test-token", sender_pid)

    case result do
      {:ok, _state} ->
        # Clean up
        ProgressTracker.complete_progress("test-token")
        assert true

      {:error, _reason} ->
        # ProgressTracker may not be started correctly
        flunk("ProgressTracker should be available when explicitly supervised")
    end
  end
end
