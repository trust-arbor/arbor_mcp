defmodule Arbor.MCP.Server.RuntimeNativeStartupExitTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization}

  defmodule HeldSupervisor do
    use Supervisor

    @impl true
    def init(owner) do
      send(owner, {:native_initializing, self(), Process.get(:"$ancestors")})
      receive do: (:release -> Supervisor.init([], strategy: :one_for_one))
    end
  end

  test "an owned cutoff kill while the initiating caller is suspended returns an explicit timeout" do
    {caller, monitor, deadline} = start_caller(false)
    assert_receive {:native_initializing, root, [^caller | _]}, 1_000
    assert :proc_lib.translate_initial_call(root) == {:supervisor, HeldSupervisor, 1}
    root_monitor = Process.monitor(root)
    :erlang.suspend_process(caller)
    on_exit(fn -> resume(caller) end)
    sleep_until(deadline + 10)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}, 1_000
    assert Process.alive?(caller)
    :erlang.resume_process(caller)
    assert_receive {:native_result, ^caller, {:error, :runtime_init_timeout}, false, []}, 1_000
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
  end

  test "normal success restores nontrapping mode and preserves the actual parent link" do
    {caller, monitor, _deadline} = start_caller(false)
    assert_receive {:native_initializing, root, [^caller | _]}, 1_000
    send(root, :release)
    assert_receive {:native_result, ^caller, {:ok, ^root}, false, []}, 1_000
    assert {:links, links} = Process.info(root, :links)
    assert caller in links
    root_monitor = Process.monitor(root)
    Process.exit(caller, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :shutdown}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :shutdown}, 1_000
  end

  test "foreign abnormal link failure retains the original nontrapping caller semantics" do
    {caller, monitor, _deadline} = start_caller(false, foreign: true)
    assert_receive {:native_foreign, ^caller, foreign}, 1_000
    assert_receive {:native_initializing, root, [^caller | _]}, 1_000
    root_monitor = Process.monitor(root)
    Process.exit(foreign, :foreign_failure)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :foreign_failure}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, 1_000
    refute_receive {:native_result, ^caller, _result, _flag, _messages}, 20
  end

  test "foreign normal exit is ignored for an originally nontrapping caller" do
    {caller, monitor, _deadline} = start_caller(false, foreign: true)
    assert_receive {:native_foreign, ^caller, foreign}, 1_000
    assert_receive {:native_initializing, root, [^caller | _]}, 1_000
    foreign_monitor = Process.monitor(foreign)
    send(foreign, :finish)
    assert_receive {:DOWN, ^foreign_monitor, :process, ^foreign, :normal}, 1_000
    assert_receive {:native_result, ^caller, {:error, :runtime_init_timeout}, false, []}, 1_000
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    refute Process.alive?(root)
  end

  test "an originally trapping caller retains its foreign EXIT message and flag" do
    {caller, monitor, _deadline} = start_caller(true, foreign: true)
    assert_receive {:native_foreign, ^caller, foreign}, 1_000
    assert_receive {:native_initializing, root, [^caller | _]}, 1_000
    Process.exit(foreign, :foreign_failure)

    assert_receive {:native_result, ^caller, {:error, :runtime_init_timeout}, true,
                    [{:EXIT, ^foreign, :foreign_failure}]},
                   1_000

    refute Process.alive?(root)
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
  end

  defp start_caller(trap_exit, opts \\ []) do
    owner = self()
    deadline = Deadline.now() + 200

    {caller, monitor} =
      spawn_monitor(fn ->
        if trap_exit, do: Process.flag(:trap_exit, true)

        if opts[:foreign] do
          foreign = spawn_link(fn -> receive do: (:finish -> :ok) end)
          send(owner, {:native_foreign, self(), foreign})
        end

        result =
          try do
            Initialization.start_supervisor(HeldSupervisor, owner, deadline)
          catch
            :exit, reason -> {:caught_exit, reason}
          end

        {:trap_exit, restored} = Process.info(self(), :trap_exit)
        {:messages, messages} = Process.info(self(), :messages)
        send(owner, {:native_result, self(), result, restored, messages})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    {caller, monitor, deadline}
  end

  defp sleep_until(deadline), do: Process.sleep(max(0, deadline - Deadline.now()))

  defp resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  catch
    :error, _reason -> :ok
  end
end
