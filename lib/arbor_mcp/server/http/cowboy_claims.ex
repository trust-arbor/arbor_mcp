defmodule Arbor.MCP.Server.HTTP.CowboyClaims do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.HTTP.ListenerAdapter
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    Diagnostics,
    Initialization,
    Ref,
    RetainedTerm,
    ShutdownGuard
  }

  @anchor {__MODULE__, :identity}
  @limit 128
  @ref_bytes 4_096
  @control_bytes 8_192
  @tick 10
  @opaque authority :: {pid(), :ets.tid(), reference(), :atomics.atomics_ref()}
  @opaque lease :: {authority(), reference()}

  def acquire(reference, deadline, authority \\ nil) do
    with {:ok, authority} <- authority(authority, deadline),
         :ok <- reference_size(reference),
         do: request(authority, {:claim, reference}, deadline)
  end

  def borrowed(reference, deadline, authority \\ nil) do
    with {:ok, authority} <- authority(authority, deadline),
         :ok <- reference_size(reference),
         do: request(authority, {:borrowed_claim, reference}, deadline)
  end

  def borrowed_done({authority, token}, result, deadline),
    do: request(authority, {:borrowed_done, token, result}, deadline)

  defp reference_size(reference) do
    if RetainedTerm.bytes(reference, @ref_bytes) <= @ref_bytes,
      do: :ok,
      else: {:error, :invalid_http_listener_reference}
  end

  def bind({authority, token}, runtime, deadline),
    do: request(authority, {:bind, token, runtime}, deadline)

  def prepare({authority, token}, runtime, context),
    do: request(authority, {:prepare, token, runtime, context}, context.deadline)

  def register({authority, token}, pid, role, deadline),
    do: request(authority, {:register, token, pid, role}, deadline)

  def published({authority, token}, listener, deadline),
    do: request(authority, {:published, token, listener}, deadline)

  def guardian({{pid, _, _, _}, _}), do: pid

  def borrowed_available?(reference) do
    case :persistent_term.get(@anchor, nil) do
      nil ->
        :ok

      authority ->
        with :ok <- valid(authority),
             {_pid, table, _id, _counter} = authority,
             false <- :ets.member(table, {:reference, reference}) do
          :ok
        else
          true -> {:error, :http_listener_reference_in_use}
          result -> result
        end
    end
  rescue
    ArgumentError -> {:error, :http_listener_claims_unavailable}
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def reference(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, {__MODULE__, :identity}, 0) do
          {_, authority} -> with :ok <- valid(authority), do: {:ok, authority}
          _ -> {:error, :http_listener_claims_unavailable}
        end

      _ ->
        {:error, :http_listener_claims_unavailable}
    end
  end

  defp authority(nil, deadline) do
    case :persistent_term.get(@anchor, nil) do
      nil ->
        case GenServer.start(__MODULE__, [global: true],
               name: __MODULE__,
               timeout: Deadline.remaining(deadline)
             ) do
          {:ok, pid} -> reference(pid)
          {:error, {:already_started, pid}} -> await_authority(pid, deadline)
          _ -> {:error, :http_listener_claims_unavailable}
        end

      authority ->
        with :ok <- valid(authority), do: {:ok, authority}
    end
  end

  defp authority(authority, _deadline), do: with(:ok <- valid(authority), do: {:ok, authority})

  defp await_authority(pid, deadline) do
    case reference(pid) do
      {:ok, _authority} = result ->
        result

      _starting ->
        if Process.alive?(pid) and Deadline.now() < deadline do
          Process.sleep(min(Deadline.remaining(deadline), 1))
          await_authority(pid, deadline)
        else
          {:error, :http_listener_claims_unavailable}
        end
    end
  end

  defp valid({pid, table, identity, _counter}) do
    if node(pid) == node() and Process.alive?(pid) and :ets.info(table, :owner) == pid and
         :ets.lookup(table, :identity) == [{:identity, identity}],
       do: :ok,
       else: {:error, :http_listener_claims_unavailable}
  rescue
    ArgumentError -> {:error, :http_listener_claims_unavailable}
  end

  defp valid(_), do: {:error, :http_listener_claims_unavailable}

  def validate({authority, token}) do
    with :ok <- valid(authority),
         {_pid, table, _identity, _counter} = authority,
         [{{:lease, ^token}, true}] <- :ets.lookup(table, {:lease, token}) do
      :ok
    else
      {:error, _} = error -> error
      _retired -> {:error, :http_listener_claims_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_listener_claims_unavailable}
  end

  def stats(authority), do: request(authority, :stats, Deadline.now() + 1_000)

  defp control_size(operation) do
    if RetainedTerm.bytes(operation, @control_bytes) <= @control_bytes,
      do: :ok,
      else: {:error, :invalid_http_claim_control}
  end

  defp request({pid, table, _id, counter} = authority, operation, deadline) do
    with :ok <- valid(authority),
         :ok <- control_size(operation),
         :ok <- slot(counter, deadline, 64) do
      alias = :erlang.alias()
      token = make_ref()
      phase = :atomics.new(1, [])

      row = %{
        operation: RetainedTerm.materialize(operation),
        caller: self(),
        reply: alias,
        deadline: deadline,
        phase: phase
      }

      :ets.insert(table, {{:control, token}, row})
      wake(pid, table)

      try do
        receive do
          {^token, result} ->
            if Deadline.now() < deadline, do: result, else: {:error, :runtime_init_timeout}
        after
          Deadline.remaining(deadline) -> {:error, :runtime_init_timeout}
        end
      after
        :atomics.put(phase, 1, 2)
        :erlang.unalias(alias)

        receive do
          {^token, _late} -> :ok
        after
          0 -> :ok
        end

        wake(pid, table)
      end
    end
  rescue
    ArgumentError -> {:error, :http_listener_claims_unavailable}
  end

  @doc false
  def tag_transport(options, lease), do: Map.put(options, :arbor_mcp_owned_claim, lease)

  @doc false
  def cleanup_objects(table, objects) do
    Enum.reduce(objects, :ok, fn object, result ->
      if :ets.select_delete(table, [{object, [], [true]}]) == 1,
        do: result,
        else: {:error, :changed_http_metadata}
    end)
  end

  defp slot(_counter, _deadline, 0), do: {:error, :http_listener_claims_busy}

  defp slot(counter, deadline, attempts) do
    count = :atomics.get(counter, 1)

    cond do
      Deadline.now() >= deadline -> {:error, :runtime_init_timeout}
      count >= @limit -> {:error, :http_listener_claims_busy}
      :atomics.compare_exchange(counter, 1, count, count + 1) == :ok -> :ok
      true -> slot(counter, deadline, attempts - 1)
    end
  end

  defp wake(pid, table) do
    if :ets.insert_new(table, {:wake}), do: send(pid, :wake)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    case ListenerAdapter.ensure_started(Plug.Cowboy, :cowboy, :plug_cowboy) do
      :ok -> initialize_authority(opts)
      _ -> {:stop, :http_listener_claims_unavailable}
    end
  end

  defp initialize_authority(opts) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    counter = :atomics.new(1, [])
    identity = make_ref()
    authority = {self(), table, identity, counter}
    :ets.insert(table, {:identity, identity})
    Process.put({__MODULE__, :identity}, authority)
    if opts[:global], do: :persistent_term.put(@anchor, authority)
    ranch = Process.whereis(:ranch_server)
    Process.monitor(ranch)
    Process.send_after(self(), :maintenance, @tick)

    {:ok,
     %{
       authority: authority,
       table: table,
       counter: counter,
       ranch: ranch,
       domains: %{},
       monitors: %{},
       barriers: %{}
     }}
  end

  @impl true
  def handle_info(:wake, state), do: {:noreply, maintain(state)}

  def handle_info(:maintenance, state) do
    Process.send_after(self(), :maintenance, @tick)
    {:noreply, maintain(state)}
  end

  def handle_info({:DOWN, _monitor, :process, ranch, _}, %{ranch: ranch} = state),
    do: {:stop, :http_listener_claims_unavailable, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, maintain(%{state | monitors: Map.delete(state.monitors, monitor)})}
  end

  def handle_info({tag, _reply}, state) when is_reference(tag) do
    case Map.pop(state.barriers, tag) do
      {nil, _} ->
        {:noreply, state}

      {{token, reply_alias, stage}, barriers} ->
        :erlang.unalias(reply_alias)
        state = %{state | barriers: barriers}

        case Map.get(state.domains, token) do
          %{kind: :borrowed} = entry when stage == :borrowed_native ->
            # This supervisor receipt runs after its original stock start_child.
            # It proves the borrowed constructor has finished, without adopting
            # or deleting anything owned by Ranch or its host.
            {:noreply,
             put_domain(state, token, %{entry | barrier: false, finished: true}) |> maintain()}

          %{kind: :borrowed} = entry ->
            {:noreply, drop_domain(state, token, entry) |> maintain()}

          %{senders: senders} = entry ->
            if Enum.all?(Map.keys(senders), &(not Process.alive?(&1))) do
              next = cleanup_owned(state, token, entry)
              {:noreply, maintain(put_domain(state, token, next))}
            else
              {:noreply, state}
            end

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  defp maintain(state) do
    :ets.delete(state.table, :wake)
    state = reap_domains(state)
    controls = :ets.match_object(state.table, {{:control, :_}, :_})

    Enum.reduce(controls, state, fn {{:control, token}, row}, state ->
      if open?(row) do
        case perform(row.operation, row, state) do
          {:wait, state} ->
            state

          {result, state} ->
            send(row.reply, {token, result})
            release_control(state, token)
            state
        end
      else
        release_control(state, token)
        state
      end
    end)
  end

  defp open?(row),
    do:
      Deadline.now() < row.deadline and Process.alive?(row.caller) and
        :atomics.get(row.phase, 1) != 2

  defp release_control(state, token) do
    if :ets.take(state.table, {:control, token}) != [], do: :atomics.sub(state.counter, 1, 1)
  end

  defp perform(:stats, _row, state) do
    {%{
       domains: map_size(state.domains),
       monitors: map_size(state.monitors),
       barriers: map_size(state.barriers),
       controls: :atomics.get(state.counter, 1),
       limit: @limit,
       reference_bytes: @ref_bytes,
       control_bytes: @control_bytes
     }, state}
  end

  defp perform({:claim, reference}, row, state) do
    case Enum.find(state.domains, fn {_, entry} -> entry.reference == reference end) do
      {_, %{quarantined: true}} ->
        {{:error, :http_listener_reference_in_use}, state}

      {_, %{root: root}} when is_pid(root) ->
        if Process.alive?(root),
          do: {{:error, :http_listener_reference_in_use}, state},
          else: {:wait, state}

      {_, _} ->
        {{:error, :http_listener_reference_in_use}, state}

      nil ->
        cond do
          map_size(state.domains) >= @limit ->
            {{:error, :http_listener_claim_capacity}, state}

          external_listener?(reference) ->
            {{:error, :http_listener_reference_in_use}, state}

          true ->
            token = make_ref()

            entry = %{
              reference: reference,
              starter: row.caller,
              root: nil,
              deadline: row.deadline,
              epoch: nil,
              senders: %{},
              clean: true,
              barrier: false,
              listener: nil,
              kind: :owned,
              finished: false,
              quarantined: false,
              address: nil
            }

            :ets.insert(state.table, [{{:reference, reference}, token}, {{:lease, token}, true}])
            state = monitor(state, row.caller) |> put_domain(token, entry)
            {{:ok, {state.authority, token}}, state}
        end
    end
  end

  defp perform({:borrowed_claim, reference}, row, state) do
    case Enum.find(state.domains, fn {_, entry} -> entry.reference == reference end) do
      {_, %{kind: :owned}} ->
        {{:error, :http_listener_reference_in_use}, state}

      {_, %{kind: :borrowed}} ->
        {{:error, :http_listener_claims_busy}, state}

      nil ->
        if map_size(state.domains) < @limit and open?(row) do
          token = make_ref()

          entry = %{
            reference: reference,
            starter: row.caller,
            root: nil,
            deadline: row.deadline,
            epoch: nil,
            senders: %{},
            clean: false,
            barrier: false,
            listener: nil,
            kind: :borrowed,
            finished: false,
            quarantined: false,
            address: nil
          }

          :ets.insert(state.table, [{{:reference, reference}, token}, {{:lease, token}, true}])
          state = monitor(state, row.caller) |> put_domain(token, entry)
          {{:ok, {state.authority, token}}, state}
        else
          {{:error, :http_listener_claim_capacity}, state}
        end
    end
  end

  defp perform({:borrowed_done, token, result}, row, state) do
    case state.domains[token] do
      %{kind: :borrowed, starter: starter} = entry when starter == row.caller ->
        if positive_borrowed?(entry.reference, result) do
          {:ok, drop_domain(state, token, entry)}
        else
          {:ok, put_domain(state, token, %{entry | finished: true})}
        end

      _ ->
        {{:error, :http_listener_claims_unavailable}, state}
    end
  end

  defp perform({:bind, token, runtime}, row, state) do
    with {:ok, runtime} <- Ref.validate(runtime),
         %{root: nil} = entry <- state.domains[token],
         true <- Ref.supervisor(runtime) == row.caller and open?(row) do
      root = Ref.supervisor(runtime)
      {:ok, state |> monitor(root) |> put_domain(token, %{entry | root: root})}
    else
      _ -> {{:error, :http_listener_claims_unavailable}, state}
    end
  end

  defp perform({:prepare, token, runtime, context}, _row, state) do
    with {:ok, runtime} <- Ref.validate(runtime),
         %{root: root, clean: true, quarantined: false} = entry <- state.domains[token],
         true <-
           root == Ref.supervisor(runtime) and
             Initialization.current?(Ref.table(runtime), context),
         true <- Enum.all?(Map.keys(entry.senders), &(not Process.alive?(&1))) do
      {:ok,
       put_domain(state, token, %{
         entry
         | epoch: context.epoch,
           deadline: context.deadline,
           senders: %{},
           clean: false,
           listener: nil,
           address: nil
       })}
    else
      _ -> {:wait, state}
    end
  end

  defp perform({:register, token, pid, role}, row, state) do
    with %{root: root} = entry <- state.domains[token],
         true <- is_pid(root) and Process.alive?(root) and pid == row.caller,
         true <- role in [:listener, :connections, :acceptors],
         true <- map_size(entry.senders) < 3 and open?(row) do
      {:ok,
       state
       |> monitor(pid)
       |> put_domain(token, %{entry | senders: Map.put(entry.senders, pid, role)})}
    else
      _ -> {{:error, :http_listener_claims_unavailable}, state}
    end
  end

  defp perform({:published, token, listener}, _row, state) do
    with %{senders: senders} = entry <- state.domains[token],
         :listener <- senders[listener],
         true <- Process.alive?(listener) do
      address = ranch_value(:addr, entry.reference)
      {:ok, put_domain(state, token, %{entry | listener: listener, address: address})}
    else
      _ -> {{:error, :http_listener_claims_unavailable}, state}
    end
  end

  defp positive_borrowed?(reference, {:ok, pid}), do: positive_borrowed_pid?(reference, pid)

  defp positive_borrowed?(reference, {:error, {:already_started, pid}}),
    do: positive_borrowed_pid?(reference, pid)

  defp positive_borrowed?(_reference, _result), do: false

  defp positive_borrowed_pid?(reference, pid) do
    is_pid(pid) and Process.alive?(pid) and
      :erlang.apply(:ranch_server, :get_listener_sup, [reference]) == pid
  rescue
    ArgumentError -> false
  end

  defp external_listener?(reference) do
    Enum.any?(
      [:listener_sup, :max_conns, :trans_opts, :proto_opts, :listener_start_args],
      &:ets.member(:ranch_server, {&1, reference})
    )
  rescue
    ArgumentError -> true
  end

  defp reap_domains(state) do
    Enum.reduce(state.domains, state, fn {token, entry}, state ->
      root_dead =
        owner_retired?(entry)

      senders_dead = Enum.all?(Map.keys(entry.senders), &(not Process.alive?(&1)))

      cond do
        entry.quarantined ->
          state

        borrowed_settlement?(entry, root_dead) ->
          borrowed_barrier(state, token, entry)

        root_dead and entry.clean ->
          drop_domain(state, token, entry)

        owned_settlement?(entry, root_dead, senders_dead) ->
          barrier(
            state,
            token,
            entry,
            state.ranch,
            :arbor_mcp_owned_listener_settlement,
            :settlement
          )

        true ->
          state
      end
    end)
  end

  defp owner_retired?(%{kind: :borrowed, starter: starter}),
    do: not Process.alive?(starter)

  defp owner_retired?(%{root: root}) when is_pid(root), do: not Process.alive?(root)

  defp owner_retired?(entry),
    do: not Process.alive?(entry.starter) or Deadline.now() >= entry.deadline

  defp borrowed_settlement?(entry, root_dead),
    do: entry.kind == :borrowed and not entry.barrier and (root_dead or entry.finished)

  defp owned_settlement?(entry, root_dead, senders_dead),
    do:
      entry.kind == :owned and senders_dead and not entry.clean and not entry.barrier and
        (root_dead or map_size(entry.senders) > 0)

  defp borrowed_barrier(state, token, entry) do
    stage = if entry.finished, do: :settlement, else: :borrowed_native
    pid = if stage == :settlement, do: state.ranch, else: Process.whereis(:ranch_sup)

    request =
      if stage == :settlement, do: :arbor_mcp_owned_listener_settlement, else: :which_children

    barrier(state, token, entry, pid, request, stage)
  end

  defp barrier(state, token, entry, pid, request, stage) do
    tag = make_ref()
    reply_alias = :erlang.alias()
    send(pid, {:"$gen_call", {reply_alias, tag}, request})
    state = %{state | barriers: Map.put(state.barriers, tag, {token, reply_alias, stage})}
    put_domain(state, token, %{entry | barrier: true})
  end

  defp cleanup_owned(state, token, entry) do
    objects =
      for key <- [
            :addr,
            :max_conns,
            :trans_opts,
            :proto_opts,
            :listener_start_args,
            :conns_sup,
            :listener_sup
          ],
          object <- :ets.lookup(:ranch_server, {key, entry.reference}),
          do: object

    if objects == [] or owned_objects?(objects, {state.authority, token}, entry) do
      case cleanup_objects(:ranch_server, objects) do
        :ok -> %{entry | clean: true, barrier: false}
        _changed -> quarantine(state, token, entry)
      end
    else
      quarantine(state, token, entry)
    end
  end

  defp quarantine(state, token, entry) do
    :ets.insert(state.table, {{:lease, token}, false})

    if is_pid(entry.root) and Process.alive?(entry.root) do
      case Runtime.ref(entry.root) do
        {:ok, runtime} ->
          ShutdownGuard.request_stop(Ref.table(runtime), :http_listener_claims_unavailable)

        _ ->
          :ok
      end
    end

    %{entry | quarantined: true, barrier: false}
  end

  defp owned_objects?(objects, lease, entry) do
    values = Map.new(objects, fn {{key, _reference}, value} -> {key, value} end)

    with %{arbor_mcp_owned_claim: ^lease} = options <- values[:trans_opts],
         [reference, _transport, ^options, _protocol, protocol_options] <-
           values[:listener_start_args],
         true <- reference == entry.reference,
         true <- values[:proto_opts] == protocol_options,
         true <- values[:max_conns] == Map.get(options, :max_connections, 1024),
         true <- role_matches?(values[:listener_sup], :listener, entry.senders),
         true <- role_matches?(values[:conns_sup], :connections, entry.senders),
         true <- values[:addr] == nil or values[:addr] == entry.address do
      true
    else
      _ -> false
    end
  end

  defp role_matches?(nil, _role, _senders), do: true
  defp role_matches?(pid, role, senders), do: senders[pid] == role

  defp ranch_value(key, reference) do
    case :ets.lookup(:ranch_server, {key, reference}) do
      [{_key, value}] -> value
      [] -> nil
    end
  end

  defp drop_domain(state, token, entry) do
    :ets.delete(state.table, {:reference, entry.reference})
    :ets.delete(state.table, {:lease, token})
    state = %{state | domains: Map.delete(state.domains, token)}

    owners =
      Enum.flat_map(state.domains, fn {_, value} ->
        [value.starter, value.root] ++ Map.keys(value.senders)
      end)

    monitors =
      Enum.reduce(state.monitors, %{}, fn {monitor, pid}, result ->
        if pid in owners do
          Map.put(result, monitor, pid)
        else
          Process.demonitor(monitor, [:flush])
          result
        end
      end)

    %{state | monitors: monitors}
  end

  defp put_domain(state, token, entry),
    do: %{state | domains: Map.put(state.domains, token, entry)}

  defp monitor(state, pid) do
    if Enum.any?(state.monitors, fn {_, owner} -> owner == pid end),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), pid)}
  end
end
