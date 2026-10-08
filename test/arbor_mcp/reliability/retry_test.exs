defmodule Arbor.MCP.Reliability.RetryTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.Retry

  describe "basic retry functionality" do
    test "succeeds on first attempt" do
      counter = start_counter()

      result =
        Retry.with_retry(fn ->
          increment_counter(counter)
          {:ok, :success}
        end)

      assert result == {:ok, :success}
      assert get_counter(counter) == 1
    end

    test "retries on failure and eventually succeeds" do
      counter = start_counter()

      result =
        Retry.with_retry(
          fn ->
            count = increment_counter(counter)

            if count < 3 do
              {:error, :temporary_failure}
            else
              {:ok, :success}
            end
          end,
          max_attempts: 5,
          initial_delay: 10
        )

      assert result == {:ok, :success}
      assert get_counter(counter) == 3
    end

    test "returns the last underlying error unchanged after max attempts" do
      counter = start_counter()

      result =
        Retry.with_retry(
          fn ->
            increment_counter(counter)
            {:error, :permanent_failure}
          end,
          max_attempts: 3,
          initial_delay: 10
        )

      # Same error shape with or without a retry policy
      assert {:error, :permanent_failure} = result
      assert get_counter(counter) == 3
    end
  end

  describe "exponential backoff" do
    test "delays increase exponentially" do
      delays =
        for attempt <- 1..5 do
          Retry.calculate_delay(attempt,
            initial_delay: 100,
            backoff_factor: 2,
            jitter: false
          )
        end

      assert delays == [100, 200, 400, 800, 1600]
    end

    test "respects max delay" do
      delay =
        Retry.calculate_delay(10,
          initial_delay: 100,
          max_delay: 1000,
          backoff_factor: 2,
          jitter: false
        )

      assert delay == 1000
    end

    test "adds jitter when enabled" do
      # Get multiple samples to verify jitter
      delays =
        for _ <- 1..10 do
          Retry.calculate_delay(3,
            initial_delay: 100,
            backoff_factor: 2,
            jitter: true
          )
        end

      # All should be around 400 ± 100 (25% jitter)
      assert Enum.all?(delays, &(&1 >= 300 and &1 <= 500))
      # But not all the same
      assert length(Enum.uniq(delays)) > 1
    end

    test "jitter does not crash for sub-4ms delays" do
      # A 1ms delay previously produced :rand.uniform(0), which raises
      for _ <- 1..10 do
        delay = Retry.calculate_delay(1, initial_delay: 1, backoff_factor: 2, jitter: true)
        assert is_integer(delay)
        assert delay >= 0
      end
    end
  end

  describe "retry conditions" do
    test "custom should_retry? function" do
      counter = start_counter()

      should_retry? = fn
        :retry_this -> true
        :dont_retry_this -> false
        _ -> false
      end

      # This should retry
      result1 =
        Retry.with_retry(
          fn ->
            count = increment_counter(counter)

            if count < 2 do
              {:error, :retry_this}
            else
              {:ok, :success}
            end
          end,
          should_retry?: should_retry?,
          initial_delay: 10
        )

      assert result1 == {:ok, :success}
      assert get_counter(counter) == 2

      # This should not retry
      reset_counter(counter)

      result2 =
        Retry.with_retry(
          fn ->
            increment_counter(counter)
            {:error, :dont_retry_this}
          end,
          should_retry?: should_retry?,
          initial_delay: 10
        )

      assert result2 == {:error, :dont_retry_this}
      assert get_counter(counter) == 1
    end
  end

  describe "on_retry callback" do
    test "calls on_retry before each retry attempt" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_retry = fn attempt, error ->
        Agent.update(agent, &[{attempt, error} | &1])
      end

      Retry.with_retry(
        fn ->
          {:error, :test_error}
        end,
        max_attempts: 3,
        on_retry: on_retry,
        initial_delay: 10
      )

      retries = Agent.get(agent, &Enum.reverse/1)
      assert retries == [{1, :test_error}, {2, :test_error}]
    end
  end

  describe "linear retry" do
    test "uses fixed delay between attempts" do
      start_time = System.monotonic_time(:millisecond)
      counter = start_counter()

      Retry.with_linear_retry(
        fn ->
          increment_counter(counter)
          {:error, :failure}
        end,
        max_attempts: 3,
        delay: 50
      )

      duration = System.monotonic_time(:millisecond) - start_time

      # Should have 2 delays of ~50ms
      assert duration >= 100
      assert duration < 200
      assert get_counter(counter) == 3
    end
  end

  describe "fallback functionality" do
    test "tries functions in order until one succeeds" do
      results = [
        fn -> {:error, :primary_failed} end,
        fn -> {:error, :secondary_failed} end,
        fn -> {:ok, :tertiary_success} end,
        fn -> {:ok, :never_called} end
      ]

      result = Retry.with_fallback(results, max_attempts: 1)
      assert result == {:ok, :tertiary_success}
    end

    test "returns error if all fallbacks fail" do
      results = [
        fn -> {:error, :primary_failed} end,
        fn -> {:error, :secondary_failed} end
      ]

      result = Retry.with_fallback(results, max_attempts: 1)
      assert result == {:error, :all_failed}
    end
  end

  describe "wrapped functions" do
    test "creates reusable retry wrapper" do
      counter = start_counter()

      wrapped =
        Retry.wrap(
          fn ->
            count = increment_counter(counter)

            if count < 2 do
              {:error, :temporary}
            else
              {:ok, :success}
            end
          end,
          max_attempts: 3,
          initial_delay: 10
        )

      # Can be called multiple times
      assert wrapped.() == {:ok, :success}
      assert get_counter(counter) == 2

      reset_counter(counter)
      assert wrapped.() == {:ok, :success}
      assert get_counter(counter) == 2
    end
  end

  describe "MCP-specific retry logic" do
    test "retries appropriate MCP errors" do
      mcp_opts = Retry.mcp_defaults()
      should_retry? = Keyword.get(mcp_opts, :should_retry?)

      # Should retry
      assert should_retry?.(:timeout) == true
      assert should_retry?.({:error, :closed}) == true
      assert should_retry?.({:error, :econnrefused}) == true
      assert should_retry?.(%{"error" => %{"code" => -32050}}) == true

      # Should not retry
      assert should_retry?.(%{"error" => %{"code" => -32600}}) == false
      assert should_retry?.(:unknown_error) == false
    end
  end

  describe "exception handling" do
    test "re-raises non-transport exceptions instead of retrying them" do
      counter = start_counter()

      assert_raise RuntimeError, "Test exception", fn ->
        Retry.with_retry(
          fn ->
            increment_counter(counter)
            raise "Test exception"
          end,
          max_attempts: 3,
          initial_delay: 10
        )
      end

      # The exception escapes on the first attempt — no retries happen
      assert get_counter(counter) == 1
    end

    test "treats transport exceptions as retryable errors" do
      result =
        Retry.with_retry(
          fn ->
            raise Arbor.MCP.Error.TransportError, transport: :http, reason: :closed
          end,
          max_attempts: 2,
          initial_delay: 10
        )

      assert {:error, %Arbor.MCP.Error.TransportError{transport: :http, reason: :closed}} = result
    end

    test "handles exits" do
      result =
        Retry.with_retry(
          fn ->
            exit(:test_exit)
          end,
          max_attempts: 2,
          initial_delay: 10
        )

      assert {:error, {:exit, :test_exit}} = result
    end

    test "handles throws" do
      result =
        Retry.with_retry(
          fn ->
            throw(:test_throw)
          end,
          max_attempts: 2,
          initial_delay: 10
        )

      assert {:error, {:throw, :test_throw}} = result
    end
  end

  # Helper functions
  defp start_counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp increment_counter(agent) do
    Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
  end

  defp get_counter(agent) do
    Agent.get(agent, & &1)
  end

  defp reset_counter(agent) do
    Agent.update(agent, fn _ -> 0 end)
  end
end
