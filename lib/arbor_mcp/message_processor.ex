defmodule Arbor.MCP.MessageProcessor do
  @moduledoc """
  Core message processing abstraction for Arbor.MCP.

  The MessageProcessor provides a simple, composable interface for processing MCP messages.
  It follows the Plug specification pattern used throughout the Elixir ecosystem.
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.MessageValidator
  alias Arbor.MCP.Protocol.{ErrorCodes, Methods, ResponseBuilder}
  alias Arbor.MCP.Server.{Cancellation, MRTR, RequestContext, ResultNormalizer, Runtime}
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.RPC.{JSONRPC, LogSummary}

  require Logger

  # Protocol versions come from Arbor.MCP.Internal.VersionRegistry (audit M8).

  # How long to wait for a graceful stop of a per-request handler process
  # before killing it.
  @handler_stop_timeout 1_000

  @type t :: module()
  @type opts :: term()
  @type conn :: %__MODULE__.Conn{}

  # Conn struct is defined in Arbor.MCP.MessageProcessor.Conn
  alias __MODULE__.Conn

  @doc """
  Callback for initializing the plug with options.
  """
  @callback init(opts) :: opts

  @doc """
  Callback for processing the connection.
  """
  @callback call(conn, opts) :: conn

  @doc """
  Creates a new connection.
  """
  @spec new(map(), keyword()) :: Conn.t()
  def new(request, opts \\ []) do
    %Conn{
      request: request,
      response: nil,
      state: nil,
      assigns: %{},
      transport: Keyword.get(opts, :transport),
      session_id: Keyword.get(opts, :session_id),
      progress_token: extract_progress_token(request),
      halted: false
    }
  end

  @doc """
  Assigns a value to the connection.
  """
  @spec assign(Conn.t(), atom(), term()) :: Conn.t()
  def assign(%Conn{} = conn, key, value), do: Conn.assign(conn, key, value)

  @doc """
  Halts the plug pipeline.
  """
  @spec halt(Conn.t()) :: Conn.t()
  def halt(%Conn{} = conn) do
    %{conn | halted: true}
  end

  @doc """
  Sets the response on the connection.
  """
  @spec put_response(Conn.t(), map()) :: Conn.t()
  def put_response(%Conn{} = conn, response) do
    %{conn | response: response}
  end

  @doc """
  Runs a list of plugs on the connection.
  """
  @spec run([{module(), opts}], Conn.t()) :: Conn.t()
  def run(plugs, %Conn{} = conn) do
    Enum.reduce_while(plugs, conn, fn {plug_module, opts}, acc ->
      if acc.halted do
        {:halt, acc}
      else
        result = plug_module.call(acc, plug_module.init(opts))
        {:cont, result}
      end
    end)
  end

  @doc """
  Process an MCP request using a handler module.

  This is a convenience function that creates a connection, processes it
  through a handler, and returns the response.
  """
  @spec process(Conn.t(), map()) :: Conn.t()
  def process(%Conn{} = conn, opts) do
    method = Map.get(conn.request, "method")

    # Validate based on message type (request vs notification)
    result =
      if notification?(conn.request) do
        # For notifications, use the simpler validation that doesn't require "id"
        case validate_notification(conn.request) do
          {:ok, _validated_notification} ->
            process_notification_with_context(conn, opts)

          {:error, error_data} ->
            # Notifications that fail validation are just logged, no response
            require Logger

            Logger.warning("Invalid notification received",
              error_shape: LogSummary.describe(error_data)
            )

            conn
        end
      else
        # For requests, use full request validation
        case MessageValidator.validate_request(conn.request) do
          {:ok, _validated_request} ->
            process_request_with_context(conn, opts)

          {:error, error_data} ->
            # Request is invalid, construct and return an error response.
            # Note: for validation errors, the ID might be null or invalid.
            # We still try to get it to adhere to JSON-RPC, but it might be nil.
            error_response =
              JSONRPC.error(get_request_id(conn.request), json_rpc_validation_error(error_data))

            put_response(conn, error_response)
        end
      end

    result = normalize_protocol_result(result)

    :telemetry.execute(
      [:arbor_mcp, :server, :request, :processed],
      %{},
      %{method: method, has_response: result.response != nil}
    )

    result
  end

  defp normalize_protocol_result(
         %Conn{
           response: %{"result" => result} = response,
           assigns: %{request_context: request_context} = assigns
         } = conn
       ) do
    case ResultNormalizer.validate_result_capabilities(result, request_context) do
      :ok ->
        result =
          ResultNormalizer.protocol_result(result, request_context,
            server_info: Map.get(assigns, :server_info)
          )

        %{conn | response: Map.put(response, "result", result)}

      {:error, error} ->
        %{conn | response: JSONRPC.error(response["id"], Error.to_json_rpc(error))}
    end
  end

  defp normalize_protocol_result(conn), do: conn

  defp process_request_with_context(%Conn{} = conn, opts) do
    case Runtime.ref(Map.get(opts, :server)) do
      {:ok, runtime} -> process_runtime_request(conn, runtime, opts)
      {:error, _reason} -> process_legacy_request_with_context(conn, opts)
    end
  end

  defp process_legacy_request_with_context(%Conn{} = conn, opts) do
    params = Map.get(conn.request, "params") || %{}
    mrtr_opts = mrtr_opts(conn, opts)

    with {:ok, request_context} <- RequestContext.from_message(conn.request),
         :ok <-
           RequestContext.validate_protocol_mode(request_context, Map.get(opts, :protocol_mode)),
         :ok <- RequestContext.validate_method(request_context),
         {:ok, request_context} <- MRTR.prepare_context(request_context, params, mrtr_opts) do
      request_context =
        %{request_context | notification_target: Map.get(opts, :request_notification_target)}

      conn
      |> assign(:request_context, request_context)
      |> assign(:mrtr_opts, mrtr_opts)
      |> process_validated_request(opts)
    else
      {:error, %Error.ProtocolError{} = error} ->
        conn
        |> assign(:http_status, 400)
        |> put_response(JSONRPC.error(get_request_id(conn.request), Error.to_json_rpc(error)))

      {:error, reason} ->
        conn
        |> assign(:http_status, RequestContext.http_status(reason))
        |> put_response(
          RequestContext.error_response(
            reason,
            get_request_id(conn.request),
            Map.get(opts, :protocol_mode)
          )
        )
    end
  end

  defp mrtr_opts(conn, opts) do
    [
      request_state: Map.get(opts, :request_state),
      endpoint: Map.get(opts, :endpoint) || transport_endpoint(conn),
      principal_id: Map.get(opts, :principal_id),
      tenant_id: Map.get(opts, :tenant_id),
      max_input_requests: Map.get(opts, :max_input_requests, 16),
      max_mrtr_bytes: Map.get(opts, :max_mrtr_bytes, 1_048_576),
      replay_cache: Map.get(opts, :replay_cache),
      require_replay_protection: Map.get(opts, :require_replay_protection, false)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp transport_endpoint(%Conn{transport: :http}), do: "/mcp"
  defp transport_endpoint(_conn), do: nil

  defp process_notification_with_context(%Conn{} = conn, opts) do
    with {:ok, request_context} <- RequestContext.from_message(conn.request),
         :ok <-
           RequestContext.validate_protocol_mode(request_context, Map.get(opts, :protocol_mode)),
         :ok <- RequestContext.validate_method(request_context) do
      conn
      |> assign(:request_context, request_context)
      |> route_validated_notification(opts)
    else
      {:error, reason} ->
        Logger.warning("Invalid notification metadata",
          reason_shape: LogSummary.describe(reason)
        )

        conn
    end
  end

  defp route_validated_notification(conn, opts) do
    case Runtime.ref(Map.get(opts, :server)) do
      {:ok, runtime} -> process_runtime_notification(conn, runtime, opts)
      {:error, _reason} -> process_validated_notification(conn, opts)
    end
  end

  defp process_runtime_notification(conn, runtime, opts) do
    scope = runtime_scope(conn)

    case conn.request do
      %{"method" => "notifications/cancelled", "params" => %{"requestId" => request_id}} ->
        Runtime.cancel(runtime, scope, request_id)

      request ->
        with {:ok, edge} <- Runtime.edge(runtime) do
          Runtime.submit(runtime, request,
            kind: :rpc,
            via_edge: true,
            scope: scope,
            reply_to: edge,
            dispatch_opts: [protocol_mode: Map.get(opts, :protocol_mode)]
          )
        end
    end

    conn
  end

  defp process_validated_request(%Conn{} = conn, opts) do
    handler = Map.get(opts, :handler)
    handler_opts = Map.get(opts, :handler_opts, [])
    server = Map.get(opts, :server)
    server_info = Map.get(opts, :server_info, %{})

    conn =
      conn
      |> put_handler_call_timeout(opts)
      |> assign(:server_info, server_info)
      |> assign(:server_capabilities, configured_server_capabilities(handler, opts))
      |> assign(:protocol_mode, Map.get(opts, :protocol_mode))
      |> assign(:instructions, Map.get(opts, :instructions))
      |> assign(:request_headers, Map.get(opts, :request_headers, []))

    cond do
      # If we have a server PID, use it directly
      is_pid(server) ->
        process_handler_request(conn, server, server_info)

      # If we have a handler module
      handler != nil ->
        case handler do
          handler_module when is_atom(handler_module) ->
            process_with_handler_genserver(conn, handler_module, server_info, handler_opts)

          _ ->
            error_response =
              JSONRPC.error(
                get_request_id(conn.request),
                ErrorCodes.internal_error(),
                "Invalid handler type"
              )

            put_response(conn, error_response)
        end

      # No handler or server configured
      true ->
        error_response =
          JSONRPC.error(
            get_request_id(conn.request),
            ErrorCodes.internal_error(),
            "No handler configured"
          )

        put_response(conn, error_response)
    end
  end

  defp process_runtime_request(conn, runtime, opts) do
    timeout = Map.get(opts, :handler_call_timeout, 10_000)

    case Runtime.request(runtime, conn.request,
           kind: :rpc,
           via_edge: true,
           scope: runtime_scope(conn),
           timeout: timeout,
           await_timeout: timeout,
           dispatch_opts:
             Keyword.merge(mrtr_opts(conn, opts),
               protocol_mode: Map.get(opts, :protocol_mode),
               instructions: Map.get(opts, :instructions)
             )
         ) do
      {:ok, response} ->
        put_response(conn, ResultNormalizer.stringify_keys(response))

      {:error, response} when is_map(response) ->
        put_response(conn, response)

      {:error, reason} ->
        put_response(
          conn,
          JSONRPC.error(
            get_request_id(conn.request),
            ErrorCodes.internal_error(),
            "Request interrupted",
            %{"type" => to_string(reason)}
          )
        )
    end
  end

  defp runtime_scope(conn), do: {:message_processor, conn.session_id || self()}

  # Process request using a temporary per-request handler GenServer.
  #
  # The handler is started *unlinked* (`GenServer.start/2`) so a crash inside
  # the handler cannot take down the request process; MethodHandlers converts
  # handler crashes, call timeouts and error returns into JSON-RPC error
  # responses instead.
  defp process_with_handler_genserver(conn, handler_module, server_info, handler_opts) do
    case GenServer.start(handler_module, handler_opts) do
      {:ok, server_pid} ->
        start_handler_watchdog(server_pid)

        try do
          # Process the request using the handler's GenServer interface
          process_handler_request(conn, server_pid, server_info)
        after
          # Clean up the temporary server on every exit path
          stop_handler(server_pid)
        end

      {:error, reason} ->
        # Log the detail; never embed it in the JSON-RPC response (audit M12).
        Logger.error("Failed to start request handler",
          handler: handler_module,
          reason_shape: LogSummary.describe(reason)
        )

        error_response =
          JSONRPC.error(
            get_request_id(conn.request),
            ErrorCodes.internal_error(),
            "Internal server error",
            %{"type" => "handler_start_failed"}
          )

        put_response(conn, error_response)
    end
  end

  # Stops the per-request handler process. `GenServer.stop/3` exits the caller
  # when the handler is already dead or does not stop within the timeout, so
  # catch those exits and fall back to a brutal kill to guarantee the handler
  # cannot outlive the request (no process leak).
  defp stop_handler(server_pid) do
    GenServer.stop(server_pid, :normal, @handler_stop_timeout)
    :ok
  catch
    :exit, _reason ->
      Process.exit(server_pid, :kill)
      :ok
  end

  # Since the handler is not linked to the request process, an exit signal
  # that kills the request process mid-call (e.g. client disconnect) would
  # skip the `after` cleanup and leak the handler. This watchdog kills the
  # handler if the request process dies first, and exits on its own once the
  # handler is down.
  defp start_handler_watchdog(server_pid) do
    request_pid = self()

    spawn(fn ->
      request_ref = Process.monitor(request_pid)
      server_ref = Process.monitor(server_pid)

      receive do
        {:DOWN, ^server_ref, :process, _pid, _reason} ->
          :ok

        {:DOWN, ^request_ref, :process, _pid, _reason} ->
          Process.exit(server_pid, :kill)
      end
    end)
  end

  # Plumb the `:handler_call_timeout` option (default 10_000, applied in
  # MethodHandlers) through the conn so all GenServer calls to the handler
  # use it.
  defp put_handler_call_timeout(%Conn{} = conn, opts) do
    case Map.get(opts, :handler_call_timeout) do
      nil -> conn
      timeout -> assign(conn, :handler_call_timeout, timeout)
    end
  end

  defp configured_server_capabilities(handler, opts) do
    capabilities =
      cond do
        is_map(Map.get(opts, :server_capabilities)) ->
          Map.get(opts, :server_capabilities)

        is_atom(handler) and function_exported?(handler, :__server_capabilities__, 0) ->
          handler.__server_capabilities__()

        true ->
          %{}
      end

    TasksExtension.put_handler_capability(capabilities, handler)
  end

  # Process handler request through GenServer calls
  defp process_handler_request(conn, server_pid, server_info) do
    conn = assign(conn, :server_info, server_info)
    dispatch_to_method_handlers(conn, server_pid)
  end

  alias Arbor.MCP.MessageProcessor.MethodHandlers

  defp dispatch_to_method_handlers(conn, handler) do
    request = conn.request
    method = Map.get(request, "method")
    params = Map.get(request, "params", %{})
    id = get_request_id(request)

    case method do
      "ping" -> handle_ping(conn, id)
      "initialize" -> handle_initialize_dispatch(conn, handler, params, id)
      _ -> dispatch_method(method, conn, handler, params, id)
    end
  end

  @doc false
  @spec dispatched_methods() :: [String.t()]
  def dispatched_methods, do: Map.keys(Methods.handler_map(:message_processor))

  defp dispatch_method(method, conn, handler, params, id) do
    case Map.fetch(Methods.handler_map(:message_processor), method) do
      {:ok, handler_fun} ->
        apply(MethodHandlers, handler_fun, [conn, handler, params, id])

      :error ->
        MethodHandlers.handle_custom_method(conn, handler, method, params, id)
    end
  end

  defp handle_ping(conn, id) do
    response = ResponseBuilder.build_success_response(%{}, id)
    put_response(conn, response)
  end

  defp handle_initialize_dispatch(conn, handler, params, id) do
    # server_info comes from the conn's assigns (set during process routing)
    server_info = Map.get(conn.assigns, :server_info, %{})
    MethodHandlers.handle_initialize(conn, handler, params, id, server_info)
  end

  defp get_request_id(request) when is_map(request), do: Map.get(request, "id")
  defp get_request_id(_), do: nil

  defp json_rpc_validation_error(error) do
    Map.new(error, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  # Progress notification helpers for MCP 2025-06-18 compliance

  # Extracts the progress token from a request's _meta field.
  # According to MCP 2025-06-18 specification, progress tokens are sent
  # in the request metadata field and must be string or integer values.
  @spec extract_progress_token(map()) :: Arbor.MCP.Types.progress_token() | nil
  defp extract_progress_token(%{"params" => %{"_meta" => %{"progressToken" => token}}} = _request)
       when is_binary(token) or is_integer(token) do
    token
  end

  defp extract_progress_token(_request), do: nil

  @doc """
  Starts progress tracking for a connection if it has a progress token.

  This should be called at the beginning of long-running operations.
  """
  @spec start_progress_tracking(Conn.t()) :: Conn.t()
  def start_progress_tracking(%Conn{progress_token: nil} = conn), do: conn

  def start_progress_tracking(%Conn{progress_token: token} = conn) when not is_nil(token) do
    case Arbor.MCP.ProgressTracker.start_progress(token, self(), owner: progress_owner(conn)) do
      {:ok, _tracker} ->
        conn

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to start progress tracking",
          progress_id: LogSummary.fingerprint(token),
          reason: LogSummary.describe(reason)
        )

        conn
    end
  end

  @doc """
  Updates progress for a connection.

  This is a helper function to send progress notifications during
  long-running operations.
  """
  @spec update_progress(Conn.t(), number(), number() | nil, String.t() | nil) :: Conn.t()
  def update_progress(%Conn{progress_token: nil} = conn, _progress, _total, _message), do: conn

  def update_progress(%Conn{progress_token: token} = conn, progress, total, message)
      when not is_nil(token) do
    case Arbor.MCP.ProgressTracker.update_progress(token, progress, total, message,
           owner: progress_owner(conn)
         ) do
      :ok ->
        conn

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to update progress",
          progress_id: LogSummary.fingerprint(token),
          reason: LogSummary.describe(reason)
        )

        conn
    end
  end

  @doc """
  Completes progress tracking for a connection.

  This should be called when a long-running operation finishes,
  either successfully or with an error.
  """
  @spec complete_progress(Conn.t()) :: Conn.t()
  def complete_progress(%Conn{progress_token: nil} = conn), do: conn

  def complete_progress(%Conn{progress_token: token} = conn) when not is_nil(token) do
    case Arbor.MCP.ProgressTracker.complete_progress(token, owner: progress_owner(conn)) do
      :ok ->
        conn

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to complete progress",
          progress_id: LogSummary.fingerprint(token),
          reason: LogSummary.describe(reason)
        )

        conn
    end
  end

  # Helper functions for notification handling

  defp notification?(%{"method" => _method} = request) do
    # Notifications don't have an "id" field
    not Map.has_key?(request, "id")
  end

  defp notification?(_), do: false

  defp validate_notification(notification) do
    # Simple validation for notifications - just check required fields
    with :ok <- validate_jsonrpc_version(notification),
         :ok <- validate_notification_structure(notification),
         :ok <-
           MessageValidator.validate_method_params(
             Map.get(notification, "method"),
             notification_params(notification)
           ) do
      {:ok, notification}
    else
      {:error, error_data} -> {:error, error_data}
    end
  end

  defp validate_jsonrpc_version(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc_version(_),
    do:
      {:error, %{"code" => ErrorCodes.invalid_request(), "message" => "Invalid JSON-RPC version"}}

  defp validate_notification_structure(%{"method" => _method}) do
    # Notifications only require jsonrpc and method fields
    :ok
  end

  defp validate_notification_structure(_) do
    {:error,
     %{"code" => ErrorCodes.invalid_request(), "message" => "Notification must have method field"}}
  end

  defp notification_params(notification) do
    if Map.has_key?(notification, "params"), do: Map.get(notification, "params"), else: %{}
  end

  defp progress_owner(%Conn{session_id: session_id}) when is_binary(session_id),
    do: {:session, session_id}

  defp progress_owner(%Conn{} = conn), do: {:connection, self(), conn.transport}

  defp process_validated_notification(%Conn{} = conn, opts) do
    # Record cancel before invoking the handler so a request running on
    # another process can observe Context.cancelled?/0 immediately.
    Cancellation.mark_from_message(conn.request)

    # Notifications don't generate responses, just process them
    handler = Map.get(opts, :handler)

    if handler do
      try do
        method = Map.get(conn.request, "method")
        params = Map.get(conn.request, "params", %{})

        # For notifications, we just call the handler but don't return a response
        if function_exported?(handler, :handle_mcp_request, 3) do
          handler.handle_mcp_request(method, params, %{})
        end
      rescue
        # Ignore errors in notifications
        _ -> :ok
      end
    end

    conn
  end
end
