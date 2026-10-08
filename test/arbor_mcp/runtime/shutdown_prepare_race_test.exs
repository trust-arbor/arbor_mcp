defmodule Arbor.MCP.Server.Runtime.ShutdownPrepareRaceTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Deadline, Ref, ShutdownControl}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    @impl true
    def init(_opts), do: {:ok, nil}
  end

  test "a captured native completion survives retired ETS and cannot renew its first cutoff" do
    id = make_ref()
    {:ok, parent} = ExUnit.fetch_test_supervisor()

    root =
      start_supervised!(
        Supervisor.child_spec({Runtime, handler: Handler, shutdown_timeout_ms: 1_000},
          id: id,
          restart: :permanent
        )
      )

    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    {:ok, control} = ShutdownControl.lookup(table)
    test_pid = self()
    heir_token = make_ref()

    :sys.replace_state(root, fn state ->
      true = :ets.setopts(table, {:heir, test_pid, heir_token})
      state
    end)

    started = Deadline.now()
    assert {:ok, ^control, deadline} = ShutdownControl.prepare(table, :normal, started)
    assert :ok = ShutdownControl.await(control, deadline, false)
    refute Process.alive?(ShutdownControl.observer(control))
    refute Process.alive?(root)
    assert_receive {:"ETS-TRANSFER", ^table, ^root, ^heir_token}, 1_000
    assert :ets.info(table, :owner) == self()

    # The native owner transferred the real table without altering its control
    # or completion cells. Its observer-owned ledger is actually gone, so this
    # exercises public preparation against a retired authentic authority.
    assert {:ok, ^control, ^deadline} =
             ShutdownControl.prepare(table, :normal, started)

    assert :ok = ShutdownControl.await(control, deadline, false)

    assert {:ok, ^control, ^deadline} =
             ShutdownControl.prepare(table, :normal, Deadline.now() + 10_000)

    replacement = replacement(parent, id, root)
    assert Process.alive?(replacement)
    assert {:ok, replacement_ref} = Runtime.ref(replacement)
    refute replacement_ref == runtime
    assert Ref.table(replacement_ref) != table
  end

  test "an actual observer death without completion never becomes a cleanup receipt" do
    root =
      start_supervised!(
        Supervisor.child_spec({Runtime, handler: Handler}, id: make_ref(), restart: :temporary)
      )

    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    {:ok, control} = ShutdownControl.lookup(table)
    observer = ShutdownControl.observer(control)
    monitor = Process.monitor(observer)
    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :killed}, 1_000

    assert {:error, :shutdown_control_unavailable} =
             ShutdownControl.prepare(table, :normal, Deadline.now())
  end

  defp replacement(parent, id, original, attempts \\ 200)
  defp replacement(_parent, _id, _original, 0), do: flunk("runtime replacement was not ready")

  defp replacement(parent, id, original, attempts) do
    case List.keyfind(Supervisor.which_children(parent), id, 0) do
      {^id, pid, _, _} when is_pid(pid) and pid != original ->
        case Runtime.ref(pid) do
          {:ok, _ref} -> pid
          _unavailable -> wait_replacement(parent, id, original, attempts)
        end

      _starting ->
        wait_replacement(parent, id, original, attempts)
    end
  end

  defp wait_replacement(parent, id, original, attempts) do
    Process.sleep(5)
    replacement(parent, id, original, attempts - 1)
  end
end
