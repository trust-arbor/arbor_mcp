defmodule Arbor.MCP.Compliance.Handlers.Handler20250618 do
  @moduledoc """
  Test handler for MCP 2025-06-18 specification compliance.

  Implements all features available in the 2025-06-18 version including:
  - All features from 2025-03-26
  - New in 2025-06-18:
    - Title fields for tools, resources, and prompts
    - Structured output for tools (outputSchema)
    - Structured content in tool responses
    - Resource links in tool responses
    - Elicitation (moved from draft to stable)
    - Enhanced completion with context
    - MCP-Protocol-Version header requirement
  """
  use Arbor.MCP.Server.Handler

  @impl GenServer
  def init(args) do
    args_map = Enum.into(args, %{})

    {:ok,
     Map.merge(
       %{
         tools: [
           %{
             name: "calculate",
             # New title field
             title: "Calculator Tool",
             description: "Performs calculations",
             inputSchema: %{
               type: "object",
               properties: %{
                 expression: %{type: "string"}
               },
               required: ["expression"]
             },
             # New in 2025-06-18
             outputSchema: %{
               type: "object",
               properties: %{
                 result: %{type: "number"},
                 explanation: %{type: "string"}
               }
             }
           }
         ],
         resources: %{
           "file://example.txt" => %{
             uri: "file://example.txt",
             # New title field
             title: "Example File",
             # Programmatic name
             name: "example",
             description: "An example file",
             mimeType: "text/plain"
           }
         },
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
             name: "summarize",
             # New title field
             title: "Text Summarizer",
             description: "Summarizes text",
             arguments: [
               %{name: "text", description: "Text to summarize", required: true}
             ]
           }
         ],
         roots: [
           %{uri: "file:///test", name: "Test"},
           %{uri: "file:///another"}
         ],
         subscriptions: MapSet.new(),
         log_level: "info"
       },
       args_map
     )}
  end

  @impl true
  def handle_initialize(_params, state) do
    # Note: Don't assert in handler, let tests handle validation

    result = %{
      protocolVersion: "2025-06-18",
      serverInfo: %{
        name: "test-server-2025-06-18",
        version: "3.0.0"
      },
      capabilities: %{
        # 2025-06-18 capabilities (no batch support)
        tools: %{listChanged: true, outputSchema: true},
        resources: %{
          subscribe: true,
          listChanged: true
        },
        prompts: %{listChanged: true},
        logging: %{setLevel: true},
        completion: %{
          hasArguments: true,
          values: true
        },
        experimental: %{
          elicitation: true,
          structuredContent: true
        }
      }
    }

    {:ok, result, state}
  end

  @impl true
  def handle_list_tools(cursor, state) do
    if cursor == nil do
      {:ok, state.tools, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  @impl true
  def handle_call_tool("calculate", %{"expression" => expr}, state) do
    # Return both content and structured output
    result = %{
      content: [
        %{type: "text", text: "Result: 42"}
      ],
      # 2025-06-18 feature: structured output
      structuredContent: %{
        "result" => 42,
        "explanation" => "Calculated #{expr}"
      },
      # 2025-06-18 feature: resource links
      resourceLinks: [
        %{
          "uri" => "math://calculation/123",
          "title" => "Calculation Details"
        }
      ]
    }

    {:ok, result, state}
  end

  @impl true
  def handle_call_tool(name, _arguments, state) do
    {:error, "Tool not found: #{name}", state}
  end

  @impl true
  def handle_list_resources(cursor, state) do
    resources = Map.values(state.resources)

    if cursor == nil do
      {:ok, resources, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  @impl true
  def handle_read_resource(uri, state) do
    case Map.get(state.resources, uri) do
      nil ->
        {:error, "Resource not found: #{uri}", state}

      resource ->
        content = %{
          uri: uri,
          mimeType: resource.mimeType,
          text: "Example content"
        }

        {:ok, content, state}
    end
  end

  @impl true
  def handle_subscribe_resource(uri, state) do
    if Map.has_key?(state.resources, uri) do
      new_state = %{state | subscriptions: MapSet.put(state.subscriptions, uri)}
      {:ok, %{}, new_state}
    else
      {:error, "Resource not found or not subscribable: #{uri}", state}
    end
  end

  @impl true
  def handle_unsubscribe_resource(uri, state) do
    if Map.has_key?(state.resources, uri) do
      new_state = %{state | subscriptions: MapSet.delete(state.subscriptions, uri)}
      {:ok, %{}, new_state}
    else
      {:error, "Resource not found: #{uri}", state}
    end
  end

  @impl true
  def handle_list_prompts(cursor, state) do
    if cursor == nil do
      {:ok, state.prompts, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  @impl true
  def handle_get_prompt("summarize", args, state) do
    {:ok,
     %{
       messages: [
         %{
           role: "user",
           content: %{
             type: "text",
             text: "Summarize: #{args["text"]}"
           }
         }
       ]
     }, state}
  end

  @impl true
  def handle_get_prompt(name, _args, state) do
    {:error, "Prompt not found: #{name}", state}
  end

  # Resource templates support
  @impl true
  def handle_list_resource_templates(cursor, state) do
    if cursor == nil do
      {:ok, state.resource_templates, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  # Roots support
  @impl true
  def handle_list_roots(state) do
    {:ok, state.roots, state}
  end

  # Sampling support
  @impl true
  def handle_create_message(params, state) do
    messages = Map.get(params, "messages", [])
    model_preferences = Map.get(params, "modelPreferences", %{})

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

  # Completion support (enhanced in 2025-06-18)
  @impl true
  def handle_complete("argument", %{"name" => "text", "value" => prefix} = args, state) do
    # Check for context in meta
    context = get_in(args, ["_meta", "context"]) || %{}

    completions =
      if Map.has_key?(context, "previousValue") do
        # Use context to provide better completions
        ["#{prefix} completion with context"]
      else
        ["#{prefix} completion"]
      end

    # Return structured output format for 2025-06-18
    {:ok,
     %{
       structuredOutput: %{
         "completion" => completions
       }
     }, state}
  end

  @impl true
  def handle_complete("argument", %{"name" => name, "value" => prefix}, state) do
    # Generic argument completion
    completions =
      case name do
        "path" -> ["/home/user/", "/var/log/", "/tmp/"]
        "language" -> ["python", "javascript", "ruby", "go"]
        _ -> ["#{prefix}_suggestion"]
      end

    filtered = Enum.filter(completions, &String.starts_with?(&1, prefix))
    {:ok, %{completion: filtered}, state}
  end

  @impl true
  def handle_complete(_ref, _arg, state) do
    {:error, "Completion not supported for this reference", state}
  end

  # Log level control
  @impl true
  def handle_set_log_level(level, state) when level in ["debug", "info", "warning", "error"] do
    {:ok, %{state | log_level: level}}
  end

  @impl true
  def handle_set_log_level(_level, state) do
    {:error, "Invalid log level", state}
  end
end
