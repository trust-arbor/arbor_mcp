defmodule Arbor.MCP.Server.HandlerServerSubscriptionsTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Runtime, Subscriptions}
  alias Arbor.MCP.Server.Runtime.Ref

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    defoverridable handle_call: 3

    @impl true
    def init(_opts), do: {:ok, %{list_calls: 0}}

    def handle_call(:list_calls, _from, state), do: {:reply, state.list_calls, state}

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, Map.update!(state, :list_calls, &(&1 + 1))}
    end
  end

  test "listen remains open while correlated notifications flow over the test transport" do
    server = start_server()
    {:ok, registry} = Runtime.service(server, :subscriptions)
    connect(server)

    send_request(server, listen_request(71, %{"toolsListChanged" => true}))

    assert_receive {:transport_message, encoded_ack}, 1_000
    acknowledged = Jason.decode!(encoded_ack)
    assert acknowledged["method"] == "notifications/subscriptions/acknowledged"
    assert acknowledged["params"]["_meta"][@subscription_id_key] == 71
    assert acknowledged["params"]["notifications"] == %{"toolsListChanged" => true}
    refute Map.has_key?(acknowledged, "id")

    {:ok, edge} = Arbor.MCP.Server.Runtime.edge(server)

    assert [%{subscription_id: 71, transport_ref: ^edge}] =
             Subscriptions.entries(service: registry)

    :ok = Server.notify_tools_changed(server)

    assert_receive {:transport_message, encoded_notification}, 1_000
    notification = Jason.decode!(encoded_notification)
    assert notification["method"] == "notifications/tools/list_changed"
    assert notification["params"]["_meta"][@subscription_id_key] == 71

    :ok = Server.notify_prompts_changed(server)
    refute_receive {:transport_message, _unrequested}

    assert :ok = Subscriptions.close(edge, 71, :test_complete, service: registry)

    assert_receive {:transport_message, encoded_complete}, 1_000
    completed = Jason.decode!(encoded_complete)
    assert completed["id"] == 71
    assert completed["result"]["resultType"] == "complete"
    assert completed["result"]["_meta"][@subscription_id_key] == 71
  end

  test "stdio-style cancellation removes the long-lived request without a completion response" do
    server = start_server()
    {:ok, registry} = Runtime.service(server, :subscriptions)
    connect(server)

    send_request(
      server,
      listen_request(72, %{"resourceSubscriptions" => ["test://watched"]})
    )

    assert_receive {:transport_message, _encoded_ack}, 1_000

    cancellation = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 72, "reason" => "no longer needed"}
    }

    send_request(server, cancellation)
    assert_eventually(fn -> Subscriptions.entries(service: registry) == [] end)
    refute_receive {:transport_message, _completion}
  end

  test "invalid filters produce a finite JSON-RPC error instead of opening a stream" do
    server = start_server()
    {:ok, registry} = Runtime.service(server, :subscriptions)
    connect(server)

    send_request(server, listen_request(73, %{"toolsListChanged" => "yes"}))

    assert_receive {:transport_message, encoded_error}, 1_000
    error = Jason.decode!(encoded_error)
    assert error["id"] == 73
    assert error["error"]["code"] == -32602
    assert error["error"]["message"] == "Subscription request rejected"
    assert Subscriptions.entries(service: registry) == []
  end

  test "request-scoped notifications are not stamped as subscription events" do
    server = start_server()
    connect(server)

    send_request(server, listen_request(74, %{"toolsListChanged" => true}))
    assert_receive {:transport_message, _encoded_ack}, 1_000

    :ok = Server.notify_progress(server, "request-progress", 1, 2)

    assert_receive {:transport_message, encoded_progress}, 1_000
    progress = Jason.decode!(encoded_progress)
    assert progress["method"] == "notifications/progress"
    assert progress["params"]["progressToken"] == "request-progress"
    refute get_in(progress, ["params", "_meta", @subscription_id_key])
  end

  test "the process lifetime rejects a duplicate request ID before handler dispatch" do
    server = start_server()
    connect(server)

    request = tools_list_request(81)
    send_request(server, request)
    assert_receive {:transport_message, first_response}, 1_000
    assert %{"id" => 81, "result" => %{"tools" => []}} = Jason.decode!(first_response)

    send_request(server, request)
    assert_receive {:transport_message, duplicate_response}, 1_000

    assert %{
             "id" => 81,
             "error" => %{
               "code" => -32600,
               "data" => %{"type" => "duplicate_request_id"}
             }
           } = Jason.decode!(duplicate_response)

    assert Server.call(server, :list_calls) == 1
  end

  test "the process lifetime fails closed when request ID storage reaches its cap" do
    server = start_server(max_request_ids: 1)
    connect(server)

    send_request(server, tools_list_request(82))
    assert_receive {:transport_message, first_response}, 1_000
    assert %{"id" => 82, "result" => %{"tools" => []}} = Jason.decode!(first_response)

    send_request(server, tools_list_request(83))
    assert_receive {:transport_message, capacity_response}, 1_000

    assert %{
             "id" => 83,
             "error" => %{
               "code" => -32600,
               "data" => %{"type" => "request_id_capacity_exceeded", "limit" => 1}
             }
           } = Jason.decode!(capacity_response)

    assert Server.call(server, :list_calls) == 1
  end

  test "BEAM-local transport shares the same process-lifetime duplicate guard" do
    server = start_server(transport: :beam)
    connect(server)

    request = tools_list_request("beam-duplicate")
    send_request(server, request)

    assert Server.call(server, :list_calls) == 1

    assert_receive {:transport_message,
                    %{"id" => "beam-duplicate", "result" => %{"tools" => []}}},
                   1_000

    send_request(server, request)

    assert Server.call(server, :list_calls) == 1

    assert_receive {:transport_message,
                    %{
                      "id" => "beam-duplicate",
                      "error" => %{
                        "code" => -32600,
                        "data" => %{"type" => "duplicate_request_id"}
                      }
                    }},
                   1_000
  end

  test "an admitted subscription that expires behind a suspended edge never creates a listener" do
    server = start_server(request_timeout_ms: 40)
    {:ok, registry} = Runtime.service(server, :subscriptions)
    connect(server)
    {:ok, edge} = Runtime.edge(server)
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    send_request(server, listen_request(91, %{"toolsListChanged" => true}))
    Process.sleep(60)
    assert %{reserved: 1} = Runtime.stats!(server)
    assert Subscriptions.entries(service: registry) == []
    :sys.resume(edge)
    assert_receive {:transport_message, encoded_error}, 1_000

    assert %{"id" => 91, "error" => %{"data" => %{"type" => "handler_timeout"}}} =
             Jason.decode!(encoded_error)

    assert_eventually(fn -> Runtime.stats!(server).reserved == 0 end)
    assert Subscriptions.entries(service: registry) == []
    refute_receive {:transport_message, _late_ack}, 30
  end

  test "queued retired listener events and mirrored indexes cannot cross peer replacement" do
    server = start_server()
    {:ok, registry} = Runtime.service(server, :subscriptions)
    connect(server)
    send_request(server, listen_request(92, %{"toolsListChanged" => true}))
    assert_receive {:transport_message, _ack}, 1_000
    {:ok, runtime} = Runtime.ref(server)
    {:ok, edge} = Runtime.edge(server)

    [{:edge_connection, ^edge, old_connection}] =
      :ets.lookup(Ref.table(runtime), :edge_connection)

    [entry] = Subscriptions.entries(service: registry)
    listener = :sys.get_state(edge).subscriptions[92]
    assert entry.transport_ref == edge
    :sys.suspend(edge)
    on_exit(fn -> if Process.alive?(edge), do: :sys.resume(edge) end)
    parent = self()

    peer =
      spawn(fn ->
        result = HandlerServer.connect(server, self())
        send(parent, {:replacement_connected, self(), result})

        receive do
          {:transport_message, message} -> send(parent, {:replacement_message, message})
        end
      end)

    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)

    assert_eventually(fn ->
      {:messages, messages} = Process.info(edge, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:runtime_peer_connect, ^peer}}, &1))
    end)

    send(
      edge,
      {:ex_mcp_subscription_message, listener, :notification,
       %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}}
    )

    :sys.resume(edge)
    assert_receive {:replacement_connected, ^peer, {:ok, ^edge, ^runtime, _connection}}, 1_000
    refute_receive {:replacement_message, _retired_event}, 30
    refute :ets.member(Ref.table(runtime), {:subscription, old_connection, 92})
    assert_eventually(fn -> Subscriptions.entries(service: registry) == [] end)
  end

  defp start_server(extra_opts \\ []) do
    opts =
      [
        handler: Handler,
        transport: :test,
        protocol_mode: :modern_only,
        services: [subscriptions: [options: [max_lifetime_ms: 5_000]]],
        principal_id: "principal-1",
        tenant_id: "tenant-1",
        authorize_subscription_filter: fn requested, _context -> {:ok, requested} end,
        authorize_subscription_publication: fn _method, _params, _context -> true end
      ]
      |> Keyword.merge(extra_opts)

    start_supervised!({HandlerServer, opts})
  end

  defp connect(server) do
    {:ok, edge, runtime, connection} = HandlerServer.connect(server, self())
    Process.put({__MODULE__, server}, {edge, runtime, connection})
  end

  defp send_request(server, request) do
    {edge, runtime, connection} = Process.get({__MODULE__, server})
    assert :ok = HandlerServer.ingress(runtime, edge, connection, request)
  end

  defp listen_request(id, filter) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "subscription-test",
            "version" => "1"
          }
        },
        "notifications" => filter
      }
    }
  end

  defp tools_list_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "request-id-test",
            "version" => "1"
          }
        }
      }
    }
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
