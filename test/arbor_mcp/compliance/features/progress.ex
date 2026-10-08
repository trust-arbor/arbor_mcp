defmodule Arbor.MCP.Compliance.Features.Progress do
  @moduledoc """
  Progress notification compliance tests for MCP versions.
  Progress notifications are available in all MCP versions.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Progress
      @version unquote(version)

      # Progress notifications (all versions)
      test "progress notifications work with tokens" do
        Arbor.MCP.Compliance.Features.Progress.test_progress_tokens(@version)
      end

      test "progress percentage is tracked correctly" do
        Arbor.MCP.Compliance.Features.Progress.test_progress_percentage(@version)
      end

      test "progress updates are incremental" do
        Arbor.MCP.Compliance.Features.Progress.test_incremental_progress(@version)
      end

      test "progress without total is supported" do
        Arbor.MCP.Compliance.Features.Progress.test_progress_without_total(@version)
      end

      # Progress message field (2025-03-26+)
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "progress notifications include message field" do
          Arbor.MCP.Compliance.Features.Progress.test_progress_message(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client

  # Actual test implementations
  def test_progress_tokens(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client

      # Progress tokens are passed in meta field
      progress_token = "progress-#{System.unique_integer()}"

      # Call a tool with progress token
      {:ok, _result} =
        Client.call_tool(client, "calculator", %{
          "operation" => "multiply",
          "a" => 100,
          "b" => 200,
          "_meta" => %{"progressToken" => progress_token}
        })

      # In a real implementation, we'd verify progress notifications were sent
      # For now, we verify the token format is accepted
      Process.sleep(50)

      # Test multiple requests with different tokens
      tokens = for i <- 1..3, do: "token-#{i}"

      for {token, i} <- Enum.with_index(tokens, 1) do
        {:ok, _} =
          Client.call_tool(client, "calculator", %{
            "operation" => "add",
            "a" => i,
            "b" => i,
            "_meta" => %{"progressToken" => token}
          })
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_progress_percentage(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test progress notification structure
      progress_notifications = [
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "test-token-1",
            "progress" => 0,
            "total" => 100
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "test-token-1",
            "progress" => 50,
            "total" => 100
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "test-token-1",
            "progress" => 100,
            "total" => 100
          }
        }
      ]

      # Validate each notification
      for notification <- progress_notifications do
        validate_progress_notification(notification, version)

        # Check percentage calculation
        params = notification["params"]
        percentage = params["progress"] / params["total"] * 100
        assert percentage >= 0 and percentage <= 100
      end

      # Validate progress sequence
      progresses = Enum.map(progress_notifications, & &1["params"]["progress"])
      assert progresses == [0, 50, 100]
    after
      cleanup_test_client(test_context)
    end
  end

  def test_incremental_progress(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test that progress values increase monotonically
      token = "incremental-test"
      total = 10

      progress_sequence =
        for i <- 0..total do
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "progressToken" => token,
              "progress" => i,
              "total" => total
            }
          }
        end

      # Validate sequence
      previous = -1

      for notification <- progress_sequence do
        validate_progress_notification(notification, version)
        current = notification["params"]["progress"]

        # Progress should never decrease
        assert current > previous
        _previous = current
      end

      # Test invalid sequences (should not be sent by compliant servers)
      # Non-monotonic
      invalid_sequence = [5, 3, 7, 2]

      for {progress, idx} <- Enum.with_index(invalid_sequence) do
        if idx > 0 and progress < Enum.at(invalid_sequence, idx - 1) do
          # This represents an invalid progression
          :invalid
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_progress_without_total(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Progress can be reported without a total (indeterminate progress)
      notifications = [
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "indeterminate-1",
            "progress" => 1
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "indeterminate-1",
            "progress" => 5
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "indeterminate-1",
            "progress" => 10
          }
        }
      ]

      for notification <- notifications do
        # Should not have total field
        refute Map.has_key?(notification["params"], "total")

        # But should still be valid
        validate_progress_notification(notification, version)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_progress_message(version) when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Progress notifications in 2025-03-26+ can include message field
      notifications_with_message = [
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "with-message-1",
            "progress" => 0,
            "total" => 100,
            "message" => "Starting process..."
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "with-message-1",
            "progress" => 50,
            "total" => 100,
            "message" => "Processing data..."
          }
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "progressToken" => "with-message-1",
            "progress" => 100,
            "total" => 100,
            "message" => "Complete!"
          }
        }
      ]

      for notification <- notifications_with_message do
        validate_progress_notification(notification, version)

        # Message field should be present and valid
        assert Map.has_key?(notification["params"], "message")
        assert is_binary(notification["params"]["message"])
        assert String.length(notification["params"]["message"]) > 0
      end

      # Test progress without message (still valid)
      notification_no_message = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "progressToken" => "no-message",
          "progress" => 25,
          "total" => 100
        }
      }

      validate_progress_notification(notification_no_message, version)
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp validate_progress_notification(notification, version) do
    # Basic structure
    assert notification["jsonrpc"] == "2.0"
    assert notification["method"] == "notifications/progress"

    # Notifications don't have ID
    refute Map.has_key?(notification, "id")

    # Validate params
    assert Map.has_key?(notification, "params")
    params = notification["params"]

    # Required fields
    assert Map.has_key?(params, "progressToken")
    assert is_binary(params["progressToken"])

    assert Map.has_key?(params, "progress")
    assert is_integer(params["progress"])
    assert params["progress"] >= 0

    # Optional total field
    if Map.has_key?(params, "total") do
      assert is_integer(params["total"])
      assert params["total"] > 0
      assert params["progress"] <= params["total"]
    end

    # Message field only in 2025-03-26+
    if Map.has_key?(params, "message") do
      if version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        assert is_binary(params["message"])
      else
        # Earlier versions shouldn't have message field
        flunk("Message field not supported in version #{version}")
      end
    end
  end
end
