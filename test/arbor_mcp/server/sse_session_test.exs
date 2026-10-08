defmodule Arbor.MCP.Server.SSESessionTest do
  # The session table is a VM-global named ETS table.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.SSESession

  @table :ex_mcp_sse_sessions

  setup do
    assert :ets.whereis(@table) == :undefined,
           "another owner left #{inspect(@table)} behind"

    :ok
  end

  test "init/0 is idempotent from one process" do
    assert :ok = SSESession.init()
    assert :ok = SSESession.init()
    assert :ets.info(@table, :owner) == self()
    :ets.delete(@table)
  end

  test "init/0 tolerates concurrent first callers" do
    # Repeat the race so a regression to check-then-create is caught reliably.
    for _round <- 1..20 do
      parent = self()

      racers =
        for _ <- 1..64 do
          spawn_link(fn ->
            receive do
              :go -> :ok
            end

            send(parent, {:init_result, self(), SSESession.init()})

            receive do
              :stop -> :ok
            end
          end)
        end

      Enum.each(racers, &send(&1, :go))

      for _ <- racers do
        assert_receive {:init_result, _pid, :ok}, 5_000
      end

      owner = :ets.info(@table, :owner)
      assert owner in racers

      # The table dies with its owner, which resets the race for the next round.
      ref = Process.monitor(owner)
      Enum.each(racers, &send(&1, :stop))
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000
      assert :ets.whereis(@table) == :undefined
    end
  end
end
