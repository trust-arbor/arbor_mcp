defmodule Arbor.MCP.Client.Handler do
  @moduledoc """
  This module implements the standard MCP specification.

  Behaviour for handling server-originated interactions and stream events.

  Legacy MCP revisions support independent server-to-client JSON-RPC requests.
  MCP 2026-07-28 replaces that wire pattern with multi-round-trip result
  envelopes (MRTR) and request-owned stream notifications. ArborMCP reuses the
  specific input callbacks when satisfying compatible MRTR input requests,
  while progress and log callbacks receive modern POST-stream events. The
  generic `handle_server_request/3` callback belongs to the legacy wire path.

  > #### Protocol-deprecated callbacks {: .warning}
  >
  > MCP 2026-07-28 deprecated Roots and Sampling. ArborMCP retains
  > `handle_list_roots/1` and `handle_create_message/2` in
  > ArborMCP 2.x for pinned legacy protocol revisions. New clients should pass directories or files explicitly and
  > integrate with LLM provider APIs directly.

  ## Example

      defmodule MyClientHandler do
        @behaviour Arbor.MCP.Client.Handler

        @impl true
        def init(args) do
          {:ok, %{roots: [%{uri: "file:///home/user", name: "Home"}]}}
        end

        @impl true
        def handle_ping(state) do
          {:ok, %{}, state}
        end

        @impl true
        def handle_list_roots(state) do
          {:ok, state.roots, state}
        end

        @impl true
        def handle_create_message(params, state) do
          # Show to user for approval, then sample LLM
          case get_user_approval(params) do
            :approved ->
              result = sample_llm(params)
              {:ok, result, state}
            :denied ->
              {:error, "User denied the request", state}
          end
        end
      end
  """

  @type state :: any()
  @type error_info :: String.t() | map()

  @doc """
  Called when the client handler is started.

  Return `{:ok, state}` to initialize the handler state.
  """
  @callback init(args :: any()) :: {:ok, state}

  @doc """
  Handles a ping request from the server.

  The client should respond promptly to indicate it's still alive.

  ## Response

  - `{:ok, result, new_state}` - Success with empty result
  - `{:error, reason, new_state}` - Error occurred
  """
  @callback handle_ping(state) ::
              {:ok, map(), state}
              | {:error, error_info, state}

  @doc """
  Handles a request to list the client's root directories.

  This is called when the server needs to understand what file system
  locations the client has access to.

  MCP Roots is deprecated as of 2026-07-28 and available in
  ArborMCP 2.x for pinned legacy protocol revisions.
  Prefer passing directories or files via tool parameters, resource URIs, or
  server configuration in new implementations.

  ## Response

  The roots should be a list of maps with:
  - `uri` (required) - The URI of the root (must start with "file://")
  - `name` (optional) - Human-readable name for the root

  ## Example

      def handle_list_roots(state) do
        roots = [
          %{uri: "file:///home/user", name: "Home"},
          %{uri: "file:///projects", name: "Projects"}
        ]
        {:ok, roots, state}
      end
  """
  @callback handle_list_roots(state) ::
              {:ok, [map()], state}
              | {:error, error_info, state}

  @doc """
  Handles a request from the server to sample an LLM.

  The client has full discretion over which model to select and should
  inform the user before beginning sampling (human in the loop).

  MCP Sampling is deprecated as of 2026-07-28 and available in
  ArborMCP 2.x for pinned legacy protocol revisions. New implementations should integrate directly with an LLM provider API.

  ## Parameters

  The params map contains:
  - `messages` - List of messages to send to the LLM
  - `modelPreferences` (optional) - Server's model preferences
  - `systemPrompt` (optional) - System prompt to use
  - `includeContext` (optional) - Whether to include MCP context
  - `temperature` (optional) - Sampling temperature
  - `maxTokens` (optional) - Maximum tokens to sample
  - `tools` (optional, 2025-11-25) - List of tool definitions the LLM may call.
    Each tool has `name`, `description`, and `inputSchema` fields.
  - `toolChoice` (optional, 2025-11-25) - Controls how the LLM uses tools.
    A map with a `type` key: `"auto"`, `"none"`, or `"tool"` (with `name`).

  ## Response

  The result should contain:
  - `role` - The role of the created message (usually "assistant")
  - `content` - The content of the message. May include `tool_use` and
    `tool_result` content blocks when tools are provided.
  - `model` - The model that was used

  ## Human-in-the-Loop

  This callback MUST implement human-in-the-loop approval. The handler can
  use the `Arbor.MCP.Approval` behaviour for this, or implement its own approval
  mechanism. The user must be informed about the sampling request and have
  the opportunity to approve or deny it.

  ## Example

      def handle_create_message(params, state) do
        case get_user_approval(params) do
          :approved ->
            result = %{
              role: "assistant",
              content: %{type: "text", text: "Hello!"},
              model: "gpt-4"
            }
            {:ok, result, state}
          :denied ->
            {:error, "User denied sampling request", state}
        end
      end

  ## Example with Tool Calling (2025-11-25)

      def handle_create_message(%{"tools" => tools} = params, state) when is_list(tools) do
        # Pass tools to the LLM and handle tool_use responses
        result = %{
          role: "assistant",
          content: %{type: "tool_use", id: "call_1", name: "get_weather", input: %{"city" => "NYC"}},
          model: "gpt-4"
        }
        {:ok, result, state}
      end
  """
  @callback handle_create_message(params :: map(), state) ::
              {:ok, map(), state}
              | {:error, error_info, state}

  @doc """
  Handles an elicitation request from the server.

  This is a stable protocol feature available in MCP 2025-06-18 and later.
  The server is requesting additional information from the user through a 
  structured form with JSON schema validation.

  ## Parameters

  - `message` - Human-readable message explaining what information is needed
  - `requested_schema` - JSON schema defining the expected response structure

  ## Response

  The result should contain:
  - `action` - One of "accept", "decline", or "cancel"
  - `content` (optional) - The user's response data (only for "accept")

  ## Example

      def handle_elicitation_create(message, requested_schema, state) do
        # Present the elicitation to the user
        case present_elicitation_to_user(message, requested_schema) do
          {:accept, data} ->
            {:ok, %{action: "accept", content: data}, state}
          :decline ->
            {:ok, %{action: "decline"}, state}
          :cancel ->
            {:ok, %{action: "cancel"}, state}
        end
      end
  """
  @callback handle_elicitation_create(message :: String.t(), requested_schema :: map(), state) ::
              {:ok, map(), state}
              | {:error, error_info, state}

  @doc """
  Handles a URL-mode elicitation request from the server.

  Instead of a form schema, the server sends a URL for the client to navigate to.
  Available in protocol version 2025-11-25.

  Prefer `c:handle_url_elicitation/4`, which also receives `elicitationId`.
  This `/3` callback is kept for 1.x compatibility and does not receive the
  id.

  URL-mode requests are routed here whenever `/4` is not implemented and this
  callback is. For compatibility, handlers that only implement
  `handle_elicitation_create/3` continue to receive URL-mode requests through
  that callback; its second argument is then a map containing `"mode"`,
  `"url"`, and `"elicitationId"`, and ArborMCP logs a once-per-handler warning.

  ## Parameters

  - `message` - Human-readable message explaining what information is needed
  - `url` - URL for the client to open/navigate to

  ## Response

  Same as handle_elicitation_create - action and optional content.
  """
  @callback handle_url_elicitation(message :: String.t(), url :: String.t(), state) ::
              {:ok, map(), state}
              | {:error, error_info, state}

  @doc """
  Handles a URL-mode elicitation request, including `elicitationId`.

  Preferred over `c:handle_url_elicitation/3` because the id can be used
  directly in `notifications/elicitation/complete` without stashing it in
  application state.

  ## Parameters

  - `message` - Human-readable message explaining what information is needed
  - `url` - URL for the client to open/navigate to
  - `elicitation_id` - Server-provided id for the complete notification

  ## Response

  Same as handle_elicitation_create - action and optional content.

  ## Example

      def handle_url_elicitation(message, url, elicitation_id, state) do
        _ = {message, open_browser(url)}

        {:ok, %{action: "accept", content: %{"authenticated" => true}},
         Map.put(state, :elicitation_id, elicitation_id)}
      end
  """
  @callback handle_url_elicitation(
              message :: String.t(),
              url :: String.t(),
              elicitation_id :: String.t() | nil,
              state
            ) ::
              {:ok, map(), state}
              | {:error, error_info, state}

  @doc """
  Handles a task status notification from the server.

  Called when the server sends a notification about a task state change.
  Available in protocol version 2025-11-25.
  """
  @callback handle_task_status(notification :: map(), state) ::
              {:ok, state}
              | {:error, error_info, state}

  @doc """
  Handles a progress notification delivered on an ordinary request's modern
  streamable-HTTP response.

  The first argument is the JSON-RPC id of the request that owns the stream.
  The map contains `"progressToken"`, `"progress"`, and optional `"total"`
  and `"message"` fields. Keep this callback fast; it runs in the client
  process before subsequent events from the same response stream are handled.
  """
  @callback handle_progress(Arbor.MCP.Types.request_id(), notification :: map(), state) ::
              {:ok, state}
              | {:error, error_info, state}

  @doc """
  Handles a request-scoped `notifications/message` event delivered before the
  final response on a modern streamable-HTTP request. The first argument is
  the owning JSON-RPC request id, which is required to correlate concurrent
  log streams because log notification params do not contain a progress token.
  """
  @callback handle_log_message(Arbor.MCP.Types.request_id(), notification :: map(), state) ::
              {:ok, state}
              | {:error, error_info, state}

  @doc """
  Called when the handler process is about to terminate.
  """
  @callback terminate(reason :: term(), state) :: :ok

  @doc """
  Handles a legacy server-to-client request without a dedicated callback.

  This is called when an initialize-based peer sends a request that does not
  have a dedicated handler callback. Modern MCP 2026-07-28 uses MRTR result
  envelopes instead of arbitrary independent server requests.

  ## Parameters

  - `method` — the JSON-RPC method name (e.g., "sampling/createMessage")
  - `params` — the request parameters map
  - `state` — the handler state

  ## Return Values

  - `{:ok, result, new_state}` — success, result is sent back as JSON-RPC response
  - `{:error, error_info, new_state}` — error, sent as JSON-RPC error response
  """
  @callback handle_server_request(method :: String.t(), params :: map(), state) ::
              {:ok, result :: map(), state}
              | {:error, error_info, state}

  @doc """
  Opts this handler into bounded parallel dispatch of MRTR input requests.

  The default is sequential dispatch in deterministic input-request ID order. A
  handler may return an integer from 2 through 16 to allow that many callbacks
  to run concurrently. Parallel callbacks all receive the same handler state
  and must return it unchanged; use sequential dispatch when callbacks need to
  update handler state.
  """
  @callback mrtr_input_concurrency() :: 2..16

  @optional_callbacks terminate: 2,
                      handle_elicitation_create: 3,
                      handle_url_elicitation: 3,
                      handle_url_elicitation: 4,
                      handle_task_status: 2,
                      handle_progress: 3,
                      handle_log_message: 3,
                      handle_server_request: 3,
                      mrtr_input_concurrency: 0
end
