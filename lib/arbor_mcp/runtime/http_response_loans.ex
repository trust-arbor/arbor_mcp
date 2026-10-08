defmodule Arbor.MCP.Server.Runtime.HTTPResponseLoans do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Admission, ByteBudget, Deadline, HTTPWriterBinding, Ref}
  alias Arbor.MCP.Server.Runtime.HTTPResources.Source

  def install(table) do
    index = :ets.new(__MODULE__, [:set, :protected])
    :ets.insert(table, {:http_response_index, self(), index})

    for {_input, token, witness} <- ByteBudget.response_consumers(table),
        do: :ets.insert(index, {token, witness, Process.monitor(witness.producer)})

    index
  end

  # Admission authenticates an already-charged ETS candidate. Its protected
  # index proves the result/consumer witness before checkout. The fixed witness
  # also lives inside the original incoming claim, so actor loss cannot make
  # the input slot/bytes reusable while an actual Task still holds the result.
  def adopt(table, index, reservation, control_token, gateway, digest) do
    key = {:http_response_candidate, reservation.token, control_token}

    with [{^key, candidate}] <- :ets.take(table, key),
         true <- is_binary(digest) and byte_size(digest) == 32,
         true <- :crypto.hash(:sha256, :erlang.term_to_binary(candidate)) == digest,
         [{:http_gateway, ^gateway}] <- :ets.lookup(table, :http_gateway),
         true <- reservation.owner == gateway and reservation.kind == :edge_response,
         true <- not reservation.terminal and reservation.deadline > Deadline.now(),
         {:ok, source} <- Source.admission_snapshot(candidate.source),
         true <- source.gateway == gateway and source.producer == candidate.producer,
         true <- source.generation == reservation.generation,
         {:ok, input} <- HTTPWriterBinding.validate(candidate.binding, source.runtime),
         true <- input.owner == reservation.caller and input.scope == reservation.scope,
         true <- input.generation == reservation.generation and input.lease == source.lease,
         true <- candidate.endpoint == source.endpoint,
         true <- length(for_input(table, reservation.token)) < reservation.work_count,
         true <- :atomics.get(candidate.phase, 1) == 0 do
      loan = %{
        input: reservation.token,
        producer: source.producer,
        phase: candidate.phase,
        gateway: gateway,
        generation: source.generation,
        source_token: source.token,
        source_phase: source.phase,
        scope_digest: :crypto.hash(:sha256, :erlang.term_to_binary(source.scope)),
        deadline: min(candidate.deadline, source.deadline),
        adoption: make_ref(),
        result: candidate.result
      }

      adopt_loan(table, index, reservation, control_token, loan)
    else
      _invalid -> {:error, :reverse_response_retired}
    end
  rescue
    ArgumentError -> {:error, :reverse_response_retired}
  end

  defp adopt_loan(table, index, reservation, token, loan) do
    witness = witness(token, loan)
    key = {:http_response_loan, token}

    if metadata_bytes(table, reservation.token) + :erlang.external_size({loan, witness}) <=
         reservation.bytes and :ets.insert_new(table, {key, loan}) do
      case ByteBudget.adopt_response(table, reservation.token, token, witness, loan.deadline) do
        :ok ->
          :ets.insert(index, {token, witness, Process.monitor(loan.producer)})
          :ok

        _unconfirmed ->
          :ets.delete(table, key)
          {:error, :reverse_response_retired}
      end
    else
      {:error, :reverse_response_retired}
    end
  end

  def checkout(runtime, token, source, deadline) do
    table = Ref.table(runtime)

    with true <- deadline > Deadline.now() and Source.current?(source),
         [{{:http_response_loan, ^token}, loan}] <-
           :ets.lookup(table, {:http_response_loan, token}),
         true <- loan.producer == self(),
         [{:admission, admission}] <- :ets.lookup(table, :admission),
         [{:http_response_index, ^admission, index}] <- :ets.lookup(table, :http_response_index),
         true <-
           :ets.info(index, :owner) == admission and :ets.info(index, :protection) == :protected,
         [{^token, proof, _monitor}] <- :ets.lookup(index, token),
         true <- fixed_witness?(proof) and proof == witness(token, loan),
         true <- adopted?(table, token, proof),
         _previous = Process.put(receipt_key(token), proof),
         :ok <- :atomics.compare_exchange(loan.phase, 1, 0, 1),
         true <- deadline > Deadline.now(),
         do: {:ok, loan.result},
         else: (_retired -> {:error, :reverse_request_retired})
  rescue
    ArgumentError -> {:error, :reverse_request_retired}
  end

  def acknowledge(runtime, token) do
    table = Ref.table(runtime)
    receipt = Process.get(receipt_key(token))

    if fixed_witness?(receipt) and receipt.producer == self() and
         receipt.token == token and adopted?(table, token, receipt) and
         :atomics.get(receipt.phase, 1) == 1 do
      :atomics.exchange(receipt.phase, 1, 2)
      Process.delete(receipt_key(token))
      wake(table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def retained?(table, token), do: for_input(table, token) != []

  def retained_tokens(table),
    do: MapSet.new(Enum.map(ByteBudget.response_consumers(table), fn {input, _, _} -> input end))

  # Only an entered phase1 liability can cross actor loss. Its data is never
  # re-consumable. Even an absent/changed application receipt is conservatively
  # quarantined until the original authenticated consumer dies; it never grants
  # another PID result authority or early credit reuse.
  def recover(table) do
    for {input, token, proof} <- ByteBudget.response_consumers(table) do
      status = :atomics.get(proof.phase, 1)

      if status == 1 and Process.alive?(proof.producer) and owned_credit?(table, input) do
        :ets.delete(table, {:http_response_loan, token})
      else
        if status == 0, do: :atomics.compare_exchange(proof.phase, 1, 0, 3)
        settle(table, input, token, proof)
      end
    end

    retained_tokens(table)
  end

  def retire_unread(table) do
    for {input, token, proof} <- ByteBudget.response_consumers(table),
        :atomics.compare_exchange(proof.phase, 1, 0, 3) == :ok,
        do: settle(table, input, token, proof)
  end

  def reap(table) do
    :ets.delete(table, :http_response_wake)

    Enum.reduce(ByteBudget.response_consumers(table), MapSet.new(), fn {input, token, proof},
                                                                       settled ->
      status = :atomics.get(proof.phase, 1)

      invalid_unread =
        status == 0 and
          (proof.deadline <= Deadline.now() or not Process.alive?(proof.gateway) or
             not current_generation?(table, proof.generation))

      if status in [2, 3] or not Process.alive?(proof.producer) or
           (invalid_unread and :atomics.compare_exchange(proof.phase, 1, 0, 3) == :ok) do
        settle(table, input, token, proof)
        MapSet.put(settled, input)
      else
        settled
      end
    end)
  end

  defp settle(table, input, token, proof) do
    case ByteBudget.settle_response(table, input, token, proof, Deadline.now() + 10) do
      :ok -> :ets.delete(table, {:http_response_loan, token})
      _pending -> :ok
    end
  end

  def monitor?(index, monitor), do: :ets.match_object(index, {:_, :_, monitor}) != []

  def reap_index(table, index) do
    adopted =
      MapSet.new(Enum.map(ByteBudget.response_consumers(table), fn {_, token, _} -> token end))

    for {token, _witness, monitor} <- :ets.tab2list(index), not MapSet.member?(adopted, token) do
      Process.demonitor(monitor, [:flush])
      :ets.delete(index, token)
    end
  end

  defp receipt_key(token), do: {__MODULE__, token}

  defp witness(token, loan),
    do:
      Map.delete(loan, :result)
      |> Map.merge(%{token: token, digest: :crypto.hash(:sha256, :erlang.term_to_binary(loan))})

  defp fixed_witness?(
         %{
           token: _,
           input: _,
           phase: _,
           generation: _,
           source_token: _,
           source_phase: _,
           adoption: _,
           producer: _,
           gateway: _,
           deadline: _,
           digest: _,
           scope_digest: _
         } = proof
       )
       when map_size(proof) == 12 do
    reference_fields?(proof) and local_pid?(proof.producer) and local_pid?(proof.gateway) and
      is_integer(proof.deadline) and Deadline.validate(proof.deadline) == :ok and
      digest?(proof.digest) and digest?(proof.scope_digest)
  end

  defp fixed_witness?(_invalid), do: false

  defp reference_fields?(proof),
    do:
      Enum.all?(
        [:token, :input, :phase, :generation, :source_token, :source_phase, :adoption],
        &is_reference(Map.fetch!(proof, &1))
      )

  defp local_pid?(pid), do: is_pid(pid) and node(pid) == node()
  defp digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp adopted?(table, token, proof),
    do:
      Enum.any?(ByteBudget.response_consumers(table), fn {input, control, witness} ->
        input == proof.input and control == token and witness == proof
      end)

  defp for_input(table, token),
    do: Enum.filter(ByteBudget.response_consumers(table), fn {input, _, _} -> input == token end)

  defp metadata_bytes(table, token),
    do:
      Enum.sum(
        Enum.map(for_input(table, token), fn {_input, _control, proof} ->
          :erlang.external_size(proof)
        end)
      )

  defp current_generation?(table, generation),
    do: match?({:ok, %{generation: ^generation}}, Admission.route(table))

  defp owned_credit?(table, token) do
    with [{{:reservation, ^token}, reservation}] <- :ets.lookup(table, {:reservation, token}),
         [{_key, budget}] <- :ets.lookup(table, {:byte_budget, :incoming}),
         %{bytes: bytes} <- budget.claims[token],
         true <- bytes == reservation.bytes do
      Enum.all?(reservation.slots, fn slot ->
        :ets.lookup(table, {:slot, slot}) == [{{:slot, slot}, token, reservation.producer}]
      end)
    else
      _invalid -> false
    end
  end

  defp wake(table) do
    case :ets.lookup(table, :admission) do
      [{:admission, admission}] ->
        if :ets.insert_new(table, {:http_response_wake, true}),
          do: send(admission, :http_response_ready)

      _missing ->
        :ok
    end
  end
end
