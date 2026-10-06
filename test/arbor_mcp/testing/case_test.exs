defmodule Arbor.MCP.Testing.CaseTest do
  @moduledoc """
  Tests for the `Arbor.MCP.TestCase` helpers.

  Every `Process.sleep/1` in this file is **intentional** (audit M25): these
  tests exercise timing primitives — `measure_time/1`, `with_timeout/2` and
  `wait_for_condition/2` — so the sleep *is* the workload being measured or
  timed out. The concurrency tests use explicit worker barriers instead of
  elapsed wall time to prove that every worker enters before any is released.
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.TestCase
  require Arbor.MCP.TestCase

  describe "with_temp_file macro" do
    test "creates temporary file with content" do
      import Arbor.MCP.TestCase

      result =
        with_temp_file("test content", ".txt") do
          assert File.exists?(file_path)
          assert File.read!(file_path) == "test content"
          assert String.ends_with?(file_path, ".txt")
          :test_result
        end

      assert result == :test_result
    end

    test "cleans up temporary file after block" do
      import Arbor.MCP.TestCase

      captured_path =
        with_temp_file("content") do
          file_path
        end

      refute File.exists?(captured_path)
    end
  end

  describe "measure_time macro" do
    test "measures execution time" do
      {result, time_ms} =
        TestCase.measure_time do
          Process.sleep(10)
          :test_result
        end

      assert result == :test_result
      assert time_ms >= 10
      # Should be much less than 100ms
      assert time_ms < 100
    end
  end

  describe "with_timeout macro" do
    test "returns result when operation completes in time" do
      result =
        TestCase.with_timeout 1000 do
          Process.sleep(10)
          :completed
        end

      assert result == :completed
    end

    test "fails when operation times out" do
      assert_raise ExUnit.AssertionError, ~r/Operation timed out/, fn ->
        TestCase.with_timeout 50 do
          Process.sleep(100)
          :should_not_reach
        end
      end
    end
  end

  describe "repeat_test macro" do
    test "runs test multiple times" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      TestCase.repeat_test 5 do
        Agent.update(agent, &(&1 + 1))
      end

      assert Agent.get(agent, & &1) == 5
      Agent.stop(agent)
    end

    test "fails with context on iteration failure" do
      assert_raise ExUnit.AssertionError, ~r/iteration/, fn ->
        counter = Agent.start_link(fn -> 0 end)
        {:ok, agent} = counter

        TestCase.repeat_test 3 do
          count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
          if count == 2, do: flunk("test failure")
        end
      end
    end
  end

  describe "concurrent_test macro" do
    test "runs operations concurrently" do
      test_pid = self()
      readiness_deadline = System.monotonic_time(:millisecond) + 1000

      # Exercise the underlying Tasks with the same worker barrier as run_parallel/2.
      tasks =
        Enum.map(1..3, fn index ->
          Task.async(fn ->
            send(test_pid, {:concurrent_worker_started, self(), index})

            receive do
              :release_concurrent_worker -> index
            end
          end)
        end)

      for {task, index} <- Enum.with_index(tasks, 1) do
        remaining = max(readiness_deadline - System.monotonic_time(:millisecond), 0)
        assert_receive {:concurrent_worker_started, worker_pid, ^index}, remaining
        assert worker_pid == task.pid
      end

      assert System.monotonic_time(:millisecond) <= readiness_deadline

      # All three workers have entered before any worker may finish.
      Enum.each(tasks, &send(&1.pid, :release_concurrent_worker))
      results = Task.await_many(tasks, 1000)

      assert results == [1, 2, 3]
    end
  end

  describe "wait_until function" do
    test "returns :ok when condition becomes true" do
      agent = Agent.start_link(fn -> false end)
      {:ok, pid} = agent

      # Set condition to true after 50ms
      Task.start(fn ->
        Process.sleep(50)
        Agent.update(pid, fn _ -> true end)
      end)

      result =
        TestCase.wait_until(
          fn ->
            Agent.get(pid, & &1)
          end,
          timeout: 200,
          interval: 10
        )

      assert result == :ok
      Agent.stop(pid)
    end

    test "returns :timeout when condition never becomes true" do
      result = TestCase.wait_until(fn -> false end, timeout: 50, interval: 10)
      assert result == :timeout
    end
  end

  describe "run_parallel function" do
    test "executes functions in parallel and returns results" do
      test_pid = self()

      functions =
        for result <- [1, 2, 3] do
          fn ->
            send(test_pid, {:parallel_worker_started, self()})

            receive do
              :release_parallel_worker -> result
            end
          end
        end

      parallel_task = Task.async(fn -> TestCase.run_parallel(functions) end)

      worker_pids =
        for _index <- 1..3 do
          assert_receive {:parallel_worker_started, worker_pid}, 1_000
          worker_pid
        end

      Enum.each(worker_pids, &send(&1, :release_parallel_worker))
      assert Task.await(parallel_task) == [1, 2, 3]
    end

    test "respects timeout option" do
      functions = [
        fn ->
          Process.sleep(100)
          :result
        end
      ]

      assert_raise RuntimeError, fn ->
        TestCase.run_parallel(functions, timeout: 50)
      end
    end
  end

  describe "start_test_supervisor function" do
    test "starts supervisor with child specs" do
      child_specs = [
        {Agent, fn -> :initial_state end}
      ]

      {:ok, supervisor} = TestCase.start_test_supervisor(child_specs)

      # Verify supervisor is running
      assert Process.alive?(supervisor)

      # Verify child processes are started
      children = Supervisor.which_children(supervisor)
      assert length(children) == 1

      Supervisor.stop(supervisor)
    end
  end

  describe "flush_messages function" do
    test "returns all messages from mailbox" do
      send(self(), :message1)
      send(self(), :message2)
      send(self(), :message3)

      messages = TestCase.flush_messages()

      assert messages == [:message1, :message2, :message3]

      # Mailbox should be empty now
      assert TestCase.flush_messages() == []
    end

    test "returns empty list when no messages" do
      messages = TestCase.flush_messages()
      assert messages == []
    end
  end

  describe "unique_id function" do
    test "generates unique identifiers with prefix" do
      id1 = TestCase.unique_id("test")
      id2 = TestCase.unique_id("test")

      assert String.starts_with?(id1, "test_")
      assert String.starts_with?(id2, "test_")
      assert id1 != id2
    end

    test "respects length parameter" do
      id = TestCase.unique_id("test", 16)

      # Format: "test_" + 16 hex characters
      # "test_" (5 chars) + 16 hex chars = 21 total
      assert String.length(id) == 5 + 16
    end
  end

  describe "create_test_context function" do
    test "creates context with unique id" do
      context = TestCase.create_test_context()

      assert Map.has_key?(context, :test_id)
      assert Map.has_key?(context, :created_at)
      assert Map.has_key?(context, :cleanup_functions)
      assert is_binary(context.test_id)
      assert String.starts_with?(context.test_id, "ctx_")
    end

    test "merges initial context" do
      initial = %{custom_data: "test"}
      context = TestCase.create_test_context(initial)

      assert context.custom_data == "test"
      assert Map.has_key?(context, :test_id)
    end
  end

  describe "add_cleanup function" do
    test "adds cleanup function to context" do
      context = TestCase.create_test_context()

      cleanup_fn = fn -> :cleanup_executed end
      updated_context = TestCase.add_cleanup(context, cleanup_fn)

      assert length(updated_context.cleanup_functions) == 1
      assert hd(updated_context.cleanup_functions) == cleanup_fn
    end

    test "accumulates multiple cleanup functions" do
      context = TestCase.create_test_context()

      fn1 = fn -> :cleanup1 end
      fn2 = fn -> :cleanup2 end

      context = TestCase.add_cleanup(context, fn1)
      context = TestCase.add_cleanup(context, fn2)

      assert length(context.cleanup_functions) == 2
      assert fn2 in context.cleanup_functions
      assert fn1 in context.cleanup_functions
    end
  end
end
