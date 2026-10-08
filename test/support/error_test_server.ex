defmodule Arbor.MCP.TestHelpers.ErrorTestServer do
  @moduledoc """
  Test server that always returns errors for testing error handling paths.

  Note: This module generates compiler warnings about unreachable clauses.
  This is expected because the DSL generates both success and error handling
  patterns, but this test server only ever returns errors. The warnings are
  benign and can be ignored.
  """
  use Arbor.MCP.Server.Handler

  @tools [
    %{name: "protocol_error", description: "Raises a protocol error", inputSchema: %{}},
    %{name: "transport_error", description: "Raises a transport error", inputSchema: %{}},
    %{name: "tool_error", description: "Raises a tool error", inputSchema: %{}},
    %{name: "resource_error", description: "Raises a resource error", inputSchema: %{}},
    %{name: "validation_error", description: "Raises a validation error", inputSchema: %{}},
    %{name: "generic_error", description: "Raises a generic error", inputSchema: %{}}
  ]

  @impl true
  def handle_initialize(params, state) do
    version = Map.get(params, "protocolVersion", "2025-03-26")

    {:ok,
     %{
       "protocolVersion" => version,
       "serverInfo" => %{"name" => "error-test-server", "version" => "1.0.0"},
       "capabilities" => %{"tools" => %{}, "resources" => %{}}
     }, state}
  end

  @impl true
  def handle_list_tools(_cursor, state), do: {:ok, @tools, nil, state}

  @impl true
  def handle_list_resources(_cursor, state) do
    resources = [
      %{
        uri: "error://test",
        name: "Test resource that errors",
        description: "A resource that always raises an error for testing"
      }
    ]

    {:ok, resources, nil, state}
  end

  @impl true
  def handle_call_tool(nil, _args, state) do
    # Handle nil tool name case
    {:error, "Missing tool name", state}
  end

  @impl true
  def handle_call_tool("protocol_error", _args, state) do
    # Return a protocol error with specific structure expected by tests
    error = %Arbor.MCP.Error.ProtocolError{
      code: -32602,
      message: "MCP Protocol Error (-32602): Invalid parameters",
      data: %{"field" => "name"}
    }

    {:error, error, state}
  end

  @impl true
  def handle_call_tool("transport_error", _args, state) do
    # Return a transport error with specific structure expected by tests
    error = %Arbor.MCP.Error.TransportError{
      transport: "stdio",
      reason: :connection_lost,
      details: %{"attempts" => 3}
    }

    {:error, error, state}
  end

  @impl true
  def handle_call_tool("tool_error", _args, state) do
    # Return a tool error with specific structure expected by tests
    error = %Arbor.MCP.Error.ToolError{
      tool_name: "test_tool",
      reason: "Tool execution failed",
      arguments: nil
    }

    {:error, error, state}
  end

  @impl true
  def handle_call_tool("resource_error", _args, state) do
    # Return a resource error with specific structure expected by tests
    error = %Arbor.MCP.Error.ResourceError{
      uri: "file:///test.txt",
      operation: :read,
      reason: "Permission denied"
    }

    {:error, error, state}
  end

  @impl true
  def handle_call_tool("validation_error", _args, state) do
    # Return a validation error with specific structure expected by tests
    error = %Arbor.MCP.Error.ValidationError{
      field: "validation_error",
      value: nil,
      reason: "Must be positive"
    }

    {:error, error, state}
  end

  @impl true
  def handle_call_tool("generic_error", _args, state) do
    # Return a generic error
    {:error, "Something went wrong", state}
  end

  @impl true
  def handle_read_resource("error://test", state) do
    {:error, "Resource not found", state}
  end

  # Add handlers that would never be called but satisfy pattern matching
  @impl true
  def handle_get_prompt(_prompt_name, _arguments, state) do
    {:error, :prompt_not_implemented, state}
  end

  @impl true
  def handle_subscribe_resource(_uri, state) do
    {:ok, %{}, state}
  end

  @impl true
  def handle_unsubscribe_resource(_uri, state) do
    {:ok, %{}, state}
  end
end
