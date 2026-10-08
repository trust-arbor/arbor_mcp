defmodule Arbor.MCP.Protocol.RequestProcessor do
  @moduledoc """
  Processes JSON-RPC requests for MCP servers.

  This module handles:
  - Request routing based on method name
  - Standard MCP method implementations
  - Delegation to custom handlers
  - Response building for each method type

  ## Supported Methods

  - `initialize` - Protocol handshake and capability negotiation
  - `tools/list` - List available tools
  - `tools/call` - Execute a tool
  - `resources/list` - List available resources
  - `resources/read` - Read a resource
  - `prompts/list` - List available prompts
  - `prompts/get` - Get a prompt
  - `notifications/initialized` - Client initialization complete
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.{Initialize, Methods, ResponseBuilder}
  alias Arbor.MCP.Server.{Context, Discover, MRTR, RequestContext, ResultNormalizer}

  @type request :: map()
  @type state :: map()
  @type process_result ::
          {:response, map(), state()}
          | {:notification, state()}
          | {:async, state()}

  @doc """
  Processes a JSON-RPC request and returns the appropriate response.

  Returns:
  - `{:response, response_map, new_state}` - Synchronous response
  - `{:notification, new_state}` - For notifications (no response needed)
  - `{:async, new_state}` - For async operations (response sent separately)

  ## Examples

      iex> request = %{"method" => "tools/list", "id" => 123}
      iex> RequestProcessor.process(request, state)
      {:response, %{"jsonrpc" => "2.0", "id" => 123, "result" => %{"tools" => []}}, state}
  """
  @spec process(request(), state()) :: process_result()
  def process(%{"method" => method} = request, state) do
    params = Map.get(request, "params") || %{}
    mrtr_opts = state_mrtr_opts(state)

    with {:ok, request_context} <- RequestContext.from_message(request),
         :ok <-
           RequestContext.validate_protocol_mode(request_context, Map.get(state, :protocol_mode)),
         :ok <- RequestContext.validate_method(request_context),
         {:ok, request_context} <- MRTR.prepare_context(request_context, params, mrtr_opts) do
      request_id = Map.get(request, "id", "notification_#{System.unique_integer([:positive])}")
      server = Map.get(state, :__module__, :unknown)

      metadata = %{
        request_id: to_string(request_id),
        method: method,
        server: server
      }

      request =
        request
        |> Map.put(:__request_context__, request_context)
        |> Map.put(:__mrtr_opts__, mrtr_opts)

      Arbor.MCP.Telemetry.span([:arbor_mcp, :request], metadata, fn ->
        method
        |> dispatch_method(request, state)
        |> normalize_protocol_result(request_context, state)
      end)
    else
      {:error, %Error.ProtocolError{} = error} ->
        if Map.has_key?(request, "id") do
          {:response, ResponseBuilder.build_error_response(error, Map.get(request, "id")), state}
        else
          {:notification, state}
        end

      {:error, reason} ->
        if Map.has_key?(request, "id") do
          response =
            RequestContext.error_response(
              reason,
              Map.get(request, "id"),
              Map.get(state, :protocol_mode)
            )

          {:response, response, state}
        else
          {:notification, state}
        end
    end
  end

  def process(_request, state) do
    # Invalid request format
    error = Error.protocol_error(-32600, "Invalid Request")
    error_response = ResponseBuilder.build_error_response(error, nil)
    {:response, error_response, state}
  end

  @doc false
  @spec dispatched_methods() :: [String.t()]
  def dispatched_methods, do: Map.keys(Methods.handler_map(:request_processor))

  for {method, handler} <- Methods.handler_map(:request_processor) do
    defp dispatch_method(unquote(method), req, state), do: unquote(handler)(req, state)
  end

  defp dispatch_method(_, req, state), do: process_unknown_method(req, state)

  # Initialize request processing
  defp process_initialize(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    module = state.__module__

    # Check if the module has custom handle_initialize implementation
    if function_exported?(module, :handle_initialize, 2) do
      case module.handle_initialize(params, state) do
        {:ok, result, new_state} ->
          result = Initialize.build_initialize_result(params, result)
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, reason)
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      # Default DSL server initialization
      process_default_initialize(id, params, state)
    end
  end

  defp process_default_initialize(id, params, state) do
    client_version = Map.get(params, "protocolVersion", VersionRegistry.preferred_version())
    supported_versions = VersionRegistry.supported_versions()

    if client_version in supported_versions do
      result =
        Initialize.build_initialize_result(params, %{
          "protocolVersion" => client_version,
          "serverInfo" => get_server_info(state),
          "capabilities" => get_capabilities(state)
        })

      response = ResponseBuilder.build_success_response(result, id)
      new_state = Map.put(state, :protocol_version, client_version)
      {:response, response, new_state}
    else
      error =
        Error.protocol_error(
          -32600,
          "Unsupported protocol version: #{client_version}",
          %{"supported_versions" => supported_versions}
        )

      error_response = ResponseBuilder.build_error_response(error, id)

      {:response, error_response, state}
    end
  end

  defp process_server_discover(%{"id" => id}, state) do
    result =
      Discover.build(get_server_info(state), get_capabilities(state),
        protocol_mode: Map.get(state, :protocol_mode, VersionRegistry.protocol_mode()),
        instructions: Map.get(state, :instructions)
      )

    response = ResponseBuilder.build_success_response(result, id)
    {:response, response, state}
  end

  # Tools list request
  defp process_tools_list(%{"id" => id}, state) do
    module = state.__module__

    if function_exported?(module, :handle_list_tools, 2) do
      case module.handle_list_tools(nil, state) do
        {:ok, tools, next_cursor, new_state} ->
          result = %{"tools" => ResultNormalizer.stringify_keys(tools)}
          result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      response = ResponseBuilder.build_success_response(%{"tools" => []}, id)
      {:response, response, state}
    end
  end

  # Tools call request - delegates to handle_call for async processing
  defp process_tools_call(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    module = state.__module__

    if function_exported?(module, :handle_call_tool, 3) do
      execute_tool_call(module, tool_name, arguments, id, request, state)
    else
      # No custom implementation, return default error
      error = %Error.ToolError{
        tool_name: tool_name || "unknown",
        reason: "Tool not implemented",
        arguments: nil
      }

      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Execute tool call with telemetry
  defp execute_tool_call(module, tool_name, arguments, id, request, state) do
    metadata = %{
      tool_name: tool_name || "unknown",
      request_id: to_string(id)
    }

    result =
      Arbor.MCP.Telemetry.span([:arbor_mcp, :tool], metadata, fn ->
        Context.with_context(request.__request_context__, fn ->
          module.handle_call_tool(tool_name, arguments, state)
        end)
      end)

    handle_tool_result(result, tool_name, id, request)
  end

  # Handle tool execution result
  defp handle_tool_result(
         {:ok, %MRTR.InputRequired{} = required, new_state},
         _tool_name,
         id,
         request
       ) do
    build_mrtr_response(required.input_requests, required.request_state, id, request, new_state)
  end

  defp handle_tool_result({:input_required, requests, new_state}, _tool_name, id, request) do
    build_mrtr_response(requests, nil, id, request, new_state)
  end

  defp handle_tool_result(
         {:input_required, requests, application_state, new_state},
         _tool_name,
         id,
         request
       ) do
    build_mrtr_response(requests, application_state, id, request, new_state)
  end

  defp handle_tool_result({:ok, result, new_state}, _tool_name, id, _request) do
    tool_result = ResultNormalizer.tool_result(result)
    response = ResponseBuilder.build_success_response(tool_result, id)
    {:response, response, new_state}
  end

  defp handle_tool_result({:error, reason, new_state}, tool_name, id, _request) do
    error = normalize_error(reason, tool_name)
    error_response = ResponseBuilder.build_error_response(error, id)
    {:response, error_response, new_state}
  end

  # Normalize various error formats to Error structs
  defp normalize_error(%Error.ProtocolError{} = err, _tool_name), do: err
  defp normalize_error(%Error.TransportError{} = err, _tool_name), do: err
  defp normalize_error(%Error.ToolError{} = err, _tool_name), do: err
  defp normalize_error(%Error.ResourceError{} = err, _tool_name), do: err
  defp normalize_error(%Error.ValidationError{} = err, _tool_name), do: err

  defp normalize_error(reason, tool_name) do
    # Create ToolError struct for plain reasons
    %Error.ToolError{
      tool_name: tool_name || "unknown",
      reason: reason,
      arguments: nil
    }
  end

  # Resources list request
  defp process_resources_list(%{"id" => id}, state) do
    module = state.__module__

    if function_exported?(module, :handle_list_resources, 2) do
      case module.handle_list_resources(nil, state) do
        {:ok, resources, next_cursor, new_state} ->
          result = %{"resources" => ResultNormalizer.stringify_keys(resources)}
          result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      response = ResponseBuilder.build_success_response(%{"resources" => []}, id)
      {:response, response, state}
    end
  end

  # Resources read request
  defp process_resources_read(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    uri = Map.get(params, "uri")
    module = state.__module__

    if function_exported?(module, :handle_read_resource, 2) do
      metadata = %{
        uri: uri || "unknown",
        request_id: to_string(id)
      }

      result =
        Arbor.MCP.Telemetry.span([:arbor_mcp, :resource, :read], metadata, fn ->
          Context.with_context(request.__request_context__, fn ->
            module.handle_read_resource(uri, state)
          end)
        end)

      handle_resource_read_result(result, uri, id, request, metadata)
    else
      # No custom implementation, return default error
      error = Error.resource_error(uri || "unknown", :read, "Resource reading not implemented")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  defp handle_resource_read_result(
         {:ok, %MRTR.InputRequired{} = required, new_state},
         _uri,
         id,
         request,
         _metadata
       ) do
    build_mrtr_response(
      required.input_requests,
      required.request_state,
      id,
      request,
      new_state
    )
  end

  defp handle_resource_read_result(
         {:input_required, requests, new_state},
         _uri,
         id,
         request,
         _metadata
       ) do
    build_mrtr_response(requests, nil, id, request, new_state)
  end

  defp handle_resource_read_result(
         {:input_required, requests, application_state, new_state},
         _uri,
         id,
         request,
         _metadata
       ) do
    build_mrtr_response(requests, application_state, id, request, new_state)
  end

  defp handle_resource_read_result({:ok, content, new_state}, _uri, id, _request, metadata) do
    case content do
      %{"text" => text} when is_binary(text) ->
        :telemetry.execute(
          [:arbor_mcp, :resource, :read, :bytes],
          %{bytes: byte_size(text)},
          metadata
        )

      _other ->
        :ok
    end

    result = %{"contents" => ResultNormalizer.stringify_keys(List.wrap(content))}
    response = ResponseBuilder.build_success_response(result, id)
    {:response, response, new_state}
  end

  defp handle_resource_read_result(
         {:error, %Error.ProtocolError{} = error, new_state},
         _uri,
         id,
         _request,
         _metadata
       ) do
    error_response = ResponseBuilder.build_error_response(error, id)
    {:response, error_response, new_state}
  end

  defp handle_resource_read_result(
         {:error, reason, new_state},
         uri,
         id,
         _request,
         _metadata
       ) do
    error = Error.resource_error(uri || "unknown", :read, reason)
    error_response = ResponseBuilder.build_error_response(error, id)
    {:response, error_response, new_state}
  end

  # Prompts list request
  defp process_prompts_list(%{"id" => id}, state) do
    module = state.__module__

    if function_exported?(module, :handle_list_prompts, 2) do
      case module.handle_list_prompts(nil, state) do
        {:ok, prompts, next_cursor, new_state} ->
          result = %{"prompts" => ResultNormalizer.stringify_keys(prompts)}
          result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      response = ResponseBuilder.build_success_response(%{"prompts" => []}, id)
      {:response, response, state}
    end
  end

  # Prompts get request
  defp process_prompts_get(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    prompt_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    module = state.__module__

    # Check if custom implementation exists
    if function_exported?(module, :handle_get_prompt, 3) do
      result =
        Context.with_context(request.__request_context__, fn ->
          module.handle_get_prompt(prompt_name, arguments, state)
        end)

      case result do
        {:ok, %MRTR.InputRequired{} = required, new_state} ->
          build_mrtr_response(
            required.input_requests,
            required.request_state,
            id,
            request,
            new_state
          )

        {:input_required, requests, new_state} ->
          build_mrtr_response(requests, nil, id, request, new_state)

        {:input_required, requests, application_state, new_state} ->
          build_mrtr_response(requests, application_state, id, request, new_state)

        {:ok, result, new_state} ->
          result = ResultNormalizer.stringify_keys(result)
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, %Error.ProtocolError{} = error, new_state} ->
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}

        {:error, reason, new_state} ->
          # Handler-authored detail only; other terms are logged (audit M12).
          message = ResultNormalizer.error_message("Prompt error", reason)
          error = Error.protocol_error(-32000, message)
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      # No custom implementation, return default error
      error = Error.protocol_error(-32000, "Prompt retrieval not implemented")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Initialized notification
  defp process_initialized_notification(_request, state) do
    # This is a notification from client, not a request - just acknowledge it
    {:notification, state}
  end

  # Elicitation complete notification (2025-11-25)
  defp process_elicitation_complete(%{"params" => params}, state) do
    module = state.__module__
    elicitation_id = Map.get(params, "elicitationId", "")

    if function_exported?(module, :handle_elicitation_complete, 2) do
      case module.handle_elicitation_complete(elicitation_id, state) do
        {:ok, new_state} -> {:notification, new_state}
        {:error, _reason, new_state} -> {:notification, new_state}
      end
    else
      {:notification, state}
    end
  end

  defp process_elicitation_complete(_request, state), do: {:notification, state}

  # Task status notification (2025-11-25)
  defp process_task_status_notification(_request, state), do: {:notification, state}

  defp build_mrtr_response(input_requests, application_state, id, request, state) do
    case MRTR.build_result(
           request.__request_context__,
           Map.get(request, "params") || %{},
           input_requests,
           application_state,
           request.__mrtr_opts__
         ) do
      {:ok, result} ->
        {:response, ResponseBuilder.build_success_response(result, id), state}

      {:error, error} ->
        {:response, ResponseBuilder.build_error_response(error, id), state}
    end
  end

  defp state_mrtr_opts(state) do
    [
      request_state: Map.get(state, :request_state),
      endpoint: Map.get(state, :endpoint),
      principal_id: Map.get(state, :principal_id),
      tenant_id: Map.get(state, :tenant_id),
      max_input_requests: Map.get(state, :max_input_requests, 16),
      max_mrtr_bytes: Map.get(state, :max_mrtr_bytes, 1_048_576),
      replay_cache: Map.get(state, :replay_cache),
      require_replay_protection: Map.get(state, :require_replay_protection, false)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Tasks/get (2025-11-25)
  defp process_task_get(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    task_id = Map.get(params, "taskId")
    module = state.__module__

    if function_exported?(module, :handle_task_get, 2) do
      case Context.with_context(request.__request_context__, fn ->
             module.handle_task_get(task_id, state)
           end) do
        {:ok, result, new_state} ->
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      error = Error.protocol_error(-32601, "Method not found: tasks/get")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Tasks/list (2025-11-25)
  defp process_task_list(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    cursor = Map.get(params, "cursor")
    module = state.__module__

    if function_exported?(module, :handle_task_list, 2) do
      case Context.with_context(request.__request_context__, fn ->
             module.handle_task_list(cursor, state)
           end) do
        {:ok, tasks, next_cursor, new_state} ->
          result = %{"tasks" => tasks}
          result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      error = Error.protocol_error(-32601, "Method not found: tasks/list")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Tasks/result (2025-11-25)
  defp process_task_result(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    task_id = Map.get(params, "taskId")
    module = state.__module__

    if function_exported?(module, :handle_task_result, 2) do
      case Context.with_context(request.__request_context__, fn ->
             module.handle_task_result(task_id, state)
           end) do
        {:ok, result, new_state} ->
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      error = Error.protocol_error(-32601, "Method not found: tasks/result")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Tasks/cancel (2025-11-25)
  defp process_task_cancel(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    task_id = Map.get(params, "taskId")
    module = state.__module__

    if function_exported?(module, :handle_task_cancel, 2) do
      case Context.with_context(request.__request_context__, fn ->
             module.handle_task_cancel(task_id, state)
           end) do
        {:ok, result, new_state} ->
          response = ResponseBuilder.build_success_response(result, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      error = Error.protocol_error(-32601, "Method not found: tasks/cancel")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Tasks/update (io.modelcontextprotocol/tasks extension)
  defp process_task_update(%{"id" => id} = request, state) do
    params = Map.get(request, "params", %{})
    task_id = Map.get(params, "taskId")
    input_responses = Map.get(params, "inputResponses")
    module = state.__module__

    if function_exported?(module, :handle_task_update, 3) do
      case Context.with_context(request.__request_context__, fn ->
             module.handle_task_update(task_id, input_responses, state)
           end) do
        {:ok, _result, new_state} ->
          response = ResponseBuilder.build_success_response(%{}, id)
          {:response, response, new_state}

        {:error, reason, new_state} ->
          error = Error.protocol_error(-32000, to_string(reason))
          error_response = ResponseBuilder.build_error_response(error, id)
          {:response, error_response, new_state}
      end
    else
      error = Error.protocol_error(-32601, "Method not found: tasks/update")
      error_response = ResponseBuilder.build_error_response(error, id)
      {:response, error_response, state}
    end
  end

  # Unknown method
  defp process_unknown_method(%{"method" => method, "id" => id}, state) do
    error = Error.protocol_error(-32601, "Method not found: #{method}")
    error_response = ResponseBuilder.build_error_response(error, id)
    {:response, error_response, state}
  end

  defp get_server_info(state) do
    if function_exported?(state.__module__, :get_server_info_from_opts, 0) do
      state.__module__.get_server_info_from_opts()
    else
      %{"name" => "Arbor.MCP Server", "version" => "0.1.0"}
    end
  end

  defp get_capabilities(state) do
    if function_exported?(state.__module__, :get_capabilities, 0) do
      state.__module__.get_capabilities()
    else
      %{}
    end
  end

  defp normalize_protocol_result(
         {:response, %{"result" => result} = response, new_state},
         request_context,
         state
       ) do
    case ResultNormalizer.validate_result_capabilities(result, request_context) do
      :ok ->
        result =
          ResultNormalizer.protocol_result(result, request_context,
            server_info: get_server_info(state)
          )

        {:response, Map.put(response, "result", result), new_state}

      {:error, error} ->
        error_response = ResponseBuilder.build_error_response(error, response["id"])
        {:response, error_response, new_state}
    end
  end

  defp normalize_protocol_result(other, _request_context, _state), do: other
end
