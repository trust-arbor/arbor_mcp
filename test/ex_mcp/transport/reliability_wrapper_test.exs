defmodule ExMCP.Transport.ReliabilityWrapperTest do
  use ExUnit.Case, async: true
  alias ExMCP.Transport.{ReliabilityWrapper, Test}

  # Reports its close to the owner, so a test can tell it ran.
  defmodule RecordingTransport do
    @moduledoc false

    def close({owner, ref}) do
      send(owner, {:wrapped_closed, ref})
      :ok
    end
  end

  describe "wrap/3" do
    test "successfully wraps a transport with circuit breaker" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [
          failure_threshold: 3,
          reset_timeout: 1000
        ]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert wrapped_state.wrapped_module == Test
      assert wrapped_state.wrapped_state == transport_state
      assert is_pid(wrapped_state.circuit_breaker_pid)
      assert wrapped_state.health_check_pid == nil
    end

    test "successfully wraps a transport with health check" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        health_check: [
          check_interval: 1000,
          failure_threshold: 2
        ]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert wrapped_state.circuit_breaker_pid == nil
      assert is_pid(wrapped_state.health_check_pid)
    end

    test "successfully wraps a transport with both circuit breaker and health check" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 2],
        health_check: [check_interval: 1000]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert is_pid(wrapped_state.circuit_breaker_pid)
      assert is_pid(wrapped_state.health_check_pid)
    end

    test "disables components when set to false" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: false,
        health_check: false
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert wrapped_state.circuit_breaker_pid == nil
      assert wrapped_state.health_check_pid == nil
    end
  end

  defmodule StatefulSendTransport do
    def send_keeping_state(:fail, state), do: {:error, :refused, Map.put(state, :failed, true)}
    def send_keeping_state(:reply, state), do: {:ok, Map.put(state, :sent, true), "response"}
    def close(_state), do: :ok
  end

  test "a synchronous send keeps its state before its response" do
    {:ok, wrapper} = ReliabilityWrapper.wrap(StatefulSendTransport, %{}, [])
    assert {:ok, updated, "response"} = ReliabilityWrapper.send_message(:reply, wrapper)
    assert updated.wrapped_state == %{sent: true}
  end

  test "failed-send state survives nested wrappers and still trips the breaker" do
    {:ok, inner} = ReliabilityWrapper.wrap(StatefulSendTransport, %{}, [])

    {:ok, outer} =
      ReliabilityWrapper.wrap(ReliabilityWrapper, inner, circuit_breaker: [failure_threshold: 1])

    on_exit(fn -> ReliabilityWrapper.close(outer) end)
    assert {:error, :refused, updated} = ReliabilityWrapper.send_keeping_state(:fail, outer)
    assert updated.wrapped_state.wrapped_state == %{failed: true}
    assert {:error, :circuit_open} = ReliabilityWrapper.send_keeping_state(:fail, updated)
  end

  describe "send_message/2" do
    test "passes through successful operations" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 3]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert {:ok, updated_state} = ReliabilityWrapper.send_message("test message", wrapped_state)
      assert %ReliabilityWrapper{} = updated_state
    end

    test "handles transport errors through circuit breaker" do
      # Create a mock transport that will fail
      defmodule FailingTransport do
        @behaviour ExMCP.Transport

        def connect(_opts), do: {:ok, %{fail_count: 0}}

        def send_message(_message, state) do
          new_state = %{state | fail_count: state.fail_count + 1}

          if new_state.fail_count <= 2 do
            {:error, {:connection_error, :simulated_failure}}
          else
            {:ok, new_state}
          end
        end

        def receive_message(state), do: {:ok, "response", state}
        def close(_state), do: :ok
        def connected?(_state), do: true
      end

      {:ok, transport_state} = FailingTransport.connect([])

      reliability_opts = [
        circuit_breaker: [
          failure_threshold: 2,
          reset_timeout: 100
        ]
      ]

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(FailingTransport, transport_state, reliability_opts)

      # First failure
      assert {:error, {:connection_error, :simulated_failure}} =
               ReliabilityWrapper.send_message("test", wrapped_state)

      # Second failure
      assert {:error, {:connection_error, :simulated_failure}} =
               ReliabilityWrapper.send_message("test", wrapped_state)

      # Circuit should now be open
      assert {:error, :circuit_open} =
               ReliabilityWrapper.send_message("test", wrapped_state)
    end

    test "operates without circuit breaker when disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert {:ok, _updated_state} =
               ReliabilityWrapper.send_message("test message", wrapped_state)
    end
  end

  describe "receive_message/2 with a circuit breaker" do
    # A receive runs in the calling process (see the wrapper), so a stdio
    # port stays with its owner; the breaker still records its outcome.
    test "trips on real receive failures" do
      defmodule FailingReceiveTransport do
        @behaviour ExMCP.Transport

        def connect(_opts), do: {:ok, %{}}

        def send_message(_message, state), do: {:ok, state}

        def receive_message(_state, _timeout),
          do: {:error, {:connection_error, :simulated_receive_failure}}

        def receive_message(state), do: receive_message(state, :infinity)
        def close(_state), do: :ok
        def connected?(_state), do: true
      end

      {:ok, transport_state} = FailingReceiveTransport.connect([])

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(FailingReceiveTransport, transport_state,
          circuit_breaker: [failure_threshold: 2, reset_timeout: 100]
        )

      assert {:error, {:connection_error, :simulated_receive_failure}} =
               ReliabilityWrapper.receive_message(wrapped_state, 1_000)

      assert {:error, {:connection_error, :simulated_receive_failure}} =
               ReliabilityWrapper.receive_message(wrapped_state, 1_000)

      assert {:error, :circuit_open} = ReliabilityWrapper.receive_message(wrapped_state, 1_000)
    end

    test "records a raise in the receive as a failure, contained" do
      defmodule RaisingReceiveTransport do
        @behaviour ExMCP.Transport

        def connect(_opts), do: {:ok, %{}}
        def send_message(_message, state), do: {:ok, state}

        def receive_message(_state, _timeout), do: raise("receive exploded")

        def receive_message(state), do: receive_message(state, :infinity)
        def close(_state), do: :ok
        def connected?(_state), do: true
      end

      {:ok, transport_state} = RaisingReceiveTransport.connect([])

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(RaisingReceiveTransport, transport_state,
          circuit_breaker: [failure_threshold: 1, reset_timeout: 100]
        )

      assert {:error, %RuntimeError{message: "receive exploded"}} =
               ReliabilityWrapper.receive_message(wrapped_state, 1_000)

      assert {:error, :circuit_open} = ReliabilityWrapper.receive_message(wrapped_state, 1_000)
    end
  end

  describe "connected?/1" do
    test "returns health check status when enabled" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        health_check: [
          check_interval: 1000,
          failure_threshold: 1
        ]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      # Give health check time to initialize and perform first check
      :timer.sleep(50)

      # Since Test transport returns false for connected? (no peer_pid),
      # and health check status is unknown initially, the wrapped transport
      # should fall back to the base transport's connected status
      assert ReliabilityWrapper.connected?(wrapped_state) == false
    end

    test "falls back to wrapped transport status when health check disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert ReliabilityWrapper.connected?(wrapped_state) == Test.connected?(transport_state)
    end
  end

  describe "circuit breaker management" do
    test "can manually control circuit breaker" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 5]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      # Get initial stats
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed

      # Manually open circuit
      :ok = ReliabilityWrapper.open_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :open

      # Manually close circuit
      :ok = ReliabilityWrapper.close_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed

      # Reset circuit
      :ok = ReliabilityWrapper.reset_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed
    end

    test "returns error when circuit breaker is disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state) == nil
      assert ReliabilityWrapper.open_circuit(wrapped_state) == {:error, :not_enabled}
      assert ReliabilityWrapper.close_circuit(wrapped_state) == {:error, :not_enabled}
      assert ReliabilityWrapper.reset_circuit(wrapped_state) == {:error, :not_enabled}
    end
  end

  describe "unwrap/1" do
    test "returns original transport module and state" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert {Test, ^transport_state} = ReliabilityWrapper.unwrap(wrapped_state)
    end
  end

  describe "close/1" do
    test "properly closes reliability components and wrapped transport" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 5],
        health_check: [check_interval: 1000]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      cb_pid = wrapped_state.circuit_breaker_pid
      hc_pid = wrapped_state.health_check_pid

      assert Process.alive?(cb_pid)
      assert Process.alive?(hc_pid)

      assert :ok = ReliabilityWrapper.close(wrapped_state)

      # Give processes time to terminate
      :timer.sleep(10)

      refute Process.alive?(cb_pid)
      refute Process.alive?(hc_pid)
    end

    for component <- [:circuit_breaker_pid, :health_check_pid] do
      @component component
      test "closes the wrapped transport when the #{component} already died" do
        ref = make_ref()

        {:ok, wrapped_state} =
          ReliabilityWrapper.wrap(RecordingTransport, {self(), ref},
            circuit_breaker: [failure_threshold: 5],
            health_check: [check_interval: 60_000]
          )

        dead = Map.fetch!(wrapped_state, @component)
        # wrap/3 links the components to the caller; unlink so the kill
        # does not take the test down with it.
        Process.unlink(dead)
        monitor = Process.monitor(dead)
        Process.exit(dead, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^dead, :killed}

        assert :ok = ReliabilityWrapper.close(wrapped_state)
        assert_receive {:wrapped_closed, ^ref}
        refute Process.alive?(wrapped_state.circuit_breaker_pid)
        refute Process.alive?(wrapped_state.health_check_pid)
      end
    end

    test "close is bounded when a component is stuck in a callback" do
      ref = make_ref()
      test_pid = self()

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(RecordingTransport, {test_pid, ref},
          health_check: [
            check_interval: 60_000,
            timeout: 5_000,
            check_fn: fn _target ->
              send(test_pid, {:checking, self()})

              receive do
                :never -> {:ok, %{}}
              end
            end
          ]
        )

      hc_pid = wrapped_state.health_check_pid
      # A check in progress holds the health check inside its callback.
      spawn(fn -> ExMCP.Reliability.HealthCheck.check_now(hc_pid) end)
      assert_receive {:checking, _check}

      # Closed from the wrapping process, as the client does. Without a bound
      # it would wait out the check's 5s timeout.
      started = System.monotonic_time(:millisecond)
      assert :ok = ReliabilityWrapper.close(wrapped_state)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_receive {:wrapped_closed, ^ref}
      refute Process.alive?(hc_pid)
    end
  end

  describe "capabilities/1" do
    test "passes through capabilities from wrapped transport" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      # Test transport implements capabilities/1 and returns [:push]
      assert ReliabilityWrapper.capabilities(wrapped_state) == [:push]
    end
  end
end
