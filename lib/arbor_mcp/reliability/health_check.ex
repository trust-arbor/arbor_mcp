defmodule Arbor.MCP.Reliability.HealthCheck do
  @moduledoc """
  Health check system for MCP clients and servers.

  Provides proactive health monitoring, automatic failure detection,
  and recovery mechanisms for MCP services.

  ## Features

  - Periodic health checks with configurable intervals
  - Multiple check strategies (ping, capability check, custom)
  - Automatic status updates and notifications
  - Integration with circuit breakers and retry logic
  - Health metrics and history tracking

  ## Usage

      # Start health checker for a client
      {:ok, checker} = HealthCheck.start_link(
        name: :my_health_check,
        target: client_pid,
        check_interval: 30_000,
        timeout: 5_000,
        failure_threshold: 3,
        recovery_threshold: 2
      )

      # Get current health status
      HealthCheck.get_status(checker)
      #=> {:healthy, %{last_check: ~U[...], consecutive_successes: 5}}

      # Subscribe to health events
      HealthCheck.subscribe(checker)

      # Manual health check
      HealthCheck.check_now(checker)
  """

  use GenServer
  require Logger

  # 1 minute
  @default_check_interval 60_000
  # 5 seconds
  @default_timeout 5_000
  @default_failure_threshold 3
  @default_recovery_threshold 2

  defstruct [
    :name,
    :target,
    :check_fn,
    :check_interval,
    :timeout,
    :failure_threshold,
    :recovery_threshold,
    :on_status_change,
    :timer_ref,
    status: :unknown,
    consecutive_failures: 0,
    consecutive_successes: 0,
    last_check_time: nil,
    last_check_result: nil,
    history: [],
    subscribers: MapSet.new(),
    metadata: %{}
  ]

  @type status :: :healthy | :unhealthy | :degraded | :unknown

  @type check_result :: %{
          status: status(),
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer(),
          details: map()
        }

  @type t :: %__MODULE__{
          name: atom(),
          target: pid() | atom(),
          check_fn: (any() -> {:ok, map()} | {:error, any()}) | nil,
          check_interval: pos_integer(),
          timeout: pos_integer(),
          failure_threshold: pos_integer(),
          recovery_threshold: pos_integer(),
          on_status_change: (status(), status() -> any()) | nil,
          timer_ref: reference() | nil,
          status: status(),
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer(),
          last_check_time: DateTime.t() | nil,
          last_check_result: check_result() | nil,
          history: [check_result()],
          subscribers: MapSet.t(pid()),
          metadata: map()
        }

  ## Client API

  @doc """
  Starts a health check process.

  ## Options

  - `:name` - Process name (required)
  - `:target` - PID or name of process to check (required)
  - `:check_fn` - Custom check function (optional, defaults to MCP ping)
  - `:check_interval` - Ms between checks (default: 60000)
  - `:timeout` - Check timeout in ms (default: 5000)
  - `:failure_threshold` - Failures before unhealthy (default: 3)
  - `:recovery_threshold` - Successes before healthy (default: 2)
  - `:on_status_change` - Callback for status changes
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the current health status.
  """
  @spec get_status(GenServer.server()) :: {status(), map()}
  def get_status(checker) do
    GenServer.call(checker, :get_status)
  end

  @doc """
  Triggers an immediate health check.
  """
  @spec check_now(GenServer.server()) :: check_result()
  def check_now(checker) do
    GenServer.call(checker, :check_now)
  end

  @doc """
  Gets health check history.
  """
  @spec get_history(GenServer.server(), pos_integer()) :: [check_result()]
  def get_history(checker, limit \\ 10) do
    GenServer.call(checker, {:get_history, limit})
  end

  @doc """
  Subscribes to health status changes.

  Subscribers receive messages: `{:health_status_changed, old_status, new_status, metadata}`
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(checker) do
    GenServer.call(checker, {:subscribe, self()})
  end

  @doc """
  Unsubscribes from health status changes.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(checker) do
    GenServer.call(checker, {:unsubscribe, self()})
  end

  @doc """
  Pauses health checks.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(checker) do
    GenServer.call(checker, :pause)
  end

  @doc """
  Resumes health checks.
  """
  @spec resume(GenServer.server()) :: :ok
  def resume(checker) do
    GenServer.call(checker, :resume)
  end

  ## Server Callbacks

  @impl GenServer
  def init(opts) do
    target = Keyword.fetch!(opts, :target)

    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      target: target,
      check_fn: Keyword.get(opts, :check_fn) || default_check_fn(target),
      check_interval: Keyword.get(opts, :check_interval, @default_check_interval),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      recovery_threshold: Keyword.get(opts, :recovery_threshold, @default_recovery_threshold),
      on_status_change: Keyword.get(opts, :on_status_change),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Start health checks after a short delay
    timer_ref = Process.send_after(self(), :perform_check, 1000)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    status_info = %{
      status: state.status,
      last_check: state.last_check_time,
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes,
      metadata: state.metadata
    }

    {:reply, {state.status, status_info}, state}
  end

  def handle_call(:check_now, _from, state) do
    {result, new_state} = perform_health_check(state)
    {:reply, result, new_state}
  end

  def handle_call({:get_history, limit}, _from, state) do
    history = Enum.take(state.history, limit)
    {:reply, history, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call(:pause, _from, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    {:reply, :ok, %{state | timer_ref: nil}}
  end

  def handle_call(:resume, _from, state) do
    timer_ref = Process.send_after(self(), :perform_check, 1000)
    {:reply, :ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(:perform_check, state) do
    {_result, new_state} = perform_health_check(state)

    # Schedule next check
    timer_ref = Process.send_after(self(), :perform_check, state.check_interval)

    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  ## Private Functions

  defp perform_health_check(state) do
    start_time = System.monotonic_time(:millisecond)
    timestamp = DateTime.utc_now()

    {status, details} = execute_check(state.check_fn, state.target, state.timeout)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    result = %{
      status: status,
      timestamp: timestamp,
      duration_ms: duration_ms,
      details: details
    }

    new_state = update_health_state(state, result)

    {result, new_state}
  end

  defp execute_check(check_fn, target, timeout) do
    task = Task.async(fn -> check_fn.(target) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, details}} ->
        {:healthy, details}

      {:ok, {:error, reason}} ->
        {:unhealthy, %{error: reason}}

      nil ->
        {:unhealthy, %{error: :timeout}}

      {:exit, reason} ->
        {:unhealthy, %{error: {:exit, reason}}}
    end
  rescue
    e ->
      {:unhealthy, %{error: Exception.format(:error, e)}}
  end

  defp update_health_state(state, result) do
    new_state =
      case result.status do
        :healthy ->
          handle_successful_check(state)

        :unhealthy ->
          handle_failed_check(state)

          # Note: :degraded status was intentionally removed to simplify health check logic.
          # The system now uses a binary healthy/unhealthy model for clearer operational status.
          # Any partially functional states are treated as :unhealthy to ensure conservative
          # load balancing and monitoring decisions.
      end

    # Update history (keep last 100 entries)
    history = [result | state.history] |> Enum.take(100)

    %{new_state | last_check_time: result.timestamp, last_check_result: result, history: history}
  end

  defp handle_successful_check(state) do
    new_successes = state.consecutive_successes + 1

    new_status =
      cond do
        state.status == :healthy -> :healthy
        new_successes >= state.recovery_threshold -> :healthy
        true -> state.status
      end

    if new_status != state.status do
      notify_status_change(state, state.status, new_status)
    end

    %{state | status: new_status, consecutive_successes: new_successes, consecutive_failures: 0}
  end

  defp handle_failed_check(state) do
    new_failures = state.consecutive_failures + 1

    new_status =
      if new_failures >= state.failure_threshold do
        :unhealthy
      else
        state.status
      end

    if new_status != state.status do
      notify_status_change(state, state.status, new_status)
    end

    %{state | status: new_status, consecutive_failures: new_failures, consecutive_successes: 0}
  end

  defp notify_status_change(state, old_status, new_status) do
    Logger.info("Health check #{state.name}: #{old_status} -> #{new_status}")

    # Call custom callback if provided
    if state.on_status_change do
      Task.start(fn ->
        state.on_status_change.(old_status, new_status)
      end)
    end

    # Notify subscribers
    metadata = %{
      checker: state.name,
      target: state.target,
      timestamp: DateTime.utc_now(),
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes
    }

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:health_status_changed, old_status, new_status, metadata})
    end)
  end

  defp default_check_fn(target) when is_pid(target) or is_atom(target) do
    fn target ->
      # For generic process health, just check if it's alive
      try do
        if Process.alive?(target) do
          {:ok, %{alive: true}}
        else
          {:error, :process_not_alive}
        end
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    end
  end

  @doc """
  Creates a health check function for MCP clients.

  This function attempts to list tools as a health check.
  """
  @spec mcp_client_check_fn() :: (pid() -> {:ok, map()} | {:error, any()})
  def mcp_client_check_fn do
    fn client ->
      case Arbor.MCP.Client.list_tools(client) do
        {:ok, result} ->
          tool_count = length(Map.get(result, "tools", []))
          {:ok, %{method: :list_tools, tool_count: tool_count}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a health check function for MCP servers.

  This function sends an initialize request to check server health.
  """
  @spec mcp_server_check_fn() :: (pid() -> {:ok, map()} | {:error, any()})
  def mcp_server_check_fn do
    fn server ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "Arbor.MCP HealthCheck",
            "version" => "1.0.0"
          }
        }
      }

      case GenServer.call(server, {:mcp_request, request}, 5000) do
        {:ok, %{"result" => result}} ->
          {:ok,
           %{
             method: :initialize,
             protocol_version: result["protocolVersion"],
             server_name: get_in(result, ["serverInfo", "name"])
           }}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :invalid_response}
      end
    end
  end
end
