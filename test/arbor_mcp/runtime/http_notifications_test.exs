defmodule Arbor.MCP.Server.Runtime.HTTPNotificationsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.SubscriptionListener

  alias Arbor.MCP.Server.Runtime.{
    HTTPGateway,
    HTTPNotifications,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server.Context
    alias Arbor.MCP.Server.Runtime.HTTPNotifications
    alias Arbor.MCP.Server.Runtime.HTTPResources.Source

    def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "controls", "version" => "2"},
         "capabilities" => %{"tools" => %{}, "logging" => %{}}
       }), state}
    end

    def handle_call_tool("context", _args, state) do
      results = [
        Context.report_progress(1, 3, "working"),
        Arbor.MCP.Server.send_log_message(self(), :info, "log", %{})
      ]

      send(state.observer, {:control_results, results})
      reply(state)
    end

    def handle_call_tool("context_json", _args, state) do
      {:ok, source} = Source.capture()
      send(state.observer, {:json_progress_source, source})

      results =
        for progress <- [0, 50, 100] do
          Context.report_progress(progress, 100, "Completed step #{progress} of 100")
        end

      send(state.observer, {:control_results, results})
      reply(state)
    end

    def handle_call_tool("intent", _args, state) do
      results = [Context.report_progress(1), Context.send_log_message(:info, "log")]
      send(state.observer, {:control_results, results})
      reply(state)
    end

    def handle_call_tool("context_log_pressure", _args, state) do
      context = %{Context.current() | log_level: "info"}

      results =
        Context.with_context(context, fn ->
          [Context.send_log_message(:info, "first"), Context.send_log_message(:info, "second")]
        end)

      send(state.observer, {:control_results, results})
      reply(state)
    end

    def handle_call_tool("admission_hold", _args, state) do
      {:ok, source} = Source.capture()
      send(state.observer, {:control_source, self(), source})

      receive do
        :emit ->
          result =
            HTTPNotifications.append(source, %{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{"progressToken" => "admitted", "progress" => 1}
            })

          send(state.observer, {:control_results, [result]})
          reply(state)
      end
    end

    def handle_call_tool("casts", _args, state) do
      results = [
        Arbor.MCP.Server.notify_progress(self(), "cast", 1),
        Arbor.MCP.Server.send_log_message(self(), :info, "cast log", %{}),
        Arbor.MCP.Server.notify_roots_changed(self()),
        Arbor.MCP.Server.notify_tools_changed(self()),
        Arbor.MCP.Server.notify_prompts_changed(self()),
        Arbor.MCP.Server.notify_resources_changed(self()),
        Arbor.MCP.Server.notify_resource_update(self(), "test://uri")
      ]

      send(state.observer, {:control_results, results})
      reply(state)
    end

    def handle_call_tool("invalid", _args, state) do
      result = Arbor.MCP.Server.send_log_message(self(), :info, "private", %{"pid" => self()})
      send(state.observer, {:control_results, [result]})
      reply(state)
    end

    def handle_call_tool("topic", _args, state) do
      result = Arbor.MCP.Server.notify_tools_changed(self())
      send(state.observer, {:control_results, [result]})
      reply(state)
    end

    def handle_call_tool("wrong_root", _args, state) do
      send(state.observer, {:control_worker, self()})

      receive do
        {:other, runtime} ->
          result = Arbor.MCP.Server.notify_progress(runtime, "wrong", 1)
          send(state.observer, {:control_results, [result]})
          reply(state)
      end
    end

    def handle_call_tool("accepted_hold", _args, state) do
      result = Arbor.MCP.Server.notify_progress(self(), "entered", 1)
      send(state.observer, {:entered_control, self(), result})

      receive do
        :finish -> reply(state)
      end
    end

    def handle_call_tool("hold", _args, state) do
      {:ok, source} = Source.capture()
      send(state.observer, {:control_source, self(), source})

      receive do
        :emit ->
          result = Arbor.MCP.Server.notify_progress(self(), "held", 1)
          send(state.observer, {:control_results, [result]})
          reply(state)
      end
    end

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}

    defp reply(state),
      do: {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
  end

  test "legacy request context durably accepts progress and log before its final replay reply" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    {_writer, _binding} = live_get(runtime, lease)
    assert %{status: 202} = alias_post(opts, id, tool(2, "context", requested_meta()))
    assert_receive {:control_results, [:ok, :ok]}
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])

    assert [
             %{"id" => 1},
             %{
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "requested", "progress" => 1, "total" => 3}
             },
             %{"method" => "notifications/message"},
             %{"id" => 2, "result" => %{}}
           ] = Enum.map(events, & &1.data)

    settled(runtime)
  end

  test "legacy JSON Context progress appends to its exact live GET and keeps the final JSON response" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)

    response = primary_post(opts, id, tool(2, "context_json", requested_meta()))
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(response.resp_body) == %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{"content" => []}
           }

    assert_receive {:control_results, [:ok, :ok, :ok]}, 1_000
    assert_receive {:json_progress_source, source}, 1_000
    assert Source.runtime(source) == runtime
    assert Source.lease(source) == lease

    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert [%{"id" => 1} | progress] = Enum.map(events, & &1.data)
    assert Enum.map(progress, & &1["params"]["progress"]) == [0, 50, 100]

    assert Enum.all?(progress, fn message ->
             message["method"] == "notifications/progress" and
               message["params"]["progressToken"] == "requested" and
               message["params"]["total"] == 100
           end)

    refute Enum.any?(events, &(&1.data["id"] == 2))
    settled(runtime)
    assert_no_io_credit(runtime)

    peek = primary_post(opts, id, tool(3, "peek"))
    assert Jason.decode!(peek.resp_body)["result"]["structuredContent"]["calls"] == 1
  end

  test "legacy JSON Context progress cannot fall back to another session's live GET" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    {_other_id, _same_sessions, other_lease} = initialize_alias(runtime, opts)
    live_get(runtime, other_lease)

    response = primary_post(opts, id, tool(2, "context_json", requested_meta()))
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]

    assert_receive {:control_results,
                    [{:error, :stream_closed}, {:error, :stream_closed}, {:error, :stream_closed}]},
                   1_000

    for current <- [lease, other_lease] do
      assert {:ok, %{events: [%{data: %{"id" => 1}}]}} =
               SessionManager.replay_page(sessions, current, nil, [])
    end

    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(sessions, [])
    settled(runtime)
    assert_no_io_credit(runtime)
  end

  test "a dead borrowed GET does not claim legacy JSON Context progress or retain phantom IO" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    {writer, _binding} = live_get(runtime, lease)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, 1_000

    response = primary_post(opts, id, tool(2, "context_json", requested_meta()))
    assert response.status == 200

    assert_receive {:control_results,
                    [{:error, :stream_closed}, {:error, :stream_closed}, {:error, :stream_closed}]},
                   1_000

    assert {:ok, %{events: [%{data: %{"id" => 1}}]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(sessions, [])
    settled(runtime)
    assert_no_io_credit(runtime)
  end

  test "stateless modern JSON does not borrow an available legacy session GET for Context progress" do
    {runtime, opts} = host()
    {_id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    request = modern(tool(2, "context_json"))
    request = put_in(request, ["params", "_meta", "progressToken"], "requested")

    response =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "context_json")
      |> HttpPlug.call(Map.put(opts, :protocol_mode, :modern_only))

    assert response.status == 200
    assert get_resp_header(response, "mcp-session-id") == []
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]

    assert_receive {:control_results,
                    [
                      {:error, :request_not_streaming},
                      {:error, :request_not_streaming},
                      {:error, :request_not_streaming}
                    ]},
                   1_000

    assert {:ok, %{events: [%{data: %{"id" => 1}}]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    settled(runtime)
    assert_no_io_credit(runtime)
  end

  test "retained Server control casts target the addressed live session rather than the singleton edge" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 202} = alias_post(opts, id, tool(2, "casts"))
    assert_receive {:control_results, results}
    assert results == List.duplicate(:ok, 7)
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    notifications = events |> Enum.map(& &1.data) |> Enum.filter(&Map.has_key?(&1, "method"))

    assert Enum.map(notifications, & &1["method"]) == [
             "notifications/progress",
             "notifications/message",
             "notifications/roots/list_changed",
             "notifications/tools/list_changed",
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/resources/updated"
           ]

    refute Map.has_key?(hd(notifications)["params"], "total")
    assert List.last(events).data["id"] == 2
    settled(runtime)
  end

  test "JSON callbacks can address the same session GET without making a request-owned stream" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 200} = primary_post(opts, id, tool(2, "casts"))
    assert_receive {:control_results, results}
    assert results == List.duplicate(:ok, 7)
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert length(events) == 8
    refute Enum.any?(events, &(&1.data["id"] == 2))
    settled(runtime)
  end

  test "offline sessions do not claim live progress delivery or fall back to another session" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    {_other, _other_sessions, other_lease} = initialize_alias(runtime, opts)
    live_get(runtime, other_lease)
    assert %{status: 202} = alias_post(opts, id, tool(2, "context", requested_meta()))
    assert_receive {:control_results, [{:error, :stream_closed}, {:error, :stream_closed}]}
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert Enum.map(events, & &1.data["id"]) == [1, 2]
    settled(runtime)
  end

  test "missing progress and log intent remain explicit instead of accepting unwanted notifications" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 202} = alias_post(opts, id, tool(2, "intent"))

    assert_receive {:control_results,
                    [{:error, :progress_not_requested}, {:error, :logging_not_requested}]}

    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert Enum.map(events, & &1.data["id"]) == [1, 2]
    settled(runtime)
  end

  test "opaque nested data fails before replay publication without arbitrary encoders" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 202} = alias_post(opts, id, tool(2, "invalid"))
    assert_receive {:control_results, [{:error, :event_not_json_encodable}]}
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert Enum.map(events, & &1.data["id"]) == [1, 2]
    settled(runtime)
  end

  test "a copied source cannot impersonate the actual callback producer" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> primary_post(opts, id, tool(2, "hold")) end)
    assert_receive {:control_source, worker, source}
    assert {:error, :stream_closed} = HTTPNotifications.append(source, notification())
    send(worker, :emit)
    assert_receive {:control_results, [:ok]}
    assert %{status: 200} = Task.await(caller)

    assert {:ok, %{events: [_init, progress]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    assert progress.data["method"] == "notifications/progress"
    settled(runtime)
  end

  test "session retirement prevents a held actual Task from appending into a recreated epoch" do
    {runtime, opts} = host()
    {id, sessions, old} = initialize_alias(runtime, opts)
    live_get(runtime, old)

    caller =
      Task.async(fn ->
        try do
          primary_post(opts, id, tool(2, "hold"))
        rescue
          Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError -> :retired_response
        end
      end)

    assert_receive {:control_source, worker, _source}
    assert :ok = SessionManager.terminate_session(sessions, old, [])

    assert {:ok, fresh} =
             SessionManager.create_session(sessions, %{transport_endpoint: "/mcp"},
               session_id: id
             )

    send(worker, :emit)
    assert_receive {:control_results, [{:error, :resource_source_retired}]}
    assert :retired_response = Task.await(caller)
    assert {:ok, %{events: []}} = SessionManager.replay_page(sessions, fresh, nil, [])
    settled(runtime)
  end

  test "request cancellation invalidates source authority before the held Task can publish" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> primary_post(opts, id, tool(2, "hold")) end)
    assert_receive {:control_source, worker, source}
    monitor = Process.monitor(worker)

    cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 2}
    }

    assert %{status: 202} = primary_post(opts, id, cancel)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    response = Task.await(caller)
    assert Jason.decode!(response.resp_body)["error"]["code"] == -32001
    refute Source.current?(source)
    assert {:ok, %{events: [_init]}} = SessionManager.replay_page(sessions, lease, nil, [])
    settled(runtime)
  end

  test "a durable notification accepted before cancellation is not rolled back or retried" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> primary_post(opts, id, tool(2, "accepted_hold")) end)
    assert_receive {:entered_control, worker, :ok}
    monitor = Process.monitor(worker)

    cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 2}
    }

    assert %{status: 202} = primary_post(opts, id, cancel)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    response = Task.await(caller)
    assert Jason.decode!(response.resp_body)["error"]["code"] == -32001
    peek = primary_post(opts, id, tool(3, "peek"))
    assert Jason.decode!(peek.resp_body)["result"]["structuredContent"]["calls"] == 0

    assert {:ok, %{events: [_init, progress]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    assert progress.data["params"]["progressToken"] == "entered"
    settled(runtime)
  end

  test "entered notifications remain durable when final output capacity prevents handler state commit" do
    {runtime, opts} = host(session_limits: [max_events: 3])
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 500} = alias_post(opts, id, tool(2, "casts"))
    assert_receive {:control_results, [:ok, :ok | rejected]}
    assert rejected == List.duplicate({:error, :replay_capacity_exhausted}, 5)
    assert {:ok, %{events: events}} = SessionManager.replay_page(sessions, lease, nil, [])

    assert [
             %{"id" => 1},
             %{"method" => "notifications/progress"},
             %{"method" => "notifications/message"}
           ] =
             Enum.map(events, & &1.data)

    peek = primary_post(opts, id, tool(3, "peek"))
    assert Jason.decode!(peek.resp_body)["result"]["structuredContent"]["calls"] == 0

    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(sessions, [])
    settled(runtime)
  end

  test "Context log intent preserves typed replay pressure without committing handler state" do
    {runtime, opts} = host(session_limits: [max_events: 2])
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    assert %{status: 500} = alias_post(opts, id, tool(2, "context_log_pressure"))
    assert_receive {:control_results, [:ok, {:error, :replay_capacity_exhausted}]}
    assert {:ok, %{events: [_init, log]}} = SessionManager.replay_page(sessions, lease, nil, [])
    assert log.data["method"] == "notifications/message"
    assert log.data["params"]["data"] == "first"

    peek = primary_post(opts, id, tool(3, "peek"))
    assert Jason.decode!(peek.resp_body)["result"]["structuredContent"]["calls"] == 0
    assert {:ok, %{pending_events: 0}} = SessionManager.get_stats(sessions, [])
    settled(runtime)
  end

  test "an admitted replay append survives GET retirement while its original source remains live" do
    {runtime, opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    {writer, binding} = live_get(runtime, lease)
    caller = Task.async(fn -> primary_post(opts, id, tool(2, "admission_hold")) end)
    assert_receive {:control_source, worker, _source}
    {:ok, service} = Arbor.MCP.Server.Runtime.Services.resolve(sessions, :sessions)
    :ok = :sys.suspend(service.server)

    try do
      send(worker, :emit)

      eventually(fn ->
        Enum.find(Arbor.MCP.Server.Runtime.ServiceOperation.entries(service.address), fn
          {_token, %{owner: ^worker, payload: {:http_callback_append, _args, _context}}} -> true
          _other -> false
        end)
      end)

      assert :ok = writer_call(writer, fn -> HTTPWriterRegistry.retire(binding) end)
      assert Process.alive?(writer)
    after
      :ok = :sys.resume(service.server)
    end

    assert_receive {:control_results, [:ok]}
    assert %{status: 200} = Task.await(caller)

    assert {:ok, %{events: [_init, progress]}} =
             SessionManager.replay_page(sessions, lease, nil, [])

    assert progress.data["params"]["progressToken"] == "admitted"
    settled(runtime)
  end

  test "an HTTP callback cannot redirect a control to a different runtime" do
    {runtime, opts} = host()
    {other, _other_opts} = host()
    {id, sessions, lease} = initialize_alias(runtime, opts)
    live_get(runtime, lease)
    caller = Task.async(fn -> primary_post(opts, id, tool(2, "wrong_root")) end)
    assert_receive {:control_worker, worker}
    send(worker, {:other, other})
    assert_receive {:control_results, [{:error, :wrong_runtime}]}
    assert %{status: 200} = Task.await(caller)
    assert {:ok, %{events: [_init]}} = SessionManager.replay_page(sessions, lease, nil, [])
    settled(runtime)
    settled(other)
  end

  test "non-HTTP helpers retain bounded native edge controls" do
    {:ok, root} =
      Arbor.MCP.Server.HandlerServer.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        transport: :test
      )

    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:ok, _transport} = Arbor.MCP.Transport.Test.connect(server: root)
    assert :ok = Arbor.MCP.Server.notify_progress(root, "native", 1)
    assert_receive {:transport_message, encoded}
    assert Jason.decode!(encoded)["params"]["progressToken"] == "native"
    {:ok, runtime} = Runtime.ref(root)
    settled(runtime)
  end

  test "modern Server topic casts use the runtime-scoped listener publication path" do
    {runtime, opts} = host(protocol_mode: :modern_only, subscriptions: true)
    writer = subscription_writer()
    {:ok, binding} = writer_call(writer, fn -> HTTPWriterProxy.capture(runtime) end)

    request =
      modern(%{
        "jsonrpc" => "2.0",
        "id" => 91,
        "method" => "subscriptions/listen",
        "params" => %{"notifications" => %{"toolsListChanged" => true}}
      })

    assert {:ok, _token} =
             writer_call(writer, fn ->
               HTTPGateway.submit(runtime, binding, request,
                 dispatch_opts: [endpoint: "/mcp", protocol_mode: :modern_only]
               )
             end)

    {:listener, listener, pid, _registration} =
      eventually(fn ->
        case writer_call(writer, fn -> HTTPWriterRegistry.listener_setup(binding) end) do
          :empty -> nil
          value -> value
        end
      end)

    assert_receive {:subscription_ready, ^writer, ^pid, id, cutoff}

    assert {:ok, :acknowledged, _message, _origin} =
             writer_call(writer, fn ->
               SubscriptionListener.checkout_http(pid, id, listener, cutoff)
             end)

    assert :ok =
             writer_call(writer, fn -> SubscriptionListener.delivered_http(pid, id, listener) end)

    value = modern(tool(2, "topic"))

    response =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(value))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "topic")
      |> HttpPlug.call(opts)

    assert response.status == 200
    assert get_resp_header(response, "mcp-session-id") == []
    assert_receive {:control_results, [:ok]}
    assert_receive {:subscription_ready, ^writer, ^pid, delivery, deadline}

    assert {:ok, :notification, %{"method" => "notifications/tools/list_changed"}, _origin} =
             writer_call(writer, fn ->
               SubscriptionListener.checkout_http(pid, delivery, listener, deadline)
             end)

    assert :ok =
             writer_call(writer, fn ->
               SubscriptionListener.delivered_http(pid, delivery, listener)
             end)

    SubscriptionListener.cancel(pid)
    settled(runtime)
  end

  defp host(options \\ []) do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        request_timeout_ms: 2_000,
        services: services(options)
      )

    {:ok, runtime} = Runtime.ref(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)

    {runtime,
     HttpPlug.init(
       runtime: runtime,
       protocol_mode: options[:protocol_mode] || :legacy_only,
       legacy_http_sse: true,
       sse_mode: :oneshot,
       allowed_origins: :any
     )}
  end

  defp services(options) do
    sessions = [sessions: [options: options[:session_limits] || []]]
    if options[:subscriptions], do: sessions ++ [subscriptions: []], else: sessions
  end

  defp subscription_writer do
    parent = self()
    writer = spawn(fn -> subscription_writer_loop(parent) end)
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    writer
  end

  defp subscription_writer_loop(parent) do
    receive do
      {:operation, from, token, operation} ->
        send(from, {token, operation.()})
        subscription_writer_loop(parent)

      {:ex_mcp_subscription_ready, pid, id, cutoff} ->
        send(parent, {:subscription_ready, self(), pid, id, cutoff})
        subscription_writer_loop(parent)

      {:mcp_http_output_wake, domain, nonce} ->
        HTTPWriterRegistry.acknowledge_wake(domain, nonce)
        subscription_writer_loop(parent)

      _notice ->
        subscription_writer_loop(parent)
    end
  end

  defp initialize_alias(runtime, opts) do
    hello = Plug.Test.conn(:get, "/sse") |> HttpPlug.call(opts)
    [_, endpoint] = Regex.run(~r/event: endpoint\ndata: ([^\n]+)/, hello.resp_body)
    id = URI.decode_query(URI.parse(endpoint).query)["sessionId"]

    params = %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "control", "version" => "2"}
    }

    assert %{status: 202} =
             alias_post(opts, id, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => params
             })

    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_session(sessions, id, %{}, [])
    {id, sessions, lease}
  end

  defp live_get(runtime, lease) do
    writer = spawn(fn -> writer_loop() end)
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    {:ok, binding} = writer_call(writer, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = writer_call(writer, fn -> HTTPWriterRegistry.bind_lease(binding, lease) end)

    assert :ok =
             writer_call(writer, fn -> HTTPWriterRegistry.register_session_stream(binding) end)

    {writer, binding}
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

  defp writer_call(writer, operation) do
    token = make_ref()
    send(writer, {:operation, self(), token, operation})

    receive do
      {^token, result} -> result
    after
      1_000 -> flunk("fake writer operation did not complete")
    end
  end

  defp alias_post(opts, id, value),
    do: post(opts, "/message?sessionId=" <> URI.encode_www_form(id), value, nil)

  defp primary_post(opts, id, value), do: post(opts, "/mcp", value, id)

  defp post(opts, path, value, session) do
    conn =
      Plug.Test.conn(:post, path, Jason.encode!(value))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    HttpPlug.call(conn, opts)
  end

  defp tool(id, name, meta \\ %{}),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}, "_meta" => meta}
    }

  defp requested_meta,
    do: %{"progressToken" => "requested", "io.modelcontextprotocol/logLevel" => "info"}

  defp notification,
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => "forged", "progress" => 1}
    }

  defp modern(value),
    do:
      put_in(value, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

  defp eventually(operation, attempts \\ 200)
  defp eventually(_operation, 0), do: flunk("listener setup did not settle")

  defp eventually(operation, attempts) do
    case operation.() do
      nil ->
        Process.sleep(5)
        eventually(operation, attempts - 1)

      value ->
        value
    end
  end

  defp assert_no_io_credit(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    assert %{frames: 0, bytes: 0} = HTTPWriterRegistry.stats(domain)
    assert match?(%{reserved: 0, response_bytes: 0}, Runtime.stats!(runtime))
  end

  defp settled(runtime, attempts \\ 200)
  defp settled(_runtime, 0), do: flunk("control admission/IO did not settle")

  defp settled(runtime, attempts) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    if Runtime.stats!(runtime).reserved == 0 and HTTPWriterRegistry.stats(domain).frames == 0 do
      :ok
    else
      Process.sleep(5)
      settled(runtime, attempts - 1)
    end
  end
end
