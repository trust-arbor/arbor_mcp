defmodule Arbor.MCP.ApplicationTest do
  use ExUnit.Case, async: false

  @server_owners [
    Arbor.MCP.Server.ReplayCache.ETS,
    Arbor.MCP.Tasks.Store.ETS,
    Arbor.MCP.Server.Subscriptions,
    Arbor.MCP.HttpPlug.SessionRegistry,
    Arbor.MCP.Server.Cancellation,
    Arbor.MCP.SubscriptionRegistry,
    Arbor.MCP.SessionManager,
    Arbor.MCP.ProgressTracker
  ]

  test "application supervisor owns package facilities and no default server state" do
    {:ok, _} = Application.ensure_all_started(:arbor_mcp)
    supervisor = Process.whereis(Arbor.MCP.Supervisor)
    assert is_pid(supervisor)
    assert Process.alive?(supervisor)
    children = Supervisor.which_children(supervisor)
    ids = Enum.map(children, &elem(&1, 0))

    for owner <- @server_owners do
      refute owner in ids
      assert is_nil(Process.whereis(owner))
    end

    for facility <- [
          Arbor.MCP.Internal.SessionStore.DETS.PathClaims,
          Arbor.MCP.DynamicSupervisor,
          Arbor.MCP.Internal.ConsentCache,
          Arbor.MCP.Client.EraCache,
          Arbor.MCP.Authorization.OAuthTransactionStore,
          Arbor.MCP.Reliability.Supervisor
        ] do
      assert is_pid(Process.whereis(facility))
    end
  end

  test "a package facility restarts without restarting healthy siblings" do
    cache = Process.whereis(Arbor.MCP.Client.EraCache)
    consent = Process.whereis(Arbor.MCP.Internal.ConsentCache)
    monitor = Process.monitor(cache)
    Process.exit(cache, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^cache, :killed}, 1_000
    replacement = wait_for_replacement(cache, 100)
    assert is_pid(replacement)
    assert replacement != cache
    assert Process.alive?(replacement)
    assert Process.whereis(Arbor.MCP.Internal.ConsentCache) == consent
  end

  test "standalone session state remains explicitly supervisable" do
    manager = start_supervised!({Arbor.MCP.SessionManager, name: nil})
    session = GenServer.call(manager, {:create_session, %{transport: :test}})
    assert {:ok, %{id: ^session}} = GenServer.call(manager, {:get_session, session})
    assert is_nil(Process.whereis(Arbor.MCP.SessionManager))
  end

  test "module implements the Application callback" do
    assert {:module, Arbor.MCP.Application} = Code.ensure_compiled(Arbor.MCP.Application)
    assert function_exported?(Arbor.MCP.Application, :start, 2)
  end

  defp wait_for_replacement(_old, 0), do: flunk("package facility did not restart")

  defp wait_for_replacement(old, attempts) do
    case Process.whereis(Arbor.MCP.Client.EraCache) do
      pid when is_pid(pid) and pid != old ->
        pid

      _pending ->
        Process.sleep(5)
        wait_for_replacement(old, attempts - 1)
    end
  end
end
