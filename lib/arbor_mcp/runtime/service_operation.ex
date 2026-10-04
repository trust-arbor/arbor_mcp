defmodule Arbor.MCP.Server.Runtime.ServiceOperation do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    Ref,
    ServiceInvocation,
    Services
  }

  @max_wait 4_294_967_295
  @cas_attempts 32
  @cleanup_ms 5

  def new(opts) do
    limits = %{
      count: Keyword.get(opts, :max_operations, 64),
      bytes: Keyword.get(opts, :max_operation_bytes, 1_000_000),
      payload: Keyword.get(opts, :max_operation_payload_bytes, 65_536),
      timeout: Keyword.get(opts, :operation_timeout_ms, 1_000)
    }

    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)) and
         limits.timeout <= @max_wait do
      table = :ets.new(__MODULE__, [:set, :public])
      :ets.insert(table, {:budget, %{used: 0, claims: %{}}})

      {:ok,
       Map.merge(limits, %{
         table: table,
         counters: :atomics.new(1, signed: false),
         server: self()
       })}
    else
      {:error, :invalid_operation_limits}
    end
  end

  def call(service, kind, operation, args, opts) do
    started = now()

    with {:ok, binding} <- Services.resolve(service, kind),
         {:ok, context} <- context(binding, kind, operation, opts, started) do
      adapter_opts =
        binding.options
        |> Keyword.merge(server: binding.server, namespace: binding.namespace || "owned")
        |> Keyword.put(:service_address, binding.address)

      binding.adapter.operate(operation, args, context, adapter_opts)
    end
  rescue
    ArgumentError -> {:error, :service_unavailable}
  catch
    :exit, _reason -> {:error, :service_unavailable}
  end

  def submit(address, operation, args, context) do
    deadline = min(context.deadline, now() + address.timeout)
    phase = :atomics.new(1, signed: false)
    context = context |> Map.put(:deadline, deadline) |> Map.put(:phase, phase)
    payload = {operation, args, context}

    token = make_ref()
    reply = :erlang.alias()
    monitor = Process.monitor(address.server)

    entry = %{
      token: token,
      payload: payload,
      owner: self(),
      reply: reply,
      bytes: 0,
      deadline: deadline,
      phase: phase
    }

    bytes = :erlang.external_size(entry) + 8
    entry = %{entry | bytes: bytes}

    try do
      with true <- bytes <= address.payload,
           :ok <- claim(address, entry, @cas_attempts) do
        wake(address)

        receive do
          {^token, result} ->
            if now() < deadline, do: result, else: {:error, :operation_timeout}

          {:DOWN, ^monitor, :process, _pid, _reason} ->
            if now() < deadline,
              do: {:error, :service_unavailable},
              else: {:error, :operation_timeout}
        after
          max(0, deadline - now()) -> {:error, :operation_timeout}
        end
      else
        false -> {:error, :operation_payload_too_large}
        {:error, _reason} = error -> error
      end
    after
      :erlang.unalias(reply)
      Process.demonitor(monitor, [:flush])
      :atomics.exchange(phase, 1, 3)
      release(address, token, min(deadline, now() + @cleanup_ms), @cas_attempts)

      receive do
        {^token, _late_result} -> :ok
      after
        0 -> :ok
      end
    end
  rescue
    ArgumentError -> {:error, :service_unavailable}
  end

  def entries(address) do
    [{:budget, budget}] = :ets.lookup(address.table, :budget)
    Map.to_list(budget.claims)
  end

  def ready(address), do: :atomics.put(address.counters, 1, 0)

  # Phases are independent of ledger CAS: reserved(0), processing(1),
  # completed(2), returned/abandoned(3). Failed cleanup cannot re-execute work.
  def begin(entry) do
    current?(entry) and :atomics.compare_exchange(entry.phase, 1, 0, 1) == :ok
  end

  def finish(address, entry, result, cleanup_deadline) do
    if :atomics.compare_exchange(entry.phase, 1, 1, 2) == :ok or
         :atomics.compare_exchange(entry.phase, 1, 0, 3) == :ok,
       do: safe_send(entry.reply, {entry.token, result})

    release(address, entry.token, cleanup_deadline, @cas_attempts)
  end

  def current?(entry) do
    context = elem(entry.payload, 2)

    :atomics.get(entry.phase, 1) in [0, 1] and Process.alive?(entry.owner) and
      Process.alive?(context.owner) and now() < entry.deadline and
      context_current?(Map.delete(context, :phase))
  rescue
    ArgumentError -> false
  end

  def context_current?(context) do
    service_current? =
      case Services.resolve(context.runtime, context.kind) do
        {:ok, binding} -> binding.generation == context.generation
        _invalid -> false
      end

    service_current? and processing?(context) and Process.alive?(context.owner) and
      origin_current?(context) and context.deadline > now()
  rescue
    ArgumentError -> false
  end

  def validate_context(context),
    do: if(context_current?(context), do: :ok, else: {:error, :operation_timeout})

  def stats(address) do
    [{:budget, budget}] = :ets.lookup(address.table, :budget)
    %{pending_operations: map_size(budget.claims), pending_operation_bytes: budget.used}
  end

  def now, do: Deadline.now()
  def maintenance_deadline, do: now() + @cleanup_ms

  @doc false
  def with_deadline(opts, cutoff) do
    supplied = Keyword.get(opts, :deadline, :infinity)

    with :ok <- validate_deadline(supplied) do
      {:ok,
       Keyword.put(
         opts,
         :deadline,
         if(supplied == :infinity, do: cutoff, else: min(cutoff, supplied))
       )}
    end
  end

  defp context(binding, kind, operation, opts, started) do
    timeout = Keyword.get(opts, :timeout, binding.address.timeout)
    origin = CallbackContext.current()

    owner = Keyword.get(opts, :owner, operation_owner(operation, origin))

    cond do
      not is_integer(timeout) or timeout <= 0 or timeout > @max_wait ->
        {:error, :invalid_operation_timeout}

      not is_pid(owner) or node(owner) != node() or not Process.alive?(owner) ->
        {:error, :invalid_owner}

      true ->
        deadline = min(started + timeout, started + binding.address.timeout)
        deadline = if origin, do: min(deadline, origin.deadline), else: deadline
        supplied_deadline = Keyword.get(opts, :deadline, :infinity)

        with :ok <- validate_deadline(deadline),
             :ok <- validate_deadline(supplied_deadline) do
          deadline =
            if supplied_deadline == :infinity,
              do: deadline,
              else: min(deadline, supplied_deadline)

          if deadline > now() do
            context = %{
              runtime: binding.runtime,
              kind: kind,
              generation: binding.generation,
              origin: origin,
              owner: owner,
              deadline: deadline
            }

            attach_invocation(context, operation, supplied_deadline)
          else
            {:error, :operation_timeout}
          end
        end
    end
  end

  defp operation_owner(:claim_initialization, %{owner: owner}), do: owner
  defp operation_owner(_operation, _origin), do: self()

  defp attach_invocation(context, :claim_initialization, supplied_deadline) do
    with {:ok, invocation} <- ServiceInvocation.capture(context, supplied_deadline),
         do: {:ok, Map.put(context, :invocation, invocation)}
  end

  defp attach_invocation(context, _operation, _supplied_deadline), do: {:ok, context}

  defp validate_deadline(deadline),
    do:
      if(Deadline.validate(deadline) == :ok, do: :ok, else: {:error, :invalid_operation_deadline})

  defp processing?(%{phase: phase}), do: :atomics.get(phase, 1) == 1
  defp processing?(_borrowed_context), do: true

  defp origin_current?(%{origin: nil}), do: true

  defp origin_current?(%{runtime: runtime, origin: origin}) do
    case Admission.route(Ref.table(runtime)) do
      {:ok, %{generation: generation}} when generation == origin.generation ->
        table = Ref.table(runtime)

        with true <- Admission.origin_active?(table, origin),
             {:ok, reservation} <- Admission.current(table, origin.token) do
          reservation.output_phase == origin.output_phase
        else
          _retired -> false
        end

      _other ->
        false
    end
  end

  # The one CAS publishes ownership, payload and both budgets atomically.
  # An exited producer always leaves a claim the owner can reap.
  defp claim(_address, _entry, 0), do: {:error, :operation_contention}

  defp claim(address, entry, attempts) do
    if now() >= entry.deadline do
      {:error, :operation_timeout}
    else
      claim_current(address, entry, attempts)
    end
  end

  defp claim_current(address, entry, attempts) do
    [{:budget, budget}] = :ets.lookup(address.table, :budget)

    if map_size(budget.claims) >= address.count or budget.used + entry.bytes > address.bytes do
      {:error, :operation_capacity_exhausted}
    else
      next = %{
        budget
        | used: budget.used + entry.bytes,
          claims: Map.put(budget.claims, entry.token, entry)
      }

      if replace(address.table, budget, next), do: :ok, else: claim(address, entry, attempts - 1)
    end
  end

  defp release(_address, _token, _deadline, 0), do: {:error, :cleanup_pending}

  defp release(address, token, deadline, attempts) do
    if now() >= deadline do
      {:error, :cleanup_pending}
    else
      release_current(address, token, deadline, attempts)
    end
  end

  defp release_current(address, token, deadline, attempts) do
    [{:budget, budget}] = :ets.lookup(address.table, :budget)

    case Map.pop(budget.claims, token) do
      {nil, _claims} ->
        :ok

      {entry, claims} ->
        next = %{budget | used: budget.used - entry.bytes, claims: claims}

        if replace(address.table, budget, next),
          do: :ok,
          else: release(address, token, deadline, attempts - 1)
    end
  rescue
    ArgumentError -> :ok
  end

  defp replace(table, previous, next) do
    match =
      {{:budget, :"$1"}, [{:"=:=", :"$1", {:const, previous}}], [{{:budget, {:const, next}}}]}

    :ets.select_replace(table, [match]) == 1
  end

  defp wake(address) do
    if :atomics.compare_exchange(address.counters, 1, 0, 1) == :ok,
      do: send(address.server, :service_operations)
  end

  defp safe_send(reply, message) do
    send(reply, message)
  rescue
    ArgumentError -> :ok
  end
end
