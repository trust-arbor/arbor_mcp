defmodule Arbor.MCP.MessageProcessor.MethodHandlers do
  @moduledoc false

  # HTTP-side MCP method table.
  #
  # Unlike Arbor.MCP.Server.Dispatch, this path talks to a handler *process* over
  # GenServer.call/3, so it owns crash/timeout handling. Method coverage
  # mirrors Arbor.MCP.Server.Dispatch and all result/error shaping is delegated to
  # Arbor.MCP.Server.ResultNormalizer, so both paths answer identically (audit M9).

  alias Arbor.MCP.Error
  alias Arbor.MCP.MessageProcessor.Conn
  alias Arbor.MCP.Protocol.{ErrorCodes, Initialize}
  alias Arbor.MCP.Server.{Discover, Dispatch, MRTR, ResultNormalizer}
  alias Arbor.MCP.Transport.HTTP.ToolHeaders
  alias Arbor.RPC.JSONRPC

  require Logger

  # Default timeout for GenServer calls into handler processes. Override per
  # request via the `:handler_call_timeout` option of
  # `Arbor.MCP.MessageProcessor.process/2`.
  @default_handler_call_timeout 10_000

  def handle_initialize(conn, server_pid, params, id, server_info) do
    safe_call(conn, server_pid, {:initialize, params}, id, "Initialize failed", fn
      {:ok, result} -> put_initialize_result(conn, params, result, server_info, id)
      {:error, reason} -> put_error(conn, "Initialize failed", reason, id)
    end)
  end

  def handle_server_discover(conn, _server_pid, _params, id) do
    result =
      Discover.build(
        Map.get(conn.assigns, :server_info, %{}),
        Map.get(conn.assigns, :server_capabilities, %{}),
        protocol_mode: Map.get(conn.assigns, :protocol_mode),
        instructions: Map.get(conn.assigns, :instructions)
      )

    put_success(conn, result, id)
  end

  def handle_tools_list(conn, server_pid, params, id) do
    list_call(conn, server_pid, {:list_tools, cursor(params)}, id, "Tools list failed", "tools")
  end

  def handle_tools_call(conn, server_pid, params, id) do
    tool_name = Map.get(params, "name")
    arguments = Dispatch.tool_arguments(params)

    :telemetry.execute(
      [:arbor_mcp, :server, :tool, :called],
      %{},
      %{tool_name: tool_name, mode: :handler}
    )

    case validate_tool_request_headers(conn, server_pid, tool_name, params) do
      :ok ->
        safe_call(
          conn,
          server_pid,
          contextual_request(conn, server_pid, {:call_tool, tool_name, arguments}),
          id,
          "Tool call failed",
          fn reply ->
            case put_mrtr_result(conn, params, reply, id) do
              {:handled, conn} -> conn
              :not_mrtr -> handle_tool_reply(conn, reply, id)
            end
          end
        )

      {:error, :tool_schema_unavailable} ->
        put_failure(conn, "Tool schema unavailable", "tool_schema_unavailable", id)

      {:error, message} ->
        conn
        |> Conn.assign(:http_status, 400)
        |> Map.put(:response, JSONRPC.error(id, ErrorCodes.header_mismatch(), message))
    end
  end

  def handle_resources_list(conn, server_pid, params, id) do
    list_call(
      conn,
      server_pid,
      {:list_resources, cursor(params)},
      id,
      "Resources list failed",
      "resources"
    )
  end

  def handle_resource_templates_list(conn, server_pid, params, id) do
    list_call(
      conn,
      server_pid,
      {:list_resource_templates, cursor(params)},
      id,
      "Resource templates list failed",
      "resourceTemplates"
    )
  end

  def handle_resources_read(conn, server_pid, params, id) do
    uri = Map.get(params, "uri")

    :telemetry.execute(
      [:arbor_mcp, :server, :resource, :read],
      %{},
      %{uri: uri, mode: :handler}
    )

    safe_call(
      conn,
      server_pid,
      contextual_request(conn, server_pid, {:read_resource, uri}),
      id,
      "Resource read failed",
      fn reply ->
        case put_mrtr_result(conn, params, reply, id) do
          {:handled, conn} -> conn
          :not_mrtr -> handle_resource_reply(conn, reply, id)
        end
      end
    )
  end

  def handle_resources_subscribe(conn, server_pid, params, id) do
    uri = Map.get(params, "uri")

    safe_call(conn, server_pid, {:subscribe_resource, uri}, id, "Subscribe failed", fn
      {:ok, _result} -> register_subscription(conn, uri, id)
      {:error, reason} -> put_error(conn, "Subscribe failed", reason, id)
    end)
  end

  def handle_resources_unsubscribe(conn, server_pid, params, id) do
    uri = Map.get(params, "uri")

    safe_call(conn, server_pid, {:unsubscribe_resource, uri}, id, "Unsubscribe failed", fn
      {:ok, _result} -> unregister_subscription(conn, uri, id)
      {:error, reason} -> put_error(conn, "Unsubscribe failed", reason, id)
    end)
  end

  defp register_subscription(%{session_id: session_id} = conn, uri, id)
       when is_binary(session_id) do
    case Arbor.MCP.SubscriptionRegistry.subscribe(session_id, uri) do
      :ok -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Subscribe failed", reason, id)
    end
  end

  defp register_subscription(conn, _uri, id), do: put_success(conn, %{}, id)

  defp unregister_subscription(%{session_id: session_id} = conn, uri, id)
       when is_binary(session_id) do
    :ok = Arbor.MCP.SubscriptionRegistry.unsubscribe(session_id, uri)
    put_success(conn, %{}, id)
  end

  defp unregister_subscription(conn, _uri, id), do: put_success(conn, %{}, id)

  def handle_prompts_list(conn, server_pid, params, id) do
    list_call(
      conn,
      server_pid,
      {:list_prompts, cursor(params)},
      id,
      "Prompts list failed",
      "prompts"
    )
  end

  def handle_prompts_get(conn, server_pid, params, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:arbor_mcp, :server, :prompt, :rendered],
      %{},
      %{name: name, mode: :handler}
    )

    safe_call(
      conn,
      server_pid,
      contextual_request(conn, server_pid, {:get_prompt, name, arguments}),
      id,
      "Prompt get failed",
      fn reply ->
        case put_mrtr_result(conn, params, reply, id) do
          {:handled, conn} -> conn
          :not_mrtr -> handle_prompt_reply(conn, reply, id)
        end
      end
    )
  end

  def handle_completion_complete(conn, server_pid, params, id) do
    request = {:complete, Map.get(params, "ref"), Map.get(params, "argument")}

    safe_call(conn, server_pid, request, id, "Completion failed", fn
      {:ok, result} -> put_success(conn, ResultNormalizer.stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Completion failed", reason, id)
    end)
  end

  # Routed through the handler rather than short-circuited with a canned
  # success, so servers can actually observe the level change (audit M10).
  def handle_set_log_level(conn, server_pid, params, id) do
    level = Map.get(params, "level")

    safe_call(conn, server_pid, {:set_log_level, level}, id, "Set log level failed", fn
      {:ok, _result} -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Set log level failed", reason, id)
    end)
  end

  def handle_roots_list(conn, server_pid, _params, id) do
    safe_call(conn, server_pid, {:list_roots}, id, "Roots list failed", fn
      {:ok, roots} ->
        put_success(conn, %{"roots" => ResultNormalizer.stringify_keys(List.wrap(roots))}, id)

      {:error, reason} ->
        put_error(conn, "Roots list failed", reason, id)
    end)
  end

  # Task methods (2025-11-25). Previously unreachable on this path: the
  # handler bridge answered "Unknown method" for them (audit M15).
  def handle_task_get(conn, server_pid, params, id) do
    request = task_request(conn, server_pid, {:task_get, Map.get(params, "taskId")})

    safe_call(conn, server_pid, request, id, "Task get failed", fn
      {:ok, result} -> put_success(conn, ResultNormalizer.stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Task get failed", reason, id)
    end)
  end

  def handle_task_result(conn, server_pid, params, id) do
    request = task_request(conn, server_pid, {:task_result, Map.get(params, "taskId")})

    safe_call(conn, server_pid, request, id, "Task result failed", fn
      {:ok, result} -> put_success(conn, ResultNormalizer.stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Task result failed", reason, id)
    end)
  end

  def handle_task_cancel(conn, server_pid, params, id) do
    request = task_request(conn, server_pid, {:task_cancel, Map.get(params, "taskId")})

    safe_call(conn, server_pid, request, id, "Task cancel failed", fn
      {:ok, result} -> put_success(conn, ResultNormalizer.stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Task cancel failed", reason, id)
    end)
  end

  def handle_task_update(conn, server_pid, params, id) do
    request =
      task_request(
        conn,
        server_pid,
        {:task_update, Map.get(params, "taskId"), Map.get(params, "inputResponses")}
      )

    safe_call(conn, server_pid, request, id, "Task update failed", fn
      {:ok, _result} -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Task update failed", reason, id)
    end)
  end

  def handle_task_list(conn, server_pid, params, id) do
    request = task_request(conn, server_pid, {:task_list, cursor(params)})
    list_call(conn, server_pid, request, id, "Task list failed", "tasks")
  end

  @doc """
  Handles a method outside the MCP method table via the handler's
  `{:request, method, params}` escape hatch.

  Only an explicit "unknown method" answer maps to `-32601`; handler errors,
  crashes and timeouts map to `-32603` so genuine failures are not disguised
  as a missing method (audit M11).
  """
  def handle_custom_method(conn, server_pid, method, params, id) do
    reply = GenServer.call(server_pid, {:request, method, params}, call_timeout(conn))

    case normalize_reply(reply) do
      {:ok, result} ->
        put_success(conn, ResultNormalizer.stringify_keys(result), id)

      {:error, reason} ->
        if unknown_method?(reason) do
          put_method_not_found(conn, id)
        else
          put_error(conn, "Method failed", reason, id)
        end
    end
  rescue
    error ->
      Logger.error("Custom method #{method}: #{Exception.format(:error, error, __STACKTRACE__)}")
      put_failure(conn, "Method failed", "handler_crash", id)
  catch
    :exit, reason ->
      Logger.error("Custom method #{method}: handler exited: #{inspect(reason)}")
      put_failure(conn, "Method failed", exit_failure_type(reason), id)
  end

  # The handler bridge reports an unimplemented method as "Unknown method: x".
  # Anything else is a real failure.
  defp unknown_method?(reason) when is_binary(reason), do: reason =~ "Unknown method"
  defp unknown_method?(:unknown_method), do: true
  defp unknown_method?({:unknown_method, _}), do: true
  defp unknown_method?({:unexpected_reply, _}), do: false
  defp unknown_method?(_reason), do: false

  # Calls the handler process, converting raised exceptions *and* exits
  # (handler crash, :noproc, call timeout) into JSON-RPC internal errors so
  # that a misbehaving handler can never crash the request process.
  defp safe_call(conn, server_pid, request, id, label, on_reply) do
    reply = GenServer.call(server_pid, request, call_timeout(conn))

    reply
    |> normalize_reply()
    |> on_reply.()
  rescue
    error ->
      Logger.error("#{label}: #{Exception.format(:error, error, __STACKTRACE__)}")
      put_failure(conn, label, "handler_crash", id)
  catch
    :exit, reason ->
      Logger.error("#{label}: handler exited: #{inspect(reason)}")
      put_failure(conn, label, exit_failure_type(reason), id)
  end

  # Paginated list methods: handlers may answer with entries plus a cursor, or
  # with a ready-made result map.
  defp list_call(conn, server_pid, request, id, label, key) do
    reply = GenServer.call(server_pid, request, call_timeout(conn))

    case normalize_list_reply(reply) do
      {:list, entries, next_cursor} ->
        key
        |> ResultNormalizer.paginated(ResultNormalizer.stringify_keys(entries), next_cursor)
        |> put_success_result(conn, id)

      {:result, result} ->
        result
        |> ResultNormalizer.stringify_keys()
        |> put_success_result(conn, id)

      {:error, reason} ->
        put_error(conn, label, reason, id)
    end
  rescue
    error ->
      Logger.error("#{label}: #{Exception.format(:error, error, __STACKTRACE__)}")
      put_failure(conn, label, "handler_crash", id)
  catch
    :exit, reason ->
      Logger.error("#{label}: handler exited: #{inspect(reason)}")
      put_failure(conn, label, exit_failure_type(reason), id)
  end

  # Collapses every reply shape a handler process may produce into one of
  # `{:ok, result}` / `{:error, reason}` (audit M13). `Arbor.MCP.Server.Handler`'s
  # GenServer bridge now emits the canonical shapes; the legacy variants stay
  # accepted here for hand-written handlers.
  defp normalize_reply(:ok), do: {:ok, %{}}

  defp normalize_reply({:input_required, requests, application_state}),
    do: {:input_required, requests, application_state}

  defp normalize_reply({:ok, result}), do: {:ok, result}
  defp normalize_reply({:ok, result, _state}), do: {:ok, result}
  defp normalize_reply({:error, reason}), do: {:error, reason}
  defp normalize_reply({:error, reason, _state}), do: {:error, reason}
  defp normalize_reply(other), do: {:error, {:unexpected_reply, other}}

  defp normalize_list_reply({:ok, entries, next_cursor, _state}) when is_list(entries),
    do: {:list, entries, next_cursor}

  defp normalize_list_reply({:ok, entries, next_cursor})
       when is_list(entries) and (is_nil(next_cursor) or is_binary(next_cursor)),
       do: {:list, entries, next_cursor}

  defp normalize_list_reply({:ok, entries}) when is_list(entries), do: {:list, entries, nil}
  defp normalize_list_reply({:ok, result, _state}) when is_map(result), do: {:result, result}
  defp normalize_list_reply({:ok, result}) when is_map(result), do: {:result, result}
  defp normalize_list_reply(other), do: normalize_reply(other)

  defp validate_tool_request_headers(
         %{assigns: %{request_context: %{era: :modern}}} = conn,
         server_pid,
         tool_name,
         params
       ) do
    with {:ok, tools} <- load_tools_for_header_validation(server_pid, conn),
         tool when is_map(tool) <- find_tool(tools, tool_name),
         {:ok, annotations} <- ToolHeaders.compile(tool) do
      ToolHeaders.validate_request(
        Map.get(conn.assigns, :request_headers, []),
        annotations,
        Map.get(params, "arguments", %{})
      )
    else
      nil -> :ok
      {:error, :tool_schema_unavailable} = error -> error
      {:error, _invalid_annotation} -> {:error, "Tool x-mcp-header annotations are invalid"}
    end
  end

  defp validate_tool_request_headers(_conn, _server_pid, _tool_name, _params), do: :ok

  defp load_tools_for_header_validation(server_pid, conn) do
    case GenServer.call(server_pid, {:list_tools, nil}, call_timeout(conn))
         |> normalize_list_reply() do
      {:list, tools, _cursor} -> {:ok, ResultNormalizer.stringify_keys(tools)}
      {:result, result} -> {:ok, Map.get(ResultNormalizer.stringify_keys(result), "tools", [])}
      {:error, _reason} -> {:error, :tool_schema_unavailable}
    end
  rescue
    _error -> {:error, :tool_schema_unavailable}
  catch
    :exit, _reason -> {:error, :tool_schema_unavailable}
  end

  defp find_tool(tools, name) when is_list(tools) do
    Enum.find(tools, &(Map.get(&1, "name") == name))
  end

  defp find_tool(_tools, _name), do: nil

  defp cursor(params), do: Map.get(params, "cursor")

  defp contextual_request(conn, server_pid, request) do
    if handler_context_capable?(server_pid) do
      case Map.get(conn.assigns, :request_context) do
        nil -> request
        context -> {:mcp_context, context, request}
      end
    else
      request
    end
  end

  # `use Arbor.MCP.Server.Handler` understands the scoped context envelope. Keep
  # the original request tuple for hand-written GenServers that implement only
  # the documented legacy bridge messages.
  defp task_request(conn, server_pid, request) do
    contextual_request(conn, server_pid, request)
  end

  defp handler_context_capable?(server_pid) when is_pid(server_pid) do
    {module, _function, _arity} = :proc_lib.translate_initial_call(server_pid)
    function_exported?(module, :__task_store_options__, 0)
  rescue
    _error -> false
  end

  defp handler_context_capable?(_server), do: false

  defp put_mrtr_result(conn, params, reply, id) do
    case mrtr_reply(reply) do
      {:ok, input_requests, application_state} ->
        context = Map.fetch!(conn.assigns, :request_context)
        opts = Map.get(conn.assigns, :mrtr_opts, [])

        case MRTR.build_result(context, params, input_requests, application_state, opts) do
          {:ok, result} -> {:handled, put_success(conn, result, id)}
          {:error, reason} -> {:handled, put_error(conn, "MRTR failed", reason, id)}
        end

      :not_mrtr ->
        :not_mrtr
    end
  end

  defp mrtr_reply({:input_required, requests, application_state}),
    do: {:ok, requests, application_state}

  defp mrtr_reply({:ok, %MRTR.InputRequired{} = required}),
    do: {:ok, required.input_requests, required.request_state}

  defp mrtr_reply(_reply), do: :not_mrtr

  defp handle_tool_reply(conn, {:ok, result}, id),
    do: put_success(conn, ResultNormalizer.tool_result(result), id)

  defp handle_tool_reply(conn, {:error, %Error.ProtocolError{} = error}, id),
    do: put_error(conn, "Tool call failed", error, id)

  defp handle_tool_reply(conn, {:error, reason}, id) do
    message = reason_message(reason)

    if ResultNormalizer.unknown_name_reason?(message) do
      put_error(conn, "Tool call failed", Error.protocol_error(-32602, message), id)
    else
      put_success(conn, ResultNormalizer.tool_error_result(reason), id)
    end
  end

  defp reason_message(reason) when is_binary(reason), do: reason

  defp reason_message(reason) do
    cond do
      is_atom(reason) -> Atom.to_string(reason)
      is_exception(reason) -> Exception.message(reason)
      true -> inspect(reason)
    end
  end

  defp handle_resource_reply(conn, {:ok, contents}, id) do
    contents = ResultNormalizer.stringify_keys(List.wrap(contents))
    put_success(conn, %{"contents" => contents}, id)
  end

  defp handle_resource_reply(conn, {:error, %Error.ProtocolError{} = error}, id),
    do: put_error(conn, "Resource read failed", error, id)

  defp handle_resource_reply(conn, {:error, reason}, id) do
    message = reason_message(reason)

    if ResultNormalizer.unknown_name_reason?(message) do
      put_error(
        conn,
        "Resource read failed",
        Error.protocol_error(ResultNormalizer.error_code(message, -32602), message),
        id
      )
    else
      put_error(conn, "Resource read failed", reason, id)
    end
  end

  defp handle_prompt_reply(conn, {:ok, result}, id),
    do: put_success(conn, ResultNormalizer.stringify_keys(result), id)

  defp handle_prompt_reply(conn, {:error, %Error.ProtocolError{} = error}, id),
    do: put_error(conn, "Prompt get failed", error, id)

  defp handle_prompt_reply(conn, {:error, reason}, id) do
    message = reason_message(reason)

    if ResultNormalizer.unknown_name_reason?(message) do
      put_error(
        conn,
        "Prompt get failed",
        Error.protocol_error(ResultNormalizer.error_code(message, -32602), message),
        id
      )
    else
      put_error(conn, "Prompt get failed", reason, id)
    end
  end

  defp call_timeout(conn) do
    Map.get(conn.assigns, :handler_call_timeout, @default_handler_call_timeout)
  end

  defp exit_failure_type({:timeout, _}), do: "handler_timeout"
  defp exit_failure_type(_reason), do: "handler_crash"

  defp put_initialize_result(conn, params, result, server_info, id) do
    result
    |> put_default_server_info(server_info)
    |> then(&Initialize.build_initialize_result(params, &1))
    |> then(&put_success(conn, &1, id))
  end

  defp put_default_server_info(result, server_info) do
    if Map.has_key?(result, "serverInfo") or Map.has_key?(result, :serverInfo) or
         Map.has_key?(result, "name") or Map.has_key?(result, :name) do
      result
    else
      Map.put(result, "serverInfo", server_info)
    end
  end

  defp put_success_result(result, conn, id), do: put_success(conn, result, id)
  defp put_success(conn, result, id), do: %{conn | response: JSONRPC.response(id, result)}

  # Error details are logged, never embedded in the JSON-RPC response: the
  # `data.type` field carries a stable, machine-readable classification
  # instead of `inspect(reason)` output (audit M12).
  defp put_error(conn, _message, %Error.ProtocolError{} = error, id) do
    conn =
      if error.code == ErrorCodes.missing_required_client_capability(),
        do: Conn.assign(conn, :http_status, 400),
        else: conn

    %{conn | response: JSONRPC.error(id, Error.to_json_rpc(error))}
  end

  defp put_error(conn, message, reason, id) do
    Logger.error("#{message}: #{inspect(reason)}")
    put_failure(conn, message, "handler_error", id)
  end

  defp put_failure(conn, message, type, id) do
    %{conn | response: JSONRPC.error(id, -32603, message, %{"type" => type})}
  end

  defp put_method_not_found(conn, id) do
    conn =
      case conn.assigns do
        %{request_context: %{era: :modern}} ->
          Conn.assign(conn, :http_status, 404)

        _legacy_or_unscoped ->
          conn
      end

    %{conn | response: JSONRPC.error(id, -32601, "Method not found")}
  end
end
