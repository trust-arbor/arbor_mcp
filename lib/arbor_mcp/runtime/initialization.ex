defmodule Arbor.MCP.Server.Runtime.Initialization do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Admission, Config, Deadline, OutputController, ShutdownGuard}

  @timer_limit 4_294_967_295

  def configure(opts) do
    started_at = Deadline.now()
    timeout = Keyword.get(opts, :init_timeout_ms, 10_000)

    if is_integer(timeout) and timeout > 0 and timeout <= @timer_limit do
      deadline = started_at + timeout
      attach_deadline(validate_before(deadline, fn -> Config.new(opts) end), deadline)
    else
      {:error, {:invalid_limit, :init_timeout_ms}}
    end
  end

  @spec start_supervisor(module(), term(), integer(), GenServer.name() | nil) ::
          Supervisor.on_start()
  def start_supervisor(module, argument, deadline, name \\ nil) do
    with :ok <- validate_before(deadline, fn -> Config.validate_name(name) end) do
      {native_name, options} = supervisor_name(name)

      # Match OTP supervisor:start_link's callback argument and actual parent.
      # Elixir Supervisor.start_link only forwards :name, ignoring :timeout.
      native_supervisor(module, argument, deadline, native_name, options)
    end
  end

  defp native_supervisor(module, argument, deadline, native_name, options) do
    previous = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(
        :supervisor,
        {native_name, module, argument},
        [timeout: Deadline.remaining(deadline)] ++ options
      )
      |> supervisor_result(deadline)
    after
      Process.flag(:trap_exit, previous)
      if not previous, do: restore_link_exits()
    end
  end

  defp restore_link_exits do
    receive do
      {:EXIT, _pid, :normal} -> restore_link_exits()
      {:EXIT, _pid, reason} -> Process.exit(self(), reason)
    after
      0 -> :ok
    end
  end

  defp validate_before(deadline, operation) do
    if Deadline.now() < deadline do
      token = make_ref()
      reply_to = :erlang.alias()

      {helper, monitor} =
        spawn_monitor(fn -> send(reply_to, {token, operation.()}) end)

      try do
        receive do
          {^token, result} ->
            if Deadline.now() < deadline, do: result, else: {:error, :runtime_init_timeout}

          {:DOWN, ^monitor, :process, ^helper, _reason} ->
            {:error, :invalid_configuration}
        after
          Deadline.remaining(deadline) -> {:error, :runtime_init_timeout}
        end
      after
        :erlang.unalias(reply_to)
        Process.exit(helper, :kill)
        Process.demonitor(monitor, [:flush])
        flush_reply(token)
      end
    else
      {:error, :runtime_init_timeout}
    end
  end

  defp supervisor_name(nil), do: {:self, []}
  defp supervisor_name(name) when is_atom(name), do: {{:local, name}, [name: name]}
  defp supervisor_name({:global, _key} = name), do: {name, [name: name]}

  defp supervisor_name({:via, module, _key} = name) when is_atom(module),
    do: {name, [name: name]}

  defp supervisor_name(invalid),
    do: raise(ArgumentError, "invalid supervisor name: #{inspect(invalid)}")

  defp supervisor_result(result, deadline) do
    if Deadline.now() < deadline and result != {:error, :timeout} do
      result
    else
      case result do
        {:ok, pid} ->
          Process.unlink(pid)
          flush_owned_exit(pid)
          Process.exit(pid, :kill)

        _failed ->
          :ok
      end

      {:error, :runtime_init_timeout}
    end
  end

  defp flush_owned_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp attach_deadline({:ok, config}, deadline), do: {:ok, config, deadline}
  defp attach_deadline(error, _deadline), do: error

  defp flush_reply(token) do
    receive do
      {^token, _result} -> flush_reply(token)
    after
      0 -> :ok
    end
  end

  def begin(table, config, scope, deadline \\ nil) do
    case current(table) do
      {:ok, %{status: :starting} = context} ->
        if Deadline.now() < context.deadline,
          do: {:ok, context},
          else: {:error, :runtime_init_timeout}

      {:ok, %{status: :failed}} ->
        {:error, :runtime_init_timeout}

      {:ok, %{status: :ready}} ->
        start_epoch(table, config, scope, Deadline.now() + config.init_timeout_ms)

      {:error, :runtime_unavailable} ->
        start_epoch(table, config, scope, deadline || Deadline.now() + config.init_timeout_ms)
    end
  end

  def current(table) do
    case :ets.lookup(table, :runtime_initialization) do
      [{:runtime_initialization, context}] ->
        {:ok, Map.put(context, :status, phase_status(:atomics.get(context.phase, 1)))}

      _missing ->
        {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def ready?(table) do
    case current(table) do
      {:ok, %{status: :ready}} -> true
      _pending -> false
    end
  end

  def edge_start(table) do
    case current(table) do
      {:ok, %{status: :starting} = context} ->
        if current?(table, context), do: :ok, else: {:error, :runtime_init_timeout}

      {:ok, %{status: :ready} = context} ->
        abort(table, context)
        {:error, :edge_restart_requires_runtime_replacement}

      _unavailable ->
        {:error, :runtime_init_timeout}
    end
  end

  def recover_edge(table) do
    case current(table) do
      {:ok, %{status: :ready} = previous} ->
        with {:ok, route} <- Admission.route(table),
             [{_key, execution}] <-
               :ets.lookup(table, {:initialization_complete, previous.epoch, :execution}),
             true <- Process.alive?(execution),
             {:ok, context} <-
               start_epoch(
                 table,
                 route.config,
                 :edge,
                 Deadline.now() + route.config.init_timeout_ms
               ),
             :ok <- complete(table, :execution, execution),
             :ok <- Admission.prepare_edge(table, route, context),
             :ok <- OutputController.connect_startup(table, context) do
          :ok
        else
          _invalid ->
            abort_current(table)
            {:error, :runtime_init_timeout}
        end

      _starting_or_failed ->
        edge_start(table)
    end
  end

  @spec remaining(:ets.tid()) :: non_neg_integer()
  def remaining(table) do
    case current(table) do
      {:ok, %{deadline: deadline, status: :starting}} when is_integer(deadline) ->
        min(@timer_limit, max(0, deadline - Deadline.now()))

      _unavailable ->
        0
    end
  end

  def current?(table, context) do
    case current(table) do
      {:ok, %{epoch: epoch, status: :starting}} ->
        epoch == context.epoch and Deadline.now() < context.deadline

      _retired ->
        false
    end
  end

  def track(table, pid, role \\ :worker)

  def track(table, pid, role) when is_pid(pid) and node(pid) == node() do
    :ets.insert(table, {{:runtime_owned, pid}, role})

    case current(table) do
      {:ok, %{status: :starting} = context} ->
        if current?(table, context) do
          result =
            GenServer.call(
              context.observer,
              {:owned, pid, role},
              Deadline.remaining(context.deadline)
            )

          if current?(table, context), do: result, else: {:error, :runtime_init_timeout}
        else
          {:error, :runtime_init_timeout}
        end

      {:ok, %{status: :failed}} ->
        {:error, :runtime_init_timeout}

      _normal_lifetime ->
        :ok
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :runtime_init_timeout}
  end

  def track(_table, _pid, _role), do: {:error, :invalid_owned_process}

  def watch(table, pid, type \\ :worker) do
    case current(table) do
      {:ok, %{status: :starting} = context} ->
        ShutdownGuard.watch(table, pid, type, context.deadline)

      {:ok, %{status: :failed}} ->
        {:error, :runtime_init_timeout}

      _normal_lifetime ->
        ShutdownGuard.watch(table, pid, type)
    end
  end

  def complete(table, role, pid) do
    with {:ok, context} <- current(table),
         true <- current?(table, context),
         true <- :ets.member(table, {:runtime_owned, pid}) and Process.alive?(pid) do
      :ets.insert(table, {{:initialization_complete, context.epoch, role}, pid})
      if current?(table, context), do: :ok, else: {:error, :runtime_init_timeout}
    else
      _expired -> {:error, :runtime_init_timeout}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def publish_ready(table, kind) do
    with {:ok, context} <- current(table),
         true <- current?(table, context) do
      if kind == :execution and context.scope != :execution do
        :ok
      else
        publish_completed(table, context, kind)
      end
    else
      _expired -> {:error, :runtime_init_timeout}
    end
  end

  defp publish_completed(table, context, kind) do
    with true <- completed?(table, context, :execution),
         true <- kind == :execution or stores_ready?(table),
         :ok <- Admission.publish_ready(table, context),
         :ok <- ready_return(table, context) do
      disarm(context)
      :ok
    else
      false -> {:error, :runtime_init_timeout}
      error -> error
    end
  end

  defp stores_ready?(table) do
    with [{:services_generation, generation, pid}] <- :ets.lookup(table, :services_generation),
         [{:services_startup, ^generation, _deadline, :ready}] <-
           :ets.lookup(table, :services_startup) do
      Process.alive?(pid)
    else
      _not_ready -> false
    end
  end

  def commit_ready(table, context, route) do
    if current?(table, context) and :atomics.compare_exchange(context.phase, 1, 0, 1) == :ok do
      if Deadline.now() < context.deadline do
        :ets.insert(table, {:route, route})
        ready_return(table, context)
      else
        abort(table, context)
        {:error, :runtime_init_timeout}
      end
    else
      {:error, :runtime_init_timeout}
    end
  end

  def ready_return(table, context) do
    case current(table) do
      {:ok, %{epoch: epoch, status: :ready}} when epoch == context.epoch ->
        if Deadline.now() < context.deadline do
          :ok
        else
          abort(table, context)
          {:error, :runtime_init_timeout}
        end

      _retired ->
        {:error, :runtime_init_timeout}
    end
  end

  def abort_current(table) do
    case current(table) do
      {:ok, context} -> abort(table, context)
      _missing -> :ok
    end
  end

  def abort(table, context) do
    case current(table) do
      {:ok, %{epoch: epoch}} when epoch == context.epoch ->
        :atomics.put(context.phase, 1, 2)
        :ets.insert(table, {:route, :closed})
        :ets.delete(table, :prepared_route)
        kill_owned(table)

      _retired ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def preserve_record?({key, _value}) do
    key in [
      :shutdown_guard,
      :closing,
      :runtime_initialization,
      :runtime_requirements,
      :http_writer_domain,
      :http_writer_proxy
    ] or
      match?({:runtime_owned, _pid}, key)
  end

  def preserve_record?(_record), do: false

  defp start_epoch(table, config, scope, deadline) do
    root = :ets.info(table, :owner)
    :ets.insert(table, {{:runtime_owned, root}, :worker})
    phase = :atomics.new(1, signed: false)
    epoch = make_ref()

    context = %{
      epoch: epoch,
      deadline: deadline,
      phase: phase,
      scope: scope,
      root: root,
      shutdown_timeout: config.shutdown_timeout_ms
    }

    owned = owned(table)

    observer =
      spawn(fn ->
        observe(table, context, Process.monitor(root), owned, monitor_owned(owned, root))
      end)

    context = Map.put(context, :observer, observer)
    :ets.insert(table, [{:runtime_initialization, context}, {:route, :closed}])
    :ets.match_delete(table, {{:initialization_complete, :_, :_}, :_})
    :ets.delete(table, :prepared_route)

    if current?(table, context),
      do: {:ok, Map.put(context, :status, :starting)},
      else: timeout(table, context)
  end

  defp timeout(table, context) do
    abort(table, context)
    {:error, :runtime_init_timeout}
  end

  defp completed?(table, context, role) do
    case :ets.lookup(table, {:initialization_complete, context.epoch, role}) do
      [{_key, pid}] -> Process.alive?(pid)
      _missing -> false
    end
  end

  defp phase_status(0), do: :starting
  defp phase_status(1), do: :ready
  defp phase_status(2), do: :failed

  defp disarm(context), do: Process.exit(context.observer, :kill)

  defp monitor_owned(known, root) do
    for {pid, _role} <- known, pid != root, into: %{}, do: {Process.monitor(pid), pid}
  end

  defp observe(table, context, root_monitor, known, monitors) do
    receive do
      {:"$gen_call", from, {:owned, pid, role}} ->
        if current?(table, context) do
          monitors =
            if Map.has_key?(known, pid),
              do: monitors,
              else: Map.put(monitors, Process.monitor(pid), pid)

          known = Map.put(known, pid, role)
          GenServer.reply(from, :ok)
          observe(table, context, root_monitor, known, monitors)
        else
          GenServer.reply(from, {:error, :runtime_init_timeout})
          expire_observer(table, context, known)
        end

      {:DOWN, ^root_monitor, :process, _root, _reason} ->
        finish_root_down(known, context)

      {:DOWN, monitor, :process, _pid, _reason} ->
        case Map.pop(monitors, monitor) do
          {nil, _remaining} ->
            observe(table, context, root_monitor, known, monitors)

          {pid, remaining} ->
            observe(table, context, root_monitor, Map.delete(known, pid), remaining)
        end
    after
      Deadline.remaining(context.deadline) ->
        expire_observer(table, context, known)
    end
  rescue
    ArgumentError -> kill_known(known, context.root)
  end

  defp expire_observer(table, context, known) do
    case current(table) do
      {:ok, %{epoch: epoch, status: status}}
      when epoch == context.epoch and status in [:starting, :failed] ->
        abort(table, context)
        kill_known(known, context.root)

      {:error, :runtime_unavailable} ->
        # The observer is armed before its context is published. Native root
        # death still has a monitor; a suspended publisher also needs this
        # original-cutoff path, even while its ETS record is absent.
        if :atomics.compare_exchange(context.phase, 1, 0, 2) == :ok,
          do: kill_known(known, context.root)

      _retired_or_ready ->
        :ok
    end
  end

  defp owned(table) do
    for {{:runtime_owned, pid}, role} <- :ets.match_object(table, {{:runtime_owned, :_}, :_}),
        into: %{},
        do: {pid, role}
  end

  defp kill_owned(table) do
    root = :ets.info(table, :owner)
    kill_known(owned(table), root)
  end

  defp kill_known(known, root) do
    for {pid, _role} <- known, pid != root and pid != self(), do: Process.exit(pid, :kill)
    if root != self(), do: Process.exit(root, :kill)
  end

  defp finish_root_down(known, context) do
    for {pid, role} <- known, role != :guard and pid != context.root, do: Process.exit(pid, :kill)

    case Enum.find(known, fn {_pid, role} -> role == :guard end) do
      {guard, :guard} ->
        receive do
          {:DOWN, _monitor, :process, ^guard, _reason} -> :ok
        after
          context.shutdown_timeout + 50 -> Process.exit(guard, :kill)
        end

      nil ->
        :ok
    end
  end
end
