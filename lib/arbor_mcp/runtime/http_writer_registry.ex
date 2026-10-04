defmodule Arbor.MCP.Server.Runtime.HTTPWriterRegistry do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    Deadline,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriteTicket,
    Ref,
    ServiceRef
  }

  alias Arbor.MCP.SessionManager.SessionLease

  @enforce_keys [:pid, :table, :root, :identity, :limits]
  defstruct [:pid, :table, :root, :identity, :limits, :runtime, :lifetime]

  @opaque t :: %__MODULE__{
            pid: pid(),
            table: :ets.tid(),
            root: pid(),
            identity: reference(),
            limits: map(),
            runtime: Ref.t() | nil,
            lifetime: :atomics.atomics_ref()
          }
  @type error :: {:error, atom()}
  @attempts 512
  @reap_ms 10
  @defaults [
    max_writers: 128,
    max_writer_metadata_bytes: 65_536,
    max_io_frames: 128,
    max_io_bytes: 4_194_304,
    max_io_frame_bytes: 1_048_576,
    max_proof_bytes: 4_096,
    control_timeout_ms: 50,
    idle_exit_ms: 100
  ]

  # Deliberately unlinked. A supervised root-owned proxy will retain this domain
  # across execution replacement; it must never restart it with fresh credits.
  @spec start(pid(), keyword()) :: {:ok, t()} | error()
  def start(root, opts \\ []) do
    with :ok <- local_pid(root),
         :ok <- runtime_valid(Keyword.get(opts, :runtime), root),
         deadline = Keyword.get(opts, :init_deadline, Deadline.now() + 5_000),
         :ok <- finite_deadline(deadline),
         :ok <- before_deadline(deadline),
         {:ok, pid} <-
           GenServer.start(__MODULE__, {root, opts}, timeout: Deadline.remaining(deadline)),
         {:ok, domain} <- ref(pid) do
      if Deadline.now() < deadline do
        {:ok, domain}
      else
        seal(domain)
        {:error, :runtime_init_timeout}
      end
    end
  end

  @spec ref(pid()) :: {:ok, t()} | error()
  def ref(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :dictionary) do
      {:dictionary, items} ->
        case List.keyfind(items, {__MODULE__, :domain}, 0) do
          {_, domain} -> valid(domain)
          _ -> {:error, :http_writer_unavailable}
        end

      _ ->
        {:error, :http_writer_unavailable}
    end
  end

  def ref(_), do: {:error, :http_writer_unavailable}

  @spec guardian(t()) :: pid()
  def guardian(%__MODULE__{pid: pid}), do: pid

  @spec register(t(), pid(), map(), keyword()) :: {:ok, HTTPWriterBinding.t()} | error()
  def register(domain, writer, proof, opts \\ []) do
    register_entry(domain, writer, proof, Keyword.get(opts, :owner, self()), nil)
  end

  defp register_entry(domain, writer, proof, owner, authority) do
    with {:ok, domain} <- valid(domain),
         :ok <- local_pid(writer),
         :ok <- local_pid(owner),
         :ok <- proof_valid(proof, domain.limits),
         :ok <- generation_valid(domain, proof.generation),
         token = make_ref(),
         binding = %{
           token: token,
           writer: writer,
           owner: owner,
           proof: proof,
           authority: authority,
           mode: :open,
           notice: false,
           closed_notice: false,
           closed_ack: false,
           reason: nil,
           bytes: 0
         },
         binding = %{binding | bytes: :erlang.external_size(binding) + 256},
         :ok <-
           update(domain, proof.deadline, fn gate ->
             register_binding(gate, binding, domain)
           end) do
      wake(domain)
      {:ok, HTTPWriterBinding.new(domain, token)}
    end
  end

  @spec proof(HTTPWriterBinding.t()) :: {:ok, map()} | error()
  def proof(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{mode: :open, proof: proof} <- gate.bindings[token],
         true <- proof.deadline > Deadline.now() do
      {:ok, proof}
    else
      _ -> {:error, :http_invocation_closed}
    end
  end

  @spec validate_invocation(HTTPWriterBinding.t(), Ref.t()) :: {:ok, map()} | error()
  def validate_invocation(binding, runtime) do
    with {:ok, runtime} <- Ref.validate(runtime),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         true <- domain.runtime == runtime and domain.root == Ref.supervisor(runtime),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         :ok <- local_pid(info.writer),
         :ok <- local_pid(info.owner),
         :ok <- generation_valid(domain, info.proof.generation),
         true <- captured_current?(domain, info) do
      {:ok, Map.merge(info.proof, %{runtime: runtime, owner: info.writer})}
    else
      _ -> {:error, :http_invocation_closed}
    end
  end

  # The installed entry facade derives every proof field; raw register/4 never
  # creates an authenticated HTTP source. Original cutoff is captured once.
  @spec capture(t(), pid(), Deadline.t()) :: {:ok, HTTPWriterBinding.t()} | error()
  def capture(domain, proxy, deadline) do
    with {:ok, domain} <- valid(domain),
         true <- installed_proxy?(domain, proxy),
         {:ok, generation} <- current_generation(domain),
         :ok <- finite_deadline(deadline),
         {:ok, deadline} <- bounded_capture_cutoff(domain, deadline),
         :ok <- before_deadline(deadline) do
      invocation = make_ref()

      proof = %{
        invocation: invocation,
        generation: generation,
        scope: {HTTPWriterProxy, invocation},
        lease: nil,
        deadline: deadline
      }

      authority = %{phase: :entered, lease_bound: false, work: nil}
      register_entry(domain, self(), proof, proxy, authority)
    else
      _invalid -> {:error, :http_invocation_closed}
    end
  end

  @spec bind_lease(HTTPWriterBinding.t(), SessionLease.t()) :: :ok | error()
  def bind_lease(binding, lease) do
    mutate_capture(binding, fn domain, info ->
      with true <- not info.authority.lease_bound and info.authority.work == nil,
           service = ServiceRef.new(domain.runtime, :sessions),
           {:ok, _identity} <- SessionLease.validate(lease, service, :sessions) do
        {:ok,
         %{
           info
           | proof: %{info.proof | lease: lease},
             authority: %{info.authority | lease_bound: true}
         }}
      else
        _invalid -> {:error, :invalid_http_session_lease}
      end
    end)
  end

  @spec bind_work(HTTPWriterBinding.t(), reference()) :: :ok | error()
  def bind_work(binding, token) when is_reference(token) do
    mutate_capture(binding, fn domain, info ->
      with true <- info.authority.work == nil,
           {:ok, reservation} <- Admission.current(Ref.table(domain.runtime), token),
           true <-
             reservation.generation == info.proof.generation and
               reservation.scope == info.proof.scope and reservation.owner == info.owner and
               not reservation.terminal and not reservation.batch?,
           work = %{
             token: token,
             generation: reservation.generation,
             scope: reservation.scope,
             phase: reservation.output_phase,
             deadline: min(reservation.deadline, info.proof.deadline)
           },
           true <- Admission.output_origin_valid?(Ref.table(domain.runtime), work) do
        {:ok, %{info | authority: %{info.authority | work: work, phase: :bound}}}
      else
        _invalid -> {:error, :invalid_http_work_origin}
      end
    end)
  end

  def bind_work(_binding, _token), do: {:error, :invalid_http_work_origin}

  @spec cleanup_status(t()) ::
          :ok | {:error, atom() | {:http_io_unsettled, pos_integer(), non_neg_integer()}}
  def cleanup_status(%__MODULE__{} = domain) do
    if :atomics.get(domain.lifetime, 1) == 1 do
      :ok
    else
      case stats(domain) do
        %{in_flight: 0} ->
          :ok

        %{in_flight: count, bytes: bytes} ->
          {:error, {:http_io_unsettled, count, bytes}}

        _unavailable ->
          # The guardian can publish its terminal receipt and delete its ETS
          # table between the first receipt read and stats. Recheck the actual
          # receipt; guardian death alone never establishes IO completion.
          if :atomics.get(domain.lifetime, 1) == 1,
            do: :ok,
            else: {:error, :http_io_cleanup_unconfirmed}
      end
    end
  rescue
    ArgumentError -> {:error, :http_io_cleanup_unconfirmed}
  end

  def cleanup_status(_domain), do: {:error, :http_io_cleanup_unconfirmed}

  defp mutate_capture(binding, operation) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         true <- info.writer == self() and captured_current?(domain, info) do
      update(domain, info.proof.deadline, fn current ->
        with {:ok, info} <- open_binding(current, token),
             true <- info.writer == self() and captured_current?(domain, info),
             {:ok, next} <- operation.(domain, info) do
          next = %{next | bytes: 0}
          next = %{next | bytes: :erlang.external_size(next) + 256}
          bytes = current.metadata_bytes - info.bytes + next.bytes

          if bytes <= domain.limits.max_writer_metadata_bytes do
            {:ok,
             %{current | bindings: Map.put(current.bindings, token, next), metadata_bytes: bytes},
             :ok}
          else
            {:error, :http_writer_busy}
          end
        else
          false -> {:error, :http_invocation_closed}
          error -> error
        end
      end)
    else
      _invalid -> {:error, :http_invocation_closed}
    end
  end

  defp captured_current?(domain, %{authority: authority} = info) when is_map(authority) do
    authority.phase in [:entered, :bound] and installed_proxy?(domain, info.owner) and
      lease_current?(domain, info.proof.lease) and work_current?(domain, authority.work)
  end

  defp captured_current?(_domain, _info), do: false
  defp lease_current?(_domain, nil), do: true

  defp lease_current?(domain, lease),
    do:
      match?(
        {:ok, _},
        SessionLease.validate(lease, ServiceRef.new(domain.runtime, :sessions), :sessions)
      )

  defp work_current?(_domain, nil), do: true

  defp work_current?(domain, proof),
    do: Admission.output_origin_valid?(Ref.table(domain.runtime), proof)

  defp installed_proxy?(%__MODULE__{runtime: nil}, _proxy), do: false

  defp installed_proxy?(domain, proxy) do
    table = Ref.table(domain.runtime)

    with {:ok, _runtime} <- Ref.validate(domain.runtime),
         [{:http_writer_domain, %{domain: ^domain}}] <- :ets.lookup(table, :http_writer_domain),
         {:ok, ^proxy} <- HTTPWriterProxy.active_proxy(domain.runtime) do
      true
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  defp bounded_capture_cutoff(domain, deadline) do
    case :ets.lookup(Ref.table(domain.runtime), :http_writer_domain) do
      [{:http_writer_domain, record}] ->
        {:ok, min(deadline, Deadline.now() + record.request_timeout_ms)}

      _retired ->
        {:error, :http_invocation_closed}
    end
  rescue
    ArgumentError -> {:error, :http_invocation_closed}
  end

  defp source_current?(_domain, %{authority: nil}), do: true
  defp source_current?(domain, info), do: captured_current?(domain, info)

  defp current_generation(domain) do
    case :ets.lookup(Ref.table(domain.runtime), :route) do
      [{:route, %{generation: generation, scheduler: scheduler}}] ->
        if Process.alive?(scheduler), do: {:ok, generation}, else: {:error, :runtime_unavailable}

      _ ->
        {:error, :runtime_unavailable}
    end
  end

  @spec prepare(HTTPWriterBinding.t(), binary(), keyword()) ::
          {:ok, HTTPWriteTicket.t()} | error()
  def prepare(binding, wire, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    with {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         {:ok, domain} <- valid(domain),
         :ok <- local_pid(owner),
         {:ok, gate} <- read(domain),
         true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
         {:ok, info} <- open_binding(gate, binding_token),
         true <- source_current?(domain, info) || {:error, :http_invocation_closed},
         {:ok, deadline} <- output_deadline(info, opts),
         :ok <- wire_valid(wire, domain.limits),
         :ok <- before_deadline(deadline),
         token = make_ref(),
         entry = candidate(token, binding_token, owner, deadline, wire),
         :ok <- update(domain, deadline, &claim(&1, entry, domain)) do
      finish_prepare(domain, entry, info.writer, wire)
    else
      error -> error
    end
  end

  # The producer transfers to the recorded persistent owner before returning;
  # the owner may also accept while the producer remains alive.
  @spec handoff(HTTPWriteTicket.t()) :: :ok | error()
  def handoff(ticket), do: change_ticket(ticket, :handoff)

  @spec publish(HTTPWriteTicket.t()) :: :ok | error()
  def publish(ticket), do: change_ticket(ticket, :publish)

  @spec checkout(HTTPWriterBinding.t()) :: :empty | {:ok, HTTPWriteTicket.t(), binary()} | error()
  def checkout(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
         {:ok, info} <- open_binding(gate, token),
         true <- info.writer == self() || {:error, :invalid_http_writer} do
      update(domain, info.proof.deadline, &take(&1, token, domain))
    end
  end

  # Only the actual borrowed writer can record an IO return. The fixed receipt
  # survives CAS contention, retirement and producer death; reaping is bounded.
  @spec complete(HTTPWriteTicket.t(), :ok | {:error, term()}) :: :ok | error()
  def complete(ticket, result) do
    with true <- HTTPWriteTicket.writer?(ticket, self()) || {:error, :invalid_http_writer},
         true <- valid_write_result?(result) || {:error, :invalid_write_result},
         {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(ticket),
         {:ok, gate} <- read(domain) do
      receipt = HTTPWriteTicket.receipt(ticket)

      case gate.claims[token] do
        %{binding: ^binding, stage: :in_flight} = entry ->
          if gate.bindings[binding].writer == self() and
               HTTPWriteTicket.receipt_matches?(ticket, entry.receipt) do
            code = return_code(gate.bindings[binding], entry, result, domain)
            reply = receipt_result(HTTPWriteTicket.record_return(ticket, code))
            wake(domain)
            reply
          else
            {:error, :invalid_http_writer}
          end

        _ when receipt != 0 ->
          receipt_result(receipt)

        _ ->
          {:error, :invalid_http_write_ticket}
      end
    end
  end

  @spec release(HTTPWriteTicket.t()) :: :ok | error()
  def release(ticket) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(ticket),
         {:ok, gate} <- read(domain) do
      case gate.claims[token] do
        %{binding: ^binding} = entry -> release_present(domain, entry)
        nil -> :ok
        _ -> {:error, :invalid_http_write_ticket}
      end
    end
  end

  @spec retire(HTTPWriterBinding.t(), atom()) :: :ok | error()
  def retire(binding, reason \\ :invocation_closed) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         :ok <- reason_valid(reason),
         :ok <-
           update(domain, control_deadline(domain), fn gate ->
             with {:ok, next, :ok} <- retire_binding(gate, token, reason),
                  do: {:ok, remove_empty_retired(next), :ok}
           end) do
      wake(domain)
      :ok
    end
  end

  @spec retire_generation(t(), reference()) :: :ok | error()
  def retire_generation(domain, generation) when is_reference(generation) do
    result =
      update(domain, control_deadline(domain), fn gate ->
        next =
          Enum.reduce(gate.bindings, gate, fn {token, info}, acc ->
            if info.proof.generation == generation,
              do: elem(retire_binding(acc, token, :generation_retired), 1),
              else: acc
          end)

        {:ok, remove_empty_retired(next), :ok}
      end)

    wake(domain)
    result
  end

  def retire_generation(_, _), do: {:error, :invalid_http_generation}

  @spec acknowledge_wake(t(), reference()) :: :ok | error()
  def acknowledge_wake(domain, nonce) when is_reference(nonce) do
    update(domain, control_deadline(domain), fn gate ->
      case gate.writers[self()] do
        %{pending: ^nonce} = slot ->
          next = %{gate | writers: Map.put(gate.writers, self(), %{slot | pending: nil})}
          {:ok, remove_empty_retired(next), :ok}

        _ ->
          {:error, :invalid_http_wake}
      end
    end)
  end

  def acknowledge_wake(_, _), do: {:error, :invalid_http_wake}

  @spec acknowledge_retirement(HTTPWriterBinding.t()) :: :ok | error()
  def acknowledge_retirement(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         :ok <-
           update(domain, control_deadline(domain), fn gate ->
             case gate.bindings[token] do
               %{mode: :retired, writer: writer} = info when writer == self() ->
                 next = %{
                   gate
                   | bindings: Map.put(gate.bindings, token, %{info | closed_ack: true})
                 }

                 {:ok, remove_empty_retired(next), :ok}

               nil ->
                 {:ok, gate, :ok}

               _ ->
                 {:error, :invalid_http_writer}
             end
           end) do
      wake(domain)
      :ok
    end
  end

  @spec seal(t()) :: :ok | error()
  def seal(domain) do
    with :ok <- update(domain, control_deadline(domain), &seal_gate/1) do
      wake(domain)
      :ok
    end
  end

  @spec stats(t()) :: map() | error()
  def stats(domain) do
    with {:ok, gate} <- read(domain) do
      stages = Enum.frequencies_by(Map.values(gate.claims), & &1.stage)

      %{
        writers: map_size(gate.writers),
        bindings: map_size(gate.bindings),
        writer_metadata_bytes: gate.metadata_bytes,
        frames: map_size(gate.claims),
        bytes: gate.bytes,
        prepared: Map.get(stages, :prepared, 0) + Map.get(stages, :candidate, 0),
        held: Map.get(stages, :held, 0),
        queued: Map.get(stages, :queued, 0),
        in_flight: Map.get(stages, :in_flight, 0),
        sealed: gate.sealed,
        identity: gate.identity
      }
    end
  end

  @impl true
  def init({root, opts}) do
    limits = Map.new(@defaults, fn {key, value} -> {key, Keyword.get(opts, key, value)} end)

    if Enum.all?(limits, fn {_, value} ->
         is_integer(value) and value > 0 and value <= 0xFFFFFFFF
       end) do
      table = :ets.new(__MODULE__, [:public, :set, read_concurrency: true])

      domain = %__MODULE__{
        pid: self(),
        table: table,
        root: root,
        identity: make_ref(),
        limits: limits,
        runtime: Keyword.get(opts, :runtime),
        lifetime: :atomics.new(1, signed: false)
      }

      gate = %{
        identity: domain.identity,
        bindings: %{},
        writers: %{},
        claims: %{},
        bytes: 0,
        metadata_bytes: 0,
        sealed: false,
        sequence: 0
      }

      :ets.insert(table, {:gate, gate})
      Process.put({__MODULE__, :domain}, domain)
      Process.send_after(self(), :reap, @reap_ms)
      {:ok, %{domain: domain, monitors: %{root => Process.monitor(root)}, idle_since: nil}}
    else
      {:stop, :invalid_http_writer_limits}
    end
  end

  @impl true
  def handle_info(message, state) when message in [:reap, :wake] do
    :ets.delete(state.domain.table, :wake)
    state = maintain(state)

    if idle?(state) do
      :atomics.put(state.domain.lifetime, 1, 1)
      {:stop, :normal, state}
    else
      if message == :reap, do: Process.send_after(self(), :reap, @reap_ms)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state) do
    state = maintain(state)

    if idle?(state) do
      :atomics.put(state.domain.lifetime, 1, 1)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp maintain(state) do
    domain = state.domain
    deadline = control_deadline(domain)

    update(domain, deadline, fn gate ->
      gate = if Process.alive?(domain.root), do: gate, else: elem(seal_gate(gate), 1)
      gate = Enum.reduce(gate.bindings, gate, fn item, acc -> reap_binding(item, acc, domain) end)
      gate = Enum.reduce(gate.claims, gate, &reap_claim/2)
      {:ok, gate, :ok}
    end)

    {:ok, gate} = read(domain)
    state = reconcile_monitors(state, gate)
    state = deliver_notices(state, gate, deadline)

    update(domain, deadline, fn current ->
      {:ok, remove_empty_retired(current), :ok}
    end)

    {:ok, gate} = read(domain)

    idle_since =
      if gate.sealed and map_size(gate.claims) == 0,
        do: state.idle_since || Deadline.now(),
        else: nil

    %{state | idle_since: idle_since}
  end

  defp register_binding(gate, binding, domain) do
    existing = gate.writers[binding.writer]
    writer = existing || writer_slot(binding.writer)
    extra = if existing, do: 0, else: writer.bytes

    cond do
      gate.sealed or not Process.alive?(domain.root) ->
        {:error, :http_writer_closed}

      not binding_parties_alive?(binding) ->
        {:error, :http_invocation_closed}

      writer.binding != nil ->
        {:error, :http_writer_in_use}

      is_nil(existing) and map_size(gate.writers) >= domain.limits.max_writers ->
        {:error, :http_writer_busy}

      gate.metadata_bytes + binding.bytes + extra > domain.limits.max_writer_metadata_bytes ->
        {:error, :http_writer_busy}

      true ->
        next = %{
          gate
          | bindings: Map.put(gate.bindings, binding.token, binding),
            writers: Map.put(gate.writers, binding.writer, %{writer | binding: binding.token}),
            metadata_bytes: gate.metadata_bytes + binding.bytes + extra
        }

        {:ok, next, :ok}
    end
  end

  defp binding_parties_alive?(binding),
    do: Process.alive?(binding.writer) and Process.alive?(binding.owner)

  defp writer_slot(pid) do
    slot = %{pid: pid, binding: nil, pending: nil, bytes: 0}
    %{slot | bytes: :erlang.external_size(slot) + 256}
  end

  defp candidate(token, binding, owner, deadline, wire) do
    entry = %{
      token: token,
      binding: binding,
      producer: self(),
      owner: owner,
      deadline: deadline,
      stage: :candidate,
      sequence: nil,
      payload: nil,
      receipt: :atomics.new(2, []),
      bytes: 0
    }

    %{
      entry
      | bytes: byte_size(wire) + :erlang.external_size(wire) + :erlang.external_size(entry) + 256
    }
  end

  defp claim(gate, entry, domain) do
    with {:ok, info} <- open_binding(gate, entry.binding),
         :ok <- generation_valid(domain, info.proof.generation),
         true <- source_current?(domain, info) || {:error, :http_invocation_closed} do
      cond do
        not Process.alive?(domain.root) ->
          {:error, :http_writer_closed}

        map_size(gate.claims) >= domain.limits.max_io_frames ->
          {:error, :http_output_busy}

        gate.bytes + entry.bytes > domain.limits.max_io_bytes ->
          {:error, :http_output_busy}

        true ->
          {:ok,
           %{
             gate
             | claims: Map.put(gate.claims, entry.token, entry),
               bytes: gate.bytes + entry.bytes
           }, :ok}
      end
    end
  end

  defp store(gate, token, binding, wire, domain) do
    entry = gate.claims[token]

    with true <- Process.alive?(domain.root),
         {:ok, info} <- open_binding(gate, binding),
         true <- source_current?(domain, info),
         :ok <- generation_valid(domain, info.proof.generation),
         %{stage: :candidate, binding: ^binding, producer: producer} <- entry,
         true <- producer == self() do
      next = %{entry | stage: :prepared, payload: wire}
      {:ok, %{gate | claims: Map.put(gate.claims, token, next)}, :ok}
    else
      _ -> {:error, :http_invocation_closed}
    end
  end

  defp finish_prepare(domain, entry, writer, wire) do
    result = update(domain, entry.deadline, &store(&1, entry.token, entry.binding, wire, domain))

    case result do
      :ok ->
        wake(domain)
        {:ok, ticket(domain, entry, writer)}

      error ->
        :atomics.put(entry.receipt, 2, 1)
        wake(domain)
        error
    end
  end

  defp release_present(domain, entry) do
    cond do
      entry.stage == :in_flight ->
        {:error, :http_write_in_flight}

      self() not in [entry.owner, entry.producer] ->
        {:error, :invalid_http_output_owner}

      true ->
        :atomics.put(entry.receipt, 2, 1)

        update(domain, control_deadline(domain), fn gate ->
          {:ok, drop(gate, entry.token), :ok}
        end)

        wake(domain)
        :ok
    end
  end

  defp change_ticket(ticket, operation) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(ticket),
         {:ok, gate} <- read(domain) do
      deadline = claim_deadline(gate, token)

      result =
        update(domain, deadline, fn current ->
          with true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
               {:ok, info} <- open_binding(current, binding),
               :ok <- generation_valid(domain, info.proof.generation),
               true <- source_current?(domain, info) || {:error, :http_invocation_closed},
               do: change(current, token, binding, operation)
        end)

      wake(domain)
      result
    end
  end

  defp change(gate, token, binding, operation) do
    case gate.claims[token] do
      %{binding: ^binding} = entry -> change_present(gate, entry, operation)
      _ -> {:error, :invalid_http_write_ticket}
    end
  end

  defp change_present(gate, entry, operation) do
    with {:ok, _} <- open_binding(gate, entry.binding),
         true <- :atomics.get(entry.receipt, 2) == 0 || {:error, :http_output_expired},
         true <-
           active_producer?(entry) ||
             {:error, :http_output_expired},
         true <-
           authorized_output_caller?(entry, operation) || {:error, :invalid_http_output_owner},
         true <- Process.alive?(entry.owner) || {:error, :http_output_expired} do
      case {operation, entry.stage} do
        {:handoff, stage} when stage in [:prepared, :held] ->
          put_entry(gate, %{entry | stage: :held})

        {:publish, stage} when stage in [:prepared, :held] ->
          gate = next_sequence(gate)
          put_entry(gate, %{entry | stage: :queued, sequence: gate.sequence})

        {:publish, :queued} ->
          {:ok, gate, :ok}

        _ ->
          {:error, :invalid_http_output_phase}
      end
    end
  end

  defp authorized_output_caller?(entry, :handoff), do: self() in [entry.owner, entry.producer]
  defp authorized_output_caller?(entry, :publish), do: self() == entry.owner

  defp next_sequence(%{sequence: 0xFFFFFFFF} = gate) do
    ordered =
      gate.claims
      |> Map.values()
      |> Enum.filter(&(&1.stage == :queued))
      |> Enum.sort_by(& &1.sequence)

    claims =
      Enum.with_index(ordered, 1)
      |> Enum.reduce(gate.claims, fn {entry, index}, claims ->
        Map.put(claims, entry.token, %{entry | sequence: index})
      end)

    %{gate | claims: claims, sequence: length(ordered) + 1}
  end

  defp next_sequence(gate), do: %{gate | sequence: gate.sequence + 1}

  defp put_entry(gate, entry),
    do: {:ok, %{gate | claims: Map.put(gate.claims, entry.token, entry)}, :ok}

  defp take(gate, token, domain) do
    with {:ok, info} <- open_binding(gate, token),
         true <- source_current?(domain, info) || {:error, :http_invocation_closed},
         :ok <- generation_valid(domain, info.proof.generation),
         true <- info.writer == self() || {:error, :invalid_http_writer} do
      entries = Enum.filter(Map.values(gate.claims), &(&1.binding == token))

      if Enum.any?(entries, &(&1.stage == :in_flight)) do
        {:error, :http_write_in_flight}
      else
        take_queued(gate, info, entries, domain)
      end
    end
  end

  defp take_queued(gate, info, entries, domain) do
    case entries
         |> Enum.filter(&(&1.stage == :queued))
         |> Enum.min_by(& &1.sequence, fn -> nil end) do
      nil ->
        {:ok, gate, :empty}

      entry ->
        if entry.deadline > Deadline.now() and Process.alive?(entry.owner) do
          next = %{entry | stage: :in_flight}
          info = %{info | notice: false}

          gate = %{
            gate
            | claims: Map.put(gate.claims, entry.token, next),
              bindings: Map.put(gate.bindings, info.token, info)
          }

          {:ok, gate, {:ok, ticket(domain, next, info.writer), next.payload}}
        else
          {:error, :http_output_expired}
        end
    end
  end

  defp retire_binding(gate, token, reason) do
    case gate.bindings[token] do
      nil ->
        {:ok, gate, :ok}

      info ->
        claims =
          Enum.reduce(gate.claims, gate, fn {id, entry}, acc ->
            if entry.binding == token and entry.stage != :in_flight, do: drop(acc, id), else: acc
          end)

        info = %{
          info
          | mode: :retired,
            reason: info.reason || reason,
            notice: false,
            closed_ack: info.closed_ack or info.writer == self()
        }

        {:ok, %{claims | bindings: Map.put(claims.bindings, token, info)}, :ok}
    end
  end

  defp seal_gate(gate) do
    next =
      Enum.reduce(gate.bindings, %{gate | sealed: true}, fn {token, _}, acc ->
        elem(retire_binding(acc, token, :root_closed), 1)
      end)

    {:ok, next, :ok}
  end

  defp reap_binding({token, info}, gate, domain) do
    reason =
      cond do
        generation_valid(domain, info.proof.generation) != :ok -> :generation_retired
        not source_current?(domain, info) -> :source_retired
        not Process.alive?(info.writer) -> :writer_down
        not Process.alive?(info.owner) -> :owner_down
        info.proof.deadline <= Deadline.now() -> :invocation_expired
        true -> nil
      end

    if reason, do: elem(retire_binding(gate, token, reason), 1), else: gate
  end

  defp reap_claim({token, %{stage: :in_flight} = entry}, gate) do
    info = gate.bindings[entry.binding]

    if :atomics.get(entry.receipt, 1) != 0 or is_nil(info) or not Process.alive?(info.writer),
      do: drop(gate, token),
      else: gate
  end

  defp reap_claim({token, entry}, gate) do
    if :atomics.get(entry.receipt, 2) != 0 or entry.deadline <= Deadline.now() or
         claim_owner_down?(entry) do
      drop(gate, token)
    else
      gate
    end
  end

  defp claim_owner_down?(%{stage: stage, producer: producer})
       when stage in [:candidate, :prepared] do
    not Process.alive?(producer)
  end

  defp claim_owner_down?(%{owner: owner}), do: not Process.alive?(owner)

  defp active_producer?(%{stage: stage, producer: producer})
       when stage in [:candidate, :prepared],
       do: Process.alive?(producer)

  defp active_producer?(_entry), do: true

  defp valid_write_result?(:ok), do: true
  defp valid_write_result?({:error, _reason}), do: true
  defp valid_write_result?(_result), do: false

  defp remove_empty_retired(gate) do
    gate =
      Enum.reduce(gate.bindings, gate, fn {token, info}, acc ->
        if info.mode == :retired and (info.closed_ack or not Process.alive?(info.writer)) and
             not Enum.any?(acc.claims, fn {_, entry} -> entry.binding == token end) do
          slot = acc.writers[info.writer]

          %{
            acc
            | bindings: Map.delete(acc.bindings, token),
              writers: Map.put(acc.writers, info.writer, %{slot | binding: nil}),
              metadata_bytes: acc.metadata_bytes - info.bytes
          }
        else
          acc
        end
      end)

    Enum.reduce(gate.writers, gate, fn {pid, slot}, acc ->
      if slot.binding == nil and (slot.pending == nil or not Process.alive?(pid)),
        do: %{
          acc
          | writers: Map.delete(acc.writers, pid),
            metadata_bytes: acc.metadata_bytes - slot.bytes
        },
        else: acc
    end)
  end

  defp drop(gate, token) do
    case Map.pop(gate.claims, token) do
      {nil, _} -> gate
      {entry, claims} -> %{gate | claims: claims, bytes: gate.bytes - entry.bytes}
    end
  end

  defp reconcile_monitors(state, gate) do
    pids =
      [state.domain.root] ++
        Map.keys(gate.writers) ++
        Enum.flat_map(gate.bindings, fn {_, info} -> [info.writer, info.owner] end) ++
        Enum.map(gate.claims, fn {_, entry} ->
          if entry.stage in [:candidate, :prepared], do: entry.producer, else: entry.owner
        end)

    desired = MapSet.new(pids)

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn {pid, monitor}, acc ->
        if MapSet.member?(desired, pid),
          do: acc,
          else:
            (
              Process.demonitor(monitor, [:flush])
              Map.delete(acc, pid)
            )
      end)

    monitors =
      Enum.reduce(desired, monitors, fn pid, acc ->
        if Map.has_key?(acc, pid), do: acc, else: Map.put(acc, pid, Process.monitor(pid))
      end)

    %{state | monitors: monitors}
  end

  defp deliver_notices(state, gate, deadline) do
    _ =
      Enum.reduce_while(gate.bindings, :ok, fn {token, info}, _ ->
        if Deadline.now() >= deadline,
          do: {:halt, :ok},
          else:
            (
              notify_binding(state.domain, token, info, deadline)
              {:cont, :ok}
            )
      end)

    state
  end

  defp notify_binding(domain, token, _snapshot, deadline) do
    result =
      update(domain, deadline, fn gate ->
        case gate.bindings[token] do
          %{mode: :retired, closed_notice: false, closed_ack: false} = info ->
            queue_wake(gate, %{info | closed_notice: true})

          %{mode: :open, notice: false} = info ->
            entries = Enum.filter(Map.values(gate.claims), &(&1.binding == token))

            if Enum.any?(entries, &(&1.stage == :queued)) and
                 not Enum.any?(entries, &(&1.stage == :in_flight)),
               do: queue_wake(gate, %{info | notice: true}),
               else: {:ok, gate, :none}

          _ ->
            {:ok, gate, :none}
        end
      end)

    case result do
      {:wake, writer, nonce} -> send(writer, {:mcp_http_output_wake, domain, nonce})
      _ -> :ok
    end
  end

  defp queue_wake(gate, info) do
    slot = gate.writers[info.writer]
    nonce = slot.pending || make_ref()
    reply = if slot.pending, do: :none, else: {:wake, info.writer, nonce}

    next = %{
      gate
      | bindings: Map.put(gate.bindings, info.token, info),
        writers: Map.put(gate.writers, info.writer, %{slot | pending: nonce})
    }

    {:ok, next, reply}
  end

  defp ticket(domain, entry, writer),
    do: HTTPWriteTicket.new(domain, entry.token, entry.binding, writer, entry.receipt)

  defp claim_deadline(gate, token),
    do: if(gate.claims[token], do: gate.claims[token].deadline, else: Deadline.now())

  defp return_code(info, entry, result, domain) do
    cond do
      is_nil(info) or not Process.alive?(domain.root) or
        generation_valid(domain, info.proof.generation) != :ok or info.mode != :open or
        not source_current?(domain, info) or
        not binding_parties_alive?(info) or entry.deadline <= Deadline.now() ->
        3

      result == :ok ->
        1

      true ->
        2
    end
  end

  defp receipt_result(1), do: :ok
  defp receipt_result(2), do: {:error, :http_write_failed}
  defp receipt_result(3), do: {:error, :http_write_uncertain}
  defp receipt_result({:error, _} = error), do: error

  defp output_deadline(info, opts) do
    deadline = Keyword.get(opts, :deadline, info.proof.deadline)
    with :ok <- finite_deadline(deadline), do: {:ok, min(deadline, info.proof.deadline)}
  end

  defp open_binding(gate, token) do
    case gate.bindings[token] do
      %{mode: :open} = info ->
        if gate.sealed or info.proof.deadline <= Deadline.now() or not Process.alive?(info.owner) or
             not Process.alive?(info.writer),
           do: {:error, :http_invocation_closed},
           else: {:ok, info}

      _ ->
        {:error, :http_invocation_closed}
    end
  end

  defp runtime_valid(nil, _root), do: :ok

  defp runtime_valid(runtime, root) do
    with {:ok, runtime} <- Ref.validate(runtime),
         true <- Ref.supervisor(runtime) == root do
      :ok
    else
      _ -> {:error, :invalid_http_runtime}
    end
  end

  defp generation_valid(%__MODULE__{runtime: nil}, _generation), do: :ok

  defp generation_valid(%__MODULE__{runtime: runtime}, generation) do
    with {:ok, runtime} <- Ref.validate(runtime),
         [{:route, %{generation: ^generation, scheduler: scheduler}}] <-
           :ets.lookup(Ref.table(runtime), :route),
         true <- Process.alive?(scheduler) do
      :ok
    else
      _ -> {:error, :http_invocation_closed}
    end
  end

  defp proof_valid(proof, limits)
       when is_map(proof) and not is_struct(proof) and map_size(proof) == 5 do
    if MapSet.equal?(
         MapSet.new(Map.keys(proof)),
         MapSet.new([:invocation, :generation, :scope, :lease, :deadline])
       ) do
      with true <- is_reference(proof.invocation) and is_reference(proof.generation),
           :ok <- finite_deadline(proof.deadline),
           :ok <- before_deadline(proof.deadline),
           true <- :erlang.external_size(proof) <= limits.max_proof_bytes do
        :ok
      else
        _ -> {:error, :invalid_http_invocation_proof}
      end
    else
      {:error, :invalid_http_invocation_proof}
    end
  end

  defp proof_valid(_, _), do: {:error, :invalid_http_invocation_proof}
  defp finite_deadline(value) when is_integer(value), do: Deadline.validate(value)
  defp finite_deadline(_), do: {:error, :invalid_http_output_deadline}

  defp before_deadline(deadline),
    do: if(deadline > Deadline.now(), do: :ok, else: {:error, :http_output_expired})

  defp wire_valid(wire, limits) when is_binary(wire),
    do:
      if(byte_size(wire) <= limits.max_io_frame_bytes,
        do: :ok,
        else: {:error, :http_frame_too_large}
      )

  defp wire_valid(_, _), do: {:error, :invalid_http_wire}

  defp reason_valid(reason) when is_atom(reason),
    do:
      if(:erlang.external_size(reason) <= 64, do: :ok, else: {:error, :invalid_http_close_reason})

  defp reason_valid(_), do: {:error, :invalid_http_close_reason}

  defp local_pid(pid) when is_pid(pid) and node(pid) == node(),
    do: if(Process.alive?(pid), do: :ok, else: {:error, :invalid_http_owner})

  defp local_pid(_), do: {:error, :invalid_http_owner}

  defp control_deadline(%__MODULE__{limits: limits}),
    do: Deadline.now() + limits.control_timeout_ms

  defp control_deadline(_), do: Deadline.now()

  defp valid(%__MODULE__{pid: pid} = domain) when is_pid(pid) do
    if node(domain.pid) == node() and Process.alive?(domain.pid),
      do: {:ok, domain},
      else: {:error, :http_writer_unavailable}
  end

  defp valid(_), do: {:error, :http_writer_unavailable}

  defp read(domain) do
    with {:ok, domain} <- valid(domain),
         [{:gate, %{identity: identity} = gate}] <- :ets.lookup(domain.table, :gate),
         true <- identity == domain.identity do
      {:ok, gate}
    else
      _ -> {:error, :http_writer_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_writer_unavailable}
  end

  defp update(domain, deadline, function, attempts \\ @attempts)
  defp update(_domain, _deadline, _function, 0), do: {:error, :http_writer_contended}

  defp update(domain, deadline, function, attempts) do
    with :ok <- before_deadline(deadline),
         {:ok, gate} <- read(domain),
         {:ok, next, result} <- function.(gate),
         :ok <- before_deadline(deadline) do
      if gate == next or replace(domain.table, gate, next),
        do: result,
        else: update(domain, deadline, function, attempts - 1)
    end
  end

  defp replace(table, previous, next) do
    :ets.select_replace(table, [
      {{:gate, :"$1"}, [{:"=:=", :"$1", {:const, previous}}], [{:const, {:gate, next}}]}
    ]) == 1
  rescue
    ArgumentError -> false
  end

  defp wake(%__MODULE__{} = domain) do
    if :ets.insert_new(domain.table, {:wake, true}), do: send(domain.pid, :wake)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp idle?(%{idle_since: nil}), do: false
  defp idle?(state), do: Deadline.now() - state.idle_since >= state.domain.limits.idle_exit_ms
end
