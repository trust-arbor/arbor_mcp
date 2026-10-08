defmodule Arbor.MCP.Reliability.CircuitBreaker.Core do
  @moduledoc """
  Pure circuit-breaker state machine used by `Arbor.MCP.Reliability.CircuitBreaker`.

  All elapsed-duration decisions use an injected `now_ms` value. The process
  shell passes `System.monotonic_time(:millisecond)` so open and half-open
  timeouts cannot go backwards when the wall clock is adjusted. Stored
  timestamps (`opened_at`, `last_failure_time`, `last_success_time`, and
  `stats.created_at`) are on that same monotonic millisecond scale.

  This module does not call `System` or `Process`. Callers must supply
  `now_ms`; there is no default clock here.
  """

  defstruct [
    :state,
    :failure_count,
    :success_count,
    :last_failure_time,
    :last_success_time,
    :opened_at,
    :config,
    :stats
  ]

  @type state :: :closed | :open | :half_open
  @type now_ms :: integer()
  @type t :: %__MODULE__{
          state: state(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          last_failure_time: now_ms() | nil,
          last_success_time: now_ms() | nil,
          opened_at: now_ms() | nil,
          config: map(),
          stats: map()
        }

  @type config :: %{
          failure_threshold: non_neg_integer(),
          success_threshold: non_neg_integer(),
          timeout: non_neg_integer(),
          failure_rate_threshold: float(),
          minimum_throughput: non_neg_integer(),
          reset_timeout: non_neg_integer()
        }

  @default_config %{
    failure_threshold: 5,
    success_threshold: 3,
    timeout: 60_000,
    failure_rate_threshold: 0.5,
    minimum_throughput: 10,
    reset_timeout: 300_000
  }

  @doc """
  Creates a new circuit breaker with the given configuration.

  `now_ms` is recorded as `stats.created_at`. Pass a monotonic millisecond
  value from the process shell.
  """
  @spec new(config() | map(), now_ms()) :: t()
  def new(config \\ %{}, now_ms) when is_integer(now_ms) do
    full_config = Map.merge(@default_config, config)

    %__MODULE__{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      last_success_time: nil,
      opened_at: nil,
      config: full_config,
      stats: init_stats(now_ms)
    }
  end

  @doc """
  Checks if a request should be allowed based on the current circuit state.
  """
  @spec allow_request?(t(), now_ms()) :: boolean()
  def allow_request?(%__MODULE__{} = circuit_breaker, now_ms) when is_integer(now_ms) do
    circuit_breaker
    |> check_state_transitions(now_ms)
    |> allowed?()
  end

  @doc """
  Checks if a request should be allowed and returns both the result and updated state.
  """
  @spec allow_request_with_state?(t(), now_ms()) :: {boolean(), t()}
  def allow_request_with_state?(%__MODULE__{} = circuit_breaker, now_ms)
      when is_integer(now_ms) do
    updated_cb = check_state_transitions(circuit_breaker, now_ms)
    {allowed?(updated_cb), updated_cb}
  end

  @doc """
  Records a successful operation and updates the circuit breaker state.
  """
  @spec record_success(t(), now_ms()) :: t()
  def record_success(%__MODULE__{} = circuit_breaker, now_ms) when is_integer(now_ms) do
    updated_cb = %{
      circuit_breaker
      | success_count: circuit_breaker.success_count + 1,
        last_success_time: now_ms,
        stats: update_stats(circuit_breaker.stats, :total_successes, 1)
    }

    case updated_cb.state do
      :half_open ->
        if updated_cb.success_count >= updated_cb.config.success_threshold do
          close_circuit(updated_cb)
        else
          updated_cb
        end

      :open ->
        %{updated_cb | success_count: 0}

      :closed ->
        updated_cb
    end
  end

  @doc """
  Records a failed operation and updates the circuit breaker state.
  """
  @spec record_failure(t(), now_ms()) :: t()
  def record_failure(%__MODULE__{} = circuit_breaker, now_ms) when is_integer(now_ms) do
    updated_cb = %{
      circuit_breaker
      | failure_count: circuit_breaker.failure_count + 1,
        last_failure_time: now_ms,
        stats: update_stats(circuit_breaker.stats, :total_failures, 1)
    }

    if should_open_circuit?(updated_cb) do
      open_circuit(updated_cb, now_ms)
    else
      updated_cb
    end
  end

  @doc """
  Forces the circuit breaker to a specific state.
  """
  @spec force_state(t(), state(), now_ms()) :: t()
  def force_state(%__MODULE__{} = circuit_breaker, new_state, now_ms) when is_integer(now_ms) do
    case new_state do
      :open ->
        %{
          circuit_breaker
          | state: :open,
            opened_at: now_ms,
            stats: update_stats(circuit_breaker.stats, :manual_opens, 1)
        }

      :closed ->
        %{
          circuit_breaker
          | state: :closed,
            failure_count: 0,
            success_count: 0,
            opened_at: nil,
            stats: update_stats(circuit_breaker.stats, :manual_closes, 1)
        }

      :half_open ->
        %{
          circuit_breaker
          | state: :half_open,
            success_count: 0,
            stats: update_stats(circuit_breaker.stats, :manual_half_opens, 1)
        }
    end
  end

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(t(), now_ms()) :: state()
  def get_state(%__MODULE__{} = circuit_breaker, now_ms) when is_integer(now_ms) do
    circuit_breaker
    |> check_state_transitions(now_ms)
    |> Map.fetch!(:state)
  end

  @doc """
  Gets circuit breaker statistics.
  """
  @spec get_stats(t()) :: map()
  def get_stats(%__MODULE__{} = circuit_breaker) do
    total_requests = circuit_breaker.stats.total_successes + circuit_breaker.stats.total_failures

    failure_rate =
      if total_requests > 0 do
        circuit_breaker.stats.total_failures / total_requests
      else
        0.0
      end

    Map.merge(circuit_breaker.stats, %{
      state: circuit_breaker.state,
      current_state: circuit_breaker.state,
      failure_count: circuit_breaker.failure_count,
      success_count: circuit_breaker.success_count,
      successful_calls: circuit_breaker.stats.total_successes,
      failed_calls: circuit_breaker.stats.total_failures,
      rejected_calls: 0,
      total_requests: total_requests,
      total_calls: total_requests,
      failure_rate: failure_rate,
      last_failure_time: circuit_breaker.last_failure_time,
      last_success_time: circuit_breaker.last_success_time,
      opened_at: circuit_breaker.opened_at
    })
  end

  @doc """
  Resets the circuit breaker to its initial state.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = circuit_breaker) do
    %{
      circuit_breaker
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil,
        last_success_time: nil,
        opened_at: nil,
        stats: update_stats(circuit_breaker.stats, :resets, 1)
    }
  end

  defp allowed?(%__MODULE__{state: :open}), do: false
  defp allowed?(%__MODULE__{}), do: true

  defp check_state_transitions(%__MODULE__{state: :open} = circuit_breaker, now_ms) do
    if circuit_breaker.opened_at != nil and
         elapsed_ms(now_ms, circuit_breaker.opened_at) >= circuit_breaker.config.reset_timeout do
      %{
        circuit_breaker
        | state: :half_open,
          success_count: 0,
          stats: update_stats(circuit_breaker.stats, :automatic_half_opens, 1)
      }
    else
      circuit_breaker
    end
  end

  defp check_state_transitions(%__MODULE__{state: :half_open} = circuit_breaker, now_ms) do
    if circuit_breaker.last_success_time != nil and
         elapsed_ms(now_ms, circuit_breaker.last_success_time) >=
           circuit_breaker.config.reset_timeout do
      close_circuit(circuit_breaker)
    else
      circuit_breaker
    end
  end

  defp check_state_transitions(circuit_breaker, _now_ms), do: circuit_breaker

  # Clamp so a backwards clock cannot produce a negative duration and trip
  # open/half-open transitions earlier than the configured timeout.
  defp elapsed_ms(now_ms, started_at) when is_integer(now_ms) and is_integer(started_at) do
    max(0, now_ms - started_at)
  end

  defp should_open_circuit?(%__MODULE__{} = circuit_breaker) do
    failure_threshold_exceeded =
      circuit_breaker.failure_count >= circuit_breaker.config.failure_threshold

    total_requests = circuit_breaker.stats.total_successes + circuit_breaker.stats.total_failures
    minimum_throughput_met = total_requests >= circuit_breaker.config.minimum_throughput

    failure_rate =
      if total_requests > 0 do
        circuit_breaker.stats.total_failures / total_requests
      else
        0.0
      end

    failure_rate_exceeded =
      minimum_throughput_met and failure_rate >= circuit_breaker.config.failure_rate_threshold

    failure_threshold_exceeded or failure_rate_exceeded
  end

  defp open_circuit(%__MODULE__{} = circuit_breaker, now_ms) do
    %{
      circuit_breaker
      | state: :open,
        opened_at: now_ms,
        stats: update_stats(circuit_breaker.stats, :circuit_opens, 1)
    }
  end

  defp close_circuit(%__MODULE__{} = circuit_breaker) do
    %{
      circuit_breaker
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        opened_at: nil,
        stats: update_stats(circuit_breaker.stats, :circuit_closes, 1)
    }
  end

  defp init_stats(now_ms) do
    %{
      total_successes: 0,
      total_failures: 0,
      circuit_opens: 0,
      circuit_closes: 0,
      manual_opens: 0,
      manual_closes: 0,
      manual_half_opens: 0,
      automatic_half_opens: 0,
      resets: 0,
      created_at: now_ms
    }
  end

  defp update_stats(stats, metric, increment) do
    current_value = Map.get(stats, metric, 0)
    Map.put(stats, metric, current_value + increment)
  end
end
