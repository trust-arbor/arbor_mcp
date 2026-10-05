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
end
