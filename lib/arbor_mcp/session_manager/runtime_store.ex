defmodule Arbor.MCP.SessionManager.RuntimeStore do
  @moduledoc false

  alias Arbor.MCP.Internal.SessionStore

  alias Arbor.MCP.Server.Runtime.{
    OutputCodec,
    RetainedTerm,
    ServiceInvocation,
    ServiceOperation,
    ServiceStore
  }

  @max_sequence 18_446_744_073_709_551_615
  @identity [:principal_id, :tenant_id, :issuer, :audience]
  alias Arbor.MCP.SessionManager.PendingEvents
  @metadata @identity ++ [:transport, :transport_endpoint, :client_info]
  @defaults [
    max_sessions: 128,
    max_metadata_bytes: 1_000_000,
    max_session_metadata_bytes: 65_536,
    max_request_ids: 1_024,
    max_request_ids_per_session: 128,
    max_request_id_bytes: 65_536,
    max_events: 1_024,
    max_events_per_session: 128,
    max_event_bytes: 65_536,
    max_replay_bytes: 1_000_000,
    max_replay_bytes_per_session: 262_144,
    max_replay_page_events: 32,
    max_replay_page_bytes: 65_536,
    session_ttl_ms: 3_600_000
  ]

  def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 1_000}

  def runtime_service_capabilities, do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}
  def runtime_service_binding(server, timeout), do: ServiceStore.binding(server, timeout)

  def operate(operation, args, context, opts),
    do:
      ServiceOperation.submit(
        opts[:service_address],
        operation,
        [opts[:namespace] | args],
        context
      )

  def lease_active?(id, epoch, opts) do
    case :ets.lookup(opts[:read_address], {opts[:namespace], id}) do
      [{_key, %{epoch: ^epoch, expires_at: expires_at}}] -> expires_at > ServiceOperation.now()
      _missing -> false
    end
  rescue
    ArgumentError -> false
  end

  def open(opts) do
    limits = Map.new(@defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)

    cond do
      Keyword.get(opts, :storage_backend, :ets) != :ets ->
        {:error, :runtime_durable_sessions_unqualified}

      not Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)) ->
        {:error, :invalid_session_limits}

      true ->
        with {:ok, store} <- SessionStore.ETS.open(%{}) do
          {:ok,
           %{
             store: store,
             limits: limits,
             claims: %{},
             expiry_offset: 0,
             pending_events: %{},
             pending_event_offset: 0
           }}
        end
    end
  end

  def read_address(model), do: model.store.sessions

  def close(model),
    do: model |> PendingEvents.close() |> Map.fetch!(:store) |> SessionStore.close()

  def event_row(model, key, epoch), do: epoch_row(model, key, epoch)
  def event_row_capacity(model, key, row), do: row_capacity(model, key, row)
  def max_sequence, do: @max_sequence

  def apply(operation, args, context, model)
      when operation in [
             :prepare_event,
             :event_current,
             :handoff_event,
             :finalize_event,
             :publish_event,
             :release_event
           ],
      do: PendingEvents.apply(operation, args, context, model)

  def apply(:create, [namespace, metadata, requested_id], context, model) do
    model = expire(model)
    id = requested_id || Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    key = {namespace, id}

    row = %{
      id: id,
      epoch: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      metadata: Map.take(metadata, @metadata),
      initialized: false,
      initialization_claimed: false,
      protocol_version: nil,
      sequence: 0,
      evicted_through: 0,
      expires_at: ServiceOperation.now() + model.limits.session_ttl_ms
    }

    with true <- valid_id?(id) and is_map(metadata) and valid_transport_metadata?(metadata),
         false <- SessionStore.member(model.store, :sessions, key),
         true <- SessionStore.info(model.store, :sessions, :size) < model.limits.max_sessions,
         :ok <- row_capacity(model, key, row),
         :ok <- ServiceOperation.validate_context(context) do
      SessionStore.insert(model.store, :sessions, {key, row})
      {{:ok, %{id: id, epoch: row.epoch}}, model}
    else
      false -> {{:error, :session_exists_or_limit_exceeded}, model}
      true -> {{:error, :session_already_exists}, model}
      {:error, _reason} = error -> {error, model}
    end
  end

  def apply(:ensure, [namespace, id, metadata, initialized?], context, model) do
    key = {namespace, id}

    with {:ok, row} <- row(model, key),
         :ok <- ensure_identity(row.metadata, metadata),
         :ok <- ensure_initialized(row, initialized?) do
      updated = %{
        row
        | metadata: Map.merge(row.metadata, Map.take(metadata, [:client_info, :transport])),
          expires_at: ServiceOperation.now() + model.limits.session_ttl_ms
      }

      case with :ok <- row_capacity(model, key, updated),
                do: ServiceOperation.validate_context(context) do
        :ok ->
          SessionStore.insert(model.store, :sessions, {key, updated})
          {{:ok, %{id: id, epoch: row.epoch}}, model}

        error ->
          {error, model}
      end
    else
      error -> {error, model}
    end
  end

  def apply(:claim_id, [namespace, {id, epoch}, wire_id], context, model) do
    key = {namespace, id}
    claim_key = {namespace, id, epoch, wire_id}
    claims = SessionStore.all(model.store, :request_ids)
    bytes = RetainedTerm.bytes({claim_key, 0}) + 8

    with {:ok, _row} <- epoch_row(model, key, epoch),
         true <- is_integer(wire_id) or is_binary(wire_id),
         false <- SessionStore.member(model.store, :request_ids, claim_key),
         true <- length(claims) < model.limits.max_request_ids,
         true <-
           Enum.count(claims, fn {{ns, sid, ep, _id}, _bytes} ->
             {ns, sid, ep} == {namespace, id, epoch}
           end) < model.limits.max_request_ids_per_session,
         true <-
           Enum.sum(Enum.map(claims, &elem(&1, 1))) + bytes <= model.limits.max_request_id_bytes,
         :ok <- ServiceOperation.validate_context(context) do
      SessionStore.insert(model.store, :request_ids, {claim_key, bytes})
      {:ok, model}
    else
      true -> {{:error, :duplicate_request_id}, model}
      false -> {{:error, :request_id_capacity_exhausted}, model}
      error -> {error, model}
    end
  end

  def apply(:claim_initialization, [namespace, {id, epoch}], context, model) do
    key = {namespace, id}

    with {:ok, row} <- epoch_row(model, key, epoch),
         false <- row.initialized && {:error, :session_already_initialized},
         false <- row.initialization_claimed && {:error, :initialization_in_progress},
         true <- ServiceInvocation.current?(context.invocation),
         true <- ServiceInvocation.matches_session?(context.invocation, namespace, id, epoch),
         :ok <- ServiceOperation.validate_context(context) do
      token = make_ref()

      claim = %{
        token: token,
        epoch: epoch,
        owner: ServiceInvocation.owner(context.invocation),
        deadline: ServiceInvocation.deadline(context.invocation),
        invocation: context.invocation,
        monitor: Process.monitor(ServiceInvocation.owner(context.invocation))
      }

      updated = %{row | initialization_claimed: true}
      next = %{model | claims: Map.put(model.claims, key, claim)}

      case with :ok <- row_capacity(next, key, updated),
                :ok <- ServiceOperation.validate_context(context),
                true <- ServiceInvocation.current?(claim.invocation),
                true <- claim_matches_session?(claim, key, epoch),
                do: :ok do
        :ok ->
          SessionStore.insert(model.store, :sessions, {key, updated})
          {{:ok, token, claim.owner, claim.deadline}, next}

        error ->
          Process.demonitor(claim.monitor, [:flush])
          {if(error == false, do: {:error, :operation_timeout}, else: error), model}
      end
    else
      false -> {{:error, :initialization_owner_unavailable}, model}
      error -> {error, model}
    end
  end

  def apply(
        :complete_initialization,
        [namespace, {id, epoch}, token, owner, original_deadline, version],
        context,
        model
      ) do
    key = {namespace, id}

    with {:ok, row} <- epoch_row(model, key, epoch),
         %{token: ^token, owner: ^owner, deadline: ^original_deadline} = claim <-
           model.claims[key],
         true <- ServiceInvocation.current?(claim.invocation),
         true <- original_deadline > ServiceOperation.now() and Process.alive?(owner),
         true <- is_binary(version) and byte_size(version) in 1..128,
         true <- row.protocol_version in [nil, version] do
      updated = %{
        row
        | initialized: true,
          initialization_claimed: false,
          protocol_version: version
      }

      next = %{model | claims: Map.delete(model.claims, key)}

      case with :ok <- row_capacity(next, key, updated),
                :ok <- ServiceOperation.validate_context(context),
                true <- ServiceInvocation.current?(claim.invocation),
                do: :ok do
        :ok ->
          SessionStore.insert(model.store, :sessions, {key, updated})
          {:ok, drop_claim(model, key)}

        error ->
          {if(error == false, do: {:error, :stale_initialization_claim}, else: error), model}
      end
    else
      {:error, _reason} = error -> {error, model}
      _invalid -> {{:error, :stale_initialization_claim}, model}
    end
  end

  def apply(:append, [namespace, {id, epoch}, type, data], context, model) do
    key = {namespace, id}

    with {:ok, row} <- epoch_row(model, key, epoch),
         true <- is_binary(type) and byte_size(type) in 1..128,
         {:ok, %{wire: encoded, term: retained}} <-
           OutputCodec.prepare(%{type: type, data: data},
             codec: :protocol,
             deadline: context.deadline,
             max_frame_bytes: model.limits.max_event_bytes + 1,
             max_term_bytes: model.limits.max_event_bytes
           ),
         true <- byte_size(encoded) <= model.limits.max_event_bytes,
         true <- row.sequence < @max_sequence do
      sequence = row.sequence + 1

      event = %{
        id: cursor(epoch, sequence),
        session_id: id,
        type: retained.type,
        data: retained.data
      }

      bytes =
        max(
          byte_size(encoded) + byte_size(event.id) + byte_size(id) + 64,
          RetainedTerm.bytes({{namespace, id, epoch, sequence}, event}) + 8
        )

      events = events(model, namespace, id, epoch)
      {pending_count, pending_bytes} = PendingEvents.session_pending(model, namespace, id, epoch)
      pending = PendingEvents.stats(model)

      limits = %{
        model.limits
        | max_events_per_session: model.limits.max_events_per_session - pending_count,
          max_replay_bytes_per_session: model.limits.max_replay_bytes_per_session - pending_bytes
      }

      {evicted, _retained} = trim(events, bytes, limits)
      all = SessionStore.all(model.store, :events)
      evicted_bytes = Enum.sum(Enum.map(evicted, fn {_key, {_event, size}} -> size end))
      total_bytes = Enum.sum(Enum.map(all, fn {_key, {_event, size}} -> size end))

      floor =
        if evicted == [], do: row.evicted_through, else: elem(elem(List.last(evicted), 0), 3)

      updated = %{row | sequence: sequence, evicted_through: floor}

      cond do
        ServiceOperation.validate_context(context) != :ok ->
          {{:error, :operation_timeout}, model}

        row_capacity(model, key, updated) != :ok ->
          {{:error, :session_metadata_capacity_exhausted}, model}

        bytes + pending_bytes > model.limits.max_replay_bytes_per_session ->
          {{:error, :replay_capacity_exhausted}, model}

        length(all) - length(evicted) + pending.pending_events >= model.limits.max_events ->
          {{:error, :replay_capacity_exhausted}, model}

        total_bytes - evicted_bytes + bytes + pending.pending_event_bytes >
            model.limits.max_replay_bytes ->
          {{:error, :replay_capacity_exhausted}, model}

        true ->
          for {event_key, _event} <- evicted,
              do: SessionStore.delete(model.store, :events, event_key)

          SessionStore.insert(
            model.store,
            :events,
            {{namespace, id, epoch, sequence}, {event, bytes}}
          )

          SessionStore.insert(model.store, :sessions, {key, updated})
          {{:ok, event}, model}
      end
    else
      false ->
        {{:error, :event_too_large_or_invalid}, model}

      {:error, reason} when reason in [:invalid_output, :output_term_too_large] ->
        {{:error, :event_not_json_encodable}, model}

      error ->
        {error, model}
    end
  end

  def apply(:replay, [namespace, {id, epoch}, after_cursor, count, bytes], _context, model) do
    with {:ok, row} <- epoch_row(model, {namespace, id}, epoch),
         {:ok, after_sequence} <- decode_cursor(row, after_cursor),
         true <- is_integer(count) and count in 1..model.limits.max_replay_page_events,
         true <- is_integer(bytes) and bytes in 1..model.limits.max_replay_page_bytes do
      pending =
        Enum.filter(events(model, namespace, id, epoch), fn {key, _event} ->
          elem(key, 3) > after_sequence
        end)

      page = page(pending, count, bytes, [], 0)
      more? = length(page) < length(pending)

      if page == [] and pending != [] do
        {{:error, :replay_page_too_small}, model}
      else
        next_cursor = if page == [], do: after_cursor, else: List.last(page).id
        {{:ok, %{events: page, next_cursor: next_cursor, more?: more?}}, model}
      end
    else
      false -> {{:error, :invalid_replay_page_limits}, model}
      error -> {error, model}
    end
  end

  def apply(:get, [namespace, {id, epoch}], _context, model),
    do: {epoch_row(model, {namespace, id}, epoch), model}

  def apply(:cursor, [namespace, {id, epoch}], _context, model) do
    reply =
      with {:ok, row} <- epoch_row(model, {namespace, id}, epoch),
           do: {:ok, if(row.sequence == 0, do: nil, else: cursor(epoch, row.sequence))}

    {reply, model}
  end

  def apply(:terminate, [namespace, {id, epoch}], context, model) do
    case epoch_row(model, {namespace, id}, epoch) do
      {:ok, _row} ->
        if ServiceOperation.context_current?(context),
          do: {:ok, retire(model, {namespace, id}, epoch)},
          else: {{:error, :operation_timeout}, model}

      error ->
        {error, model}
    end
  end

  def apply(:stats, [_namespace], _context, model) do
    stats = %{
      sessions: SessionStore.info(model.store, :sessions, :size),
      metadata_bytes: metadata_bytes(model),
      request_ids: SessionStore.info(model.store, :request_ids, :size),
      request_id_bytes:
        Enum.sum(Enum.map(SessionStore.all(model.store, :request_ids), &elem(&1, 1))),
      events: SessionStore.info(model.store, :events, :size),
      replay_bytes:
        Enum.sum(
          Enum.map(SessionStore.all(model.store, :events), fn {_key, {_event, bytes}} -> bytes end)
        )
    }

    {{:ok, Map.merge(stats, PendingEvents.stats(model))}, model}
  end

  def apply(_operation, _args, _context, model),
    do: {{:error, :unsupported_session_operation}, model}

  def expire(model) do
    now = ServiceOperation.now()

    Enum.reduce(SessionStore.all(model.store, :sessions), model, fn {key, row}, model ->
      claim = model.claims[key]

      if row.expires_at <= now or
           (claim && not ServiceInvocation.current?(claim.invocation)),
         do: retire(model, key, row.epoch),
         else: model
    end)
  end

  def expire(model, deadline) do
    rows = SessionStore.all(model.store, :sessions)
    count = length(rows)
    offset = if count == 0, do: 0, else: rem(model.expiry_offset, count)

    {model, processed} =
      rows
      |> Enum.drop(offset)
      |> Enum.take(32)
      |> Enum.reduce_while({model, 0}, fn {key, row}, {model, processed} ->
        now = ServiceOperation.now()

        if now < deadline do
          claim = model.claims[key]

          expired? =
            row.expires_at <= now or
              (claim && not ServiceInvocation.current?(claim.invocation))

          model = if expired?, do: retire(model, key, row.epoch), else: model
          {:cont, {model, processed + 1}}
        else
          {:halt, {model, processed}}
        end
      end)

    model
    |> Map.put(:expiry_offset, offset + processed)
    |> PendingEvents.expire(deadline)
  end

  def info({:DOWN, monitor, :process, owner, _reason}, model) do
    model = PendingEvents.info({:DOWN, monitor, :process, owner, :retired}, model)

    case Enum.find(model.claims, fn {_key, claim} ->
           claim.monitor == monitor and claim.owner == owner
         end) do
      {key, %{epoch: epoch}} ->
        case SessionStore.lookup(model.store, :sessions, key) do
          [{^key, %{epoch: ^epoch}}] -> retire(model, key, epoch)
          _missing_or_replaced -> drop_claim(model, key)
        end

      nil ->
        model
    end
  end

  def info(_message, model), do: model

  defp retire(model, {namespace, id} = key, epoch) do
    model = PendingEvents.retire(model, namespace, id, epoch)
    SessionStore.delete(model.store, :sessions, key)

    for {event_key = {^namespace, ^id, ^epoch, _sequence}, _event} <-
          SessionStore.all(model.store, :events),
        do: SessionStore.delete(model.store, :events, event_key)

    for {claim_key = {^namespace, ^id, ^epoch, _wire_id}, _bytes} <-
          SessionStore.all(model.store, :request_ids),
        do: SessionStore.delete(model.store, :request_ids, claim_key)

    drop_claim(model, key)
  end

  defp drop_claim(model, key) do
    case Map.pop(model.claims, key) do
      {nil, _claims} ->
        model

      {claim, claims} ->
        Process.demonitor(claim.monitor, [:flush])
        %{model | claims: claims}
    end
  end

  defp row(model, key) do
    case SessionStore.lookup(model.store, :sessions, key) do
      [{^key, row}] ->
        claim = model.claims[key]

        if row.expires_at > ServiceOperation.now() and
             (is_nil(claim) or ServiceInvocation.current?(claim.invocation)),
           do: {:ok, row},
           else: {:error, :session_not_found}

      _missing ->
        {:error, :session_not_found}
    end
  end

  defp epoch_row(model, key, epoch) do
    case row(model, key) do
      {:ok, %{epoch: ^epoch} = row} -> {:ok, row}
      _invalid -> {:error, :stale_session_lease}
    end
  end

  defp identity_matches?(bound, supplied),
    do:
      is_map(supplied) and Enum.all?(@identity, &(Map.get(bound, &1) == Map.get(supplied, &1))) and
        transport_identity_matches?(bound, supplied)

  # Trusted addressed application calls retain their existing metadata-free
  # lookup. Every HTTP path supplies this private field before store access.
  defp transport_identity_matches?(bound, supplied) do
    case Map.fetch(supplied, :transport_endpoint) do
      :error ->
        true

      {:ok, endpoint} ->
        valid_transport_metadata?(supplied) and Map.get(bound, :transport_endpoint) == endpoint
    end
  end

  defp valid_transport_metadata?(metadata) do
    case Map.fetch(metadata, :transport_endpoint) do
      :error ->
        true

      {:ok, value} ->
        is_binary(value) and byte_size(value) in 1..4_096 and String.starts_with?(value, "/")
    end
  end

  defp ensure_identity(bound, supplied) do
    if identity_matches?(bound, supplied),
      do: :ok,
      else: {:error, :session_identity_mismatch}
  end

  defp ensure_initialized(_row, false), do: :ok
  defp ensure_initialized(%{initialized: true}, true), do: :ok
  defp ensure_initialized(_row, _required), do: {:error, :session_not_initialized}

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128

  defp row_capacity(model, key, row) do
    size = RetainedTerm.bytes({key, row})

    previous =
      case SessionStore.lookup(model.store, :sessions, key) do
        [{^key, old}] -> RetainedTerm.bytes({key, old})
        [] -> 0
      end

    growth = PendingEvents.metadata_growth(model, key, row)

    if size + growth <= model.limits.max_session_metadata_bytes and
         metadata_bytes(model) - previous + size +
           PendingEvents.metadata_growth(model, key, row, :all) <= model.limits.max_metadata_bytes,
       do: :ok,
       else: {:error, :session_metadata_capacity_exhausted}
  end

  defp metadata_bytes(model),
    do:
      Enum.sum(Enum.map(SessionStore.all(model.store, :sessions), &RetainedTerm.bytes/1)) +
        Enum.sum(Enum.map(model.claims, &RetainedTerm.bytes/1))

  defp events(model, namespace, id, epoch),
    do:
      SessionStore.all(model.store, :events)
      |> Enum.filter(fn {{ns, sid, ep, _sequence}, _event} ->
        {ns, sid, ep} == {namespace, id, epoch}
      end)
      |> Enum.sort_by(fn {key, _event} -> elem(key, 3) end)

  defp trim(events, new_bytes, limits) do
    used = Enum.sum(Enum.map(events, fn {_key, {_event, bytes}} -> bytes end))
    trim(events, [], used, new_bytes, limits)
  end

  defp trim([event | rest] = events, evicted, used, bytes, limits) do
    if length(events) >= limits.max_events_per_session or
         used + bytes > limits.max_replay_bytes_per_session,
       do: trim(rest, [event | evicted], used - elem(elem(event, 1), 1), bytes, limits),
       else: {Enum.reverse(evicted), events}
  end

  defp trim([], evicted, _used, _bytes, _limits), do: {Enum.reverse(evicted), []}
  defp cursor(epoch, sequence), do: epoch <> ":" <> Integer.to_string(sequence)
  defp decode_cursor(_row, nil), do: {:ok, 0}

  defp decode_cursor(row, value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [epoch, number] when epoch == row.epoch ->
        case Integer.parse(number) do
          {sequence, ""} when sequence > 0 and sequence <= row.evicted_through ->
            {:error, :cursor_evicted}

          {sequence, ""} when sequence > 0 and sequence <= row.sequence ->
            if cursor(epoch, sequence) == value,
              do: {:ok, sequence},
              else: {:error, :unknown_cursor}

          _invalid ->
            {:error, :unknown_cursor}
        end

      [_epoch, _number] ->
        {:error, :foreign_cursor}

      _invalid ->
        {:error, :unknown_cursor}
    end
  end

  defp decode_cursor(_row, _value), do: {:error, :unknown_cursor}

  defp page([{_key, {event, bytes}} | rest], count, limit, result, used)
       when length(result) < count and used + bytes <= limit,
       do: page(rest, count, limit, [event | result], used + bytes)

  defp page(_remaining, _count, _limit, result, _used), do: Enum.reverse(result)

  defp claim_matches_session?(claim, {namespace, id}, epoch),
    do: ServiceInvocation.matches_session?(claim.invocation, namespace, id, epoch)
end
