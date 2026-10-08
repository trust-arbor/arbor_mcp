defmodule Arbor.MCP.Integration.TelemetryTest do
  @moduledoc """
  Integration tests for telemetry events across the system.
  """

  use ExUnit.Case, async: true
  require Logger

  alias Arbor.MCP.Protocol.RequestProcessor
  alias Arbor.MCP.TestHelpers

  describe "telemetry integration" do
    test "emits events for complete request lifecycle" do
      # Set up telemetry handler
      events_ref = make_ref()
      events_pid = self()

      handler_id = "test-handler-#{inspect(events_ref)}"

      events = [
        [:arbor_mcp, :request, :start],
        [:arbor_mcp, :request, :stop],
        [:arbor_mcp, :tool, :start],
        [:arbor_mcp, :tool, :stop]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(events_pid, {events_ref, event, measurements, metadata})
        end,
        nil
      )

      # Make a tool call
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{}
        }
      }

      response = process_request(TestHelpers.RefactoredTestServer, request)

      # Wait for events — match on specific metadata fields to avoid picking up
      # telemetry events from concurrent async tests (telemetry handlers are global)
      assert_receive {^events_ref, [:arbor_mcp, :request, :start], measurements,
                      %{request_id: "1", method: "tools/call"}}

      assert measurements.system_time

      assert_receive {^events_ref, [:arbor_mcp, :tool, :start], measurements,
                      %{tool_name: "test_tool", request_id: "1"}}

      assert measurements.system_time

      assert_receive {^events_ref, [:arbor_mcp, :tool, :stop], measurements,
                      %{tool_name: "test_tool", status: :ok}}

      assert measurements.duration > 0

      assert_receive {^events_ref, [:arbor_mcp, :request, :stop], measurements,
                      %{request_id: "1", status: :ok}}

      assert measurements.duration > 0

      # Clean up
      :telemetry.detach(handler_id)

      # Verify response
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Tool executed"}]
    end

    test "emits events for resource operations" do
      # Set up telemetry handler
      events_ref = make_ref()
      events_pid = self()

      handler_id = "test-handler-#{inspect(events_ref)}"

      events = [
        [:arbor_mcp, :resource, :read, :start],
        [:arbor_mcp, :resource, :read, :stop]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(events_pid, {events_ref, event, measurements, metadata})
        end,
        nil
      )

      # Make a resource read
      request = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "id" => 2,
        "params" => %{
          "uri" => "test://resource"
        }
      }

      response = process_request(TestHelpers.RefactoredTestServer, request)

      # Wait for events — match on specific metadata to avoid cross-test interference
      assert_receive {^events_ref, [:arbor_mcp, :resource, :read, :start], measurements,
                      %{uri: "test://resource", request_id: "2"}}

      assert measurements.system_time

      assert_receive {^events_ref, [:arbor_mcp, :resource, :read, :stop], measurements,
                      %{uri: "test://resource", status: :ok}}

      assert measurements.duration > 0

      # Clean up
      :telemetry.detach(handler_id)

      # Verify response
      assert [%{"text" => "Resource content"}] = response["result"]["contents"]
    end

    test "emits exception events on errors", %{} do
      # Set up telemetry handler
      events_ref = make_ref()
      events_pid = self()

      handler_id = "test-handler-#{inspect(events_ref)}"

      events = [
        [:arbor_mcp, :request, :start],
        [:arbor_mcp, :request, :stop],
        [:arbor_mcp, :tool, :start],
        [:arbor_mcp, :tool, :stop]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(events_pid, {events_ref, event, measurements, metadata})
        end,
        nil
      )

      # Make a tool call that will error (use a non-generic error)
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 3,
        "params" => %{
          "name" => "tool_error",
          "arguments" => %{}
        }
      }

      response = process_request(TestHelpers.ErrorTestServer, request)

      # Wait for events — match on specific metadata to avoid cross-test interference
      assert_receive {^events_ref, [:arbor_mcp, :request, :start], _measurements,
                      %{request_id: "3", method: "tools/call"}}

      assert_receive {^events_ref, [:arbor_mcp, :tool, :start], _measurements,
                      %{tool_name: "tool_error", request_id: "3"}}

      assert_receive {^events_ref, [:arbor_mcp, :tool, :stop], _measurements,
                      %{tool_name: "tool_error", status: :error}}

      assert_receive {^events_ref, [:arbor_mcp, :request, :stop], _measurements,
                      %{request_id: "3", status: :error}}

      # Clean up
      :telemetry.detach(handler_id)

      # Verify error response
      assert response["error"]["code"] == -32000
    end
  end

  describe "telemetry span helper" do
    test "span/3 correctly emits start and stop events" do
      events_ref = make_ref()
      events_pid = self()

      handler_id = "test-handler-#{inspect(events_ref)}"

      events = [
        [:test, :operation, :start],
        [:test, :operation, :stop]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(events_pid, {events_ref, event, measurements, metadata})
        end,
        nil
      )

      result =
        Arbor.MCP.Telemetry.span([:test, :operation], %{id: "test-123"}, fn ->
          Process.sleep(10)
          {:ok, "success"}
        end)

      assert {:ok, "success"} = result

      assert_receive {^events_ref, [:test, :operation, :start], measurements, metadata}
      assert measurements.system_time
      assert metadata.id == "test-123"

      assert_receive {^events_ref, [:test, :operation, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.id == "test-123"
      assert metadata.status == :ok

      # Clean up
      :telemetry.detach(handler_id)
    end

    test "span/3 correctly emits exception events on error" do
      events_ref = make_ref()
      events_pid = self()

      handler_id = "test-handler-#{inspect(events_ref)}"

      events = [
        [:test, :operation, :start],
        [:test, :operation, :exception]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(events_pid, {events_ref, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, "test error", fn ->
        Arbor.MCP.Telemetry.span([:test, :operation], %{id: "test-456"}, fn ->
          raise "test error"
        end)
      end

      assert_receive {^events_ref, [:test, :operation, :start], _measurements, _metadata}
      assert_receive {^events_ref, [:test, :operation, :exception], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.id == "test-456"
      assert metadata.kind == :error
      assert %RuntimeError{message: "test error"} = metadata.error
      assert is_list(metadata.stacktrace)

      # Clean up
      :telemetry.detach(handler_id)
    end
  end

  defp process_request(module, request) do
    Code.ensure_compiled!(module)

    case RequestProcessor.process(request, %{__module__: module}) do
      {:response, response, _state} -> response
      {:notification, _state} -> :ok
    end
  end
end
