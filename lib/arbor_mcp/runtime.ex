defmodule Arbor.MCP.Server.Runtime do
  @moduledoc """
  Supervises one independently owned MCP server and its bounded callback work.

  Stateful callbacks execute serially by default. Set `execution: :stateless`
  explicitly before increasing `max_concurrency`; stateless callbacks cannot
  change their initialized handler state.

  One original `init_timeout_ms` budget covers configuration validation and all
  owned startup phases through final admission readiness. A genuine service or
  execution replacement establishes one new startup budget shared by subsequent
  children. Test/BEAM edge replacement uses its own fresh budget while retaining
  handler state and the healthy scheduler generation. Failed or late startup
  closes admission and forcefully cleans proven owned processes; borrowed
  services survive. Custom adapters must register every owned process before
  initialization can block. Capability declarations and child-spec construction
  must be free of side effects.

  Additional stores use `store_children: [[adapter: MyStore, options: []]]`.
  Each adapter declares `bounded_startup: 1` and follows
  `Arbor.MCP.Server.Runtime.ServiceAdapter`'s early registration contract.
  Raw module/argument, map and MFA child specifications are rejected in v2.
  Additional stores start inside the fail-stop store cohort before execution.

  Unnamed, local, global and standard `Registry` names are supported. A custom
  `:via` module must declare `runtime_name_capabilities/0` as
  `%{finite_lookup: 1}` and provide a pure, finite `whereis_name/1`. That lookup
  runs in OTP's initiating caller before the native timeout; arbitrary blocking
  lookup implementations are unsupported. Unqualified modules fail validation.
  Registration and subsequent initialization use the original finite cutoff.

  Runtime references survive child restarts. Requests are reserved against
  count and byte budgets before their payload enters the scheduler mailbox.
  The test/BEAM protocol edge uses an ETS payload handoff and a coalesced wake:
  accepted ingress never queues its full payload in the edge mailbox.

  Data admission permits `max_concurrency + max_queue` work items. A legacy
  batch reserves one permit per member, including notifications and invalid
  elements, and retains them until the whole envelope settles. Non-array input
  and an empty invalid array each reserve one permit. `max_pending_bytes` covers
  serialized input/context/options once plus an array's serialized permit-set
  metadata; member payloads are not charged repeatedly. Outgoing helper controls
  and incoming reverse-request responses have independent admission lanes,
  each permitting `max_control_queue` envelopes and `max_control_bytes` bytes.
  The aggregate control limit is twice each configured control limit. A
  reverse request retains its outgoing reservation until reply or expiry;
  its response can still enter when that outgoing lane is full. These limits
  cover supported ingress and helper APIs, not arbitrary Erlang sends or handler
  state.

  Test/BEAM callback replies and synchronous custom calls prepare bounded output
  before handler state commits. Combined hidden, queued and in-flight credit is
  limited by `max_output_frames` and `max_output_bytes`; each retained term and
  protocol wire also has its own cap. Legacy batches reserve prospective aggregate
  credit before each member commit and publish one charged array. Earlier member
  effects remain committed if a later output is rejected; the envelope fails
  explicitly without partial output. Local delivery ACK means sending to the
  peer mailbox returned, not that the peer processed the response. Managed
  stdio/HTTP and helper/subscription output use their bounded reservation and
  writer paths, with transport-specific completion and uncertainty receipts.
  These managed limits do not bound peer mailboxes, raw Erlang sends, OS/socket
  buffers, borrowed IO-device buffers or arbitrary external processes, and do
  not prove remote consumption.

  `request/3` uses a temporary process alias: a finite `await_timeout` covers
  admission and waiting from API entry, without leaving late replies in the
  caller mailbox. Finite waits range from zero through 4,294,967,295 ms;
  a zero wait admits no new work. It does not
  cancel accepted work; use `timeout` for the server deadline or `cancel/4` for
  explicit cancellation. Low-level `submit/3` and `await/2` deliver to the
  configured reply target. An `await/2` timeout leaves that delivery active,
  so the same token can be awaited again; its caller must monitor the runtime
  when abrupt runtime death also needs to end its wait.

  Low-level `submit/3` reply targets must be local process IDs or local process
  aliases. Erlang cannot validate whether a reference is an active alias:
  invalid references and deactivated aliases discard delivery without undoing
  accepted work or its state commit. `request/3` creates and manages its own
  alias, overriding any supplied `reply_to` option.

  `stop/2` captures one overall shutdown budget at public API entry. Concurrent
  calls coalesce without extending it. A runtime-owned observer enforces the
  original cutoff even if the graceful shutdown guard stalls. Actual root and
  registered child DOWN receipts before that cutoff are required for success;
  late or incomplete cleanup returns `{:error, :shutdown_cleanup_unconfirmed}`.
  Loss of the observer fails admission closed and returns
  `{:error, :shutdown_control_unavailable}`. Registration has a fixed 16,384
  live-PID inventory plus this one observer, and stop reasons are limited to
  4,096 retained bytes. Borrowed IO liabilities retain their existing transport
  receipts; process DOWN never invents a physical IO completion.
  It forcefully cleans explicitly registered children and callback tasks. A parent supervisor applies the same
  finite budget through this runtime's child specification. Forced cleanup may
  interrupt handler or store termination hooks; it does not promise persisted
  store data or cleanup of arbitrary processes spawned outside owned children.
  This stops the current runtime instance. A parent still applies its child
  restart policy, so a managed endpoint must be removed with
  `Supervisor.terminate_child(parent, child_id)` when it should remain stopped.
  Dynamically created descendants of custom store supervisors must register
  with the runtime shutdown guard before running work.
  """

  use Supervisor

  alias Arbor.MCP.Server.HTTP.{Config, CowboyClaims}

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    Diagnostics,
    ExecutionSupervisor,
    HTTPGateway,
    HTTPWriterProxy,
    Initialization,
    Ref,
    RetainedTerm,
    ShutdownControl,
    ShutdownGuard
  }

  @type server :: pid() | atom() | {:global, term()} | {:via, module(), term()} | Ref.t()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, config, deadline} <- Initialization.configure(opts) do
      start_configured(opts, config, deadline)
    end
  end

  @doc false
  def start_configured(opts, config, deadline) do
    with {:ok, http} <- Config.acquire(config.http, deadline) do
      start_owned_configured(opts, %{config | http: http}, deadline)
    end
  end

  defp start_owned_configured(opts, config, deadline) do
    result =
      Initialization.start_supervisor(
        __MODULE__,
        fn -> {opts, config, deadline} end,
        deadline,
        opts[:name]
      )

    if Deadline.now() < deadline do
      result
    else
      case result do
        {:ok, pid} ->
          Process.unlink(pid)

          case ref(pid) do
            {:ok, runtime} -> Initialization.abort_current(Ref.table(runtime))
            _unavailable -> Process.exit(pid, :kill)
          end

        _failed ->
          :ok
      end

      {:error, :runtime_init_timeout}
    end
  end

  def child_spec(opts) do
    Diagnostics.child_spec(%{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: Keyword.get(opts, :shutdown_timeout_ms, 5_000)
    })
  end

  @impl true
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init({opts, config, deadline}) do
    if Deadline.now() >= deadline, do: exit(:runtime_init_timeout)
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    {:ok, _context} = Initialization.begin(table, config, :runtime, deadline)
    {:ok, guard} = ShutdownGuard.start(self(), table, config)
    :ets.insert(table, {:shutdown_guard, guard})

    Process.put({__MODULE__, :reference}, Ref.new(self(), table))

    if config.transport == :http and config.http.backend == :cowboy do
      :ok = CowboyClaims.bind(config.http.lease, Ref.new(self(), table), deadline)
    end

    runtime_opts = [table: table, supervisor: self(), config: config]

    # HTTP listener construction occurs after the installed Gateway and before
    # the root readiness barrier, under the same original initialization cutoff.
    http_children =
      if config.transport == :http do
        [{Arbor.MCP.Server.HTTP.Supervisor, [runtime: Ref.new(self(), table), config: config]}]
      else
        []
      end

    children =
      [
        {HTTPWriterProxy, runtime_opts},
        {Admission, runtime_opts},
        {Arbor.MCP.Server.Runtime.StoreSupervisor, runtime_opts}
      ] ++
        [
          {ExecutionSupervisor, runtime_opts},
          {HTTPGateway, runtime_opts}
        ] ++
        http_children ++
        case Keyword.get(opts, :edge) do
          nil ->
            []

          {module, edge_opts} ->
            [
              ShutdownGuard.owned_spec(
                {module, [runtime: Ref.new(self(), table)] ++ edge_opts},
                table
              )
            ]
        end ++ [{Initialization.Barrier, [kind: :root] ++ runtime_opts}]

    Supervisor.init(Enum.map(children, &Diagnostics.child_spec/1), strategy: :rest_for_one)
  end

  @doc """
  Returns an opaque logical reference to this runtime's configured service.

  Supported kinds are `:tasks`, `:replay_cache`, `:subscriptions`, `:sessions` and
  `:resource_subscriptions`. References
  survive service-child restarts but do not follow a whole-runtime replacement.
  An unavailable explicit reference never falls back to an application service.
  """
  @spec service(
          server(),
          :tasks | :replay_cache | :subscriptions | :sessions | :resource_subscriptions
        ) ::
          {:ok, Arbor.MCP.Server.Runtime.ServiceRef.t()} | {:error, atom()}
  def service(server, kind), do: Arbor.MCP.Server.Runtime.Services.reference(server, kind)

  @doc """
  Captures a logical service reference from the active runtime callback.

  Capture the reference before spawning a worker, and pass it as `service:` to
  service operations. Callback context is not inherited by spawned processes.
  Tasks workers must also retain `Arbor.MCP.Tasks.owner/1` for authorization.
  """
  @spec service(:tasks | :replay_cache | :subscriptions | :sessions | :resource_subscriptions) ::
          {:ok, Arbor.MCP.Server.Runtime.ServiceRef.t()} | {:error, atom()}
  def service(kind) do
    case CallbackContext.current() do
      %{runtime: runtime} -> service(runtime, kind)
      nil -> {:error, :no_runtime_context}
    end
  end

  @spec ref(server()) :: {:ok, Ref.t()} | {:error, :runtime_unavailable}
  def ref(server) do
    case Ref.validate(server) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, _reason} -> resolve_reference(server)
    end
  end

  defp resolve_reference(server) do
    with {:ok, address} <- Ref.address(server),
         pid when is_pid(pid) <- GenServer.whereis(address),
         true <- node(pid) == node(),
         {:supervisor, __MODULE__, 1} <- :proc_lib.translate_initial_call(pid),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {{__MODULE__, :reference}, runtime} <-
           List.keyfind(dictionary, {__MODULE__, :reference}, 0) do
      Ref.validate(runtime)
    else
      _ -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @doc "Returns the live protocol edge owned by this runtime."
  @spec edge(server()) :: {:ok, pid()} | {:error, :runtime_unavailable}
  def edge(server) do
    with {:ok, runtime} <- ref(server),
         [{:edge, edge}] <- :ets.lookup(Ref.table(runtime), :edge),
         true <- is_pid(edge) and node(edge) == node() and Process.alive?(edge) do
      {:ok, edge}
    else
      _ -> {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  @doc false
  def reserve_ingress(server, message, opts) do
    with {:ok, runtime} <- ref(server) do
      opts = opts |> Keyword.put_new(:kind, :ingress) |> Keyword.put(:via_edge, true)
      Admission.reserve(runtime, %{"payload" => message}, opts)
    end
  end

  @doc false
  def publish_ingress(server, route, reservation, payload, edge) do
    with {:ok, runtime} <- ref(server),
         do: Admission.publish(Ref.table(runtime), route, reservation, payload, edge)
  end

  @doc false
  def dispatch_reserved(server, token, request, opts \\ []) do
    with {:ok, runtime} <- ref(server),
         {:ok, route} <- Admission.route(Ref.table(runtime)),
         {:ok, _reservation} <- Admission.promote(Ref.table(runtime), token, request, opts) do
      work_opts = [
        runtime: runtime,
        dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
        output: Keyword.get(opts, :output),
        retain_reservation: Keyword.get(opts, :retain_reservation, false)
      ]

      send(route.scheduler, {:submit, route.generation, token, request, work_opts})
      {:ok, token}
    end
  end

  @doc false
  def discard_ingress(server, token) do
    with {:ok, runtime} <- ref(server) do
      Admission.release(Ref.table(runtime), token)
    end
  end

  @spec stop(server(), term()) :: :ok | {:error, term()}
  def stop(server, reason \\ :normal) do
    started = Deadline.now()

    with {:ok, runtime} <- ref(server), {:ok, reason} <- ShutdownControl.reason(reason) do
      root = Ref.supervisor(runtime)
      table = Ref.table(runtime)
      domain = HTTPWriterProxy.domain(runtime)
      previous_trap = Process.flag(:trap_exit, true)

      result =
        try do
          case ShutdownControl.prepare(table, reason, started) do
            {:ok, control, deadline} ->
              Process.unlink(root)
              HTTPWriterProxy.seal(domain)

              case ShutdownControl.await(control, deadline, previous_trap) do
                :ok ->
                  receipt = HTTPWriterProxy.cleanup_status(domain)

                  if Deadline.now() < deadline,
                    do: receipt,
                    else: {:error, :shutdown_cleanup_unconfirmed}

                error ->
                  error
              end

            {:error, :shutdown_control_unavailable} = error ->
              Process.unlink(root)
              ShutdownControl.failure(table)
              error

            error ->
              error
          end
        after
          restore_stop_exit_policy(root, previous_trap)
        end

      case result do
        {:foreign_exit, exit_reason} -> Process.exit(self(), exit_reason)
        other -> other
      end
    end
  end

  defp restore_stop_exit_policy(root, previous_trap) do
    flush_owned_exit(root)
    if not previous_trap, do: forward_foreign_exit()
    Process.flag(:trap_exit, previous_trap)
  end

  defp forward_foreign_exit do
    receive do
      {:EXIT, _pid, :normal} ->
        forward_foreign_exit()

      {:EXIT, _pid, reason} ->
        Process.flag(:trap_exit, false)
        Process.exit(self(), reason)
    after
      0 -> :ok
    end
  end

  defp flush_owned_exit(root) do
    receive do
      {:EXIT, ^root, _reason} -> flush_owned_exit(root)
    after
      0 -> :ok
    end
  end

  @doc false
  def submit(server, request, opts \\ []) when is_map(request) do
    with {:ok, runtime} <- ref(server) do
      if Keyword.get(opts, :via_edge, false) do
        with {:ok, edge} <- edge(runtime),
             opts = Keyword.merge(opts, owner: edge, edge: edge),
             {:ok, route, reservation} <- Admission.reserve(runtime, request, opts),
             :ok <-
               Admission.publish(
                 Ref.table(runtime),
                 route,
                 reservation,
                 {:custom, request, Keyword.get(opts, :kind, :call),
                  [dispatch_opts: Keyword.get(opts, :dispatch_opts, [])]},
                 edge
               ),
             do: {:ok, reservation.token}
      else
        with {:ok, route, reservation} <- Admission.reserve(runtime, request, opts) do
          request = RetainedTerm.materialize(request)

          opts = [
            runtime: runtime,
            dispatch_opts: RetainedTerm.materialize(Keyword.get(opts, :dispatch_opts, []))
          ]

          send(route.scheduler, {:submit, route.generation, reservation.token, request, opts})
          {:ok, reservation.token}
        end
      end
    end
  end

  @doc false
  def request(server, request, opts \\ []) do
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    with :ok <- validate_await_timeout(await_timeout),
         deadline = Deadline.after_ms(await_timeout),
         :ok <- await_budget_open(deadline),
         {:ok, runtime} <- ref(server) do
      monitor = Process.monitor(Ref.supervisor(runtime))
      reply_alias = :erlang.alias()

      try do
        opts = Keyword.put(opts, :admission_deadline, deadline)
        request_with_alias(runtime, request, opts, monitor, reply_alias)
      after
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  @doc false
  def await(token, timeout \\ :infinity) do
    receive do
      {:arbor_mcp_runtime, ^token, result} -> result
    after
      timeout -> {:error, :await_timeout}
    end
  end

  @doc false
  def cancel(server, scope, request_id, opts \\ []) do
    with {:ok, runtime} <- ref(server),
         {:ok, route} <- Admission.route(Ref.table(runtime)) do
      key = Admission.key(scope, request_id, Keyword.get(opts, :direction, :inbound))
      control = {{:cancel_control, key}, self()}

      if Admission.pending_key?(Ref.table(runtime), key) and
           :ets.insert_new(Ref.table(runtime), control) do
        try do
          GenServer.call(route.scheduler, {:cancel, route.generation, key}, 5_000)
        after
          :ets.delete_object(Ref.table(runtime), control)
        end
      else
        :ok
      end
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @doc false
  def cancel_scope(server, scope) do
    with {:ok, runtime} <- ref(server) do
      Ref.table(runtime)
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:request, {^scope, direction, id}}, _token} -> [{direction, id}]
        {{:wire_request, ^scope, id, _token}, _active} -> [{:inbound, id}]
        _object -> []
      end)
      |> Enum.uniq()
      |> Enum.each(fn {direction, id} -> cancel(runtime, scope, id, direction: direction) end)

      :ok
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  @doc false
  def stats(server) do
    with {:ok, runtime} <- ref(server),
         {:ok, route} <- Admission.route(Ref.table(runtime)),
         scheduler when is_map(scheduler) <- GenServer.call(route.scheduler, :stats),
         admission when is_map(admission) <- Admission.stats(Ref.table(runtime)) do
      Map.merge(scheduler, admission)
    else
      {:error, _reason} = error -> error
      _invalid_stats -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @doc false
  def cancelled?, do: CallbackContext.cancelled?()

  defp request_with_alias(runtime, request, opts, monitor, reply_alias) do
    deadline = Keyword.fetch!(opts, :admission_deadline)

    with :ok <- await_budget_open(deadline),
         {:ok, token} <- submit(runtime, request, Keyword.put(opts, :reply_to, reply_alias)) do
      try do
        with :ok <- await_budget_open(deadline) do
          receive do
            {:arbor_mcp_runtime, ^token, result} ->
              result_before_deadline(result, deadline)

            {:DOWN, ^monitor, :process, _pid, _reason} ->
              result_before_deadline({:error, :runtime_unavailable}, deadline)
          after
            Deadline.remaining(deadline) -> {:error, :await_timeout}
          end
        end
      after
        :erlang.unalias(reply_alias)

        receive do
          {:arbor_mcp_runtime, ^token, _late_reply} -> :ok
        after
          0 -> :ok
        end
      end
    end
  end

  defp validate_await_timeout(:infinity), do: :ok

  defp validate_await_timeout(timeout)
       when is_integer(timeout) and timeout >= 0 and timeout <= 4_294_967_295,
       do: :ok

  defp validate_await_timeout(_timeout), do: {:error, :invalid_await_timeout}

  defp await_budget_open(deadline) do
    if Deadline.remaining(deadline) == 0, do: {:error, :await_timeout}, else: :ok
  end

  defp result_before_deadline(result, deadline) do
    with :ok <- await_budget_open(deadline), do: result
  end
end
