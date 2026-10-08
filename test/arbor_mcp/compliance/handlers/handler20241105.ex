defmodule Arbor.MCP.Compliance.Handlers.Handler20241105 do
  @moduledoc """
  Test handler for MCP 2024-11-05 specification compliance.

  Implements all features available in the 2024-11-05 version including:
  - Basic features: tools, resources, prompts, logging
  - Progress notifications and cancellation
  - Resource templates
  - Client capabilities: roots, sampling
  """
  use Arbor.MCP.Server.Handler

  @impl true
  def init(_args) do
    {:ok,
     %{
       tools: [
         %{
           name: "calculator",
           description: "Basic arithmetic operations",
           inputSchema: %{
             type: "object",
             properties: %{
               operation: %{type: "string", enum: ["add", "subtract", "multiply", "divide"]},
               a: %{type: "number"},
               b: %{type: "number"}
             },
             required: ["operation", "a", "b"]
           }
         }
       ],
       resources: [
         %{
           uri: "file:///config.json",
           name: "Configuration",
           description: "System configuration",
           mimeType: "application/json"
         }
       ],
       resource_templates: [
         %{
           uriTemplate: "file:///{path}",
           name: "Project Files",
           description: "Access files in the project directory",
           mimeType: "application/octet-stream"
         }
       ],
       prompts: [
         %{
           name: "code-review",
           description: "Review code for best practices",
           arguments: [
             %{name: "language", description: "Programming language", required: true}
           ]
         }
       ],
       roots: [
         %{uri: "file:///test", name: "Test"},
         %{uri: "file:///another"}
       ]
     }}
  end

  @impl true
  def handle_initialize(_params, state) do
    # Expecting 2024-11-05 version
    # Note: Don't assert in handler, let tests handle validation

    result = %{
      protocolVersion: "2024-11-05",
      serverInfo: %{
        name: "test-server-2024-11-05",
        version: "1.0.0"
      },
      capabilities: %{
        # 2024-11-05 capabilities (no listChanged, no subscribe)
        tools: %{},
        resources: %{},
        prompts: %{},
        logging: %{}
      }
    }

    {:ok, result, state}
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    {:ok, state.tools, nil, state}
  end

  @impl true
  def handle_call_tool("calculator", %{"operation" => op, "a" => a, "b" => b}, state) do
    result =
      case op do
        "add" -> a + b
        "subtract" -> a - b
        "multiply" -> a * b
        "divide" when b != 0 -> a / b
        "divide" -> {:error, "Division by zero"}
      end

    case result do
      {:error, msg} ->
        {:error, msg, state}

      value ->
        {:ok, [%{type: "text", text: "Result: #{value}"}], state}
    end
  end

  @impl true
  def handle_call_tool(name, _arguments, state) do
    {:error, "Tool not found: #{name}", state}
  end

  @impl true
  def handle_list_resources(_cursor, state) do
    {:ok, state.resources, nil, state}
  end

  @impl true
  def handle_read_resource("file:///config.json", state) do
    content = %{
      version: "1.0.0",
      features: %{
        logging: true,
        metrics: false
      }
    }

    {:ok,
     %{
       uri: "file:///config.json",
       mimeType: "application/json",
       text: Jason.encode!(content)
     }, state}
  end

  @impl true
  def handle_list_prompts(_cursor, state) do
    {:ok, state.prompts, nil, state}
  end

  @impl true
  def handle_get_prompt("code-review", %{"language" => lang}, state) do
    {:ok,
     %{
       description: "Review #{lang} code",
       messages: [
         %{
           role: "user",
           content: %{
             type: "text",
             text: "Please review this #{lang} code for best practices."
           }
         }
       ]
     }, state}
  end

  # Resource templates support (2024-11-05 feature)
  @impl true
  def handle_list_resource_templates(_cursor, state) do
    {:ok, state.resource_templates, nil, state}
  end

  # Roots support (client feature in 2024-11-05)
  @impl true
  def handle_list_roots(state) do
    {:ok, state.roots, state}
  end

  # Sampling support (client feature in 2024-11-05)
  @impl true
  def handle_create_message(params, state) do
    # Extract messages and model preferences from params
    messages = Map.get(params, "messages", [])
    model_preferences = Map.get(params, "modelPreferences", %{})

    # Simulate processing a sampling request
    case messages do
      [%{"role" => "user", "content" => %{"text" => text}}] ->
        response = %{
          "role" => "assistant",
          "content" => %{
            "type" => "text",
            "text" => "Mock response to: #{text}"
          },
          "model" => Map.get(model_preferences, "hints", ["mock-model"]) |> List.first(),
          "stopReason" => "endTurn"
        }

        {:ok, response, state}

      _ ->
        {:error, "Invalid message format", state}
    end
  end

  # Methods not available in 2024-11-05
  @impl true
  def handle_subscribe_resource(_uri, state) do
    {:error, "Resource subscriptions not available in 2024-11-05", state}
  end

  @impl true
  def handle_complete(_ref, _arg, state) do
    {:error, "Completion not available in 2024-11-05", state}
  end

  @impl true
  def handle_set_log_level(_level, state) do
    {:error, "Log level control not available in 2024-11-05", state}
  end
end
