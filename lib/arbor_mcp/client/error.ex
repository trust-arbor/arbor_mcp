defmodule Arbor.MCP.Client.Error do
  @moduledoc """
  Enhanced error formatting and actionable guidance for MCP.

  This module transforms low-level MCP protocol errors into developer-friendly
  error messages with actionable guidance and debugging context.

  ## Features

  - Human-readable error descriptions
  - Actionable troubleshooting steps
  - Context preservation for debugging
  - Error categorization and severity levels
  - Common error pattern recognition

  ## Error Categories

  - **Connection**: Transport and connectivity issues
  - **Protocol**: MCP protocol violations or mismatches
  - **Authentication**: Auth and permission problems
  - **Resource**: Tool/resource/prompt related errors
  - **Timeout**: Request timeout and performance issues
  - **Validation**: Input validation and schema errors
  """

  @type error_category ::
          :connection
          | :protocol
          | :authentication
          | :resource
          | :timeout
          | :validation
          | :internal
          | :unknown

  @type error_severity :: :low | :medium | :high | :critical

  @type formatted_error :: %{
          type: atom(),
          category: error_category(),
          severity: error_severity(),
          message: String.t(),
          details: String.t() | nil,
          suggestions: [String.t()],
          context: map(),
          original_error: any()
        }

  @doc """
  Formats an error with enhanced context and actionable guidance.

  ## Examples

      Error.format(:tool_call_failed, :timeout, %{tool: "slow_tool", args: %{}})
      # => %{
      #   type: :tool_call_failed,
      #   category: :timeout,
      #   severity: :medium,
      #   message: "Tool call to 'slow_tool' timed out",
      #   suggestions: ["Increase timeout value", "Check tool performance"],
      #   context: %{tool: "slow_tool", args: %{}}
      # }
  """
  @spec format(atom(), any(), map()) :: formatted_error()
  def format(error_type, reason, context \\ %{})

  # Connection Errors
  def format(:connection_failed, reason, context) do
    %{
      type: :connection_failed,
      category: :connection,
      severity: determine_connection_severity(reason),
      message: format_connection_message(reason),
      details: format_connection_details(reason),
      suggestions: connection_suggestions(reason),
      context: context,
      original_error: reason
    }
  end

  def format(:transport_connect_failed, reason, context) do
    %{
      type: :transport_connect_failed,
      category: :connection,
      severity: :high,
      message: "Failed to connect to MCP server",
      details: format_transport_error(reason),
      suggestions: transport_suggestions(reason),
      context: context,
      original_error: reason
    }
  end

  def format(:all_transports_failed, _reason, context) do
    %{
      type: :all_transports_failed,
      category: :connection,
      severity: :critical,
      message: "All configured transports failed to connect",
      details: "None of the configured transport methods could establish a connection",
      suggestions: [
        "Check if the MCP server is running",
        "Verify network connectivity and firewall settings",
        "Review transport configuration (URLs, ports, commands)",
        "Try connecting with a single transport to isolate the issue",
        "Check server logs for startup errors"
      ],
      context: context,
      original_error: :all_transports_failed
    }
  end

  # Tool Errors
  def format(:tool_call_failed, reason, context) do
    tool_name = Map.get(context, :tool, "unknown")

    %{
      type: :tool_call_failed,
      category: :resource,
      severity: determine_tool_error_severity(reason),
      message: "Tool call to '#{tool_name}' failed",
      details: format_tool_error(reason),
      suggestions: tool_error_suggestions(reason, tool_name),
      context: context,
      original_error: reason
    }
  end

  def format(:tool_list_failed, reason, context) do
    %{
      type: :tool_list_failed,
      category: :resource,
      severity: :medium,
      message: "Failed to list available tools",
      details: format_generic_error(reason),
      suggestions: [
        "Check if the server supports tools",
        "Verify server capabilities during connection",
        "Try reconnecting to the server",
        "Check server logs for tool-related errors"
      ],
      context: context,
      original_error: reason
    }
  end

  # Resource Errors
  def format(:resource_read_failed, reason, context) do
    uri = Map.get(context, :uri, "unknown")

    %{
      type: :resource_read_failed,
      category: :resource,
      severity: :medium,
      message: "Failed to read resource '#{uri}'",
      details: format_resource_error(reason, uri),
      suggestions: resource_error_suggestions(reason, uri),
      context: context,
      original_error: reason
    }
  end

  def format(:resource_list_failed, reason, context) do
    %{
      type: :resource_list_failed,
      category: :resource,
      severity: :medium,
      message: "Failed to list available resources",
      details: format_generic_error(reason),
      suggestions: [
        "Check if the server supports resources",
        "Verify server capabilities",
        "Try reconnecting to the server"
      ],
      context: context,
      original_error: reason
    }
  end

  # Prompt Errors
  def format(:prompt_get_failed, reason, context) do
    prompt_name = Map.get(context, :prompt, "unknown")

    %{
      type: :prompt_get_failed,
      category: :resource,
      severity: :medium,
      message: "Failed to get prompt '#{prompt_name}'",
      details: format_prompt_error(reason),
      suggestions: prompt_error_suggestions(reason, prompt_name),
      context: context,
      original_error: reason
    }
  end

  def format(:prompt_list_failed, reason, context) do
    %{
      type: :prompt_list_failed,
      category: :resource,
      severity: :medium,
      message: "Failed to list available prompts",
      details: format_generic_error(reason),
      suggestions: [
        "Check if the server supports prompts",
        "Verify server capabilities",
        "Try reconnecting to the server"
      ],
      context: context,
      original_error: reason
    }
  end

  # Protocol Errors
  def format(:unexpected_response, reason, context) do
    %{
      type: :unexpected_response,
      category: :protocol,
      severity: :medium,
      message: "Received unexpected response format",
      details: "Expected: #{reason}, Got: #{inspect(context)}",
      suggestions: [
        "Check server protocol version compatibility",
        "Verify the server implements the expected MCP methods",
        "Review server logs for protocol errors",
        "Try with a different MCP client to isolate the issue"
      ],
      context: context,
      original_error: reason
    }
  end

  # Timeout Errors
  def format(:timeout, _reason, context) do
    %{
      type: :timeout,
      category: :timeout,
      severity: :medium,
      message: "Operation timed out",
      details: "The operation did not complete within the specified timeout period",
      suggestions: [
        "Increase the timeout value for this operation",
        "Check network connectivity and latency",
        "Verify the server is not overloaded",
        "Consider using async operations for long-running tasks"
      ],
      context: context,
      original_error: :timeout
    }
  end

  # Generic fallback
  def format(error_type, reason, context) do
    %{
      type: error_type,
      category: :unknown,
      severity: :medium,
      message: "Operation failed: #{error_type}",
      details: format_generic_error(reason),
      suggestions: [
        "Check the server logs for more information",
        "Verify the operation parameters",
        "Try the operation again",
        "Contact support if the issue persists"
      ],
      context: context,
      original_error: reason
    }
  end

  @doc """
  Creates a user-friendly error summary for display.
  """
  @spec summarize(formatted_error()) :: String.t()
  def summarize(%{message: message, details: nil}), do: message

  def summarize(%{message: message, details: details}) do
    "#{message}\n\nDetails: #{details}"
  end

  @doc """
  Gets troubleshooting suggestions for an error.
  """
  @spec get_suggestions(formatted_error()) :: [String.t()]
  def get_suggestions(%{suggestions: suggestions}), do: suggestions

  @doc """
  Formats suggestions as a readable list.
  """
  @spec format_suggestions([String.t()]) :: String.t()
  def format_suggestions([]), do: "No specific suggestions available."

  def format_suggestions(suggestions) do
    suggestions
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {suggestion, index} -> "#{index}. #{suggestion}" end)
  end

  # Private Implementation

  defp determine_connection_severity(:timeout), do: :medium
  defp determine_connection_severity(:connection_refused), do: :high
  defp determine_connection_severity(:network_unreachable), do: :high
  defp determine_connection_severity(_), do: :medium

  defp format_connection_message(:timeout), do: "Connection attempt timed out"
  defp format_connection_message(:connection_refused), do: "Connection refused by server"
  defp format_connection_message(:network_unreachable), do: "Network unreachable"
  defp format_connection_message(:closed), do: "Connection closed unexpectedly"
  defp format_connection_message(reason), do: "Connection failed: #{inspect(reason)}"

  defp format_connection_details(:timeout) do
    "The server did not respond within the timeout period. This could indicate server overload, network issues, or incorrect server configuration."
  end

  defp format_connection_details(:connection_refused) do
    "The server actively refused the connection. This usually means the server is not running on the specified port or is not accepting connections."
  end

  defp format_connection_details(:network_unreachable) do
    "The network route to the server could not be established. This indicates network infrastructure issues."
  end

  defp format_connection_details(_), do: nil

  defp connection_suggestions(:timeout) do
    [
      "Verify the server is running and responding",
      "Check network connectivity and latency",
      "Increase connection timeout value",
      "Verify firewall settings allow the connection"
    ]
  end

  defp connection_suggestions(:connection_refused) do
    [
      "Verify the server is running on the specified port",
      "Check if the server is accepting connections",
      "Verify the connection URL or command is correct",
      "Check firewall settings"
    ]
  end

  defp connection_suggestions(_) do
    [
      "Check server status and logs",
      "Verify connection parameters",
      "Test network connectivity",
      "Try with different transport if available"
    ]
  end

  defp format_transport_error({:transport_exception, {kind, reason}}) do
    "Transport exception (#{kind}): #{inspect(reason)}"
  end

  defp format_transport_error(reason), do: inspect(reason)

  defp transport_suggestions(:connection_refused) do
    [
      "Check if the MCP server is running",
      "Verify the server URL and port",
      "Check firewall and network settings",
      "Try a different transport method if available"
    ]
  end

  defp transport_suggestions(_) do
    [
      "Verify transport configuration",
      "Check server connectivity",
      "Review server startup logs",
      "Try connecting manually to debug"
    ]
  end

  defp determine_tool_error_severity(:timeout), do: :medium
  defp determine_tool_error_severity({:not_connected, _}), do: :high
  defp determine_tool_error_severity(_), do: :low

  defp format_tool_error(:timeout), do: "Tool execution timed out"
  defp format_tool_error({:not_connected, status}), do: "Client not connected (status: #{status})"
  defp format_tool_error(%{"error" => %{"message" => message}}), do: message
  defp format_tool_error(%{"message" => message}), do: message
  defp format_tool_error(reason), do: inspect(reason)

  defp tool_error_suggestions(:timeout, tool_name) do
    [
      "Increase timeout for tool '#{tool_name}'",
      "Check if the tool operation is computationally expensive",
      "Verify tool implementation performance",
      "Consider using async operations for long-running tools"
    ]
  end

  defp tool_error_suggestions({:not_connected, _}, _tool_name) do
    [
      "Check connection status",
      "Reconnect to the server",
      "Verify server is still running"
    ]
  end

  defp tool_error_suggestions(_reason, tool_name) do
    [
      "Verify tool '#{tool_name}' exists on the server",
      "Check tool arguments and schema requirements",
      "Review server logs for tool execution errors",
      "Test tool with minimal arguments"
    ]
  end

  defp format_resource_error(reason, uri) do
    case reason do
      :not_found -> "Resource '#{uri}' not found"
      :access_denied -> "Access denied to resource '#{uri}'"
      :timeout -> "Timeout reading resource '#{uri}'"
      _ -> format_generic_error(reason)
    end
  end

  defp resource_error_suggestions(:not_found, uri) do
    [
      "Verify the resource URI '#{uri}' is correct",
      "Check if the resource still exists",
      "List available resources to see what's available"
    ]
  end

  defp resource_error_suggestions(:access_denied, uri) do
    [
      "Check permissions for resource '#{uri}'",
      "Verify client authentication",
      "Contact server administrator for access"
    ]
  end

  defp resource_error_suggestions(_, _) do
    [
      "Check resource availability",
      "Verify resource URI format",
      "Review server resource configuration"
    ]
  end

  defp format_prompt_error(%{"error" => %{"message" => message}}), do: message
  defp format_prompt_error(reason), do: format_generic_error(reason)

  defp prompt_error_suggestions(_reason, prompt_name) do
    [
      "Verify prompt '#{prompt_name}' exists on the server",
      "Check prompt arguments and requirements",
      "List available prompts to see what's available",
      "Review server logs for prompt errors"
    ]
  end

  defp format_generic_error(reason) when is_binary(reason), do: reason
  defp format_generic_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_generic_error(reason), do: inspect(reason)
end
