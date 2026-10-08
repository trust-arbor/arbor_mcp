defmodule Arbor.MCP.ClientLogMessageTest do
  @moduledoc """
  Tests for the Client.log_message/3,4 functions added in Phase 2.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  describe "log_message/3,4 basic functionality" do
    test "functions exist with correct arity" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Client)
      assert function_exported?(Client, :log_message, 3)
      assert function_exported?(Client, :log_message, 4)
    end

    test "returns ok when not connected (notifications are fire-and-forget)" do
      {:ok, client} =
        GenServer.start_link(Client,
          transport: :test,
          _skip_connect: true
        )

      # Notifications should return :ok even when not connected
      assert :ok = Client.log_message(client, "info", "Test message")
      assert :ok = Client.log_message(client, "error", "Error message", %{code: 500})

      GenServer.stop(client)
    end

    test "accepts valid log levels" do
      {:ok, client} =
        GenServer.start_link(Client,
          transport: :test,
          _skip_connect: true
        )

      # Test all standard RFC 5424 log levels
      levels = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

      for level <- levels do
        assert :ok = Client.log_message(client, level, "Test message at #{level} level")
        assert :ok = Client.log_message(client, level, "Test message", %{level: level})
      end

      GenServer.stop(client)
    end

    test "handles different data types" do
      {:ok, client} =
        GenServer.start_link(Client,
          transport: :test,
          _skip_connect: true
        )

      # Test various data types
      assert :ok = Client.log_message(client, "info", "Message with map", %{key: "value"})
      assert :ok = Client.log_message(client, "info", "Message with list", ["item1", "item2"])
      assert :ok = Client.log_message(client, "info", "Message with nil", nil)
      assert :ok = Client.log_message(client, "info", "Message with string", "additional data")
      assert :ok = Client.log_message(client, "info", "Message with number", 42)

      GenServer.stop(client)
    end

    test "3-arity version calls 4-arity version with nil data" do
      {:ok, client} =
        GenServer.start_link(Client,
          transport: :test,
          _skip_connect: true
        )

      # Both should work and behave the same
      assert :ok = Client.log_message(client, "info", "Test message")
      assert :ok = Client.log_message(client, "info", "Test message", nil)

      GenServer.stop(client)
    end
  end

  describe "parameter validation" do
    test "requires binary level and message" do
      {:ok, client} =
        GenServer.start_link(Client,
          transport: :test,
          _skip_connect: true
        )

      # These should work
      assert :ok = Client.log_message(client, "info", "Valid message")
      assert :ok = Client.log_message(client, "error", "Valid message", %{})

      GenServer.stop(client)
    end
  end
end
