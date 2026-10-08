defmodule Arbor.MCP.Reliability.SupervisorTest do
  use ExUnit.Case, async: false
  import Arbor.MCP.TestHelpers, only: [unique_process_name: 2]

  alias Arbor.MCP.TestHelpers

  alias Arbor.MCP.Reliability
  alias Arbor.MCP.Reliability.Supervisor, as: ReliabilitySupervisor
  alias Arbor.MCP.Testing.MockServer

  describe "start_link/1" do
    test "starts supervisor with default options" do
      assert {:ok, pid} = ReliabilitySupervisor.start_link()
      assert Process.alive?(pid)
      assert is_pid(pid)

      # Verify it's actually a supervisor process (uses GenServer underneath)
      assert {:status, ^pid, {:module, :gen_server}, _} = :sys.get_status(pid)

      GenServer.stop(pid)
    end

    test "starts supervisor with custom name", %{test: test} do
      name = unique_process_name(test, "supervisor")
      assert {:ok, pid} = ReliabilitySupervisor.start_link(name: name)
      assert Process.whereis(name) == pid
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "starts child supervisors and registry" do
      assert {:ok, pid} = ReliabilitySupervisor.start_link()

      # Give supervisor time to start children
      Process.sleep(50)

      # Verify child processes exist
      children = Supervisor.which_children(pid)
      assert length(children) == 3

      # Check for registry and dynamic supervisors by their module name patterns
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      # Should have CircuitBreakerSupervisor, HealthCheckSupervisor, and Registry
      assert Enum.any?(child_ids, &String.contains?(to_string(&1), "CircuitBreakerSupervisor"))
      assert Enum.any?(child_ids, &String.contains?(to_string(&1), "HealthCheckSupervisor"))
      assert Enum.any?(child_ids, &String.contains?(to_string(&1), "Registry"))

      GenServer.stop(pid)
    end
  end

  describe "create_reliable_client/2" do
    setup %{test: test} do
      supervisor_name = unique_process_name(test, "supervisor")
      mock_server_name = unique_process_name(test, "mock_server")

      {:ok, supervisor} = ReliabilitySupervisor.start_link(name: supervisor_name)
      {:ok, mock_server} = MockServer.start_link(name: mock_server_name)

      on_exit(fn ->
        TestHelpers.safe_stop_process(supervisor)
        TestHelpers.safe_stop_process(mock_server)
      end)

      %{supervisor: supervisor, mock_server: mock_server}
    end

    test "creates basic reliable client without reliability features", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      assert is_pid(client_pid)
      assert Process.alive?(client_pid)

      # Cleanup
      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "creates reliable client with circuit breaker", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 circuit_breaker: [
                   failure_threshold: 3,
                   reset_timeout: 1000
                 ]
               )

      assert is_pid(client_pid)
      assert Process.alive?(client_pid)

      # Cleanup
      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "creates reliable client with health check", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 health_check: [
                   check_interval: 5000,
                   failure_threshold: 2
                 ]
               )

      assert is_pid(client_pid)
      assert Process.alive?(client_pid)

      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "creates reliable client with retry configuration", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 retry: [
                   max_attempts: 5,
                   backoff_factor: 1.5
                 ]
               )

      assert is_pid(client_pid)
      assert Process.alive?(client_pid)

      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "creates reliable client with all reliability features", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 circuit_breaker: [failure_threshold: 3],
                 retry: [max_attempts: 3],
                 health_check: [check_interval: 10_000]
               )

      assert is_pid(client_pid)
      assert Process.alive?(client_pid)

      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "handles transport start failure gracefully", %{
      supervisor: supervisor,
      mock_server: _mock_server
    } do
      # Use stdio transport with invalid path to simulate failure
      assert {:error, _reason} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :stdio, command: ["/nonexistent/command"]]
               )
    end

    test "generates unique client IDs for multiple clients", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, client1} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      assert {:ok, client2} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      assert client1 != client2

      if Process.alive?(client1), do: GenServer.stop(client1)
      if Process.alive?(client2), do: GenServer.stop(client2)
    end

    test "accepts custom client ID", %{supervisor: supervisor, mock_server: mock_server} do
      custom_id = "my_custom_client_123"

      assert {:ok, client_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 id: custom_id,
                 transport: [type: :mock, server_pid: mock_server]
               )

      assert is_pid(client_pid)

      if Process.alive?(client_pid), do: GenServer.stop(client_pid)
    end

    test "cleans up on wrapper start failure", %{supervisor: supervisor, mock_server: mock_server} do
      # Stop the supervisor to force wrapper creation failure
      GenServer.stop(supervisor)

      # This should fail because supervisor is down
      assert {:error, _reason} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )
    end
  end

  describe "ClientWrapper integration" do
    setup %{test: test} do
      supervisor_name = unique_process_name(test, "supervisor")
      mock_server_name = unique_process_name(test, "mock_server")

      {:ok, supervisor} = ReliabilitySupervisor.start_link(name: supervisor_name)
      {:ok, mock_server} = MockServer.start_link(name: mock_server_name)

      on_exit(fn ->
        TestHelpers.safe_stop_process(supervisor)
        TestHelpers.safe_stop_process(mock_server)
      end)

      %{supervisor: supervisor, mock_server: mock_server}
    end

    test "wrapped client forwards MCP operations", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      assert {:ok, wrapper_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      # Test that wrapper can receive and handle calls
      # Note: The actual MCP calls would be tested through the public API
      # but since we're testing the supervisor, we verify the wrapper exists
      assert is_pid(wrapper_pid)
      assert Process.alive?(wrapper_pid)

      if Process.alive?(wrapper_pid), do: GenServer.stop(wrapper_pid)
    end

    test "wrapper monitors underlying client", %{supervisor: supervisor, mock_server: mock_server} do
      assert {:ok, wrapper_pid} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      # Monitor the wrapper to see when it dies
      wrapper_ref = Process.monitor(wrapper_pid)

      # For this test, we'll just verify the wrapper was created successfully
      # The actual monitoring behavior would require more complex setup
      assert is_pid(wrapper_pid)
      Process.demonitor(wrapper_ref)

      if Process.alive?(wrapper_pid), do: GenServer.stop(wrapper_pid)
    end
  end

  describe "Arbor.MCP.Reliability.with_retry/2" do
    test "executes function without retry options" do
      result = Reliability.with_retry(fn -> {:ok, "success"} end)
      assert result == {:ok, "success"}
    end

    test "retries failing function" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        Reliability.with_retry(
          fn ->
            current = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
            if current < 3, do: {:error, :not_ready}, else: {:ok, "success"}
          end,
          max_attempts: 5,
          base_delay: 10
        )

      assert result == {:ok, "success"}
      assert Agent.get(agent, & &1) == 3

      Agent.stop(agent)
    end

    test "respects max attempts limit" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        Reliability.with_retry(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:error, :always_fails}
          end,
          max_attempts: 3,
          base_delay: 1
        )

      # The last underlying error is returned unchanged
      assert result == {:error, :always_fails}
      assert Agent.get(agent, & &1) == 3

      Agent.stop(agent)
    end

    test "handles transport exceptions during retry" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        Reliability.with_retry(
          fn ->
            current = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

            if current < 2 do
              raise Arbor.MCP.Error.TransportError, transport: :test, reason: :closed
            else
              {:ok, "recovered"}
            end
          end,
          max_attempts: 3,
          base_delay: 1
        )

      assert result == {:ok, "recovered"}

      Agent.stop(agent)
    end

    test "re-raises non-transport exceptions" do
      assert_raise RuntimeError, "test error", fn ->
        Reliability.with_retry(fn -> raise "test error" end, max_attempts: 3, base_delay: 1)
      end
    end
  end

  describe "Arbor.MCP.Reliability.protect/2" do
    test "creates circuit breaker protected function", %{test: test} do
      # Create a function that always succeeds
      breaker_name = unique_process_name(test, "breaker")

      protected_fn =
        Reliability.protect(fn -> {:ok, "success"} end,
          name: breaker_name
        )

      assert is_function(protected_fn)
      result = protected_fn.([])
      assert result == {:ok, "success"}
    end

    test "circuit breaker trips on repeated failures", %{test: test} do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      # Create a function that fails consistently
      breaker_name = unique_process_name(test, "breaker")

      protected_fn =
        Reliability.protect(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:error, :service_down}
          end,
          failure_threshold: 3,
          name: breaker_name
        )

      # First few calls should execute and fail
      assert protected_fn.([]) == {:error, :service_down}
      assert protected_fn.([]) == {:error, :service_down}
      assert protected_fn.([]) == {:error, :service_down}

      # Circuit should now be open - calls should fail fast
      result = protected_fn.([])
      assert {:error, :circuit_open} = result

      # Should not have incremented counter (circuit open, function not called)
      final_count = Agent.get(agent, & &1)
      # Only the first 3 calls that opened the circuit
      assert final_count == 3

      Agent.stop(agent)
    end

    test "reuses circuit breaker for same function", %{test: test} do
      breaker_name = unique_process_name(test, "breaker")

      protected_fn = Reliability.protect(fn -> {:ok, "test"} end, name: breaker_name)

      # First call creates the breaker
      assert protected_fn.([]) == {:ok, "test"}
      breaker_pid = Process.whereis(breaker_name)
      assert is_pid(breaker_pid)

      # Second call should reuse the same breaker
      assert protected_fn.([]) == {:ok, "test"}
      assert Process.whereis(breaker_name) == breaker_pid

      # Clean up
      if Process.alive?(breaker_pid), do: GenServer.stop(breaker_pid)
    end

    test "creates unique circuit breakers for different functions", %{test: test} do
      breaker1_name = unique_process_name(test, "breaker1")
      breaker2_name = unique_process_name(test, "breaker2")

      protected_fn1 =
        Reliability.protect(fn -> {:ok, "fn1"} end,
          name: breaker1_name
        )

      protected_fn2 =
        Reliability.protect(fn -> {:ok, "fn2"} end,
          name: breaker2_name
        )

      assert protected_fn1.([]) == {:ok, "fn1"}
      assert protected_fn2.([]) == {:ok, "fn2"}
    end

    test "handles function arguments correctly", %{test: test} do
      breaker_name = unique_process_name(test, "breaker")

      protected_fn =
        Reliability.protect(fn -> {:ok, 8} end,
          name: breaker_name
        )

      result = protected_fn.([5, 3])
      assert result == {:ok, 8}
    end

    test "respects circuit breaker configuration", %{test: test} do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      breaker_name = unique_process_name(test, "breaker")
      # Use a low failure threshold for testing
      protected_fn =
        Reliability.protect(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:error, :fail}
          end,
          failure_threshold: 1,
          name: breaker_name
        )

      # First call should fail and open circuit
      assert protected_fn.([]) == {:error, :fail}

      # Second call should be circuit open
      result = protected_fn.([])
      assert {:error, :circuit_open} = result

      # Should have only called function once
      assert Agent.get(agent, & &1) == 1

      Agent.stop(agent)
    end
  end

  describe "integration scenarios" do
    setup %{test: test} do
      supervisor_name = unique_process_name(test, "supervisor")
      mock_server_name = unique_process_name(test, "mock_server")

      {:ok, supervisor} = ReliabilitySupervisor.start_link(name: supervisor_name)
      {:ok, mock_server} = MockServer.start_link(name: mock_server_name)

      on_exit(fn ->
        TestHelpers.safe_stop_process(supervisor)
        TestHelpers.safe_stop_process(mock_server)
      end)

      %{supervisor: supervisor, mock_server: mock_server}
    end

    test "multiple reliable clients can coexist", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      # Create multiple clients with different configurations
      assert {:ok, client1} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 circuit_breaker: [failure_threshold: 5]
               )

      assert {:ok, client2} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 retry: [max_attempts: 3]
               )

      assert {:ok, client3} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 health_check: [check_interval: 30_000]
               )

      # All should be different processes
      assert client1 != client2
      assert client2 != client3
      assert client1 != client3

      # All should be alive
      assert Process.alive?(client1)
      assert Process.alive?(client2)
      assert Process.alive?(client3)

      # Clean up
      for client <- [client1, client2, client3] do
        if Process.alive?(client), do: GenServer.stop(client)
      end
    end

    test "supervisor recovery after child failure", %{
      supervisor: supervisor,
      mock_server: mock_server
    } do
      # Create initial client
      assert {:ok, client1} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      # Force stop the client (simulating crash)
      GenServer.stop(client1, :kill)

      # Give time for any cleanup
      Process.sleep(10)

      # Should be able to create new clients after failure
      assert {:ok, client2} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      assert Process.alive?(client2)
      assert client1 != client2

      if Process.alive?(client2), do: GenServer.stop(client2)
    end

    test "combining convenience functions with supervised clients", %{
      test: test,
      supervisor: supervisor,
      mock_server: mock_server
    } do
      # Create supervised client
      assert {:ok, client} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )

      # Use convenience retry function
      retry_result = Reliability.with_retry(fn -> {:ok, "retry_success"} end)
      assert retry_result == {:ok, "retry_success"}

      # Use convenience protect function
      breaker_name = unique_process_name(test, "breaker")

      protected_fn =
        Reliability.protect(fn -> {:ok, "protect_success"} end,
          name: breaker_name
        )

      protect_result = protected_fn.([])
      assert protect_result == {:ok, "protect_success"}

      # All should work independently
      assert Process.alive?(client)

      if Process.alive?(client), do: GenServer.stop(client)
    end
  end

  describe "error handling and edge cases" do
    setup do
      {:ok, mock_server} = MockServer.start_link([])
      Arbor.MCP.TestHelpers.stop_on_exit(mock_server)
      %{mock_server: mock_server}
    end

    test "handles invalid supervisor reference", %{mock_server: mock_server} do
      non_existent_supervisor = :non_existent_supervisor

      assert {:error, _reason} =
               ReliabilitySupervisor.create_reliable_client(
                 non_existent_supervisor,
                 transport: [type: :mock, server_pid: mock_server]
               )
    end

    test "handles empty and nil options gracefully", %{mock_server: mock_server} do
      {:ok, supervisor} = ReliabilitySupervisor.start_link()

      # Empty options - should fail because no transport provided
      assert {:error, _reason} = ReliabilitySupervisor.create_reliable_client(supervisor, [])

      # Nil values in options
      assert {:ok, client2} =
               ReliabilitySupervisor.create_reliable_client(
                 supervisor,
                 transport: [type: :mock, server_pid: mock_server],
                 circuit_breaker: nil,
                 retry: nil,
                 health_check: nil
               )

      assert is_pid(client2)

      # Clean up
      if Process.alive?(client2), do: GenServer.stop(client2)
      GenServer.stop(supervisor)
    end

    test "protect function handles exceptions in protected function", %{test: test} do
      breaker_name = unique_process_name(test, "breaker")

      protected_fn =
        Reliability.protect(
          fn ->
            raise RuntimeError, "test exception"
          end,
          name: breaker_name
        )

      # Should catch exception and return error
      result = protected_fn.([])
      assert {:error, %RuntimeError{}} = result
    end

    test "with_retry preserves error shapes" do
      # The last underlying error is returned unchanged
      assert {:error, :simple} =
               Reliability.with_retry(fn -> {:error, :simple} end, max_attempts: 1)

      assert {:error, "string"} =
               Reliability.with_retry(fn -> {:error, "string"} end, max_attempts: 1)

      # Non-transport exceptions are re-raised, not converted to errors
      assert_raise RuntimeError, "test", fn ->
        Reliability.with_retry(fn -> raise "test" end, max_attempts: 1)
      end
    end
  end
end
