defmodule Arbor.MCP.Reliability.HealthCheckTest.MockTarget do
  @moduledoc false
  use GenServer

  def init(state) do
    {:ok, state}
  end

  def handle_call(:ping, _from, state) do
    reply =
      case state do
        :healthy -> :pong
        # Will customize check function instead
        :failing -> :pong
        _ -> :pong
      end

    {:reply, reply, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:update, fun}, _from, state) do
    new_state = fun.(state)
    {:reply, :ok, new_state}
  end

  # For toggle functionality
  def handle_cast({:set_state, new_state}, _state) do
    {:noreply, new_state}
  end

  # For Agent.update compatibility in toggle tests
  def handle_cast({:update, fun}, state) do
    {:noreply, fun.(state)}
  end
end

defmodule Arbor.MCP.Reliability.HealthCheckTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.HealthCheck

  setup do
    checker_name = :"test_checker_#{System.unique_integer([:positive])}"
    {:ok, checker_name: checker_name}
  end

  describe "health monitoring" do
    test "starts with unknown status", context do
      {:ok, target} = Agent.start_link(fn -> :ok end)

      # Provide a custom check function that works with Agent
      check_fn = fn agent ->
        try do
          Agent.get(agent, & &1)
          {:ok, %{status: :ok}}
        catch
          _, _ -> {:error, :check_failed}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 60_000
        )

      {status, _info} = HealthCheck.get_status(checker)
      assert status == :unknown
    end

    test "becomes healthy after successful checks", context do
      {:ok, target} = start_healthy_target()

      check_fn = fn target ->
        case GenServer.call(target, :ping) do
          :pong -> {:ok, %{status: :healthy}}
          _ -> {:error, :unhealthy}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          recovery_threshold: 2
        )

      # Trigger immediate checks
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, info} = HealthCheck.get_status(checker)
      assert status == :healthy
      assert info.consecutive_successes >= 2
    end

    test "becomes unhealthy after failed checks", context do
      {:ok, target} = start_failing_target()

      # Custom check function that actually fails for failing target
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 2
        )

      # Trigger immediate checks
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, info} = HealthCheck.get_status(checker)
      assert status == :unhealthy
      assert info.consecutive_failures >= 2
    end

    test "recovers from unhealthy to healthy", context do
      {:ok, target} = start_toggle_target()

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 2,
          recovery_threshold: 2
        )

      # Make it unhealthy
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, _} = HealthCheck.get_status(checker)
      assert status == :unhealthy

      # Toggle to healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})

      # Make it healthy again
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, _} = HealthCheck.get_status(checker)
      assert status == :healthy
    end
  end

  describe "custom check functions" do
    test "uses custom check function", context do
      {:ok, target} = Agent.start_link(fn -> 42 end)

      check_fn = fn target ->
        value = Agent.get(target, & &1)

        if value > 40 do
          {:ok, %{value: value}}
        else
          {:error, :value_too_low}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000
        )

      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
      assert result.details.value == 42
    end
  end

  describe "subscriptions" do
    test "notifies subscribers of status changes", context do
      {:ok, target} = start_toggle_target()

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 1,
          recovery_threshold: 1
        )

      # Subscribe to changes
      HealthCheck.subscribe(checker)

      # Make it healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})
      HealthCheck.check_now(checker)

      assert_receive {:health_status_changed, :unknown, :healthy, metadata}
      assert metadata.checker == context.checker_name

      # Make it unhealthy
      GenServer.call(target, {:update, fn _ -> :failing end})
      HealthCheck.check_now(checker)

      assert_receive {:health_status_changed, :healthy, :unhealthy, _metadata}
    end

    test "handles subscriber crashes", context do
      {:ok, target} = start_healthy_target()

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_interval: 10_000
        )

      # Start a subscriber that will crash
      spawn(fn ->
        HealthCheck.subscribe(checker)
        Process.sleep(10)
        exit(:boom)
      end)

      Process.sleep(50)

      # Should still work
      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
    end
  end

  describe "pause and resume" do
    test "pauses health checks", context do
      {:ok, target} = start_healthy_target()
      check_count = start_counter()

      check_fn = fn target ->
        increment_counter(check_count)

        case GenServer.call(target, :ping) do
          :pong -> {:ok, %{}}
          _ -> {:error, :ping_failed}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 50
        )

      # Trigger some immediate checks first
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      # Let it run a bit and make sure we get some checks
      Process.sleep(150)
      initial_count = get_counter(check_count)
      assert initial_count >= 2

      # Pause
      HealthCheck.pause(checker)
      Process.sleep(120)

      # Count shouldn't increase
      assert get_counter(check_count) == initial_count

      # Resume
      HealthCheck.resume(checker)
      # Trigger immediate check after resume
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)
      Process.sleep(150)

      # Should be checking again
      final_count = get_counter(check_count)

      assert final_count > initial_count,
             "Expected count to increase from #{initial_count} but got #{final_count}"
    end
  end

  describe "history tracking" do
    test "maintains check history", context do
      {:ok, target} = start_healthy_target()

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_interval: 10_000
        )

      # Perform multiple checks
      for _ <- 1..5 do
        HealthCheck.check_now(checker)
      end

      history = HealthCheck.get_history(checker, 3)
      assert length(history) == 3
      assert Enum.all?(history, &(&1.status == :healthy))
    end
  end

  describe "status change callbacks" do
    test "calls on_status_change callback", context do
      {:ok, target} = start_toggle_target()
      {:ok, callback_agent} = Agent.start_link(fn -> [] end)

      on_status_change = fn old_status, new_status ->
        # Update synchronously within the callback
        Agent.update(callback_agent, &[{old_status, new_status} | &1])
      end

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 1,
          # Only need 1 success to become healthy
          recovery_threshold: 1,
          on_status_change: on_status_change
        )

      # Make it healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})
      HealthCheck.check_now(checker)

      # Let callback execute (ensure enough time for async Task)
      Process.sleep(500)

      changes = Agent.get(callback_agent, &Enum.reverse/1)
      assert length(changes) > 0, "No status changes were recorded"
      # Should see transition from unknown to healthy
      assert {:unknown, :healthy} in changes
    end
  end

  describe "MCP-specific health checks" do
    test "MCP client check function", context do
      # Mock MCP client
      {:ok, mock_client} =
        Agent.start_link(fn ->
          %{"tools" => [%{"name" => "tool1"}, %{"name" => "tool2"}]}
        end)

      # Mock client check function for testing
      check_fn = fn client ->
        result = Agent.get(client, & &1)
        tool_count = length(Map.get(result, "tools", []))
        {:ok, %{method: :list_tools, tool_count: tool_count}}
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: mock_client,
          check_fn: check_fn,
          check_interval: 10_000
        )

      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
      assert result.details.tool_count == 2
    end
  end

  # Helper functions
  defp start_healthy_target do
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :healthy)
    {:ok, pid}
  end

  defp start_failing_target do
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :failing)
    {:ok, pid}
  end

  defp start_toggle_target do
    # Starts failing, can be toggled
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :failing)
    {:ok, pid}
  end

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
end
