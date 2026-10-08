defmodule Arbor.MCP.Reliability.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.CircuitBreaker

  describe "circuit breaker states" do
    test "starts in closed state" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 3)

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
      assert state.failure_count == 0
    end

    test "opens after reaching failure threshold" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 3,
          reset_timeout: 100
        )

      # Fail 3 times
      for _ <- 1..3 do
        result = CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
        assert result == {:error, :test_error}
      end

      # Circuit should be open now
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open

      # Calls should fail fast
      result = CircuitBreaker.call(breaker, fn -> {:ok, :should_not_run} end)
      assert result == {:error, :circuit_open}
    end

    test "transitions to half-open after reset timeout" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          reset_timeout: 50
        )

      # Open the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
      end

      # Wait for reset timeout
      Process.sleep(100)

      # Should try half-open
      result = CircuitBreaker.call(breaker, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "closes after success threshold in half-open" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          success_threshold: 2,
          reset_timeout: 50
        )

      # Open the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
      end

      # Wait for reset timeout
      Process.sleep(100)

      # Succeed twice to close
      for _ <- 1..2 do
        result = CircuitBreaker.call(breaker, fn -> {:ok, :success} end)
        assert result == {:ok, :success}
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
    end
  end

  describe "error filtering" do
    test "only counts specified errors" do
      error_filter = fn
        :counted_error -> true
        _ -> false
      end

      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          error_filter: error_filter
        )

      # These should not count
      for _ <- 1..3 do
        CircuitBreaker.call(breaker, fn -> {:error, :ignored_error} end)
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
      assert state.failure_count == 0

      # These should count
      for _ <- 1..2 do
        CircuitBreaker.call(breaker, fn -> {:error, :counted_error} end)
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end
  end

  describe "manual controls" do
    test "manual trip opens circuit" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 10)

      assert CircuitBreaker.trip(breaker) == :ok

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end

    test "manual reset closes circuit" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      # Open it
      CircuitBreaker.call(breaker, fn -> {:error, :test} end)

      assert CircuitBreaker.reset(breaker) == :ok

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
    end
  end

  describe "statistics" do
    test "tracks call statistics" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 10)

      # Make some successful calls
      for _ <- 1..3 do
        CircuitBreaker.call(breaker, fn -> {:ok, :success} end)
      end

      # Make some failed calls
      for _ <- 1..2 do
        CircuitBreaker.call(breaker, fn -> {:error, :failure} end)
      end

      stats = CircuitBreaker.get_stats(breaker)
      assert stats.total_calls == 5
      assert stats.successful_calls == 3
      assert stats.failed_calls == 2
      assert stats.rejected_calls == 0
    end
  end

  describe "timeout handling" do
    test "handles operation timeouts" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          timeout: 50
        )

      result =
        CircuitBreaker.call(breaker, fn ->
          Process.sleep(100)
          {:ok, :too_late}
        end)

      assert result == {:error, :timeout}
    end
  end
end
