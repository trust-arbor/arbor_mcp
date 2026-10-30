defmodule Arbor.MCP.Reliability.CircuitBreaker do
  @moduledoc """
  Circuit breaker GenServer wrapper.

  Provides a GenServer-based interface to the circuit breaker pattern for
  protecting MCP services from cascading failures.

  The process shell is the clock owner. It injects
  `System.monotonic_time(:millisecond)` as `now_ms` into
  `Arbor.MCP.Reliability.CircuitBreaker.Core` so elapsed open/half-open
  durations cannot go backwards if the wall clock is adjusted. The caller
  enforces an original monotonic execution cutoff and rejects results
  observed after it.
  """

  use GenServer

  alias Arbor.MCP.Reliability.CircuitBreaker.Core

  @type options :: [
          failure_threshold: non_neg_integer(),
          success_threshold: non_neg_integer(),
          timeout: non_neg_integer(),
          reset_timeout: non_neg_integer(),
          error_filter: (any() -> boolean())
        ]

  @doc """
  Starts a circuit breaker process.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, cb_opts} = split_options(opts)
    GenServer.start_link(__MODULE__, cb_opts, gen_opts)
  end

  @doc """
  Executes a function through the circuit breaker.
  """
  @spec call(GenServer.server(), (-> any())) :: any()
  def call(server, fun) do
    call(server, fun, 5000)
  end

  @doc """
  Executes a function through the circuit breaker with timeout.

  The function runs in a process spawned by the *caller*, never inside the
  circuit breaker itself: a raising/exiting function can neither crash the
  breaker nor block other callers. The breaker only admits the call and
  records its outcome. The effective execution timeout is the breaker's
  configured `:timeout` bounded by `timeout` (this argument).
  """
  @spec call(GenServer.server(), (-> any()), timeout()) :: any()
  def call(server, fun, timeout) do
    admit(server, fun, &effective_timeout(&1, timeout))
  end

  @doc """
  Like `call/3`, for an operation that carries its own deadline, such as a
  receive with a timeout: `timeout` alone bounds the execution, and the
  breaker's configured `:timeout`, meant for operations without one, does not
  cut it short.
  """
  @spec call_with_deadline(GenServer.server(), (-> any()), timeout()) :: any()
  def call_with_deadline(server, fun, timeout) do
    admit(server, fun, fn _config_timeout -> timeout end)
  end

  @doc false
  # Admission for an operation that runs elsewhere and reports its own
  # outcome with report/2, such as an HTTP POST from a task of its own. No
  # execution timeout applies: the operation has its own deadline.
  @spec acquire(GenServer.server()) ::
          :ok | {:error, :circuit_open | :circuit_breaker_unavailable}
  def acquire(server) do
    case GenServer.call(server, :acquire, 5000) do
      {:ok, _config_timeout} -> :ok
      {:error, :circuit_open} = error -> error
    end
  catch
    :exit, _reason -> {:error, :circuit_breaker_unavailable}
  end

  @doc false
  # Records the result of an operation acquire/1 admitted, as call/3 records
  # the result of its function: `{:error, reason}` goes through the error
  # filter, anything else is a success.
  @spec report(GenServer.server(), term()) :: :ok
  def report(server, result), do: GenServer.cast(server, {:report, {:ok, result}})

  @doc false
  # Admission for an operation `holder` (the calling process by default)
  # runs and settles later with settle/3, such as an HTTP POST from its own
  # task, which may be killed before it can report. The breaker monitors the
  # holder, and an admission it never settles is settled when it goes down:
  # as a failure, unless it exited normally. Taking it for another process
  # lets the process that starts the operation admit it before anything else
  # can settle it.
  @spec hold(GenServer.server(), pid()) ::
          :ok | {:error, :circuit_open | :circuit_breaker_unavailable}
  def hold(server, holder \\ self()) when is_pid(holder) do
    GenServer.call(server, {:hold, holder}, 5000)
  catch
    :exit, _reason -> {:error, :circuit_breaker_unavailable}
  end

  @doc false
  # Settles the admission `holder` took with hold/1, exactly once:
  # `{:result, result}` records the result as call/3 records its function's,
  # `:failure` counts a failure, and `:release` frees it without counting.
  # Later settles, and the holder's :DOWN, are ignored. Synchronous, so a
  # settle made before killing the holder is never overtaken by its :DOWN.
  @spec settle(GenServer.server(), pid(), {:result, term()} | :failure | :release) :: :ok
  def settle(server, holder, outcome) when is_pid(holder) do
    GenServer.call(server, {:settle, holder, outcome}, 5000)
  catch
    :exit, _reason -> :ok
  end

  defp admit(server, fun, execution_timeout) do
    case GenServer.call(server, :acquire, 5000) do
      {:error, :circuit_open} = error ->
        error

      {:ok, config_timeout} ->
        outcome = run_protected(fun, execution_timeout.(config_timeout))
        GenServer.cast(server, {:report, outcome})
        outcome_to_result(outcome)
    end
  end

  defp effective_timeout(:infinity, timeout), do: timeout
  defp effective_timeout(config_timeout, :infinity), do: config_timeout
  defp effective_timeout(config_timeout, timeout), do: min(config_timeout, timeout)

  # Runs `fun` in an unlinked, monitored process so that raises, throws and
  # exits are contained and a timeout can be enforced without trapping.
  defp run_protected(fun, timeout) do
    parent = self()
    deadline = if timeout == :infinity, do: :infinity, else: now_ms() + timeout

    {pid, ref} =
      spawn_monitor(fn ->
        outcome =
          try do
            {:ok, fun.()}
          rescue
            error -> {:raised, error}
          catch
            :throw, value -> {:threw, value}
            :exit, reason -> {:exited, reason}
          end

        send(parent, {:circuit_breaker_result, self(), outcome})
      end)

    receive do
      {:circuit_breaker_result, ^pid, outcome} ->
        if execution_open?(deadline) do
          Process.demonitor(ref, [:flush])
          outcome
        else
          terminate_protected(pid, ref)
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        if execution_open?(deadline), do: {:exited, reason}, else: :timeout
    after
      execution_remaining(deadline) -> terminate_protected(pid, ref)
    end
  end

  defp execution_open?(:infinity), do: true
  defp execution_open?(deadline), do: now_ms() < deadline
  defp execution_remaining(:infinity), do: :infinity
  defp execution_remaining(deadline), do: max(deadline - now_ms(), 0)

  defp terminate_protected(pid, ref) do
    Process.exit(pid, :kill)
    await_protected_down(pid, ref)
  end

  defp await_protected_down(pid, ref) do
    receive do
      {:circuit_breaker_result, ^pid, _outcome} -> await_protected_down(pid, ref)
      {:DOWN, ^ref, :process, ^pid, _reason} -> :timeout
    end
  end

  defp outcome_to_result({:ok, value}), do: value
  defp outcome_to_result({:raised, error}), do: {:error, error}
  defp outcome_to_result({:threw, value}), do: {:error, {:throw, value}}
  defp outcome_to_result({:exited, reason}), do: {:error, {:exit, reason}}
  defp outcome_to_result(:timeout), do: {:error, :timeout}

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(GenServer.server()) :: Core.state()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Gets circuit breaker statistics.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(server) do
    GenServer.call(server, :get_stats)
  end

  @doc """
  Manually opens the circuit breaker.
  """
  @spec open(GenServer.server()) :: :ok
  def open(server) do
    GenServer.cast(server, :open)
  end

  @doc """
  Manually closes the circuit breaker.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.cast(server, :close)
  end

  @doc """
  Resets the circuit breaker to initial state.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.cast(server, :reset)
  end

  @doc """
  Manually trips (opens) the circuit breaker.
  Alias for open/1 to match test expectations.
  """
  @spec trip(GenServer.server()) :: :ok
  def trip(server) do
    open(server)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    {error_filter, cb_opts} = Keyword.pop(opts, :error_filter, fn _ -> true end)
    circuit_breaker = Core.new(Map.new(cb_opts), now_ms())

    state = %{
      circuit_breaker: circuit_breaker,
      error_filter: error_filter,
      # Admissions taken with hold/1 and not yet settled: holder => monitor.
      holders: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:acquire, _from, state) do
    {allowed, updated_cb} = Core.allow_request_with_state?(state.circuit_breaker, now_ms())
    updated_state = %{state | circuit_breaker: updated_cb}

    if allowed do
      timeout = Map.get(updated_cb.config, :timeout, :infinity)
      {:reply, {:ok, timeout}, updated_state}
    else
      {:reply, {:error, :circuit_open}, updated_state}
    end
  end

  def handle_call({:hold, holder}, _from, state) do
    {allowed, updated_cb} = Core.allow_request_with_state?(state.circuit_breaker, now_ms())
    state = %{state | circuit_breaker: updated_cb}

    cond do
      not allowed ->
        {:reply, {:error, :circuit_open}, state}

      Map.has_key?(state.holders, holder) ->
        {:reply, :ok, state}

      true ->
        holders = Map.put(state.holders, holder, Process.monitor(holder))
        {:reply, :ok, %{state | holders: holders}}
    end
  end

  def handle_call({:settle, holder, outcome}, _from, state) do
    case Map.pop(state.holders, holder) do
      {nil, _holders} ->
        {:reply, :ok, state}

      {monitor, holders} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | holders: holders}
        {:reply, :ok, %{state | circuit_breaker: settled(outcome, state)}}
    end
  end

  def handle_call(:get_state, _from, state) do
    # Check for state transitions and update the GenServer state
    {_allowed, updated_cb} = Core.allow_request_with_state?(state.circuit_breaker, now_ms())
    updated_state = %{state | circuit_breaker: updated_cb}

    # Get fresh stats from the updated circuit breaker
    stats = Core.get_stats(updated_cb)
    {:reply, stats, updated_state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = Core.get_stats(state.circuit_breaker)
    {:reply, stats, state}
  end

  def handle_call(:open, _from, state) do
    updated_cb = Core.force_state(state.circuit_breaker, :open, now_ms())
    {:reply, :ok, %{state | circuit_breaker: updated_cb}}
  end

  def handle_call(:close, _from, state) do
    updated_cb = Core.force_state(state.circuit_breaker, :closed, now_ms())
    {:reply, :ok, %{state | circuit_breaker: updated_cb}}
  end

  def handle_call(:reset, _from, state) do
    updated_cb = Core.reset(state.circuit_breaker)
    {:reply, :ok, %{state | circuit_breaker: updated_cb}}
  end

  @impl GenServer
  def handle_cast({:report, outcome}, state) do
    updated_cb = record_outcome(outcome, state)
    {:noreply, %{state | circuit_breaker: updated_cb}}
  end

  def handle_cast(:open, state) do
    updated_cb = Core.force_state(state.circuit_breaker, :open, now_ms())
    {:noreply, %{state | circuit_breaker: updated_cb}}
  end

  def handle_cast(:close, state) do
    updated_cb = Core.force_state(state.circuit_breaker, :closed, now_ms())
    {:noreply, %{state | circuit_breaker: updated_cb}}
  end

  def handle_cast(:reset, state) do
    updated_cb = Core.reset(state.circuit_breaker)
    {:noreply, %{state | circuit_breaker: updated_cb}}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, holder, reason}, state) do
    case Map.get(state.holders, holder) do
      ^monitor ->
        state = %{state | holders: Map.delete(state.holders, holder)}
        outcome = if reason == :normal, do: :release, else: :failure
        {:noreply, %{state | circuit_breaker: settled(outcome, state)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Private helpers

  # Success/failure accounting, preserving the pre-existing semantics:
  # ok results record success; {:error, _} returns and raised exceptions go
  # through the error filter; throws, exits and timeouts always count.
  defp record_outcome({:ok, {:error, reason}}, state), do: record_filtered(reason, state)

  defp record_outcome({:ok, {:error, reason, _updated}}, state),
    do: record_filtered(reason, state)

  defp record_outcome({:ok, _value}, state),
    do: Core.record_success(state.circuit_breaker, now_ms())

  defp record_outcome({:raised, error}, state), do: record_filtered(error, state)
  defp record_outcome(_failure, state), do: Core.record_failure(state.circuit_breaker, now_ms())

  defp settled({:result, result}, state), do: record_outcome({:ok, result}, state)
  defp settled(:failure, state), do: Core.record_failure(state.circuit_breaker, now_ms())
  defp settled(:release, state), do: state.circuit_breaker

  defp record_filtered(reason, state) do
    if state.error_filter.(reason) do
      Core.record_failure(state.circuit_breaker, now_ms())
    else
      state.circuit_breaker
    end
  end

  defp split_options(opts) do
    {gen_opts, cb_opts} = Keyword.split(opts, [:name])
    {gen_opts, cb_opts}
  end

  # Documented default clock for Core. Core itself has no System/Process calls.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
