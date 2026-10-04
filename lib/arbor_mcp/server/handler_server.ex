defmodule Arbor.MCP.Server.HandlerServer do
  @moduledoc """
  Runtime-backed test and BEAM server for `Arbor.MCP.Server.Handler` modules.

  `start_link/1` returns an owned runtime supervisor. Its protocol edge handles
  validation, reverse requests and subscriptions; the runtime alone initializes,
  executes and terminates the handler. Stateful callbacks run serially in
  supervised tasks. Pass the supervisor or `Runtime.ref/1` reference to clients
  and public `Arbor.MCP.Server` helpers.

  Custom callbacks use `Arbor.MCP.Server.call/3` and `Arbor.MCP.Server.cast/2`.
  Direct `GenServer` callers must explicitly resolve `Runtime.edge/1`; direct
  calls and raw Erlang sends bypass the supported pre-mailbox ingress bound.

  ## Usage

      # Handler module implementing Arbor.MCP.Server.Handler
      defmodule MyHandler do
        use Arbor.MCP.Server.Handler

        @impl true
        def handle_initialize(params, state) do
          {:ok, %{
            protocolVersion: "2025-03-26",
            serverInfo: %{name: "test-server", version: "1.0.0"},
            capabilities: %{tools: %{}}
          }, state}
        end

        @impl true
        def handle_list_tools(_cursor, state) do
          tools = [
            %{
              name: "ping",
              description: "Simple ping tool",
              inputSchema: %{type: "object", properties: %{}}
            }
          ]
          {:ok, tools, nil, state}
        end
      end

      # Start the server
      {:ok, server} = Arbor.MCP.Server.HandlerServer.start_link(transport: :test, handler: MyHandler)
  """

  use GenServer
  require Logger

  alias Arbor.MCP.Error.ProtocolError
  alias Arbor.MCP.Internal.{MessageValidator, VersionRegistry}
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.RPC.{JSONRPC, LogSummary}

  alias Arbor.MCP.Server.{
    CancellationTracker,
    RequestContext,
    RequestState,
    Runtime,
    Subscriptions
  }

  alias Arbor.MCP.Server.Runtime.{Admission, Ref, ShutdownGuard}

  alias Arbor.MCP.Transport.{Local, Test}

  # JSON-RPC batches were removed from the spec in 2025-06-18 and have not
  # come back since, so every version from 2025-06-18 onwards rejects them.
  @batch_removed_in "2025-06-18"

  @type handler_module :: module()
  @type state :: %{
          handler_module: handler_module(),
          runtime: Ref.t(),
          transport: any(),
          transport_state: any(),
          protocol_version: String.t() | nil,
          validation_state: %{
            seen_request_ids: MapSet.t(String.t() | integer()),
            max_request_ids: pos_integer(),
            protocol_version: String.t() | nil
          },
          protocol_mode: Arbor.MCP.Types.protocol_mode() | nil,
          connection_era: :legacy | :modern | nil,
          instructions: String.t() | nil,
          request_state: keyword() | nil,
          endpoint: String.t() | nil,
          principal_id: String.t() | nil,
          tenant_id: String.t() | nil,
          replay_cache: module() | {module(), keyword()} | nil,
          require_replay_protection: boolean(),
          pending_requests: map(),
          cancelled_requests: MapSet.t(),
          cancellation_tracker: module(),
          subscriptions: map(),
          subscription_options: keyword()
        }

  @doc """
  Starts a handler-based server.

  ## Options

  * `:handler` - Module implementing `Arbor.MCP.Server.Handler` behaviour (required)
  * `:transport` - Transport type (`:test` or `:beam`)
  * `:handler_args` - Optional term passed to `handler.init/1` (default: `[]`)
  * `:cancellation_tracker` - Module implementing
    `Arbor.MCP.Server.CancellationTracker` used to propagate
    `notifications/cancelled` into handler state
    (default: `Arbor.MCP.Server.CancellationTracker.Default`)
  * `:max_request_ids` - Maximum number of distinct client request IDs retained
    for this peer connection (default: `10_000`). Once reached, new request IDs
    fail closed while already-seen IDs continue to be rejected as duplicates.
  * Runtime execution, admission, deadline and shutdown options are passed to
    `Arbor.MCP.Server.Runtime`. A replacement test/BEAM peer receives a fresh
    request-ID scope and cancels outstanding work for the retired connection.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case validate_mrtr_configuration(opts) do
      :ok ->
        Runtime.start_link(
          Keyword.merge(opts,
            cancellation_tracker:
              Keyword.get(opts, :cancellation_tracker, CancellationTracker.Default),
            edge: {__MODULE__, Keyword.delete(opts, :name)}
          )
        )

      {:error, reason} ->
        {:error, {:mrtr_configuration_error, reason}}
    end
  end

  @doc false
  def start_edge_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    if Keyword.has_key?(opts, :runtime) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_edge_link, [opts]},
        shutdown: Keyword.get(opts, :shutdown_timeout_ms, 5_000)
      }
    else
      %{
        Runtime.child_spec(opts)
        | id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]}
      }
    end
  end

  @doc false
  def connect(server, peer) do
    with {:ok, edge} <- Runtime.edge(server),
         {:ok, runtime, connection} <- GenServer.call(edge, {:runtime_peer_connect, peer}) do
      {:ok, edge, runtime, connection}
    end
  end

  @doc false
  def ingress(runtime, edge, connection, message) do
    if :ets.lookup(Ref.table(runtime), :edge_connection) == [{:edge_connection, edge, connection}] do
      case decode_transport_message(message) do
        {:ok,
         %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => params} =
             request}
        when not is_map_key(request, "id") ->
          case MessageValidator.validate_method_params("notifications/cancelled", params) do
            :ok ->
              Runtime.cancel(runtime, {:connection, connection}, params["requestId"])
              cancel_subscription(runtime, edge, connection, params["requestId"])

            {:error, _reason} ->
              :ok
          end

        decoded ->
          message =
            case decoded do
              {:ok, message} -> message
              _error -> message
            end

          kind =
            case decoded do
              {:ok, %{"result" => _result}} -> :edge_response
              {:ok, %{"error" => _error}} -> :edge_response
              _request -> :ingress
            end

          with {:ok, route, reservation} <-
                 Runtime.reserve_ingress(runtime, message,
                   owner: edge,
                   reply_to: edge,
                   scope: {:connection, connection},
                   kind: kind,
                   edge: edge,
                   wire_ids: wire_ids(message),
                   uncancellable_ids: uncancellable_ids(message),
                   batch?: is_list(message)
                 ) do
            Runtime.publish_ingress(
              runtime,
              route,
              reservation,
              {:transport, connection, message},
              edge
            )
          end
      end
    else
      {:error, :connection_closed}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  defp cancel_subscription(runtime, edge, connection, id) do
    table = Ref.table(runtime)
    key = {:subscription, connection, id}
    control = {{:subscription_cancel, connection, id}, self()}

    if :ets.member(table, key) and :ets.insert_new(table, control) do
      try do
        GenServer.call(edge, {:runtime_subscription_cancel, connection, id})
      after
        :ets.delete_object(table, control)
      end
    else
      :ok
    end
  end

  @impl GenServer
  def init(opts) do
    case validate_mrtr_configuration(opts) do
      :ok -> do_init(opts)
      {:error, reason} -> {:stop, {:mrtr_configuration_error, reason}}
    end
  end

  defp do_init(opts) do
    handler_module = Keyword.fetch!(opts, :handler)
    transport_type = Keyword.get(opts, :transport, :test)
    cancellation_tracker = Keyword.get(opts, :cancellation_tracker, CancellationTracker.Default)
    runtime = Keyword.fetch!(opts, :runtime)
    :ok = ShutdownGuard.watch(Ref.table(runtime), self())
    clear_retired_edge(Ref.table(runtime))
    :ets.insert(Ref.table(runtime), {:edge, self()})
    # Connect to the transport
    case connect_transport(transport_type, opts) do
      {:ok, {transport_mod, transport_state}} ->
        state = %{
          handler_module: handler_module,
          runtime: runtime,
          transport: transport_mod,
          transport_state: transport_state,
          protocol_version: nil,
          validation_state:
            MessageValidator.new_session(nil,
              max_request_ids: Keyword.get(opts, :max_request_ids, 10_000)
            ),
          protocol_mode: Keyword.get(opts, :protocol_mode),
          connection_era: nil,
          instructions: Keyword.get(opts, :instructions),
          request_state: Keyword.get(opts, :request_state),
          endpoint: Keyword.get(opts, :endpoint),
          principal_id: Keyword.get(opts, :principal_id),
          tenant_id: Keyword.get(opts, :tenant_id),
          replay_cache: Keyword.get(opts, :replay_cache),
          require_replay_protection: Keyword.get(opts, :require_replay_protection, false),
          pending_requests: %{},
          pending_timers: %{},
          max_reverse_requests: Keyword.get(opts, :max_control_queue, 32),
          invocations: %{},
          ingress: %{},
          ingress_queue: :queue.new(),
          current_ingress: nil,
          initializing: nil,
          batch_active: nil,
          connection: nil,
          peer_monitor: nil,
          cancellation_tracker: cancellation_tracker,
          subscriptions: %{},
          subscription_options: Subscriptions.runtime_options(opts, handler_module)
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:transport_error, reason}}
    end
  end

  defp clear_retired_edge(table) do
    case :ets.lookup(table, :edge_connection) do
      [{:edge_connection, edge, connection}] ->
        :ets.delete(table, {:ingress_wakeup, edge})

        for {{:subscription, ^connection, _id}, _listener} = object <- :ets.tab2list(table),
            do: :ets.delete_object(table, object)

      _ ->
        :ok
    end

    :ets.delete(table, :edge_connection)
  end

  defp validate_mrtr_configuration(opts) do
    if Keyword.get(opts, :mrtr, false) do
      RequestState.validate_configuration(request_state: Keyword.get(opts, :request_state))
    else
      :ok
    end
  end

  @impl GenServer
  def handle_info({{:runtime_edge_reply, token}, result}, state) do
    Admission.terminal(Ref.table(state.runtime), token, {:ok, result})
    Runtime.discard_ingress(state.runtime, token)
    {:noreply, state}
  end

  def handle_info({:runtime_ingress_expired, token}, state) do
    {:noreply, fail_unbound_ingress(token, state)}
  end

  def handle_info(:runtime_ingress_ready, state) do
    :ets.delete(Ref.table(state.runtime), {:ingress_wakeup, self()})
    {:noreply, drain_published(state)}
  end

  def handle_info({:runtime_ingress, token, connection, message}, state) do
    if connection == state.connection do
      accept_ingress(token, message, state)
    else
      Runtime.discard_ingress(state.runtime, token)
      {:noreply, state}
    end
  end

  def handle_info({:arbor_mcp_runtime, token, result}, state) do
    {:noreply, complete_invocation(token, result, state)}
  end

  def handle_info({:arbor_mcp_step_ready, token}, state) do
    case Map.get(state.ingress, token) do
      %{connection: connection} when connection == state.connection ->
        {:noreply, advance_ingress(token, state)}

      _ ->
        Runtime.discard_ingress(state.runtime, token)
        {:noreply, %{state | ingress: Map.delete(state.ingress, token)}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _peer, _reason}, %{peer_monitor: monitor} = state),
    do: {:noreply, replace_peer(nil, state)}

  def handle_info({:transport_message, message}, state) do
    # Raw Erlang send bypasses the supported ingress API's pre-mailbox bound.
    case Runtime.reserve_ingress(state.runtime, message,
           owner: self(),
           reply_to: self(),
           scope: {:connection, state.connection}
         ) do
      {:ok, _route, reservation} -> accept_ingress(reservation.token, message, state)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({:transport_error, reason}, state) do
    Logger.error("Transport error",
      reason_shape: LogSummary.describe(reason)
    )

    {:noreply, state}
  end

  def handle_info(
        {:ex_mcp_subscription_message, listener, kind, message},
        state
      ) do
    if listener not in Map.values(state.subscriptions) do
      Subscriptions.delivered(listener)
      {:noreply, state}
    else
      case send_message(message, state) do
        {:ok, new_state} ->
          Subscriptions.delivered(listener)

          new_state =
            if kind == :complete,
              do: remove_subscription_by_listener(new_state, listener),
              else: new_state

          {:noreply, new_state}

        {:error, _reason} ->
          Arbor.MCP.Server.SubscriptionListener.cancel(listener)
          {:noreply, remove_subscription_by_listener(state, listener)}
      end
    end
  end

  def handle_info({:subscription_listener_closed, listener, _token, _transport, _reason}, state) do
    {:noreply, remove_subscription_by_listener(state, listener)}
  end

  def handle_info({:test_transport_connect, client_pid}, state) do
    {:noreply, replace_peer(client_pid, state)}
  end

  def handle_info({:transport_closed}, state) do
    Logger.info("Transport closed")
    {:stop, :normal, state}
  end

  def handle_info({:cancelled, request_id}, state) do
    # Handle cancellation notifications from clients
    Logger.debug("Received cancellation for request",
      request_id_hash: LogSummary.fingerprint(request_id)
    )

    # Check if this request is still pending and cancel it
    case Map.get(state.pending_requests, request_id) do
      nil ->
        # Request not found - either completed, cancelled, or never existed
        Logger.debug("Cancellation for unknown request",
          request_id_hash: LogSummary.fingerprint(request_id)
        )

        {:noreply, state}

      _pending_request ->
        # Cancel the pending request
        new_state = drop_reverse(request_id, state)

        Logger.debug("Cancelled pending request",
          request_id_hash: LogSummary.fingerprint(request_id)
        )

        {:noreply, new_state}
    end
  end

  def handle_info({:request_timeout, request_id}, state) do
    # Handle timeout for server->client requests
    case Map.get(state.pending_requests, request_id) do
      nil ->
        # Request already completed or doesn't exist
        {:noreply, state}

      {from, :server_request} ->
        # Request timed out, reply with timeout error
        GenServer.reply(from, {:error, :timeout})

        # Remove from pending requests
        {:noreply, drop_reverse(request_id, state)}

      _ ->
        # Not a server request, ignore
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp decode_transport_message(message) when is_binary(message), do: Jason.decode(message)
  defp decode_transport_message(message) when is_map(message), do: {:ok, message}
  defp decode_transport_message(messages) when is_list(messages), do: {:ok, messages}
  defp decode_transport_message(_message), do: {:error, :invalid_message}

  defp wire_ids(message) do
    message
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id, "method" => method}
      when (is_binary(id) or is_integer(id)) and is_binary(method) ->
        if :erlang.external_size(id) <= 4_000, do: [id], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp uncancellable_ids(message) do
    for %{"id" => id, "method" => "initialize"} <- List.wrap(message),
        (is_binary(id) or is_integer(id)) and :erlang.external_size(id) <= 4_000,
        do: id
  end

  defp drain_published(state) do
    pending =
      Admission.pending_ingress(Ref.table(state.runtime))
      |> Enum.sort_by(fn {_token, reservation} -> reservation.sequence end)

    Enum.reduce(pending, state, &drain_reservation/2)
  end

  defp drain_reservation({token, reservation}, state) do
    cond do
      reservation.terminal ->
        fail_published(token, reservation, state)

      (state.batch_active || state.initializing) &&
          reservation.kind not in [:edge_control, :edge_response] ->
        state

      true ->
        case Admission.checkout(Ref.table(state.runtime), token) do
          {:ok, _reservation, payload} -> dispatch_published(token, payload, state)
          _expired -> state
        end
    end
  end

  defp dispatch_published(token, {:transport, connection, message}, state) do
    if connection == state.connection do
      {:noreply, state} = accept_ingress(token, message, state)
      state
    else
      finish_ingress(token, state)
    end
  end

  defp dispatch_published(token, {:custom, request, :edge_control, _opts}, state),
    do: process_edge_control(token, request["payload"], state)

  defp dispatch_published(token, {:custom, request, kind, opts}, state) do
    case Runtime.dispatch_reserved(state.runtime, token, request, Keyword.put(opts, :kind, kind)) do
      {:ok, _token} ->
        state

      {:error, reason} ->
        Admission.terminal(Ref.table(state.runtime), token, {:error, reason})
        finish_ingress(token, state)
    end
  end

  defp process_edge_control(token, {kind, request, origin}, state) do
    if active_origin?(origin, token, state) do
      result =
        case kind do
          :edge_call -> handle_call(request, {self(), {:runtime_edge_reply, token}}, state)
          :edge_cast -> handle_cast(request, state)
        end

      case result do
        {:reply, reply, state} ->
          Admission.terminal(Ref.table(state.runtime), token, {:ok, reply})
          finish_ingress(token, state)

        {:noreply, state} when kind == :edge_cast ->
          Admission.terminal(Ref.table(state.runtime), token, :notification)
          finish_ingress(token, state)

        {:noreply, state} ->
          state
      end
    else
      Admission.terminal(Ref.table(state.runtime), token, {:ok, {:error, :request_cancelled}})
      finish_ingress(token, state)
    end
  end

  defp active_origin?(nil, _token, _state), do: true

  defp active_origin?(%{scope: scope} = origin, token, state) do
    connection_matches =
      case scope do
        {:connection, connection} when is_reference(connection) -> connection == state.connection
        _ -> true
      end

    connection_matches and
      case Admission.current(Ref.table(state.runtime), token) do
        {:ok, %{origin: ^origin, origin_status: :completed}} ->
          true

        {:ok, %{origin: ^origin, origin_status: :active}} ->
          Admission.origin_active?(Ref.table(state.runtime), origin)

        _ ->
          false
      end
  end

  defp drop_reverse(id, state) do
    if timer = state.pending_timers[id], do: Process.cancel_timer(timer)

    %{
      state
      | pending_requests: Map.delete(state.pending_requests, id),
        pending_timers: Map.delete(state.pending_timers, id)
    }
  end

  defp fail_unbound_ingress(token, state) do
    case {Map.get(state.ingress, token), Admission.current(Ref.table(state.runtime), token)} do
      {nil, {:ok, %{stage: :published} = reservation}} ->
        fail_published(token, reservation, state)

      {nil, _reservation} ->
        expired =
          for {id, {{_pid, {:runtime_edge_reply, ^token}}, :server_request}} <-
                state.pending_requests,
              do: id

        state = Enum.reduce(expired, state, &drop_reverse/2)
        Runtime.discard_ingress(state.runtime, token)
        state

      {_ingress, _reservation} ->
        expire_ingress(token, state)
    end
  end

  defp fail_published(token, reservation, state) do
    state =
      if reservation.scope == {:connection, state.connection} do
        responses =
          Enum.map(
            reservation.wire_ids,
            &JSONRPC.error(&1, ErrorCodes.internal_error(), "Request timeout", %{
              "type" => "handler_timeout"
            })
          )

        case responses do
          [] -> state
          [response] when not reservation.batch? -> send_response(response, state)
          responses -> send_response(responses, state)
        end
      else
        state
      end

    finish_ingress(token, state)
  end

  defp accept_ingress(token, message, state) do
    case decode_transport_message(message) do
      {:ok, %{"result" => _result} = response} ->
        Runtime.discard_ingress(state.runtime, token)
        handle_client_response(response, state)

      {:ok, %{"error" => _error} = response} ->
        Runtime.discard_ingress(state.runtime, token)
        handle_client_response(response, state)

      {:ok, requests} when is_list(requests) ->
        enqueue_ingress(token, requests, true, state)

      {:ok, request} when is_map(request) ->
        if request["method"] == "notifications/cancelled" do
          state = %{state | current_ingress: token}
          {_kind, state} = process_mcp_request(request, state)
          Runtime.discard_ingress(state.runtime, token)
          {:noreply, %{state | current_ingress: nil}}
        else
          enqueue_ingress(token, [request], false, state)
        end

      _invalid ->
        Runtime.discard_ingress(state.runtime, token)
        {:noreply, state}
    end
  end

  defp enqueue_ingress(token, requests, batch?, state) do
    ingress = %{
      remaining: requests,
      responses: [],
      batch?: batch?,
      connection: state.connection,
      checked: false
    }

    state = put_in(state.ingress[token], ingress)
    state = if batch?, do: %{state | batch_active: token}, else: state

    if state.initializing do
      {:noreply, %{state | ingress_queue: :queue.in(token, state.ingress_queue)}}
    else
      {:noreply, advance_ingress(token, state)}
    end
  end

  defp advance_ingress(token, state) do
    case Admission.current(Ref.table(state.runtime), token) do
      {:ok, %{terminal: false, deadline: deadline}} ->
        if deadline > System.monotonic_time(:millisecond),
          do: do_advance_ingress(token, state),
          else: expire_ingress(token, state)

      _ ->
        expire_ingress(token, state)
    end
  end

  defp do_advance_ingress(token, state) do
    case Map.get(state.ingress, token) do
      %{batch?: true, checked: false} = ingress ->
        check_batch(token, ingress, state)

      %{remaining: []} = ingress ->
        responses = Enum.reverse(ingress.responses)

        state =
          if ingress.batch? and responses != [], do: send_response(responses, state), else: state

        finish_ingress(token, state)

      %{remaining: [request | remaining]} ->
        state = put_in(state.ingress[token].remaining, remaining)
        state = %{state | current_ingress: token}

        result = process_ingress_entry(token, request, state)

        case result do
          {:pending, state} ->
            %{state | current_ingress: nil}

          {:response, response, state} ->
            state = record_response(token, response, state)
            advance_ingress(token, %{state | current_ingress: nil})

          {:notification, state} ->
            advance_ingress(token, %{state | current_ingress: nil})
        end

      nil ->
        state
    end
  end

  defp check_batch(token, ingress, state) do
    if ingress.remaining != [] and batch_allowed?(state, ingress.remaining) do
      advance_ingress(token, put_in(state.ingress[token].checked, true))
    else
      message =
        if ingress.remaining == [],
          do: "Invalid Request",
          else: "Batch requests are not supported in protocol version #{state.protocol_version}"

      state = send_response(JSONRPC.error(nil, ErrorCodes.invalid_request(), message), state)
      finish_ingress(token, state)
    end
  end

  defp batch_allowed?(%{protocol_mode: :modern_only}, _requests), do: false
  defp batch_allowed?(%{connection_era: :modern}, _requests), do: false

  defp batch_allowed?(state, requests) do
    batch_supported?(state.protocol_version) and not Enum.any?(requests, &modern_batch_entry?/1)
  end

  defp modern_batch_entry?(request) when is_map(request) do
    case RequestContext.from_message(request) do
      {:ok, %RequestContext{era: :modern}} -> true
      _legacy_or_invalid -> false
    end
  end

  defp modern_batch_entry?(_invalid), do: false

  defp process_ingress_entry(token, request, state) do
    cancelled_native =
      is_map(request) and
        request["method"] in ["subscriptions/listen", "notifications/cancelled"] and
        :ets.member(Ref.table(state.runtime), {:wire_cancel, token, request["id"]})

    if cancelled_native do
      {:response,
       JSONRPC.error(request["id"], ErrorCodes.request_cancelled(), "Request cancelled"), state}
    else
      process_mcp_request(request, state)
    end
  end

  defp complete_invocation(token, result, state) do
    case Map.pop(state.invocations, token) do
      {nil, _invocations} ->
        if match?({:error, _reason}, result), do: fail_unbound_ingress(token, state), else: state

      {%{kind: :call, from: from}, invocations} ->
        reply =
          case result do
            {:ok, reply} -> reply
            error -> error
          end

        GenServer.reply(from, reply)
        %{state | invocations: invocations}

      {%{kind: :rpc} = invocation, invocations} ->
        state = %{state | invocations: invocations}
        state = complete_rpc(token, invocation, result, state)
        finish_initialize_barrier(token, state)
    end
  end

  defp complete_rpc(token, invocation, result, state) do
    if invocation.connection == state.connection do
      response = rpc_response(invocation, result)
      state = observe_initialize(invocation.method, response, state)
      if response, do: record_response(token, response, state), else: state
    else
      state
    end
  end

  defp rpc_response(_invocation, {:ok, response}), do: response
  defp rpc_response(_invocation, {:error, response}) when is_map(response), do: response

  defp rpc_response(%{id: id}, {:error, reason}) when not is_nil(id),
    do:
      JSONRPC.error(id, ErrorCodes.internal_error(), "Request interrupted", %{
        "type" => to_string_reason(reason)
      })

  defp rpc_response(_invocation, _notification), do: nil

  defp observe_initialize("initialize", %{"result" => result}, state) when is_map(result) do
    emit_initialize_telemetry(result)
    %{state | protocol_version: protocol_version_from_result(result)}
  end

  defp observe_initialize(_method, _response, state), do: state

  defp finish_initialize_barrier(token, %{initializing: token} = state) do
    state = %{state | initializing: nil}
    if state.batch_active, do: state, else: drain_published(drain_ingress_queue(state))
  end

  defp finish_initialize_barrier(_token, state), do: state

  defp record_response(token, response, state) do
    case Map.get(state.ingress, token) do
      %{batch?: true} ->
        update_in(state.ingress[token].responses, &[response | &1])

      %{connection: connection} when connection == state.connection ->
        send_response(response, state)

      _ ->
        state
    end
  end

  defp send_response(response, state) do
    case send_message(response, state) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp finish_ingress(token, state) do
    Runtime.discard_ingress(state.runtime, token)
    state = %{state | ingress: Map.delete(state.ingress, token)}

    if state.batch_active == token do
      drain_published(%{state | batch_active: nil})
    else
      state
    end
  end

  defp expire_ingress(token, state) do
    case Map.get(state.ingress, token) do
      %{connection: connection} when connection != state.connection ->
        finish_ingress(token, state)

      _ ->
        do_expire_ingress(token, state)
    end
  end

  defp do_expire_ingress(token, state) do
    state =
      case Map.get(state.ingress, token) do
        %{remaining: remaining} ->
          Enum.reduce(remaining, state, fn request, state ->
            if notification?(request),
              do: state,
              else:
                record_response(
                  token,
                  JSONRPC.error(
                    response_id(request),
                    ErrorCodes.internal_error(),
                    "Request timeout",
                    %{"type" => "handler_timeout"}
                  ),
                  state
                )
          end)

        _ ->
          state
      end

    case Map.get(state.ingress, token) do
      %{batch?: true, responses: responses} when responses != [] ->
        state = send_response(Enum.reverse(responses), state)
        finish_ingress(token, state)

      %{batch?: false, responses: [response | _responses]} ->
        state = send_response(response, state)
        finish_ingress(token, state)

      _ ->
        finish_ingress(token, state)
    end
  end

  defp drain_ingress_queue(state) do
    case :queue.out(state.ingress_queue) do
      {{:value, token}, queue} ->
        state = advance_ingress(token, %{state | ingress_queue: queue})
        if state.initializing, do: state, else: drain_ingress_queue(state)

      {:empty, _queue} ->
        state
    end
  end

  defp replace_peer(peer, state) do
    if state.peer_monitor, do: Process.demonitor(state.peer_monitor, [:flush])
    if state.connection, do: Runtime.cancel_scope(state.runtime, {:connection, state.connection})

    for {_id, {from, :server_request}} <- state.pending_requests,
        do: GenServer.reply(from, {:error, :connection_closed})

    for {_id, timer} <- state.pending_timers, do: Process.cancel_timer(timer)

    Subscriptions.remove_transport(self(), state.subscription_options)

    for {id, _listener} <- state.subscriptions,
        do: :ets.delete(Ref.table(state.runtime), {:subscription, state.connection, id})

    connection = if peer, do: make_ref(), else: nil
    :ets.insert(Ref.table(state.runtime), {:edge_connection, self(), connection})

    transport_state =
      case state.transport do
        Test -> %{state.transport_state | peer_pid: peer}
        Local -> %{state.transport_state | server_pid: peer, connected: not is_nil(peer)}
      end

    %{
      state
      | transport_state: transport_state,
        connection: connection,
        peer_monitor: if(peer, do: Process.monitor(peer), else: nil),
        pending_requests: %{},
        pending_timers: %{},
        protocol_version: nil,
        connection_era: nil,
        validation_state:
          MessageValidator.new_session(nil,
            max_request_ids: state.validation_state.max_request_ids
          ),
        initializing: nil,
        batch_active: nil,
        ingress_queue: :queue.new(),
        subscriptions: %{}
    }
  end

  # Batches are allowed up to (but not including) the version that removed
  # them. Ordering comes from VersionRegistry (newest first) instead of a
  # string equality check, so newer versions such as 2025-11-25 also reject
  # batches (audit M7).
  defp batch_supported?(nil), do: true

  defp batch_supported?(version) do
    versions = VersionRegistry.supported_versions()
    removed_index = Enum.find_index(versions, &(&1 == @batch_removed_in))
    version_index = Enum.find_index(versions, &(&1 == version))

    cond do
      is_nil(removed_index) -> true
      is_nil(version_index) -> false
      true -> version_index > removed_index
    end
  end

  @impl GenServer
  def handle_call({:runtime_subscription_cancel, connection, id}, _from, state) do
    if connection == state.connection do
      :ok = Subscriptions.cancel(self(), id, state.subscription_options)
      :ets.delete(Ref.table(state.runtime), {:subscription, connection, id})
      {:reply, :ok, %{state | subscriptions: Map.delete(state.subscriptions, id)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:runtime_peer_connect, peer}, _from, state) when is_pid(peer) do
    state = replace_peer(peer, state)
    {:reply, {:ok, state.runtime, state.connection}, state}
  end

  def handle_call(:get_pending_requests, _from, state) do
    ids =
      for {{:wire_request, {:connection, connection}, id, _token}, _active} <-
            :ets.tab2list(Ref.table(state.runtime)),
          connection == state.connection,
          do: id

    ids = Enum.uniq(ids)
    {:reply, ids, state}
  end

  def handle_call(:ping, from, state), do: reverse_request("ping", %{}, 5_000, from, state)

  def handle_call({:list_roots, timeout}, from, state),
    do: reverse_request("roots/list", %{}, timeout, from, state)

  def handle_call(:list_roots, from, state), do: handle_call({:list_roots, 5_000}, from, state)

  def handle_call({:create_message, params}, from, state),
    do: reverse_request("sampling/createMessage", params, 5_000, from, state)

  def handle_call(request, from, state) do
    case Runtime.submit(state.runtime, %{"payload" => request},
           kind: :call,
           caller: elem(from, 0),
           owner: self(),
           reply_to: self(),
           scope: {:control, self()}
         ) do
      {:ok, token} ->
        {:noreply, put_in(state.invocations[token], %{kind: :call, from: from})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast({:send_log_message, level, message, data}, state) do
    # Send log notification to client
    log_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{
        "level" => level,
        "logger" => "Arbor.MCP.Server",
        "data" => data || %{},
        "message" => message
      }
    }

    case send_message(log_notification, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:notify_progress, progress_token, progress, total}, state) do
    # Send progress notification to client
    progress_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{
        "progressToken" => progress_token,
        "progress" => progress,
        "total" => total
      }
    }

    case send_message(progress_notification, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:notify_resource_update, uri}, state) do
    publish_or_send("notifications/resources/updated", %{"uri" => uri}, state)
  end

  def handle_cast({:notify_resources_changed}, state) do
    publish_or_send("notifications/resources/list_changed", %{}, state)
  end

  def handle_cast({:notify_tools_changed}, state) do
    publish_or_send("notifications/tools/list_changed", %{}, state)
  end

  def handle_cast({:notify_prompts_changed}, state) do
    publish_or_send("notifications/prompts/list_changed", %{}, state)
  end

  def handle_cast(:notify_roots_changed, state) do
    # Send roots changed notification to client
    roots_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/roots/list_changed",
      "params" => %{}
    }

    case send_message(roots_notification, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:notification, "notifications/cancelled", params}, state) do
    # Handle cancellation notifications from clients
    handle_cancellation_notification(params, state)
  end

  def handle_cast(request, state) do
    _result =
      Runtime.submit(state.runtime, %{"payload" => request},
        kind: :cast,
        owner: self(),
        reply_to: self(),
        scope: {:control, self()}
      )

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Subscriptions.remove_transport(self(), state.subscription_options)

    for {id, _listener} <- state.subscriptions,
        do: :ets.delete(Ref.table(state.runtime), {:subscription, state.connection, id})

    :ok
  end

  defp reverse_request(method, params, timeout, from, state) do
    if map_size(state.pending_requests) >= state.max_reverse_requests do
      {:reply, {:error, :server_busy}, state}
    else
      id = System.unique_integer([:positive])
      request = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

      case send_message(request, state) do
        {:ok, state} ->
          timer = Process.send_after(self(), {:request_timeout, id}, timeout)

          {:noreply,
           %{
             state
             | pending_requests: Map.put(state.pending_requests, id, {from, :server_request}),
               pending_timers: Map.put(state.pending_timers, id, timer)
           }}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  # Private functions

  # Handle responses from clients to server requests
  defp handle_client_response(%{"id" => request_id} = response, state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        Logger.warning(
          "Received response for unknown request ID",
          request_id_hash: LogSummary.fingerprint(request_id)
        )

        {:noreply, state}

      {from, :server_request} ->
        # This is a response to a server->client request
        if Map.has_key?(response, "result") do
          GenServer.reply(from, {:ok, response["result"]})
        else
          error = response["error"]
          GenServer.reply(from, {:error, error})
        end

        # Remove from pending requests
        {:noreply, drop_reverse(request_id, state)}

      _ ->
        Logger.warning(
          "Received response for request with unexpected pending state",
          request_id_hash: LogSummary.fingerprint(request_id)
        )

        {:noreply, state}
    end
  end

  defp handle_client_response(response, state) do
    Logger.warning("Received response without ID: #{LogSummary.describe(response)}")

    {:noreply, state}
  end

  # Handle cancellation notifications from clients
  defp handle_cancellation_notification(%{"requestId" => request_id} = params, state) do
    reason = Map.get(params, "reason", "Request cancelled by client")

    Logger.debug("Received cancellation request",
      request_id_hash: LogSummary.fingerprint(request_id),
      reason_shape: LogSummary.describe(reason)
    )

    Runtime.cancel(state.runtime, {:connection, state.connection}, request_id)
    {:noreply, state}
  end

  defp handle_cancellation_notification(params, state) do
    Logger.warning("Invalid cancellation notification: #{LogSummary.describe(params)}")

    {:noreply, state}
  end

  defp connect_transport(:test, opts) do
    case Test.connect(opts) do
      {:ok, transport_state} -> {:ok, {Test, transport_state}}
      error -> error
    end
  end

  defp connect_transport(:beam, opts) do
    case Local.connect(opts) do
      {:ok, transport_state} -> {:ok, {Local, transport_state}}
      error -> error
    end
  end

  defp connect_transport(transport_type, _opts) do
    {:error, {:unsupported_transport, transport_type}}
  end

  # Process a single MCP request or notification.
  #
  # Method coverage and result/error shaping live in Arbor.MCP.Server.Dispatch so
  # that every transport answers the same set of methods identically (audit
  # M9). Only the pieces that are specific to this process — protocol version
  # capture, telemetry, and cancellation bookkeeping — stay here.
  defp process_mcp_request(request, state) do
    case MessageValidator.validate_message(request, state.validation_state) do
      {{:ok, _validated_request}, validation_state} ->
        do_process_mcp_request(request, %{state | validation_state: validation_state})

      {{:error, error}, validation_state} ->
        state = %{state | validation_state: validation_state}

        if notification?(request) do
          {:notification, state}
        else
          {:response, JSONRPC.error(response_id(request), json_rpc_validation_error(error)),
           state}
        end
    end
  end

  defp do_process_mcp_request(%{"method" => "initialize"} = request, state) do
    dispatch(request, %{state | initializing: state.current_ingress})
  end

  defp do_process_mcp_request(%{"method" => "tools/call"} = request, state) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    enhanced_arguments =
      params
      |> Map.get("arguments", %{})
      |> Map.put("_request_id", id)
      |> put_meta(Map.get(params, "_meta"))

    enhanced_params = Map.put(params, "arguments", enhanced_arguments)
    enhanced_request = Map.put(request, "params", enhanced_params)

    dispatch(enhanced_request, state)
  end

  defp do_process_mcp_request(%{"method" => "subscriptions/listen"} = request, state) do
    open_subscription(request, state)
  end

  defp do_process_mcp_request(%{"method" => "notifications/cancelled"} = request, state) do
    params = Map.get(request, "params", %{})

    case MessageValidator.validate_method_params("notifications/cancelled", params) do
      :ok ->
        request_id = Map.get(params, "requestId")

        case Map.pop(state.subscriptions, request_id) do
          {nil, _subscriptions} ->
            {_, new_state} = handle_cancellation_notification(params, state)
            {:notification, new_state}

          {_listener, subscriptions} ->
            :ok = Subscriptions.cancel(self(), request_id, state.subscription_options)
            {:notification, %{state | subscriptions: subscriptions}}
        end

      {:error, _validation_error} ->
        {:notification, state}
    end
  end

  defp do_process_mcp_request(%{"method" => _method} = request, state) do
    dispatch(request, state)
  end

  defp do_process_mcp_request(_invalid_request, state) do
    # Invalid request format (e.g. not a map)
    response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid Request")
    {:response, response, state}
  end

  defp notification?(request) when is_map(request) do
    Map.has_key?(request, "method") and not Map.has_key?(request, "id")
  end

  defp notification?(_request), do: false

  defp response_id(request) when is_map(request) do
    case Map.get(request, "id") do
      id when is_binary(id) or is_integer(id) -> id
      _invalid_or_missing -> nil
    end
  end

  defp response_id(_request), do: nil

  defp json_rpc_validation_error(error), do: stringify_map_keys(error)

  defp stringify_map_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_map_keys(nested)}
    end)
  end

  defp stringify_map_keys(value) when is_list(value), do: Enum.map(value, &stringify_map_keys/1)
  defp stringify_map_keys(value), do: value

  # Runs the shared dispatcher against the handler module and folds the new
  # handler state back into the server state.
  defp dispatch(request, state) do
    state = maybe_pin_connection_era(request, state)

    dispatch_opts = [
      protocol_mode: effective_protocol_mode(state),
      instructions: state.instructions,
      request_state: state.request_state,
      endpoint: state.endpoint,
      principal_id: state.principal_id,
      tenant_id: state.tenant_id,
      replay_cache: state.replay_cache,
      require_replay_protection: state.require_replay_protection
    ]

    token = state.current_ingress

    case Runtime.dispatch_reserved(state.runtime, token, request,
           dispatch_opts: dispatch_opts,
           retain_reservation: true
         ) do
      {:ok, ^token} ->
        invocation = %{
          kind: :rpc,
          id: Map.get(request, "id"),
          method: request["method"],
          connection: state.connection
        }

        {:pending, put_in(state.invocations[token], invocation)}

      {:error, reason} ->
        {:response,
         JSONRPC.error(response_id(request), ErrorCodes.internal_error(), "Request rejected", %{
           "type" => Atom.to_string(reason)
         }), state}
    end
  end

  defp maybe_pin_connection_era(request, %{connection_era: nil} = state) do
    with {:ok, context} <- RequestContext.from_message(request),
         era when era in [:legacy, :modern] <- pin_candidate(context),
         true <- mode_allows_era?(state.protocol_mode, era) do
      %{state | connection_era: era}
    else
      _other -> state
    end
  end

  defp maybe_pin_connection_era(_request, state), do: state

  defp pin_candidate(%RequestContext{era: :modern}), do: :modern
  defp pin_candidate(%RequestContext{era: :legacy, method: "initialize"}), do: :legacy
  defp pin_candidate(_context), do: nil

  defp mode_allows_era?(:modern_only, :legacy), do: false
  defp mode_allows_era?(:legacy_only, :modern), do: false
  defp mode_allows_era?(_mode, _era), do: true

  defp effective_protocol_mode(%{protocol_mode: mode})
       when mode in [:legacy_only, :modern_only],
       do: mode

  defp effective_protocol_mode(%{connection_era: :legacy}), do: :legacy_only
  defp effective_protocol_mode(%{connection_era: :modern}), do: :modern_only
  defp effective_protocol_mode(state), do: state.protocol_mode

  defp put_meta(arguments, nil), do: arguments
  defp put_meta(arguments, meta), do: Map.put(arguments, "_meta", meta)

  defp emit_initialize_telemetry(result) do
    server_name =
      case result do
        %{"serverInfo" => %{"name" => name}} -> name
        %{serverInfo: %{name: name}} -> name
        _ -> "unknown"
      end

    :telemetry.execute(
      [:arbor_mcp, :server, :initialize, :completed],
      %{},
      %{server_name: server_name}
    )
  end

  defp protocol_version_from_result(%{"protocolVersion" => version}), do: version
  defp protocol_version_from_result(%{protocolVersion: version}), do: version
  defp protocol_version_from_result(_result), do: nil

  defp send_message(message, state) do
    outbound_message =
      if state.transport == Arbor.MCP.Transport.Local do
        message
      else
        Jason.encode!(message)
      end

    case state.transport.send_message(outbound_message, state.transport_state) do
      {:ok, new_transport_state} ->
        {:ok, %{state | transport_state: new_transport_state}}

      # Transports may also answer with an immediate response payload.
      {:ok, new_transport_state, _response} ->
        {:ok, %{state | transport_state: new_transport_state}}

      error ->
        error
    end
  end

  defp open_subscription(request, state) do
    id = Map.get(request, "id")
    params = Map.get(request, "params") || %{}

    with :ok <- MessageValidator.validate_method_params("subscriptions/listen", params),
         {:ok, context} <- RequestContext.from_message(request),
         :ok <- RequestContext.validate_protocol_mode(context, effective_protocol_mode(state)),
         :ok <- RequestContext.validate_method(context),
         :modern <- context.era,
         {:ok, entry} <-
           Subscriptions.listen(
             id,
             Map.get(params, "notifications"),
             self(),
             Keyword.put(
               state.subscription_options,
               :client_capabilities,
               context.client_capabilities
             )
           ) do
      subscriptions = Map.put(state.subscriptions, id, entry.listener_pid)

      :ets.insert(
        Ref.table(state.runtime),
        {{:subscription, state.connection, id}, entry.listener_pid}
      )

      {:notification, %{state | subscriptions: subscriptions, connection_era: :modern}}
    else
      {:error, reason} ->
        {:response, subscription_error(id, reason), state}

      _other ->
        {:response, subscription_error(id, :modern_protocol_required), state}
    end
  end

  defp subscription_error(id, %ProtocolError{} = error) do
    JSONRPC.error(id, error.code, error.message, error.data)
  end

  defp subscription_error(id, %{code: code, message: message} = error) do
    JSONRPC.error(id, code, message, Map.get(error, :data))
  end

  defp subscription_error(id, reason) do
    JSONRPC.error(id, ErrorCodes.invalid_params(), "Subscription request rejected", %{
      "reason" => to_string_reason(reason)
    })
  end

  defp to_string_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_string_reason(_reason), do: "invalid_subscription"

  defp publish_or_send(method, params, state) do
    if modern_connection?(state) do
      _counts =
        Subscriptions.publish(
          method,
          params,
          Keyword.put(state.subscription_options, :transport_ref, self())
        )

      {:noreply, state}
    else
      notification = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

      case send_message(notification, state) do
        {:ok, new_state} -> {:noreply, new_state}
        {:error, _reason} -> {:noreply, state}
      end
    end
  end

  defp modern_connection?(%{connection_era: :modern}), do: true
  defp modern_connection?(%{protocol_version: version}), do: VersionRegistry.modern?(version)

  defp remove_subscription_by_listener(state, listener) do
    for {id, ^listener} <- state.subscriptions,
        do: :ets.delete(Ref.table(state.runtime), {:subscription, state.connection, id})

    subscriptions =
      Map.reject(state.subscriptions, fn {_id, listener_pid} -> listener_pid == listener end)

    %{state | subscriptions: subscriptions}
  end
end
