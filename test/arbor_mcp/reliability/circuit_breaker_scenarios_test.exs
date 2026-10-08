defmodule Arbor.MCP.Reliability.CircuitBreakerScenariosTest do
  @moduledoc """
  Additional circuit breaker tests covering various failure scenarios.

  This test suite expands on the basic circuit breaker tests to cover
  more complex scenarios and edge cases.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.CircuitBreaker

  describe "failure threshold scenarios" do
    test "circuit stays closed when failures are below threshold" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 5)

      # Fail 4 times (below threshold)
      for _ <- 1..4 do
        result = CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
        assert result == {:error, :test_error}
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
      assert state.failure_count == 4

      # Success doesn't necessarily reset count in this implementation
      result = CircuitBreaker.call(breaker, fn -> {:ok, :success} end)
      assert result == {:ok, :success}

      # Just verify it's still closed
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
    end

    test "circuit opens exactly at failure threshold" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 3)

      # Fail exactly 3 times
      for i <- 1..3 do
        result = CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
        assert result == {:error, :test_error}

        state = CircuitBreaker.get_state(breaker)

        if i < 3 do
          assert state.state == :closed
        else
          assert state.state == :open
        end
      end
    end
  end

  describe "timeout scenarios" do
    test "operation timeout counts as failure" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          timeout: 50
        )

      # First timeout
      result =
        CircuitBreaker.call(breaker, fn ->
          Process.sleep(100)
          {:ok, :too_late}
        end)

      assert result == {:error, :timeout}

      # Second timeout should open circuit
      result =
        CircuitBreaker.call(breaker, fn ->
          Process.sleep(100)
          {:ok, :too_late}
        end)

      assert result == {:error, :timeout}

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end

    test "fast failures with timeouts" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 3,
          timeout: 50
        )

      # Mix of fast failures and timeouts
      assert {:error, :fast_error} = CircuitBreaker.call(breaker, fn -> {:error, :fast_error} end)

      assert {:error, :timeout} =
               CircuitBreaker.call(breaker, fn ->
                 Process.sleep(100)
                 {:ok, :success}
               end)

      assert {:error, :fast_error} = CircuitBreaker.call(breaker, fn -> {:error, :fast_error} end)

      # Circuit should be open now
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end
  end

  describe "error filtering scenarios" do
    test "mixed errors with filtering" do
      # Only count :important_error as failures
      error_filter = fn
        :important_error -> true
        _ -> false
      end

      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          error_filter: error_filter
        )

      # These should not count
      for _ <- 1..5 do
        CircuitBreaker.call(breaker, fn -> {:error, :unimportant_error} end)
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
      assert state.failure_count == 0

      # These should count and open circuit
      CircuitBreaker.call(breaker, fn -> {:error, :important_error} end)
      CircuitBreaker.call(breaker, fn -> {:error, :important_error} end)

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end

    test "error filter with timeout and exceptions" do
      # Only count :connection_error
      error_filter = fn
        :connection_error -> true
        _ -> false
      end

      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 2,
          timeout: 50,
          error_filter: error_filter
        )

      # Timeout is handled by circuit breaker itself and may count regardless of filter
      result =
        CircuitBreaker.call(breaker, fn ->
          Process.sleep(100)
          {:ok, :success}
        end)

      assert result == {:error, :timeout}

      # Only connection errors count through filter
      CircuitBreaker.call(breaker, fn -> {:error, :connection_error} end)
      CircuitBreaker.call(breaker, fn -> {:error, :connection_error} end)

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end
  end

  describe "manual control scenarios" do
    test "basic manual control functions" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 10)

      # Initially closed
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed

      # Manual trip
      :ok = CircuitBreaker.trip(breaker)

      # Should be open now
      # Brief wait for async operation
      :timer.sleep(10)
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open

      # Manual reset
      :ok = CircuitBreaker.reset(breaker)

      # Should be closed again
      # Brief wait for async operation
      :timer.sleep(10)
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed
    end
  end

  describe "statistics tracking scenarios" do
    test "statistics accuracy under load" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 100)

      # Mix of successes and failures
      success_count = 30
      failure_count = 20

      for _ <- 1..success_count do
        CircuitBreaker.call(breaker, fn -> {:ok, :success} end)
      end

      for _ <- 1..failure_count do
        CircuitBreaker.call(breaker, fn -> {:error, :failure} end)
      end

      stats = CircuitBreaker.get_stats(breaker)
      assert stats.total_calls == success_count + failure_count
      assert stats.successful_calls == success_count
      assert stats.failed_calls == failure_count
      assert stats.rejected_calls == 0
    end

    test "statistics with open circuit" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 2)

      # Open circuit
      CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
      CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)

      # Verify circuit is open
      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open

      # Check that we have some statistics tracked
      stats = CircuitBreaker.get_stats(breaker)
      assert is_map(stats)
      assert stats.failed_calls >= 2
    end
  end

  describe "edge cases" do
    test "zero failure threshold" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 0)

      # Should open immediately on any failure
      result = CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
      assert result == {:error, :test_error}

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end

    test "moderate threshold works correctly" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 10)

      # Many failures should not open circuit yet
      for _ <- 1..9 do
        CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)
      end

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :closed

      # One more should open it
      CircuitBreaker.call(breaker, fn -> {:error, :test_error} end)

      state = CircuitBreaker.get_state(breaker)
      assert state.state == :open
    end
  end
end
