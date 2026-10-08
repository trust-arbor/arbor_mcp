defmodule Arbor.MCP.Server.HTTPOwnedAcceptorDeadlineTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.HTTP.Cowboy.Owned
  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, Ref}
  alias Arbor.MCP.Server.{Runtime, Transport}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
  end

  test "a ready native acceptor parent rejects a queued startup ACK after its original cutoff" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         transport: :http,
         init_timeout_ms: 1_000,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    {:ok, initial} = Initialization.current(table)
    {:ok, %{listener: listener}} = Transport.http_listener(runtime)
    acceptors = child(listener, :ranch_acceptors_sup)
    [{_id, previous, :worker, _modules} | _] = Supervisor.which_children(acceptors)
    [{:shutdown_guard, guard}] = :ets.lookup(table, :shutdown_guard)
    Process.sleep(max(0, initial.deadline - Deadline.now() + 1))
    assert Initialization.ready?(table)

    :ok = :sys.suspend(guard)
    :erlang.trace_pattern({Owned, :init_acceptor, 1}, true, [:local])
    :erlang.trace(acceptors, true, [:call, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({Owned, :init_acceptor, 1}, false, [:local])
      resume(acceptors)
      if Process.alive?(guard), do: :sys.resume(guard)
    end)

    Process.exit(previous, :kill)

    assert_receive {:trace, replacement, :call, {Owned, :init_acceptor, [constructor]}},
                   1_000

    {^acceptors, ^table, context, original_cutoff, _arguments} = constructor.()
    assert context.epoch == initial.epoch
    assert original_cutoff > initial.deadline
    monitor = Process.monitor(replacement)

    await(
      fn ->
        {:messages, messages} = Process.info(guard, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:watch, ^replacement}}, &1))
      end,
      original_cutoff
    )

    assert :erlang.suspend_process(acceptors)
    :ok = :sys.resume(guard)

    await(
      fn ->
        {:messages, messages} = Process.info(acceptors, :messages)
        {:ack, replacement, {:ok, replacement}} in messages
      end,
      original_cutoff
    )

    assert :ets.member(table, {:runtime_owned, replacement})
    assert Process.alive?(replacement)
    Process.sleep(max(0, original_cutoff - Deadline.now() + 1))
    assert :erlang.resume_process(acceptors)
    assert_receive {:DOWN, ^monitor, :process, ^replacement, :killed}, 1_000
    refute Process.alive?(replacement)
  end

  defp child(parent, id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(parent), id, 0)
    pid
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end

  defp await(fun, deadline) do
    if fun.() do
      :ok
    else
      assert Deadline.now() < deadline
      Process.sleep(1)
      await(fun, deadline)
    end
  end
end
