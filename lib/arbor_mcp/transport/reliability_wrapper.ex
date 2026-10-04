defmodule Arbor.MCP.Transport.ReliabilityWrapper do
  @moduledoc """
  Transport wrapper that adds circuit breaker protection to any MCP transport.

  This module provides a transparent reliability layer that can be wrapped around
  any transport implementation to add circuit breaker protection, health monitoring,
  and retry logic without modifying the underlying transport.

  ## Features

  - Circuit breaker protection for transport operations
  - Health monitoring integration
  - Automatic error classification
  - Transport-specific configuration
  - Transparent pass-through for unaffected operations

  ## Usage

      # Wrap an existing transport with reliability features
      {:ok, transport_state} = SomeTransport.connect(opts)
      
      reliability_opts = [
        circuit_breaker: [
          failure_threshold: 5,
          reset_timeout: 30_000
        ],
        health_check: [
          check_interval: 60_000
        ]
      ]
      
      {:ok, wrapped_state} = ReliabilityWrapper.wrap(
        SomeTransport, 
        transport_state, 
        reliability_opts
      )
      
      # Use wrapped transport normally
      {:ok, new_state} = ReliabilityWrapper.send_message(message, wrapped_state)

  ## Error Classification

  The wrapper automatically classifies transport errors for circuit breaker decisions:

  - Connection errors: Always count as failures
  - Transport errors: Count as failures  
  - Security violations: Do not count as failures (policy issue, not transport failure)
  - Validation errors: Do not count as failures (client issue, not transport failure)
  - Timeout errors: Count as failures
  - Protocol errors: Count as failures
  """

  @behaviour Arbor.MCP.Transport

  alias Arbor.MCP.Reliability.{CircuitBreaker, HealthCheck}

  require Logger

  defstruct [
    :wrapped_module,
    :wrapped_state,
    :circuit_breaker_pid,
    :health_check_pid,
    :config
  ]

  @type t :: %__MODULE__{
          wrapped_module: module(),
          wrapped_state: any(),
          circuit_breaker_pid: pid() | nil,
          health_check_pid: pid() | nil,
          config: map()
        }

  @type reliability_opts :: [
          circuit_breaker: keyword() | false,
          health_check: keyword() | false
        ]

  @doc """
  Wraps an existing transport with reliability features.

  ## Options

  - `:circuit_breaker` - Circuit breaker configuration or `false` to disable
  - `:health_check` - Health check configuration or `false` to disable

  ## Circuit Breaker Options

  - `:failure_threshold` - Number of failures before opening (default: 5)
  - `:success_threshold` - Number of successes to close half-open circuit (default: 3)
  - `:reset_timeout` - Time before transitioning from open to half-open (default: 30_000)
  - `:timeout` - Operation timeout in milliseconds (default: 5_000)

  ## Health Check Options

  - `:check_interval` - Interval between health checks (default: 60_000)
  - `:failure_threshold` - Health check failures before marking unhealthy (default: 3)
  - `:recovery_threshold` - Health check successes before marking healthy (default: 2)
  """
  @spec wrap(module(), any(), reliability_opts()) :: {:ok, t()} | {:error, any()}
  def wrap(transport_module, transport_state, opts \\ []) do
    circuit_breaker_opts = Keyword.get(opts, :circuit_breaker, [])
    health_check_opts = Keyword.get(opts, :health_check, [])

    # Start circuit breaker if enabled
    circuit_breaker_pid =
      if circuit_breaker_opts != false and circuit_breaker_opts != [] do
        cb_config = merge_circuit_breaker_defaults(circuit_breaker_opts)

        {:ok, pid} =
          CircuitBreaker.start_link([
            {:error_filter, &should_count_as_failure?/1} | cb_config
          ])

        pid
      else
        nil
      end

    # Start health check if enabled
    health_check_pid =
      if health_check_opts != false and health_check_opts != [] do
        hc_config =
          merge_health_check_defaults(health_check_opts, transport_module, transport_state)

        {:ok, pid} = HealthCheck.start_link(hc_config)
        pid
      else
        nil
      end

    config = %{
      circuit_breaker_enabled: circuit_breaker_pid != nil,
      health_check_enabled: health_check_pid != nil
    }

    wrapped_state = %__MODULE__{
      wrapped_module: transport_module,
      wrapped_state: transport_state,
      circuit_breaker_pid: circuit_breaker_pid,
      health_check_pid: health_check_pid,
      config: config
    }

    {:ok, wrapped_state}
  end

  @doc """
  Unwraps the reliability wrapper to get the original transport state.

  Useful for accessing transport-specific functions not part of the Transport behaviour.
  """
  @spec unwrap(t()) :: {module(), any()}
  def unwrap(%__MODULE__{} = state) do
    {state.wrapped_module, state.wrapped_state}
  end

  # Transport behaviour implementation

  @impl true
  def connect(_opts) do
    {:error, :use_wrap_function_instead}
  end

  @impl true
  def send_message(message, %__MODULE__{} = state) do
    if state.config.circuit_breaker_enabled do
      CircuitBreaker.call(state.circuit_breaker_pid, fn ->
        execute_wrapped_operation(:send_message, [message, state.wrapped_state], state)
      end)
    else
      execute_wrapped_operation(:send_message, [message, state.wrapped_state], state)
    end
  end

  @impl true
  def receive_message(%__MODULE__{} = state) do
    if state.config.circuit_breaker_enabled do
      CircuitBreaker.call(state.circuit_breaker_pid, fn ->
        execute_wrapped_operation(:receive_message, [state.wrapped_state], state)
      end)
    else
      execute_wrapped_operation(:receive_message, [state.wrapped_state], state)
    end
  end

  def receive_message(%__MODULE__{} = state, timeout) do
    if state.config.circuit_breaker_enabled do
      CircuitBreaker.call(state.circuit_breaker_pid, fn ->
        execute_wrapped_operation(:receive_message, [state.wrapped_state, timeout], state)
      end)
    else
      execute_wrapped_operation(:receive_message, [state.wrapped_state, timeout], state)
    end
  end

  @impl true
  def close(%__MODULE__{} = state) do
    # Always attempt the actual transport cleanup, even after a component dies.
    result = close_wrapped(state)
    components = Enum.map([state.circuit_breaker_pid, state.health_check_pid], &stop_component/1)

    case result do
      :ok -> Enum.find(components, :ok, &(&1 != :ok))
      {:error, _reason} = error -> error
    end
  end

  defp close_wrapped(state) do
    case state.wrapped_module.close(state.wrapped_state) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_close_result, other}}
    end
  rescue
    error -> {:error, {:cleanup_exception, error.__struct__}}
  catch
    kind, reason -> {:error, {:cleanup_failure, kind, reason}}
  end

  defp stop_component(nil), do: :ok

  defp stop_component(pid) do
    GenServer.stop(pid, :normal, 500)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, _reason -> kill_component(pid)
  end

  defp kill_component(pid) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      500 ->
        Process.demonitor(monitor, [:flush])
        {:error, :reliability_cleanup_timeout}
    end
  end

  @impl true
  def connected?(%__MODULE__{} = state) do
    # If health check is enabled, use its status
    if state.config.health_check_enabled do
      case HealthCheck.get_status(state.health_check_pid) do
        {:healthy, _metadata} ->
          true

        {:unhealthy, _metadata} ->
          false

        {:unknown, _metadata} ->
          # For unknown status, fall back to wrapped transport status
          state.wrapped_module.connected?(state.wrapped_state)

        _ ->
          false
      end
    else
      # Fall back to wrapped transport's connected status
      state.wrapped_module.connected?(state.wrapped_state)
    end
  end

  @impl true
  def linked_processes(%__MODULE__{} = state) do
    Enum.filter([state.circuit_breaker_pid, state.health_check_pid], &is_pid/1) ++
      Arbor.MCP.Transport.linked_processes(state.wrapped_module, state.wrapped_state)
  end

  @impl true
  def capabilities(%__MODULE__{} = state) do
    # Pass through capabilities from wrapped transport
    if function_exported?(state.wrapped_module, :capabilities, 1) do
      state.wrapped_module.capabilities(state.wrapped_state)
    else
      []
    end
  end

  @impl true
  def subscribe(subscriber, %__MODULE__{} = state) do
    if function_exported?(state.wrapped_module, :subscribe, 2) do
      case state.wrapped_module.subscribe(subscriber, state.wrapped_state) do
        {:ok, wrapped} -> {:ok, %{state | wrapped_state: wrapped}}
        {:error, _reason} = error -> error
      end
    else
      {:error, :push_not_supported}
    end
  end

  @doc """
  Gets circuit breaker statistics if enabled.
  """
  @spec get_circuit_breaker_stats(t()) :: map() | nil
  def get_circuit_breaker_stats(%__MODULE__{circuit_breaker_pid: nil}), do: nil

  def get_circuit_breaker_stats(%__MODULE__{circuit_breaker_pid: pid}) do
    CircuitBreaker.get_stats(pid)
  end

  @doc """
  Gets health check status if enabled.
  """
  @spec get_health_status(t()) :: map() | nil
  def get_health_status(%__MODULE__{health_check_pid: nil}), do: nil

  def get_health_status(%__MODULE__{health_check_pid: pid}) do
    HealthCheck.get_status(pid)
  end

  @doc """
  Manually opens the circuit breaker if enabled.
  """
  @spec open_circuit(t()) :: :ok | {:error, :not_enabled}
  def open_circuit(%__MODULE__{circuit_breaker_pid: nil}), do: {:error, :not_enabled}

  def open_circuit(%__MODULE__{circuit_breaker_pid: pid}) do
    CircuitBreaker.open(pid)
  end

  @doc """
  Manually closes the circuit breaker if enabled.
  """
  @spec close_circuit(t()) :: :ok | {:error, :not_enabled}
  def close_circuit(%__MODULE__{circuit_breaker_pid: nil}), do: {:error, :not_enabled}

  def close_circuit(%__MODULE__{circuit_breaker_pid: pid}) do
    CircuitBreaker.close(pid)
  end

  @doc """
  Resets the circuit breaker if enabled.
  """
  @spec reset_circuit(t()) :: :ok | {:error, :not_enabled}
  def reset_circuit(%__MODULE__{circuit_breaker_pid: nil}), do: {:error, :not_enabled}

  def reset_circuit(%__MODULE__{circuit_breaker_pid: pid}) do
    CircuitBreaker.reset(pid)
  end

  # Private functions

  defp execute_wrapped_operation(function, args, state) do
    case apply(state.wrapped_module, function, args) do
      {:ok, new_wrapped_state} ->
        {:ok, %{state | wrapped_state: new_wrapped_state}}

      {:ok, result, new_wrapped_state} ->
        {:ok, result, %{state | wrapped_state: new_wrapped_state}}

      {:error, reason} = error ->
        Logger.debug("Transport operation failed",
          module: state.wrapped_module,
          function: function,
          error: reason
        )

        error

      other ->
        other
    end
  end

  # Define which error types should count as failures
  @failure_error_types [:connection_error, :transport_error, :timeout_error, :protocol_error]
  @non_failure_error_types [:security_violation, :validation_error]

  defp should_count_as_failure?(:timeout), do: true
  defp should_count_as_failure?(:circuit_open), do: false

  defp should_count_as_failure?({:error, {error_type, _reason}}),
    do: failure_error_type?(error_type)

  defp should_count_as_failure?({:error, _reason}), do: true
  defp should_count_as_failure?(_), do: true

  defp failure_error_type?(error_type) when error_type in @failure_error_types, do: true
  defp failure_error_type?(error_type) when error_type in @non_failure_error_types, do: false
  defp failure_error_type?(_), do: true

  defp merge_circuit_breaker_defaults(opts) do
    defaults = [
      failure_threshold: 5,
      success_threshold: 3,
      reset_timeout: 30_000,
      timeout: 5_000
    ]

    Keyword.merge(defaults, opts)
  end

  defp merge_health_check_defaults(opts, _transport_module, _transport_state) do
    defaults = [
      check_interval: 60_000,
      failure_threshold: 3,
      recovery_threshold: 2,
      # Use a mock target for transport health checks
      target: self(),
      check_fn: fn _target ->
        # Always return healthy for transport wrapper
        # In a real implementation, this could check transport connectivity
        {:ok, :healthy}
      end
    ]

    merged = Keyword.merge(defaults, opts)

    # Add name if not provided (required by HealthCheck)
    if not Keyword.has_key?(merged, :name) do
      Keyword.put(merged, :name, :"health_check_#{System.unique_integer([:positive])}")
    else
      merged
    end
  end
end
