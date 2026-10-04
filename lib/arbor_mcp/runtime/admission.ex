defmodule Arbor.MCP.Server.Runtime.Admission do
  @moduledoc false

  use GenServer

  @cleanup_turn_ms 10

  alias Arbor.MCP.Server.Runtime.{ByteBudget, Deadline, Failure, Ref, ShutdownGuard}

  def start_link(opts) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, opts) do
      :ok = ShutdownGuard.watch(Keyword.fetch!(opts, :table), pid)
      {:ok, pid}
    end
  end

  # The bounded ETS slot is claimed before sending even the small confirmation
  # message. No request payload is ever placed in this owner's mailbox.
  @spec reserve(Ref.t(), map(), keyword()) :: {:ok, map(), map()} | {:error, atom()}
  def reserve(runtime, request, opts) do
    table = Ref.table(runtime)

    with :ok <- Deadline.validate(Keyword.get(opts, :admission_deadline, :infinity)),
         {:ok, route} <- route(table),
         {:ok, bytes} <- request_size(request, opts, route.config),
         {:ok, reservation} <- claim_slot(runtime, route, request, bytes, opts) do
      confirm_candidate(table, route, reservation)
    end
  end

  defp confirm_candidate(table, route, reservation) do
    {wait, timeout_reason} = Deadline.confirmation_budget(reservation)

    if wait == 0 do
      rollback_candidate(table, reservation)
      {:error, timeout_reason}
    else
      try do
        case GenServer.call(route.admission, {:confirm, reservation.token}, wait) do
          {:ok, confirmed} ->
            {:ok, route, confirmed}

          {:error, _reason} = error ->
            rollback_candidate(table, reservation)
            error
        end
      catch
        :exit, {:timeout, _call} ->
          GenServer.cast(route.admission, {:abandon, reservation.token})
          {:error, timeout_reason}

        :exit, _reason ->
          # Confirmation may have succeeded before the caller timed out. Keep
          # the slot until the admission owner has released its ledger record;
          # otherwise another producer could reuse count capacity too soon.
          GenServer.cast(route.admission, {:abandon, reservation.token})
          {:error, :runtime_unavailable}
      end
    end
  end

  def route(table) do
    case :ets.lookup(table, :route) do
      [{:route, %{scheduler: scheduler} = route}] when is_pid(scheduler) ->
        if Process.alive?(scheduler), do: {:ok, route}, else: {:error, :runtime_unavailable}

      _ ->
        {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def activate(table, scheduler, config) do
    [{:admission, admission}] = :ets.lookup(table, :admission)
    GenServer.call(admission, {:activate, scheduler, config})
  end

  def bind(table, token), do: call(table, {:bind, token})
  def find(table, key), do: call(table, {:find, key})
  def terminal(table, token, result), do: call(table, {:terminal, token, result})
  def release(table, token), do: call(table, {:release, token})
  def close(table, reason), do: call(table, {:close, reason})
  def stats(table), do: call(table, :stats)
  def promote(table, token, request, opts), do: call(table, {:promote, token, request, opts})
  def release_step(table, token), do: call(table, {:release_step, token})
  def checkout(table, token), do: call(table, {:checkout, token})

  def current(table, token) do
    case :ets.lookup(table, {:reservation, token}) do
      [{_key, reservation}] -> {:ok, Map.delete(reservation, :payload)}
      _ -> {:error, :admission_lost}
    end
  end

  def pending_ingress(table) do
    for {{:reservation, token}, %{stage: :published} = reservation} <- :ets.tab2list(table),
        do: {token, Map.delete(reservation, :payload)}
  end

  def publish(table, route, reservation, payload, edge) do
    key = {:reservation, reservation.token}
    stored = Map.merge(reservation, %{payload: payload, stage: :published, edge: edge})

    match =
      {{key, :"$1"}, [{:"=:=", :"$1", {:const, reservation}}],
       [{{{:const, key}, {:const, stored}}}]}

    if :ets.select_replace(table, [match]) == 1 do
      GenServer.cast(route.admission, {:ingress_ready, reservation.token, edge})
      :ok
    else
      {:error, :admission_lost}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def pending_key?(table, {scope, :inbound, id} = key) do
    :ets.member(table, {:request, key}) or
      :ets.match_object(table, {{:wire_request, scope, id, :_}, :_}) != []
  end

  def pending_key?(table, key), do: :ets.member(table, {:request, key})

  def cancel_ingress(table, token, id), do: call(table, {:cancel_ingress, token, id})

  def origin_active?(table, %{token: token, generation: generation, scope: scope}) do
    case current(table, token) do
      {:ok, %{terminal: false, generation: ^generation, scope: ^scope} = reservation} ->
        reservation.deadline > System.monotonic_time(:millisecond) and
          Process.alive?(reservation.owner) and not :ets.member(table, {:cancelled, token})

      _ ->
        false
    end
  end

  def origin_active?(_table, nil), do: true
  def origin_active?(_table, _invalid), do: false

  def key(scope, request_id, direction), do: {scope, direction, request_id}

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    supervisor = Keyword.fetch!(opts, :supervisor)
    :ok = ShutdownGuard.watch(table, self())

    for {{:reservation, token}, %{terminal: false} = reservation} <- :ets.tab2list(table) do
      deliver_reply(
        reservation.reply_to,
        token,
        Failure.result(reservation, :runtime_restarted)
      )
    end

    for object <- :ets.tab2list(table), elem(object, 0) not in [:shutdown_guard, :closing] do
      :ets.delete_object(table, object)
    end

    :ets.insert(table, [{:admission, self()}, {:route, :closed}])
    Process.send_after(self(), :reap_unconfirmed, 100)

    {:ok,
     %{
       table: table,
       supervisor: supervisor,
       reservations: %{},
       monitors: %{},
       bytes: 0,
       control_bytes: 0,
       response_bytes: 0,
       scheduler_ref: nil,
       generation: nil,
       config: nil
     }}
  end

  @impl true
  def handle_call(:reference, _from, state) do
    {:reply, {:ok, Ref.new(state.supervisor, state.table)}, state}
  end

  def handle_call({:activate, scheduler, config}, _from, state) do
    state = drain(state, :runtime_restarted)
    if state.scheduler_ref, do: Process.demonitor(state.scheduler_ref, [:flush])
    generation = make_ref()
    monitor = Process.monitor(scheduler)

    route = %{
      admission: self(),
      scheduler: scheduler,
      generation: generation,
      config: config
    }

    :ets.insert(state.table, {:route, route})
    :ok = ByteBudget.reset(state.table, generation, config)

    {:reply, {:ok, generation},
     %{state | scheduler_ref: monitor, generation: generation, config: config}}
  end

  def handle_call({:confirm, token}, _from, state) do
    case ByteBudget.candidate(state.table, token) do
      reservation when is_map(reservation) -> confirm_reservation(reservation, state)
      _ -> {:reply, {:error, :admission_lost}, state}
    end
  end

  def handle_call({:checkout, token}, _from, state) do
    case :ets.lookup(state.table, {:reservation, token}) do
      [{_key, %{stage: :published, terminal: false, payload: payload} = stored}] ->
        if stored.deadline > System.monotonic_time(:millisecond) do
          {stored, state} = monitor_ingress_owner(stored, state)
          reservation = %{Map.delete(stored, :payload) | stage: :processing}
          :ets.insert(state.table, {{:reservation, token}, reservation})
          {:reply, {:ok, reservation, payload}, put_in(state.reservations[token], reservation)}
        else
          state = deliver_terminal(state, token, Failure.result(stored, :handler_timeout))
          {:reply, {:error, :handler_timeout}, state}
        end

      _ ->
        {:reply, {:error, :admission_lost}, state}
    end
  end

  def handle_call({:cancel_ingress, token, id}, _from, state) do
    case Map.get(state.reservations, token) do
      reservation when is_map(reservation) ->
        if id in reservation.wire_ids and id not in reservation.uncancellable_ids and
             (not reservation.terminal or reservation.request_id != id) do
          :ets.insert(state.table, {{:wire_cancel, token, id}, true})

          if reservation.request_id == id and reservation.kind == :rpc,
            do: :ets.insert(state.table, {{:cancelled, token}, true})
        end

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:bind, token}, _from, state) do
    case Map.get(state.reservations, token) do
      %{bound: false, terminal: false} = reservation ->
        if Process.alive?(reservation.owner) do
          Process.demonitor(reservation.monitor, [:flush])
          Process.cancel_timer(reservation.timer)
          bound = %{reservation | bound: true, monitor: nil, timer: nil}
          reservations = Map.put(state.reservations, token, bound)
          monitors = Map.delete(state.monitors, reservation.monitor)
          :ets.insert(state.table, {{:reservation, token}, bound})
          {:reply, {:ok, bound}, %{state | reservations: reservations, monitors: monitors}}
        else
          state = deliver_terminal(state, token, Failure.result(reservation, :owner_down))
          {:reply, {:error, :owner_down}, release_reservation(state, token)}
        end

      _ ->
        {:reply, {:error, :admission_lost}, state}
    end
  end

  def handle_call({:promote, token, request, opts}, _from, state) do
    case Map.get(state.reservations, token) do
      %{bound: false, terminal: false} = reservation ->
        request_id = Map.get(request, "id")
        key = key(reservation.scope, request_id || {:notification, token}, :inbound)

        cond do
          reservation.deadline <= System.monotonic_time(:millisecond) ->
            {:reply, {:error, :handler_timeout}, state}

          :erlang.external_size(key) > 4_096 ->
            {:reply, {:error, :invalid_scope}, state}

          Enum.any?(state.reservations, fn {other, entry} ->
            other != token and entry.key == key
          end) ->
            {:reply, {:error, :duplicate_request_id}, state}

          true ->
            :ets.delete_object(state.table, {{:request, reservation.key}, token})

            reservation = %{
              reservation
              | request_id: request_id,
                key: key,
                kind: Keyword.get(opts, :kind, :rpc)
            }

            :ets.insert(state.table, [
              {{:request, key}, token},
              {{:reservation, token}, reservation}
            ])

            if :ets.member(state.table, {:wire_cancel, token, request_id}),
              do: :ets.insert(state.table, {{:cancelled, token}, true})

            {:reply, {:ok, reservation}, put_in(state.reservations[token], reservation)}
        end

      _ ->
        {:reply, {:error, :admission_lost}, state}
    end
  end

  def handle_call({:release_step, token}, _from, state) do
    case Map.get(state.reservations, token) do
      %{terminal: true} = reservation ->
        monitor = Process.monitor(reservation.owner)

        timer =
          Process.send_after(
            self(),
            {:unbound_timeout, token},
            max(0, reservation.deadline - System.monotonic_time(:millisecond))
          )

        :ets.delete_object(state.table, {{:request, reservation.key}, token})

        :ets.delete(
          state.table,
          {:wire_request, reservation.scope, reservation.request_id, token}
        )

        :ets.delete(state.table, {:wire_cancel, token, reservation.request_id})
        key = key(reservation.scope, {:notification, token}, :inbound)

        reservation = %{
          reservation
          | bound: false,
            terminal: false,
            monitor: monitor,
            timer: timer,
            request_id: nil,
            wire_ids: List.delete(reservation.wire_ids, reservation.request_id),
            kind: :ingress,
            key: key,
            stage: :holding,
            monitoring_owner: true
        }

        :ets.insert(state.table, {{:reservation, token}, reservation})
        :ets.delete(state.table, {:cancelled, token})
        send(reservation.owner, {:arbor_mcp_step_ready, token})

        {:reply, :ok,
         %{
           state
           | reservations: Map.put(state.reservations, token, reservation),
             monitors: Map.put(state.monitors, monitor, token)
         }}

      _ ->
        {:reply, {:error, :admission_lost}, state}
    end
  end

  def handle_call({:find, key}, _from, state) do
    direct =
      Enum.find_value(state.reservations, fn {_token, entry} -> if entry.key == key, do: entry end)

    result =
      direct ||
        earliest(
          Enum.filter(Map.values(state.reservations), fn entry ->
            {scope, direction, id} = key
            direction == :inbound and entry.scope == scope and id in entry.wire_ids
          end)
        )

    {:reply, result, state}
  end

  def handle_call({:terminal, token, result}, _from, state) do
    {:reply, :ok, deliver_terminal(state, token, result)}
  end

  def handle_call({:release, token}, _from, state),
    do: {:reply, :ok, release_reservation(state, token)}

  def handle_call({:close, reason}, _from, state) do
    :ets.insert(state.table, {:route, :closed})
    {:reply, :ok, %{drain(state, reason) | generation: nil}}
  end

  def handle_call(:stats, _from, state) do
    slots = :ets.match_object(state.table, {{:slot, :_}, :_, :_})
    data_capacity = state.config.max_concurrency + state.config.max_queue

    data_slots =
      Enum.filter(slots, fn {{:slot, index}, _token, _producer} -> index <= data_capacity end)

    bytes = ByteBudget.used(state.table)

    {:reply,
     %{
       reserved: length(slots),
       reserved_envelopes: envelope_count(slots),
       admitted_work: length(data_slots),
       admitted_envelopes: envelope_count(data_slots),
       confirmed_work: confirmed_work(state.reservations),
       pending_byte_cleanup: length(ByteBudget.pending(state.table)),
       pending_bytes: bytes.data + bytes.outgoing + bytes.incoming,
       control_bytes: bytes.outgoing + bytes.incoming,
       response_bytes: bytes.incoming,
       confirmed: map_size(state.reservations)
     }, state}
  end

  @impl true
  def handle_cast({:ingress_ready, token, edge}, state) do
    state =
      case :ets.lookup(state.table, {:reservation, token}) do
        [{_key, %{stage: stage, terminal: false, bound: false} = stored}]
        when stage in [:published, :processing] ->
          {_stored, state} = monitor_ingress_owner(stored, state)
          state

        _ ->
          state
      end

    wake_edge(state.table, edge)
    {:noreply, state}
  end

  def handle_cast({:abandon, token}, state) do
    case ByteBudget.candidate(state.table, token) do
      reservation when is_map(reservation) -> release_slot(state.table, reservation)
      _ -> :ok
    end

    {:noreply, release_reservation(state, token)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{scheduler_ref: ref} = state) do
    :ets.insert(state.table, {:route, :closed})
    {:noreply, %{drain(state, :runtime_restarted) | scheduler_ref: nil, generation: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      token ->
        state =
          deliver_terminal(
            state,
            token,
            Failure.result(state.reservations[token], :producer_down)
          )

        {:noreply,
         if(retain_ingress?(state, token), do: state, else: release_reservation(state, token))}
    end
  end

  def handle_info({:unbound_timeout, token}, state) do
    case Map.get(state.reservations, token) do
      %{bound: false} ->
        state =
          deliver_terminal(
            state,
            token,
            Failure.result(state.reservations[token], :handler_timeout)
          )

        {:noreply,
         if(retain_ingress?(state, token), do: state, else: release_reservation(state, token))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:byte_cleanup, state) do
    ByteBudget.reap(state.table, Deadline.now() + @cleanup_turn_ms)
    {:noreply, state}
  end

  def handle_info(:reap_unconfirmed, state) do
    cleanup_deadline = Deadline.now() + @cleanup_turn_ms
    ByteBudget.reap(state.table, cleanup_deadline)
    # A producer may be killed between insert_new and confirm. Reap those
    # bounded slot records without charging bytes or allocating a monitor.
    producers =
      state.table
      |> :ets.match_object({{:slot, :_}, :_, :_})
      |> Enum.map(fn {_key, token, producer} -> {token, producer} end)
      |> Enum.uniq()

    for {token, producer} <- producers,
        not Map.has_key?(state.reservations, token),
        not Process.alive?(producer) do
      release_slot(state.table, %{token: token, producer: producer}, deadline: cleanup_deadline)
    end

    for {{:cancel_control, _key}, producer} = object <- :ets.tab2list(state.table),
        not Process.alive?(producer) do
      :ets.delete_object(state.table, object)
    end

    Process.send_after(self(), :reap_unconfirmed, 100)
    {:noreply, state}
  end

  defp monitor_ingress_owner(%{monitoring_owner: true} = stored, state), do: {stored, state}

  defp monitor_ingress_owner(stored, state) do
    previous = state.reservations[stored.token]
    Process.demonitor(previous.monitor, [:flush])
    monitor = Process.monitor(stored.owner)
    stored = %{stored | monitor: monitor, monitoring_owner: true}
    :ets.insert(state.table, {{:reservation, stored.token}, stored})

    state = %{
      state
      | reservations: Map.put(state.reservations, stored.token, Map.delete(stored, :payload)),
        monitors: state.monitors |> Map.delete(previous.monitor) |> Map.put(monitor, stored.token)
    }

    {stored, state}
  end

  defp confirm_reservation(reservation, state) do
    deadline_error = Deadline.admission_error(reservation)

    cond do
      ShutdownGuard.closing?(state.table) ->
        {:reply, {:error, :runtime_stopped}, state}

      reservation.generation != state.generation ->
        {:reply, {:error, :runtime_unavailable}, state}

      not reservation_available?(state.table, reservation) ->
        release_slot(state.table, reservation)
        {:reply, {:error, :admission_lost}, state}

      deadline_error ->
        release_slot(state.table, reservation)
        {:reply, {:error, deadline_error}, state}

      not origin_active?(state.table, reservation.origin) ->
        release_slot(state.table, reservation)
        {:reply, {:error, :request_cancelled}, state}

      not participants_alive?(reservation) ->
        release_slot(state.table, reservation)
        {:reply, {:error, :owner_down}, state}

      byte_budget_exhausted?(state, reservation) ->
        release_slot(state.table, reservation)
        {:reply, {:error, :server_busy}, state}

      Enum.any?(state.reservations, fn {_token, existing} -> existing.key == reservation.key end) ->
        release_slot(state.table, reservation)
        {:reply, {:error, :duplicate_request_id}, state}

      true ->
        monitor = Process.monitor(reservation.producer)

        timer =
          Process.send_after(
            self(),
            {:unbound_timeout, reservation.token},
            max(0, reservation.deadline - System.monotonic_time(:millisecond))
          )

        reservation =
          Map.merge(reservation, %{
            monitor: monitor,
            timer: timer,
            bound: false,
            terminal: false,
            monitoring_owner: false,
            sequence: System.unique_integer([:monotonic, :positive])
          })

        state = %{
          state
          | reservations: Map.put(state.reservations, reservation.token, reservation),
            monitors: Map.put(state.monitors, monitor, reservation.token),
            bytes: state.bytes + data_bytes(reservation),
            control_bytes:
              state.control_bytes +
                control_bytes(reservation),
            response_bytes: state.response_bytes + response_bytes(reservation)
        }

        :ets.insert(state.table, {{:request, reservation.key}, reservation.token})
        :ets.insert(state.table, {{:reservation, reservation.token}, reservation})
        ByteBudget.confirm(state.table, reservation.token)

        for id <- reservation.wire_ids,
            do:
              :ets.insert(
                state.table,
                {{:wire_request, reservation.scope, id, reservation.token}, true}
              )

        :telemetry.execute(
          [:arbor_mcp, :server, :request, :admitted],
          %{count: 1, request_bytes: reservation.bytes},
          %{runtime: state.supervisor}
        )

        {:reply, {:ok, reservation}, state}
    end
  end

  defp reservation_available?(table, reservation),
    do:
      slot_owned?(table, reservation) and
        not ByteBudget.release_requested?(table, reservation.token)

  defp participants_alive?(reservation),
    do: Process.alive?(reservation.producer) and Process.alive?(reservation.owner)

  defp request_size(request, opts, config) do
    request_bytes = :erlang.external_size(request)
    context_bytes = :erlang.external_size(Keyword.get(opts, :dispatch_opts, []))

    context_bytes = context_bytes + retained_option_bytes(opts)

    bytes = request_bytes + context_bytes

    budget =
      if Keyword.get(opts, :kind) in [:edge_control, :edge_response],
        do: config.max_control_bytes,
        else: config.max_pending_bytes

    cond do
      request_bytes > config.max_request_bytes -> {:error, :request_too_large}
      bytes > budget -> {:error, :server_busy}
      true -> {:ok, bytes}
    end
  end

  defp retained_option_bytes(opts) do
    Enum.reduce([:wire_ids, :origin, :uncancellable_ids, :scope, :admission_deadline], 0, fn key,
                                                                                             bytes ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> bytes
        {:ok, value} -> bytes + :erlang.external_size(value)
        :error -> bytes
      end
    end)
  end

  defp claim_slot(runtime, route, request, bytes, opts) do
    token = make_ref()
    producer = self()
    caller = Keyword.get(opts, :caller, producer)
    owner = Keyword.get(opts, :owner, producer)
    target = Keyword.get(opts, :reply_to, producer)
    timeout = Keyword.get(opts, :timeout, route.config.request_timeout_ms)
    scope = Keyword.get(opts, :scope, {:connection, owner})
    direction = Keyword.get(opts, :direction, :inbound)
    request_id = Map.get(request, "id")
    key = key(scope, request_id || {:notification, token}, direction)
    participant_error = participant_error(owner, caller)

    cond do
      participant_error ->
        {:error, participant_error}

      not local_reply_target?(target) ->
        {:error, :invalid_reply_target}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, :invalid_timeout}

      :erlang.external_size(key) > 4_096 ->
        {:error, :invalid_scope}

      not valid_origin?(Keyword.get(opts, :origin)) ->
        {:error, :invalid_origin}

      true ->
        count = work_count(request, opts)
        timeout = min(timeout, route.config.request_timeout_ms)
        deadline = System.monotonic_time(:millisecond) + timeout
        admission_deadline = Keyword.get(opts, :admission_deadline, :infinity)

        limit =
          Deadline.admission_limit(%{deadline: deadline, admission_deadline: admission_deadline})

        available = available_slots(route.config, Keyword.get(opts, :kind))

        with {:ok, slots} <-
               claim_work_slots(Ref.table(runtime), available, count, token, producer, limit) do
          reservation = %{
            token: token,
            slot: hd(slots),
            slots: slots,
            work_count: count,
            producer: producer,
            caller: caller,
            owner: owner,
            reply_to: target,
            kind: Keyword.get(opts, :kind, :rpc),
            stage: if(Keyword.get(opts, :via_edge, false), do: :waiting, else: :direct),
            edge: Keyword.get(opts, :edge),
            origin: Keyword.get(opts, :origin),
            origin_status: :active,
            wire_ids: Keyword.get(opts, :wire_ids, []),
            uncancellable_ids: Keyword.get(opts, :uncancellable_ids, []),
            batch?: Keyword.get(opts, :batch?, false),
            bytes: bytes + work_metadata_bytes(request, slots, token, producer),
            request_id: request_id,
            key: key,
            scope: scope,
            generation: route.generation,
            timeout: timeout,
            admission_deadline: admission_deadline,
            deadline: deadline
          }

          claim_candidate(Ref.table(runtime), route.generation, reservation)
        end
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  defp participant_error(owner, caller) do
    cond do
      not local_pid?(owner) -> :invalid_owner
      not local_pid?(caller) -> :invalid_caller
      true -> nil
    end
  end

  defp claim_candidate(table, generation, reservation) do
    case ByteBudget.claim(table, generation, reservation) do
      :ok ->
        {:ok, reservation}

      {:error, _reason} = error ->
        rollback_candidate(table, reservation)
        error
    end
  end

  defp slot_owned?(table, reservation) do
    Enum.all?(reservation.slots, fn slot ->
      :ets.lookup(table, {:slot, slot}) == [
        {{:slot, slot}, reservation.token, reservation.producer}
      ]
    end)
  end

  defp rollback_candidate(table, reservation) do
    {deadline, _reason} = Deadline.admission_limit(reservation)
    ByteBudget.release(table, reservation.token, deadline: deadline)
  end

  defp release_slot(table, reservation, opts \\ []) do
    ByteBudget.release(table, reservation.token, opts)
  end

  defp work_count(%{"payload" => members}, opts) when is_list(members) do
    if Keyword.get(opts, :kind) in [:edge_control, :edge_response],
      do: 1,
      else: max(1, length(members))
  end

  defp work_count(_request, _opts), do: 1

  # The input payload/context/options remain charged once. Arrays add the
  # serialized permit records and new reservation slot metadata once, rather
  # than retaining or charging a separate copy of every member payload.
  defp work_metadata_bytes(%{"payload" => members}, slots, token, producer)
       when is_list(members) do
    metadata = %{slot: hd(slots), slots: slots, work_count: length(slots)}
    records = Enum.map(slots, &{{:slot, &1}, token, producer})
    cleanup_bytes = ByteBudget.cleanup_record_bytes(token, producer)

    :erlang.external_size(metadata) + cleanup_bytes +
      Enum.sum(Enum.map(records, &:erlang.external_size/1))
  end

  defp work_metadata_bytes(_request, _slots, _token, _producer), do: 0

  defp claim_work_slots(table, available, count, token, producer, limit, attempts \\ 512)

  defp claim_work_slots(_table, _available, _count, _token, _producer, _deadline, 0),
    do: {:error, :server_busy}

  defp claim_work_slots(
         table,
         available,
         count,
         token,
         producer,
         {deadline, reason} = limit,
         attempts
       ) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, reason}
    else
      slots = available |> Stream.reject(&:ets.member(table, {:slot, &1})) |> Enum.take(count)

      records = [
        ByteBudget.cleanup_record(token, producer)
        | Enum.map(slots, &{{:slot, &1}, token, producer})
      ]

      cond do
        length(slots) != count -> {:error, :server_busy}
        :ets.insert_new(table, records) -> {:ok, slots}
        true -> claim_work_slots(table, available, count, token, producer, limit, attempts - 1)
      end
    end
  end

  defp envelope_count(slots) do
    slots |> Enum.map(fn {_key, token, _producer} -> token end) |> Enum.uniq() |> length()
  end

  defp confirmed_work(reservations) do
    Enum.reduce(reservations, 0, fn {_token, reservation}, total ->
      if reservation.kind in [:edge_control, :edge_response],
        do: total,
        else: total + reservation.work_count
    end)
  end

  defp data_bytes(%{kind: kind}) when kind in [:edge_control, :edge_response], do: 0
  defp data_bytes(reservation), do: reservation.bytes
  defp control_bytes(%{kind: :edge_control} = reservation), do: reservation.bytes
  defp control_bytes(_reservation), do: 0
  defp response_bytes(%{kind: :edge_response} = reservation), do: reservation.bytes
  defp response_bytes(_reservation), do: 0

  defp available_slots(%{max_control_queue: 0}, kind)
       when kind in [:edge_control, :edge_response] do
    []
  end

  defp available_slots(config, :edge_control) do
    capacity = config.max_concurrency + config.max_queue
    (capacity + 1)..(capacity + config.max_control_queue)
  end

  defp available_slots(config, :edge_response) do
    capacity = config.max_concurrency + config.max_queue + config.max_control_queue
    (capacity + 1)..(capacity + config.max_control_queue)
  end

  defp available_slots(config, _kind), do: 1..(config.max_concurrency + config.max_queue)

  defp valid_origin?(nil), do: true

  defp valid_origin?(%{token: token, generation: generation, scope: scope} = origin),
    do:
      is_reference(token) and is_reference(generation) and map_size(origin) == 3 and
        :erlang.external_size(scope) <= 4_096

  defp valid_origin?(_origin), do: false

  defp settle_origin_controls(state, token, result) do
    status =
      if match?({:ok, _response}, result) or result == :notification,
        do: :completed,
        else: :invalid

    Enum.reduce(state.reservations, state, fn
      {control, %{origin: %{token: ^token}}}, state ->
        case :ets.lookup(state.table, {:reservation, control}) do
          [{key, stored}] ->
            stored = %{stored | origin_status: status}
            :ets.insert(state.table, {key, stored})
            put_in(state.reservations[control], Map.delete(stored, :payload))

          _ ->
            state
        end

      _entry, state ->
        state
    end)
  end

  defp deliver_terminal(state, token, result) do
    case Map.get(state.reservations, token) do
      %{terminal: false} = reservation ->
        state = settle_origin_controls(state, token, result)

        reservation =
          case :ets.lookup(state.table, {:reservation, token}) do
            [{_key, stored}] -> Map.delete(stored, :payload)
            _ -> reservation
          end

        :ets.insert(state.table, {{:reservation, token}, %{reservation | terminal: true}})

        :telemetry.execute(
          [:arbor_mcp, :server, :request, :completed],
          %{
            count: 1,
            duration_ms:
              max(
                0,
                System.monotonic_time(:millisecond) - (reservation.deadline - reservation.timeout)
              )
          },
          %{runtime: state.supervisor, outcome: outcome_class(result)}
        )

        deliver_reply(reservation.reply_to, token, result)

        if not reservation.bound and reservation.stage in [:published, :processing, :holding] and
             is_pid(reservation.edge) and match?({:error, _reason}, result),
           do: send(reservation.edge, {:runtime_ingress_expired, token})

        reservations = Map.put(state.reservations, token, %{reservation | terminal: true})
        %{state | reservations: reservations}

      _ ->
        state
    end
  end

  defp deliver_reply(target, token, result) do
    send(target, {:arbor_mcp_runtime, token, result})
    :ok
  rescue
    # Erlang cannot distinguish an ordinary reference from a process alias
    # during admission. Delivery is best effort and must not interrupt the
    # terminal ledger update or a restart's outstanding-reservation cleanup.
    ArgumentError -> :ok
  end

  defp release_reservation(state, token) do
    case Map.pop(state.reservations, token) do
      {nil, _reservations} ->
        state

      {reservation, reservations} ->
        if reservation.monitor, do: Process.demonitor(reservation.monitor, [:flush])
        if reservation.timer, do: Process.cancel_timer(reservation.timer)
        release_slot(state.table, reservation)
        :ets.delete_object(state.table, {{:request, reservation.key}, token})
        :ets.delete(state.table, {:reservation, token})
        :ets.delete(state.table, {:cancelled, token})

        for id <- reservation.wire_ids do
          :ets.delete(state.table, {:wire_request, reservation.scope, id, token})
          :ets.delete(state.table, {:wire_cancel, token, id})
        end

        %{
          state
          | reservations: reservations,
            monitors: Map.delete(state.monitors, reservation.monitor),
            bytes: state.bytes - data_bytes(reservation),
            control_bytes:
              state.control_bytes -
                control_bytes(reservation),
            response_bytes: state.response_bytes - response_bytes(reservation)
        }
    end
  end

  defp earliest([]), do: nil
  defp earliest(entries), do: Enum.min_by(entries, & &1.sequence)

  defp wake_edge(table, edge) when is_pid(edge) do
    if :ets.insert_new(table, {{:ingress_wakeup, edge}, true}),
      do: send(edge, :runtime_ingress_ready)

    :ok
  end

  defp retain_ingress?(state, token) do
    reservation = state.reservations[token]

    if reservation.stage in [:published, :processing, :holding] do
      if is_pid(reservation.edge), do: wake_edge(state.table, reservation.edge)
      Process.alive?(reservation.owner)
    else
      false
    end
  end

  defp byte_budget_exhausted?(state, %{kind: :edge_control} = reservation),
    do: state.control_bytes + reservation.bytes > state.config.max_control_bytes

  defp byte_budget_exhausted?(state, %{kind: :edge_response} = reservation),
    do: state.response_bytes + reservation.bytes > state.config.max_control_bytes

  defp byte_budget_exhausted?(state, reservation),
    do: state.bytes + reservation.bytes > state.config.max_pending_bytes

  defp drain(state, reason) do
    :ets.insert(state.table, {:route, :closed})
    ByteBudget.clear(state.table)

    state =
      Enum.reduce(Map.keys(state.reservations), state, fn token, acc ->
        acc
        |> deliver_terminal(token, Failure.result(acc.reservations[token], reason))
        |> release_reservation(token)
      end)

    :ets.select_delete(state.table, [
      {{{:slot, :_}, :_, :_}, [], [true]},
      {{{:byte_cleanup, :_}, :_, :_}, [], [true]}
    ])

    :ets.select_delete(state.table, [{{{:cancel_control, :_}, :_}, [], [true]}])
    state
  end

  defp outcome_class({:ok, %{"error" => _error}}), do: :application_error
  defp outcome_class({:ok, _response}), do: :ok
  defp outcome_class({:error, %{"error" => %{"data" => %{"type" => type}}}}), do: type
  defp outcome_class({:error, reason}) when is_atom(reason), do: reason
  defp outcome_class(:notification), do: :notification

  defp local_pid?(pid), do: is_pid(pid) and node(pid) == node()

  defp local_reply_target?(target) do
    (is_pid(target) or is_reference(target)) and node(target) == node()
  end

  defp call(table, message) do
    case :ets.lookup(table, :admission) do
      [{:admission, owner}] -> GenServer.call(owner, message, 5_000)
      _ -> {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end
end
