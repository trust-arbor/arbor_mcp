defmodule Arbor.MCP.Server.Dispatch do
  @moduledoc """
  Single MCP method table for handler modules invoked with their own state.

  `Arbor.MCP.Server.HandlerServer` (test/BEAM transports) and
  `Arbor.MCP.Server.StdioServer` both drive an `Arbor.MCP.Server.Handler` module by
  calling its callbacks with the handler state and turning the return value
  into a JSON-RPC response. They used to carry two independently maintained
  copies of that table, which drifted: stdio never implemented
  `completion/complete`, `resources/subscribe`, `roots/list`,
  `logging/setLevel` or the task methods, and the two copies normalized tool
  results differently.

  This module owns the table. Transports keep their own framing (stdout lines
  vs. transport `send_message/2`), batching, and cancellation bookkeeping, and
  delegate callback invocation plus result shaping here. Shaping itself lives
  in `Arbor.MCP.Server.ResultNormalizer`, which the HTTP message processor also
  shares, so every transport agrees
  on tool-result shape and on which error detail is safe to return.

  ## Return value

  * `{:response, response_map, new_handler_state}` for requests
  * `{:notification, new_handler_state}` for notifications (no response)

  Callbacks that `Arbor.MCP.Server.Handler` marks optional are probed with
  `function_exported?/3`; a handler that does not implement one answers
  `-32601 Method not found`.
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.MessageValidator
  alias Arbor.MCP.Protocol.{ErrorCodes, Initialize, Methods}
  alias Arbor.MCP.Server.{Context, Discover, MRTR, RequestContext, ResultNormalizer}
  alias Arbor.RPC.JSONRPC

  @type handler_state :: term()
  @type result ::
          {:response, map(), handler_state()} | {:notification, handler_state()}

  @doc """
  Returns the list of MCP methods handled by this dispatcher.
  """
  @spec methods() :: [String.t()]
  def methods, do: Methods.methods_for(:server_dispatch)

  @doc """
  Whether `method` is part of the shared MCP method table.
  """
  @spec known_method?(String.t()) :: boolean()
  def known_method?(method), do: method in Methods.methods_for(:server_dispatch)

  @doc """
  Dispatches a decoded JSON-RPC request or notification to `handler_module`.
  """
  @spec dispatch(map(), module(), handler_state()) :: result()
  def dispatch(request, handler_module, handler_state) do
    dispatch(request, handler_module, handler_state, [])
  end

  @doc false
  @spec dispatch(map(), module(), handler_state(), keyword()) :: result()
  def dispatch(request, handler_module, handler_state, opts)

  def dispatch(%{"method" => method} = request, handler_module, state, opts) do
    params = if Map.has_key?(request, "params"), do: Map.get(request, "params"), else: %{}

    case MessageValidator.validate_method_params(method, params) do
      :ok -> dispatch_validated(request, method, params, handler_module, state, opts)
      {:error, error} -> parameter_error_result(request, error, state)
    end
  end

  def dispatch(_invalid_request, _handler_module, state, _opts) do
    {:response, JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid Request"), state}
  end

  defp dispatch_validated(request, method, params, handler_module, state, opts) do
    case RequestContext.from_message(request) do
      {:ok, request_context} ->
        with :ok <-
               RequestContext.validate_protocol_mode(
                 request_context,
                 Keyword.get(opts, :protocol_mode)
               ),
             :ok <- RequestContext.validate_method(request_context),
             {:ok, request_context} <- MRTR.prepare_context(request_context, params, opts) do
          request_context = %{
            request_context
            | application_context: Keyword.get(opts, :application_context),
              notification_target: Keyword.get(opts, :request_notification_target)
          }

          ctx = %{
            method: method,
            id: Map.get(request, "id"),
            params: params,
            request?: Map.has_key?(request, "id"),
            request_context: request_context,
            module: handler_module,
            dispatch_opts: opts
          }

          method
          |> do_dispatch(ctx, state)
          |> normalize_protocol_result(request_context, handler_module)
        else
          {:error, reason} ->
            context_error_result(request, reason, state, opts)
        end

      {:error, reason} ->
        context_error_result(request, reason, state, opts)
    end
  end

  defp context_error_result(request, %Error.ProtocolError{} = error, state, _opts) do
    if Map.has_key?(request, "id") do
      {:response, JSONRPC.error(Map.get(request, "id"), Error.to_json_rpc(error)), state}
    else
      {:notification, state}
    end
  end

  defp context_error_result(request, reason, state, opts) do
    if Map.has_key?(request, "id") do
      response =
        RequestContext.error_response(
          reason,
          Map.get(request, "id"),
          Keyword.get(opts, :protocol_mode)
        )

      {:response, response, state}
    else
      {:notification, state}
    end
  end

  defp parameter_error_result(request, error, state) do
    if Map.has_key?(request, "id") do
      {:response, JSONRPC.error(Map.get(request, "id"), json_rpc_error(error)), state}
    else
      # JSON-RPC notifications never receive responses, including when their
      # method parameters are invalid.
      {:notification, state}
    end
  end

  defp json_rpc_error(error) do
    Map.new(error, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  @doc """
  Builds the argument map handed to `c:Arbor.MCP.Server.Handler.handle_call_tool/3`.

  Request-level `_meta` (which carries `progressToken`) lives beside
  `arguments` in the JSON-RPC params, but `Arbor.MCP.Server.Handler` documents it
  as reachable from the arguments map, so it is merged in here. Arguments that
  already carry their own `_meta` win.
  """
  @spec tool_arguments(map()) :: map()
  def tool_arguments(params) when is_map(params) do
    arguments = Map.get(params, "arguments") || %{}

    case Map.get(params, "_meta") do
      nil -> arguments
      meta -> Map.put_new(arguments, "_meta", meta)
    end
  end

  defp do_dispatch("initialize", ctx, state) do
    call(ctx, :handle_initialize, [ctx.params, state], "Initialize error", state,
      on_ok: &Initialize.build_initialize_result(ctx.params, &1)
    )
  end

  defp do_dispatch("ping", ctx, state) do
    {:response, JSONRPC.response(ctx.id, %{}), state}
  end

  defp do_dispatch("server/discover", ctx, state) do
    result =
      Discover.build(handler_server_info(ctx.module) || %{}, handler_capabilities(ctx.module),
        protocol_mode: Keyword.get(ctx.dispatch_opts, :protocol_mode) || protocol_mode(state),
        instructions:
          Keyword.get(ctx.dispatch_opts, :instructions) || state_value(state, :instructions)
      )

    {:response, JSONRPC.response(ctx.id, result), state}
  end

  defp do_dispatch("tools/list", ctx, state) do
    args = [cursor(ctx), state]
    paginated(ctx, :handle_list_tools, args, "tools", "List tools error", state)
  end

  defp do_dispatch("tools/call", ctx, state) do
    name = Map.get(ctx.params, "name")
    arguments = tool_arguments(ctx.params)

    call(ctx, :handle_call_tool, [name, arguments, state], "Tool call error", state,
      on_ok: &ResultNormalizer.tool_result(&1, wrap_bare_map: true)
    )
  end

  defp do_dispatch("resources/list", ctx, state) do
    args = [cursor(ctx), state]
    paginated(ctx, :handle_list_resources, args, "resources", "List resources error", state)
  end

  defp do_dispatch("resources/templates/list", ctx, state) do
    args = [cursor(ctx), state]

    paginated(
      ctx,
      :handle_list_resource_templates,
      args,
      "resourceTemplates",
      "List resource templates error",
      state
    )
  end

  defp do_dispatch("resources/read", ctx, state) do
    uri = Map.get(ctx.params, "uri")

    call(ctx, :handle_read_resource, [uri, state], "Read resource error", state,
      on_ok: &%{"contents" => List.wrap(&1)}
    )
  end

  defp do_dispatch("resources/subscribe", ctx, state) do
    uri = Map.get(ctx.params, "uri")
    resource_call(ctx, :handle_subscribe_resource, uri, "Subscribe resource error", state)
  end

  defp do_dispatch("resources/unsubscribe", ctx, state) do
    uri = Map.get(ctx.params, "uri")
    resource_call(ctx, :handle_unsubscribe_resource, uri, "Unsubscribe resource error", state)
  end

  defp do_dispatch("prompts/list", ctx, state) do
    args = [cursor(ctx), state]
    paginated(ctx, :handle_list_prompts, args, "prompts", "List prompts error", state)
  end

  defp do_dispatch("prompts/get", ctx, state) do
    name = Map.get(ctx.params, "name")
    arguments = Map.get(ctx.params, "arguments") || %{}
    call(ctx, :handle_get_prompt, [name, arguments, state], "Get prompt error", state)
  end

  defp do_dispatch("completion/complete", ctx, state) do
    ref = Map.get(ctx.params, "ref")
    argument = Map.get(ctx.params, "argument")
    call(ctx, :handle_complete, [ref, argument, state], "Completion error", state)
  end

  defp do_dispatch("logging/setLevel", ctx, state) do
    set_log_level(ctx, state)
  end

  defp do_dispatch("roots/list", ctx, state) do
    call(ctx, :handle_list_roots, [state], "List roots error", state, on_ok: &%{"roots" => &1})
  end

  defp do_dispatch("tasks/get", ctx, state) do
    args = [Map.get(ctx.params, "taskId"), state]
    call(ctx, :handle_task_get, args, "Task get error", state)
  end

  defp do_dispatch("tasks/result", ctx, state) do
    args = [Map.get(ctx.params, "taskId"), state]
    call(ctx, :handle_task_result, args, "Task result error", state)
  end

  defp do_dispatch("tasks/cancel", ctx, state) do
    args = [Map.get(ctx.params, "taskId"), state]
    call(ctx, :handle_task_cancel, args, "Task cancel error", state)
  end

  defp do_dispatch("tasks/update", ctx, state) do
    args = [Map.get(ctx.params, "taskId"), Map.get(ctx.params, "inputResponses"), state]
    call(ctx, :handle_task_update, args, "Task update error", state, on_ok: fn _ -> %{} end)
  end

  defp do_dispatch("tasks/list", ctx, state) do
    args = [cursor(ctx), state]
    paginated(ctx, :handle_task_list, args, "tasks", "Task list error", state)
  end

  defp do_dispatch("notifications/elicitation/complete", ctx, state) do
    elicitation_id = Map.get(ctx.params, "elicitationId", "")

    if exported?(ctx.module, :handle_elicitation_complete, 2) do
      case ctx.module.handle_elicitation_complete(elicitation_id, state) do
        {:ok, new_state} -> {:notification, new_state}
        {:error, _reason, new_state} -> {:notification, new_state}
        _other -> {:notification, state}
      end
    else
      {:notification, state}
    end
  end

  defp do_dispatch(method, ctx, state) do
    if ctx.request? do
      {:response, method_not_found(ctx.id, method), state}
    else
      # Unknown notification: nothing to answer.
      {:notification, state}
    end
  end

  # logging/setLevel answers {:ok, state} (no result term), so it cannot go
  # through call/6. A handler without the callback still succeeds: logging is
  # optional and clients should not have to special-case it.
  defp set_log_level(ctx, state) do
    level = Map.get(ctx.params, "level")

    if exported?(ctx.module, :handle_set_log_level, 2) do
      case ctx.module.handle_set_log_level(level, state) do
        {:ok, new_state} ->
          {:response, JSONRPC.response(ctx.id, %{}), new_state}

        {:ok, _result, new_state} ->
          {:response, JSONRPC.response(ctx.id, %{}), new_state}

        {:error, reason, new_state} ->
          {:response, error_response(ctx.id, "Set log level error", reason), new_state}

        {:error, reason} ->
          {:response, error_response(ctx.id, "Set log level error", reason), state}
      end
    else
      {:response, JSONRPC.response(ctx.id, %{}), state}
    end
  end

  defp resource_call(ctx, callback, uri, label, state) do
    case call(ctx, callback, [uri, state], label, state) do
      {:response, %{"result" => _result} = response, next_state} ->
        case Arbor.MCP.Server.Runtime.HTTPResources.track(ctx.method, uri) do
          :ok ->
            {:response, response, next_state}

          {:error, _reason} ->
            {:response,
             JSONRPC.error(
               ctx.id,
               ErrorCodes.internal_error(),
               "Resource subscription unavailable"
             ), state}
        end

      result ->
        result
    end
  end

  # Invokes a callback returning {:ok, result, state} | {:error, reason, state}.
  defp call(ctx, fun, args, label, state, opts \\ []) do
    if exported?(ctx.module, fun, length(args)) do
      on_ok = Keyword.get(opts, :on_ok, & &1)

      case Context.with_context(ctx.request_context, fn -> apply(ctx.module, fun, args) end) do
        {:input_required, input_requests, new_state} ->
          input_required_response(ctx, input_requests, nil, new_state)

        {:input_required, input_requests, application_state, new_state} ->
          input_required_response(ctx, input_requests, application_state, new_state)

        {:ok, %MRTR.InputRequired{} = required, new_state} ->
          input_required_response(
            ctx,
            required.input_requests,
            required.request_state,
            new_state
          )

        {:ok, %MRTR.InputRequired{} = required} ->
          input_required_response(ctx, required.input_requests, required.request_state, state)

        {:ok, result, new_state} ->
          {:response, JSONRPC.response(ctx.id, on_ok.(result)), new_state}

        {:ok, result} ->
          {:response, JSONRPC.response(ctx.id, on_ok.(result)), state}

        {:error, reason, new_state} ->
          {:response, error_response(ctx.id, label, reason), new_state}

        {:error, reason} ->
          {:response, error_response(ctx.id, label, reason), state}
      end
    else
      {:response, method_not_found(ctx.id, ctx.method), state}
    end
  end

  # Invokes a paginated list callback returning {:ok, entries, cursor, state}.
  defp paginated(ctx, fun, args, key, label, state) do
    if exported?(ctx.module, fun, length(args)) do
      case Context.with_context(ctx.request_context, fn -> apply(ctx.module, fun, args) end) do
        {:ok, entries, next_cursor, new_state} ->
          result = ResultNormalizer.paginated(key, entries, next_cursor)
          {:response, JSONRPC.response(ctx.id, result), new_state}

        {:ok, entries, new_state} when is_list(entries) ->
          result = ResultNormalizer.paginated(key, entries, nil)
          {:response, JSONRPC.response(ctx.id, result), new_state}

        {:error, reason, new_state} ->
          {:response, error_response(ctx.id, label, reason), new_state}

        {:error, reason} ->
          {:response, error_response(ctx.id, label, reason), state}
      end
    else
      {:response, method_not_found(ctx.id, ctx.method), state}
    end
  end

  defp cursor(ctx), do: Map.get(ctx.params, "cursor")

  defp input_required_response(ctx, input_requests, application_state, state) do
    case MRTR.build_result(
           ctx.request_context,
           ctx.params,
           input_requests,
           application_state,
           ctx.dispatch_opts
         ) do
      {:ok, result} -> {:response, JSONRPC.response(ctx.id, result), state}
      {:error, reason} -> {:response, error_response(ctx.id, "MRTR error", reason), state}
    end
  end

  defp method_not_found(id, method) do
    JSONRPC.error(id, ErrorCodes.method_not_found(), "Method not found: #{method}")
  end

  # Error details are logged by ResultNormalizer; only handler-authored text
  # reaches the client (audit M12).
  defp error_response(id, _label, %Error.ProtocolError{} = error) do
    JSONRPC.error(id, Error.to_json_rpc(error))
  end

  defp error_response(id, label, reason) do
    JSONRPC.error(
      id,
      ResultNormalizer.error_code(reason, -32000),
      ResultNormalizer.error_message(label, reason)
    )
  end

  defp exported?(module, fun, arity) do
    function_exported?(module, fun, arity) or
      (Code.ensure_loaded?(module) and function_exported?(module, fun, arity))
  end

  defp normalize_protocol_result(
         {:response, %{"result" => result} = response, state},
         request_context,
         handler_module
       ) do
    case ResultNormalizer.validate_result_capabilities(result, request_context) do
      :ok ->
        result =
          ResultNormalizer.protocol_result(result, request_context,
            server_info: handler_server_info(handler_module)
          )

        {:response, Map.put(response, "result", result), state}

      {:error, error} ->
        {:response, JSONRPC.error(response["id"], Error.to_json_rpc(error)), state}
    end
  end

  defp normalize_protocol_result(other, _request_context, _handler_module), do: other

  defp handler_server_info(handler_module) do
    if exported?(handler_module, :__server_info__, 0),
      do: handler_module.__server_info__(),
      else: nil
  end

  defp handler_capabilities(handler_module) do
    capabilities =
      if exported?(handler_module, :__server_capabilities__, 0),
        do: handler_module.__server_capabilities__(),
        else: %{}

    Arbor.MCP.Tasks.Extension.put_handler_capability(capabilities, handler_module)
  end

  defp protocol_mode(state) do
    state_value(state, :protocol_mode) || Arbor.MCP.Internal.VersionRegistry.protocol_mode()
  end

  defp state_value(state, key) when is_map(state), do: Map.get(state, key)
  defp state_value(_state, _key), do: nil
end
