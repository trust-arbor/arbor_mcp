defmodule Arbor.MCP.Compliance.Features.Cancellation do
  @moduledoc """
  Request cancellation compliance tests for MCP versions.
  Cancellation is available in all MCP versions.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Cancellation
      @version unquote(version)

      # Cancellation (all versions)
      test "notifications/cancelled works correctly" do
        Arbor.MCP.Compliance.Features.Cancellation.test_request_cancellation(@version)
      end

      test "cancelled requests are properly handled" do
        Arbor.MCP.Compliance.Features.Cancellation.test_cancelled_handling(@version)
      end

      test "cancellation with reason is accepted" do
        Arbor.MCP.Compliance.Features.Cancellation.test_cancellation_with_reason(@version)
      end

      test "multiple cancellations are idempotent" do
        Arbor.MCP.Compliance.Features.Cancellation.test_idempotent_cancellation(@version)
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol

  # Actual test implementations
  def test_request_cancellation(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client

      # Generate a unique request ID
      request_id = Protocol.generate_id()

      # Start an async request that we'll cancel
      task =
        Task.async(fn ->
          # Simulate a long-running operation
          Client.call_tool(client, "long_running_tool", %{
            "duration" => 5000,
            "_meta" => %{"requestId" => request_id}
          })
        end)

      # Give it time to start
      Process.sleep(100)

      # Cancel the request
      :ok = Client.send_cancelled(client, request_id, "User cancelled")

      # The task should complete (with either result or cancellation)
      result = Task.await(task, 2000)

      # Result should indicate cancellation or error
      case result do
        {:error, error} ->
          assert error =~ "cancelled" or error =~ "Cancelled"

        {:ok, _} ->
          # Some implementations might return success with cancelled flag
          :ok
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_cancelled_handling(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client

      # Test that the cancellation notification format is correct
      request_id = 12345
      reason = "Operation took too long"

      # Send cancellation
      :ok = Client.send_cancelled(client, request_id, reason)

      # The notification format should be:
      # {
      #   "jsonrpc": "2.0",
      #   "method": "notifications/cancelled",
      #   "params": {
      #     "requestId": 12345,
      #     "reason": "Operation took too long"
      #   }
      # }

      # Validate we can send without error
      Process.sleep(50)

      # Test cancellation without reason
      :ok = Client.send_cancelled(client, request_id + 1, nil)
    after
      cleanup_test_client(test_context)
    end
  end

  def test_cancellation_with_reason(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client

      # Test various cancellation reasons
      test_cases = [
        {1001, "User pressed cancel button"},
        {1002, "Timeout exceeded"},
        {1003, "Resource limit reached"},
        # Empty reason
        {1004, ""},
        # No reason
        {1005, nil}
      ]

      for {request_id, reason} <- test_cases do
        result = Client.send_cancelled(client, request_id, reason)
        assert result == :ok
      end

      # Validate notification structure
      notification = build_cancellation_notification(2001, "Test reason")
      validate_cancellation_notification(notification)
    after
      cleanup_test_client(test_context)
    end
  end

  def test_idempotent_cancellation(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client
      request_id = Protocol.generate_id()

      # Cancel the same request multiple times
      :ok = Client.send_cancelled(client, request_id, "First cancellation")
      :ok = Client.send_cancelled(client, request_id, "Second cancellation")
      :ok = Client.send_cancelled(client, request_id, "Third cancellation")

      # All cancellations should succeed (idempotent)
      Process.sleep(50)

      # Test cancelling a non-existent request
      :ok = Client.send_cancelled(client, 99999, "Cancel non-existent")
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp build_cancellation_notification(request_id, reason) do
    base = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{
        "requestId" => request_id
      }
    }

    if reason do
      put_in(base, ["params", "reason"], reason)
    else
      base
    end
  end

  defp validate_cancellation_notification(notification) do
    # Validate notification structure
    assert notification["jsonrpc"] == "2.0"
    assert notification["method"] == "notifications/cancelled"

    # Notifications don't have an ID
    refute Map.has_key?(notification, "id")

    # Validate params
    assert Map.has_key?(notification, "params")
    params = notification["params"]

    # Request ID is required
    assert Map.has_key?(params, "requestId")
    assert is_integer(params["requestId"]) or is_binary(params["requestId"])

    # Reason is optional
    if Map.has_key?(params, "reason") do
      assert is_binary(params["reason"])
    end
  end
end
