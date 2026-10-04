defmodule Arbor.MCP.Server.Runtime.OutputLedger do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Initialization, OutputCodec, OutputTicket}

  @enforce_keys [:pid, :table, :generation, :owner, :limits]
  defstruct [:pid, :table, :generation, :owner, :limits]

  @opaque t :: %__MODULE__{
            pid: pid(),
            table: :ets.tid(),
            generation: reference(),
            owner: pid(),
            limits: map()
          }
  @type error :: {:error, atom()}
  @reap_ms 20
  @defaults [
    max_frame_bytes: 1_048_576,
    max_term_bytes: 1_048_576,
    max_output_bytes: 4_194_304,
    max_output_frames: 128,
    max_scope_bytes: 65_536,
    call_timeout_ms: 5_000
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      Keyword.put_new(opts, :owner, self()),
      Keyword.take(opts, [:timeout])
    )
  end

  @spec ref(pid()) :: {:ok, t()} | error()
  def ref(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, {__MODULE__, :reference}, 0) do
          {_, reference} -> validate(reference)
          _ -> {:error, :output_unavailable}
        end

      _ ->
        {:error, :output_unavailable}
    end
  end

  def ref(_), do: {:error, :output_unavailable}

  @spec open_scope(t(), term(), integer() | nil) :: :ok | error()
  def open_scope(ref, scope, deadline \\ nil) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         :ok <- scope_deadline_valid(deadline),
         do: invoke(ref, {:scope, scope}, {:open_scope, scope, deadline}, deadline)
  end

  @spec prepare(t(), term(), keyword()) :: {:ok, OutputTicket.t()} | error()
  def prepare(%__MODULE__{} = ref, term, opts) do
    scope = Keyword.get(opts, :scope)
    owner = Keyword.get(opts, :owner, ref.owner)
    deadline = Keyword.get(opts, :deadline)

    with {:ok, _} <- validate(ref),
         true <- Keyword.has_key?(opts, :scope) || {:error, :invalid_output_scope},
         :ok <- scope_valid(scope),
         :ok <- pid_valid(owner),
         :ok <- deadline_valid(deadline),
         {:ok, gate} <- read(ref),
         :ok <- preparable(gate.scopes[scope]),
         {:ok, payload} <-
           OutputCodec.prepare(term,
             max_frame_bytes: ref.limits.max_frame_bytes,
             max_term_bytes: ref.limits.max_term_bytes,
             deadline: deadline,
             codec: Keyword.get(opts, :codec, :json)
           ),
         token = make_ref(),
         entry = %{
           token: token,
           scope: scope,
           owner: owner,
           producer: self(),
           deadline: deadline,
           stage: :candidate,
           confirmed: false,
           monitor: nil,
           consumer: nil,
           sequence: nil,
           group: Keyword.get(opts, :group, false),
           term_bytes: payload.term_bytes,
           wire_bytes: payload.wire_bytes,
           bytes: payload.bytes,
           payload: nil
         },
         bytes =
           payload.bytes * if(entry.group, do: 2, else: 1) + if(entry.group, do: 64, else: 32) +
             entry_metadata_bytes(entry),
         entry = %{entry | bytes: bytes},
         :ok <- claim(ref, entry) do
      case store_prepared(ref, token, payload) do
        :ok ->
          case invoke(ref, {:ticket, token}, {:confirm, token}, deadline) do
            :ok ->
              {:ok, ticket(ref, token, scope)}

            error ->
              # The actor may have confirmed just as its call alias expired.
              # Reaping an explicit cancellation also removes actor monitors.
              change_entry(ref, token, &%{&1 | deadline: now()}, min(deadline, now() + 10))
              error
          end

        error ->
          abandon(ref, token)
          error
      end
    end
  rescue
    ArgumentError -> {:error, :output_unavailable}
  end

  @spec publish(OutputTicket.t()) :: :ok | error()
  def publish(ticket), do: ticket_operation(ticket, :publish)
  @spec handoff(OutputTicket.t()) :: :ok | error()
  def handoff(ticket), do: ticket_operation(ticket, :handoff)
  @spec hold(OutputTicket.t()) :: :ok | error()
  def hold(ticket), do: ticket_operation(ticket, :hold)
  @spec value(OutputTicket.t()) :: {:ok, term()} | error()
  def value(ticket), do: ticket_operation(ticket, :value)
  @spec payload(OutputTicket.t()) :: {:ok, OutputTicket.t(), term(), binary() | nil} | error()
  def payload(ticket), do: ticket_operation(ticket, :payload)

  def discard_hidden(ref, scope) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         do: invoke(ref, {:scope, scope}, {:discard_hidden, scope})
  end

  @spec finish_group(t(), term()) :: {:ok, OutputTicket.t()} | error()
  def finish_group(ref, scope) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         do: invoke(ref, {:scope, scope}, {:finish_group, scope})
  end

  @spec release(OutputTicket.t()) :: :ok | error()
  def release(ticket), do: ticket_operation(ticket, :release)
  @spec ack(OutputTicket.t()) :: :ok | error()
  def ack(ticket), do: ticket_operation(ticket, :ack)

  @spec subscribe(t(), term(), pid()) :: :ok | error()
  def subscribe(ref, scope, consumer) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         :ok <- pid_valid(consumer),
         :ok <- known_scope(ref, scope),
         do: invoke(ref, {:scope, scope}, {:subscribe, scope, consumer})
  end

  @spec checkout(t(), term()) ::
          :empty | {:ok, OutputTicket.t(), term(), binary() | nil} | error()
  def checkout(ref, scope) do
    with {:ok, _} <- validate(ref),
         :ok <- scope_valid(scope),
         do: invoke(ref, {:scope, scope}, {:checkout, scope})
  end

  @spec begin_drain(t(), term(), integer()) :: :ok | error()
  def begin_drain(ref, scope, deadline) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         :ok <- deadline_valid(deadline),
         do: invoke(ref, {:scope, scope}, {:begin_drain, scope, deadline})
  end

  @spec seal(t(), term()) :: :ok | error()
  def seal(ref, scope) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         do: invoke(ref, {:scope, scope}, {:seal, scope})
  end

  @spec retire_scope(t(), term(), atom()) :: :ok | error()
  def retire_scope(ref, scope, reason \\ :connection_closed) do
    with :ok <- owner_valid(ref),
         :ok <- scope_valid(scope),
         true <-
           (is_atom(reason) and :erlang.external_size(reason) <= 64) || {:error, :invalid_reason},
         do: invoke(ref, {:scope, scope}, {:retire, scope, reason})
  end

  @spec reset_generation(t(), reference()) :: {:ok, t()} | error()
  def reset_generation(ref, generation) do
    with :ok <- owner_valid(ref),
         true <-
           (is_reference(generation) and generation != ref.generation) ||
             {:error, :invalid_generation},
         do: invoke(ref, :generation, {:reset, generation})
  end

  @spec drained?(t(), term()) :: boolean() | error()
  def drained?(ref, scope) do
    with {:ok, gate} <- read(ref),
         :ok <- scope_valid(scope),
         do: not Enum.any?(gate.claims, fn {_, entry} -> entry.scope == scope end)
  end

  @spec stats(t()) :: map() | error()
  def stats(ref) do
    with {:ok, gate} <- read(ref) do
      stages = Enum.frequencies_by(Map.values(gate.claims), & &1.stage)

      %{
        frames: gate.frames,
        bytes: gate.bytes,
        prepared: Map.get(stages, :prepared, 0),
        candidates: Map.get(stages, :candidate, 0),
        queued: Map.get(stages, :queued, 0),
        in_flight: Map.get(stages, :in_flight, 0),
        scopes: map_size(gate.scopes),
        metadata_bytes: metadata_bytes(gate),
        pending_controls: map_size(gate.pending),
        generation: gate.generation
      }
    end
  end

  @impl true
  def init(opts) do
    limits = Map.new(@defaults, fn {key, value} -> {key, Keyword.get(opts, key, value)} end)
    owner = Keyword.fetch!(opts, :owner)
    generation = Keyword.get(opts, :generation, make_ref())

    with :ok <- watch_runtime(opts),
         :ok <- pid_valid(owner),
         true <- is_reference(generation) || {:error, :invalid_generation},
         true <-
           (Enum.all?(limits, fn {_, n} -> is_integer(n) and n > 0 end) and
              limits.max_scope_bytes >= metadata_bytes(%{scopes: %{}, pending: %{}})) ||
             {:error, :invalid_output_limits} do
      table = :ets.new(__MODULE__, [:public, :set, read_concurrency: true])

      ref = %__MODULE__{
        pid: self(),
        table: table,
        generation: generation,
        owner: owner,
        limits: limits
      }

      :ets.insert(
        table,
        {:gate,
         %{generation: generation, frames: 0, bytes: 0, claims: %{}, scopes: %{}, pending: %{}}}
      )

      Process.put({__MODULE__, :reference}, ref)
      Process.send_after(self(), :reap, @reap_ms)
      {:ok, %{ref: ref, owner_monitor: Process.monitor(owner), monitors: %{}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp watch_runtime(opts) do
    case Keyword.get(opts, :runtime_table) do
      nil -> :ok
      table -> Initialization.watch(table, self())
    end
  end

  @impl true
  def handle_call({:operation, id}, {caller, _}, state) do
    case pending(state.ref, id) do
      {key, %{producer: ^caller, deadline: deadline, request: request}}
      when is_integer(deadline) ->
        {reply, state} =
          if deadline > now() and Process.alive?(caller),
            do: within_control_deadline(deadline, fn -> operate(request, caller, state) end),
            else: {{:error, :output_call_expired}, state}

        clear_pending(state.ref, key, id)
        {:reply, reply, state}

      _ ->
        {:reply, {:error, :output_call_expired}, state}
    end
  end

  @impl true
  def handle_info(:reap, state) do
    {:ok, gate} = read(state.ref)

    state =
      Enum.reduce(gate.claims, state, fn {token, entry}, state ->
        reap_claim(token, entry, state)
      end)

    {:ok, gate} = read(state.ref)

    state =
      Enum.reduce(gate.scopes, state, fn {scope, info}, state ->
        if is_integer(info.deadline) and info.deadline <= now(),
          do:
            elem(
              retire(
                scope,
                if(info.mode == :open, do: :output_expired, else: :drain_timeout),
                state
              ),
              1
            ),
          else: state
      end)

    update(state.ref, fn gate ->
      pending =
        Map.reject(gate.pending, fn {_, item} ->
          item.deadline <= now() or not Process.alive?(item.producer)
        end)

      {:ok, %{gate | pending: pending}, :ok}
    end)

    {:ok, gate} = read(state.ref)
    state = Enum.reduce(Map.keys(gate.scopes), state, &wake(&1, &2))
    Process.send_after(self(), :reap, @reap_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    state =
      case Map.get(state.monitors, monitor) do
        {:ticket, token} ->
          case entry(state.ref, token) do
            {:ok, %{stage: stage, scope: scope}} when stage in [:held, :queued, :in_flight] ->
              elem(retire(scope, :output_owner_down, state), 1)

            _ ->
              drop(token, state)
          end

        {:scope, scope} ->
          elem(retire(scope, :consumer_down, state), 1)

        _ ->
          state
      end

    {:noreply, state}
  end

  defp operate({:confirm, token}, producer, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- entry.producer == producer,
         :ok <- live_entry(entry),
         true <- entry.stage == :prepared do
      monitor = Process.monitor(producer)

      case change_entry(state.ref, token, &%{&1 | confirmed: true, monitor: monitor}) do
        :ok ->
          {:ok, %{state | monitors: Map.put(state.monitors, monitor, {:ticket, token})}}

        error ->
          Process.demonitor(monitor, [:flush])
          {error, state}
      end
    else
      _ -> {{:error, :output_expired}, drop(token, state)}
    end
  end

  defp operate({:publish, token}, caller, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- entry.owner == caller,
         :ok <- live_entry(entry),
         {:ok, gate} <- read(state.ref),
         :ok <- publishable(gate.scopes[entry.scope]) do
      if entry.stage in [:queued, :in_flight] do
        {:ok, state}
      else
        if entry.confirmed and entry.stage == :prepared do
          monitor = Process.monitor(entry.owner)

          result =
            update(state.ref, fn gate ->
              entry = %{
                gate.claims[token]
                | stage: :queued,
                  monitor: monitor,
                  sequence: System.unique_integer([:positive, :monotonic])
              }

              {:ok, %{gate | claims: Map.put(gate.claims, token, entry)}, :ok}
            end)

          if result == :ok do
            state = demonitor(entry.monitor, state)
            state = %{state | monitors: Map.put(state.monitors, monitor, {:ticket, token})}
            {:ok, wake(entry.scope, state)}
          else
            Process.demonitor(monitor, [:flush])
            {result, state}
          end
        else
          {{:error, :output_not_prepared}, state}
        end
      end
    else
      false -> {{:error, :invalid_output_owner}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp operate({:handoff, token}, caller, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- entry.producer == caller and entry.stage == :prepared and entry.confirmed,
         :ok <- live_entry(entry) do
      monitor = Process.monitor(entry.owner)
      result = change_entry(state.ref, token, &%{&1 | producer: entry.owner, monitor: monitor})

      if result == :ok do
        state = demonitor(entry.monitor, state)
        {:ok, %{state | monitors: Map.put(state.monitors, monitor, {:ticket, token})}}
      else
        Process.demonitor(monitor, [:flush])
        {result, state}
      end
    else
      false -> {{:error, :invalid_output_owner}, state}
      error -> {error, state}
    end
  end

  defp operate({:hold, token}, caller, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- entry.owner == caller and entry.group and entry.stage == :prepared,
         :ok <- live_entry(entry) do
      {change_entry(
         state.ref,
         token,
         &%{&1 | stage: :held, sequence: System.unique_integer([:positive, :monotonic])}
       ), state}
    else
      false -> {{:error, :invalid_output_owner}, state}
      error -> {error, state}
    end
  end

  defp operate({:value, token}, caller, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- caller in [entry.owner, state.ref.owner],
         :ok <- live_entry(entry) do
      {{:ok, entry.payload.term}, state}
    else
      false -> {{:error, :invalid_output_owner}, state}
      error -> {error, state}
    end
  end

  defp operate({:payload, token}, caller, state) do
    with {:ok, entry} <- entry(state.ref, token),
         true <- entry.stage == :in_flight and entry.consumer == caller,
         :ok <- live_entry(entry) do
      {{:ok, ticket(state.ref, token, entry.scope), entry.payload.term, entry.payload.wire},
       state}
    else
      false -> {{:error, :invalid_output_owner}, state}
      error -> {error, state}
    end
  end

  defp operate({:finish_group, scope}, caller, state) do
    with true <- caller == state.ref.owner,
         {:ok, gate} <- read(state.ref),
         :ok <- publishable(gate.scopes[scope]),
         entries = gate.claims |> Map.values() |> Enum.filter(&(&1.scope == scope)),
         true <- entries != [] and Enum.all?(entries, &(&1.stage == :held)),
         true <- Enum.all?(entries, &(live_entry(&1) == :ok)) do
      entries = Enum.sort_by(entries, & &1.sequence)
      term = Enum.map(entries, & &1.payload.term)

      wire =
        IO.iodata_to_binary([
          "[",
          Enum.intersperse(Enum.map(entries, & &1.payload.wire), ","),
          "]"
        ])

      term_bytes = :erlang.external_size(term)

      payload = %{
        term: term,
        wire: wire,
        term_bytes: term_bytes,
        wire_bytes: byte_size(wire) + 1,
        bytes: term_bytes + byte_size(wire) + 1
      }

      token = make_ref()
      monitor = Process.monitor(caller)

      aggregate = %{
        hd(entries)
        | token: token,
          owner: caller,
          producer: caller,
          deadline: Enum.min(Enum.map(entries, & &1.deadline)),
          stage: :queued,
          monitor: monitor,
          group: false,
          payload: payload,
          term_bytes: term_bytes,
          wire_bytes: payload.wire_bytes,
          bytes: payload.bytes + 32 + entry_metadata_bytes(hd(entries))
      }

      result =
        update(
          state.ref,
          fn current ->
            if Enum.all?(entries, &(current.claims[&1.token] == &1)) and
                 aggregate.deadline > now() and
                 aggregate.bytes <= Enum.sum(Enum.map(entries, & &1.bytes)) do
              current = Enum.reduce(entries, current, &remove_claim(&2, &1.token))

              {:ok,
               %{
                 current
                 | frames: current.frames + 1,
                   bytes: current.bytes + aggregate.bytes,
                   claims: Map.put(current.claims, token, aggregate)
               }, :ok}
            else
              {:error, :output_expired}
            end
          end,
          aggregate.deadline
        )

      if result == :ok do
        state = Enum.reduce(entries, state, &demonitor(&1.monitor, &2))
        state = %{state | monitors: Map.put(state.monitors, monitor, {:ticket, token})}
        {{:ok, ticket(state.ref, token, scope)}, wake(scope, state)}
      else
        Process.demonitor(monitor, [:flush])
        {result, state}
      end
    else
      false -> {{:error, :output_group_incomplete}, state}
      error -> {error, state}
    end
  end

  defp operate({:discard_hidden, scope}, caller, state) do
    if caller == state.ref.owner do
      {:ok, gate} = read(state.ref)

      hidden =
        gate.claims
        |> Map.values()
        |> Enum.filter(&(&1.scope == scope and &1.stage in [:candidate, :prepared]))

      {:ok, Enum.reduce(hidden, state, &drop(&1.token, &2))}
    else
      {{:error, :invalid_output_owner}, state}
    end
  end

  defp operate({operation, token}, caller, state) when operation in [:release, :ack] do
    case entry(state.ref, token) do
      {:error, :output_released} ->
        {:ok, state}

      {:ok, entry} ->
        permitted =
          if operation == :ack,
            do: entry.stage == :in_flight and entry.consumer == caller,
            else:
              caller == entry.owner or
                (entry.stage in [:candidate, :prepared] and caller == entry.producer)

        if permitted,
          do: drop_result(token, state),
          else: {{:error, :invalid_output_owner}, state}

      error ->
        {error, state}
    end
  end

  defp operate({:open_scope, scope, deadline}, caller, state) do
    if caller == state.ref.owner do
      result =
        update(state.ref, fn gate ->
          case gate.scopes[scope] do
            %{mode: :open} = info ->
              info = %{info | deadline: earlier_deadline(info.deadline, deadline)}
              {:ok, %{gate | scopes: Map.put(gate.scopes, scope, info)}, :ok}

            nil ->
              info = %{mode: :open, deadline: deadline, consumer: nil, monitor: nil, wake: false}
              {:ok, %{gate | scopes: Map.put(gate.scopes, scope, info)}, :ok}

            _ ->
              {:error, :output_sealed}
          end
        end)

      {result, state}
    else
      {{:error, :invalid_output_owner}, state}
    end
  end

  defp operate({:subscribe, scope, consumer}, caller, state) do
    with true <- caller == state.ref.owner,
         :ok <- pid_valid(consumer),
         {:ok, gate} <- read(state.ref) do
      case gate.scopes[scope] do
        nil ->
          {{:error, :output_unknown_scope}, state}

        %{consumer: ^consumer} ->
          {:ok, wake(scope, state)}

        %{consumer: other} when not is_nil(other) ->
          {{:error, :consumer_already_registered}, state}

        _ ->
          monitor = Process.monitor(consumer)

          result =
            scope_change(state.ref, scope, &{:ok, %{&1 | consumer: consumer, monitor: monitor}})

          if result == :ok do
            state = %{state | monitors: Map.put(state.monitors, monitor, {:scope, scope})}
            {:ok, wake(scope, state)}
          else
            Process.demonitor(monitor, [:flush])
            {result, state}
          end
      end
    else
      false -> {{:error, :invalid_output_owner}, state}
      error -> {error, state}
    end
  end

  defp operate({:checkout, scope}, caller, state) do
    result = update(state.ref, &checkout_gate(&1, scope, caller, state.ref))

    case result do
      {:error, reason} when reason in [:output_expired, :drain_timeout] ->
        {_, state} = retire(scope, reason, state)
        {result, state}

      _ ->
        {result, state}
    end
  end

  defp operate({:begin_drain, scope, deadline}, caller, state) do
    if caller == state.ref.owner and deadline > now() do
      result =
        scope_change(state.ref, scope, fn info ->
          if info.mode in [:open, :draining],
            do:
              {:ok, %{info | mode: :draining, deadline: min(deadline, info.deadline || deadline)}},
            else: {:error, :output_sealed}
        end)

      {result, state}
    else
      {{:error, :invalid_output_owner}, state}
    end
  end

  defp operate({:seal, scope}, caller, state) do
    if caller == state.ref.owner do
      result =
        update(state.ref, fn gate ->
          case gate.scopes[scope] do
            nil ->
              {:error, :output_unknown_scope}

            info ->
              hidden =
                gate.claims
                |> Map.values()
                |> Enum.filter(&(&1.scope == scope and &1.stage in [:candidate, :prepared]))

              gate = Enum.reduce(hidden, gate, &remove_claim(&2, &1.token))

              {:ok, %{gate | scopes: Map.put(gate.scopes, scope, %{info | mode: :sealed})},
               {:sealed, hidden}}
          end
        end)

      case result do
        {:sealed, hidden} -> {:ok, Enum.reduce(hidden, state, &demonitor(&1.monitor, &2))}
        error -> {error, state}
      end
    else
      {{:error, :invalid_output_owner}, state}
    end
  end

  defp operate({:retire, scope, reason}, caller, state) do
    if caller == state.ref.owner,
      do: retire(scope, reason, state),
      else: {{:error, :invalid_output_owner}, state}
  end

  defp operate({:reset, generation}, caller, state) do
    if caller == state.ref.owner and is_reference(generation) and
         generation != state.ref.generation and
         Process.get({__MODULE__, :operation_deadline}, now() + 1) > now() do
      {:ok, gate} = read(state.ref)
      ref = %{state.ref | generation: generation}
      # One replacement invalidates old candidate publication; no late producer
      # may insert payload into the retired generation after this point.
      :ets.insert(
        ref.table,
        {:gate,
         %{generation: generation, frames: 0, bytes: 0, claims: %{}, scopes: %{}, pending: %{}}}
      )

      Enum.each(gate.scopes, fn {scope, info} ->
        if info.mode != :retired and info.consumer,
          do:
            send(
              info.consumer,
              {:arbor_mcp_output, state.ref.generation, scope, {:closed, :generation_retired}}
            )
      end)

      Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))
      Process.put({__MODULE__, :reference}, ref)
      {{:ok, ref}, %{state | ref: ref, monitors: %{}}}
    else
      {{:error, :invalid_output_owner}, state}
    end
  end

  defp checkout_gate(gate, scope, caller, ref) do
    case gate.scopes[scope] do
      %{consumer: ^caller} = info -> checkout_available(gate, scope, caller, ref, info)
      nil -> {:error, :output_unknown_scope}
      _ -> {:error, :invalid_output_consumer}
    end
  end

  defp checkout_available(gate, scope, caller, ref, info) do
    # Consuming the coalesced wake resets it even while prior credit is held.
    gate = %{gate | scopes: Map.put(gate.scopes, scope, %{info | wake: false})}

    active =
      Enum.any?(gate.claims, fn {_, entry} ->
        entry.scope == scope and entry.stage == :in_flight
      end)

    cond do
      is_integer(info.deadline) and info.deadline <= now() ->
        {:ok, gate, {:error, :drain_timeout}}

      active ->
        {:ok, gate, {:error, :output_credit_exhausted}}

      true ->
        checkout_queued(gate, scope, caller, ref)
    end
  end

  defp checkout_queued(gate, scope, caller, ref) do
    queued =
      gate.claims |> Map.values() |> Enum.filter(&(&1.scope == scope and &1.stage == :queued))

    case Enum.min_by(queued, & &1.sequence, fn -> nil end) do
      nil -> {:ok, gate, :empty}
      entry -> deliver_entry(gate, entry, scope, caller, ref)
    end
  end

  defp deliver_entry(gate, entry, scope, caller, ref) do
    if entry.deadline > now() do
      entry = %{entry | stage: :in_flight, consumer: caller}
      gate = %{gate | claims: Map.put(gate.claims, entry.token, entry)}
      {:ok, gate, {:ok, ticket(ref, entry.token, scope), entry.payload.term, entry.payload.wire}}
    else
      {:ok, gate, {:error, :output_expired}}
    end
  end

  defp claim(ref, entry) do
    update(
      ref,
      fn gate ->
        with :ok <- preparable(gate.scopes[entry.scope]),
             :ok <- group_capacity(gate, entry, ref),
             true <- gate.frames < ref.limits.max_output_frames || {:error, :output_full},
             true <-
               gate.bytes + entry.bytes <= ref.limits.max_output_bytes || {:error, :output_full} do
          {:ok,
           %{
             gate
             | frames: gate.frames + 1,
               bytes: gate.bytes + entry.bytes,
               claims: Map.put(gate.claims, entry.token, entry)
           }, :ok}
        end
      end,
      min(entry.deadline, now() + ref.limits.call_timeout_ms)
    )
  end

  defp group_capacity(_gate, %{group: false}, _ref), do: :ok

  defp group_capacity(gate, entry, ref) do
    previous = gate.claims |> Map.values() |> Enum.filter(&(&1.scope == entry.scope))
    wire = Enum.reduce(previous, entry.wire_bytes + 3, &(&1.wire_bytes + 1 + &2))
    term = Enum.reduce(previous, entry.term_bytes + 7, &(&1.term_bytes + &2))

    cond do
      wire > ref.limits.max_frame_bytes -> {:error, :output_frame_too_large}
      term > ref.limits.max_term_bytes -> {:error, :output_term_too_large}
      true -> :ok
    end
  end

  defp store_prepared(ref, token, payload) do
    with {:ok, entry} <- entry(ref, token) do
      update(
        ref,
        fn gate ->
          with %{stage: :candidate} = entry <- gate.claims[token],
               :ok <- preparable(gate.scopes[entry.scope]),
               :ok <- live_entry(entry) do
            {:ok,
             %{
               gate
               | claims:
                   Map.put(gate.claims, token, %{entry | stage: :prepared, payload: payload})
             }, :ok}
          else
            _ -> {:error, :output_expired}
          end
        end,
        min(entry.deadline, now() + ref.limits.call_timeout_ms)
      )
    end
  end

  defp ticket_operation(ticket, operation) do
    with {:ok, ref, token} <- ticket_ref(ticket) do
      deadline =
        case operation do
          operation when operation in [:publish, :handoff, :hold, :value, :payload] ->
            case entry(ref, token) do
              {:ok, entry} -> entry.deadline
              _ -> nil
            end

          _ ->
            nil
        end

      invoke(ref, {:ticket, token}, {operation, token}, deadline)
    end
  end

  defp invoke(ref, key, request, output_deadline \\ nil) do
    id = make_ref()
    control_deadline = now() + ref.limits.call_timeout_ms
    control_deadline = min(control_deadline, output_deadline || control_deadline)

    pending = %{
      id: id,
      producer: self(),
      deadline: control_deadline,
      request: request
    }

    with {:ok, _} <- validate(ref),
         :ok <-
           update(
             ref,
             fn gate ->
               cond do
                 Map.has_key?(gate.pending, key) ->
                   {:error, :output_busy}

                 map_size(gate.pending) >= ref.limits.max_output_frames * 2 + 1 ->
                   {:error, :output_busy}

                 true ->
                   {:ok, %{gate | pending: Map.put(gate.pending, key, pending)}, :ok}
               end
             end,
             pending.deadline
           ),
         remaining = pending.deadline - now(),
         true <- remaining > 0 || {:error, :output_call_expired} do
      GenServer.call(ref.pid, {:operation, id}, remaining)
    end
  catch
    :exit, _ -> {:error, :output_unavailable}
  end

  defp reap_claim(token, entry, state) do
    expired = entry.deadline <= now() or not Process.alive?(entry.owner)

    cond do
      expired and entry.stage in [:held, :queued, :in_flight] ->
        elem(retire(entry.scope, :output_expired, state), 1)

      expired ->
        drop(token, state)

      entry.stage in [:candidate, :prepared] and not Process.alive?(entry.producer) ->
        drop(token, state)

      true ->
        state
    end
  end

  defp within_control_deadline(deadline, callback) do
    Process.put({__MODULE__, :operation_deadline}, deadline)

    try do
      callback.()
    after
      Process.delete({__MODULE__, :operation_deadline})
    end
  end

  defp update(ref, callback, deadline \\ nil) do
    deadline = deadline || now() + ref.limits.call_timeout_ms
    deadline = min(deadline, Process.get({__MODULE__, :operation_deadline}, deadline))
    cas_update(ref, callback, deadline, 512)
  end

  defp cas_update(_ref, _callback, _deadline, 0), do: {:error, :output_contention}

  defp cas_update(ref, callback, deadline, attempts) do
    if deadline <= now() do
      {:error, :output_call_expired}
    else
      with {:ok, previous} <- read(ref) do
        case callback.(previous) do
          {:ok, next, reply} ->
            if map_size(next.scopes) <= ref.limits.max_output_frames and
                 metadata_bytes(next) <= ref.limits.max_scope_bytes do
              match =
                {{:gate, :"$1"}, [{:"=:=", :"$1", {:const, previous}}],
                 [{{:gate, {:const, next}}}]}

              cond do
                deadline <= now() -> {:error, :output_call_expired}
                next === previous -> reply
                :ets.select_replace(ref.table, [match]) == 1 -> reply
                true -> cas_update(ref, callback, deadline, attempts - 1)
              end
            else
              {:error, :output_scope_limit}
            end

          error ->
            error
        end
      end
    end
  rescue
    ArgumentError -> {:error, :output_unavailable}
  end

  defp read(ref) do
    case :ets.lookup(ref.table, :gate) do
      [{:gate, %{generation: generation} = gate}] when generation == ref.generation -> {:ok, gate}
      _ -> {:error, :output_unavailable}
    end
  rescue
    ArgumentError -> {:error, :output_unavailable}
  end

  defp validate(%__MODULE__{} = ref) do
    if local_pid?(ref.pid) and Process.alive?(ref.pid) and :ets.info(ref.table, :owner) == ref.pid do
      with {:ok, _} <- read(ref), do: {:ok, ref}
    else
      {:error, :output_unavailable}
    end
  rescue
    ArgumentError -> {:error, :output_unavailable}
  end

  defp owner_valid(ref),
    do:
      with(
        {:ok, _} <- validate(ref),
        true <- ref.owner == self() || {:error, :invalid_output_owner},
        do: :ok
      )

  defp ticket_ref(ticket) do
    with {:ok, {ledger, token}} <- OutputTicket.address(ticket),
         {:ok, ref} <- ref(ledger),
         :ok <- OutputTicket.validate_ledger(ticket, ref.pid, ref.table, ref.generation),
         :ok <- ticket_entry_valid(ref, token, ticket) do
      {:ok, ref, token}
    end
  end

  defp ticket_entry_valid(ref, token, ticket) do
    case entry(ref, token) do
      {:ok, entry} -> OutputTicket.validate_scope(ticket, entry.scope)
      {:error, :output_released} -> :ok
      error -> error
    end
  end

  defp entry(ref, token),
    do:
      with(
        {:ok, gate} <- read(ref),
        do:
          if(gate.claims[token], do: {:ok, gate.claims[token]}, else: {:error, :output_released})
      )

  defp change_entry(ref, token, callback, deadline \\ nil),
    do:
      update(
        ref,
        fn gate ->
          case gate.claims[token] do
            nil -> {:error, :output_released}
            entry -> {:ok, %{gate | claims: Map.put(gate.claims, token, callback.(entry))}, :ok}
          end
        end,
        deadline
      )

  defp preparable(nil), do: {:error, :output_unknown_scope}
  defp preparable(%{mode: :open}), do: :ok
  defp preparable(%{mode: :retired}), do: {:error, :scope_retired}
  defp preparable(_), do: {:error, :output_sealed}
  defp publishable(%{mode: :open}), do: :ok

  defp publishable(%{mode: :draining, deadline: deadline}),
    do: if(deadline > now(), do: :ok, else: {:error, :output_expired})

  defp publishable(%{mode: :retired}), do: {:error, :scope_retired}
  defp publishable(_), do: {:error, :output_sealed}

  defp live_entry(entry) do
    producer_alive = entry.stage not in [:candidate, :prepared] or Process.alive?(entry.producer)

    if entry.deadline > now() and Process.alive?(entry.owner) and producer_alive,
      do: :ok,
      else: {:error, :output_expired}
  end

  defp known_scope(ref, scope) do
    with {:ok, gate} <- read(ref),
         do: if(Map.has_key?(gate.scopes, scope), do: :ok, else: {:error, :output_unknown_scope})
  end

  defp scope_valid(scope), do: OutputTicket.validate_scope_value(scope)

  defp deadline_valid(deadline),
    do:
      if(is_integer(deadline) and deadline > now() and deadline <= 9_223_372_036_854_775_807,
        do: :ok,
        else: {:error, :invalid_output_deadline}
      )

  defp scope_deadline_valid(nil), do: :ok
  defp scope_deadline_valid(deadline), do: deadline_valid(deadline)
  defp earlier_deadline(nil, deadline), do: deadline
  defp earlier_deadline(deadline, nil), do: deadline
  defp earlier_deadline(left, right), do: min(left, right)

  defp pid_valid(pid),
    do:
      if(local_pid?(pid) and Process.alive?(pid), do: :ok, else: {:error, :invalid_output_owner})

  defp local_pid?(pid), do: is_pid(pid) and node(pid) == node()
  defp now, do: System.monotonic_time(:millisecond)

  defp entry_metadata_bytes(entry) do
    largest = %{
      Map.delete(entry, :payload)
      | stage: :in_flight,
        monitor: make_ref(),
        consumer: self(),
        sequence: 9_223_372_036_854_775_807
    }

    :erlang.external_size(largest) + 16
  end

  defp metadata_bytes(gate) do
    # Reserve the maximal local PID/monitor/wake representation at scope creation.
    scopes =
      Map.new(gate.scopes, fn {scope, info} ->
        {scope,
         %{
           info
           | mode: :draining,
             deadline: 9_223_372_036_854_775_807,
             consumer: self(),
             monitor: make_ref(),
             wake: false
         }}
      end)

    # A full scope budget must still permit one retirement/seal operation.
    reserve =
      Enum.reduce(Map.keys(scopes), control_reserve(nil), fn scope, largest ->
        max(largest, control_reserve(scope))
      end)

    :erlang.external_size(scopes) + max(:erlang.external_size(gate.pending), reserve)
  end

  defp control_reserve(scope) do
    pending = %{
      {:scope, scope} => %{
        id: make_ref(),
        producer: self(),
        deadline: 9_223_372_036_854_775_807,
        request: {:subscribe, scope, self(), 9_223_372_036_854_775_807, :generation_retired}
      }
    }

    :erlang.external_size(pending) + 64
  end

  defp ticket(ref, token, scope),
    do: OutputTicket.new(ref.pid, ref.table, ref.generation, token, scope)

  defp pending(ref, id) do
    with {:ok, gate} <- read(ref) do
      Enum.find(gate.pending, fn {_, item} -> item.id == id end)
    end
  end

  defp clear_pending(ref, key, id),
    do:
      update(ref, fn gate ->
        pending =
          case gate.pending[key] do
            %{id: ^id} -> Map.delete(gate.pending, key)
            _ -> gate.pending
          end

        {:ok, %{gate | pending: pending}, :ok}
      end)

  defp abandon(ref, token), do: update(ref, fn gate -> {:ok, remove_claim(gate, token), :ok} end)

  defp remove_claim(gate, token) do
    case Map.pop(gate.claims, token) do
      {nil, _} ->
        gate

      {entry, claims} ->
        %{gate | frames: gate.frames - 1, bytes: gate.bytes - entry.bytes, claims: claims}
    end
  end

  defp drop(token, state), do: elem(drop_result(token, state), 1)

  defp drop_result(token, state) do
    case entry(state.ref, token) do
      {:ok, entry} ->
        case abandon(state.ref, token) do
          :ok ->
            state = demonitor(entry.monitor, state)
            {:ok, wake(entry.scope, state)}

          error ->
            {error, state}
        end

      {:error, :output_released} ->
        {:ok, state}

      error ->
        {error, state}
    end
  end

  defp demonitor(nil, state), do: state

  defp demonitor(monitor, state) do
    Process.demonitor(monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor)}
  end

  defp scope_change(ref, scope, callback) do
    update(ref, fn gate ->
      case gate.scopes[scope] do
        nil ->
          {:error, :output_unknown_scope}

        info ->
          with {:ok, info} <- callback.(info),
               do: {:ok, %{gate | scopes: Map.put(gate.scopes, scope, info)}, :ok}
      end
    end)
  end

  defp wake(scope, state) do
    update(state.ref, fn gate ->
      case gate.scopes[scope] do
        %{consumer: consumer, wake: false, mode: mode} = info
        when is_pid(consumer) and mode != :retired ->
          queued =
            Enum.any?(gate.claims, fn {_, entry} ->
              entry.scope == scope and entry.stage == :queued
            end)

          active =
            Enum.any?(gate.claims, fn {_, entry} ->
              entry.scope == scope and entry.stage == :in_flight
            end)

          if not queued or active do
            {:ok, gate, :ok}
          else
            {:ok, %{gate | scopes: Map.put(gate.scopes, scope, %{info | wake: true})},
             {:wake, consumer}}
          end

        _ ->
          {:ok, gate, :ok}
      end
    end)
    |> case do
      {:wake, consumer} ->
        send(consumer, {:arbor_mcp_output, state.ref.generation, scope, :ready})

      _ ->
        :ok
    end

    state
  end

  defp retire(scope, reason, state) do
    result =
      update(state.ref, fn gate ->
        case gate.scopes[scope] do
          nil ->
            {:ok, gate, :absent}

          info ->
            entries = gate.claims |> Map.values() |> Enum.filter(&(&1.scope == scope))
            gate = Enum.reduce(entries, gate, &remove_claim(&2, &1.token))
            {:ok, %{gate | scopes: Map.delete(gate.scopes, scope)}, {:retired, info, entries}}
        end
      end)

    case result do
      :absent ->
        {:ok, state}

      {:retired, info, entries} ->
        if info.consumer,
          do:
            send(
              info.consumer,
              {:arbor_mcp_output, state.ref.generation, scope, {:closed, reason}}
            )

        state = Enum.reduce(entries, state, &demonitor(&1.monitor, &2))
        {:ok, demonitor(info.monitor, state)}

      error ->
        {error, state}
    end
  end
end
