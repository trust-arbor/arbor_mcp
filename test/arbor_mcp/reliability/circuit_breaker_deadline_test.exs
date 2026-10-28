defmodule Arbor.MCP.Reliability.CircuitBreakerDeadlineTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.CircuitBreaker

  for outcome <- [{:ok, :late_success}, {:error, :late_error}] do
    @outcome outcome
    test "rejects queued #{inspect(outcome)} after the execution cutoff" do
      breaker = start_supervised!({CircuitBreaker, timeout: 150})
      test_pid = self()
      outcome = @outcome

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          result =
            CircuitBreaker.call(breaker, fn ->
              send(test_pid, {:protected_worker, self()})

              receive do
                :finish -> outcome
              end
            end)

          send(test_pid, {:call_result, self(), result})
        end)

      assert_receive {:protected_worker, worker}, 1000
      worker_monitor = Process.monitor(worker)

      try do
        true = :erlang.suspend_process(caller)
        Process.sleep(180)
        send(worker, :finish)
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1000
        {:messages, messages} = Process.info(caller, :messages)

        assert Enum.any?(messages, fn
                 {:circuit_breaker_result, ^worker, {:ok, ^outcome}} -> true
                 _ -> false
               end)

        true = :erlang.resume_process(caller)
        assert_receive {:call_result, ^caller, {:error, :timeout}}, 1000
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1000
        assert CircuitBreaker.get_stats(breaker).failure_count == 1
      after
        for pid <- [caller, worker] do
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end
      end
    end
  end

  test "accepts a result within the execution budget" do
    breaker = start_supervised!({CircuitBreaker, timeout: 1000})
    assert CircuitBreaker.call(breaker, fn -> {:ok, :success} end) == {:ok, :success}
    assert CircuitBreaker.get_stats(breaker).failure_count == 0
  end

  test "times out and observes the blocked worker's actual death" do
    breaker = start_supervised!({CircuitBreaker, timeout: 50})
    test_pid = self()

    assert CircuitBreaker.call(breaker, fn ->
             send(test_pid, {:blocked_worker, self()})

             receive do
               :finish -> :unexpected
             end
           end) == {:error, :timeout}

    assert_receive {:blocked_worker, worker}
    refute Process.alive?(worker)
    refute_receive {:circuit_breaker_result, ^worker, _}, 0
  end

  describe "call_with_deadline/3" do
    # The work outlasts the breaker's configured :timeout: call/3 cuts it
    # short there, while an operation with its own, longer deadline runs on.
    test "lets the caller's deadline, not the breaker's :timeout, bound the work" do
      breaker = start_supervised!({CircuitBreaker, timeout: 100})
      test_pid = self()

      work = fn ->
        send(test_pid, {:working, self()})

        receive do
          :finish -> {:ok, :done}
        end
      end

      for {call, expected} <- [
            {&CircuitBreaker.call(breaker, &1, 5_000), {:error, :timeout}},
            {&CircuitBreaker.call_with_deadline(breaker, &1, 5_000), {:ok, :done}}
          ] do
        caller = Task.async(fn -> call.(work) end)
        assert_receive {:working, worker}
        # Past the breaker's 100 ms, then the work finishes.
        Process.sleep(200)
        send(worker, :finish)
        assert Task.await(caller) == expected
      end

      assert CircuitBreaker.get_stats(breaker).failure_count == 1
    end

    test "still ends work that outlasts the caller's deadline" do
      breaker = start_supervised!({CircuitBreaker, timeout: :infinity})

      assert CircuitBreaker.call_with_deadline(
               breaker,
               fn ->
                 receive do
                   :never -> :ok
                 end
               end,
               100
             ) == {:error, :timeout}
    end
  end
end
