defmodule Arbor.MCP.Server.Runtime.HTTPResourcesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  alias Arbor.MCP.{HttpPlug, SessionManager, SubscriptionRegistry}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    HTTPResources,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Initialization,
    Ref,
    ServiceOperation
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source

  defmodule Identity do
    def principal(conn, _request, _token), do: conn.assigns[:verified_principal]
    def tenant(conn, _request, _token), do: conn.assigns[:verified_tenant]
  end

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server.Runtime.HTTPResources.Source

    def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(
           params,
           %{
             "serverInfo" => %{"name" => "resource", "version" => "2"},
             "capabilities" => %{"resources" => %{"subscribe" => true}}
           }
         ), state}

    def handle_subscribe_resource(uri, state), do: resource_callback(:subscribe, uri, state)

    def handle_unsubscribe_resource(uri, state), do: resource_callback(:unsubscribe, uri, state)

    defp resource_callback(method, uri, state) do
      if uri == "test://hold-track" do
        send(state.observer, {:resource_callback, method, self()})

        receive do
          :finish_resource -> :ok
        end
      end

      {:ok, %{}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("broadcast", args, state) do
      result = Arbor.MCP.Server.notify_resource_update(args["uri"])
      send(state.observer, {:publication_result, result})
      {:ok, %{"content" => []}, state}
    end

    def handle_call_tool("hold", _args, state) do
      {:ok, source} = Source.capture()
      send(state.observer, {:held_source, self(), source})

      receive do
        {:publish, uri} ->
          result = Arbor.MCP.Server.notify_resource_update(uri)
          send(state.observer, {:held_result, result})
          {:ok, %{"content" => []}, state}
      end
    end

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}

    def handle_elicitation_complete(uri, state) do
      result = Arbor.MCP.Server.notify_resource_update(uri)
      send(state.observer, {:publication_result, result})
      {:ok, state}
    end
  end

  test "retained publication exports fail explicitly outside callback and never use global tables" do
    assert {:error, :no_request_context} = HttpPlug.broadcast_resource_update("test://uri")
    assert {:error, :no_request_context} = Arbor.MCP.Server.notify_resource_update("test://uri")
    assert {:error, :invalid_resource_uri} = HTTPResources.broadcast(String.duplicate("a", 4_097))
  end

  test "successful addressed resource callbacks register and unregister exact session epochs" do
    {runtime, opts} = host()
    id = initialize(opts)
    subscribed = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})
    assert subscribed.status == 200
    assert Jason.decode!(subscribed.resp_body)["result"] == %{}
    {resources, sessions, lease} = services(runtime, id)
    assert {:ok, ["test://uri"]} = SubscriptionRegistry.subscriptions(resources, lease, [])
    assert {:ok, %{subscriptions: 1}} = SubscriptionRegistry.get_stats(resources, [])
    assert %{status: 200} = request(opts, id, "resources/unsubscribe", %{"uri" => "test://uri"})
    assert {:ok, []} = SubscriptionRegistry.subscriptions(resources, lease, [])

    assert {:ok, %{metadata: %{transport_endpoint: "/mcp"}}} =
             SessionManager.get_session(sessions, lease, [])

    settled(runtime)
  end

  test "offline subscribed sessions durably receive publication without invented live delivery" do
    {runtime, opts} = host()

    ids =
      for _ <- 1..3 do
        id = initialize(opts)
        assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})
        id
      end

    assert %{status: 200} =
             request(opts, hd(ids), "tools/call", %{
               "name" => "broadcast",
               "arguments" => %{"uri" => "test://uri"}
             })

    assert_receive {:publication_result, %{subscribers: 3, delivered: 0}}

    for id <- ids do
      {_resources, sessions, lease} = services(runtime, id)

      assert {:ok,
              %{
                events: [
                  %{
                    data: %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "test://uri"}
                    }
                  }
                ]
              }} = SessionManager.replay_page(sessions, lease, nil, [])
    end

    settled(runtime)
  end

  test "resource lookup pressure fails before durable append and failed tracking cannot commit handler state" do
    {runtime, opts} = host(resource_limits: [max_lookup_results: 1, max_subscriptions: 2])

    ids =
      for _ <- 1..2 do
        id = initialize(opts)
        assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})
        id
      end

    assert %{status: 200} =
             request(opts, hd(ids), "tools/call", %{
               "name" => "broadcast",
               "arguments" => %{"uri" => "test://uri"}
             })

    assert_receive {:publication_result, {:error, :lookup_page_required}}

    for id <- ids do
      {_resources, sessions, lease} = services(runtime, id)
      assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, lease, nil, [])
    end

    rejected = request(opts, hd(ids), "resources/subscribe", %{"uri" => "test://overflow"})
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32603
    peek = request(opts, hd(ids), "tools/call", %{"name" => "peek", "arguments" => %{}})
    assert Jason.decode!(peek.resp_body)["result"]["structuredContent"]["calls"] == 2
    settled(runtime)
  end

  test "private forwarded endpoint and trusted principal plus tenant isolate durable fanout" do
    {runtime, opts} = host()

    contexts = [
      [prefix: "a", principal: "alice", tenant: "one"],
      [prefix: "b", principal: "alice", tenant: "one"],
      [prefix: "a", principal: "bob", tenant: "one"],
      [prefix: "a", principal: "alice", tenant: "two"],
      [prefix: "a"]
    ]

    targets =
      for context <- contexts do
        id = initialize(opts, context)

        assert %{status: 200} =
                 request(opts, id, "resources/subscribe", %{"uri" => "test://uri"}, context)

        {id, context}
      end

    {source, context} = hd(targets)

    assert %{status: 200} =
             request(
               opts,
               source,
               "tools/call",
               %{"name" => "broadcast", "arguments" => %{"uri" => "test://uri"}},
               context
             )

    assert_receive {:publication_result, %{subscribers: 1, delivered: 0}}

    for {{id, target_context}, index} <- Enum.with_index(targets) do
      {_resources, sessions, lease} = services(runtime, id, target_context)
      assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
      assert length(events) == if(index == 0, do: 1, else: 0)
    end

    settled(runtime)
  end

  test "partial replay pressure retains prior durable append and reports exact accepted counts" do
    {runtime, opts} = host(session_limits: [max_events: 1])

    ids =
      for _ <- 1..3 do
        id = initialize(opts)
        assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})
        id
      end

    assert %{status: 200} =
             request(opts, hd(ids), "tools/call", %{
               "name" => "broadcast",
               "arguments" => %{"uri" => "test://uri"}
             })

    assert_receive {:publication_result,
                    {:error,
                     {:resource_publication_partial, :replay_capacity_exhausted,
                      %{subscribers: 3, stored: 1, delivered: 0}}}}

    events =
      for id <- ids do
        {_resources, sessions, lease} = services(runtime, id)
        {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
        length(events)
      end

    assert Enum.sum(events) == 1
    settled(runtime)
  end

  test "copied source cannot authorize another producer and expires with its actual task" do
    {runtime, opts} = host()
    id = initialize(opts)
    assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})

    caller =
      Task.async(fn ->
        request(opts, id, "tools/call", %{"name" => "hold", "arguments" => %{}})
      end)

    assert_receive {:held_source, worker, source}
    refute Source.current?(source)
    {resources, sessions, lease} = services(runtime, id)

    assert {:error, :resource_source_retired} =
             ServiceOperation.call(
               resources,
               :resource_subscriptions,
               :http_subscribe,
               [resources, lease, "test://forged", source],
               []
             )

    send(worker, {:publish, "test://uri"})
    assert_receive {:held_result, %{subscribers: 1, delivered: 0}}
    assert %{status: 200} = Task.await(caller)
    assert {:ok, ["test://uri"]} = SubscriptionRegistry.subscriptions(resources, lease, [])
    assert {:ok, %{events: [_event]}} = SessionManager.replay_page(sessions, lease, nil, [])
    wait(fn -> not Process.alive?(worker) end)
    refute Source.current?(source)
    settled(runtime)
  end

  test "an original admitted cancellation retires the held source without durable mutation" do
    {runtime, opts} = host()
    id = initialize(opts)
    assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})

    caller =
      Task.async(fn ->
        request(opts, id, "tools/call", %{"name" => "hold", "arguments" => %{}}, id: 700)
      end)

    assert_receive {:held_source, worker, source}
    monitor = Process.monitor(worker)

    assert %{status: 202} =
             notification(opts, id, "notifications/cancelled", %{"requestId" => 700})

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert %{status: 200} = Task.await(caller)
    refute Source.current?(source)
    {_resources, sessions, lease} = services(runtime, id)
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, lease, nil, [])
    settled(runtime)
  end

  test "cancellation before automatic tracking leaves both registration and handler state unchanged" do
    for method <- [:subscribe, :unsubscribe] do
      {runtime, opts} = host()
      id = initialize(opts)
      {resources, _sessions, lease} = services(runtime, id)

      if method == :unsubscribe,
        do:
          assert(:ok == SubscriptionRegistry.subscribe(resources, lease, "test://hold-track", []))

      caller =
        Task.async(fn ->
          request(opts, id, "resources/#{method}", %{"uri" => "test://hold-track"}, id: 701)
        end)

      assert_receive {:resource_callback, ^method, worker}, 1_000
      monitor = Process.monitor(worker)

      assert %{status: 202} =
               notification(opts, id, "notifications/cancelled", %{"requestId" => 701})

      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
      cancelled_response(Task.await(caller))
      expected = if method == :subscribe, do: [], else: ["test://hold-track"]
      assert {:ok, ^expected} = SubscriptionRegistry.subscriptions(resources, lease, [])
      assert_calls(opts, id, 0)
      settled(runtime)
    end
  end

  test "tracking accepted before queued cancellation is retained while handler state cannot commit" do
    for method <- [:subscribe, :unsubscribe] do
      {runtime, opts} = host()
      id = initialize(opts)
      {resources, _sessions, lease} = services(runtime, id)

      if method == :unsubscribe,
        do:
          assert(:ok == SubscriptionRegistry.subscribe(resources, lease, "test://hold-track", []))

      caller =
        Task.async(fn ->
          request(opts, id, "resources/#{method}", %{"uri" => "test://hold-track"}, id: 702)
        end)

      assert_receive {:resource_callback, ^method, worker}, 1_000

      {:ok, route} =
        Admission.route(Ref.table(runtime))

      scheduler = route.scheduler
      :ok = :sys.suspend(scheduler)

      cancel =
        Task.async(fn ->
          notification(opts, id, "notifications/cancelled", %{"requestId" => 702})
        end)

      try do
        wait(fn ->
          scheduler_message?(scheduler, fn message -> match?({:http_cancel, _, _, _}, message) end)
        end)

        send(worker, :finish_resource)
        expected = if method == :subscribe, do: ["test://hold-track"], else: []

        wait(fn ->
          SubscriptionRegistry.subscriptions(resources, lease, []) == {:ok, expected}
        end)

        wait(fn ->
          scheduler_message?(scheduler, fn message ->
            match?({ref, _} when is_reference(ref), message)
          end)
        end)
      after
        if Process.alive?(scheduler), do: :sys.resume(scheduler)
      end

      assert %{status: 202} = Task.await(cancel)
      cancelled_response(Task.await(caller))
      expected = if method == :subscribe, do: ["test://hold-track"], else: []
      assert {:ok, ^expected} = SubscriptionRegistry.subscriptions(resources, lease, [])
      assert_calls(opts, id, 0)
      settled(runtime)
    end
  end

  test "a captured old GET cannot replace a healthy registration after route generation changes" do
    {runtime, opts} = host()
    id = initialize(opts)
    {_resources, _sessions, lease} = services(runtime, id)
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    old_writer = fake_writer()
    {:ok, old} = writer_call(old_writer, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = writer_call(old_writer, fn -> HTTPWriterRegistry.bind_lease(old, lease) end)
    guardian = HTTPWriterRegistry.guardian(domain)
    :ok = :sys.suspend(guardian)

    try do
      table = Ref.table(runtime)
      {:ok, previous} = Admission.route(table)
      Process.exit(previous.scheduler, :kill)

      wait(fn ->
        Initialization.ready?(table) and
          match?(
            {:ok, %{generation: generation}} when generation != previous.generation,
            Admission.route(table)
          )
      end)

      fresh_writer = fake_writer()
      {:ok, fresh} = writer_call(fresh_writer, fn -> HTTPWriterProxy.capture(runtime) end)

      assert :ok =
               writer_call(fresh_writer, fn -> HTTPWriterRegistry.bind_lease(fresh, lease) end)

      assert :ok =
               writer_call(fresh_writer, fn ->
                 HTTPWriterRegistry.register_session_stream(fresh)
               end)

      assert {:ok, _proof} = HTTPWriterBinding.validate(fresh, runtime)

      assert {:error, :invalid_http_session_stream} =
               writer_call(old_writer, fn -> HTTPWriterRegistry.register_session_stream(old) end)

      assert {:ok, _proof} = HTTPWriterBinding.validate(fresh, runtime)
      assert :ok = writer_call(fresh_writer, fn -> HTTPWriterRegistry.retire(fresh) end)
      assert :ok = writer_call(old_writer, fn -> HTTPWriterRegistry.retire(old) end)
    after
      if Process.alive?(guardian), do: :sys.resume(guardian)
    end

    settled(runtime)
  end

  test "retired session epochs cannot receive new fanout and a recreated session has no old URI" do
    {runtime, opts} = host()
    old_id = initialize(opts)
    publisher_id = initialize(opts)
    assert %{status: 200} = request(opts, old_id, "resources/subscribe", %{"uri" => "test://uri"})
    {resources, sessions, old_lease} = services(runtime, old_id)
    assert :ok = SessionManager.terminate_session(sessions, old_lease, [])

    assert {:ok, new_lease} =
             SessionManager.create_session(sessions, %{transport_endpoint: "/mcp"},
               session_id: old_id
             )

    refute new_lease == old_lease
    assert {:ok, []} = SubscriptionRegistry.subscriptions(resources, new_lease, [])

    assert %{status: 200} =
             request(opts, publisher_id, "tools/call", %{
               "name" => "broadcast",
               "arguments" => %{"uri" => "test://uri"}
             })

    assert_receive {:publication_result, %{subscribers: 0, delivered: 0}}
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, new_lease, nil, [])
    settled(runtime)
  end

  test "native non-HTTP resource callbacks retain their existing application-state contract" do
    {:ok, root} = Runtime.start_link(handler: Handler, handler_args: [observer: self()])
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:ok, runtime} = Runtime.ref(root)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "resources/subscribe",
      "params" => %{"uri" => "test://uri"}
    }

    assert {:ok, %{"result" => %{}}} = Runtime.request(runtime, request)

    peek = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "peek", "arguments" => %{}}
    }

    assert {:ok, %{"result" => %{"structuredContent" => %{"calls" => 1}}}} =
             Runtime.request(runtime, peek)
  end

  test "accepted notification-array resource effects retain actual producer proof after socket return" do
    {runtime, opts} = host()
    id = initialize(opts)

    notifications =
      for uri <- ["test://one", "test://two"] do
        %{"jsonrpc" => "2.0", "method" => "resources/subscribe", "params" => %{"uri" => uri}}
      end

    result =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(notifications))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> HttpPlug.call(opts)

    assert result.status == 202
    {resources, _sessions, lease} = services(runtime, id)

    wait(fn ->
      SubscriptionRegistry.subscriptions(resources, lease, []) ==
        {:ok, ["test://one", "test://two"]}
    end)

    settled(runtime)
  end

  test "original invocation expiry stops a held producer and cannot append a late publication" do
    {runtime, opts} = host()
    id = initialize(opts)
    assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})

    caller =
      Task.async(fn ->
        request(opts, id, "tools/call", %{"name" => "hold", "arguments" => %{}})
      end)

    assert_receive {:held_source, worker, source}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
    assert %{status: 200} = Task.await(caller)
    refute Source.current?(source)
    {_resources, sessions, lease} = services(runtime, id)
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, lease, nil, [])
    settled(runtime)
  end

  test "modern JSON and accepted notifications authenticate actual Tasks without inventing sessions" do
    {runtime, opts} = host(protocol_mode: :prefer_modern)
    id = initialize(opts)
    assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})

    result =
      modern(
        opts,
        "tools/call",
        %{"name" => "broadcast", "arguments" => %{"uri" => "test://uri"}},
        800
      )

    assert result.status == 200
    assert get_resp_header(result, "mcp-session-id") == []
    assert_receive {:publication_result, %{subscribers: 1, delivered: 0}}

    completed =
      modern(
        opts,
        "tools/call",
        %{"name" => "broadcast", "arguments" => %{"uri" => "test://uri"}},
        nil
      )

    assert completed.status == 202
    assert get_resp_header(completed, "mcp-session-id") == []
    assert_receive {:publication_result, %{subscribers: 1, delivered: 0}}, 1_000
    {_resources, sessions, lease} = services(runtime, id)

    assert {:ok, %{events: [_first, _second]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    settled(runtime)
  end

  test "deprecated SSE POST callbacks use the same authenticated Task before durable reply" do
    {runtime, opts} = host(legacy_http_sse: true, sse_mode: :oneshot)
    hello = Plug.Test.conn(:get, "/sse") |> HttpPlug.call(opts)
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, hello.resp_body)
    id = URI.decode_query(URI.parse(endpoint).query)["sessionId"]

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "resource", "version" => "2"}
      }
    }

    assert %{status: 202} = alias_post(opts, id, init)

    subscribe = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "resources/subscribe",
      "params" => %{"uri" => "test://uri"}
    }

    assert %{status: 202} = alias_post(opts, id, subscribe)

    publish = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "broadcast", "arguments" => %{"uri" => "test://uri"}}
    }

    assert %{status: 202} = alias_post(opts, id, publish)
    assert_receive {:publication_result, %{subscribers: 1, delivered: 0}}
    {resources, sessions, lease} = services(runtime, id)
    assert {:ok, ["test://uri"]} = SubscriptionRegistry.subscriptions(resources, lease, [])
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert Enum.map(events, & &1.data["id"]) == [1, 2, nil, 3]
    settled(runtime)
  end

  test "a still-live Task cannot publish under its retired session epoch" do
    {runtime, opts} = host()
    id = initialize(opts)
    assert %{status: 200} = request(opts, id, "resources/subscribe", %{"uri" => "test://uri"})

    caller =
      Task.async(fn ->
        try do
          request(opts, id, "tools/call", %{"name" => "hold", "arguments" => %{}})
        rescue
          Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError -> :retired_response_authority
        end
      end)

    assert_receive {:held_source, worker, _source}, 1_000
    {_resources, sessions, old_lease} = services(runtime, id)
    assert :ok = SessionManager.terminate_session(sessions, old_lease, [])

    assert {:ok, replacement} =
             SessionManager.create_session(sessions, %{transport_endpoint: "/mcp"},
               session_id: id
             )

    assert Process.alive?(worker)
    send(worker, {:publish, "test://uri"})
    assert_receive {:held_result, {:error, :resource_source_retired}}, 1_000
    assert :retired_response_authority = Task.await(caller)
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, replacement, nil, [])
    settled(runtime)
  end

  defp fake_writer do
    writer = spawn(fn -> fake_writer_loop() end)
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    writer
  end

  defp fake_writer_loop do
    receive do
      {:write_operation, from, token, operation} ->
        send(from, {token, operation.()})
        fake_writer_loop()

      _notice ->
        fake_writer_loop()
    end
  end

  defp writer_call(writer, operation) do
    token = make_ref()
    send(writer, {:write_operation, self(), token, operation})

    receive do
      {^token, result} -> result
    after
      1_000 -> flunk("fake GET writer did not complete")
    end
  end

  defp cancelled_response(%{status: 200, resp_body: body}) do
    assert %{"error" => %{"code" => -32001, "data" => %{"type" => "request_cancelled"}}} =
             Jason.decode!(body)
  end

  defp assert_calls(opts, id, expected) do
    response = request(opts, id, "tools/call", %{"name" => "peek", "arguments" => %{}})
    assert Jason.decode!(response.resp_body)["result"]["structuredContent"]["calls"] == expected
  end

  defp scheduler_message?(scheduler, predicate) do
    {:messages, messages} = Process.info(scheduler, :messages)
    Enum.any?(messages, predicate)
  end

  defp host(config \\ []) do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        request_timeout_ms: config[:request_timeout_ms] || 1_000,
        services: [
          sessions: [options: config[:session_limits] || []],
          resource_subscriptions: [options: config[:resource_limits] || []]
        ]
      )

    {:ok, runtime} = Runtime.ref(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)

    {runtime,
     HttpPlug.init(
       runtime: runtime,
       protocol_mode: config[:protocol_mode] || :legacy_only,
       legacy_http_sse: config[:legacy_http_sse] || false,
       sse_mode: config[:sse_mode] || :stream,
       allowed_origins: :any,
       principal_id: {Identity, :principal, []},
       tenant_id: {Identity, :tenant, []}
     )}
  end

  defp initialize(opts, context \\ []) do
    result =
      Plug.Test.conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "resource", "version" => "2"}
          }
        })
      )
      |> transport_context(context)
      |> put_req_header("content-type", "application/json")
      |> HttpPlug.call(opts)

    assert result.status == 200
    [id] = get_resp_header(result, "mcp-session-id")
    id
  end

  defp request(opts, id, method, params, context \\ []) do
    Plug.Test.conn(
      :post,
      "/mcp",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => context[:id] || System.unique_integer([:positive]) + 1_000,
        "method" => method,
        "params" => params
      })
    )
    |> transport_context(context)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> HttpPlug.call(opts)
  end

  defp notification(opts, id, method, params) do
    Plug.Test.conn(
      :post,
      "/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> HttpPlug.call(opts)
  end

  defp alias_post(opts, id, value) do
    Plug.Test.conn(:post, "/message?sessionId=" <> URI.encode_www_form(id), Jason.encode!(value))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> HttpPlug.call(opts)
  end

  defp modern(opts, method, params, id) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    value = %{"jsonrpc" => "2.0", "method" => method, "params" => Map.put(params, "_meta", meta)}
    value = if id, do: Map.put(value, "id", id), else: value

    Plug.Test.conn(:post, "/mcp", Jason.encode!(value))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> modern_name(params)
    |> HttpPlug.call(opts)
  end

  defp modern_name(conn, %{"name" => name}), do: put_req_header(conn, "mcp-name", name)
  defp modern_name(conn, _params), do: conn

  defp transport_context(conn, context) do
    conn = if context[:prefix], do: %{conn | script_name: [context[:prefix]]}, else: conn

    conn
    |> assign(:verified_principal, context[:principal])
    |> assign(:verified_tenant, context[:tenant])
  end

  defp services(runtime, id, context \\ []) do
    {:ok, resources} = Runtime.service(runtime, :resource_subscriptions)
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    metadata = %{principal_id: context[:principal], tenant_id: context[:tenant]}
    {:ok, lease} = SessionManager.ensure_session(sessions, id, metadata, [])
    {resources, sessions, lease}
  end

  defp settled(runtime, attempts \\ 200)
  defp settled(_runtime, 0), do: flunk("resource admission/IO credits did not settle")

  defp settled(runtime, attempts) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    if Runtime.stats(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0,
      do: :ok,
      else:
        (
          Process.sleep(5)
          settled(runtime, attempts - 1)
        )
  end

  defp wait(predicate, attempts \\ 200)
  defp wait(_predicate, 0), do: flunk("resource lifecycle observation did not settle")

  defp wait(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(predicate, attempts - 1)
        )
  end
end
