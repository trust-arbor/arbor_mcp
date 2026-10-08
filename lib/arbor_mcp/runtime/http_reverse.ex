defmodule Arbor.MCP.Server.Runtime.HTTPReverse do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPNotifications,
    HTTPResponseLoans,
    OutputCodec
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source

  @max_wait 4_294_967_295

  def init(table) do
    %{table: table, pending: %{}}
  end

  def accept(state, token, control, reservation) do
    with {:ok, source} <- Source.gateway_snapshot(control.source),
         true <- reservation.kind == :edge_control and reservation.owner == self(),
         true <- reservation.caller == source.producer and reservation.edge == self(),
         true <- reservation.scope == source.scope,
         true <- reservation.generation == source.generation,
         true <-
           reservation.deadline <= source.deadline and control.deadline == reservation.deadline,
         true <- reservation.deadline > Deadline.now() do
      phase = :atomics.new(1, signed: false)

      pending = %{
        source: control.source,
        id: control.request["id"],
        producer: source.producer,
        deadline: reservation.deadline,
        reply: control.reply,
        monitor: Process.monitor(source.producer),
        phase: phase,
        response_token: nil
      }

      send(control.reply, {:http_reverse, token, :registered})
      %{state | pending: Map.put(state.pending, token, pending)}
    else
      _invalid ->
        Admission.terminal(state.table, token, {:error, :reverse_request_retired})
        Admission.release(state.table, token)
        state
    end
  end

  # The complete response remains charged to its existing input reservation.
  # The socket never sends its result to a callback mailbox. A token-only wake
  # lets the original Task take exactly one protected ETS loan instead.
  def respond(state, response_token, job, response) do
    found =
      Enum.find(state.pending, fn {_token, pending} ->
        pending.id == response["id"] and pending.response_token == nil and
          pending.deadline > Deadline.now() and :atomics.get(pending.phase, 1) == 0 and
          response_target?(pending, job)
      end)

    case found do
      {token, pending} -> adopt_response(state, response_token, token, pending, job, response)
      nil -> {state, nil}
    end
  end

  defp adopt_response(state, response_token, token, pending, job, response) do
    case OutputCodec.prepare(response,
           codec: :protocol,
           deadline: pending.deadline,
           max_frame_bytes: 65_536,
           max_term_bytes: 65_536
         ) do
      {:ok, prepared} ->
        response = Jason.decode!(prepared.wire)

        result =
          if Map.has_key?(response, "result"),
            do: {:ok, response["result"]},
            else: {:error, response["error"]}

        candidate = %{
          source: pending.source,
          producer: pending.producer,
          phase: pending.phase,
          deadline: pending.deadline,
          result: result,
          binding: job.binding,
          endpoint: job.dispatch_opts[:http_endpoint] || job.dispatch_opts[:endpoint]
        }

        key = {:http_response_candidate, response_token, token}
        digest = :crypto.hash(:sha256, :erlang.term_to_binary(candidate))
        :ets.insert(state.table, {key, candidate})

        case Admission.adopt_http_response(
               state.table,
               response_token,
               token,
               digest,
               pending.deadline
             ) do
          :ok ->
            pending = %{pending | response_token: response_token}
            send(pending.reply, {:http_reverse, token, :result_ready})
            {%{state | pending: Map.put(state.pending, token, pending)}, token}

          _retired ->
            :ets.delete(state.table, key)
            {state, nil}
        end

      _invalid ->
        {state, nil}
    end
  end

  defp response_target?(pending, job) do
    with {:ok, source} <- Source.gateway_snapshot(pending.source),
         true <- job.lease == source.lease,
         true <-
           (job.dispatch_opts[:http_endpoint] || job.dispatch_opts[:endpoint]) == source.endpoint,
         do: true,
         else: (_retired -> false)
  end

  def reap(state) do
    Enum.reduce(state.pending, {state, []}, fn {token, pending}, {state, settled} ->
      status = :atomics.get(pending.phase, 1)

      expired =
        pending.deadline <= Deadline.now() or
          not match?({:ok, _}, Source.gateway_snapshot(pending.source))

      cond do
        status in [2, 3] or not Process.alive?(pending.producer) ->
          retire(state, token, pending, settled)

        status == 0 and expired ->
          if :atomics.compare_exchange(pending.phase, 1, 0, 3) == :ok,
            do: retire(state, token, pending, settled),
            else: {state, settled}

        true ->
          # A checked-out result remains a charged Task liability through its
          # actual acknowledgement or death, including deadline/generation loss.
          {state, settled}
      end
    end)
  end

  defp retire(state, token, pending, settled) do
    Process.demonitor(pending.monitor, [:flush])
    Admission.terminal(state.table, token, {:error, :reverse_request_retired})
    Admission.release(state.table, token)

    settled =
      if pending.response_token, do: [{pending.response_token, token} | settled], else: settled

    {%{state | pending: Map.delete(state.pending, token)}, settled}
  end

  # The callback Task owns the durable request append and the result checkout.
  # Gateway control messages and alias wakes carry tokens only.
  def call(server, :get_pending_requests, _timeout) do
    with {:ok, source} <- Source.capture(),
         {:ok, runtime} <- Runtime.ref(server),
         true <- runtime == Source.runtime(source),
         {:ok, snapshot} <- Source.producer_snapshot(source) do
      table = Arbor.MCP.Server.Runtime.Ref.table(runtime)

      for {{:wire_request, scope, id, token}, _active} <- :ets.tab2list(table),
          {:ok, reservation} <- [Admission.current(table, token)],
          not reservation.terminal and reservation.generation == snapshot.generation,
          [{_key, origin}] <- [:ets.lookup(table, {:http_session_origin, token})],
          origin.owner == snapshot.gateway and origin.endpoint == snapshot.endpoint,
          origin.lease == snapshot.lease,
          not is_nil(snapshot.lease) or scope == snapshot.scope,
          uniq: true,
          do: id
    else
      {:error, reason} when reason in [:not_http_request, :no_request_context] ->
        :not_http_request

      false ->
        {:error, :wrong_runtime}

      error ->
        error
    end
  end

  def call(server, control, timeout) do
    with {:ok, source} <- Source.capture(),
         {:ok, runtime} <- Runtime.ref(server),
         true <- runtime == Source.runtime(source),
         {:ok, snapshot} <- Source.producer_snapshot(source),
         false <- is_nil(snapshot.lease),
         %{era: :legacy} <- Context.current(),
         {:ok, deadline} <- cutoff(snapshot.deadline, timeout),
         {:ok, method, params} <- request(control, deadline),
         {:ok, prepared} <-
           OutputCodec.prepare(
             %{
               "jsonrpc" => "2.0",
               "id" => System.unique_integer([:positive]),
               "method" => method,
               "params" => params
             },
             codec: :protocol,
             deadline: deadline,
             max_frame_bytes: 65_536,
             max_term_bytes: 65_536
           ) do
      invoke(runtime, source, snapshot, prepared.term, deadline)
    else
      {:error, reason} when reason in [:not_http_request, :no_request_context] ->
        :not_http_request

      false ->
        {:error, :wrong_runtime}

      true ->
        {:error, :reverse_requests_unavailable}

      {:error, _reason} = error ->
        error

      _modern ->
        {:error, :reverse_requests_unavailable}
    end
  end

  defp request(:ping, _deadline), do: {:ok, "ping", %{}}
  defp request({:list_roots, _timeout}, _deadline), do: {:ok, "roots/list", %{}}
  defp request(:list_roots, _deadline), do: {:ok, "roots/list", %{}}

  defp request({:create_message, params}, _deadline) when is_map(params),
    do: {:ok, "sampling/createMessage", params}

  defp request({:elicit, params, _timeout}, deadline) do
    with {:ok, normalized} <- Arbor.MCP.Protocol.Elicitation.validate(params, deadline),
         do: {:ok, "elicitation/create", normalized}
  end

  defp request(_control, _deadline), do: {:error, :unsupported_http_reverse_control}

  defp cutoff(original, :infinity), do: {:ok, original}

  defp cutoff(original, timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_wait do
    deadline = min(original, Deadline.now() + timeout)
    if deadline > Deadline.now(), do: {:ok, deadline}, else: {:error, :timeout}
  end

  defp cutoff(_original, _timeout), do: {:error, :invalid_reverse_timeout}

  defp invoke(runtime, source, snapshot, request, deadline) do
    reply = :erlang.alias()
    monitor = Process.monitor(snapshot.gateway)
    control = %{source: source, deadline: deadline, request: request, reply: reply}
    origin = Map.take(snapshot, [:token, :scope, :generation])

    try do
      with {:ok, route, reservation} <-
             RuntimeIngress.reserve_ingress(runtime, request,
               kind: :edge_control,
               direction: :outbound,
               owner: snapshot.gateway,
               caller: self(),
               edge: snapshot.gateway,
               reply_to: reply,
               scope: snapshot.scope,
               origin: origin,
               admission_deadline: deadline,
               invocation_deadline: deadline,
               dispatch_opts: [
                 http_reverse: source,
                 lifecycle_metadata_reserve:
                   :binary.copy(<<0>>, 2_048 + 2 * :erlang.external_size(control))
               ]
             ),
           :ok <-
             RuntimeIngress.publish_ingress(
               runtime,
               route,
               reservation,
               {:http_reverse, control},
               snapshot.gateway
             ) do
        try do
          with :ok <- registered(reservation.token, monitor, deadline),
               :ok <- HTTPNotifications.append(source, request),
               :ok <- result_ready(reservation.token, monitor, deadline),
               {:ok, result} <- checkout(runtime, reservation.token, source, deadline) do
            result
          end
        after
          acknowledge(runtime, reservation.token)
        end
      end
    after
      :erlang.unalias(reply)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp registered(token, monitor, deadline), do: await(token, monitor, deadline, :registered)
  defp result_ready(token, monitor, deadline), do: await(token, monitor, deadline, :result_ready)

  defp await(token, monitor, deadline, expected) do
    if Deadline.remaining(deadline) == 0 do
      {:error, :timeout}
    else
      receive do
        {:http_reverse, ^token, ^expected} ->
          if Deadline.remaining(deadline) > 0, do: :ok, else: {:error, :timeout}

        {:arbor_mcp_runtime, ^token, _terminal} ->
          if Deadline.remaining(deadline) == 0,
            do: {:error, :timeout},
            else: {:error, :reverse_request_retired}

        {:DOWN, ^monitor, :process, _gateway, _reason} ->
          {:error, :http_gateway_unavailable}
      after
        Deadline.remaining(deadline) -> {:error, :timeout}
      end
    end
  end

  defp checkout(runtime, token, source, deadline),
    do: HTTPResponseLoans.checkout(runtime, token, source, deadline)

  defp acknowledge(runtime, token), do: HTTPResponseLoans.acknowledge(runtime, token)
end
