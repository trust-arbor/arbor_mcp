defmodule Arbor.MCP.Server.Runtime.HTTPWriterRegistry do
  @moduledoc false
  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    HTTPListenerBinding,
    HTTPListenerCompletion,
    HTTPSessionStreamBinding,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriteTicket,
    Ref,
    Scheduler,
    ServiceRef,
    Services
  }

  alias Arbor.MCP.Server.Runtime.OutputTicket

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
    idle_exit_ms: 100,
    failure_timeout_ms: 5_000
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
  def capture(domain, proxy, deadline), do: capture(domain, proxy, deadline, Deadline.now())

  @spec capture(t(), pid(), Deadline.t(), Deadline.t()) :: {:ok, HTTPWriterBinding.t()} | error()
  def capture(domain, proxy, deadline, started) do
    with {:ok, domain} <- valid(domain),
         true <- installed_proxy?(domain, proxy),
         {:ok, generation} <- current_generation(domain),
         :ok <- finite_deadline(deadline),
         :ok <- finite_deadline(started),
         true <- started <= Deadline.now(),
         {:ok, deadline, listener_deadline, session_deadline} <-
           bounded_capture_cutoffs(domain, deadline, started),
         :ok <- before_deadline(deadline) do
      invocation = make_ref()

      proof = %{
        invocation: invocation,
        generation: generation,
        scope: {HTTPWriterProxy, invocation},
        lease: nil,
        deadline: deadline
      }

      authority = %{
        phase: :entered,
        lease_bound: false,
        work: nil,
        listener: %{deadline: listener_deadline, registration: make_ref(), state: :available},
        legacy_stream: %{deadline: session_deadline, registration: make_ref(), state: :available},
        failure: %{
          deadline: deadline + domain.limits.failure_timeout_ms,
          state: :available,
          token: make_ref(),
          effect: make_ref(),
          controller: self()
        }
      }

      register_entry(domain, self(), proof, proxy, authority)
    else
      _invalid -> {:error, :http_invocation_closed}
    end
  end

  # Establishment uses the original entry and an actually admitted Gateway
  # token. The long listener lifetime never becomes an RPC/service deadline.
  @spec establish_listener(HTTPWriterBinding.t(), reference(), keyword()) ::
          {:ok, HTTPListenerBinding.t()} | error()
  def establish_listener(binding, source, opts \\ []) do
    result =
      mutate_capture(
        binding,
        fn domain, info -> establish_listener_current(domain, info, source, opts) end,
        :gateway
      )

    with :ok <- result,
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{authority: %{listener: listener}} <- gate.bindings[token] do
      {:ok, HTTPListenerBinding.new(binding, listener.registration)}
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :invalid_http_listener_binding}
    end
  end

  defp establish_listener_current(domain, info, source, opts) do
    with %{state: :available, deadline: maximum} = listener when is_integer(maximum) <-
           info.authority.listener,
         true <- listener_setup_source?(domain, info.authority, source),
         true <- not info.authority.lease_bound,
         {:ok, settings} <- listener_options(opts),
         {:ok, reservation} <- Admission.current(Ref.table(domain.runtime), source),
         true <-
           reservation.owner == self() and not reservation.terminal and not reservation.batch?,
         true <-
           reservation.generation == info.proof.generation and
             reservation.scope == info.proof.scope,
         true <- reservation.kind == :rpc,
         true <- reservation.deadline > Deadline.now() and info.proof.deadline > Deadline.now(),
         deadline = min(maximum, settings.deadline || maximum),
         :ok <- before_deadline(deadline) do
      listener =
        Map.merge(listener, %{
          state: :established,
          gateway: self(),
          generation: reservation.generation,
          source: source,
          source_phase: reservation.output_phase,
          source_deadline: min(reservation.deadline, info.proof.deadline),
          endpoint: settings.endpoint,
          identity: materialize_identity(settings.identity),
          deadline: deadline,
          terminal: %{
            deadline: deadline + domain.limits.failure_timeout_ms,
            state: 1,
            token: make_ref(),
            effect: make_ref()
          }
        })

      {:ok, %{info | authority: %{info.authority | phase: :listener, listener: listener}}}
    else
      _invalid -> {:error, :invalid_http_listener_binding}
    end
  end

  defp listener_setup_source?(_domain, %{phase: :entered, work: nil}, _source), do: true

  defp listener_setup_source?(domain, %{phase: :bound, work: %{token: token} = work}, source),
    do: token == source and not Map.has_key?(work, :final) and work_current?(domain, work)

  defp listener_setup_source?(_domain, _authority, _source), do: false

  # Failed setup may return to its original scalar error-response authority.
  # No listener capability or deadline is renewed, and establishment stays spent.
  def reject_listener_setup(binding, source) do
    mutate_capture(
      binding,
      fn domain, info ->
        case info.authority.listener do
          %{source: ^source, source_phase: phase} = listener ->
            if listener_setup_rejection_current?(domain, info, source, phase) do
              authority = %{
                info.authority
                | phase: :bound,
                  listener: %{listener | state: :failed}
              }

              {:ok, %{info | authority: authority}}
            else
              {:error, :http_listener_closed}
            end

          _invalid ->
            {:error, :http_listener_closed}
        end
      end,
      :gateway,
      :listener_setup
    )
  end

  defp listener_setup_rejection_current?(domain, info, source, phase) do
    with 1 <- :atomics.get(phase, 1),
         {:ok, reservation} <- Admission.current(Ref.table(domain.runtime), source),
         true <- reservation.owner == self() and not reservation.terminal,
         true <- reservation.generation == info.proof.generation,
         true <- reservation.scope == info.proof.scope and reservation.output_phase == phase,
         do: reservation.deadline > Deadline.now(),
         else: (_retired -> false)
  end

  def attach_listener(listener, pid, registration, subscription_id) do
    with {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         :ok <- local_pid(pid),
         true <- is_binary(registration) and byte_size(registration) in 1..128 do
      mutate_capture(
        binding,
        fn _domain, info ->
          with %{registration: ^nonce, state: :established} = proof <- info.authority.listener,
               false <- Map.has_key?(proof, :pid),
               true <- Process.alive?(pid) do
            proof =
              Map.merge(proof, %{
                pid: pid,
                token: :binary.copy(registration),
                id:
                  if(is_binary(subscription_id),
                    do: :binary.copy(subscription_id),
                    else: subscription_id
                  )
              })

            {:ok, %{info | authority: %{info.authority | listener: proof}}}
          else
            _invalid -> {:error, :http_listener_closed}
          end
        end,
        :gateway,
        :listener
      )
    else
      _invalid -> {:error, :http_listener_closed}
    end
  end

  def listener_setup(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         true <- info.writer == self(),
         %{state: :established, registration: nonce, pid: pid, token: registration} = proof <-
           info.authority.listener,
         true <- :atomics.get(proof.source_phase, 1) == 2 and listener_current?(domain, info) do
      {:listener, HTTPListenerBinding.new(binding, nonce), pid, registration}
    else
      _not_ready -> :empty
    end
  end

  # A fixed completion is the only frame allowed to use the immutable listener
  # tail. It is authorized by the exact owned Listener and prepared by its
  # actual borrowed socket; publications and service claims cannot use it.
  def authorize_listener_completion(listener) do
    with {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{authority: %{listener: %{registration: ^nonce, pid: pid, terminal: terminal}}} <-
           gate.bindings[token],
         true <- pid == self(),
         :ok <-
           update(domain, terminal.deadline, fn gate ->
             info = gate.bindings[token]

             with %{state: 1} = terminal <- info.authority.listener.terminal,
                  true <- listener_domain_current?(domain, info),
                  true <- terminal.deadline > Deadline.now() do
               proof = %{info.authority.listener | terminal: %{terminal | state: 2}}

               next = %{
                 info
                 | mode: :listener_tail,
                   authority: %{info.authority | listener: proof}
               }

               {:ok, listener_tail(gate, next), :ok}
             else
               _invalid -> {:error, :http_listener_completion_closed}
             end
           end) do
      {:ok, HTTPListenerCompletion.new(listener, terminal.token)}
    else
      _invalid -> {:error, :http_listener_completion_closed}
    end
  end

  def validate_listener_completion(completion) do
    with {:ok, listener, receipt} <- HTTPListenerCompletion.address(completion),
         {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{
           authority: %{
             listener: %{registration: ^nonce, terminal: %{token: ^receipt} = terminal}
           }
         } = info <- gate.bindings[token],
         true <- not gate.sealed and terminal.state in [2, 3],
         true <- terminal.deadline > Deadline.now() and listener_domain_current?(domain, info) do
      {:ok, %{deadline: terminal.deadline, runtime: domain.runtime, writer: info.writer}}
    else
      _invalid -> {:error, :http_listener_completion_closed}
    end
  rescue
    ArgumentError -> {:error, :http_listener_completion_closed}
  end

  def listener_wait_deadline(listener, runtime) do
    with {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         true <- domain.runtime == runtime,
         {:ok, gate} <- read(domain),
         %{writer: writer, authority: %{listener: %{registration: ^nonce} = proof}} = info <-
           gate.bindings[token],
         true <- writer == self() and not gate.sealed and listener_domain_current?(domain, info),
         true <- proof.terminal.deadline > Deadline.now() do
      {:ok, proof.terminal.deadline}
    else
      _retired -> {:error, :http_listener_closed}
    end
  end

  def prepare_listener_completion(completion) do
    with {:ok, listener, receipt} <- HTTPListenerCompletion.address(completion),
         {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{
           writer: writer,
           authority: %{
             listener:
               %{registration: ^nonce, terminal: %{state: 2, token: ^receipt} = terminal} =
                 listener_proof
           }
         } = info <- gate.bindings[binding_token],
         true <- writer == self(),
         {:ok, _proof} <- validate_listener_completion(completion),
         wire = listener_completion_wire(listener_proof.id),
         :ok <- wire_valid(wire, domain.limits),
         token = terminal.effect,
         entry =
           candidate(
             token,
             binding_token,
             self(),
             self(),
             terminal.deadline,
             wire,
             %{listener_completion: completion},
             0
           ),
         :ok <- update(domain, terminal.deadline, &claim(&1, entry, domain)) do
      finish_prepare(domain, entry, info.writer, wire)
    else
      _invalid -> {:error, :http_listener_completion_closed}
    end
  end

  defp listener_completion_wire(id) do
    value = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
      }
    }

    "data: " <> Jason.encode!(value) <> "\r\n\r\n"
  end

  defp listener_domain_current?(domain, %{authority: %{listener: %{pid: pid} = proof}} = info) do
    installed_proxy?(domain, info.owner) and
      registered_actor?(domain, :http_gateway, proof.gateway) and
      generation_valid(domain, proof.generation) == :ok and
      Process.alive?(info.writer) and Process.alive?(pid) and
      :atomics.get(proof.source_phase, 1) == 2
  end

  defp listener_domain_current?(_domain, _info), do: false

  defp listener_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 3 and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:deadline, :endpoint, :identity])) do
      endpoint = Keyword.get(opts, :endpoint, "/mcp")
      identity = Keyword.get(opts, :identity)
      deadline = Keyword.get(opts, :deadline)

      with true <- is_binary(endpoint) and byte_size(endpoint) in 1..4_096,
           true <- listener_identity?(identity, endpoint),
           true <- is_nil(deadline) or finite_deadline(deadline) == :ok do
        {:ok, %{endpoint: :binary.copy(endpoint), identity: identity, deadline: deadline}}
      else
        _invalid -> {:error, :invalid_http_listener_options}
      end
    else
      {:error, :invalid_http_listener_options}
    end
  end

  defp listener_options(_opts), do: {:error, :invalid_http_listener_options}
  defp listener_identity?(nil, _endpoint), do: true

  defp listener_identity?({endpoint, principal, tenant}, endpoint),
    do:
      is_binary(principal) and byte_size(principal) in 1..4_096 and
        (is_nil(tenant) or (is_binary(tenant) and byte_size(tenant) in 1..4_096))

  defp listener_identity?(_identity, _endpoint), do: false

  defp materialize_identity(nil), do: nil

  defp materialize_identity({endpoint, principal, tenant}),
    do: {:binary.copy(endpoint), :binary.copy(principal), if(tenant, do: :binary.copy(tenant))}

  @spec validate_listener(HTTPListenerBinding.t()) :: {:ok, map()} | error()
  def validate_listener(listener) do
    with {:ok, binding, _registration} <- HTTPListenerBinding.address(listener),
         {:ok, {%__MODULE__{runtime: runtime}, _token}} <-
           HTTPWriterBinding.address(binding) do
      validate_listener(listener, runtime)
    else
      _invalid -> {:error, :http_listener_closed}
    end
  end

  @spec validate_listener(HTTPListenerBinding.t(), Ref.t()) :: {:ok, map()} | error()
  def validate_listener(listener, runtime) do
    with {:ok, runtime} <- Ref.validate(runtime),
         {:ok, binding, registration} <- HTTPListenerBinding.address(listener),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         true <- domain.runtime == runtime,
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         %{state: :established, registration: ^registration} = proof <- info.authority.listener,
         true <- listener_current?(domain, info) do
      {:ok,
       Map.merge(proof, %{
         runtime: runtime,
         writer: info.writer,
         owner: info.owner,
         scope: info.proof.scope
       })}
    else
      _invalid -> {:error, :http_listener_closed}
    end
  rescue
    ArgumentError -> {:error, :http_listener_closed}
  end

  defp listener_current?(domain, %{authority: %{listener: listener}} = info) do
    listener.state == :established and listener.terminal.state == 1 and
      listener.deadline > Deadline.now() and
      installed_proxy?(domain, info.owner) and
      registered_actor?(domain, :http_gateway, listener.gateway) and
      generation_valid(domain, listener.generation) == :ok and
      case :atomics.get(listener.source_phase, 1) do
        1 -> listener.source_deadline > Deadline.now()
        2 -> true
        _failed -> false
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

  def source_valid?(binding, source) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{authority: %{work: %{token: ^source}}} = info <- gate.bindings[id],
         true <- source_current?(domain, info),
         do: true,
         else: (_ -> false)
  end

  # Replay preparation is authorized by the actual promoted producer. This
  # snapshot is metadata only; protocol output remains in its admitted ledger.
  def event_source(binding, source, primary) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{authority: %{work: %{token: ^source}}} = info <- gate.bindings[id],
         true <- source_current?(domain, info),
         table = Ref.table(domain.runtime),
         {:ok, reservation} <- Admission.current(table, source),
         {:ok, %{scheduler: scheduler}} <- Admission.route(table),
         {:ok, producer_metadata} <- event_producer_metadata(table, reservation),
         true <- not is_nil(info.proof.lease),
         [{:output_controller, controller}] <- :ets.lookup(table, :output_controller),
         true <- Process.alive?(controller),
         :ok <- OutputTicket.validate_scope(primary, event_scope(reservation)) do
      {:ok,
       %{
         runtime: domain.runtime,
         binding: binding,
         token: source,
         generation: reservation.generation,
         scope: reservation.scope,
         owner: reservation.owner,
         controller: controller,
         scheduler: scheduler,
         phase: reservation.output_phase,
         producer: self(),
         writer: info.writer,
         lease: info.proof.lease,
         primary: OutputTicket.identity(primary),
         group: reservation.batch?,
         initialization: producer_metadata.initialization,
         deadline: min(reservation.deadline, info.proof.deadline)
       }}
    else
      _invalid -> {:error, :invalid_session_event_origin}
    end
  rescue
    ArgumentError -> {:error, :invalid_session_event_origin}
  end

  defp event_producer_metadata(table, reservation) do
    case CallbackContext.current() do
      %{table: ^table, token: token, generation: generation, scope: scope, output_phase: phase} ->
        if token == reservation.token and generation == reservation.generation and
             scope == reservation.scope and phase == reservation.output_phase and
             Admission.origin_active?(table, %{
               token: token,
               generation: generation,
               scope: scope,
               output_phase: phase,
               owner: reservation.owner
             }),
           do: Scheduler.output_producer_metadata(table, reservation),
           else: {:error, :invalid_output_producer}

      nil ->
        if :ets.lookup(table, :http_gateway) == [{:http_gateway, self()}] and
             reservation.owner == self(),
           do: {:ok, %{initialization: false}},
           else: {:error, :invalid_output_producer}

      _invalid ->
        {:error, :invalid_output_producer}
    end
  end

  defp event_scope(%{batch?: true} = reservation),
    do: {:batch, reservation.generation, reservation.token}

  defp event_scope(reservation),
    do: {:work, reservation.generation, reservation.token}

  def event_preparation_authorized?(source, producer) do
    table = Ref.table(source.runtime)

    with true <- event_source_current?(source),
         true <- source.producer == producer,
         {:ok, %{server: store}} <-
           Services.resolve(source.runtime, :sessions),
         true <- store == self(),
         {:ok, reservation} <- Admission.current(table, source.token),
         true <- reservation.output_phase == source.phase do
      if :ets.lookup(table, :http_gateway) == [{:http_gateway, producer}] do
        reservation.owner == producer and source.initialization == false
      else
        Scheduler.replay_producer_metadata(table, reservation, producer) ==
          {:ok, %{initialization: source.initialization}}
      end
    else
      _untrusted -> false
    end
  rescue
    _invalid -> false
  end

  def event_source_current?(source) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(source.binding),
         true <- domain.runtime == source.runtime,
         {:ok, gate} <- read(domain),
         %{writer: writer, authority: %{work: work}, proof: proof} = info <- gate.bindings[id],
         true <-
           writer == source.writer and proof.generation == source.generation and
             proof.scope == source.scope and proof.lease == source.lease,
         true <- work.token == source.token and work.gateway == source.owner,
         true <- registered_actor?(domain, :output_controller, source.controller),
         {:ok, %{scheduler: scheduler}} <- Admission.route(Ref.table(source.runtime)),
         true <- scheduler == source.scheduler,
         true <- source.deadline > Deadline.now(),
         do: source_current?(domain, info),
         else: (_retired -> false)
  rescue
    _exception -> false
  end

  def event_publication_authorized?(source, primary, actor) do
    with true <- event_source_current?(source),
         {:ok, {domain, id}} <- HTTPWriterBinding.address(source.binding),
         {:ok, gate} <- read(domain),
         %{writer: writer, authority: %{work: work}} <- gate.bindings[id],
         true <-
           actor == writer or
             (actor == source.controller and registered_actor?(domain, :output_controller, actor)) do
      event_committed?(domain, work, primary)
    else
      _retired -> false
    end
  rescue
    _exception -> false
  end

  defp event_committed?(_domain, %{kind: :batch, final: {:done, identity}}, primary),
    do: OutputTicket.identity(primary) == identity

  defp event_committed?(domain, %{token: token, phase: phase}, primary) do
    with 2 <- :atomics.get(phase, 1),
         [{_, committed}] <- :ets.lookup(Ref.table(domain.runtime), {:output_commit, token}),
         do: OutputTicket.same?(committed, primary),
         else: (_uncommitted -> false)
  end

  defp event_committed?(_domain, _work, _primary), do: false

  # The socket publishes a bounded setup descriptor before notifying Gateway.
  # Only Gateway can establish the long target, under original entry authority.
  def request_session_stream(binding, endpoint) do
    mutate_capture(binding, fn domain, info ->
      with %{state: :available, deadline: maximum} = stream when is_integer(maximum) <-
             info.authority.legacy_stream,
           true <- info.authority.phase == :entered and info.authority.work == nil,
           :ok <- generation_valid(domain, info.proof.generation),
           true <- info.authority.lease_bound and not is_nil(info.proof.lease),
           true <- is_binary(endpoint) and byte_size(endpoint) in 1..4_096 do
        stream = %{stream | state: :requested} |> Map.put(:endpoint, :binary.copy(endpoint))
        {:ok, %{info | authority: %{info.authority | legacy_stream: stream}}}
      else
        _invalid -> {:error, :invalid_http_session_stream}
      end
    end)
  end

  def session_stream_setup(binding) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(binding),
         true <- registered_actor?(domain, :http_gateway, self()),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, id),
         true <- captured_current?(domain, info),
         :ok <- generation_valid(domain, info.proof.generation),
         %{state: :requested, endpoint: endpoint} <- info.authority.legacy_stream,
         do:
           {:ok,
            %{
              runtime: domain.runtime,
              writer: info.writer,
              lease: info.proof.lease,
              endpoint: endpoint,
              deadline: info.proof.deadline
            }},
         else: (_invalid -> {:error, :invalid_http_session_stream})
  end

  def establish_session_stream(binding, lease_expiry) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         true <- capture_mutation_current?(:gateway, :request, domain, info),
         :ok <-
           update(domain, info.proof.deadline, fn current ->
             establish_session_stream_current(current, domain, token, lease_expiry)
           end),
         {:ok, gate} <- read(domain),
         %{authority: %{legacy_stream: stream}} <- gate.bindings[token] do
      wake(domain)
      {:ok, HTTPSessionStreamBinding.new(binding, stream.registration)}
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :invalid_http_session_stream}
    end
  end

  defp establish_session_stream_current(gate, domain, token, lease_expiry) do
    with {:ok, info} <- open_binding(gate, token),
         true <- session_setup_current?(domain, info),
         %{state: :requested, deadline: maximum} = stream <- info.authority.legacy_stream,
         :ok <- finite_deadline(lease_expiry),
         deadline = min(maximum, lease_expiry),
         :ok <- before_deadline(deadline) do
      stream =
        Map.merge(stream, %{
          state: :established,
          deadline: deadline,
          gateway: self(),
          generation: info.proof.generation
        })

      next = %{
        info
        | authority:
            info.authority
            |> Map.put(:phase, :legacy_session_stream)
            |> Map.put(:legacy_stream, stream)
            |> Map.put(:session_stream, true)
      }

      with {:ok, gate, :ok} <- store_capture(gate, domain, token, next) do
        {:ok, retire_other_session_streams(gate, token, info.proof.lease), :ok}
      end
    else
      _invalid -> {:error, :invalid_http_session_stream}
    end
  end

  defp session_setup_current?(domain, info),
    do:
      capture_mutation_current?(:gateway, :request, domain, info) and
        generation_valid(domain, info.proof.generation) == :ok

  defp retire_other_session_streams(gate, token, lease) do
    Enum.reduce(gate.bindings, gate, fn {old_token, old}, current ->
      if old_token != token and Map.get(old.authority || %{}, :session_stream, false) and
           old.proof.lease == lease,
         do: elem(retire_binding(current, old_token, :session_stream_replaced), 1),
         else: current
    end)
  end

  def validate_session_stream(stream, runtime) do
    with {:ok, runtime} <- Ref.validate(runtime),
         {:ok, binding, registration} <- HTTPSessionStreamBinding.address(stream),
         {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         true <- domain.runtime == runtime,
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         %{registration: ^registration} = proof <- info.authority.legacy_stream,
         true <- session_stream_current?(domain, info),
         do:
           {:ok,
            Map.merge(proof, %{
              runtime: runtime,
              writer: info.writer,
              lease: info.proof.lease,
              scope: info.proof.scope
            })},
         else: (_invalid -> {:error, :http_session_stream_closed})
  rescue
    ArgumentError -> {:error, :http_session_stream_closed}
  end

  defp session_stream_current?(
         domain,
         %{authority: %{phase: :legacy_session_stream, legacy_stream: stream}} = info
       ) do
    stream.state == :established and stream.deadline > Deadline.now() and
      installed_proxy?(domain, info.owner) and
      registered_actor?(domain, :http_gateway, stream.gateway) and
      generation_valid(domain, stream.generation) == :ok and
      Process.alive?(info.writer) and lease_current?(domain, info.proof.lease)
  end

  defp session_stream_current?(_domain, _info), do: false

  # The existing charged writer row is the session stream registration. A
  # replacement retires the old binding; it never kills a borrowed socket PID
  # or releases an IO liability that has already started.
  @spec register_session_stream(HTTPWriterBinding.t()) :: :ok | error()
  def register_session_stream(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, proof} <- proof(binding),
         result <-
           update(domain, proof.deadline, fn gate ->
             register_session_stream_current(gate, domain, token)
           end) do
      wake(domain)
      result
    end
  end

  defp register_session_stream_current(gate, domain, token) do
    with {:ok, info} <- open_binding(gate, token),
         true <- info.writer == self() and captured_current?(domain, info),
         true <- info.authority.lease_bound and info.authority.work == nil,
         false <- Map.get(info.authority, :session_stream, false) do
      next = %{info | authority: Map.put(info.authority, :session_stream, true), bytes: 0}
      next = %{next | bytes: :erlang.external_size(next) + 256}
      bytes = gate.metadata_bytes - info.bytes + next.bytes

      if bytes <= domain.limits.max_writer_metadata_bytes do
        gate = %{gate | bindings: Map.put(gate.bindings, token, next), metadata_bytes: bytes}

        gate =
          Enum.reduce(gate.bindings, gate, fn {old_token, old}, gate ->
            if old_token != token and Map.get(old.authority || %{}, :session_stream, false) and
                 old.proof.lease == info.proof.lease do
              elem(retire_binding(gate, old_token, :session_stream_replaced), 1)
            else
              gate
            end
          end)

        {:ok, gate, :ok}
      else
        {:error, :http_writer_busy}
      end
    else
      _invalid -> {:error, :invalid_http_session_stream}
    end
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

  # The root-installed gateway binds the phase after promotion. The actual
  # socket cannot author a future callback phase or an aggregate outcome.
  def bind_dispatched(binding, token) when is_reference(token) do
    mutate_capture(
      binding,
      fn domain, info ->
        with true <- info.authority.work == nil,
             {:ok, reservation} <- Admission.current(Ref.table(domain.runtime), token),
             true <-
               reservation.generation == info.proof.generation and
                 reservation.scope == info.proof.scope and reservation.owner == self() and
                 not reservation.terminal do
          work = dispatched_proof(domain, info, reservation)
          {:ok, %{info | authority: %{info.authority | work: work, phase: :bound}}}
        else
          _invalid -> {:error, :invalid_http_work_origin}
        end
      end,
      :gateway
    )
  end

  def bind_dispatched(_binding, _token), do: {:error, :invalid_http_work_origin}

  defp dispatched_proof(domain, info, reservation) do
    base = %{
      token: reservation.token,
      generation: reservation.generation,
      scope: reservation.scope,
      deadline: min(reservation.deadline, info.proof.deadline),
      gateway: self()
    }

    if reservation.batch? do
      Map.merge(base, %{
        kind: :batch,
        final:
          {:pending,
           {self(), domain.table, make_ref(), make_ref(),
            {:batch, reservation.generation, reservation.token}}}
      })
    else
      Map.put(base, :phase, reservation.output_phase)
    end
  end

  def finalize_batch(binding, token, primary) do
    mutate_capture(
      binding,
      fn domain, info ->
        with %{kind: :batch, token: ^token, final: {:pending, _reserved}} = work <-
               info.authority.work,
             :ok <- OutputTicket.validate_scope(primary, {:batch, work.generation, work.token}),
             {:ok, values} when is_list(values) <-
               Arbor.MCP.Server.Runtime.OutputLedger.value(primary),
             true <- work_current?(domain, work) do
          final = %{work | final: {:done, OutputTicket.identity(primary)}}
          {:ok, %{info | authority: %{info.authority | work: final}}}
        else
          _invalid -> {:error, :invalid_http_batch_outcome}
        end
      end,
      :controller
    )
  end

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

  defp mutate_capture(binding, operation, actor \\ :writer, mode \\ :request) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, token),
         true <- capture_actor?(actor, domain, info) and mutation_current?(mode, domain, info) do
      update(domain, info.proof.deadline, fn current ->
        with {:ok, info} <- open_binding(current, token),
             true <- capture_mutation_current?(actor, mode, domain, info),
             {:ok, next} <- operation.(domain, info) do
          store_capture(current, domain, token, next)
        else
          false -> {:error, :http_invocation_closed}
          error -> error
        end
      end)
    else
      _invalid -> {:error, :http_invocation_closed}
    end
  end

  defp store_capture(current, domain, token, next) do
    previous = current.bindings[token]
    next = %{next | bytes: 0}
    next = %{next | bytes: :erlang.external_size(next) + 256}
    bytes = current.metadata_bytes - previous.bytes + next.bytes

    if bytes <= domain.limits.max_writer_metadata_bytes,
      do:
        {:ok,
         %{current | bindings: Map.put(current.bindings, token, next), metadata_bytes: bytes},
         :ok},
      else: {:error, :http_writer_busy}
  end

  defp mutation_current?(:request, domain, info), do: captured_current?(domain, info)
  defp mutation_current?(:listener, domain, info), do: listener_current?(domain, info)

  defp mutation_current?(:listener_setup, domain, info),
    do: listener_current?(domain, info) and not Map.has_key?(info.authority.listener, :pid)

  defp capture_mutation_current?(actor, mode, domain, info),
    do: capture_actor?(actor, domain, info) and mutation_current?(mode, domain, info)

  defp capture_actor?(:writer, _domain, info), do: info.writer == self()

  defp capture_actor?(:gateway, domain, _info),
    do: registered_actor?(domain, :http_gateway, self())

  defp capture_actor?(:controller, domain, _info),
    do: registered_actor?(domain, :output_controller, self())

  defp registered_actor?(domain, key, pid) do
    :ets.lookup(Ref.table(domain.runtime), key) == [{key, pid}] and Process.alive?(pid)
  rescue
    ArgumentError -> false
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

  defp work_current?(domain, %{kind: :batch} = work) do
    table = Ref.table(domain.runtime)

    with {:ok, %{generation: generation}} <- Admission.route(table),
         true <- generation == work.generation and work.deadline > Deadline.now(),
         true <- registered_actor?(domain, :http_gateway, work.gateway),
         false <- :ets.member(table, {:cancelled, work.token}) do
      case work.final do
        {:pending, _reserved} ->
          case Admission.current(table, work.token) do
            {:ok, %{generation: ^generation, scope: scope, batch?: true}} -> scope == work.scope
            _invalid -> false
          end

        {:done, {_ledger, _table, _generation, _token, {:batch, ^generation, token}}} ->
          token == work.token
      end
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  defp work_current?(domain, %{gateway: gateway} = proof),
    do:
      registered_actor?(domain, :http_gateway, gateway) and
        Admission.output_origin_valid?(Ref.table(domain.runtime), proof)

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

  defp bounded_capture_cutoffs(domain, deadline, started) do
    case :ets.lookup(Ref.table(domain.runtime), :http_writer_domain) do
      [{:http_writer_domain, record}] ->
        listener_deadline =
          case Map.get(record, :listener_lifetime_ms) do
            value when is_integer(value) and value > 0 and value <= 0xFFFFFFFF -> started + value
            _disabled -> nil
          end

        session_deadline =
          case Map.get(record, :session_lifetime_ms) do
            value when is_integer(value) and value > 0 and value <= 0xFFFFFFFF -> started + value
            _disabled -> nil
          end

        {:ok, min(deadline, started + record.request_timeout_ms), listener_deadline,
         session_deadline}

      _retired ->
        {:error, :http_invocation_closed}
    end
  rescue
    ArgumentError -> {:error, :http_invocation_closed}
  end

  defp source_current?(domain, %{mode: mode} = info)
       when mode in [:listener_tail, :listener_completion],
       do:
         info.authority.listener.terminal.deadline > Deadline.now() and
           listener_domain_current?(domain, info)

  defp source_current?(domain, %{authority: %{phase: :legacy_session_stream}} = info),
    do: session_stream_current?(domain, info)

  defp source_current?(domain, %{authority: %{phase: :listener}} = info),
    do: listener_current?(domain, info)

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
    release_owner = Keyword.get(opts, :release_owner, owner)

    with {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         {:ok, domain} <- valid(domain),
         :ok <- local_pid(owner),
         :ok <- local_pid(release_owner),
         {:ok, gate} <- read(domain),
         true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
         {:ok, info} <- open_binding(gate, binding_token),
         true <- source_current?(domain, info) || {:error, :http_invocation_closed},
         {:ok, deadline} <- output_deadline(info, opts),
         :ok <- wire_valid(wire, domain.limits),
         {:ok, metadata, handles} <- output_metadata(opts, domain.limits),
         :ok <- before_deadline(deadline),
         token = make_ref(),
         entry =
           candidate(
             token,
             binding_token,
             owner,
             release_owner,
             deadline,
             wire,
             metadata,
             handles
           ),
         :ok <- update(domain, deadline, &claim(&1, entry, domain)) do
      finish_prepare(domain, entry, info.writer, wire)
    else
      error -> error
    end
  end

  def failure_deadline(binding, token) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(binding),
         true <- registered_actor?(domain, :output_controller, self()),
         {:ok, gate} <- read(domain),
         %{} = info <- gate.bindings[id] do
      failure_authority(domain, info, token)
    else
      _invalid -> {:error, :http_failure_expired}
    end
  end

  def prepare_failure(binding, reservation_token, wire, opts) do
    with {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{authority: %{failure: %{state: :available}}} = info <- gate.bindings[binding_token],
         true <- registered_actor?(domain, :output_controller, self()),
         {:ok, deadline} <- failure_authority(domain, info, reservation_token),
         :ok <- wire_valid(wire, domain.limits),
         {:ok, metadata, handles} <- output_metadata(opts, domain.limits),
         token = make_ref(),
         entry =
           candidate(
             token,
             binding_token,
             self(),
             self(),
             deadline,
             wire,
             Map.put(metadata, :failure_token, reservation_token),
             handles
           ),
         :ok <- update(domain, deadline, &claim(&1, entry, domain)) do
      finish_prepare(domain, entry, info.writer, wire)
    else
      false -> {:error, :invalid_http_failure_authority}
      _invalid -> {:error, :http_failure_expired}
    end
  end

  defp failure_authority(domain, info, token) do
    with %{
           work: %{token: ^token, gateway: gateway},
           failure: %{state: :available, deadline: tail}
         } <- info.authority,
         true <- registered_actor?(domain, :http_gateway, gateway),
         :ok <- generation_valid(domain, info.proof.generation),
         true <- binding_parties_alive?(info) and lease_current?(domain, info.proof.lease),
         [{_, %{generation: generation, scope: scope, caller: caller, deadline: deadline}}] <-
           :ets.lookup(Ref.table(domain.runtime), {:output_failure, token}),
         true <-
           generation == info.proof.generation and scope == info.proof.scope and
             caller == info.writer,
         deadline = min(deadline, tail),
         true <- deadline > Deadline.now() do
      {:ok, deadline}
    else
      _invalid -> {:error, :http_failure_expired}
    end
  rescue
    ArgumentError -> {:error, :http_failure_expired}
  end

  @spec prepared?(HTTPWriteTicket.t()) :: boolean()
  def prepared?(ticket) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(ticket),
         {:ok, gate} <- read(domain),
         %{binding: ^binding, stage: stage} = entry <- gate.claims[token],
         true <- stage in [:prepared, :held],
         true <-
           entry.deadline > Deadline.now() and active_producer?(entry) and
             Process.alive?(entry.owner),
         true <- :atomics.get(entry.receipt, 2) == 0,
         {:ok, info} <- io_binding(gate, binding),
         true <- entry_current?(domain, info, entry),
         :ok <- generation_valid(domain, info.proof.generation) do
      HTTPWriteTicket.receipt_matches?(ticket, entry.receipt)
    else
      _invalid -> false
    end
  end

  defp output_metadata(opts, limits) do
    metadata = Keyword.get(opts, :metadata)
    handles = Keyword.get(opts, :handle_bytes, 0)

    if :erlang.external_size(metadata) <= limits.max_proof_bytes and is_integer(handles) and
         handles >= 0 and handles <= limits.max_proof_bytes * 3,
       do: {:ok, metadata, handles},
       else: {:error, :http_output_metadata_too_large}
  end

  # The producer transfers to the recorded persistent owner before returning;
  # the owner may also accept while the producer remains alive.
  @spec handoff(HTTPWriteTicket.t()) :: :ok | error()
  def handoff(ticket), do: change_ticket(ticket, :handoff)

  @spec publish(HTTPWriteTicket.t()) :: :ok | error()
  def publish(ticket), do: change_ticket(ticket, :publish)

  @spec commit_member(HTTPWriteTicket.t(), OutputTicket.t()) :: :ok | error()
  def commit_member(ticket, primary) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(ticket),
         {:ok, gate} <- read(domain),
         %{binding: ^binding} = entry <- gate.claims[token] do
      update(domain, entry.deadline, fn current ->
        with %{binding: ^binding, stage: :held} = entry <- current.claims[token],
             true <- self() == entry.release_owner,
             true <- OutputTicket.same?(entry.metadata.primary, primary),
             true <- source_current?(domain, current.bindings[binding]) do
          put_entry(current, %{entry | committed?: true})
        else
          _invalid -> {:error, :invalid_http_output_phase}
        end
      end)
    else
      _invalid -> {:error, :invalid_http_write_ticket}
    end
  end

  @spec finish_group(HTTPWriterBinding.t(), OutputTicket.t()) ::
          {:ok, HTTPWriteTicket.t()} | error()
  def finish_group(binding, primary) do
    with {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         {:ok, info} <- open_binding(gate, binding_token),
         true <- aggregate_authorized?(domain, info, primary),
         entries =
           gate.claims
           |> Map.values()
           |> Enum.filter(&(&1.binding == binding_token and group_member?(&1)))
           |> Enum.sort_by(& &1.sequence),
         true <- entries != [],
         true <-
           Enum.all?(entries, fn entry ->
             entry.stage == :held and entry.owner == self() and entry.committed? and
               entry.deadline > Deadline.now() and :atomics.get(entry.receipt, 2) == 0
           end),
         {:ok, aggregate} <- aggregate_entry(entries, primary, domain),
         :ok <- replace_group(domain, entries, aggregate) do
      {:ok, ticket(domain, aggregate, info.writer)}
    else
      false -> {:error, :http_group_incomplete}
      error -> error
    end
  end

  defp aggregate_authorized?(%__MODULE__{runtime: nil}, _info, _primary), do: true

  defp aggregate_authorized?(
         domain,
         %{authority: %{work: %{kind: :batch} = work}} = info,
         primary
       ),
       do:
         work.final == {:done, OutputTicket.identity(primary)} and
           captured_current?(domain, info)

  defp aggregate_authorized?(_domain, _info, _primary), do: false

  defp aggregate_entry(entries, primary, domain) do
    first = hd(entries)
    json = "[" <> Enum.map_join(entries, ",", & &1.payload) <> "]"
    wire = if(first.metadata.format == :sse, do: "data: " <> json <> "\r\n\r\n", else: json)
    charge = Enum.reduce(entries, 0, &(&1.bytes + &2))

    aggregate = %{
      first
      | metadata: %{primary: primary, group: false, final_group: true},
        payload: wire,
        wire_bytes: byte_size(wire),
        deadline: Enum.min(Enum.map(entries, & &1.deadline)),
        bytes: charge
    }

    minimum =
      byte_size(wire) + :erlang.external_size(wire) + :erlang.external_size(aggregate) + 256

    if byte_size(wire) <= domain.limits.max_io_frame_bytes and minimum <= charge,
      do: {:ok, aggregate},
      else: {:error, :http_frame_too_large}
  end

  defp replace_group(domain, entries, aggregate) do
    update(domain, aggregate.deadline, fn gate ->
      if Enum.all?(entries, &(gate.claims[&1.token] == &1)) and
           source_current?(domain, gate.bindings[aggregate.binding]) do
        claims = Enum.reduce(entries, gate.claims, &Map.delete(&2, &1.token))
        {:ok, %{gate | claims: Map.put(claims, aggregate.token, aggregate)}, :ok}
      else
        {:error, :http_group_incomplete}
      end
    end)
  end

  def peek(binding) do
    with {:ok, {domain, id}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
         :ok <- peekable_binding(gate, id),
         {:ok, info} <- io_binding(gate, id),
         true <- info.writer == self(),
         :ok <- generation_valid(domain, info.proof.generation) do
      entries = Enum.filter(Map.values(gate.claims), &(&1.binding == id))

      if Enum.any?(entries, &(&1.stage == :in_flight)) do
        {:error, :http_write_in_flight}
      else
        entry =
          entries
          |> Enum.filter(&(&1.stage == :queued))
          |> Enum.min_by(& &1.sequence, fn -> nil end)

        case entry do
          nil ->
            :empty

          entry ->
            if entry.deadline > Deadline.now() and Process.alive?(entry.owner) and
                 entry_current?(domain, info, entry),
               do: {:ok, ticket(domain, entry, info.writer), entry.payload},
               else: {:error, :http_invocation_closed}
        end
      end
    else
      {:error, :http_writer_closed} = error -> error
      _closed -> {:error, :http_invocation_closed}
    end
  end

  defp peekable_binding(gate, id) do
    case gate.bindings[id] do
      nil -> {:error, :http_writer_closed}
      %{mode: :retired} -> {:error, :http_writer_closed}
      _live -> :ok
    end
  end

  # Only the recorded socket can retrieve its queued response companion.
  # The opaque primary carries no payload; durable publication rechecks the
  # same installed source, committed phase and exact session lease.
  def response_primary(effect) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(effect),
         true <- HTTPWriteTicket.writer?(effect, self()),
         {:ok, gate} <- read(domain),
         %{binding: ^binding, stage: :queued, metadata: %{primary: primary}} = entry <-
           gate.claims[token],
         info when is_map(info) <- gate.bindings[binding],
         true <- entry.deadline > Deadline.now() and entry_current?(domain, info, entry),
         do: {:ok, primary},
         else: (_invalid -> {:error, :invalid_http_response_ticket})
  end

  def kind(effect) do
    with {:ok, {domain, token, binding}} <- HTTPWriteTicket.address(effect),
         true <- HTTPWriteTicket.writer?(effect, self()),
         {:ok, gate} <- read(domain),
         %{binding: ^binding, metadata: metadata} <- gate.claims[token] do
      cond do
        Map.get(metadata || %{}, :notification, false) -> :notification
        Map.get(metadata || %{}, :accepted, false) -> :accepted
        true -> :response
      end
    else
      _missing -> :closed
    end
  end

  # Read-only receipt observation remains usable after the logical output scope
  # is gone. A missing claim is settled only after the guardian's atomic removal;
  # in-flight claims cannot be removed while their writer remains alive.
  @spec in_flight_observation(HTTPWriterBinding.t()) ::
          {:ok, HTTPWriteTicket.observation()} | error()
  def in_flight_observation(binding) do
    with {:ok, {domain, binding_token}} <- HTTPWriterBinding.address(binding),
         true <- registered_actor?(domain, :http_gateway, self()),
         {:ok, gate} <- read(domain),
         %{writer: writer} <- gate.bindings[binding_token],
         {_token, entry} <-
           Enum.find(gate.claims, fn {_token, entry} ->
             entry.binding == binding_token and entry.stage == :in_flight
           end) do
      {:ok, HTTPWriteTicket.observation(ticket(domain, entry, writer))}
    else
      _not_writing -> {:error, :http_output_not_writing}
    end
  end

  def observation_status(domain, token, receipt) do
    case :atomics.get(receipt, 1) do
      1 ->
        :returned

      2 ->
        :failed

      3 ->
        :uncertain

      0 ->
        case read(domain) do
          {:ok, %{claims: claims}} ->
            case claims[token] do
              %{receipt: ^receipt, stage: :in_flight} -> :in_flight
              %{receipt: ^receipt} -> :pending
              _settled -> :retired
            end

          _unavailable ->
            if :atomics.get(domain.lifetime, 1) == 1, do: :retired, else: :unconfirmed
        end
    end
  rescue
    ArgumentError -> :unconfirmed
  end

  # Waiting may observe a fixed failure-only tail, but this accessor grants no
  # work, store, publication or socket-write authority.
  def wait_deadline(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         %{writer: writer} = info <- gate.bindings[token],
         true <- writer == self() do
      {:ok, info.authority.failure.deadline}
    else
      _closed -> {:error, :http_invocation_closed}
    end
  end

  @spec checkout(HTTPWriterBinding.t()) :: :empty | {:ok, HTTPWriteTicket.t(), binary()} | error()
  def checkout(binding) do
    with {:ok, {domain, token}} <- HTTPWriterBinding.address(binding),
         {:ok, gate} <- read(domain),
         true <- Process.alive?(domain.root) || {:error, :http_writer_closed},
         {:ok, info} <- io_binding(gate, token),
         true <- info.writer == self() || {:error, :invalid_http_writer} do
      limit =
        if info.mode == :failure_only,
          do: info.authority.failure.deadline,
          else: binding_deadline(info)

      update(domain, limit, &take(&1, token, domain))
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
    # A sequential call on the same socket owner need not wait for the guardian
    # timer after an actual return. Keep any outstanding wake nonce across the
    # binding handoff, and never reap a still-running physical write here.
    gate = reap_returned_claims(gate)

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

  defp reap_returned_claims(gate) do
    gate.claims
    |> Enum.reduce(gate, fn {token, entry}, gate ->
      if entry.stage == :in_flight and :atomics.get(entry.receipt, 1) != 0,
        do: drop(gate, token),
        else: gate
    end)
    |> remove_empty_retired()
  end

  defp binding_parties_alive?(binding),
    do: Process.alive?(binding.writer) and Process.alive?(binding.owner)

  defp writer_slot(pid) do
    slot = %{pid: pid, binding: nil, pending: nil, bytes: 0}
    %{slot | bytes: :erlang.external_size(slot) + 256}
  end

  defp candidate(token, binding, owner, release_owner, deadline, wire, metadata, handles) do
    entry = %{
      token: token,
      binding: binding,
      producer: self(),
      owner: owner,
      release_owner: release_owner,
      deadline: deadline,
      stage: :candidate,
      sequence: System.unique_integer([:positive, :monotonic]),
      payload: nil,
      metadata: metadata,
      handle_bytes: handles,
      wire_bytes: byte_size(wire),
      committed?: false,
      receipt: :atomics.new(2, []),
      bytes: 0
    }

    %{
      entry
      | bytes:
          byte_size(wire) + :erlang.external_size(wire) + :erlang.external_size(entry) + handles +
            256 + if(group_member?(entry), do: 20, else: 0)
    }
  end

  defp claim(gate, entry, domain) do
    gate = reap_returned_claims(gate)

    with {:ok, info} <- claim_binding(gate, entry, domain),
         :ok <- generation_valid(domain, info.proof.generation) do
      gate =
        cond do
          Map.has_key?(entry.metadata || %{}, :failure_token) -> failure_only(gate, info, domain)
          Map.has_key?(entry.metadata || %{}, :listener_completion) -> completion_only(gate, info)
          true -> gate
        end

      cond do
        not Process.alive?(domain.root) ->
          {:error, :http_writer_closed}

        map_size(gate.claims) >= domain.limits.max_io_frames ->
          {:error, :http_output_busy}

        gate.bytes + entry.bytes > domain.limits.max_io_bytes ->
          {:error, :http_output_busy}

        not prospective_group_valid?(gate, entry, domain) ->
          {:error, :http_frame_too_large}

        true ->
          {:ok,
           %{
             gate
             | claims: Map.put(gate.claims, entry.token, entry),
               bindings: Map.put(gate.bindings, info.token, info),
               bytes: gate.bytes + entry.bytes
           }, :ok}
      end
    end
  end

  defp claim_binding(gate, %{metadata: %{listener_completion: completion}} = entry, domain) do
    with {:ok, listener, receipt} <- HTTPListenerCompletion.address(completion),
         {:ok, _binding, nonce} <- HTTPListenerBinding.address(listener),
         %{
           authority: %{
             listener:
               %{registration: ^nonce, terminal: %{token: ^receipt, state: 2} = terminal} = proof
           }
         } = info <- gate.bindings[entry.binding],
         true <- info.writer == self() and listener_domain_current?(domain, info),
         true <- terminal.deadline > Deadline.now() and entry.deadline == terminal.deadline do
      proof = %{proof | terminal: %{terminal | state: 3}}
      {:ok, %{info | mode: :listener_completion, authority: %{info.authority | listener: proof}}}
    else
      _invalid -> {:error, :http_listener_completion_closed}
    end
  end

  defp claim_binding(gate, %{metadata: %{failure_token: token}} = entry, domain) do
    with %{authority: %{failure: %{state: :available} = failure}} = info <-
           gate.bindings[entry.binding],
         true <- registered_actor?(domain, :output_controller, self()),
         {:ok, deadline} <- failure_authority(domain, info, token),
         true <- entry.deadline <= deadline do
      failure = %{
        failure
        | state: :claimed,
          token: token,
          effect: entry.token,
          controller: self()
      }

      {:ok, %{info | mode: :failure_only, authority: %{info.authority | failure: failure}}}
    else
      _invalid -> {:error, :http_failure_expired}
    end
  end

  defp claim_binding(gate, entry, domain) do
    with {:ok, info} <- open_binding(gate, entry.binding),
         true <- source_current?(domain, info) || {:error, :http_invocation_closed},
         do: {:ok, info}
  end

  defp entry_current?(domain, info, %{token: effect, metadata: %{listener_completion: completion}}) do
    with {:ok, _listener, receipt} <- HTTPListenerCompletion.address(completion),
         %{token: ^receipt, state: 3, effect: ^effect} <- info.authority.listener.terminal,
         {:ok, _proof} <- validate_listener_completion(completion),
         do: listener_domain_current?(domain, info),
         else: (_retired -> false)
  end

  defp entry_current?(domain, info, %{
         metadata: %{subscription_origin: origin, listener: listener}
       }) do
    with {:ok, binding, nonce} <- HTTPListenerBinding.address(listener),
         {:ok, {^domain, token}} <- HTTPWriterBinding.address(binding),
         true <- info.token == token and info.authority.listener.registration == nonce,
         true <- Arbor.MCP.Server.Subscriptions.Origin.valid?(origin),
         do: listener_current?(domain, info),
         else: (_retired -> false)
  end

  defp entry_current?(domain, %{authority: %{work: %{gateway: gateway}}} = info, %{
         owner: gateway,
         wire_bytes: 0,
         metadata: %{accepted: true}
       }) do
    registered_actor?(domain, :http_gateway, gateway) and
      info.proof.deadline > Deadline.now() and binding_parties_alive?(info) and
      lease_current?(domain, info.proof.lease) and
      generation_valid(domain, info.proof.generation) == :ok
  end

  defp entry_current?(domain, %{authority: %{failure: failure}} = info, %{
         token: effect,
         metadata: %{failure_token: token}
       }) do
    failure.state == :claimed and failure.token == token and failure.effect == effect and
      failure.deadline > Deadline.now() and binding_parties_alive?(info) and
      lease_current?(domain, info.proof.lease) and
      registered_actor?(domain, :output_controller, failure.controller) and
      generation_valid(domain, info.proof.generation) == :ok
  end

  defp entry_current?(domain, info, _entry), do: source_current?(domain, info)

  defp io_binding(gate, token) do
    case gate.bindings[token] do
      %{mode: :listener_completion, authority: %{listener: %{terminal: %{deadline: tail}}}} = info ->
        if tail > Deadline.now(),
          do: {:ok, info},
          else: {:error, :http_listener_completion_closed}

      %{mode: :failure_only, authority: %{failure: %{deadline: tail}}} = info ->
        if tail > Deadline.now(), do: {:ok, info}, else: {:error, :http_failure_expired}

      _ordinary ->
        open_binding(gate, token)
    end
  end

  defp group_member?(%{metadata: %{group: true}}), do: true
  defp group_member?(_entry), do: false

  defp prospective_group_valid?(gate, entry, domain) do
    if group_member?(entry) do
      others =
        gate.claims
        |> Map.values()
        |> Enum.filter(&(&1.binding == entry.binding and group_member?(&1)))

      count = length(others) + 1
      framing = if(entry.metadata.format == :sse, do: 10, else: 0)
      wire_bytes = Enum.reduce(others, entry.wire_bytes, &(&1.wire_bytes + &2))
      wire_bytes + count + 1 + framing <= domain.limits.max_io_frame_bytes
    else
      true
    end
  end

  defp store(gate, token, binding, wire, domain) do
    entry = gate.claims[token]

    with true <- Process.alive?(domain.root),
         {:ok, info} <- io_binding(gate, binding),
         true <- entry_current?(domain, info, entry),
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

      self() not in [entry.owner, entry.producer, entry.release_owner] ->
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
               {:ok, info} <- io_binding(current, binding),
               %{binding: ^binding} = entry <- current.claims[token],
               :ok <- generation_valid(domain, info.proof.generation),
               true <- entry_current?(domain, info, entry) || {:error, :http_invocation_closed},
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
    with {:ok, _} <- io_binding(gate, entry.binding),
         true <- :atomics.get(entry.receipt, 2) == 0 || {:error, :http_output_expired},
         true <-
           active_producer?(entry) ||
             {:error, :http_output_expired},
         true <-
           authorized_output_caller?(entry, operation) || {:error, :invalid_http_output_owner},
         true <- publish_allowed?(entry, operation) || {:error, :http_group_incomplete},
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

  defp publish_allowed?(entry, :publish), do: not group_member?(entry)
  defp publish_allowed?(_entry, _operation), do: true

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
    with {:ok, info} <- io_binding(gate, token),
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
        if entry.deadline > Deadline.now() and Process.alive?(entry.owner) and
             entry_current?(domain, info, entry) do
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
    reason = binding_retirement_reason(info, domain)

    cond do
      reason in [:source_retired, :invocation_expired] and listener_tail_live?(domain, info) ->
        listener_tail(gate, info)

      reason in [:source_retired, :invocation_expired] and failure_tail_live?(domain, info) ->
        failure_only(gate, info, domain)

      reason ->
        elem(retire_binding(gate, token, reason), 1)

      true ->
        gate
    end
  end

  defp binding_retirement_reason(info, domain) do
    cond do
      generation_valid(domain, info.proof.generation) != :ok -> :generation_retired
      not source_current?(domain, info) -> :source_retired
      not Process.alive?(info.writer) -> :writer_down
      not Process.alive?(info.owner) -> :owner_down
      binding_deadline(info) <= Deadline.now() -> :invocation_expired
      true -> nil
    end
  end

  defp listener_tail_live?(domain, %{authority: %{phase: :listener, listener: listener}} = info),
    do: listener.terminal.deadline > Deadline.now() and listener_domain_current?(domain, info)

  defp listener_tail_live?(_domain, _info), do: false

  defp listener_tail(gate, info) do
    gate =
      Enum.reduce(gate.claims, gate, fn {token, entry}, acc ->
        if entry.binding == info.token and entry.stage != :in_flight and
             not Map.has_key?(entry.metadata || %{}, :listener_completion),
           do: drop(acc, token),
           else: acc
      end)

    %{gate | bindings: Map.put(gate.bindings, info.token, %{info | mode: :listener_tail})}
  end

  defp failure_tail_live?(_domain, %{authority: %{phase: phase}})
       when phase in [:listener, :legacy_session_stream],
       do: false

  defp failure_tail_live?(domain, %{authority: %{failure: failure}} = info),
    do:
      failure.deadline > Deadline.now() and binding_parties_alive?(info) and
        lease_current?(domain, info.proof.lease)

  defp failure_tail_live?(_domain, _info), do: false

  defp completion_only(gate, info) do
    gate =
      Enum.reduce(gate.claims, gate, fn {token, entry}, acc ->
        if entry.binding == info.token and entry.stage != :in_flight,
          do: drop(acc, token),
          else: acc
      end)

    %{gate | bindings: Map.put(gate.bindings, info.token, info)}
  end

  defp failure_only(gate, info, domain) do
    gate =
      Enum.reduce(gate.claims, gate, fn {token, entry}, gate ->
        if entry.binding == info.token and entry.stage != :in_flight and
             not Map.has_key?(entry.metadata || %{}, :failure_token) and
             not (Map.get(entry.metadata || %{}, :accepted, false) and
                    entry_current?(domain, info, entry)) do
          drop(gate, token)
        else
          gate
        end
      end)

    %{gate | bindings: Map.put(gate.bindings, info.token, %{info | mode: :failure_only})}
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

          %{mode: mode, notice: false} = info
          when mode in [:open, :failure_only, :listener_completion] ->
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
        generation_valid(domain, info.proof.generation) != :ok or
        info.mode not in [:open, :failure_only, :listener_completion] or
        not entry_current?(domain, info, entry) or
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
    maximum = binding_deadline(info)
    deadline = Keyword.get(opts, :deadline, maximum)
    with :ok <- finite_deadline(deadline), do: {:ok, min(deadline, maximum)}
  end

  defp binding_deadline(%{
         mode: mode,
         authority: %{listener: %{terminal: terminal}}
       })
       when mode in [:listener_tail, :listener_completion],
       do: terminal.deadline

  defp binding_deadline(%{authority: %{phase: :listener, listener: listener}}),
    do: listener.deadline

  defp binding_deadline(%{authority: %{phase: :legacy_session_stream, legacy_stream: stream}}),
    do: stream.deadline

  defp binding_deadline(info), do: info.proof.deadline

  defp open_binding(gate, token) do
    case gate.bindings[token] do
      %{mode: :open} = info ->
        if gate.sealed or binding_deadline(info) <= Deadline.now() or
             not Process.alive?(info.owner) or
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
