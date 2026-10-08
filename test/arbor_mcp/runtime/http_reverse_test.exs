defmodule Arbor.MCP.Server.Runtime.HTTPReverseTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Protocol.Elicitation
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.Transport.Test

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    ByteBudget,
    HTTPGateway,
    HTTPResponseLoans,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Initialization,
    Ref
  }

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.Runtime.{Admission, HTTPNotifications, HTTPResponseLoans}
    alias Arbor.MCP.Server.Runtime.HTTPResources.Source

    def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "reverse", "version" => "2"},
         "capabilities" => %{"tools" => %{}}
       }), state}
    end

    def handle_call_tool("ping", _args, state) do
      send(state.observer, {:reverse_worker, self()})
      result = Server.ping(self(), 1_000)
      send(state.observer, {:reverse_result, result})
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("short_ping", _args, state) do
      result = Server.ping(self(), 50)
      send(state.observer, {:reverse_result, result})
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("held_short_ping", _args, state) do
      send(state.observer, {:reverse_worker, self()})
      result = Server.ping(self(), 500)
      send(state.observer, {:short_reverse_result, result})
      receive do: (:next_reverse -> :ok)
      result = Server.ping(self(), 500)
      send(state.observer, {:reverse_result, result})
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}

    def handle_call_tool("held_loan", _args, state) do
      {:ok, source} = Source.capture()
      {:ok, proof} = Source.producer_snapshot(source)

      request = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "ping",
        "params" => %{}
      }

      control = %{source: source, deadline: proof.deadline, request: request, reply: self()}

      {:ok, route, reservation} =
        RuntimeIngress.reserve_ingress(proof.runtime, request,
          kind: :edge_control,
          direction: :outbound,
          owner: proof.gateway,
          caller: self(),
          edge: proof.gateway,
          scope: proof.scope,
          reply_to: self(),
          origin: Map.take(proof, [:token, :scope, :generation]),
          admission_deadline: proof.deadline,
          invocation_deadline: proof.deadline,
          dispatch_opts: [
            http_reverse: source,
            lifecycle_metadata_reserve: :binary.copy(<<0>>, 8_192)
          ]
        )

      :ok =
        RuntimeIngress.publish_ingress(
          proof.runtime,
          route,
          reservation,
          {:http_reverse, control},
          proof.gateway
        )

      receive do: ({:http_reverse, token, :registered} when token == reservation.token -> :ok)
      :ok = HTTPNotifications.append(source, request)
      receive do: ({:http_reverse, token, :result_ready} when token == reservation.token -> :ok)

      {:ok, result} =
        HTTPResponseLoans.checkout(proof.runtime, reservation.token, source, proof.deadline)

      send(state.observer, {:held_loan, self(), reservation.token, source, result})
      await_loan(reservation.token)
      :ok = HTTPResponseLoans.acknowledge(proof.runtime, reservation.token)
      Admission.release(Ref.table(proof.runtime), reservation.token)
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("reverse", %{"control" => control} = args, state) do
      send(state.observer, {:reverse_worker, self()})

      result =
        case control do
          "roots" ->
            Server.list_roots(self(), 1_000)

          "sampling" ->
            Server.create_message(self(), %{"messages" => [], "maxTokens" => 10})

          "form" ->
            Server.elicit(
              self(),
              %{
                "message" => "Choose",
                "requestedSchema" => %{"type" => "object", "properties" => %{}}
              },
              1_000
            )

          "url" ->
            Server.elicit(
              self(),
              %{
                "mode" => "url",
                "message" => "Open",
                "url" => "https://example.com/input",
                "elicitationId" => "input-1"
              },
              1_000
            )

          "invalid" ->
            Server.elicit(self(), %{"message" => "Choose", "requestedSchema" => false}, 1_000)

          "timeout" ->
            Server.elicit(self(), %{}, Map.get(args, "timeout", :infinity))

          "pending" ->
            Server.get_pending_requests(self())
        end

      send(state.observer, {:reverse_result, result})
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("pair", _args, state) do
      {:ok, source} = Source.capture()
      {:ok, proof} = Source.producer_snapshot(source)
      controls = for _index <- 1..2, do: open_control(source, proof)

      for {reservation, request} <- controls do
        receive do: ({:http_reverse, token, :registered} when token == reservation.token -> :ok)
        :ok = HTTPNotifications.append(source, request)
      end

      results =
        for {reservation, _request} <- controls do
          receive do: ({:http_reverse, token, :result_ready} when token == reservation.token ->
                         :ok)

          {:ok, result} =
            HTTPResponseLoans.checkout(proof.runtime, reservation.token, source, proof.deadline)

          {reservation.token, result}
        end

      send(state.observer, {:held_pair, self(), results})
      receive do: (:ack_loan -> :ok)

      for {token, _result} <- results do
        HTTPResponseLoans.acknowledge(proof.runtime, token)
        Admission.release(Ref.table(proof.runtime), token)
      end

      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_elicitation_complete("probe", state) do
      send(state.observer, {:normal_notification, self()})
      {:ok, state}
    end

    defp open_control(source, proof) do
      request = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "ping",
        "params" => %{}
      }

      control = %{source: source, deadline: proof.deadline, request: request, reply: self()}

      {:ok, route, reservation} =
        RuntimeIngress.reserve_ingress(proof.runtime, request,
          kind: :edge_control,
          direction: :outbound,
          owner: proof.gateway,
          caller: self(),
          edge: proof.gateway,
          scope: proof.scope,
          reply_to: self(),
          origin: Map.take(proof, [:token, :scope, :generation]),
          admission_deadline: proof.deadline,
          invocation_deadline: proof.deadline,
          dispatch_opts: [
            http_reverse: source,
            lifecycle_metadata_reserve: :binary.copy(<<0>>, 8_192)
          ]
        )

      :ok =
        RuntimeIngress.publish_ingress(
          proof.runtime,
          route,
          reservation,
          {:http_reverse, control},
          proof.gateway
        )

      {reservation, request}
    end

    defp await_loan(token) do
      receive do
        :ack_loan ->
          :ok

        :drop_receipt ->
          Process.delete({HTTPResponseLoans, token})
          await_loan(token)
      end
    end
  end

  test "a response can settle an addressed reverse request while callback capacity is full" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)
    assert Runtime.stats(runtime).active == 1
    assert %{status: 202} = post(opts, id, response(request["id"], %{"answer" => 7}))
    assert_receive {:reverse_result, {:ok, %{"answer" => 7}}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "a paused callback retains the response byte permit until its actual checkout and ACK" do
    {runtime, opts} = host(max_control_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, worker}
    request = reverse_request(sessions, lease)
    true = :erlang.suspend_process(worker)

    try do
      assert %{status: 202} = post(opts, id, response(request["id"], %{"held" => true}))
      assert Runtime.stats(runtime).response_bytes > 0
      held_bytes = Runtime.stats(runtime).response_bytes

      assert_raise HttpPlug.RuntimeWriter.AdmissionError, fn ->
        post(opts, id, response(request["id"], %{"duplicate" => true}))
      end

      assert Runtime.stats(runtime).response_bytes == held_bytes
      assert Process.alive?(worker)
      refute_receive {:reverse_result, _result}, 20
    after
      true = :erlang.resume_process(worker)
    end

    assert_receive {:reverse_result, {:ok, %{"held" => true}}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    assert Runtime.stats(runtime).response_bytes == 0
  end

  test "actual producer death releases an unread response without repeating its durable request" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, worker}
    request = reverse_request(sessions, lease)
    true = :erlang.suspend_process(worker)
    assert %{status: 202} = post(opts, id, response(request["id"], %{"discarded" => true}))
    assert Runtime.stats(runtime).response_bytes > 0
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert %{status: 200} = conn = Task.await(caller)
    assert is_map(Jason.decode!(conn.resp_body)["error"])
    refute_receive {:reverse_result, _value}, 20
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    assert Runtime.stats(runtime).response_bytes == 0
    assert {:ok, %{events: [event]}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert event.data["id"] == request["id"]
  end

  test "a reverse wait expires at its captured cutoff without replaying the callback or request" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 200} = post(opts, id, tool(2, "short_ping"))
    assert_receive {:reverse_result, {:error, :timeout}}
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)

    assert {:ok, %{events: [%{data: %{"method" => "ping"}}]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    assert %{status: 200} = conn = post(opts, id, tool(3, "peek"))
    assert Jason.decode!(conn.resp_body)["result"]["structuredContent"]["calls"] == 1
  end

  test "an externally retired unread response frees controls while its original Task stays alive" do
    {runtime, opts} = host(max_control_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "held_short_ping")) end)
    assert_receive {:reverse_worker, worker}
    request = reverse_request(sessions, lease)
    true = :erlang.suspend_process(worker)
    {:ok, gateway} = HTTPGateway.address(runtime)

    try do
      assert %{status: 202} = post(opts, id, response(request["id"], %{"unread" => true}))
      table = Ref.table(runtime)
      [{_input, _control, proof}] = ByteBudget.response_consumers(table)
      :ok = :sys.suspend(gateway)

      try do
        eventually(fn -> if :atomics.get(proof.phase, 1) == 3, do: :ok end)
      after
        :sys.resume(gateway)
      end

      eventually(fn -> if :sys.get_state(gateway).reverse.pending == %{}, do: :ok end)
      eventually(fn -> if ByteBudget.used(table).incoming == 0, do: :ok end)
      assert Process.alive?(worker)
      assert ByteBudget.used(table).outgoing == 0
    after
      true = :erlang.resume_process(worker)
    end

    assert_receive {:short_reverse_result, {:error, :timeout}}
    send(worker, :next_reverse)

    next =
      eventually(fn ->
        {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
        if event = Enum.find(events, &(&1.data["id"] != request["id"])), do: event.data
      end)

    assert %{status: 202} = post(opts, id, response(next["id"], %{"new" => true}))
    assert_receive {:reverse_result, {:ok, %{"new" => true}}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "the same response ID from a different session cannot settle the original callback" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    {other_id, _sessions, _other_lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)
    assert %{status: 202} = post(opts, other_id, response(request["id"], %{"wrong" => true}))
    refute_receive {:reverse_result, _result}, 20
    assert %{status: 202} = post(opts, id, response(request["id"], %{"right" => true}))
    assert_receive {:reverse_result, {:ok, %{"right" => true}}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "mixed response preflight settles the callback before ordered normal-member admission" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)

    assert %{status: 200} =
             conn =
             post(opts, id, [response(request["id"], %{"settled" => true}), tool(3, "peek")])

    assert_receive {:reverse_result, {:ok, %{"settled" => true}}}
    assert %{status: 200} = Task.await(caller)

    assert [%{"id" => 3, "result" => %{"structuredContent" => %{"calls" => 1}}}] =
             Jason.decode!(conn.resp_body)

    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "checked-out result credit survives generation reset until the actual Task ACK" do
    Process.flag(:trap_exit, true)
    {runtime, opts} = host(max_control_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)

    caller =
      Task.async(fn ->
        try do
          post(opts, id, tool(2, "held_loan"))
        rescue
          HttpPlug.RuntimeWriter.AdmissionError -> :original_invocation_retired
        end
      end)

    request = reverse_request(sessions, lease)
    assert %{status: 202} = post(opts, id, response(request["id"], %{"held" => 7}))
    assert_receive {:held_loan, worker, token, source, {:ok, %{"held" => 7}}}
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    held = ByteBudget.used(table).incoming
    assert held > 0

    try do
      assert {:ok, _epoch} = Initialization.begin(table, route.config, :cohort)
      assert {:ok, replacement} = Admission.activate(table, route.scheduler, route.config)
      assert replacement != route.generation
      assert Process.alive?(worker)
      assert ByteBudget.used(table).incoming == held

      assert {:error, :reverse_request_retired} =
               HTTPResponseLoans.checkout(
                 runtime,
                 token,
                 source,
                 System.monotonic_time(:millisecond) + 500
               )

      assert :ok = HTTPResponseLoans.acknowledge(runtime, token)
      assert ByteBudget.used(table).incoming == held
      send(worker, :ack_loan)
      eventually(fn -> if ByteBudget.used(table).incoming == 0, do: :ok end)
    after
      if Process.alive?(worker), do: send(worker, :ack_loan)
    end

    Task.await(caller)
  end

  test "hard Admission death cannot reopen checked-out input credit before the consumer dies" do
    Process.flag(:trap_exit, true)
    {runtime, opts} = host(max_control_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)

    caller =
      Task.async(fn ->
        try do
          post(opts, id, tool(2, "held_loan"))
        rescue
          HttpPlug.RuntimeWriter.AdmissionError -> :original_invocation_retired
        end
      end)

    request = reverse_request(sessions, lease)
    assert %{status: 202} = post(opts, id, response(request["id"], %{"held" => true}))
    assert_receive {:held_loan, worker, _token, _source, {:ok, _result}}
    table = Ref.table(runtime)
    {:ok, route} = Admission.route(table)
    held = ByteBudget.used(table).incoming
    {:ok, root} = Runtime.ref(runtime)
    root_pid = Ref.supervisor(root)
    :ok = :sys.suspend(root_pid)
    worker_monitor = Process.monitor(worker)
    admission_monitor = Process.monitor(route.admission)

    try do
      Process.exit(route.admission, :kill)
      assert_receive {:DOWN, ^admission_monitor, :process, _, :killed}
      assert Process.alive?(worker)
      assert ByteBudget.used(table).incoming == held

      assert Enum.any?(ByteBudget.response_consumers(table), fn {_input, _token, proof} ->
               proof.producer == worker
             end)
    after
      :ok = :sys.resume(root_pid)
    end

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000

    eventually(fn ->
      case Admission.route(table) do
        {:ok, %{generation: generation}} when generation != route.generation -> :ok
        _not_ready -> nil
      end
    end)

    assert ByteBudget.used(table).incoming == 0
    assert ByteBudget.response_consumers(table) == []
    Task.await(caller)
  end

  test "a forged public loan body cannot supply uncharged data or refund the real consumer" do
    {runtime, opts} = host(max_control_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "held_loan")) end)
    request = reverse_request(sessions, lease)
    assert %{status: 202} = post(opts, id, response(request["id"], %{"real" => 7}))
    assert_receive {:held_loan, worker, token, source, {:ok, %{"real" => 7}}}
    table = Ref.table(runtime)
    held = ByteBudget.used(table).incoming
    [{key, loan}] = :ets.lookup(table, {:http_response_loan, token})
    forged_phase = :atomics.new(1, signed: false)
    forged = %{loan | result: {:ok, %{"forged" => true}}, phase: forged_phase, producer: self()}
    :ets.insert(table, {key, forged})

    assert {:error, :reverse_request_retired} =
             HTTPResponseLoans.checkout(
               runtime,
               token,
               source,
               System.monotonic_time(:millisecond) + 100
             )

    assert :ok = HTTPResponseLoans.acknowledge(runtime, token)
    Admission.release(table, loan.input)
    assert ByteBudget.used(table).incoming == held
    :ets.delete(table, key)
    assert :ok = HTTPResponseLoans.acknowledge(runtime, token)
    assert ByteBudget.used(table).incoming == held
    send(worker, :ack_loan)
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if ByteBudget.used(table).incoming == 0, do: :ok end)
  end

  for {control, method} <- [
        {"roots", "roots/list"},
        {"sampling", "sampling/createMessage"},
        {"form", "elicitation/create"},
        {"url", "elicitation/create"}
      ] do
    test "retained #{control} reverse helper validates and settles its scoped response" do
      {runtime, opts} = host()
      {id, sessions, lease} = initialize(runtime, opts)
      live_get(runtime, lease)

      value =
        put_in(tool(2, "reverse"), ["params", "arguments"], %{"control" => unquote(control)})

      caller = Task.async(fn -> post(opts, id, value) end)
      assert_receive {:reverse_worker, _worker}
      request = reverse_request(sessions, lease, unquote(method))
      assert %{status: 202} = post(opts, id, response(request["id"], %{"action" => "accept"}))
      assert_receive {:reverse_result, {:ok, %{"action" => "accept"}}}
      assert %{status: 200} = Task.await(caller)
      eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    end
  end

  test "invalid elicitation schema and timeout never append a reverse effect" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    invalid = put_in(tool(2, "reverse"), ["params", "arguments"], %{"control" => "invalid"})
    assert %{status: 200} = post(opts, id, invalid)
    assert_receive {:reverse_result, {:error, :invalid_elicitation_params}}
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)

    invalid =
      put_in(tool(3, "reverse"), ["params", "arguments"], %{
        "control" => "timeout",
        "timeout" => 0
      })

    assert %{status: 200} = post(opts, id, invalid)
    assert_receive {:reverse_result, {:error, :invalid_reverse_timeout}}
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, lease, nil, [])
  end

  test "scoped pending query retains the current client request ID" do
    {runtime, opts} = host()
    {id, _sessions, _lease} = initialize(runtime, opts)

    value =
      put_in(tool("pending-query", "reverse"), ["params", "arguments"], %{"control" => "pending"})

    assert %{status: 200} = post(opts, id, value)
    assert_receive {:reverse_result, ["pending-query"]}
  end

  test "modern MRTR elicitation descriptor keeps its retained one-argument shape" do
    value =
      Arbor.MCP.Server.elicit(%{
        "message" => "Choose",
        "requestedSchema" => %{"type" => "object", "properties" => %{}}
      })

    assert %{
             "method" => "elicitation/create",
             "params" => %{"message" => "Choose", "requestedSchema" => %{"type" => "object"}}
           } = value

    assert {:error, :invalid_reverse_timeout} = Arbor.MCP.Server.elicit(self(), %{}, :infinity)
  end

  test "response-only arrays charge every loan and complete before their202" do
    {runtime, opts} = host(max_control_queue: 2)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "pair")) end)

    requests =
      eventually(fn ->
        {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
        if length(events) == 2, do: Enum.map(events, & &1.data)
      end)

    values =
      Enum.with_index(requests, fn request, index ->
        response(request["id"], %{"index" => index})
      end)

    assert %{status: 202} = post(opts, id, values)

    assert_receive {:held_pair, worker,
                    [{_token1, {:ok, %{"index" => 0}}}, {_token2, {:ok, %{"index" => 1}}}]}

    table = Ref.table(runtime)

    assert [{input, _control, _witness}, {same_input, _other, _proof}] =
             ByteBudget.response_consumers(table)

    assert input == same_input
    assert {:ok, %{work_count: 2}} = Admission.current(table, input)

    assert_raise HttpPlug.RuntimeWriter.AdmissionError, fn ->
      post(opts, id, response("extra", %{}))
    end

    send(worker, :ack_loan)
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "an entered response prefix is not replayed when the normal lane expires" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "held_loan")) end)
    request = reverse_request(sessions, lease)
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 80)
    :ok = HTTPWriterRegistry.bind_lease(binding, lease)
    members = [response(request["id"], %{"entered" => true}), tool(3, "peek")]

    assert {:error,
            {:http_partial_effect, %{accepted_responses: 1, normal_outcome: :handler_timeout}}} =
             HTTPGateway.submit(runtime, binding, members,
               dispatch_opts: [endpoint: "/mcp", http_endpoint: "/mcp"]
             )

    assert_receive {:held_loan, worker, _token, _source, {:ok, %{"entered" => true}}}
    send(worker, :ack_loan)
    assert %{status: 200} = Task.await(caller)
    HTTPWriterRegistry.retire(binding, :test_complete)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    assert {:ok, %{events: [_one_effect]}} = SessionManager.replay_page(sessions, lease, nil, [])
  end

  test "tampered unread data is rejected by the actual callback's protected digest" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, worker}
    request = reverse_request(sessions, lease)
    true = :erlang.suspend_process(worker)
    assert %{status: 202} = post(opts, id, response(request["id"], %{"real" => true}))
    table = Ref.table(runtime)
    [{_input, token, _proof}] = ByteBudget.response_consumers(table)
    [{key, loan}] = :ets.lookup(table, {:http_response_loan, token})
    :ets.insert(table, {key, %{loan | result: {:ok, %{"forged" => true}}}})
    true = :erlang.resume_process(worker)
    assert_receive {:reverse_result, {:error, :reverse_request_retired}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    assert ByteBudget.response_consumers(table) == []
  end

  test "response errors settle their exact waiter without changing the wire error object" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)
    error = %{"code" => -32603, "message" => "Authored failure", "data" => %{"safe" => true}}

    assert %{status: 202} =
             post(opts, id, %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error})

    assert_receive {:reverse_result, {:error, ^error}}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "null and unsolicited response IDs are ignored under charged202 acceptance" do
    {runtime, opts} = host(max_control_queue: 2)
    {id, sessions, lease} = initialize(runtime, opts)

    members = [
      %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32600, "message" => "Invalid request"}
      },
      response("unsolicited", %{})
    ]

    assert %{status: 202} = post(opts, id, members)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert ByteBudget.used(Ref.table(runtime)).incoming == 0
  end

  test "single response validation retains modern-only mode and malformed-envelope rejection" do
    {runtime, opts} = host()
    {id, _sessions, _lease} = initialize(runtime, opts)
    modern_opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)

    assert %{status: 400} = modern = post(modern_opts, id, response("unsolicited", %{}))

    assert Jason.decode!(modern.resp_body)["error"]["code"] ==
             Arbor.MCP.Protocol.ErrorCodes.unsupported_protocol_version()

    malformed = %{
      "jsonrpc" => "2.0",
      "id" => "invalid-response",
      "result" => %{},
      "error" => %{"code" => -32603, "message" => "error"}
    }

    assert %{status: 400} = rejected = post(opts, id, malformed)
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32600
    assert Runtime.stats(runtime).reserved == 0
  end

  test "mixed normal notifications run only after their response prefix releases work capacity" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)

    members = [
      response(request["id"], %{}),
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/elicitation/complete",
        "params" => %{"elicitationId" => "probe"}
      }
    ]

    assert %{status: 202} = post(opts, id, members)
    assert_receive {:reverse_result, {:ok, %{}}}
    assert_receive {:normal_notification, _worker}
    assert %{status: 200} = Task.await(caller)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "mixed invalid members retain normal relative order and aggregate omission of responses" do
    {runtime, opts} = host(max_queue: 1)
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)

    assert %{status: 200} =
             conn = post(opts, id, [tool(3, "peek"), response(request["id"], %{}), 7])

    assert_receive {:reverse_result, {:ok, %{}}}
    assert %{status: 200} = Task.await(caller)

    assert [
             %{"id" => 3, "result" => %{"structuredContent" => %{"calls" => 1}}},
             %{"id" => nil, "error" => %{"code" => -32600}}
           ] = Jason.decode!(conn.resp_body)

    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "nested response arrays consume normal member capacity and return ordered invalid errors" do
    {runtime, opts} = host(max_queue: 1, max_control_queue: 1)
    {id, _sessions, _lease} = initialize(runtime, opts)
    {:ok, gateway} = HTTPGateway.address(runtime)
    {:ok, route} = Admission.route(Ref.table(runtime))
    :ok = :sys.suspend(gateway)
    nested = [response(7, %{})]
    caller = Task.async(fn -> post(opts, id, [nested, tool(8, "peek")]) end)

    try do
      eventually(fn -> if Runtime.stats(runtime).admitted_work == 2, do: :ok end)
      assert Runtime.stats(runtime).response_bytes == 0
      assert ByteBudget.used(Ref.table(runtime)).incoming == 0
    after
      :sys.resume(gateway)
    end

    assert %{status: 200} = conn = Task.await(caller)

    assert [
             %{"id" => nil, "error" => %{"code" => -32600}},
             %{"id" => 8, "result" => %{"structuredContent" => %{"calls" => 0}}}
           ] = Jason.decode!(conn.resp_body)

    assert {:ok, same} = Admission.route(Ref.table(runtime))
    assert same.admission == route.admission and same.generation == route.generation
    assert Process.alive?(route.admission)
    assert Process.alive?(gateway)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "a response prefix cannot make a multi-member normal array consume one work slot" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> post(opts, id, tool(2, "ping")) end)
    assert_receive {:reverse_worker, _worker}
    request = reverse_request(sessions, lease)
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 80)
    :ok = HTTPWriterRegistry.bind_lease(binding, lease)
    members = [response(request["id"], %{}), tool(3, "peek"), tool(4, "peek")]

    assert {:error,
            {:http_partial_effect, %{accepted_responses: 1, normal_outcome: :handler_timeout}}} =
             HTTPGateway.submit(runtime, binding, members,
               dispatch_opts: [endpoint: "/mcp", http_endpoint: "/mcp"]
             )

    assert_receive {:reverse_result, {:ok, %{}}}
    assert %{status: 200} = Task.await(caller)
    HTTPWriterRegistry.retire(binding, :test_complete)
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
  end

  test "pinned elicitation validation rejects nested non-JSON instance data safely" do
    deadline = System.monotonic_time(:millisecond) + 500

    params = %{
      "message" => "Choose",
      "requestedSchema" => %{"type" => "object", "properties" => %{}},
      "private" => self()
    }

    assert {:error, :invalid_elicitation_params} =
             Elicitation.validate(params, deadline)

    assert {:error, :invalid_elicitation_params} =
             Elicitation.validate(%{}, deadline - 1_000)
  end

  test "direct borrowed-binding arrays reject excessive metadata before Gateway admission" do
    {runtime, _opts} = host(max_control_queue: 2)
    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, gateway} = HTTPGateway.address(runtime)
    table = Ref.table(runtime)
    before_claims = ByteBudget.used(table)
    :ok = :sys.suspend(gateway)

    try do
      for members <- [
            List.duplicate(response(7, %{}), 4),
            List.duplicate(tool(7, "peek"), 4),
            List.duplicate([response(7, %{})], 4)
          ] do
        assert {:error, :server_busy} = HTTPGateway.submit(runtime, binding, members)
      end

      assert ByteBudget.used(table) == before_claims
      assert Runtime.stats(runtime).reserved == 0
      assert {:messages, messages} = Process.info(gateway, :messages)
      refute Enum.any?(messages, &match?(:runtime_ingress_ready, &1))
    after
      :sys.resume(gateway)
      HTTPWriterRegistry.retire(binding, :test_complete)
    end
  end

  test "additive elicitation helper preserves the native Test reverse transport" do
    root =
      start_supervised!(
        {Arbor.MCP.Server.HandlerServer,
         [transport: :test, handler: Handler, handler_args: [observer: self()]]}
      )

    {:ok, transport} = Test.connect(server: root)

    params = %{
      "message" => "Choose",
      "requestedSchema" => %{"type" => "object", "properties" => %{}}
    }

    caller = Task.async(fn -> Arbor.MCP.Server.elicit(root, params, 500) end)
    assert {:ok, wire, transport} = Test.receive_message(transport, 500)

    assert %{"method" => "elicitation/create", "id" => id, "params" => ^params} =
             Jason.decode!(wire)

    result = %{"action" => "accept", "content" => %{}}
    assert {:ok, _transport} = Test.send_message(response(id, result), transport)
    assert {:ok, ^result} = Task.await(caller)

    assert {:error, :invalid_elicitation_params} =
             Arbor.MCP.Server.elicit(root, %{"requestedSchema" => false}, 500)

    refute_receive {:transport_message, _unadmitted}
  end

  defp host(options \\ []) do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        request_timeout_ms: 2_000,
        max_concurrency: 1,
        max_queue: Keyword.get(options, :max_queue, 0),
        services: [sessions: []],
        max_control_queue: Keyword.get(options, :max_control_queue, 32)
      )

    {:ok, runtime} = Runtime.ref(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)

    {runtime, HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, allowed_origins: :any)}
  end

  defp initialize(runtime, opts) do
    value = %{
      "jsonrpc" => "2.0",
      "id" => "init-" <> Integer.to_string(System.unique_integer([:positive])),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "client", "version" => "2"},
        "capabilities" => %{}
      }
    }

    assert %{status: 200} = conn = post(opts, nil, value)
    [id] = get_resp_header(conn, "mcp-session-id")
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_session(sessions, id, %{}, [])
    eventually(fn -> if Runtime.stats(runtime).reserved == 0, do: :ok end)
    {id, sessions, lease}
  end

  defp live_get(runtime, lease) do
    writer = spawn(fn -> writer_loop() end)
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)

    operation = fn ->
      {:ok, binding} = HTTPWriterProxy.capture(runtime)
      :ok = HTTPWriterRegistry.bind_lease(binding, lease)
      :ok = HTTPWriterRegistry.register_session_stream(binding)
    end

    token = make_ref()
    send(writer, {:operation, self(), token, operation})
    assert_receive {^token, :ok}
    writer
  end

  defp writer_loop do
    receive do
      {:operation, from, token, operation} ->
        send(from, {token, operation.()})
        writer_loop()

      _notice ->
        writer_loop()
    end
  end

  defp reverse_request(sessions, lease, method \\ "ping") do
    eventually(fn ->
      {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
      if event = Enum.find(events, &(&1.data["method"] == method)), do: event.data
    end)
  end

  defp post(opts, id, value) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(value))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    conn = if id, do: put_req_header(conn, "mcp-session-id", id), else: conn
    HttpPlug.call(conn, opts)
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp eventually(operation, attempts \\ 200)
  defp eventually(_operation, 0), do: flunk("reverse operation did not settle")

  defp eventually(operation, attempts) do
    case operation.() do
      nil ->
        Process.sleep(5)
        eventually(operation, attempts - 1)

      result ->
        result
    end
  end
end
