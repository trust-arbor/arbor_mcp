defmodule Arbor.MCP.Server.Handler do
  @moduledoc """
  This module implements the standard MCP specification.

  Behaviour for implementing MCP server handlers.

  This behaviour defines callbacks for handling MCP protocol operations,
  including tools, resources, prompts, and retained compatibility features.

  > #### Protocol-deprecated callbacks {: .warning}
  >
  > MCP 2026-07-28 deprecated Roots, Sampling, and protocol Logging. Arbor.MCP
  > retains `handle_list_roots/1`, `handle_create_message/2`, and
  > `handle_set_log_level/2` in
  > Arbor.MCP 2.x for pinned legacy protocol revisions. For new implementations, pass
  > directories explicitly, call LLM provider APIs directly, and use stderr or
  > OpenTelemetry for logging.

  The handler behaviour pattern is an implementation detail but all callbacks
  correspond to official MCP protocol methods.

  ## Metadata (_meta) Support

  Handlers receive metadata passed by clients through the `_meta` field:

  - For `handle_call_tool/3`: The `_meta` field is included in the arguments map
  - For list operations: The cursor parameter may be a map containing `_meta`
  - For other operations: Check the params for `_meta` field

  Modern handlers can inspect the validated callback context and report
  progress on the originating request's response stream:

      def handle_call_tool("my_tool", arguments, state) do
        if Arbor.MCP.Server.Context.progress_token() do
          :ok = Arbor.MCP.Server.Context.report_progress(25, 100, "Working")
        end

        # Process arguments and return the final response...
      end

  ## Required client capabilities

  A modern handler that cannot continue without a capability declared in the
  request may return the standard `-32021` error reason:

      {:error,
       Arbor.MCP.Error.missing_required_client_capability(%{"sampling" => %{}}),
       state}

  Arbor.MCP preserves that protocol error, including its
  `data.requiredCapabilities` field, across every server transport.

  ## Basic Example

  > #### Tip
  > For most servers, prefer the declarative DSL instead of implementing
  > these callbacks by hand:
  >
  > ```elixir
  > defmodule MyServer do
  >   use Arbor.MCP.Server.Handler
  >   use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"
  >
  >   tool "calculate", "Perform calculations" do
  >     param :expression, :string, required: true
  >     run fn %{expression: expr}, state ->
  >       # ... compute ...
  >       {:ok, %{content: [%{type: "text", text: "Result: ..."}]}, state}
  >     end
  >   end
  > end
  > ```
  >
  > Raw callbacks are useful when capabilities are fully dynamic.

      defmodule MyServer do
        use Arbor.MCP.Server.Handler

        @impl true
        def handle_initialize(params, state) do
          # Check client's protocol version
          client_version = params["protocolVersion"]

          # Accept 2025-03-26 or propose 2024-11-05 as fallback
          negotiated_version = case client_version do
            "2025-03-26" -> "2025-03-26"
            "2024-11-05" -> "2024-11-05"
            _ -> "2025-03-26"  # Propose latest as default
          end

          {:ok, %{
            protocolVersion: negotiated_version,
            serverInfo: %{
              name: "my-server",
              version: "1.0.0"
            },
            capabilities: %{
              tools: %{},
              resources: %{},
              prompts: %{},
              sampling: %{}  # Enable LLM features
            }
          }, state}
        end

        @impl true
        def handle_list_tools(_cursor, state) do
          tools = [
            %{
              name: "calculate",
              description: "Perform calculations",
              inputSchema: %{
                type: "object",
                properties: %{
                  expression: %{type: "string"}
                },
                required: ["expression"]
              }
            }
          ]
          {:ok, tools, nil, state}
        end

        @impl true
        def handle_call_tool("calculate", params, state) do
          # Your tool implementation
          case eval_expression(params["expression"]) do
            {:ok, result} ->
              # Send progress updates if token provided
              if Arbor.MCP.Server.Context.progress_token() do
                :ok = Arbor.MCP.Server.Context.report_progress(100, 100, "Complete")
              end

              {:ok, %{content: [%{type: "text", text: "Result: \#{result}"}]}, state}

            {:error, reason} ->
              # Return tool execution error with isError flag
              error_result = %{
                content: [%{type: "text", text: "Calculation failed: \#{reason}"}],
                isError: true
              }
              {:ok, error_result, state}
          end
        end
      end

  ## Advanced Features

  ### Structured Tool Output (Draft Feature)

  > #### Draft Feature {: .info}
  > This implements the MCP specification feature from version 2025-06-18.

  Example implementation:

      defmodule WeatherServer do
        use Arbor.MCP.Server.Handler

        @impl true
        def handle_list_tools(_cursor, state) do
          tools = [
            %{
              name: "get_weather",
              description: "Get current weather data",
              inputSchema: %{
                type: "object",
                properties: %{
                  location: %{type: "string", description: "City name"}
                },
                required: ["location"]
              },
              # Draft feature: declare expected output structure
              outputSchema: %{
                type: "object",
                properties: %{
                  temperature: %{type: "number", description: "Temperature in Celsius"},
                  conditions: %{type: "string", description: "Weather conditions"},
                  humidity: %{type: "number", description: "Humidity percentage"}
                },
                required: ["temperature", "conditions"]
              }
            }
          ]
          {:ok, tools, nil, state}
        end

        @impl true
        def handle_call_tool("get_weather", %{"location" => location}, state) do
          # Fetch weather data (example implementation)
          # In real code, this would call an actual weather API
          temp = 22.5
          conditions = "Partly cloudy"
          humidity = 65

          # Return both unstructured and structured content
          result = %{
            content: [%{
              type: "text",
              text: "Current weather in \#{location}: \#{temp}°C, \#{conditions}"
            }],
            # Draft feature: structured content matching outputSchema
            structuredContent: %{
              "temperature" => temp,
              "conditions" => conditions,
              "humidity" => humidity
            }
          }

          {:ok, result, state}
        end

        # ... other callbacks ...
      end

  ### Sampling/LLM Integration

      @impl Arbor.MCP.Server.Handler
      def handle_create_message(params, state) do
        messages = params["messages"]
        model_prefs = params["modelPreferences"]

        # Integrate with your LLM provider
        response = call_llm_api(messages, model_prefs)

        result = %{
          content: %{type: "text", text: response.text},
          model: response.model,
          stopReason: "stop"
        }

        {:ok, result, state}
      end

  ### Progress Notifications

  For a modern streamable-HTTP request, report progress synchronously from the
  callback. Each notification is written to that request's SSE response before
  the final JSON-RPC response. The callback context is intentionally not
  inherited by detached processes, because they could outlive or lose the
  association with the originating request.

      @impl true
      def handle_call_tool("process_file", params, state) do
        file_path = params["path"]

        if Arbor.MCP.Server.Context.progress_token() do
          :ok = Arbor.MCP.Server.Context.report_progress(10, 100, "Starting")
        end

        result = process_file(file_path)

        if Arbor.MCP.Server.Context.progress_token() do
          :ok = Arbor.MCP.Server.Context.report_progress(100, 100, "Complete")
        end

        {:ok, %{content: [%{type: "text", text: result}]}, state}
      end

  Transport-aware legacy servers may continue to use
  `Arbor.MCP.Server.notify_progress/4` with their server process and explicit
  progress token.

  ### Dynamic Content Notifications

  Notify clients when your server's content changes:

      def add_new_tool(server, tool_def) do
        # Add tool to your server state
        # Then notify clients
        Arbor.MCP.Server.notify_tools_changed(server)
      end

      def update_resource(server, uri) do
        # Update the resource
        # Then notify clients
        Arbor.MCP.Server.notify_resource_update(server, uri)
      end

  ## Callback Reference

  The `use` macro provides default implementations for optional callbacks.
  You only need to implement the callbacks for features your server supports.
  """

  @type state :: any()
  @type initialize_result :: Arbor.MCP.Types.initialize_result()
  @type tool :: Arbor.MCP.Types.tool()
  @type resource :: Arbor.MCP.Types.resource()
  @type prompt :: Arbor.MCP.Types.prompt()
  @type input_required_return ::
          {:input_required, %{String.t() => map()}, state()}
          | {:input_required, %{String.t() => map()}, request_state :: term(), state()}

  @doc """
  Handles the initialize request from a client.

  The params map contains:
  - `"protocolVersion"` - The client's requested protocol version
  - `"capabilities"` - The client's declared capabilities
  - `"clientInfo"` - Information about the client implementation

  ## Version Negotiation

  The server should check the client's protocol version and either:
  1. Accept it by returning the same version
  2. Propose an alternative supported version
  3. Return an error if no compatible version exists

  ## Example

      def handle_initialize(params, state) do
        client_version = params["protocolVersion"]

        # Accept supported versions or propose latest
        negotiated_version = case client_version do
          "2025-03-26" -> "2025-03-26"
          "2024-11-05" -> "2024-11-05"
          _ -> "2025-03-26"  # Propose latest for unknown versions
        end

        # Use version-aware capabilities
        capabilities = Arbor.MCP.Server.Capabilities.build_capabilities(__MODULE__, negotiated_version)

        {:ok, %{
          protocolVersion: negotiated_version,
          serverInfo: %{name: "my-server", version: "1.0.0"},
          capabilities: capabilities
        }, state}
      end
  """
  @callback handle_initialize(params :: map(), state()) ::
              {:ok, initialize_result(), state()} | {:error, any(), state()}

  @doc """
  Handles listing available tools.

  Supports pagination via optional cursor parameter.
  Should return tools and optional nextCursor for pagination.
  """
  @callback handle_list_tools(cursor :: String.t() | nil, state()) ::
              {:ok, tools :: [tool()], next_cursor :: String.t() | nil, state()}
              | {:error, any(), state()}

  @doc """
  Handles a tool call.

  The result can be returned in multiple formats:

  1. Simple format (array of content items):
      {:ok, [%{type: "text", text: "Success"}], state}

  2. Extended format (with isError flag):
      {:ok, %{content: [%{type: "text", text: "Error occurred"}], isError: true}, state}

  3. Structured output format (2025-06-18 feature):
      {:ok, %{
        content: [%{type: "text", text: "Weather data"}],
        structuredContent: %{
          "temperature" => 22.5,
          "conditions" => "Partly cloudy",
          "humidity" => 65
        }
      }, state}

  > #### Draft Feature {: .info}
  > Structured tool output is available in MCP specification 2025-06-18.

  Use the extended format with `isError: true` to indicate tool execution errors
  that should be reported to the client as part of the result (not protocol errors).

  When returning structured content, tools should provide both unstructured content
  (for backwards compatibility) and structured content that conforms to the tool's
  declared outputSchema.
  """
  @callback handle_call_tool(name :: String.t(), arguments :: map(), state()) ::
              {:ok,
               Arbor.MCP.Types.tool_result()
               | list(map())
               | Arbor.MCP.Server.MRTR.InputRequired.t(), state()}
              | {:error, any(), state()}
              | input_required_return()

  @doc """
  Handles listing available resources.

  Supports pagination via optional cursor parameter.
  Should return resources and optional nextCursor for pagination.
  """
  @callback handle_list_resources(cursor :: String.t() | nil, state()) ::
              {:ok, resources :: [resource()], next_cursor :: String.t() | nil, state()}
              | {:error, any(), state()}

  @doc """
  Handles reading a resource.
  """
  @callback handle_read_resource(uri :: String.t(), state()) ::
              {:ok, Arbor.MCP.Types.resource_contents() | Arbor.MCP.Server.MRTR.InputRequired.t(),
               state()}
              | {:error, any(), state()}
              | input_required_return()

  @doc """
  Handles listing available prompts.

  Supports pagination via optional cursor parameter.
  Should return prompts and optional nextCursor for pagination.
  """
  @callback handle_list_prompts(cursor :: String.t() | nil, state()) ::
              {:ok, prompts :: [prompt()], next_cursor :: String.t() | nil, state()}
              | {:error, any(), state()}

  @doc """
  Handles getting a prompt.
  """
  @callback handle_get_prompt(name :: String.t(), arguments :: map(), state()) ::
              {:ok, Arbor.MCP.Types.prompt_message() | Arbor.MCP.Server.MRTR.InputRequired.t(),
               state()}
              | {:error, any(), state()}
              | input_required_return()

  @doc """
  Handles a completion request for argument autocompletion.

  This callback is invoked when a client requests completion suggestions
  for tool arguments, resource URIs, or prompt arguments.

  ## Parameters
    - ref: Reference type (e.g., "argument")
    - params: Map containing:
      - name: The argument/parameter name to complete
      - value: The partial value to complete

  ## Return Value
    Should return a map with:
    - completion: List of completion suggestion strings

  ## Example

      def handle_complete("argument", %{"name" => "file_path", "value" => "/home/"}, state) do
        completions = ["/home/user/", "/home/documents/", "/home/downloads/"]
        {:ok, %{completion: completions}, state}
      end

  Note: Servers should declare the `completion` capability to advertise support.
  """
  @callback handle_complete(ref :: String.t(), params :: map(), state()) ::
              {:ok, result :: map(), state()} | {:error, any(), state()}

  @doc """
  Handles a sampling create message request.

  MCP Sampling is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions. New implementations should integrate directly with an LLM provider API.
  """
  @callback handle_create_message(params :: Arbor.MCP.Types.create_message_params(), state()) ::
              {:ok, Arbor.MCP.Types.create_message_result(), state()} | {:error, any(), state()}

  @doc """
  Handles listing available roots.

  MCP Roots is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions.
  Prefer tool parameters, resource URIs, or server configuration for new
  implementations.
  """
  @callback handle_list_roots(state()) ::
              {:ok, [Arbor.MCP.Types.root()], state()} | {:error, any(), state()}

  @doc """
  Handles resource subscription.
  """
  @callback handle_subscribe_resource(uri :: String.t(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles resource unsubscription.

  > #### Arbor.MCP Extension {: .info}
  > This callback handles the resources/unsubscribe method which is an Arbor.MCP extension.
  > The MCP specification does not define this method.
  """
  @callback handle_unsubscribe_resource(uri :: String.t(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles listing resource templates.

  Supports pagination via optional cursor parameter.
  Should return resource templates and optional nextCursor for pagination.
  """
  @callback handle_list_resource_templates(cursor :: String.t() | nil, state()) ::
              {:ok, resource_templates :: [Arbor.MCP.Types.resource_template()],
               next_cursor :: String.t() | nil, state()}
              | {:error, any(), state()}

  # init/1 and terminate/2 are inherited from GenServer (injected by `use GenServer`
  # in __using__). Not declared here to avoid "conflicting behaviours" warnings
  # in Elixir 1.19+.

  @doc """
  Handles setting the log level for the server.

  This callback is called when the client sends a logging/setLevel request.
  The level parameter will be one of: "debug", "info", "warning", "error".

  The implementation should adjust the server's logging verbosity accordingly.

  > #### Protocol-deprecated feature {: .warning}
  >
  > MCP protocol Logging is deprecated as of 2026-07-28 and retained
  > in Arbor.MCP 2.x for pinned legacy protocol revisions. `logging/setLevel` remains applicable to legacy
  > connections. Prefer stderr for stdio or OpenTelemetry for new
  > observability integrations.

  @doc api: :public
  """
  @callback handle_set_log_level(level :: String.t(), state()) ::
              {:ok, state()} | {:error, any(), state()}

  # Task callbacks (new in 2025-11-25)

  @doc """
  Handles a tasks/get request.

  Returns the current state of a task by ID.
  """
  @callback handle_task_get(task_id :: String.t(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles a tasks/result request.

  Returns the result of a completed task.
  """
  @callback handle_task_result(task_id :: String.t(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles a tasks/list request.

  Returns a list of known tasks.
  """
  @callback handle_task_list(cursor :: String.t() | nil, state()) ::
              {:ok, tasks :: [map()], next_cursor :: String.t() | nil, state()}
              | {:error, any(), state()}

  @doc """
  Handles a tasks/cancel request.

  Cancels a running task.
  """
  @callback handle_task_cancel(task_id :: String.t(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles a modern tasks/update request.

  Accepts client responses to the task's currently outstanding input requests.
  A successful update is acknowledged with an empty modern result.
  """
  @callback handle_task_update(task_id :: String.t(), input_responses :: map(), state()) ::
              {:ok, map(), state()} | {:error, any(), state()}

  @doc """
  Handles a notifications/elicitation/complete notification.

  Called when the client notifies that a URL-mode elicitation has completed.
  """
  @callback handle_elicitation_complete(elicitation_id :: String.t(), state()) ::
              {:ok, state()} | {:error, any(), state()}

  # `init/1` and `terminate/2` are intentionally NOT declared as callbacks here.
  # Handlers run inside a GenServer, so those names belong to `GenServer`;
  # declaring them on this behaviour too makes every module that implements both
  # behaviours emit a "conflicting behaviours" warning. Modules that declare only
  # `@behaviour Arbor.MCP.Server.Handler` should annotate their GenServer callbacks
  # with `@impl GenServer` (or omit `@impl`), not `@impl true`.

  # Optional callbacks with defaults provided in __using__.
  @optional_callbacks [
    handle_list_resources: 2,
    handle_read_resource: 2,
    handle_list_prompts: 2,
    handle_get_prompt: 3,
    handle_complete: 3,
    handle_create_message: 2,
    handle_list_roots: 1,
    handle_subscribe_resource: 2,
    handle_unsubscribe_resource: 2,
    handle_list_resource_templates: 2,
    handle_set_log_level: 2,
    handle_task_get: 2,
    handle_task_result: 2,
    handle_task_list: 2,
    handle_task_cancel: 2,
    handle_task_update: 3,
    handle_elicitation_complete: 2
  ]

  defmacro __using__(opts) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, __CALLER__))
    task_store_opts = task_store_options!(opts)

    quote do
      @behaviour Arbor.MCP.Server.Handler
      use GenServer
      alias Arbor.MCP.Internal.Logging
      alias Arbor.MCP.Server.HandlerBridge
      alias Arbor.MCP.Tasks.Server, as: TaskServer

      @ex_mcp_task_store_opts unquote(Macro.escape(task_store_opts))

      # Required callback defaults live in @before_compile with
      # defoverridable so the Tool DSL's @before_compile can override them.
      @before_compile Arbor.MCP.Server.Handler

      @impl GenServer
      def init(_args), do: {:ok, %{}}

      # Defaults for optional callbacks — user inline overrides work
      # via defoverridable.
      @impl Arbor.MCP.Server.Handler
      def handle_list_resources(_cursor, state) do
        {:error, "Resources not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_read_resource(uri, state) do
        {:error,
         Arbor.MCP.Error.protocol_error(
           Arbor.MCP.Protocol.ErrorCodes.resource_not_found(:modern),
           "Resource not found: #{uri}"
         ), state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_list_prompts(_cursor, state) do
        {:error, "Prompts not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_get_prompt(name, _arguments, state) do
        {:error, Arbor.MCP.Error.protocol_error(-32602, "Prompt not found: #{name}"), state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_complete(_ref, _params, state) do
        {:error, "Completion not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_create_message(_params, state) do
        {:error, "Sampling not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_list_roots(state) do
        {:error, "Roots not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_subscribe_resource(_uri, state) do
        {:error, "Resource subscriptions not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_unsubscribe_resource(_uri, state) do
        {:error, "Resource subscriptions not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_list_resource_templates(_cursor, state) do
        {:error, "Resource templates not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_set_log_level(level, state) do
        case Logging.set_global_level(level) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end
      end

      @impl Arbor.MCP.Server.Handler
      def handle_task_get(task_id, state) do
        if @ex_mcp_task_store_opts do
          TaskServer.get(task_id, state, @ex_mcp_task_store_opts)
        else
          {:error, "Tasks not implemented", state}
        end
      end

      @impl Arbor.MCP.Server.Handler
      def handle_task_result(_task_id, state) do
        {:error, "Tasks not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_task_list(_cursor, state) do
        {:error, "Tasks not implemented", state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_task_cancel(task_id, state) do
        if @ex_mcp_task_store_opts do
          TaskServer.cancel(task_id, state, @ex_mcp_task_store_opts)
        else
          {:error, "Tasks not implemented", state}
        end
      end

      @impl Arbor.MCP.Server.Handler
      def handle_task_update(task_id, input_responses, state) do
        if @ex_mcp_task_store_opts do
          TaskServer.update(task_id, input_responses, state, @ex_mcp_task_store_opts)
        else
          {:error, "Tasks not implemented", state}
        end
      end

      @doc false
      def __task_store_options__, do: @ex_mcp_task_store_opts || []

      @doc false
      def __task_store_enabled__, do: not is_nil(@ex_mcp_task_store_opts)

      @impl Arbor.MCP.Server.Handler
      def handle_elicitation_complete(_elicitation_id, state) do
        {:ok, state}
      end

      @impl GenServer
      def terminate(_reason, _state), do: :ok

      defoverridable init: 1,
                     handle_list_resources: 2,
                     handle_read_resource: 2,
                     handle_list_prompts: 2,
                     handle_get_prompt: 3,
                     handle_complete: 3,
                     handle_create_message: 2,
                     handle_list_roots: 1,
                     handle_subscribe_resource: 2,
                     handle_unsubscribe_resource: 2,
                     handle_list_resource_templates: 2,
                     handle_set_log_level: 2,
                     handle_task_get: 2,
                     handle_task_result: 2,
                     handle_task_list: 2,
                     handle_task_cancel: 2,
                     handle_task_update: 3,
                     __task_store_options__: 0,
                     __task_store_enabled__: 0,
                     handle_elicitation_complete: 2,
                     terminate: 2

      # GenServer bridge (inline — must beat GenServer's @before_compile
      # catch-all). Each clause delegates to Arbor.MCP.Server.HandlerBridge, which
      # normalizes the handler's return value into a single reply shape.

      @impl GenServer
      def handle_call({:mcp_context, context, request}, from, state) do
        Arbor.MCP.Server.Context.with_context(context, fn -> handle_call(request, from, state) end)
      end

      def handle_call({:initialize, params}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_initialize, [params], state)

      def handle_call({:list_tools, cursor}, _from, state),
        do: HandlerBridge.list(__MODULE__, :handle_list_tools, [cursor], state)

      def handle_call({:call_tool, name, args}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_call_tool, [name, args], state)

      def handle_call({:execute_tool, name, args}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_call_tool, [name, args], state)

      def handle_call({:list_resources, cursor}, _from, state),
        do: HandlerBridge.list(__MODULE__, :handle_list_resources, [cursor], state)

      def handle_call({:list_resource_templates, cursor}, _from, state),
        do: HandlerBridge.list(__MODULE__, :handle_list_resource_templates, [cursor], state)

      def handle_call({:read_resource, uri}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_read_resource, [uri], state)

      def handle_call({:subscribe_resource, uri}, _from, state),
        do: HandlerBridge.ack(__MODULE__, :handle_subscribe_resource, [uri], state)

      def handle_call({:unsubscribe_resource, uri}, _from, state),
        do: HandlerBridge.ack(__MODULE__, :handle_unsubscribe_resource, [uri], state)

      def handle_call({:list_prompts, cursor}, _from, state),
        do: HandlerBridge.list(__MODULE__, :handle_list_prompts, [cursor], state)

      def handle_call({:get_prompt, name, args}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_get_prompt, [name, args], state)

      def handle_call({:complete, ref, argument}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_complete, [ref, argument], state)

      def handle_call({:set_log_level, level}, _from, state),
        do: HandlerBridge.ack(__MODULE__, :handle_set_log_level, [level], state)

      def handle_call({:list_roots}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_list_roots, [], state)

      def handle_call({:task_get, task_id}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_task_get, [task_id], state)

      def handle_call({:task_result, task_id}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_task_result, [task_id], state)

      def handle_call({:task_cancel, task_id}, _from, state),
        do: HandlerBridge.call(__MODULE__, :handle_task_cancel, [task_id], state)

      def handle_call({:task_update, task_id, input_responses}, _from, state),
        do:
          HandlerBridge.call(
            __MODULE__,
            :handle_task_update,
            [task_id, input_responses],
            state
          )

      def handle_call({:task_list, cursor}, _from, state),
        do: HandlerBridge.list(__MODULE__, :handle_task_list, [cursor], state)

      def handle_call({:request, method, _params}, _from, state),
        do: {:reply, {:error, "Unknown method: #{method}"}, state}

      def handle_call(_msg, _from, state),
        do: {:reply, {:error, "Unknown message"}, state}
    end
  end

  defp task_store_options!(opts) do
    case Keyword.get(opts, :tasks, false) do
      false ->
        nil

      :store ->
        store_opts = Keyword.get(opts, :task_store_opts, [])

        case Keyword.fetch(opts, :task_store) do
          {:ok, store} -> Keyword.put_new(store_opts, :store, store)
          :error -> store_opts
        end

      invalid ->
        raise ArgumentError,
              "expected :tasks to be false or :store, got: #{inspect(invalid)}"
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    defaults =
      [
        unless Module.defines?(env.module, {:handle_initialize, 2}, :def) do
          quote do
            @impl Arbor.MCP.Server.Handler
            def handle_initialize(params, state) do
              # Default negotiated version comes from the single source of
              # truth so every entry point agrees (audit M8).
              {:ok,
               Arbor.MCP.Protocol.Initialize.build_initialize_result(params, %{
                 serverInfo: %{name: "ex_mcp", version: "0.1.0"},
                 capabilities: %{}
               }), state}
            end
          end
        end,
        unless Module.defines?(env.module, {:handle_list_tools, 2}, :def) do
          quote do
            @impl Arbor.MCP.Server.Handler
            def handle_list_tools(_cursor, state) do
              {:ok, [], nil, state}
            end
          end
        end,
        unless Module.defines?(env.module, {:handle_call_tool, 3}, :def) do
          quote do
            @impl Arbor.MCP.Server.Handler
            def handle_call_tool(name, _arguments, state) do
              {:error, Arbor.MCP.Error.protocol_error(-32602, "Unknown tool: #{name}"), state}
            end
          end
        end
      ]
      |> Enum.reject(&is_nil/1)

    overridable =
      [
        unless(Module.defines?(env.module, {:handle_initialize, 2}, :def),
          do: {:handle_initialize, 2}
        ),
        unless(Module.defines?(env.module, {:handle_list_tools, 2}, :def),
          do: {:handle_list_tools, 2}
        ),
        unless(Module.defines?(env.module, {:handle_call_tool, 3}, :def),
          do: {:handle_call_tool, 3}
        )
      ]
      |> Enum.reject(&is_nil/1)

    quote do
      # =================================================================
      # Required callback defaults (injected via @before_compile)
      #
      # These use defoverridable so the Tool DSL's @before_compile
      # (which runs after this one) can override them. User inline
      # defs also override these since inline defs beat @before_compile.
      # =================================================================

      unquote_splicing(defaults)
      defoverridable unquote(overridable)
    end
  end

  @doc """
  Builds server capabilities based on which callbacks are implemented.

  This is a convenience function that can be used in your handle_initialize/2
  callback to automatically generate capabilities based on your handler's
  implemented functions.

  ## Example

      def handle_initialize(params, state) do
        capabilities = Arbor.MCP.Server.Handler.build_capabilities(__MODULE__)

        {:ok, %{
          protocolVersion: "2025-03-26",
          serverInfo: %{name: "my-server", version: "1.0.0"},
          capabilities: capabilities
        }, state}
      end
  """
  alias Arbor.MCP.Server.Capabilities

  @spec build_capabilities(module()) :: map()
  def build_capabilities(handler_module) do
    Capabilities.build_capabilities(handler_module)
  end
end
