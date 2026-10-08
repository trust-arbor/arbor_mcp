defmodule Arbor.MCP.Server.Runtime.BatchAdmissionTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Server.Runtime.{Admission, ByteBudget, Ref}
  alias Arbor.MCP.Transport.Test

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: opts[:test_pid], count: 0}}

    @impl true
    def handle_call_tool("hold", _arguments, state) do
      send(state.test_pid, {:batch_holding, self()})

      receive do
        :release -> increment(state)
      end
    end

    def handle_call_tool("inc", _arguments, state), do: increment(state)

    defp increment(state) do
      send(state.test_pid, {:batch_incremented, self()})

      {:ok, %{content: [], structuredContent: %{count: state.count + 1}},
       %{state | count: state.count + 1}}
    end
  end

  test "each request, notification and invalid member holds capacity before dispatch" do
    {root, transport} = start_pair(max_queue: 2)
    {:ok, runtime} = Runtime.ref(root)
    members = [tool(1, "hold"), notification(), nil]

    assert {:ok, _transport} = Test.send_message(members, transport)
    assert_receive {:batch_holding, worker}

    assert %{
             active: 1,
             queued: 0,
             reserved: 3,
             reserved_envelopes: 1,
             admitted_work: 3,
             admitted_envelopes: 1,
             confirmed_work: 3
           } = Runtime.stats(runtime)

    assert {:error, {:transport_error, :server_busy}} =
             Test.send_message(tool(2, "inc"), transport)

    send(worker, :release)
    assert_receive {:transport_message, encoded}

    assert [%{"id" => 1, "result" => _result}, %{"id" => nil, "error" => %{"code" => -32600}}] =
             decode(encoded)

    wait_for_empty(runtime)
    assert {:ok, _transport} = Test.send_message(tool(2, "inc"), transport)
    assert_receive {:transport_message, _response}
  end

  test "an over-capacity batch is rejected atomically without callbacks" do
    {root, transport} = start_pair(max_queue: 1)

    assert {:error, {:transport_error, :server_busy}} =
             Test.send_message([tool(1, "inc"), notification(), nil], transport)

    assert %{reserved: 0, reserved_envelopes: 0, admitted_work: 0, pending_bytes: 0} =
             Runtime.stats(root)

    refute_receive {:batch_incremented, _worker}, 20
    assert {:ok, _transport} = Test.send_message([tool(1, "inc"), tool(2, "inc")], transport)
    assert_receive {:transport_message, response}, 1_000
    assert Enum.map(decode(response), & &1["id"]) == [1, 2]
    wait_for_empty(root)
  end

  test "insufficient remaining permits do not retain a partial batch claim" do
    runtime = start_runtime(max_queue: 2)
    assert {:ok, _route, held} = reserve(runtime, [notification()])
    assert {:error, :server_busy} = reserve(runtime, [notification(), nil, 42])
    assert %{reserved: 1, reserved_envelopes: 1, admitted_work: 1} = Runtime.stats(runtime)
    assert :ok = RuntimeIngress.discard_ingress(runtime, held.token)
    assert {:ok, _route, whole} = reserve(runtime, [notification(), nil, 42])
    assert %{reserved: 3, admitted_work: 3, admitted_envelopes: 1} = Runtime.stats(runtime)
    assert :ok = RuntimeIngress.discard_ingress(runtime, whole.token)
    assert :ok = RuntimeIngress.discard_ingress(runtime, whole.token)
    wait_for_empty(runtime)
  end

  test "permit holes are reused while live neighboring envelopes keep their credits" do
    runtime = start_runtime(max_queue: 4)

    reservations =
      for _index <- 1..5 do
        {:ok, _route, reservation} = reserve(runtime, [notification()])
        reservation
      end

    for index <- [1, 3],
        do:
          RuntimeIngress.discard_ingress(
            runtime,
            Enum.at(reservations, index).token
          )

    assert {:ok, _route, batch} = reserve(runtime, [nil, 42])
    assert %{reserved: 5, reserved_envelopes: 4, admitted_work: 5} = Runtime.stats(runtime)
    assert {:error, :server_busy} = reserve(runtime, [notification()])
    assert :ok = RuntimeIngress.discard_ingress(runtime, batch.token)

    for _index <- 1..2,
        do: assert({:ok, _route, _reservation} = reserve(runtime, [notification()]))

    assert %{reserved: 5, reserved_envelopes: 5} = Runtime.stats(runtime)
  end

  test "input is charged once plus batch permit metadata with exact byte-edge rollback" do
    members = [nil, 42, notification()]
    profile = start_runtime(max_queue: 2)
    assert {:ok, _route, measured} = reserve(profile, members)
    charged = Runtime.stats(profile).pending_bytes
    input = :erlang.external_size(%{"payload" => members}) + :erlang.external_size([])
    assert charged == measured.bytes
    assert charged > input

    assert :ok =
             RuntimeIngress.discard_ingress(profile, measured.token)

    exact = start_runtime(max_queue: 2, max_pending_bytes: charged)
    assert {:ok, _route, accepted} = reserve(exact, members)
    assert Runtime.stats(exact).pending_bytes == charged
    assert :ok = RuntimeIngress.discard_ingress(exact, accepted.token)

    rejected = start_runtime(max_queue: 2, max_pending_bytes: charged - 1)
    {:ok, route} = Admission.route(Ref.table(rejected))
    :sys.suspend(route.admission)
    on_exit(fn -> resume(route.admission) end)
    assert {:error, :server_busy} = reserve(rejected, members)
    assert [] == slots(rejected)
    assert %{data: 0, outgoing: 0, incoming: 0} = ByteBudget.used(Ref.table(rejected))
    assert {:messages, []} = Process.info(route.admission, :messages)
    :sys.resume(route.admission)
    assert {:ok, _route, smaller} = reserve(rejected, [nil, 42])

    assert :ok =
             RuntimeIngress.discard_ingress(rejected, smaller.token)

    wait_for_empty(rejected)
  end

  test "concurrent batches cannot overfill a suspended Admission and dead producers are reaped" do
    runtime = start_runtime(max_queue: 8)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :sys.suspend(route.admission)
    on_exit(fn -> resume(route.admission) end)
    parent = self()
    members = [nil, notification(), tool(1, "inc")]

    producers =
      for _index <- 1..60 do
        spawn(fn ->
          send(
            parent,
            {:batch_candidate, self(), reserve(runtime, members, owner: parent, reply_to: parent)}
          )
        end)
      end

    on_exit(fn -> for pid <- producers, Process.alive?(pid), do: Process.exit(pid, :kill) end)

    for _index <- 1..57,
        do: assert_receive({:batch_candidate, _pid, {:error, :server_busy}}, 1_000)

    wait_for(fn ->
      claimed = slots(runtime)

      length(claimed) == 9 and
        Enum.all?(claimed, fn {_key, token, _pid} ->
          is_map(ByteBudget.candidate(Ref.table(runtime), token))
        end)
    end)

    claimed = slots(runtime)
    assert length(Enum.uniq_by(claimed, &elem(&1, 0))) == 9
    assert length(Enum.uniq_by(claimed, &elem(&1, 1))) == 3
    {:messages, messages} = Process.info(route.admission, :messages)
    confirmations = Enum.filter(messages, &match?({:"$gen_call", _, {:confirm, _}}, &1))
    assert length(confirmations) == 3
    assert Enum.all?(confirmations, &(:erlang.external_size(&1) < 256))
    for pid <- claimed |> Enum.map(&elem(&1, 2)) |> Enum.uniq(), do: Process.exit(pid, :kill)
    :sys.resume(route.admission)
    wait_for_empty(runtime)
    assert %{data: 0, outgoing: 0, incoming: 0} = ByteBudget.used(Ref.table(runtime))
    assert {:ok, _route, again} = reserve(runtime, List.duplicate(nil, 9))
    assert :ok = RuntimeIngress.discard_ingress(runtime, again.token)
  end

  test "owner handoff retains all permits after producer exit and reaps them on owner death" do
    runtime = start_runtime(max_queue: 2)
    table = Ref.table(runtime)
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    producer =
      spawn(fn ->
        {:ok, route, reservation} =
          reserve(runtime, [nil, 42, notification()], owner: owner, reply_to: parent)

        :ok =
          RuntimeIngress.publish_ingress(
            runtime,
            route,
            reservation,
            {:probe, :admitted},
            owner
          )

        send(parent, {:batch_published, self(), reservation.token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:batch_published, ^producer, token}
    assert {:ok, _reservation, {:probe, :admitted}} = Admission.checkout(table, token)
    monitor = Process.monitor(producer)
    send(producer, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    assert %{reserved: 3, admitted_envelopes: 1} = Runtime.stats(runtime)
    Process.exit(owner, :kill)
    wait_for_empty(runtime)
    assert {:ok, _route, again} = reserve(runtime, [nil, 42, notification()])
    assert :ok = RuntimeIngress.discard_ingress(runtime, again.token)
  end

  test "an unbound batch deadline frees every permit and byte without dispatch" do
    runtime = start_runtime(max_queue: 2)

    assert {:ok, _route, reservation} =
             reserve(runtime, [nil, notification(), tool(1, "inc")], timeout: 30)

    assert %{reserved: 3} = Runtime.stats(runtime)
    wait_for_empty(runtime)
    refute_receive {:batch_incremented, _worker}, 20

    assert :ok =
             RuntimeIngress.discard_ingress(runtime, reservation.token)

    assert {:ok, _route, again} = reserve(runtime, [nil, 42, notification()])
    assert :ok = RuntimeIngress.discard_ingress(runtime, again.token)
  end

  test "future member cancellation preserves order and holds the whole batch's credits until settlement" do
    {root, transport} = start_pair(max_queue: 2)

    assert {:ok, _transport} =
             Test.send_message([tool(1, "hold"), tool(2, "inc"), notification()], transport)

    assert_receive {:batch_holding, worker}
    assert {:ok, _transport} = Test.send_message(cancel(2), transport)
    assert %{reserved: 3, admitted_work: 3} = Runtime.stats(root)
    send(worker, :release)
    assert_receive {:transport_message, response}

    assert [%{"id" => 1, "result" => _result}, %{"id" => 2, "error" => %{"code" => -32001}}] =
             decode(response)

    wait_for_empty(root)
    assert {:ok, _transport} = Test.send_message(tool(3, "inc"), transport)
    assert_receive {:transport_message, _response}
  end

  test "scope cancellation releases an entire held batch and permits readmission" do
    {root, transport} = start_pair(max_queue: 2)

    assert {:ok, _transport} =
             Test.send_message([tool(1, "hold"), tool(2, "inc"), notification()], transport)

    assert_receive {:batch_holding, _worker}
    assert :ok = Runtime.cancel_scope(root, {:connection, transport.connection})
    wait_for_empty(root)
    assert_receive {:transport_message, retired}
    assert Enum.map(decode(retired), & &1["id"]) == [1, 2]
    assert {:ok, _transport} = Test.send_message([tool(3, "inc"), tool(4, "inc")], transport)
    assert_receive {:transport_message, response}
    assert Enum.map(decode(response), & &1["id"]) == [3, 4]
    wait_for_empty(root)
  end

  test "notification-only arrays consume capacity and settle without a response" do
    {root, transport} = start_pair(max_queue: 1)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> resume(edge) end)
    assert {:ok, _transport} = Test.send_message([notification(), notification()], transport)
    assert %{admitted_work: 2, admitted_envelopes: 1} = Runtime.stats(root)

    assert {:error, {:transport_error, :server_busy}} =
             Test.send_message(tool(1, "inc"), transport)

    :sys.resume(edge)
    wait_for_empty(root)
    refute_receive {:transport_message, _response}, 20
    assert {:ok, _transport} = Test.send_message(tool(1, "inc"), transport)
    assert_receive {:transport_message, _response}
  end

  test "invalid members each consume capacity and preserve grouped invalid-request replies" do
    {root, transport} = start_pair(max_queue: 1)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> resume(edge) end)
    assert {:ok, _transport} = Test.send_message([nil, 42], transport)
    assert %{admitted_work: 2, admitted_envelopes: 1} = Runtime.stats(root)
    :sys.resume(edge)
    assert_receive {:transport_message, response}

    assert [
             %{"id" => nil, "error" => %{"code" => -32600}},
             %{"id" => nil, "error" => %{"code" => -32600}}
           ] = decode(response)

    wait_for_empty(root)
    refute_receive {:batch_incremented, _worker}, 20
  end

  test "empty arrays retain one invalid-envelope permit and keep the existing error shape" do
    {root, transport} = start_pair(max_queue: 0)
    {:ok, edge} = Runtime.edge(root)
    :sys.suspend(edge)
    on_exit(fn -> resume(edge) end)
    assert {:ok, _transport} = Test.send_message([], transport)
    assert %{admitted_work: 1, admitted_envelopes: 1} = Runtime.stats(root)
    :sys.resume(edge)
    assert_receive {:transport_message, response}
    assert %{"id" => nil, "error" => %{"code" => -32600}} = decode(response)
    wait_for_empty(root)
    assert {:ok, _transport} = Test.send_message(tool(1, "inc"), transport)
    assert_receive {:transport_message, _response}
  end

  test "modern arrays within capacity still reject every member before callbacks" do
    {root, transport} = start_pair(max_queue: 1, protocol_mode: :modern_only)
    assert {:ok, _transport} = Test.send_message([tool(1, "inc"), tool(2, "inc")], transport)
    assert_receive {:transport_message, response}
    assert %{"id" => nil, "error" => %{"code" => -32600}} = decode(response)
    wait_for_empty(root)
    refute_receive {:batch_incremented, _worker}, 20
  end

  defp start_runtime(opts) do
    {root, _transport} = start_pair(opts)
    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp start_pair(opts) do
    opts =
      Keyword.merge([handler: Handler, handler_args: [test_pid: self()], transport: :test], opts)

    root =
      start_supervised!(
        Supervisor.child_spec({HandlerServer, opts}, id: make_ref(), restart: :temporary)
      )

    {:ok, transport} = Test.connect(server: root)
    {root, transport}
  end

  defp reserve(runtime, members, opts \\ []) do
    RuntimeIngress.reserve_ingress(
      runtime,
      members,
      Keyword.merge([owner: self(), reply_to: self()], opts)
    )
  end

  defp slots(runtime), do: :ets.match_object(Ref.table(runtime), {{:slot, :_}, :_, :_})

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp notification, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value
  defp resume(pid), do: if(Process.alive?(pid), do: :sys.resume(pid))

  defp wait_for_empty(runtime),
    do:
      wait_for(fn ->
        match?(
          %{reserved: 0, pending_bytes: 0, admitted_work: 0, admitted_envelopes: 0},
          Runtime.stats(runtime)
        )
      end)

  defp wait_for(fun, attempts \\ 200)
  defp wait_for(fun, 0), do: assert(fun.())

  defp wait_for(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            wait_for(fun, attempts - 1)
          )
      )
end
