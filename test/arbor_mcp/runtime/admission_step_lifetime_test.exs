defmodule Arbor.MCP.Server.Runtime.AdmissionStepLifetimeTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, Ref}

  defmodule Handler do
    def init(_opts), do: {:ok, 0}
  end

  test "unbound step churn replaces monitors and rejects queued old phase timers and DOWNs" do
    root = start_supervised!({Runtime, handler: Handler, request_timeout_ms: 2_000})
    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    message = [
      %{"jsonrpc" => "2.0", "id" => 1, "method" => "fixture"},
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "fixture"}
    ]

    {:ok, route, initial} =
      Runtime.reserve_ingress(runtime, message,
        owner: owner,
        reply_to: self(),
        edge: owner,
        scope: make_ref(),
        batch?: true
      )

    :ok = Runtime.publish_ingress(runtime, route, initial, message, owner)
    {:ok, _entry, ^message} = Admission.checkout(table, initial.token)

    for _iteration <- 1..30 do
      {:ok, old} = Admission.current(table, initial.token)
      :ok = Admission.terminal(table, initial.token, :notification)
      assert :ok = Admission.release_step(table, initial.token)
      {:ok, fresh} = Admission.current(table, initial.token)
      refute old.monitor == fresh.monitor
      refute old.output_phase == fresh.output_phase
      send(route.admission, {:unbound_timeout, initial.token, old.output_phase})
      send(route.admission, {:unbound_timeout, initial.token})
      send(route.admission, {:DOWN, old.monitor, :process, owner, :normal})
      state = :sys.get_state(route.admission)
      assert map_size(state.monitors) == 1
      assert state.monitors[fresh.monitor] == initial.token
      assert %{terminal: false, output_phase: phase} = state.reservations[initial.token]
      assert phase == fresh.output_phase
      assert %{reserved: 2} = Admission.stats(table)
    end

    {:ok, last} = Admission.current(table, initial.token)
    Process.exit(owner, :kill)
    wait(fn -> match?(%{reserved: 0, pending_bytes: 0}, Admission.stats(table)) end)
    assert Process.alive?(route.admission)
    assert :sys.get_state(route.admission).monitors == %{}
    send(route.admission, {:unbound_timeout, initial.token, last.output_phase})
    send(route.admission, {:DOWN, last.monitor, :process, owner, :killed})
    assert :sys.get_state(route.admission).reservations == %{}
  end

  defp wait(fun, left \\ 200)
  defp wait(_fun, 0), do: flunk("owner credit cleanup did not settle")

  defp wait(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end
end
