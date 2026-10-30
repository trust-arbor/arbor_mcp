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
  `-32601 Method not found`, as does the default `use Arbor.MCP.Server.Handler`
  provides for it. Entries added with `Arbor.MCP.Server.add_tool/3` and its
  siblings are still listed, read and fetched for such a handler.
  """

  require Logger

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.MessageValidator
  alias Arbor.MCP.Protocol.{ErrorCodes, Initialize, Methods}

  alias Arbor.MCP.Server.{
    Context,
    Discover,
    Middleware,
    MRTR,
    Registry,
    RequestContext,
    Result,
    ResultNormalizer
  }

  alias Arbor.MCP.Server.DSL.Matcher
  alias Arbor.MCP.Server.Internal.DSLArguments
  alias Arbor.MCP.Server.Runtime.{CallbackContext, Deadline}
  alias Arbor.MCP.Transport.HTTP.ToolHeaders
  alias Arbor.RPC.JSONRPC

  @method_not_found ErrorCodes.method_not_found()

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
              notification_target: Keyword.get(opts, :request_notification_target),
              session_id: Keyword.get(opts, :session_id),
              auth_info: Keyword.get(opts, :auth_info),
              request_headers: Keyword.get(opts, :request_headers)
          }

          ctx = %{
            method: method,
            id: Map.get(request, "id"),
            params: params,
            request?: Map.has_key?(request, "id"),
            request_context: request_context,
            module: handler_module,
            dispatch_opts: opts,
            snapshot: state
          }

          run_middleware(ctx, state, Keyword.get(opts, :middleware, []))
        else
          {:error, reason} ->
            context_error_result(request, reason, state, opts)
        end

      {:error, reason} ->
        context_error_result(request, reason, state, opts)
    end
  end

  defp handle(ctx, state) do
    ctx.method
    |> do_dispatch(ctx, state)
    |> normalize_protocol_result(ctx, state)
  end

  defp run_middleware(ctx, state, []), do: handle(ctx, state)

  # The chain never sees the handler state: the innermost step threads it
  # through the process dictionary, and remembers its last answer so a
  # middleware that passes it through returns the dispatch result unchanged.
  defp run_middleware(ctx, state, middleware) do
    key = {Middleware, make_ref()}
    Process.put(key, {state, nil})

    inner = fn %{params: params} ->
      {current, _last} = Process.get(key)
      result = handle_params(ctx, params, current)
      wire = wire_result(result)
      Process.put(key, {result_state(result), {wire, result}})
      wire
    end

    request = %{method: ctx.method, id: ctx.id, params: ctx.params, context: ctx.request_context}

    try do
      returned =
        Context.with_context(ctx.request_context, fn ->
          Middleware.run(middleware, request, inner)
        end)

      case Process.get(key) do
        {_state, {^returned, result}} -> result
        {current, _last} -> middleware_result(returned, ctx, current)
      end
    after
      Process.delete(key)
    end
  end

  defp handle_params(%{params: params} = ctx, params, state), do: handle(ctx, state)

  defp handle_params(ctx, params, state) do
    request =
      if ctx.request?,
        do: %{"id" => ctx.id, "method" => ctx.method},
        else: %{"method" => ctx.method}

    case MessageValidator.validate_method_params(ctx.method, params) do
      :ok -> handle(%{ctx | params: params}, state)
      {:error, error} -> parameter_error_result(request, error, state)
    end
  end

  defp wire_result({:response, %{"result" => result}, _state}),
    do: {:ok, ResultNormalizer.stringify_keys(result)}

  defp wire_result({:response, %{"error" => error}, _state}),
    do: {:error, ResultNormalizer.stringify_keys(error)}

  defp wire_result({:notification, _state}), do: :noreply

  defp result_state({:response, _response, state}), do: state
  defp result_state({:notification, state}), do: state

  defp middleware_result(_returned, %{request?: false}, state), do: {:notification, state}

  defp middleware_result({:ok, result}, ctx, state) when is_map(result) do
    {:response, %{"jsonrpc" => "2.0", "id" => ctx.id, "result" => result}, state}
    |> normalize_protocol_result(ctx, state)
  end

  defp middleware_result({:error, %Error.ProtocolError{} = error}, ctx, state),
    do: {:response, JSONRPC.error(ctx.id, Error.to_json_rpc(error)), state}

  defp middleware_result({:error, %{} = error}, ctx, state) do
    case json_rpc_error(error) do
      %{"code" => code, "message" => message} = error
      when is_integer(code) and is_binary(message) ->
        {:response, JSONRPC.error(ctx.id, error), state}

      _invalid ->
        invalid_middleware_result(ctx, state)
    end
  end

  defp middleware_result(_returned, ctx, state), do: invalid_middleware_result(ctx, state)

  defp invalid_middleware_result(ctx, state) do
    Logger.error("MCP middleware returned an invalid result", method: ctx.method)

    {:response,
     JSONRPC.error(ctx.id, ErrorCodes.internal_error(), "Internal error", %{
       "type" => "invalid_middleware_result"
     }), state}
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
    result =
      call(ctx, :handle_initialize, [ctx.params, state], "Initialize error", state,
        on_ok:
          &(ctx.params |> Initialize.build_initialize_result(&1) |> registered_capabilities())
      )

    validate_http_initialize(ctx, result, state)
  end

  defp do_dispatch("ping", ctx, state) do
    {:response, JSONRPC.response(ctx.id, %{}), state}
  end

  defp do_dispatch("server/discover", ctx, state) do
    # Discovery fills in its own ttlMs and cacheScope, which a hint from
    # :cache_hints could no longer replace once the result carries them.
    hint = ctx.dispatch_opts |> Keyword.get(:cache_hints, %{}) |> Map.get("server/discover", %{})

    result =
      Discover.build(
        handler_server_info(ctx.module) || %{},
        ctx.module |> handler_capabilities() |> with_registered_capabilities(),
        protocol_mode: Keyword.get(ctx.dispatch_opts, :protocol_mode) || protocol_mode(state),
        instructions:
          Keyword.get(ctx.dispatch_opts, :instructions) || state_value(state, :instructions) ||
            handler_instructions(ctx.module),
        ttl_ms: hint["ttlMs"],
        cache_scope: hint["cacheScope"]
      )

    {:response, JSONRPC.response(ctx.id, result), state}
  end

  defp do_dispatch("tools/list", ctx, state) do
    args = [cursor(ctx), state]

    registered_list(ctx, :handle_list_tools, args, "tools", "List tools error", state, :tool)
  end

  defp do_dispatch("tools/call", ctx, state) do
    name = Map.get(ctx.params, "name")
    arguments = tool_arguments(ctx.params)
    registered = Registry.lookup(Registry.current(), :tool, name)

    case validate_tool_headers(ctx, name, arguments, state, registered) do
      {:ok, validated_state} when registered != :error ->
        {:ok, entry} = registered
        call_registered_tool(ctx, entry, arguments, validated_state)

      {:ok, validated_state} ->
        call(
          ctx,
          :handle_call_tool,
          [name, arguments, validated_state],
          "Tool call error",
          validated_state,
          on_ok: &ResultNormalizer.tool_result(&1, wrap_bare_map: true)
        )

      {:error, message} ->
        {:response, JSONRPC.error(ctx.id, ErrorCodes.header_mismatch(), message), state}
    end
  end

  defp do_dispatch("resources/list", ctx, state) do
    args = [cursor(ctx), state]

    registered_list(
      ctx,
      :handle_list_resources,
      args,
      "resources",
      "List resources error",
      state,
      :resource
    )
  end

  defp do_dispatch("resources/templates/list", ctx, state) do
    args = [cursor(ctx), state]

    registered_list(
      ctx,
      :handle_list_resource_templates,
      args,
      "resourceTemplates",
      "List resource templates error",
      state,
      :resource_template
    )
  end

  defp do_dispatch("resources/read", ctx, state) do
    uri = Map.get(ctx.params, "uri")
    on_ok = &ResultNormalizer.read_result/1

    case registered_resource(Registry.current(), uri) do
      {:ok, entry, args} ->
        result = ctx |> run_registered(entry, args) |> resource_contents(uri, entry)
        callback_result(ctx, result, "Read resource error", state, on_ok)

      :error ->
        ctx
        |> call(:handle_read_resource, [uri, state], "Read resource error", state, on_ok: on_ok)
        |> unless_served(ctx)
    end
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

    registered_list(
      ctx,
      :handle_list_prompts,
      args,
      "prompts",
      "List prompts error",
      state,
      :prompt
    )
  end

  defp do_dispatch("prompts/get", ctx, state) do
    name = Map.get(ctx.params, "name")
    arguments = Map.get(ctx.params, "arguments") || %{}

    case Registry.lookup(Registry.current(), :prompt, name) do
      {:ok, entry} ->
        result = ctx |> run_registered(entry, [arguments]) |> prompt_messages()
        callback_result(ctx, result, "Get prompt error", state, & &1)

      :error ->
        ctx
        |> call(:handle_get_prompt, [name, arguments, state], "Get prompt error", state)
        |> unless_served(ctx)
    end
  end

  # handle_complete/4 also receives the request's context (the values of the
  # other arguments, since 2025-06-18); handlers with only /3 keep working.
  defp do_dispatch("completion/complete", ctx, state) do
    ref = Map.get(ctx.params, "ref")
    argument = Map.get(ctx.params, "argument")

    result =
      if exported?(ctx.module, :handle_complete, 4) do
        context = Map.get(ctx.params, "context") || %{}
        call(ctx, :handle_complete, [ref, argument, context, state], "Completion error", state)
      else
        call(ctx, :handle_complete, [ref, argument, state], "Completion error", state)
      end

    unless_served(result, ctx)
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
      result = Context.with_context(ctx.request_context, fn -> apply(ctx.module, fun, args) end)
      callback_result(ctx, result, label, state, Keyword.get(opts, :on_ok, & &1))
    else
      {:response, method_not_found(ctx.id, ctx.method), state}
    end
  end

  defp callback_result(ctx, result, label, state, on_ok) do
    case result do
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
  end

  # Invokes a paginated list callback returning {:ok, entries, cursor, state}.
  defp paginated(ctx, fun, args, key, label, state, unimplemented \\ nil) do
    if exported?(ctx.module, fun, length(args)) do
      case Context.with_context(ctx.request_context, fn -> apply(ctx.module, fun, args) end) do
        {:ok, entries, next_cursor, new_state} ->
          result = ResultNormalizer.paginated(key, entries, next_cursor)
          {:response, JSONRPC.response(ctx.id, result), new_state}

        {:ok, entries, new_state} when is_list(entries) ->
          result = ResultNormalizer.paginated(key, entries, nil)
          {:response, JSONRPC.response(ctx.id, result), new_state}

        {:error, reason, new_state} ->
          list_error(ctx, label, reason, new_state, unimplemented)

        {:error, reason} ->
          list_error(ctx, label, reason, state, unimplemented)
      end
    else
      if unimplemented,
        do: unimplemented.(state),
        else: {:response, method_not_found(ctx.id, ctx.method), state}
    end
  end

  # A list the handler doesn't serve: the Handler defaults answer -32601, and
  # so may the handler itself.
  defp list_error(
         _ctx,
         _label,
         %Error.ProtocolError{code: @method_not_found},
         state,
         unimplemented
       )
       when is_function(unimplemented, 1),
       do: unimplemented.(state)

  defp list_error(ctx, label, reason, state, _unimplemented),
    do: {:response, error_response(ctx.id, label, reason), state}

  # A method the handler doesn't serve, within a capability the server does
  # serve: through the DSL, entries added at runtime or its own declaration.
  # Like the TypeScript SDK, the server then answers an empty completion, or
  # not-found for a name, rather than -32601 (see ResultNormalizer).
  defp unless_served(
         {:response, %{"error" => %{"code" => @method_not_found}}, state} = result,
         ctx
       ) do
    case ResultNormalizer.served_capability_answer(ctx.method, ctx.params, served(ctx)) do
      {:ok, answer} -> {:response, JSONRPC.response(ctx.id, answer), state}
      {:error, error} -> {:response, JSONRPC.error(ctx.id, Error.to_json_rpc(error)), state}
      nil -> result
    end
  end

  defp unless_served(result, _ctx), do: result

  # What the server advertises, as server/discover reports it.
  defp served(ctx), do: ctx.module |> handler_capabilities() |> with_registered_capabilities()

  defp cursor(ctx), do: Map.get(ctx.params, "cursor")

  # A legacy client has no input_required result. Like the TypeScript, Go and
  # C# SDKs, the server sends each input request to it as the request it
  # stands for (elicitation, sampling, roots), then runs the callback again
  # with the answers in Context.input_responses/0 and the application state
  # in Context.request_state/0, so one handler serves both eras.
  @max_legacy_input_rounds 10

  defp input_required_response(
         %{request_context: %{era: :legacy} = request_context} = ctx,
         input_requests,
         application_state,
         state
       ) do
    round = (request_context.mrtr_round || 0) + 1

    with :ok <- legacy_round(round),
         :ok <- snapshot_kept(ctx, state),
         {:ok, requests} <-
           MRTR.legacy_input_requests(request_context, input_requests, ctx.dispatch_opts),
         # Sent from inside the request's context: over legacy HTTP it names
         # the session stream the requests go out on.
         {:ok, responses} <-
           Context.with_context(request_context, fn -> legacy_inputs(requests, ctx) end) do
      request_context = %{
        request_context
        | input_responses: responses,
          request_state: application_state,
          mrtr_round: round
      }

      do_dispatch(ctx.method, %{ctx | request_context: request_context}, state)
    else
      {:error, :invalid_handler_state} ->
        {:response,
         JSONRPC.error(ctx.id, ErrorCodes.internal_error(), "Internal error", %{
           "type" => "invalid_handler_state"
         }), ctx.snapshot}

      {:error, reason} ->
        {:response, error_response(ctx.id, "Input request error", reason), state}
    end
  end

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

  # A stateless callback must return its snapshot every time, not only after
  # its last round; a changed state would otherwise reach the next round.
  defp snapshot_kept(%{dispatch_opts: opts, snapshot: snapshot}, state) do
    if Keyword.get(opts, :execution) == :stateless and state !== snapshot,
      do: {:error, :invalid_handler_state},
      else: :ok
  end

  defp legacy_round(round) when round <= @max_legacy_input_rounds, do: :ok

  defp legacy_round(_round),
    do:
      {:error,
       Error.protocol_error(
         ErrorCodes.internal_error(),
         "Input was requested more than #{@max_legacy_input_rounds} times"
       )}

  # In order, each under what is left of the request's deadline.
  defp legacy_inputs(requests, ctx) do
    # Over HTTP the session's negotiated revision must define the method;
    # BEAM and stdio connections check that, and the client's capabilities,
    # at the edge.
    version = Keyword.get(ctx.dispatch_opts, :http_expected_protocol_version)

    requests
    |> Enum.sort_by(fn {id, _request} -> id end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, %{"method" => method, "params" => params}},
                                        {:ok, responses} ->
      with :ok <- available_input(method, version),
           {:ok, result} <- Arbor.MCP.Server.legacy_input(method, params, input_timeout()) do
        {:cont, {:ok, Map.put(responses, id, result)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp available_input(method, version) when is_binary(version) do
    if Methods.available?(method, version),
      do: :ok,
      else: {:error, {:method_unavailable, method, version}}
  end

  defp available_input(_method, _version), do: :ok

  defp input_timeout do
    remaining =
      case CallbackContext.current() do
        %{deadline: deadline} when is_integer(deadline) -> Deadline.remaining(deadline)
        _outside -> 30_000
      end

    remaining |> max(1) |> min(4_294_967_295)
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

  # before_state is the handler state from before the callback: a rejected
  # result must not commit what the callback changed.
  defp normalize_protocol_result(
         {:response, %{"result" => result} = response, state},
         %{request_context: request_context, module: handler_module} = ctx,
         before_state
       ) do
    case ResultNormalizer.validate_result_capabilities(result, request_context) do
      :ok ->
        result =
          ResultNormalizer.protocol_result(result, request_context,
            server_info: handler_server_info(handler_module),
            cache_hints: Keyword.get(ctx.dispatch_opts, :cache_hints, %{})
          )

        {:response, Map.put(response, "result", result), state}

      {:error, error} ->
        {:response, JSONRPC.error(response["id"], Error.to_json_rpc(error)), state}
    end
  rescue
    # A result this revision can't carry, such as non-object structuredContent
    # in a legacy era, is the handler's bug: say so rather than crash.
    exception in ArgumentError ->
      Logger.error(
        "#{inspect(handler_module)} returned an invalid result: #{Exception.message(exception)}"
      )

      {:response,
       JSONRPC.error(response["id"], ErrorCodes.internal_error(), "Invalid result", %{
         "type" => "invalid_result"
       }), before_state}
  end

  defp normalize_protocol_result(other, _ctx, _before_state),
    do: other

  defp validate_http_initialize(
         ctx,
         {:response, %{"result" => result} = response, next_state},
         state
       ) do
    expected = Keyword.get(ctx.dispatch_opts, :http_expected_protocol_version)

    if is_binary(expected) and result["protocolVersion"] != expected do
      error =
        JSONRPC.error(ctx.id, ErrorCodes.internal_error(), "Service unavailable", %{
          "type" => "session_manager_unavailable"
        })

      {:response, error, state}
    else
      {:response, response, next_state}
    end
  end

  defp validate_http_initialize(_ctx, result, _state), do: result

  # Unless the handler's handle_get_tool/2 supplies it, the tool's
  # x-mcp-header annotations may be on any page of tools/list, so follow the
  # cursors until it turns up. A list that runs past the bound fails closed
  # rather than skipping the header check.
  @max_tool_pages 100

  defp validate_tool_headers(
         %{request_context: %{era: :modern}, dispatch_opts: opts},
         name,
         arguments,
         state,
         {:ok, entry}
       ) do
    if Keyword.has_key?(opts, :request_headers),
      do: validate_tool_header_entries([entry.definition], name, arguments, opts, state),
      else: {:ok, state}
  end

  defp validate_tool_headers(
         %{request_context: %{era: :modern}, dispatch_opts: opts} = ctx,
         name,
         arguments,
         state,
         :error
       ) do
    if Keyword.has_key?(opts, :request_headers) do
      case handler_tool(ctx, name, state) do
        {:ok, tools, next_state} ->
          validate_tool_header_entries(tools, name, arguments, opts, next_state)

        :unavailable ->
          {:error, "Tool schema unavailable"}
      end
    else
      {:ok, state}
    end
  end

  defp validate_tool_headers(_ctx, _name, _arguments, state, _registered), do: {:ok, state}

  # A handler that defines handle_get_tool/2 names the definition itself; nil
  # means it doesn't know the tool, so the walk still runs and the check is
  # never skipped. The lookup runs inside the request's work, like the walk,
  # under the same deadline.
  defp handler_tool(ctx, name, state) do
    if exported?(ctx.module, :handle_get_tool, 2) do
      looked_up =
        Context.with_context(ctx.request_context, fn ->
          ctx.module.handle_get_tool(name, state)
        end)

      # {:ok, result} keeps the state, as for other callbacks and over the
      # MessageProcessor's handler bridge.
      case looked_up do
        {:ok, nil, next_state} -> listed_tool(ctx, name, nil, next_state, @max_tool_pages)
        {:ok, nil} -> listed_tool(ctx, name, nil, state, @max_tool_pages)
        {:ok, tool, next_state} when is_map(tool) -> named_tool(tool, name, next_state)
        {:ok, tool} when is_map(tool) -> named_tool(tool, name, state)
        _unavailable -> :unavailable
      end
    else
      listed_tool(ctx, name, nil, state, @max_tool_pages)
    end
  end

  # A definition for another tool would match no name and skip the check.
  defp named_tool(tool, name, state) do
    if listed?([tool], name), do: {:ok, [tool], state}, else: :unavailable
  end

  defp listed_tool(_ctx, _name, _cursor, _state, 0), do: :unavailable

  defp listed_tool(ctx, name, cursor, state, pages) do
    page =
      Context.with_context(ctx.request_context, fn ->
        ctx.module.handle_list_tools(cursor, state)
      end)

    case page do
      {:ok, entries, next, next_state} when is_list(entries) ->
        if is_binary(next) and not listed?(entries, name),
          do: listed_tool(ctx, name, next, next_state, pages - 1),
          else: {:ok, entries, next_state}

      {:ok, entries, next_state} when is_list(entries) ->
        {:ok, entries, next_state}

      _unavailable ->
        :unavailable
    end
  end

  defp listed?(entries, name),
    do: Enum.any?(ResultNormalizer.stringify_keys(entries), &(&1["name"] == name))

  # Tools, resources and prompts added with Server.add_tool/3 and its
  # siblings. Their entries come after the handler's, on its last page, and
  # replace handler entries with the same identifier.
  defp registered_list(ctx, fun, args, key, label, state, kind) do
    case Registry.entries(Registry.current(), kind) do
      [] ->
        # A list the handler doesn't serve, within a capability the server
        # serves, is empty.
        ctx |> paginated(fun, args, key, label, state) |> unless_served(ctx)

      entries ->
        # A handler that doesn't serve this list lists only the registered
        # entries; any other error it returns stands.
        only = fn state ->
          result = %{key => Enum.map(entries, & &1.definition)}
          {:response, JSONRPC.response(ctx.id, result), state}
        end

        ctx
        |> paginated(fun, args, key, label, state, only)
        |> merge_registered(entries, key)
    end
  end

  defp merge_registered({:response, %{"result" => result} = response, state}, entries, key) do
    ids = MapSet.new(entries, & &1.id)

    own =
      result
      |> Map.get(key, [])
      |> ResultNormalizer.stringify_keys()
      |> Enum.reject(&(registered_id(&1) in ids))

    listed = if result["nextCursor"], do: own, else: own ++ Enum.map(entries, & &1.definition)
    {:response, %{response | "result" => Map.put(result, key, listed)}, state}
  end

  defp merge_registered(other, _entries, _key), do: other

  defp registered_id(%{"uriTemplate" => template}), do: template
  defp registered_id(%{"uri" => uri}), do: uri
  defp registered_id(%{"name" => name}), do: name
  defp registered_id(_entry), do: nil

  defp call_registered_tool(ctx, entry, arguments, state) do
    arguments = ResultNormalizer.stringify_keys(arguments)

    # Invalid arguments and output that fails its schema are tool errors the
    # model can correct, as for DSL tools (SEP-1303).
    result =
      case SchemaPolicy.validate_optional(Map.drop(arguments, ["_meta"]), entry.input_schema) do
        :ok ->
          with {:ok, response} <- run_registered(ctx, entry, [arguments]) do
            case DSLArguments.validate_tool_response(response, entry.output_schema) do
              {:ok, response} -> {:ok, response}
              {:error, message} -> {:ok, Result.error(message)}
            end
          end

        {:error, diagnostics} ->
          message =
            DSLArguments.input_error_message(
              {:invalid_tool_arguments, List.wrap(diagnostics)},
              entry.definition["inputSchema"]
            )

          {:ok, Result.error(message)}
      end

    callback_result(
      ctx,
      result,
      "Tool call error",
      state,
      &ResultNormalizer.tool_result(&1, wrap_bare_map: true)
    )
  end

  defp registered_resource(registry, uri) when is_binary(uri) do
    case Registry.lookup(registry, :resource, uri) do
      {:ok, entry} ->
        {:ok, entry, [uri]}

      :error ->
        registry
        |> Registry.entries(:resource_template)
        |> Enum.find_value(:error, fn entry ->
          case Matcher.match_uri_template(uri, entry.id) do
            {:ok, variables} -> {:ok, entry, [uri, variables]}
            :error -> nil
          end
        end)
    end
  end

  defp registered_resource(_registry, _uri), do: :error

  # Registered functions take no handler state; they return a result,
  # {:ok, result} or {:error, reason}.
  defp run_registered(ctx, entry, args) do
    case Context.with_context(ctx.request_context, fn -> apply(entry.fun, args) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      result -> {:ok, result}
    end
  end

  defp resource_contents({:ok, text}, uri, entry) when is_binary(text) do
    contents =
      %{"uri" => uri, "text" => text}
      |> Arbor.MCP.Internal.Maps.put_present("mimeType", entry.definition["mimeType"])

    {:ok, contents}
  end

  defp resource_contents(result, _uri, _entry), do: result

  defp prompt_messages({:ok, text}) when is_binary(text),
    do:
      {:ok,
       %{"messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}]}}

  defp prompt_messages(result), do: result

  # Kinds with registered entries are advertised with listChanged, so a
  # handler that registers everything at runtime needs no static declaration.
  defp registered_capabilities(%{"capabilities" => capabilities} = result),
    do: %{result | "capabilities" => with_registered_capabilities(capabilities)}

  defp registered_capabilities(result), do: result

  defp with_registered_capabilities(capabilities) do
    registry = Registry.current()

    [tool: "tools", resource: "resources", resource_template: "resources", prompt: "prompts"]
    |> Enum.filter(fn {kind, _key} -> Registry.any?(registry, kind) end)
    |> Enum.reduce(capabilities, fn {_kind, key}, acc ->
      acc = ResultNormalizer.stringify_keys(acc)
      Map.update(acc, key, %{"listChanged" => true}, &Map.put(&1, "listChanged", true))
    end)
  end

  defp validate_tool_header_entries(entries, name, arguments, opts, state) do
    tool = Enum.find(ResultNormalizer.stringify_keys(entries), &(&1["name"] == name))

    case ToolHeaders.compile(tool) do
      {:ok, annotations} ->
        case ToolHeaders.validate_request(opts[:request_headers], annotations, arguments) do
          :ok -> {:ok, state}
          error -> error
        end

      {:error, _invalid} ->
        {:error, "Tool x-mcp-header annotations are invalid"}
    end
  end

  defp handler_server_info(handler_module) do
    if exported?(handler_module, :__server_info__, 0),
      do: handler_module.__server_info__(),
      else: nil
  end

  defp handler_instructions(handler_module) do
    if exported?(handler_module, :__server_instructions__, 0),
      do: handler_module.__server_instructions__()
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
