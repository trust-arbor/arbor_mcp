defmodule Arbor.MCP.Client.ConnectionScope do
  @moduledoc false
  import Kernel, except: [spawn_monitor: 1, spawn_link: 1]

  alias Arbor.MCP.Client.Internal.Connection, as: ClientConnection

  alias Arbor.MCP.Client.ConnectionScope.{Observer, Ref}
  alias Arbor.MCP.Client.{Deadline, Lifetime}

  @max_timeout 2_147_483_647
  @key {__MODULE__, :scope}

  def run(spec, opts, callback) when is_list(opts) and is_function(callback, 1) do
    with true <- Keyword.keyword?(opts),
         {:ok, establish} <- finite_option(opts, :establish_timeout, 12_000),
         deadline = Deadline.after_ms(establish),
         {:ok, cleanup} <- finite_option(opts, :cleanup_timeout, 1_000),
         {:ok, workers} <- finite_option(opts, :max_scope_workers, 256),
         {:ok, client_opts} <-
           ClientConnection.connection_options(spec, opts),
         :ok <- validate_name(client_opts),
         token = make_ref(),
         {:ok, observer} <- Observer.start(self(), client_opts, deadline, cleanup, workers, token) do
      scope = Ref.new(observer, token, deadline, cleanup)

      case call(scope, :ready, deadline) do
        {:ok, client} -> run_callback(scope, client, callback)
        error -> connection_failure(scope, error)
      end
    else
      false -> {:error, :invalid_connection_scope_options}
      error -> error
    end
  end

  def run(_spec, _opts, _callback), do: {:error, :invalid_connection_scope_options}

  defp validate_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> :ok
      name when is_atom(name) -> :ok
      _name -> {:error, :connection_scope_requires_local_name}
    end
  end

  defp finite_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= @max_timeout -> {:ok, value}
      _value -> {:error, {:invalid_connection_scope_option, key}}
    end
  end

  defp run_callback(scope, client, callback) do
    case call(scope, :activate, Ref.deadline(scope)) do
      :ok ->
        try do
          value = callback.(client)

          case finish(scope) do
            :ok -> {:ok, value}
            {:error, reason} -> {:error, {:cleanup_failed, reason, value}}
          end
        catch
          kind, reason ->
            stack = __STACKTRACE__
            cleanup = finish(scope)
            report_exception_cleanup(cleanup)
            :erlang.raise(kind, reason, stack)
        end

      error ->
        connection_failure(scope, error)
    end
  end

  defp connection_failure(scope, error) do
    case finish(scope) do
      :ok -> error
      {:error, reason} -> {:error, {:connection_cleanup_failed, error, reason}}
    end
  end

  defp report_exception_cleanup(:ok), do: :ok

  defp report_exception_cleanup({:error, _reason}) do
    :telemetry.execute([:arbor_mcp, :client, :scope_cleanup_failed], %{}, %{callback_failed: true})
  end

  defp finish(scope) do
    # Both caller and observer use this captured cleanup cutoff. Retries and
    # later cleanup stages cannot extend it.
    deadline = Deadline.after_ms(Ref.cleanup_ms(scope))

    case call(scope, {:finish, deadline}, deadline, :cleanup_timeout) do
      {:cleanup, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def current, do: Process.get(@key)

  @doc false
  def register_client(nil), do: :ok

  def register_client(scope) do
    Process.put(@key, scope)
    Process.put({__MODULE__, :establishing}, true)

    case call(scope, {:register_client, self()}, Ref.deadline(scope)) do
      {:ok, guardian} ->
        watch_owned(self(), guardian, Ref.observer(scope))
        :ok

      error ->
        error
    end
  end

  @doc false
  def establish_deadline(opts) do
    case Keyword.get(opts, :_connection_scope) do
      nil -> nil
      scope -> if(Process.get({__MODULE__, :establishing}), do: Ref.deadline(scope), else: nil)
    end
  end

  @doc false
  def opening do
    if scope = current(), do: call(scope, :opening, control_deadline(scope)), else: :ok
  end

  @doc false
  def transport(mod, state) do
    if scope = current(),
      do: call(scope, {:transport, mod, state}, control_deadline(scope)),
      else: :ok
  end

  @doc false
  def established, do: Process.delete({__MODULE__, :establishing})

  defp control_deadline(scope) do
    if Process.get({__MODULE__, :establishing}),
      do: Ref.deadline(scope),
      else: Deadline.after_ms(1_000)
  end

  @doc false
  def start_worker(fun) do
    case current() do
      nil ->
        {pid, monitor} = Lifetime.spawn_monitor(fun)
        Process.demonitor(monitor, [:flush])
        {:ok, pid}

      _scope ->
        {pid, monitor} = spawn_monitor(fun)
        Process.demonitor(monitor, [:flush])
        {:ok, pid}
    end
  end

  @doc false
  def closed(mod, state, result) do
    if scope = current(),
      do: call(scope, {:closed, mod, state, result}, Deadline.after_ms(1_000)),
      else: :ok
  end

  @doc false
  def async(fun) do
    case current() do
      nil ->
        Lifetime.async(fun)

      scope ->
        owner = self()
        nonce = make_ref()

        task =
          Lifetime.async(fn ->
            Process.put(@key, scope)
            watch_owned(self(), owner, Ref.observer(scope))

            receive do
              {^nonce, :run} -> fun.()
            after
              1_000 -> exit(:connection_scope_closed)
            end
          end)

        case call(scope, {:worker, task.pid}, control_deadline(scope)) do
          :ok -> send(task.pid, {nonce, :run})
          _error -> Process.exit(task.pid, :kill)
        end

        task
    end
  end

  @doc false
  def spawn_monitor(fun) do
    case current() do
      nil -> Lifetime.spawn_monitor(fun)
      scope -> start_owned_worker(scope, fun)
    end
  end

  @doc false
  def spawn_monitor(fun, deadline) do
    case current() do
      nil -> Lifetime.spawn_monitor(fun, deadline)
      scope -> start_owned_worker(scope, fun, false, deadline)
    end
  end

  @doc false
  def spawn_link(fun) do
    case current() do
      nil ->
        Lifetime.spawn_link(fun)

      scope ->
        {pid, monitor} = start_owned_worker(scope, fun, true)
        Process.demonitor(monitor, [:flush])
        pid
    end
  end

  @doc false
  def start_process(module, opts, mode) do
    scope = Keyword.get(opts, :_connection_scope)

    if scope do
      # Keep the native parent link during construction. The early init hook
      # registers and arms the owned child before its acknowledgement; only
      # then can the modern stream resume its ordinary unlinked lifetime.
      result =
        Lifetime.start_process(module, opts, :linked, control_deadline(scope))

      if mode == :unlinked and match?({:ok, _pid}, result) do
        {:ok, pid} = result
        Process.unlink(pid)
      end

      result
    else
      case mode do
        :unlinked -> Lifetime.start_process(module, opts, :unlinked)
        :linked -> Lifetime.start_process(module, opts, :linked)
      end
    end
  end

  @doc false
  def register_process(scope, lifetime \\ nil, deadline \\ Deadline.after_ms(1_000)) do
    with :ok <- Lifetime.register_process(lifetime, deadline), do: register_scoped_process(scope)
  end

  defp register_scoped_process(nil), do: :ok

  defp register_scoped_process(scope) do
    Process.put(@key, scope)

    case call(scope, {:native_worker, self()}, Deadline.after_ms(1_000)) do
      {:ok, client} ->
        watch_owned(self(), client, Ref.observer(scope))
        :ok

      error ->
        error
    end
  end

  @doc false
  def watch_guardian(guardian, observer), do: watch_owned(guardian, observer, observer)

  defp watch_owned(worker, owner, observer) do
    spawn(fn ->
      monitors = Enum.map([worker, owner, observer], &{Process.monitor(&1), &1})

      receive do
        {:DOWN, monitor, :process, pid, _reason} ->
          if {monitor, pid} in monitors and pid != worker, do: Process.exit(worker, :kill)
      end
    end)
  end

  defp start_owned_worker(scope, fun, linked \\ false, deadline \\ nil) do
    owner = self()
    nonce = make_ref()

    {pid, monitor} =
      Lifetime.spawn_monitor(
        fn ->
          Process.put(@key, scope)
          watch_owned(self(), owner, Ref.observer(scope))
          owner_monitor = Process.monitor(owner)

          receive do
            {^nonce, :run} ->
              Process.demonitor(owner_monitor, [:flush])
              fun.()

            {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
              :ok
          after
            Deadline.cap(1_000, deadline) -> :ok
          end
        end,
        deadline
      )

    if linked, do: Process.link(pid)

    case call(scope, {:worker, pid}, deadline || Deadline.after_ms(1_000)) do
      :ok -> send(pid, {nonce, :run})
      _error -> Process.exit(pid, :kill)
    end

    {pid, monitor}
  end

  @doc false
  def call(scope, message, deadline, timeout_error \\ :establish_timeout) do
    observer = Ref.observer(scope)
    reply = :erlang.alias()
    monitor = Process.monitor(observer)

    try do
      send(observer, {:scope_call, Ref.token(scope), self(), reply, message})

      receive do
        {^reply, result} ->
          if Deadline.expired?(deadline), do: {:error, timeout_error}, else: result

        {:DOWN, ^monitor, :process, ^observer, _reason} ->
          {:error, :connection_scope_closed}
      after
        Deadline.remaining(deadline) -> {:error, timeout_error}
      end
    after
      :erlang.unalias(reply)
      Process.demonitor(monitor, [:flush])
      flush(reply)
    end
  end

  defp flush(reply) do
    receive do
      {^reply, _result} -> flush(reply)
    after
      0 -> :ok
    end
  end
end
