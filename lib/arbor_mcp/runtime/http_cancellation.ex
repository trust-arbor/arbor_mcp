defmodule Arbor.MCP.Server.Runtime.HTTPCancellation do
  @moduledoc false
  alias Arbor.MCP.Server.RequestContext
  alias Arbor.MCP.Server.Runtime.{Admission, Deadline, Ref, ServiceRef}
  alias Arbor.MCP.SessionManager.SessionLease

  def identity(opts, request, nil) do
    with {:ok, context} <- RequestContext.from_message(request),
         true <- context.era == :modern or (context.era == :unknown and not context.request?),
         principal when is_binary(principal) and byte_size(principal) > 0 <- opts[:principal_id],
         endpoint when is_binary(endpoint) <- opts[:http_endpoint] || opts[:endpoint],
         tenant when is_binary(tenant) or is_nil(tenant) <- opts[:tenant_id] do
      {endpoint, principal, tenant}
    else
      _uncorrelated -> nil
    end
  end

  def identity(_opts, _request, _session_lease), do: nil

  # One payload-free origin row per admitted envelope. Its term cost is
  # precharged in the Gateway ingress metadata reservation, and the same
  # owner removes it when that envelope settles. No per-target mailbox queue.
  def register(runtime, token, lease, identity, endpoint \\ "/mcp") do
    table = Ref.table(runtime)

    with [{:http_gateway, owner}] when owner == self() <- :ets.lookup(table, :http_gateway),
         {:ok, reservation} <- Admission.current(table, token),
         true <- reservation.owner == self() and reservation.deadline > Deadline.now(),
         true <- is_binary(endpoint) and byte_size(endpoint) in 1..4_096 do
      entry = %{
        runtime: runtime,
        lease: lease,
        identity: identity,
        endpoint: :binary.copy(endpoint),
        generation: reservation.generation,
        owner: self(),
        scope: reservation.scope,
        phase: reservation.output_phase,
        deadline: reservation.deadline,
        cancellation: nil
      }

      :ets.insert(table, {{:http_session_origin, token}, entry})
      :ok
    else
      _retired -> {:error, :invalid_http_work_origin}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def request(table, token, id) do
    with true <- valid_id?(id),
         [{_key, %{owner: owner, cancellation: nil} = entry}] when owner == self() <-
           :ets.lookup(table, {:http_session_origin, token}),
         true <- live_source?(table, token, entry) do
      id = if(is_binary(id), do: :binary.copy(id), else: id)
      :ets.insert(table, {{:http_session_origin, token}, %{entry | cancellation: {:pending, id}}})
      {:ok, entry.generation, entry.phase}
    else
      _invalid -> {:error, :invalid_http_cancellation}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def take(table, token, generation, phase) do
    with [{_key, %{generation: ^generation, phase: ^phase, cancellation: {:pending, id}} = entry}] <-
           :ets.lookup(table, {:http_session_origin, token}),
         true <- current_owner?(table, token, entry) do
      :ets.insert(
        table,
        {{:http_session_origin, token}, %{entry | cancellation: {:consumed, id}}}
      )

      source = Map.merge(entry, %{token: token, id: id})
      if live_source?(table, token, entry), do: {:ok, source}, else: {:expired, source}
    else
      _retired -> {:error, :http_cancellation_retired}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def consumed_source(table, token, generation, phase) do
    with [
           {_key,
            %{generation: ^generation, phase: ^phase, cancellation: {:consumed, id}} = entry}
         ] <-
           :ets.lookup(table, {:http_session_origin, token}),
         true <- current_owner?(table, token, entry) do
      {:ok, Map.merge(entry, %{token: token, id: id})}
    else
      _retired -> {:error, :http_cancellation_retired}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def complete(table, token, generation, phase) do
    with {:ok, source} <- consumed_source(table, token, generation, phase) do
      entry = Map.drop(source, [:token, :id])
      :ets.insert(table, {{:http_session_origin, token}, %{entry | cancellation: :completed}})
      {:ok, source}
    end
  end

  def future_target?(table, source, reservation) do
    with true <- live_source?(table, source.token, source),
         true <- source.id in reservation.wire_ids,
         true <- source.id not in reservation.uncancellable_ids,
         true <- future_or_unbound?(reservation, source.id),
         [{_key, target}] <- :ets.lookup(table, {:http_session_origin, reservation.token}),
         true <- target.owner == source.owner and target.generation == source.generation,
         true <- target.scope == reservation.scope and target_phase?(target, reservation),
         true <- correlated?(source, target),
         {:ok, current} <- Admission.current(table, reservation.token),
         true <-
           current.output_phase == reservation.output_phase and current.key == reservation.key,
         true <- current.generation == source.generation and current.owner == source.owner,
         true <- source.id in current.wire_ids and future_or_unbound?(current, source.id),
         true <- current.deadline > Deadline.now(),
         true <- live_source?(table, source.token, source) do
      true
    else
      _unmatched -> false
    end
  rescue
    ArgumentError -> false
  end

  defp future_or_unbound?(reservation, id),
    do: id !== reservation.request_id or unbound_member?(reservation)

  defp unbound_member?(reservation) do
    not reservation.bound and not reservation.terminal and
      reservation.stage in [:processing, :holding] and
      :atomics.get(reservation.output_phase, 1) == 1
  end

  defp target_phase?(target, reservation) do
    (target.phase == reservation.output_phase and :atomics.get(target.phase, 1) in [1, 2]) or
      (reservation.stage == :holding and unbound_member?(reservation) and
         :atomics.get(target.phase, 1) == 2)
  end

  def marker_metadata_bytes(runtime, scope, lease, identity, ids) do
    # One receipt per remaining wire ID, including its ETS key and native
    # fixed-size owner/phase/generation/deadline fields, plus a retained ID
    # key. This is additional to the original reservation options charge.
    Enum.reduce(ids, 0, fn id, bytes ->
      bytes + 512 + :erlang.external_size({runtime, scope, lease, identity, id})
    end)
  end

  def mark_future(table, source, reservation) do
    with {:ok, %{admission: admission}} <- Admission.route(table),
         true <- admission == self(),
         true <- future_target?(table, source, reservation) do
      key = {:http_wire_cancel, reservation.token, source.id}

      receipt = %{
        runtime: source.runtime,
        owner: source.owner,
        generation: source.generation,
        scope: reservation.scope,
        source_token: source.token,
        source_phase: source.phase,
        deadline: min(source.deadline, reservation.deadline),
        lease: source.lease,
        identity: source.identity
      }

      # Repeated admitted controls coalesce without renewing the first
      # receipt's immutable cutoff or accumulating per-ID payload rows.
      :ets.insert_new(table, {key, receipt})
      :ok
    else
      _retired -> {:error, :http_cancellation_retired}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def cancelled_member?(table, token, id) do
    case :ets.lookup(table, {:http_wire_cancel, token, id}) do
      [{_key, receipt}] ->
        if marker_current?(table, token, id, receipt) do
          true
        else
          :ets.delete(table, {:http_wire_cancel, token, id})
          false
        end

      [] ->
        :ets.member(table, {:wire_cancel, token, id})
    end
  rescue
    ArgumentError -> false
  end

  defp marker_current?(table, token, id, %{owner: owner} = receipt) do
    with true <- receipt.deadline > Deadline.now(),
         true <- :atomics.get(receipt.source_phase, 1) in [1, 2],
         true <- Process.alive?(owner),
         true <- Ref.table(receipt.runtime) == table,
         [{:http_gateway, ^owner}] <- :ets.lookup(table, :http_gateway),
         {:ok, route} <- Admission.route(table),
         true <- route.generation == receipt.generation,
         {:ok, reservation} <- Admission.current(table, token),
         true <- reservation.owner == owner and reservation.generation == receipt.generation,
         true <- reservation.scope == receipt.scope and reservation.deadline > Deadline.now(),
         true <- id in reservation.wire_ids and id not in reservation.uncancellable_ids,
         [{_key, target}] <- :ets.lookup(table, {:http_session_origin, token}),
         true <- target.owner == owner and target.generation == receipt.generation,
         true <- target.scope == receipt.scope and :atomics.get(target.phase, 1) in [1, 2],
         true <- correlated?(receipt, target),
         true <- receipt.deadline > Deadline.now() do
      true
    else
      _retired -> false
    end
  end

  def target?(table, source, reservation) do
    with true <- live_source?(table, source.token, source),
         true <- reservation.request_id === source.id,
         true <- source.id not in reservation.uncancellable_ids,
         true <- not reservation.terminal,
         [{_key, target}] <- :ets.lookup(table, {:http_session_origin, reservation.token}),
         true <- target.owner == source.owner and target.generation == source.generation,
         true <- target.scope == reservation.scope and target.phase == reservation.output_phase,
         true <- correlated?(source, target),
         {:ok, current} <- Admission.current(table, reservation.token),
         true <- current.output_phase == target.phase and current.key == reservation.key,
         true <- current.generation == source.generation and current.owner == source.owner,
         true <- not current.terminal and current.deadline > Deadline.now(),
         true <- live_source?(table, source.token, source) do
      true
    else
      _unmatched -> false
    end
  rescue
    ArgumentError -> false
  end

  def retire(table, token), do: :ets.delete(table, {:http_session_origin, token})

  defp session_key(origin),
    do: SessionLease.validate(origin.lease, ServiceRef.new(origin.runtime, :sessions), :sessions)

  defp correlated?(%{lease: nil, identity: identity}, %{lease: nil, identity: identity})
       when not is_nil(identity) do
    true
  end

  defp correlated?(%{lease: nil}, _target), do: false
  defp correlated?(_source, %{lease: nil}), do: false

  defp correlated?(source, target) do
    with {:ok, key} <- session_key(source),
         {:ok, ^key} <- session_key(target),
         do: true,
         else: (_unmatched -> false)
  end

  defp live_source?(table, token, origin) do
    with true <- origin.deadline > Deadline.now(),
         true <- current_owner?(table, token, origin),
         {:ok, reservation} <- Admission.current(table, token) do
      not reservation.terminal
    else
      _retired -> false
    end
  end

  defp current_owner?(table, token, origin) do
    with true <- Process.alive?(origin.owner),
         [{:http_gateway, owner}] when owner == origin.owner <- :ets.lookup(table, :http_gateway),
         {:ok, reservation} <- Admission.current(table, token) do
      reservation.generation == origin.generation and reservation.owner == origin.owner and
        reservation.scope == origin.scope and reservation.output_phase == origin.phase
    else
      _retired -> false
    end
  end

  defp valid_id?(id),
    do: (is_binary(id) or is_integer(id)) and :erlang.external_size(id) <= 4_000
end
