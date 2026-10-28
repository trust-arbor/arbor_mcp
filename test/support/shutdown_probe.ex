defmodule Arbor.MCP.Test.ShutdownProbe do
  @moduledoc false
  # Stops a runtime whose cleanup can only finish by force and checks the
  # shutdown contract against instants taken from one monotonic clock, the
  # VM's trace timestamps:
  #
  #   * the cutoff is charged when stop is called: `cutoff - budget` is within
  #     @charge_epsilon_ms of the instant `Runtime.stop/1` was entered;
  #   * `:ok` only once the observer's write of its confirmation (phase 3 in
  #     the control cells) had completed before stop returned;
  #   * an unconfirmed result only at or after the charged cutoff;
  #   * either result no later than `margin` past the cutoff;
  #   * the observer exits normally with the cleanup confirmed.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.ShutdownControl

  @charge_epsilon_ms 25
  @confirm {:atomics, :put, 3}
  @stop {Runtime, :stop, 1}

  def stop_forced(server, control, budget, margin) do
    observer = ShutdownControl.observer(control)
    observer_monitor = Process.monitor(observer)
    tracer = spawn(fn -> collect([]) end)
    test = self()

    on_exit(fn ->
      :erlang.trace_pattern(@confirm, false, [:global])
      :erlang.trace_pattern(@stop, false, [:global])
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
    end)

    # The observer writes phase 3 last, once every owned DOWN is in. The
    # return trace marks the instant that write has completed.
    assert 1 ==
             :erlang.trace_pattern(@confirm, [{[:_, 2, 3], [], [{:return_trace}]}], [:global])

    assert 1 == :erlang.trace_pattern(@stop, [{:_, [], [{:return_trace}]}], [:global])
    flags = [:call, :monotonic_timestamp, {:tracer, tracer}]
    assert 1 == :erlang.trace(observer, true, flags)
    assert 1 == :erlang.trace(test, true, flags)

    result = Runtime.stop(server)
    :erlang.trace(test, false, [:call])
    cutoff = :atomics.get(control.cells, 1)
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :normal}, 2_000
    assert :atomics.get(control.cells, 2) == 3

    %{entered: entered, returned_at: returned_at, confirmed_at: confirmed_at} =
      traces(tracer, test, observer)

    entered_ms = System.convert_time_unit(entered, :native, :millisecond)
    returned_ms = System.convert_time_unit(returned_at, :native, :millisecond)
    assert (cutoff - budget - entered_ms) in 0..@charge_epsilon_ms
    assert returned_ms <= cutoff + margin

    case result do
      :ok ->
        assert confirmed_at < returned_at,
               "stop returned :ok before the observer confirmed cleanup"

      {:error, :shutdown_cleanup_unconfirmed} ->
        assert returned_ms >= cutoff
    end

    result
  end

  defp traces(tracer, test, observer) do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 2_000
    send(tracer, {:dump, self()})
    assert_receive {:traces, traces}, 2_000

    entered =
      Enum.find_value(traces, fn
        {:trace_ts, ^test, :call, {Runtime, :stop, _args}, ts} -> ts
        _other -> nil
      end)

    returned_at =
      Enum.find_value(traces, fn
        {:trace_ts, ^test, :return_from, {Runtime, :stop, 1}, _result, ts} -> ts
        _other -> nil
      end)

    confirmed_at =
      Enum.find_value(traces, fn
        {:trace_ts, ^observer, :return_from, {:atomics, :put, 3}, :ok, ts} -> ts
        _other -> nil
      end)

    assert entered && returned_at && confirmed_at, "missing traces: #{inspect(traces)}"
    %{entered: entered, returned_at: returned_at, confirmed_at: confirmed_at}
  end

  defp collect(traces) do
    receive do
      {:dump, caller} -> send(caller, {:traces, Enum.reverse(traces)})
      trace -> collect([trace | traces])
    end
  end
end
