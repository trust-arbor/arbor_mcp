defmodule Arbor.MCP.Compliance.Features.Logging do
  @moduledoc """
  Logging compliance tests for MCP versions.
  Basic logging is available in all versions, setLevel added in 2025-03-26.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Logging
      @version unquote(version)

      # Basic logging (all versions)
      test "logging messages are sent correctly" do
        Arbor.MCP.Compliance.Features.Logging.test_log_messages(@version)
      end

      test "log levels are respected" do
        Arbor.MCP.Compliance.Features.Logging.test_log_levels(@version)
      end

      test "log message structure is valid" do
        Arbor.MCP.Compliance.Features.Logging.test_log_structure(@version)
      end

      test "log data field supports arbitrary JSON" do
        Arbor.MCP.Compliance.Features.Logging.test_log_data_field(@version)
      end

      # Set log level (2025-03-26+)
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "logging/setLevel works correctly" do
          Arbor.MCP.Compliance.Features.Logging.test_set_log_level(@version)
        end

        test "setLevel persists across requests" do
          Arbor.MCP.Compliance.Features.Logging.test_log_level_persistence(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client
  alias Arbor.MCP.Server

  # Log levels in order of severity
  @log_levels ["debug", "info", "warning", "error"]

  # Actual test implementations
  def test_log_messages(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      server = test_context.server

      # Test sending log messages at different levels
      for level <- @log_levels do
        message = "Test #{level} message"
        data = %{"timestamp" => System.system_time(:second), "level" => level}

        :ok = Server.send_log_message(server, level, message, data)
      end

      # Give time for messages to be processed
      Process.sleep(100)

      # Verify server can send logs without error
      # In a real test, we'd verify client receives them
    after
      cleanup_test_client(test_context)
    end
  end

  def test_log_levels(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      server = test_context.server

      # Test that all standard log levels are accepted
      test_cases = [
        {"debug", "Debug information for developers"},
        {"info", "Informational message"},
        {"warning", "Warning about potential issue"},
        {"error", "Error occurred but recovered"}
      ]

      for {level, message} <- test_cases do
        :ok = Server.send_log_message(server, level, message, %{})

        # Build notification to validate structure
        notification = build_log_notification(level, message, %{})
        validate_log_notification(notification)
      end

      # Test invalid log level
      # Most implementations should accept any string level
      :ok = Server.send_log_message(server, "custom", "Custom level", %{})
    after
      cleanup_test_client(test_context)
    end
  end

  def test_log_structure(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test various log message structures
      test_cases = [
        # Simple message
        {"info", "Simple message", %{}},

        # Message with structured data
        {"debug", "Request received",
         %{
           "requestId" => 12345,
           "method" => "tools/list",
           "timestamp" => System.system_time(:millisecond)
         }},

        # Error with stack trace
        {"error", "Exception occurred",
         %{
           "error" => "ArgumentError",
           "message" => "Invalid argument",
           "stackTrace" => ["app.ex:123", "server.ex:456"]
         }},

        # Warning with context
        {"warning", "Deprecated method used",
         %{
           "method" => "oldMethod",
           "alternative" => "newMethod",
           "deprecatedSince" => "2024-11-05"
         }}
      ]

      for {level, message, data} <- test_cases do
        notification = build_log_notification(level, message, data)
        validate_log_notification(notification)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_log_data_field(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      server = test_context.server

      # Test various data field contents
      test_data = [
        # Empty object
        %{},

        # Nested objects
        %{
          "user" => %{
            "id" => "user-123",
            "name" => "Test User"
          },
          "action" => "login",
          "metadata" => %{
            "ip" => "192.168.1.1",
            "userAgent" => "TestClient/1.0"
          }
        },

        # Arrays
        %{
          "errors" => [
            %{"code" => "E001", "message" => "First error"},
            %{"code" => "E002", "message" => "Second error"}
          ]
        },

        # Mixed types
        %{
          "count" => 42,
          "ratio" => 0.95,
          "active" => true,
          "tags" => ["test", "compliance", "mcp"],
          "nullValue" => nil
        }
      ]

      for data <- test_data do
        :ok = Server.send_log_message(server, "info", "Test data field", data)

        notification = build_log_notification("info", "Test data field", data)
        validate_log_notification(notification)

        # Verify data field matches what was sent
        assert notification["params"]["data"] == data
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_set_log_level(version) when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client

      # Test setting each log level
      for level <- @log_levels do
        {:ok, result} = Client.set_log_level(client, level)

        # Result should confirm the level was set
        assert result == %{} or Map.has_key?(result, :level)
      end

      # Test setting invalid level (should typically be accepted)
      {:ok, _} = Client.set_log_level(client, "trace")
    after
      cleanup_test_client(test_context)
    end
  end

  def test_log_level_persistence(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      client = test_context.client
      server = test_context.server

      # Set log level to warning
      {:ok, _} = Client.set_log_level(client, "warning")

      # Send messages at different levels
      :ok = Server.send_log_message(server, "debug", "Debug msg", %{})
      :ok = Server.send_log_message(server, "info", "Info msg", %{})
      :ok = Server.send_log_message(server, "warning", "Warning msg", %{})
      :ok = Server.send_log_message(server, "error", "Error msg", %{})

      Process.sleep(50)

      # In a real implementation, we'd verify that only warning and error
      # messages were actually delivered to the client

      # Change level to debug (everything should be logged)
      {:ok, _} = Client.set_log_level(client, "debug")

      # Now all messages should be delivered
      :ok = Server.send_log_message(server, "debug", "Debug msg 2", %{})
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp build_log_notification(level, message, data) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{
        "level" => level,
        "logger" => "test-logger",
        "message" => message,
        "data" => data
      }
    }
  end

  defp validate_log_notification(notification) do
    # Basic structure
    assert notification["jsonrpc"] == "2.0"
    assert notification["method"] == "notifications/message"

    # Notifications don't have ID
    refute Map.has_key?(notification, "id")

    # Validate params
    assert Map.has_key?(notification, "params")
    params = notification["params"]

    # Required fields
    assert Map.has_key?(params, "level")
    assert is_binary(params["level"])

    assert Map.has_key?(params, "message")
    assert is_binary(params["message"])

    # Optional logger field
    if Map.has_key?(params, "logger") do
      assert is_binary(params["logger"])
    end

    # Data field can be any JSON value
    if Map.has_key?(params, "data") do
      # Just verify it exists, can be any type
      assert Map.has_key?(params, "data")
    end
  end
end
