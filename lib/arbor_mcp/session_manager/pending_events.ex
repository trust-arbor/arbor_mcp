defmodule Arbor.MCP.SessionManager.PendingEvents do
  @moduledoc false

  alias Arbor.MCP.Internal.SessionStore

  alias Arbor.MCP.Server.Runtime.{
    HTTPWriterRegistry,
    OutputCodec,
    OutputTicket,
    RetainedTerm,
    ServiceOperation,
    ServiceRef
  }

  alias Arbor.MCP.SessionManager.{EventTicket, RuntimeStore, SessionLease}

  # Pending events share the visible replay pool. Credits include the entire
  # prospective row, native data, encoded wire, handles and maximal monitors.
  # No eviction or replay publication happens before state commit.
  def apply(:prepare_event, [namespace, {id, epoch}, source, wire, group?], context, model) do
    key = {namespace, id, epoch, source.token}
    previous = model.pending_events[key]

    with :ok <- prepare_source(source, context, namespace, id, epoch),
         {:ok, row} <- RuntimeStore.event_row(model, {namespace, id}, epoch),
         true <- row.sequence < RuntimeStore.max_sequence(),
         true <- group? == source.group,
         {:ok, members} <- members(previous, source, wire),
         {:ok, payload} <- payload(members, group?, source.deadline, model.limits),
         entry = candidate(key, source, context, members, payload),
         :ok <- capacity(model, key, entry),
         reserved = %{model | pending_events: Map.put(model.pending_events, key, entry)},
         :ok <- RuntimeStore.event_row_capacity(reserved, {namespace, id}, row),
         :ok <- ServiceOperation.validate_context(context),
         true <- HTTPWriterRegistry.event_source_current?(source) do
      entry = monitor(entry)
      model = drop(model, key, 2)
      model = %{model | pending_events: Map.put(model.pending_events, key, entry)}
      {{:ok, ticket(context.runtime, entry)}, model}
    else
      false -> {{:error, :invalid_session_event_origin}, model}
      error -> {error, model}
    end
  end

  def apply(:event_current, [_namespace, ticket], context, model) do
    valid =
      case find(model, ticket) do
        {_key, entry} ->
          context.owner in [
            entry.owner,
            entry.source.producer,
            entry.source.controller,
            entry.source.scheduler
          ] and
            ServiceOperation.context_current?(context) and current?(entry)

        nil ->
          false
      end

    {valid, model}
  end

  def apply(:handoff_event, [_namespace, ticket], context, model) do
    case find(model, ticket) do
      {key, %{stage: :prepared, owner: owner} = entry} when owner == context.owner ->
        if ServiceOperation.context_current?(context) and current?(entry) do
          Process.demonitor(entry.monitor, [:flush])
          owner = entry.source.controller
          next = %{entry | owner: owner, monitor: Process.monitor(owner), stage: :held}
          {:ok, %{model | pending_events: Map.put(model.pending_events, key, next)}}
        else
          {{:error, :session_event_retired}, model}
        end

      _invalid ->
        {{:error, :invalid_session_event_owner}, model}
    end
  end

  def apply(:finalize_event, [_namespace, token, primary], context, model) do
    found = Enum.find(model.pending_events, fn {_key, entry} -> entry.token == token end)

    case found do
      {key, %{stage: :held, source: %{group: true}} = entry} ->
        with true <- context.owner == entry.source.controller,
             true <- current?(entry),
             true <-
               Enum.all?(entry.members, fn {_id, _wire, phase, _initialization} ->
                 :atomics.get(phase, 1) == 2
               end),
             true <-
               HTTPWriterRegistry.event_publication_authorized?(
                 entry.source,
                 primary,
                 context.owner
               ),
             :ok <- ServiceOperation.validate_context(context) do
          next = %{entry | version: make_ref(), primary: OutputTicket.identity(primary)}
          model = %{model | pending_events: Map.put(model.pending_events, key, next)}
          {{:ok, ticket(context.runtime, next)}, model}
        else
          _invalid -> {{:error, :invalid_session_event_aggregate}, model}
        end

      _invalid ->
        {{:error, :invalid_session_event_aggregate}, model}
    end
  end

  def apply(:publish_event, [_namespace, ticket, primary], context, model) do
    case find(model, ticket) do
      {key = {namespace, id, epoch, _source}, %{stage: :held} = entry} ->
        with true <- context.owner == entry.source.writer,
             true <- current?(entry),
             true <- entry.primary == OutputTicket.identity(primary),
             true <-
               HTTPWriterRegistry.event_publication_authorized?(
                 entry.source,
                 primary,
                 context.owner
               ),
             {:ok, row} <- RuntimeStore.event_row(model, {namespace, id}, epoch),
             true <- row.sequence < RuntimeStore.max_sequence(),
             :ok <- initialization_settled(entry, row),
             sequence = row.sequence + 1,
             updated = %{row | sequence: sequence},
             :ok <- RuntimeStore.event_row_capacity(model, {namespace, id}, updated),
             event = %{
               id: epoch <> ":" <> Integer.to_string(sequence),
               session_id: id,
               type: entry.payload.term.type,
               data: entry.payload.term.data
             },
             bytes = event_bytes(namespace, id, epoch, sequence, event, entry.payload.wire),
             true <- bytes <= entry.bytes,
             :ok <- ServiceOperation.validate_context(context),
             true <-
               HTTPWriterRegistry.event_publication_authorized?(
                 entry.source,
                 primary,
                 context.owner
               ),
             :ok <- enter_publication(entry) do
          SessionStore.insert(
            model.store,
            :events,
            {{namespace, id, epoch, sequence}, {event, bytes}}
          )

          SessionStore.insert(model.store, :sessions, {{namespace, id}, updated})
          :atomics.put(entry.receipt, 1, 1)
          {{:ok, event}, drop(model, key, 1)}
        else
          {:error, :session_initialization_unsettled} = error -> {error, model}
          _invalid -> {{:error, :session_event_retired}, model}
        end

      _invalid ->
        if EventTicket.receipt(ticket) == 1,
          do: {{:error, :session_event_already_published}, model},
          else: {{:error, :session_event_retired}, model}
    end
  end

  def apply(:release_event, [_namespace, ticket], context, model) do
    case find(model, ticket) do
      {key, entry} ->
        cond do
          :atomics.get(entry.receipt, 1) == 3 ->
            {{:error, :session_event_durability_unconfirmed}, model}

          context.owner in [
            entry.owner,
            entry.source.producer,
            entry.source.controller,
            entry.source.scheduler
          ] ->
            {:ok, drop(model, key, 2)}

          true ->
            {{:error, :invalid_session_event_owner}, model}
        end

      nil ->
        {:ok, model}
    end
  end

  def info({:DOWN, monitor, :process, owner, _reason}, model) do
    Enum.reduce(model.pending_events, model, fn {key, entry}, model ->
      owned? = entry.monitor == monitor and entry.owner == owner

      if owned? and :atomics.get(entry.receipt, 1) != 3,
        do: drop(model, key, 2),
        else: model
    end)
  end

  def info(_message, model), do: model

  def expire(model, deadline) do
    entries = Map.to_list(model.pending_events)
    offset = if entries == [], do: 0, else: rem(model.pending_event_offset, length(entries))

    {model, processed} =
      entries
      |> Enum.drop(offset)
      |> Enum.take(32)
      |> Enum.reduce_while({model, 0}, fn {key, entry}, {model, processed} ->
        if ServiceOperation.now() < deadline do
          next =
            if not current?(entry) and :atomics.get(entry.receipt, 1) != 3,
              do: drop(model, key, 2),
              else: model

          {:cont, {next, processed + 1}}
        else
          {:halt, {model, processed}}
        end
      end)

    %{model | pending_event_offset: offset + processed}
  end

  def retire(model, namespace, id, epoch) do
    Enum.reduce(model.pending_events, model, fn {key = {ns, sid, ep, _}, entry}, model ->
      if {ns, sid, ep} == {namespace, id, epoch} and :atomics.get(entry.receipt, 1) != 3,
        do: drop(model, key, 2),
        else: model
    end)
  end

  # A pending event reserves the largest finite cursor representation once
  # per session, independently of the replay pool's term/wire accounting.
  def metadata_growth(model, key, row) do
    if Enum.any?(model.pending_events, fn {{ns, id, epoch, _}, _entry} ->
         {ns, id} == key and epoch == row.epoch
       end),
       do:
         max(
           0,
           RetainedTerm.bytes({key, %{row | sequence: RuntimeStore.max_sequence()}}) -
             RetainedTerm.bytes({key, row})
         ),
       else: 0
  end

  def metadata_growth(model, key, row, :all) do
    SessionStore.all(model.store, :sessions)
    |> Enum.reject(fn {other, _} -> other == key end)
    |> Enum.reduce(metadata_growth(model, key, row), fn {other, value}, total ->
      total + metadata_growth(model, other, value)
    end)
  end

  def close(model) do
    Enum.each(model.pending_events, fn {_key, entry} ->
      if :atomics.get(entry.receipt, 1) == 0, do: :atomics.put(entry.receipt, 1, 2)
      Process.demonitor(entry.monitor, [:flush])
    end)

    model
  end

  def stats(model),
    do: %{
      pending_events: map_size(model.pending_events),
      pending_event_bytes: pending_bytes(model)
    }

  def pending_bytes(model),
    do: Enum.sum(Enum.map(model.pending_events, fn {_key, entry} -> entry.bytes end))

  def session_pending(model, namespace, id, epoch) do
    entries = for {{^namespace, ^id, ^epoch, _}, entry} <- model.pending_events, do: entry
    {length(entries), Enum.sum(Enum.map(entries, & &1.bytes))}
  end

  defp prepare_source(source, context, namespace, id, epoch) do
    with true <- source.runtime == context.runtime and source.producer == context.owner,
         true <- HTTPWriterRegistry.event_preparation_authorized?(source, context.owner),
         service = ServiceRef.new(context.runtime, :sessions),
         {:ok, {^id, ^epoch}} <- SessionLease.validate(source.lease, service, :sessions),
         {:ok, binding} <- Arbor.MCP.Server.Runtime.Services.resolve(service, :sessions),
         true <- namespace == (binding.namespace || "owned"),
         do: :ok,
         else: (_invalid -> {:error, :invalid_session_event_origin})
  end

  defp members(nil, source, wire) when is_binary(wire),
    do: {:ok, [{source.primary, :binary.copy(wire), source.phase, source.initialization}]}

  defp members(previous, source, wire) do
    cond do
      not source.group or not same_source?(previous.source, source) ->
        {:error, :invalid_session_event_group}

      Enum.any?(previous.members, fn {id, _wire, _phase, _initialization} ->
        id == source.primary
      end) ->
        {:error, :duplicate_session_event_member}

      Enum.any?(previous.members, fn {_id, _wire, phase, _initialization} ->
        :atomics.get(phase, 1) != 2
      end) ->
        {:error, :uncommitted_session_event_member}

      true ->
        {:ok,
         previous.members ++
           [{source.primary, :binary.copy(wire), source.phase, source.initialization}]}
    end
  end

  defp same_source?(left, right),
    do:
      Map.take(left, [
        :runtime,
        :binding,
        :token,
        :generation,
        :scope,
        :owner,
        :controller,
        :scheduler,
        :writer,
        :lease,
        :deadline
      ]) ==
        Map.take(right, [
          :runtime,
          :binding,
          :token,
          :generation,
          :scope,
          :owner,
          :controller,
          :scheduler,
          :writer,
          :lease,
          :deadline
        ])

  defp payload(members, group?, deadline, limits) do
    wire =
      if group?,
        do:
          IO.iodata_to_binary(["[", Enum.intersperse(Enum.map(members, &elem(&1, 1)), ","), "]"]),
        else: members |> hd() |> elem(1)

    with true <- byte_size(wire) <= limits.max_event_bytes,
         {:ok, data} <- Jason.decode(wire),
         {:ok, payload} <-
           OutputCodec.prepare(%{type: "message", data: data},
             codec: :protocol,
             deadline: deadline,
             max_frame_bytes: limits.max_event_bytes + 1,
             max_term_bytes: limits.max_event_bytes
           ),
         true <- byte_size(payload.wire) <= limits.max_event_bytes,
         do: {:ok, payload},
         else: (_invalid -> {:error, :event_too_large_or_invalid})
  end

  defp candidate(key, source, context, members, payload) do
    entry = %{
      token: make_ref(),
      version: make_ref(),
      receipt: :atomics.new(1, signed: false),
      service_generation: context.generation,
      source: source,
      primary: source.primary,
      owner: context.owner,
      monitor: nil,
      stage: :prepared,
      members: members,
      payload: payload,
      bytes: 0
    }

    # Store cursor and index overhead is reserved before any publication.
    largest = %{entry | monitor: make_ref(), owner: source.controller, stage: :held}
    bytes = RetainedTerm.bytes({key, largest}) + byte_size(payload.wire) + 512
    %{entry | bytes: bytes}
  end

  defp capacity(model, {namespace, id, epoch, _} = key, entry) do
    pending = Map.delete(model.pending_events, key)
    retained = SessionStore.all(model.store, :events)
    session = for {{^namespace, ^id, ^epoch, _}, {_event, bytes}} <- retained, do: bytes
    pending_session = for {{^namespace, ^id, ^epoch, _}, item} <- pending, do: item.bytes
    all_pending = Enum.sum(Enum.map(pending, fn {_key, item} -> item.bytes end))
    visible_bytes = Enum.sum(Enum.map(retained, fn {_key, {_event, bytes}} -> bytes end))

    if length(retained) + map_size(pending) + 1 <= model.limits.max_events and
         length(session) + length(pending_session) + 1 <= model.limits.max_events_per_session and
         visible_bytes + all_pending + entry.bytes <= model.limits.max_replay_bytes and
         Enum.sum(session) + Enum.sum(pending_session) + entry.bytes <=
           model.limits.max_replay_bytes_per_session,
       do: :ok,
       else: {:error, :replay_capacity_exhausted}
  end

  defp current?(entry),
    do:
      Process.alive?(entry.owner) and HTTPWriterRegistry.event_source_current?(entry.source) and
        :atomics.get(entry.receipt, 1) == 0

  defp find(model, ticket),
    do:
      Enum.find(model.pending_events, fn {_key, entry} -> EventTicket.matches?(ticket, entry) end)

  defp monitor(entry), do: %{entry | monitor: Process.monitor(entry.owner)}

  defp drop(model, key, receipt) do
    case Map.pop(model.pending_events, key) do
      {nil, _pending} ->
        model

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        :atomics.put(entry.receipt, 1, receipt)
        %{model | pending_events: pending}
    end
  end

  defp ticket(runtime, entry),
    do:
      EventTicket.new(
        ServiceRef.new(runtime, :sessions),
        entry.service_generation,
        entry.token,
        entry.version,
        entry.receipt,
        entry.source.deadline
      )

  defp initialization_settled(entry, row) do
    valid? =
      Enum.all?(entry.members, fn
        {_identity, wire, _phase, true} ->
          case Jason.decode(wire) do
            {:ok, %{"error" => _error}} ->
              true

            {:ok, %{"result" => %{"protocolVersion" => version}}} ->
              row.initialized and is_binary(version) and row.protocol_version == version

            _invalid ->
              false
          end

        _ordinary ->
          true
      end)

    if valid?, do: :ok, else: {:error, :session_initialization_unsettled}
  end

  defp enter_publication(entry),
    do:
      if(:atomics.compare_exchange(entry.receipt, 1, 0, 3) == :ok,
        do: :ok,
        else: {:error, :session_event_already_published}
      )

  defp event_bytes(namespace, id, epoch, sequence, event, encoded),
    do:
      max(
        byte_size(encoded) + byte_size(event.id) + byte_size(id) + 64,
        RetainedTerm.bytes({{namespace, id, epoch, sequence}, event}) + 8
      )
end
