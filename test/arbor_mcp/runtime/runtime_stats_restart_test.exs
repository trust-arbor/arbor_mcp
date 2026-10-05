defmodule Arbor.MCP.Server.RuntimeStatsRestartTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, Ref}

  defmodule Handler do
    def init(_args), do: {:ok, 0}

    def dispatch(request, _module, state, _opts) do
      next = state + 1
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => next}, next}
    end
  end

  test "a queued actual Scheduler stats reply survives Admission replacement as a typed error" do
    {root, runtime} = start_runtime()
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    [{:admission, admission}] = :ets.lookup(table, :admission)
    scheduler = route.scheduler
    test_pid = self()
    invocation = make_ref()

    :erlang.suspend_process(scheduler)

    caller =
      spawn(fn ->
        result =
          try do
            Runtime.stats(runtime)
          rescue
            error in BadMapError -> {:raised, BadMapError, error.term}
          end

        send(test_pid, {invocation, result})
      end)

    on_exit(fn ->
      safe_resume(root)
      safe_resume(scheduler)
      safe_resume(caller)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end)

    wait_for(fn ->
      case Process.info(scheduler, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", {^caller, _tag}, :stats} -> true
            _other -> false
          end)

        _dead ->
          false
      end
    end)

    :erlang.suspend_process(caller)
    :erlang.resume_process(scheduler)

    queued_reply =
      wait_for(fn ->
        case Process.info(caller, :messages) do
          {:messages, messages} ->
            Enum.find(messages, fn
              {_tag, %{active: 0, queued: 0, generation: generation}} ->
                generation == route.generation

              _other ->
                false
            end)

          _dead ->
            nil
        end
      end)

    assert {_actual_reply_tag, %{active: 0, queued: 0, generation: generation}} = queued_reply
    assert generation == route.generation

    # The real root is paused only after the actual Scheduler reply is queued.
    # This holds the native rest-for-one replacement behind the stats consumer.
    :erlang.suspend_process(root)
    monitor = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}, 1_000
    assert {:error, :runtime_unavailable} = Admission.stats(table)
    :erlang.resume_process(caller)
    assert_receive {^invocation, result}, 1_000
    assert result == {:error, :runtime_unavailable}

    :erlang.resume_process(root)

    wait_for(fn ->
      case {:ets.lookup(table, :admission), Admission.route(table)} do
        {[{:admission, replacement}], {:ok, _route}} ->
          replacement != admission and Process.alive?(replacement)

        _pending ->
          false
      end
    end)

    assert Process.alive?(root)
    assert {:ok, ^runtime} = Runtime.ref(root)

    assert %{active: 0, queued: 0, reserved: 0, generation: recovered_generation} =
             Runtime.stats(runtime)

    refute recovered_generation == route.generation

    assert {:ok, %{"result" => 1}} =
             Runtime.request(runtime, %{"jsonrpc" => "2.0", "id" => 7, "method" => "increment"})
  end

  test "live statistics retain both Scheduler and Admission fields" do
    {_root, runtime} = start_runtime()

    assert %{active: 0, queued: 0, reserved: 0, pending_bytes: 0, generation: generation} =
             Runtime.stats(runtime)

    assert is_reference(generation)
  end

  test "invalid and stopped runtime references retain the unavailable result" do
    assert {:error, :runtime_unavailable} = Runtime.stats(:no_such_stats_runtime)
    {root, runtime} = start_runtime()
    assert :ok = Supervisor.stop(root, :normal, 1_000)
    assert {:error, :runtime_unavailable} = Runtime.stats(runtime)
  end

  defp start_runtime do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        dispatcher: Handler,
        init_timeout_ms: 1_000,
        shutdown_timeout_ms: 500
      )

    Process.unlink(root)
    {:ok, runtime} = Runtime.ref(root)

    on_exit(fn ->
      safe_resume(root)

      if Process.alive?(root) do
        try do
          Supervisor.stop(root, :normal, 1_000)
        catch
          :exit, _reason -> Process.exit(root, :kill)
        end
      end
    end)

    {root, runtime}
  end

  defp wait_for(function, attempts \\ 1_000)
  defp wait_for(_function, 0), do: flunk("actual process transition did not occur")

  defp wait_for(function, attempts) do
    case function.() do
      result when result not in [nil, false] ->
        result

      _pending ->
        Process.sleep(1)
        wait_for(function, attempts - 1)
    end
  end

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end
end
