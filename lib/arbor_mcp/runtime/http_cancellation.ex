defmodule Arbor.MCP.Server.Runtime.HTTPCancellation do
  @moduledoc false
  alias Arbor.MCP.Server.RequestContext
  alias Arbor.MCP.Server.Runtime.{Admission, Deadline, Ref, ServiceRef}
  alias Arbor.MCP.SessionManager.SessionLease

  def identity(opts, request, nil) do
    with {:ok, context} <- RequestContext.from_message(request),
         true <- context.era == :modern or (context.era == :unknown and not context.request?),
         principal when is_binary(principal) and byte_size(principal) > 0 <- opts[:principal_id],
         endpoint when is_binary(endpoint) <- opts[:endpoint],
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
  def register(runtime, token, lease, identity) do
    table = Ref.table(runtime)

    with [{:http_gateway, owner}] when owner == self() <- :ets.lookup(table, :http_gateway),
         {:ok, reservation} <- Admission.current(table, token),
         true <- reservation.owner == self() and reservation.deadline > Deadline.now() do
      entry = %{
        runtime: runtime,
        lease: lease,
        identity: identity,
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
      :ets.insert(table, {{:http_session_origin, token}, %{entry | cancellation: :consumed}})
      source = Map.merge(entry, %{token: token, id: id})
      if live_source?(table, token, entry), do: {:ok, source}, else: {:expired, source}
    else
      _retired -> {:error, :http_cancellation_retired}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
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

  defp session_key(%{lease: nil}), do: {:error, :session_required}

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
