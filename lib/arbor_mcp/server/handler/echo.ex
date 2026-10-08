defmodule Arbor.MCP.Server.Handler.Echo do
  @moduledoc """
  This module provides ArborMCP extensions beyond the standard MCP specification.

  Simple echo handler for testing purposes.

  This handler echoes back tool calls and provides basic implementations
  for testing server functionality.
  """

  @behaviour Arbor.MCP.Server.Handler

  alias Arbor.MCP.Protocol.ErrorCodes

  @doc """
  Initializes the echo handler state.
  """
  def init(_args), do: {:ok, %{}}

  @doc """
  Terminates the echo handler.
  """
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_initialize(params, state) do
    # Echo back the protocol version sent by the client
    client_version = params["protocolVersion"] || "2025-06-18"

    {:ok,
     %{
       protocolVersion: client_version,
       serverInfo: %{
         name: "echo-server",
         version: "1.0.0"
       },
       capabilities: %{
         tools: %{listChanged: false},
         resources: %{listChanged: false, subscribe: false},
         prompts: %{listChanged: false},
         logging: %{},
         completions: %{},
         experimental: %{}
       }
     }, state}
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        name: "echo",
        description: "Echoes back the input",
        inputSchema: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Message to echo"}
          },
          required: ["message"]
        }
      }
    ]

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("echo", arguments, state) do
    message = Map.get(arguments, "message", "")

    result = %{
      "content" => [
        %{"type" => "text", "text" => "Echo: #{message}"}
      ]
    }

    {:ok, result, state}
  end

  def handle_call_tool(name, _arguments, state) do
    {:error, Arbor.MCP.Error.protocol_error(-32602, "Unknown tool: #{name}"), state}
  end

  @impl true
  def handle_list_resources(_cursor, state) do
    {:ok, [], nil, state}
  end

  @impl true
  def handle_read_resource(uri, state) do
    {:error,
     Arbor.MCP.Error.protocol_error(
       ErrorCodes.resource_not_found(:modern),
       "Resource not found: #{uri}"
     ), state}
  end

  @impl true
  def handle_list_prompts(_cursor, state) do
    {:ok, [], nil, state}
  end

  @impl true
  def handle_get_prompt(name, _arguments, state) do
    {:error, Arbor.MCP.Error.protocol_error(-32602, "Prompt not found: #{name}"), state}
  end

  @impl true
  def handle_list_resource_templates(_cursor, state) do
    {:ok, [], nil, state}
  end

  @impl true
  def handle_complete(_ref, _argument, state) do
    {:ok, %{completion: []}, state}
  end
end
