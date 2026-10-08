defmodule Arbor.MCP.Internal.Protocol do
  @moduledoc false

  # Implements the Model Context Protocol JSON-RPC message format.
  # This module handles the low-level protocol details for both
  # client and server implementations.
  #
  # Example:
  #
  #     # With progress token
  #     Protocol.encode_call_tool("my_tool", %{}, %{"progressToken" => "op-123"})
  #
  #     # With custom metadata
  #     Protocol.encode_list_resources(nil, %{"requestId" => "req-456", "userId" => "user-789"})
  #
  # All methods in this module are part of the official MCP specification.

  alias Arbor.MCP.Internal.{MapBuilder, MessageValidator, RequestParams, VersionRegistry}
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.RPC.JSONRPC

  @type json_rpc_id :: String.t() | integer()
  @type method :: String.t()
  @type params :: map()
  @type result :: any()
  @type error :: %{code: integer(), message: String.t(), data: any()}

  # Client Request Encoding

  @doc """
  Encodes an initialize request from client to server.
  """
  @spec encode_initialize(map(), map() | nil, String.t() | nil) :: map()
  def encode_initialize(client_info, capabilities \\ nil, version \\ nil) do
    # Use provided capabilities or defaults
    caps = capabilities || %{"roots" => %{}, "sampling" => %{}}
    protocol_version = version || VersionRegistry.preferred_version()

    %{
      "protocolVersion" => protocol_version,
      "capabilities" => caps,
      "clientInfo" => client_info
    }
    |> jsonrpc_request("initialize")
  end

  @doc """
  Encodes an initialized notification.
  """
  @spec encode_initialized() :: map()
  def encode_initialized do
    encode_notification("notifications/initialized", %{})
  end

  @doc """
  Encodes a request to list available tools.

  ## Parameters
  - `cursor` - Optional cursor for pagination
  - `meta` - Optional metadata map to include in _meta field
  """
  @spec encode_list_tools(String.t() | nil, map() | nil) :: map()
  def encode_list_tools(cursor \\ nil, meta \\ nil) do
    params =
      cursor
      |> RequestParams.cursor()
      |> RequestParams.with_non_empty_meta(meta)

    jsonrpc_request(params, "tools/list")
  end

  @doc """
  Encodes a tool call request.

  ## Parameters
  - `name` - The tool name
  - `arguments` - Tool arguments map
  - `meta_or_progress_token` - Either a progress token (string/integer) or full metadata map

  Supports backward compatibility: if a string/integer is provided, it's treated as a progress token.
  """
  @spec encode_call_tool(String.t(), map(), Arbor.MCP.Types.progress_token() | nil | map()) ::
          map()
  def encode_call_tool(name, arguments, meta_or_progress_token \\ nil) do
    params =
      name
      |> RequestParams.named(arguments)
      |> RequestParams.with_progress_or_meta(meta_or_progress_token)

    jsonrpc_request(params, "tools/call")
  end

  @doc """
  Encodes a request to list available resources.
  """
  @spec encode_list_resources(String.t() | nil, map() | nil) :: map()
  def encode_list_resources(cursor \\ nil, meta \\ nil) do
    params =
      cursor
      |> RequestParams.cursor()
      |> RequestParams.with_non_empty_meta(meta)

    jsonrpc_request(params, "resources/list")
  end

  @doc """
  Encodes a resource read request.
  """
  @spec encode_read_resource(String.t()) :: map()
  def encode_read_resource(uri) do
    uri
    |> RequestParams.uri()
    |> jsonrpc_request("resources/read")
  end

  @doc """
  Encodes a request to list available prompts.
  """
  @spec encode_list_prompts(String.t() | nil, map() | nil) :: map()
  def encode_list_prompts(cursor \\ nil, meta \\ nil) do
    params =
      cursor
      |> RequestParams.cursor()
      |> RequestParams.with_non_empty_meta(meta)

    jsonrpc_request(params, "prompts/list")
  end

  @doc """
  Encodes a prompt get request.
  """
  @spec encode_get_prompt(String.t(), map(), map() | nil) :: map()
  def encode_get_prompt(name, arguments \\ %{}, meta \\ nil) do
    params =
      name
      |> RequestParams.named(arguments)
      |> RequestParams.with_non_empty_meta(meta)

    jsonrpc_request(params, "prompts/get")
  end

  @doc """
  Encodes a completion request.
  """
  @spec encode_complete(
          Arbor.MCP.Types.complete_ref(),
          Arbor.MCP.Types.complete_argument(),
          map() | nil
        ) ::
          map()
  def encode_complete(ref, argument, meta \\ nil) do
    params =
      ref
      |> RequestParams.completion(argument)
      |> RequestParams.with_non_empty_meta(meta)

    jsonrpc_request(params, "completion/complete")
  end

  @doc """
  Encodes a sampling create message request.
  """
  @spec encode_create_message(Arbor.MCP.Types.create_message_params(), map() | nil) :: map()
  def encode_create_message(params, meta \\ nil) do
    params = RequestParams.with_non_empty_meta(params, meta)

    jsonrpc_request(params, "sampling/createMessage")
  end

  @doc """
  Encodes a request to list roots.
  """
  @spec encode_list_roots() :: map()
  def encode_list_roots do
    jsonrpc_request(%{}, "roots/list")
  end

  @doc """
  Encodes a resource subscription request.
  """
  @spec encode_subscribe_resource(String.t()) :: map()
  def encode_subscribe_resource(uri) do
    uri
    |> RequestParams.uri()
    |> jsonrpc_request("resources/subscribe")
  end

  @doc """
  Encodes a resource unsubscribe request.

  > #### ArborMCP Extension {: .info}
  > This encodes the resources/unsubscribe method which is an ArborMCP extension.
  > The MCP specification does not define this method.
  """
  @spec encode_unsubscribe_resource(String.t()) :: map()
  def encode_unsubscribe_resource(uri) do
    uri
    |> RequestParams.uri()
    |> jsonrpc_request("resources/unsubscribe")
  end

  # Server Response Encoding

  @doc """
  Encodes a successful response.
  """
  @spec encode_response(result(), json_rpc_id()) :: map()
  def encode_response(result, id) do
    JSONRPC.response(id, result)
  end

  @doc """
  Encodes an error response.
  """
  @spec encode_error(integer(), String.t(), any(), json_rpc_id() | nil) :: map()
  def encode_error(code, message, data \\ nil, id) do
    error = %{
      "code" => code,
      "message" => message
    }

    error = if data, do: Map.put(error, "data", data), else: error

    JSONRPC.error(id, error)
  end

  @doc """
  Encodes a notification (no id field).
  """
  @spec encode_notification(method(), params()) :: map()
  def encode_notification(method, params) do
    JSONRPC.notification(method, params)
  end

  @doc """
  Encodes a resources list changed notification.
  """
  @spec encode_resources_changed() :: map()
  def encode_resources_changed do
    encode_notification("notifications/resources/list_changed", %{})
  end

  @doc """
  Encodes a tools list changed notification.
  """
  @spec encode_tools_changed() :: map()
  def encode_tools_changed do
    encode_notification("notifications/tools/list_changed", %{})
  end

  @doc """
  Encodes a prompts list changed notification.
  """
  @spec encode_prompts_changed() :: map()
  def encode_prompts_changed do
    encode_notification("notifications/prompts/list_changed", %{})
  end

  @doc """
  Encodes a resource updated notification.
  """
  @spec encode_resource_updated(String.t()) :: map()
  def encode_resource_updated(uri) do
    encode_notification("notifications/resources/updated", %{"uri" => uri})
  end

  @doc """
  Encodes a progress notification.

  ## Parameters
  - `progress_token` - Token identifying the operation
  - `progress` - Current progress value
  - `total` - Optional total value for calculating percentage
  - `message` - Optional human-readable progress message
  """
  @spec encode_progress(
          Arbor.MCP.Types.progress_token(),
          number(),
          number() | nil,
          String.t() | nil
        ) ::
          map()
  def encode_progress(progress_token, progress, total \\ nil, message \\ nil) do
    params = %{
      "progressToken" => progress_token,
      "progress" => progress
    }

    params =
      params
      |> MapBuilder.put_if_present("total", total)
      |> MapBuilder.put_if_present("message", message)

    encode_notification("notifications/progress", params)
  end

  @doc """
  Encodes a roots list changed notification.
  """
  @spec encode_roots_changed() :: map()
  def encode_roots_changed do
    encode_notification("notifications/roots/list_changed", %{})
  end

  @doc """
  Encodes a cancelled notification.

  Per MCP specification, the "initialize" request cannot be cancelled.
  This function will validate the request ID and return an error for
  invalid cancellation attempts.

  ## Examples

      # Valid cancellation
      {:ok, notification} = Protocol.encode_cancelled("req_123", "User cancelled")

      # Invalid - initialize cannot be cancelled
      {:error, :cannot_cancel_initialize} = Protocol.encode_cancelled("initialize", "reason")

  """
  @spec encode_cancelled(Arbor.MCP.Types.request_id(), String.t() | nil) ::
          {:ok, map()} | {:error, :cannot_cancel_initialize}
  def encode_cancelled(request_id, reason \\ nil) do
    # Per MCP spec: The "initialize" request CANNOT be cancelled
    if request_id == "initialize" do
      {:error, :cannot_cancel_initialize}
    else
      params = %{"requestId" => request_id}
      params = if reason, do: Map.put(params, "reason", reason), else: params
      notification = encode_notification("notifications/cancelled", params)
      {:ok, notification}
    end
  end

  @doc """
  Encodes a cancelled notification (legacy version).

  This version maintains backward compatibility but does not validate
  against cancelling the initialize request.
  """
  @spec encode_cancelled!(Arbor.MCP.Types.request_id(), String.t() | nil) :: map()
  def encode_cancelled!(request_id, reason \\ nil) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params
    encode_notification("notifications/cancelled", params)
  end

  @doc """
  Encodes a ping request.
  """
  @spec encode_ping() :: map()
  def encode_ping do
    jsonrpc_request(%{}, "ping")
  end

  @doc """
  Encodes a pong response.
  """
  @spec encode_pong(json_rpc_id()) :: map()
  def encode_pong(id) do
    encode_response(%{}, id)
  end

  @doc """
  Encodes a request to list resource templates.
  """
  @spec encode_list_resource_templates(String.t() | nil) :: map()
  def encode_list_resource_templates(cursor \\ nil) do
    params = RequestParams.cursor(cursor)

    jsonrpc_request(params, "resources/templates/list")
  end

  @doc """
  Encodes a logging message.
  """
  @spec encode_log_message(Arbor.MCP.Types.log_level(), String.t(), any()) :: map()
  def encode_log_message(level, message, data \\ nil) do
    params = %{
      "level" => level,
      "message" => message
    }

    params = if data, do: Map.put(params, "data", data), else: params
    encode_notification("notifications/message", params)
  end

  @doc """
  Encodes a logging/setLevel request.
  """
  @spec encode_set_log_level(String.t()) :: map()
  def encode_set_log_level(level) do
    %{"level" => level}
    |> jsonrpc_request("logging/setLevel")
  end

  @doc """
  Encodes an elicitation/create request with form schema.

  This feature is available in protocol version 2025-06-18 and later.
  """
  @spec encode_elicitation_create(String.t(), map()) :: map()
  def encode_elicitation_create(message, requested_schema) do
    %{
      "message" => message,
      "requestedSchema" => requested_schema
    }
    |> jsonrpc_request("elicitation/create")
  end

  @doc """
  Encodes a URL-mode elicitation/create request.

  This feature is available in protocol version 2025-11-25 and later.
  Instead of a form schema, the server sends a URL for the client to navigate to.
  """
  @spec encode_elicitation_create_url(String.t(), String.t(), keyword()) :: map()
  def encode_elicitation_create_url(message, url, _opts \\ []) do
    %{
      "message" => message,
      "url" => url,
      "mode" => "url",
      "elicitationId" => "elicit-#{generate_id()}"
    }
    |> jsonrpc_request("elicitation/create")
  end

  @doc """
  Encodes an elicitation complete notification.

  Sent by the client to notify the server that an elicitation (especially URL-mode)
  has been completed. Available in protocol version 2025-11-25.
  """
  @spec encode_elicitation_complete_notification(String.t()) :: map()
  def encode_elicitation_complete_notification(elicitation_id) do
    encode_notification("notifications/elicitation/complete", %{
      "elicitationId" => elicitation_id
    })
  end

  # Task protocol methods (new in 2025-11-25)

  @doc """
  Encodes a tasks/get request.
  """
  @spec encode_task_get(String.t()) :: map()
  def encode_task_get(task_id) do
    %{"taskId" => task_id}
    |> jsonrpc_request("tasks/get")
  end

  @doc """
  Encodes a tasks/result request to get the result of a completed task.
  """
  @spec encode_task_result(String.t()) :: map()
  def encode_task_result(task_id) do
    %{"taskId" => task_id}
    |> jsonrpc_request("tasks/result")
  end

  @doc """
  Encodes a tasks/list request.
  """
  @spec encode_task_list(String.t() | nil) :: map()
  def encode_task_list(cursor \\ nil) do
    params = RequestParams.cursor(cursor)

    jsonrpc_request(params, "tasks/list")
  end

  @doc """
  Encodes a tasks/cancel request.
  """
  @spec encode_task_cancel(String.t()) :: map()
  def encode_task_cancel(task_id) do
    %{"taskId" => task_id}
    |> jsonrpc_request("tasks/cancel")
  end

  @doc "Encodes a modern tasks/update request with input responses."
  @spec encode_task_update(String.t(), map()) :: map()
  def encode_task_update(task_id, input_responses) do
    %{"taskId" => task_id, "inputResponses" => input_responses}
    |> jsonrpc_request("tasks/update")
  end

  @doc """
  Encodes a task status notification.
  """
  @spec encode_task_status_notification(String.t(), String.t(), map() | nil) :: map()
  def encode_task_status_notification(task_id, status, metadata \\ nil) do
    params = %{
      "taskId" => task_id,
      "status" => status
    }

    params = if metadata, do: Map.put(params, "metadata", metadata), else: params
    encode_notification("notifications/tasks/status", params)
  end

  @doc "Encodes a modern full-state task notification."
  @spec encode_task_notification(map() | Arbor.MCP.Tasks.Task.t()) :: map()
  def encode_task_notification(%Arbor.MCP.Tasks.Task{} = task) do
    encode_notification("notifications/tasks", Arbor.MCP.Tasks.Task.to_map(task, :modern))
  end

  def encode_task_notification(task) when is_map(task) do
    encode_notification("notifications/tasks", task)
  end

  # Message Parsing

  @doc """
  Parses a JSON-RPC message with validation.

  Returns one of:
  - `{:request, method, params, id}` - An incoming request
  - `{:notification, method, params}` - An incoming notification
  - `{:result, result, id}` - A response to our request
  - `{:error, error, id}` - An error response
  - `{:error, :invalid_message}` - Invalid message format
  - `{:error, :validation_failed, error_details}` - Validation failed
  """
  @spec parse_message(String.t() | map(), MessageValidator.session_state() | nil) ::
          {:request, method(), params(), json_rpc_id()}
          | {:notification, method(), params()}
          | {:result, result(), json_rpc_id()}
          | {:error, error(), json_rpc_id()}
          | {:error, :invalid_message}
          | {:error, :validation_failed, map()}

  def parse_message(data, session_state \\ nil)

  @spec parse_message_unvalidated(String.t() | map() | list()) ::
          {:request, method(), params(), json_rpc_id()}
          | {:notification, method(), params()}
          | {:result, result(), json_rpc_id()}
          | {:error, error(), json_rpc_id()}
          | {:batch, list()}
          | {:error, :invalid_message}
  def parse_message(data, session_state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> parse_message(decoded, session_state)
      {:error, _} -> {:error, :invalid_message}
    end
  end

  def parse_message(message, session_state) do
    # Use session state or create new one
    state = session_state || MessageValidator.new_session()

    # First do basic parsing
    parsed = parse_message_unvalidated(message)

    # Then validate if we have a valid parsed message
    case parsed do
      {:error, :invalid_message} ->
        {:error, :invalid_message}

      _ ->
        # For individual messages, validate the original message structure
        case MessageValidator.validate_message(message, state) do
          {{:ok, _validated}, _new_state} -> parsed
          {{:error, error}, _state} -> {:error, :validation_failed, error}
        end
    end
  end

  def parse_message_unvalidated(data) when is_binary(data) do
    JSONRPC.parse_unvalidated(data)
  end

  def parse_message_unvalidated(message), do: JSONRPC.parse_unvalidated(message)

  # Version-specific utilities

  @doc """
  Checks if a method is available in the given protocol version.
  """
  @spec method_available?(String.t(), String.t()) :: boolean()
  def method_available?(method, version),
    do: Arbor.MCP.Protocol.Methods.available?(method, version)

  @doc """
  Validates that a message is compatible with the given protocol version.
  """
  @spec validate_message_version(map(), String.t()) :: :ok | {:error, String.t()}
  def validate_message_version(%{"method" => method}, version) do
    if method_available?(method, version) do
      :ok
    else
      {:error, "Method #{method} is not available in protocol version #{version}"}
    end
  end

  def validate_message_version(_, _), do: :ok

  # Batch Processing (for backward compatibility with older protocol versions)

  @doc """
  Encodes a batch of JSON-RPC requests.

  Note: Batch support is deprecated in protocol version 2025-06-18.
  This function is maintained for backward compatibility with older versions.
  """
  @spec encode_batch(list(map())) :: list(map())
  def encode_batch(requests) when is_list(requests) do
    requests
  end

  @doc """
  Parses a batch of JSON-RPC responses.

  Note: Batch support is deprecated in protocol version 2025-06-18.
  This function is maintained for backward compatibility with older versions.
  """
  @spec parse_batch_response(list(map())) ::
          list({:result | :error | :notification, any(), any()})
  def parse_batch_response(responses) when is_list(responses) do
    Enum.map(responses, &parse_message_unvalidated/1)
  end

  # Utilities

  @doc """
  Encodes a message to JSON string.
  """
  @spec encode_to_string(map() | list(map())) :: {:ok, String.t()} | {:error, any()}
  def encode_to_string(message) do
    Jason.encode(message)
  end

  @doc """
  Generates a unique ID for requests.
  """
  @spec generate_id() :: integer()
  defdelegate generate_id, to: JSONRPC

  defp jsonrpc_request(params, method) when is_map(params) and is_binary(method) do
    JSONRPC.request(method, params, generate_id())
  end

  @doc """
  Standard JSON-RPC error codes.
  """
  def parse_error, do: ErrorCodes.parse_error()
  def invalid_request, do: ErrorCodes.invalid_request()
  def method_not_found, do: ErrorCodes.method_not_found()
  def invalid_params, do: ErrorCodes.invalid_params()
  def internal_error, do: ErrorCodes.internal_error()
end
