defmodule Arbor.MCP.Server.Runtime.HTTPGateway do
  @moduledoc false
  use GenServer
  alias Arbor.MCP.Internal.MessageValidator
  alias Arbor.MCP.Server.{RequestContext, SubscriptionListener, Subscriptions}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPCancellation,
    HTTPReverse,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket,
    Initialization,
    OutputController,
    OutputTicket,
    Ref
  }

  @reap_ms 10

  def start_link(opts) do
    with {:ok, pid} <-
           GenServer.start_link(__MODULE__, fn -> opts end,
             timeout: Initialization.remaining(opts[:table])
           ),
         :ok <- Initialization.watch(opts[:table], pid),
         do: {:ok, pid}
  end

  def submit(runtime, binding, message, opts \\ []) do
    with {:ok, runtime} <- Runtime.ref(runtime),
         {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         true <- proof.owner == self(),
         {:ok, gateway} <- address(runtime),
         {:ok, format, dispatch_opts} <- options(opts),
         {:ok, response_bytes} <- response_metadata_reserve(runtime, message),
         identity = HTTPCancellation.identity(dispatch_opts, message, proof.lease),
         retained = %{
           binding: binding,
           format: format,
           dispatch_opts: dispatch_opts,
           acceptance: nil,
           socket: self(),
           scope: proof.scope,
           lease: proof.lease,
           identity: identity,
           lifecycle_metadata_reserve:
             :binary.copy(
               <<0>>,
               5_024 + response_bytes +
                 2 * :erlang.external_size({proof.scope, proof.lease, identity}) +
                 HTTPCancellation.marker_metadata_bytes(
                   runtime,
                   proof.scope,
                   proof.lease,
                   identity,
                   wire_ids(message)
                 )
             )
         },
         {:ok, admitted_message, attempts, entered_responses} <-
           preflight(runtime, proof, gateway, message, retained) do
      submit_work(runtime, proof, gateway, binding, admitted_message, retained, attempts)
      |> partial_result(entered_responses)
    else
      false -> {:error, :invalid_http_writer}
      error -> error
    end
  end

  defp submit_work(runtime, proof, gateway, binding, message, retained, attempts) do
    with {:ok, acceptance} <- acceptance(binding, message, gateway) do
      retained = Map.put(retained, :acceptance, acceptance)
      result = publish_retry(runtime, proof, gateway, message, retained, attempts)

      if match?({:error, _}, result) and acceptance,
        do: HTTPWriterRegistry.release(acceptance)

      result
    end
  end

  defp preflight(runtime, proof, gateway, [_ | _] = members, retained) do
    {responses, work} = Enum.split_with(members, &response_member?/1)

    if responses != [] and work != [] do
      reply = :erlang.alias()
      retained = Map.put(retained, :acceptance, nil)

      try do
        with {:ok, route, reservation} <-
               Runtime.reserve_ingress(runtime, responses,
                 kind: :edge_response,
                 owner: gateway,
                 caller: self(),
                 reply_to: reply,
                 edge: gateway,
                 scope: proof.scope,
                 admission_deadline: proof.deadline,
                 invocation_deadline: proof.deadline,
                 dispatch_opts: [http: retained]
               ),
             :ok <-
               Runtime.publish_ingress(
                 runtime,
                 route,
                 reservation,
                 {:http_reverse_preflight, responses, retained, reply},
                 gateway
               ),
             {:ok, entered} <- await_preflight(reservation.token, proof.deadline) do
          {:ok, work, 512, entered}
        end
      after
        :erlang.unalias(reply)
      end
    else
      {:ok, members, 1, 0}
    end
  end

  defp preflight(_runtime, _proof, _gateway, message, _retained), do: {:ok, message, 1, 0}

  defp partial_result({:error, reason}, count) when count > 0,
    do: {:error, {:http_partial_effect, %{accepted_responses: count, normal_outcome: reason}}}

  defp partial_result(result, _count), do: result

  defp await_preflight(token, deadline) do
    if Deadline.remaining(deadline) == 0 do
      preflight_uncertain(:handler_timeout)
    else
      receive do
        {:http_reverse_preflight, ^token, {:accepted, entered}} ->
          if Deadline.remaining(deadline) > 0,
            do: {:ok, entered},
            else: partial_result({:error, :handler_timeout}, entered)

        {:arbor_mcp_runtime, ^token, :notification} ->
          await_preflight(token, deadline)

        {:arbor_mcp_runtime, ^token, _error} ->
          preflight_uncertain(:http_preflight_retired)
      after
        Deadline.remaining(deadline) -> preflight_uncertain(:handler_timeout)
      end
    end
  end

  defp preflight_uncertain(reason),
    do:
      {:error,
       {:http_partial_effect, %{accepted_responses: :unconfirmed, normal_outcome: reason}}}

  defp publish_retry(runtime, proof, gateway, message, retained, attempts) do
    case publish(runtime, proof, gateway, message, retained) do
      {:error, :server_busy} when attempts > 1 ->
        if proof.deadline > Deadline.now() do
          Process.sleep(min(5, Deadline.remaining(proof.deadline)))
          publish_retry(runtime, proof, gateway, message, retained, attempts - 1)
        else
          {:error, :handler_timeout}
        end

      result ->
        result
    end
  end

  def establish_session_stream(runtime, binding, endpoint) do
    with {:ok, runtime} <- Runtime.ref(runtime),
         {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         true <- proof.owner == self(),
         :ok <- HTTPWriterRegistry.request_session_stream(binding, endpoint),
         {:ok, gateway} <- address(runtime),
         remaining = proof.deadline - System.monotonic_time(:millisecond),
         true <- remaining > 0,
         result = GenServer.call(gateway, {:establish_session_stream, binding}, remaining),
         true <- proof.deadline > System.monotonic_time(:millisecond),
         do: result,
         else: (error -> session_stream_error(error))
  catch
    :exit, _reason -> {:error, :http_session_stream_closed}
  end

  defp session_stream_error({:error, _reason} = error), do: error
  defp session_stream_error(_invalid), do: {:error, :invalid_http_session_stream}

  defp publish(runtime, proof, gateway, message, retained) do
    with {:ok, route, reservation} <-
           Runtime.reserve_ingress(runtime, message,
             kind: if(response_only?(message), do: :edge_response, else: :ingress),
             owner: gateway,
             caller: self(),
             reply_to: gateway,
             edge: gateway,
             scope: proof.scope,
             admission_deadline: proof.deadline,
             invocation_deadline: proof.deadline,
             dispatch_opts: [http: retained],
             wire_ids: wire_ids(message),
             uncancellable_ids: uncancellable_ids(message),
             batch?: is_list(message)
           ),
         :ok <-
           Runtime.publish_ingress(
             runtime,
             route,
             reservation,
             {:http, message, retained},
             gateway
           ),
         do: {:ok, reservation.token}
  end

  defp acceptance(binding, message, gateway) do
    if notification_only?(message) or response_only?(message) do
      case HTTPWriterRegistry.prepare(binding, "",
             owner: gateway,
             release_owner: self(),
             metadata: %{accepted: true}
           ) do
        {:ok, ticket} ->
          case HTTPWriterRegistry.handoff(ticket) do
            :ok ->
              {:ok, ticket}

            error ->
              HTTPWriterRegistry.release(ticket)
              error
          end

        error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  defp notification_only?([_ | _] = members), do: Enum.all?(members, &notification_only?/1)

  defp notification_only?(%{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method),
       do:
         not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
           not Map.has_key?(message, "error")

  defp notification_only?(_message), do: false

  defp response_metadata_reserve(runtime, message) do
    # A direct installed-binding caller must pass the same finite lane boundary
    # before constructing retained metadata. The Plug body/member validator is
    # not the sole admission boundary. Normal lane claims remain later so an
    # entered mixed-array response prefix keeps its explicit partial outcome.
    with {:ok, route} <- Admission.route(Ref.table(runtime)),
         capacity =
           route.config.max_concurrency + route.config.max_queue +
             route.config.max_control_queue,
         {:ok, count} <- response_count(List.wrap(message), capacity, 0),
         true <- count <= route.config.max_control_queue do
      bytes = if count == 0, do: 0, else: 32_768 + count * 2_048

      if bytes <= route.config.max_control_bytes,
        do: {:ok, bytes},
        else: {:error, :request_too_large}
    else
      false -> {:error, :server_busy}
      error -> error
    end
  end

  defp response_count([], _capacity, count), do: {:ok, count}
  defp response_count([_ | _], 0, _count), do: {:error, :server_busy}

  defp response_count([member | remaining], capacity, count),
    do:
      response_count(
        remaining,
        capacity - 1,
        count + if(response_member?(member), do: 1, else: 0)
      )

  defp response_only?([_ | _] = members), do: Enum.all?(members, &response_member?/1)
  defp response_only?(message), do: response_member?(message)

  defp response_member?(%{"jsonrpc" => "2.0", "id" => id} = response)
       when is_binary(id) or is_integer(id) or is_nil(id),
       do:
         not Map.has_key?(response, "method") and
           match?({:ok, _}, MessageValidator.validate_response(response))

  defp response_member?(_message), do: false

  def address(runtime) do
    case :ets.lookup(Ref.table(runtime), :http_gateway) do
      [{:http_gateway, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :http_gateway_unavailable}

      _missing ->
        {:error, :http_gateway_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_gateway_unavailable}
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 2 and
         Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:format, :dispatch_opts])) do
      format = Keyword.get(opts, :format, :json)
      dispatch = Keyword.get(opts, :dispatch_opts, [])

      if format in [:json, :sse, :legacy_sse] and Keyword.keyword?(dispatch),
        do: {:ok, format, dispatch},
        else: {:error, :invalid_http_gateway_options}
    else
      {:error, :invalid_http_gateway_options}
    end
  end

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  @impl true
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    :ok = Initialization.watch(table, self())
    :ets.insert(table, {:http_gateway, self()})
    Process.send_after(self(), :reap, @reap_ms)

    {:ok,
     %{
       runtime: Ref.new(opts[:supervisor], table),
       table: table,
       jobs: %{},
       reverse: HTTPReverse.init(table)
     }}
  end

  @impl true
  def handle_info(:runtime_ingress_ready, state) do
    :ets.delete(state.table, {:ingress_wakeup, self()})

    pending =
      Admission.pending_ingress(state.table) |> Enum.sort_by(fn {_, item} -> item.sequence end)

    state =
      Enum.reduce(pending, state, fn {token, reservation}, state ->
        if reservation.edge == self() do
          case Admission.checkout(state.table, token) do
            {:ok, _entry, {:http, message, retained}} ->
              accept(token, message, retained, state)

            {:ok, entry, {:http_reverse, control}} ->
              %{state | reverse: HTTPReverse.accept(state.reverse, token, control, entry)}

            {:ok, entry, {:http_reverse_preflight, responses, retained, reply}} ->
              accept_preflight(token, entry, responses, retained, reply, state)

            _unavailable ->
              state
          end
        else
          state
        end
      end)

    {:noreply, state}
  end

  def handle_info(
        {:arbor_mcp_runtime, token, {:ok, %{"__runtime_output" => ticket} = result}},
        state
      ) do
    case state.jobs[token] do
      %{batch?: true} ->
        case OutputController.deliver(state.table, token, ticket) do
          :ok ->
            state = put_in(state.jobs[token].output?, true)

            state =
              if state.jobs[token].initializing? and
                   Map.has_key?(result, "error"),
                 do: put_in(state.jobs[token].remaining, []),
                 else: state

            {:noreply, state}

          {:error, reason} ->
            {:noreply, fail(token, reason, state)}
        end

      %{} ->
        case OutputController.deliver(state.table, token, ticket) do
          :ok ->
            {:noreply,
             put_in(
               state.jobs[token].observation,
               HTTPWriteTicket.observation(OutputTicket.http(ticket))
             )}

          {:error, reason} ->
            {:noreply, fail(token, reason, state)}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:arbor_mcp_step_ready, token}, state), do: {:noreply, advance(token, state)}

  def handle_info({:http_cancel_settled, token, phase, result}, state) do
    case state.jobs[token] do
      %{cancelling?: true, cancellation_phase: ^phase} ->
        Admission.terminal(state.table, token, result)
        state = put_in(state.jobs[token].cancelling?, false)

        if result == :notification do
          Admission.release_step(state.table, token)
          {:noreply, state}
        else
          {:noreply, finish(token, state)}
        end

      _retired ->
        {:noreply, state}
    end
  end

  def handle_info({:http_output_settled, token, _result}, state),
    do: {:noreply, finish(token, state)}

  def handle_info({:arbor_mcp_runtime, token, {:error, reason}}, state),
    do: {:noreply, fail(token, reason, state)}

  def handle_info({:arbor_mcp_runtime, _token, :notification}, state), do: {:noreply, state}

  def handle_info(:reap, state) do
    state = settle_reverse(state)

    state =
      Enum.reduce(state.jobs, state, fn {token, job}, state ->
        state = retire_replaced_cancellation(token, job, state)
        job = state.jobs[token]

        case job.observation && HTTPWriteTicket.observation_status(job.observation) do
          nil ->
            if job.done?, do: finish(token, state), else: state

          result when result in [:pending, :in_flight] ->
            state

          result when result in [:returned, :failed, :uncertain] ->
            finish(token, state)

          _retired ->
            if job.failed? or job.done? or job.socket_down?,
              do: finish(token, state),
              else: fail(token, :handler_timeout, state)
        end
      end)

    Process.send_after(self(), :reap, @reap_ms)
    {:noreply, state}
  end

  def handle_info(:http_reverse_ready, state) do
    :ets.delete(state.table, {:http_reverse_wake, self()})
    {:noreply, settle_reverse(state)}
  end

  def handle_info({:DOWN, monitor, :process, _socket, _reason}, state) do
    state =
      Enum.reduce(state.jobs, state, fn {token, job}, state ->
        if job.socket_monitor == monitor and not job.notification_only? do
          Runtime.cancel_scope(state.runtime, job.scope)
          HTTPWriterRegistry.retire(job.binding, :writer_down)
          state = put_in(state.jobs[token].socket_down?, true)
          finish(token, state)
        else
          state
        end
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:establish_session_stream, binding}, {writer, _tag}, state) do
    reply =
      with {:ok, setup} <- HTTPWriterRegistry.session_stream_setup(binding),
           true <- setup.runtime == state.runtime and setup.writer == writer,
           {:ok, service} <- Runtime.service(state.runtime, :sessions),
           {:ok, row} <-
             SessionManager.get_session(service, setup.lease, deadline: setup.deadline),
           true <- row.metadata[:transport_endpoint] == setup.endpoint,
           do: HTTPWriterRegistry.establish_session_stream(binding, row.expires_at),
           else: (_invalid -> {:error, :invalid_http_session_stream})

    {:reply, reply, state}
  end

  defp retire_replaced_cancellation(token, %{cancelling?: true} = job, state) do
    case Admission.current(state.table, token) do
      {:ok, reservation} ->
        if reservation.generation != job.cancellation_generation or
             reservation.output_phase != job.cancellation_phase do
          state
          |> put_in([:jobs, token, :cancelling?], false)
          |> put_in([:jobs, token, :done?], true)
        else
          state
        end

      {:error, :admission_lost} ->
        state
        |> put_in([:jobs, token, :cancelling?], false)
        |> put_in([:jobs, token, :done?], true)
    end
  end

  defp retire_replaced_cancellation(_token, _job, state), do: state

  defp accept(token, message, retained, state) do
    batch? = is_list(message)

    job =
      retained
      |> Map.delete(:lifecycle_metadata_reserve)
      |> Map.merge(%{
        notification_only?: notification_only?(message) or response_only?(message),
        response_loans: %{},
        batch?: batch?,
        remaining: if(batch?, do: message, else: [message]),
        output?: false,
        bound?: false,
        done?: false,
        failed?: false,
        initializing?: false,
        cancelling?: false,
        cancellation_phase: nil,
        cancellation_generation: nil,
        observation: nil,
        socket_monitor: Process.monitor(retained.socket),
        socket_down?: false
      })

    state = put_in(state.jobs[token], job)
    advance(token, state)
  end

  defp accept_preflight(token, reservation, responses, retained, reply, state) do
    with {:ok, proof} <- HTTPWriterBinding.validate(retained.binding, state.runtime),
         true <- proof.owner == reservation.caller and retained.socket == proof.owner,
         true <- proof.scope == reservation.scope and proof.lease == retained.lease,
         true <- proof.generation == reservation.generation and reservation.owner == self(),
         true <- reservation.kind == :edge_response and proof.deadline > Deadline.now() do
      job =
        retained
        |> Map.delete(:lifecycle_metadata_reserve)
        |> Map.merge(%{
          notification_only?: true,
          response_loans: %{},
          batch?: true,
          remaining: [],
          output?: false,
          bound?: false,
          done?: true,
          failed?: false,
          initializing?: false,
          cancelling?: false,
          cancellation_phase: nil,
          cancellation_generation: nil,
          observation: nil,
          socket_monitor: Process.monitor(retained.socket),
          socket_down?: false
        })

      {reverse, loans} =
        Enum.reduce(responses, {state.reverse, %{}}, fn response, {reverse, loans} ->
          {reverse, loan} = HTTPReverse.respond(reverse, token, job, response)
          {reverse, if(loan, do: Map.put(loans, loan, true), else: loans)}
        end)

      state = %{state | reverse: reverse}
      state = put_in(state.jobs[token], %{job | response_loans: loans})
      Admission.complete_output_phase(state.table, token)
      Admission.terminal(state.table, token, :notification)
      send(reply, {:http_reverse_preflight, token, {:accepted, map_size(loans)}})
      finish(token, state)
    else
      _invalid ->
        Admission.terminal(state.table, token, {:error, :http_preflight_retired})
        Admission.release(state.table, token)
        state
    end
  end

  defp advance(token, state) do
    case state.jobs[token] do
      %{done?: true} ->
        finish(token, state)

      %{failed?: true} ->
        state

      %{remaining: []} = job ->
        if job.batch? and job.output? do
          case OutputController.finish(state.table, token) do
            :ok -> capture_observation(token, state)
            {:error, reason} -> fail(token, reason, state)
          end
        else
          finish(token, state)
        end

      %{remaining: [request | rest]} = job ->
        state = put_in(state.jobs[token].remaining, rest)

        state =
          put_in(state.jobs[token].initializing?, match?(%{"method" => "initialize"}, request))

        dispatch(token, request, job, state)

      nil ->
        state
    end
  end

  defp output_http(state, %{format: :legacy_sse} = job, token) do
    session =
      case Runtime.service(state.runtime, :sessions) do
        {:ok, service} -> %{service: service, lease: job.lease}
        _unavailable -> nil
      end

    %{binding: job.binding, format: job.format, source: token, session: session}
  end

  defp output_http(_state, job, _token), do: %{binding: job.binding, format: job.format}

  defp dispatch(token, request, job, state) do
    cond do
      response_member?(request) -> dispatch_response(token, request, job, state)
      valid_envelope?(request) -> dispatch_valid(token, request, job, state)
      true -> invalid_member(token, job, state)
    end
  end

  defp dispatch_response(token, response, job, state) do
    with {:ok, reservation} <-
           Admission.promote(state.table, token, response, kind: :edge_response),
         :ok <- bind(job, token, reservation, state) do
      {reverse, loan} = HTTPReverse.respond(state.reverse, token, job, response)
      loans = if loan, do: Map.put(job.response_loans, loan, true), else: job.response_loans
      state = %{state | reverse: reverse}
      state = put_in(state.jobs[token].response_loans, loans)
      state = put_in(state.jobs[token].bound?, true)

      # Every accepted response is an entered effect. In a response-only array,
      # finish all original-order loans before allowing its socket to return202.
      case publish_response_acceptance(state.jobs[token]) do
        :ok ->
          Admission.terminal(state.table, token, :notification)
          Admission.release_step(state.table, token)
          state

        {:error, reason} ->
          fail(token, reason, state)
      end
    else
      {:error, reason} -> fail(token, reason, state)
    end
  end

  defp publish_response_acceptance(%{remaining: []} = job), do: publish_acceptance(job)
  defp publish_response_acceptance(_job), do: :ok

  defp valid_envelope?(%{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    not Map.has_key?(request, "result") and not Map.has_key?(request, "error") and
      (not Map.has_key?(request, "id") or is_binary(request["id"]) or is_integer(request["id"]))
  end

  defp valid_envelope?(_invalid), do: false

  defp invalid_member(token, job, state) do
    invalid = %{"jsonrpc" => "2.0", "id" => nil, "method" => "__invalid_http_request"}

    output = %{
      edge: self(),
      connection: job.binding,
      batch?: job.batch?,
      http: output_http(state, job, token)
    }

    with {:ok, reservation} <- Admission.promote(state.table, token, invalid, kind: :rpc),
         :ok <- bind(job, token, reservation, state),
         :ok <-
           OutputController.edge_result(
             state.table,
             token,
             output,
             Arbor.RPC.JSONRPC.error(nil, -32600, "Invalid Request")
           ) do
      state = put_in(state.jobs[token].bound?, true)
      state = put_in(state.jobs[token].output?, true)
      if job.batch?, do: advance(token, state), else: state
    else
      {:error, reason} -> fail(token, reason, state)
    end
  end

  defp dispatch_valid(token, request, job, state) do
    output = %{
      edge: self(),
      connection: job.binding,
      batch?: job.batch?,
      http: output_http(state, job, token)
    }

    with {:ok, reservation} <- Admission.promote(state.table, token, request, kind: :rpc),
         :ok <-
           HTTPCancellation.register(
             state.runtime,
             token,
             job.lease,
             job.identity,
             job.dispatch_opts[:http_endpoint] || job.dispatch_opts[:endpoint] || "/mcp"
           ),
         :ok <- uncancelled_member(state.table, token, request),
         :ok <- bind(job, token, reservation, state),
         :ok <- publish_acceptance(job),
         {:ok, route} <- Admission.route(state.table) do
      work_opts = [
        runtime: state.runtime,
        dispatch_opts: job.dispatch_opts,
        output: output,
        retain_reservation: true
      ]

      state = put_in(state.jobs[token].bound?, true)
      state = put_in(state.jobs[token].acceptance, nil)

      if HTTPCancellation.cancelled_member?(state.table, token, request["id"]) do
        fail(token, :request_cancelled, state)
      else
        dispatch_or_cancel(token, request, route, work_opts, state)
      end
    else
      {:error, reason} -> fail(token, reason, state)
    end
  end

  defp uncancelled_member(table, token, request) do
    if HTTPCancellation.cancelled_member?(table, token, request["id"]),
      do: {:error, :request_cancelled},
      else: :ok
  end

  defp dispatch_or_cancel(
         token,
         %{"method" => "subscriptions/listen"} = request,
         _route,
         work_opts,
         state
       ) do
    job = state.jobs[token]
    endpoint = job.dispatch_opts[:http_endpoint] || job.dispatch_opts[:endpoint] || "/mcp"

    with false <- job.batch?,
         {:ok, context} <- RequestContext.from_message(request),
         :modern <- context.era,
         :ok <- RequestContext.validate_protocol_mode(context, job.dispatch_opts[:protocol_mode]),
         :ok <- RequestContext.validate_method(context),
         {:ok, listener} <-
           HTTPWriterRegistry.establish_listener(job.binding, token,
             endpoint: endpoint,
             identity: job.identity
           ),
         {:ok, entry} <-
           Subscriptions.listen_http(
             listener,
             request["id"],
             get_in(request, ["params", "notifications"]),
             job.dispatch_opts
             |> Enum.reject(fn {_key, value} -> is_nil(value) end)
             |> Subscriptions.runtime_options()
             |> Keyword.put(:audience, job.dispatch_opts[:endpoint] || "/mcp")
             |> Keyword.update(:authorization_required, false, &(&1 or not is_nil(job.identity)))
             |> Keyword.put(:client_capabilities, context.client_capabilities)
           ),
         :ok <- attach_subscription(listener, entry) do
      Admission.complete_output_phase(state.table, token)
      Admission.terminal(state.table, token, {:ok, :subscription})
      finish(token, state)
    else
      invalid ->
        HTTPWriterRegistry.reject_listener_setup(job.binding, token)
        output = Keyword.fetch!(work_opts, :output)
        response = subscription_error(request["id"], invalid)

        case OutputController.edge_result(state.table, token, output, response) do
          :ok -> put_in(state.jobs[token].output?, true)
          {:error, reason} -> fail(token, reason, state)
        end
    end
  end

  defp dispatch_or_cancel(
         token,
         %{"method" => "notifications/cancelled", "params" => %{"requestId" => id}} = request,
         route,
         work_opts,
         state
       )
       when not is_map_key(request, "id") do
    case MessageValidator.validate_method_params(
           "notifications/cancelled",
           request["params"]
         ) do
      :ok ->
        case HTTPCancellation.request(state.table, token, id) do
          {:ok, generation, phase} ->
            send(route.scheduler, {:http_cancel, generation, token, phase})
            state = put_in(state.jobs[token].cancelling?, true)
            state = put_in(state.jobs[token].cancellation_generation, generation)
            put_in(state.jobs[token].cancellation_phase, phase)

          _invalid ->
            Admission.terminal(state.table, token, :notification)
            Admission.release_step(state.table, token)
            state
        end

      _invalid ->
        send(route.scheduler, {:submit, route.generation, token, request, work_opts})
        state
    end
  end

  defp dispatch_or_cancel(token, request, route, work_opts, state) do
    send(route.scheduler, {:submit, route.generation, token, request, work_opts})
    state
  end

  defp subscription_error(id, {:error, %Arbor.MCP.Error.ProtocolError{} = error}),
    do: Arbor.RPC.JSONRPC.error(id, error.code, error.message, error.data)

  # Only these fixed parser reason codes are public; custom authorizer failures stay opaque.
  defp subscription_error(id, {:error, :unknown_subscription_filter}),
    do:
      Arbor.RPC.JSONRPC.error(id, -32602, "Invalid subscription request", %{
        "reason" => "unknown_subscription_filter"
      })

  defp subscription_error(id, {:error, :invalid_subscription_filter}),
    do:
      Arbor.RPC.JSONRPC.error(id, -32602, "Invalid subscription request", %{
        "reason" => "invalid_subscription_filter"
      })

  defp subscription_error(id, {:error, :subscription_filter_required}),
    do:
      Arbor.RPC.JSONRPC.error(id, -32602, "Invalid subscription request", %{
        "reason" => "subscription_filter_required"
      })

  defp subscription_error(id, _invalid),
    do: Arbor.RPC.JSONRPC.error(id, -32602, "Invalid subscription request")

  defp attach_subscription(binding, entry) do
    case HTTPWriterRegistry.attach_listener(
           binding,
           entry.listener_pid,
           entry.token,
           entry.subscription_id
         ) do
      :ok ->
        :ok

      error ->
        SubscriptionListener.cancel(entry.listener_pid)
        error
    end
  end

  defp publish_acceptance(%{acceptance: nil}), do: :ok

  defp publish_acceptance(%{acceptance: ticket}) do
    with :ok <- HTTPWriterRegistry.handoff(ticket), do: HTTPWriterRegistry.publish(ticket)
  end

  # Acceptance is a single charged socket effect. After its first member has
  # been bound, a notification-only envelope belongs to this Gateway through
  # its original reservation lifetime, even after the socket has returned 202.
  defp bind(%{notification_only?: true, bound?: true, scope: scope}, token, reservation, state) do
    with {:ok, route} <- Admission.route(state.table),
         true <- reservation.token == token and reservation.owner == self(),
         true <- reservation.scope == scope and reservation.generation == route.generation,
         true <- reservation.deadline > System.monotonic_time(:millisecond),
         true <- :ets.lookup(state.table, :http_gateway) == [{:http_gateway, self()}] do
      :ok
    else
      _retired -> {:error, :invalid_http_work_origin}
    end
  end

  defp bind(%{batch?: true, bound?: true, binding: binding}, _token, _reservation, state) do
    case HTTPWriterBinding.validate(binding, state.runtime) do
      {:ok, _proof} -> :ok
      error -> error
    end
  end

  defp bind(%{binding: binding}, token, _reservation, _state),
    do: HTTPWriterRegistry.bind_dispatched(binding, token)

  defp fail(token, reason, state) do
    case state.jobs[token] do
      %{binding: binding} ->
        case HTTPWriterRegistry.in_flight_observation(binding) do
          {:ok, observation} ->
            state
            |> put_in([:jobs, token, :observation], observation)
            |> put_in([:jobs, token, :failed?], true)
            |> put_in([:jobs, token, :done?], true)

          _not_writing ->
            fail_work(token, reason, state)
        end

      _missing ->
        fail_work(token, reason, state)
    end
  end

  defp fail_work(token, reason, state) do
    case state.jobs[token] do
      %{failed?: true} ->
        state

      %{notification_only?: true} ->
        finish(token, state)

      %{binding: binding, format: format} ->
        OutputController.mark_failure(state.table, token, safe_failure(reason))

        case OutputController.http_failure(state.table, token, binding, format) do
          :ok ->
            capture_observation(token, put_in(state.jobs[token].failed?, true))

          _unavailable ->
            OutputController.retire(state.table, token, :http_invocation_failed)
            HTTPWriterRegistry.retire(binding, :http_invocation_failed)
            finish(token, state)
        end

      _missing ->
        finish(token, state)
    end
  end

  defp safe_failure(reason) when reason in [:handler_timeout, :request_cancelled], do: reason
  defp safe_failure(_reason), do: :http_invocation_failed

  defp finish(token, state) do
    case state.jobs[token] do
      %{response_loans: loans} when map_size(loans) > 0 ->
        put_in(state.jobs[token].done?, true)

      %{cancelling?: true} ->
        # The token-only Scheduler control is still queued. Retain its permit
        # until the matching ACK or this Gateway's death, even after expiry.
        state

      %{observation: observation} when not is_nil(observation) ->
        if HTTPWriteTicket.observation_status(observation) in [:pending, :in_flight],
          do: put_in(state.jobs[token].done?, true),
          else: finish_work(token, state)

      _missing ->
        finish_work(token, state)
    end
  end

  defp settle_reverse(state) do
    {reverse, settled} = HTTPReverse.reap(state.reverse)
    state = %{state | reverse: reverse}

    Enum.reduce(settled, state, fn {response_token, control_token}, state ->
      case state.jobs[response_token] do
        %{response_loans: loans} ->
          state =
            put_in(state.jobs[response_token].response_loans, Map.delete(loans, control_token))

          if state.jobs[response_token].done?, do: finish(response_token, state), else: state

        nil ->
          state
      end
    end)
  end

  defp finish_work(token, state) do
    case Admission.current(state.table, token) do
      {:ok, %{bound: true}} ->
        if state.jobs[token], do: put_in(state.jobs[token].done?, true), else: state

      _settled ->
        HTTPCancellation.retire(state.table, token)
        if job = state.jobs[token], do: Process.demonitor(job.socket_monitor, [:flush])
        :ets.delete(state.table, {:output_failure, token})
        :ets.delete(state.table, {:output_commit, token})
        Admission.release(state.table, token)
        %{state | jobs: Map.delete(state.jobs, token)}
    end
  end

  defp wire_ids(message) do
    message
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id, "method" => method}
      when (is_binary(id) or is_integer(id)) and is_binary(method) ->
        if :erlang.external_size(id) <= 4_000, do: [id], else: []

      _invalid ->
        []
    end)
    |> Enum.uniq()
  end

  defp uncancellable_ids(message) do
    for %{"id" => id, "method" => "initialize"} <- List.wrap(message),
        (is_binary(id) or is_integer(id)) and :erlang.external_size(id) <= 4_000,
        do: id
  end

  defp capture_observation(token, state) do
    case OutputController.http_observation(state.table, token) do
      {:ok, observation} -> put_in(state.jobs[token].observation, observation)
      _settled -> finish(token, state)
    end
  end
end
