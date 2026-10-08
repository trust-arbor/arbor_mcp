defmodule Arbor.MCP.Compliance.Handlers.Handler20250326 do
  @moduledoc """
  Test handler for MCP 2025-03-26 specification compliance.

  Implements all features available in the 2025-03-26 version including:
  - Basic features: tools, resources, prompts, logging
  - Progress notifications and cancellation
  - Resource templates, roots, sampling
  - New in 2025-03-26:
    - Tool annotations
    - Audio content type
    - Resource subscriptions
    - List change notifications
    - Completion capability
    - Log level control (setLevel)
    - JSON-RPC batching support
  """
  use Arbor.MCP.Server.Handler

  @impl true
  def init(_args) do
    {:ok,
     %{
       tools: [
         %{
           name: "file_write",
           description: "Write content to a file",
           inputSchema: %{
             type: "object",
             properties: %{
               path: %{type: "string"},
               content: %{type: "string"}
             },
             required: ["path", "content"]
           },
           # Tool annotations new in 2025-03-26
           annotations: %{
             destructiveHint: true,
             idempotentHint: false,
             readOnlyHint: false,
             openWorldHint: false
           }
         },
         %{
           name: "file_read",
           description: "Read content from a file",
           inputSchema: %{
             type: "object",
             properties: %{
               path: %{type: "string"}
             },
             required: ["path"]
           },
           annotations: %{
             destructiveHint: false,
             idempotentHint: true,
             readOnlyHint: true,
             openWorldHint: false
           }
         }
       ],
       resources: %{
         "config://app" => %{
           uri: "config://app",
           name: "Application Config",
           description: "Application configuration",
           mimeType: "application/json"
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
           name: "analyze-code",
           description: "Analyze code with AI",
           arguments: [
             %{name: "language", description: "Programming language", required: true},
             %{name: "framework", description: "Framework used", required: false}
           ]
         }
       ],
       roots: [
         %{uri: "file:///test", name: "Test"},
         %{uri: "file:///another"}
       ],
       subscriptions: MapSet.new(),
       log_level: "info"
     }}
  end

  @impl true
  def handle_initialize(_params, state) do
    # Note: Don't assert in handler, let tests handle validation

    result = %{
      protocolVersion: "2025-03-26",
      serverInfo: %{
        name: "test-server-2025-03-26",
        version: "2.0.0"
      },
      capabilities: %{
        # 2025-03-26 capabilities
        tools: %{listChanged: true},
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
          batchProcessing: true
        }
      }
    }

    {:ok, result, state}
  end

  @impl true
  def handle_list_tools(cursor, state) do
    # Support pagination
    if cursor == nil do
      {:ok, state.tools, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  @impl true
  def handle_call_tool("file_write", %{"path" => path, "content" => content}, state) do
    # Simulate file write with progress
    progress_token = get_in(state, [:current_request, :progress_token])

    if progress_token do
      # Send progress notifications
      send(self(), {:notify_progress, progress_token, 50, 100, "Writing file..."})
    end

    # Return both text and audio content (new in 2025-03-26)
    result = [
      %{type: "text", text: "Wrote #{byte_size(content)} bytes to #{path}"},
      %{
        type: "audio",
        data: Base.encode64("fake-audio-data"),
        mimeType: "audio/mp3"
      }
    ]

    {:ok, result, state}
  end

  @impl true
  def handle_call_tool("file_read", %{"path" => path}, state) do
    content = "Sample content from #{path}"
    {:ok, [%{type: "text", text: content}], state}
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
          text: Jason.encode!(%{debug: true, version: "2.0"})
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
      {:error, "Resource not found: #{uri}", state}
    end
  end

  @impl true
  def handle_unsubscribe_resource(uri, state) do
    new_state = %{state | subscriptions: MapSet.delete(state.subscriptions, uri)}
    {:ok, %{}, new_state}
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
  def handle_get_prompt("analyze-code", args, state) do
    lang = args["language"]
    framework = args["framework"] || "none"

    {:ok,
     %{
       description: "Analyze #{lang} code using #{framework}",
       messages: [
         %{
           role: "system",
           content: %{
             type: "text",
             text: "You are a code analyzer for #{lang}."
           }
         },
         %{
           role: "user",
           content: %{
             type: "text",
             text: "Analyze this code for best practices."
           }
         }
       ]
     }, state}
  end

  # Resource templates support (available in 2025-03-26)
  @impl true
  def handle_list_resource_templates(cursor, state) do
    if cursor == nil do
      {:ok, state.resource_templates, nil, state}
    else
      {:ok, [], nil, state}
    end
  end

  # Roots support (client feature)
  @impl true
  def handle_list_roots(state) do
    {:ok, state.roots, state}
  end

  # Sampling support (client feature)
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

  # Completion support (new in 2025-03-26)
  @impl true
  def handle_complete("argument", %{"name" => "path", "value" => prefix}, state) do
    # Provide path completions
    completions =
      [
        "/home/user/documents/",
        "/home/user/downloads/",
        "/var/log/"
      ]
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.take(5)

    {:ok, %{completion: completions}, state}
  end

  @impl true
  def handle_complete(_ref, _arg, state) do
    {:error, "Completion not supported for this reference", state}
  end

  # Log level control (new in 2025-03-26)
  @impl true
  def handle_set_log_level(level, state) when level in ["debug", "info", "warning", "error"] do
    {:ok, %{state | log_level: level}}
  end

  @impl true
  def handle_set_log_level(_level, state) do
    {:error, "Invalid log level", state}
  end
end
