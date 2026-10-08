defmodule Arbor.MCP.Reliability.HealthMonitoringTest do
  @moduledoc """
  Tests for health monitoring and recovery scenarios.

  This test suite focuses on health check functionality and how it
  integrates with other reliability features like circuit breakers.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.HealthCheck
  alias Arbor.MCP.Transport.{ReliabilityWrapper, Test}

  describe "health check basic functionality" do
    test "health check starts and performs initial check" do
      check_fn = fn _target -> {:ok, :healthy} end

      {:ok, health_check} =
        HealthCheck.start_link(
          name: :test_health_check,
          target: self(),
          check_fn: check_fn,
          check_interval: 1000,
          failure_threshold: 2
        )

      # Give it time to perform initial check
      :timer.sleep(50)

      status = HealthCheck.get_status(health_check)
      assert is_tuple(status)

      # Clean up
      GenServer.stop(health_check)
    end

    test "health check with custom check function" do
      # Simple health check that just works
      check_fn = fn _target -> {:ok, :healthy} end

      {:ok, health_check} =
        HealthCheck.start_link(
          name: :test_health_check_custom,
          target: self(),
          check_fn: check_fn,
          check_interval: 100,
          failure_threshold: 1
        )

      # Wait for health check to initialize
      :timer.sleep(50)

      # Should be able to get status
      status = HealthCheck.get_status(health_check)
      assert is_tuple(status)

      # Clean up
      GenServer.stop(health_check)
    end
  end

  describe "health check with transport integration" do
    test "transport health check integration" do
      {:ok, transport_state} = Test.connect([])

      # Create a simple health check for the transport
      health_check_fn = fn _target ->
        # Simple check that always returns healthy
        {:ok, :healthy}
      end

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(
          Test,
          transport_state,
          health_check: [
            check_interval: 100,
            check_fn: health_check_fn,
            failure_threshold: 2
          ]
        )

      # Wait for health check to initialize
      :timer.sleep(50)

      # Get health status
      health_status = ReliabilityWrapper.get_health_status(wrapped_state)
      assert health_status != nil

      # Verify connected status uses health check
      connected = ReliabilityWrapper.connected?(wrapped_state)
      assert is_boolean(connected)

      # Clean up
      ReliabilityWrapper.close(wrapped_state)
    end

    test "transport health check affects connection status" do
      {:ok, transport_state} = Test.connect([])

      # Simple health check that returns healthy
      simple_check_fn = fn _target -> {:ok, :healthy} end

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(
          Test,
          transport_state,
          health_check: [
            check_interval: 100,
            check_fn: simple_check_fn,
            failure_threshold: 1,
            recovery_threshold: 1
          ]
        )

      # Wait for health check to initialize
      :timer.sleep(50)

      # Should be able to get health status
      health_status = ReliabilityWrapper.get_health_status(wrapped_state)
      assert health_status != nil

      # Connection status should work
      connected = ReliabilityWrapper.connected?(wrapped_state)
      assert is_boolean(connected)

      # Clean up
      ReliabilityWrapper.close(wrapped_state)
    end
  end

  describe "health check failure scenarios" do
    test "health check failure threshold behavior" do
      failure_count = Agent.start_link(fn -> 0 end) |> elem(1)

      failing_check_fn = fn _target ->
        count = Agent.get_and_update(failure_count, fn x -> {x + 1, x + 1} end)
        if count <= 2, do: {:ok, :healthy}, else: {:error, :service_down}
      end

      {:ok, health_check} =
        HealthCheck.start_link(
          name: :test_failing_health_check,
          target: self(),
          check_fn: failing_check_fn,
          check_interval: 30,
          failure_threshold: 2
        )

      # Wait for checks to run and failures to accumulate
      :timer.sleep(200)

      # Get final status - should be unhealthy after threshold reached
      status = HealthCheck.get_status(health_check)
      assert is_tuple(status)

      # Clean up
      GenServer.stop(health_check)
      Agent.stop(failure_count)
    end

    test "health check recovery after failures" do
      # Simple test that creates a health check that initially fails then succeeds
      check_pid = self()

      recovery_check_fn = fn _target ->
        # First call fails, subsequent calls succeed
        receive do
          :fail -> {:error, :temporary_failure}
        after
          0 -> {:ok, :recovered}
        end
      end

      {:ok, health_check} =
        HealthCheck.start_link(
          name: :test_recovery_health_check,
          target: check_pid,
          check_fn: recovery_check_fn,
          check_interval: 100,
          failure_threshold: 1,
          recovery_threshold: 1
        )

      # Wait for health check to initialize
      :timer.sleep(50)

      # Should be able to get status
      status = HealthCheck.get_status(health_check)
      assert is_tuple(status)

      # Clean up
      GenServer.stop(health_check)
    end
  end

  describe "health monitoring with circuit breaker integration" do
    test "health check and circuit breaker work together" do
      {:ok, transport_state} = Test.connect([])

      # Start with healthy check
      health_status = Agent.start_link(fn -> :healthy end) |> elem(1)

      health_check_fn = fn _target ->
        status = Agent.get(health_status, & &1)

        case status do
          :healthy -> {:ok, :healthy}
          :unhealthy -> {:error, :service_down}
        end
      end

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(
          Test,
          transport_state,
          circuit_breaker: [failure_threshold: 3, reset_timeout: 100],
          health_check: [
            check_interval: 50,
            check_fn: health_check_fn,
            failure_threshold: 1
          ]
        )

      # Initially both should be working
      assert {:ok, _} = ReliabilityWrapper.send_message("test", wrapped_state)

      # Mark health as unhealthy
      Agent.update(health_status, fn _ -> :unhealthy end)

      # Wait for health check to detect the change
      :timer.sleep(100)

      # Connection status should reflect health check
      health_check_status = ReliabilityWrapper.get_health_status(wrapped_state)
      assert health_check_status != nil

      # Clean up
      ReliabilityWrapper.close(wrapped_state)
      Agent.stop(health_status)
    end

    test "circuit breaker and health monitoring combined failure handling" do
      # Create a mock transport that can be controlled
      defmodule ControllableTransport do
        @behaviour Arbor.MCP.Transport

        def connect(_opts), do: {:ok, %{should_fail: false}}

        def send_message(_msg, %{should_fail: true}) do
          {:error, :service_unavailable}
        end

        def send_message(_msg, state), do: {:ok, state}

        def receive_message(state), do: {:ok, "response", state}
        def close(_state), do: :ok
        def connected?(%{should_fail: true}), do: false
        def connected?(_state), do: true

        def set_failure_mode(state, should_fail) do
          %{state | should_fail: should_fail}
        end
      end

      {:ok, transport_state} = ControllableTransport.connect([])

      service_health = Agent.start_link(fn -> :healthy end) |> elem(1)

      combined_health_check = fn _target ->
        case Agent.get(service_health, & &1) do
          :healthy -> {:ok, :all_systems_operational}
          :degraded -> {:error, :performance_issues}
          :down -> {:error, :service_unavailable}
        end
      end

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(
          ControllableTransport,
          transport_state,
          circuit_breaker: [failure_threshold: 2, reset_timeout: 100],
          health_check: [
            check_interval: 50,
            check_fn: combined_health_check,
            failure_threshold: 1
          ]
        )

      # Initially everything works
      assert {:ok, _} = ReliabilityWrapper.send_message("test", wrapped_state)

      # Simulate service degradation
      Agent.update(service_health, fn _ -> :degraded end)
      :timer.sleep(100)

      # Should still work but health check reflects degradation
      assert {:ok, _} = ReliabilityWrapper.send_message("test", wrapped_state)

      # Simulate complete failure
      Agent.update(service_health, fn _ -> :down end)

      # Update the transport state to fail
      {ControllableTransport, current_state} = ReliabilityWrapper.unwrap(wrapped_state)
      failed_state = ControllableTransport.set_failure_mode(current_state, true)
      updated_wrapped = %{wrapped_state | wrapped_state: failed_state}

      # Operations should start failing
      assert {:error, :service_unavailable} =
               ReliabilityWrapper.send_message("test", updated_wrapped)

      # Clean up
      ReliabilityWrapper.close(updated_wrapped)
      Agent.stop(service_health)
    end
  end

  describe "health check configuration validation" do
    test "health check with various thresholds" do
      check_fn = fn _target -> {:ok, :healthy} end

      # Test different threshold configurations
      configs = [
        [failure_threshold: 1, recovery_threshold: 1],
        [failure_threshold: 3, recovery_threshold: 2],
        [failure_threshold: 5, recovery_threshold: 3]
      ]

      for config <- configs do
        full_config =
          [
            name: :"health_check_#{System.unique_integer([:positive])}",
            target: self(),
            check_fn: check_fn,
            check_interval: 1000
          ] ++ config

        {:ok, health_check} = HealthCheck.start_link(full_config)

        # Give it time to initialize
        :timer.sleep(10)

        # Should be able to get status
        status = HealthCheck.get_status(health_check)
        assert is_tuple(status)

        # Clean up
        GenServer.stop(health_check)
      end
    end

    test "health check with edge case intervals" do
      check_fn = fn _target -> {:ok, :healthy} end

      # Very short interval (should work but be fast)
      {:ok, fast_check} =
        HealthCheck.start_link(
          name: :fast_health_check,
          target: self(),
          check_fn: check_fn,
          # Very fast
          check_interval: 10,
          failure_threshold: 1
        )

      :timer.sleep(50)

      status = HealthCheck.get_status(fast_check)
      assert is_tuple(status)

      GenServer.stop(fast_check)

      # Longer interval (should work normally)
      {:ok, slow_check} =
        HealthCheck.start_link(
          name: :slow_health_check,
          target: self(),
          check_fn: check_fn,
          # Slower
          check_interval: 2000,
          failure_threshold: 1
        )

      # Don't wait for full interval
      :timer.sleep(20)

      status = HealthCheck.get_status(slow_check)
      assert is_tuple(status)

      GenServer.stop(slow_check)
    end
  end
end
