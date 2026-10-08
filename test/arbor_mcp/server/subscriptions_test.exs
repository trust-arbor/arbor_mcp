defmodule Arbor.MCP.Server.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Subscriptions
  alias Arbor.MCP.Server.Subscriptions.PubSub
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.{Extension, Store}

  defmodule RejectingAdapter do
    @behaviour Arbor.MCP.Server.Subscriptions.Adapter

    @impl true
    def init(test_pid: test_pid), do: {:ok, test_pid}

    @impl true
    def put(entry, test_pid) do
      send(test_pid, {:listener_started, entry.listener_pid})
      {:error, :storage_unavailable, test_pid}
    end

    @impl true
    def delete(_token, test_pid), do: {:ok, test_pid}

    @impl true
    def all(test_pid), do: {[], test_pid}
  end

  defmodule TestPubSub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def subscribe(server, topic), do: GenServer.call(server, {:subscribe, topic})

    def broadcast_from(server, from, topic, message) do
      GenServer.call(server, {:broadcast_from, from, topic, message})
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:subscribe, topic}, {subscriber, _tag}, state) do
      subscribers =
        Map.update(state, topic, MapSet.new([subscriber]), &MapSet.put(&1, subscriber))

      {:reply, :ok, subscribers}
    end

    def handle_call({:broadcast_from, from, topic, message}, _caller, state) do
      state
      |> Map.get(topic, MapSet.new())
      |> Enum.reject(&(&1 == from))
      |> Enum.each(&send(&1, message))

      {:reply, :ok, state}
    end
  end

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  test "acknowledges first, stamps correlation metadata, and filters publications" do
    registry = start_registry()

    assert {:ok, entry} =
             Subscriptions.listen(
               41,
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["test://one"]
               },
               self(),
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, acknowledged}
    assert listener == entry.listener_pid

    assert acknowledged["method"] == "notifications/subscriptions/acknowledged"
    assert acknowledged["params"]["_meta"][@subscription_id_key] == 41
    assert acknowledged["params"]["notifications"] == entry.filter

    assert %{subscribers: 1, enqueued: 1} =
             publish(registry, "notifications/tools/list_changed")

    assert %{subscribers: 1, enqueued: 1} =
             publish(registry, "notifications/resources/updated", %{"uri" => "test://one"})

    assert %{subscribers: 0} =
             publish(registry, "notifications/resources/updated", %{"uri" => "test://other"})

    assert %{subscribers: 0} =
             publish(registry, "notifications/prompts/list_changed")

    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _message}

    Subscriptions.delivered(listener)

    assert_receive {:ex_mcp_subscription_message, ^listener, :notification, tools_changed}
    assert tools_changed["method"] == "notifications/tools/list_changed"
    assert tools_changed["params"]["_meta"][@subscription_id_key] == 41

    Subscriptions.delivered(listener)

    assert_receive {:ex_mcp_subscription_message, ^listener, :notification, resource_updated}
    assert resource_updated["params"]["uri"] == "test://one"
    assert resource_updated["params"]["_meta"][@subscription_id_key] == 41
  end

  test "authorization narrows the acknowledged filter and is rechecked for every publication" do
    gate = :atomics.new(1, signed: false)
    :atomics.put(gate, 1, 1)

    registry =
      start_registry(
        authorize_filter: fn requested, context ->
          assert context.principal_id == "principal-1"
          {:ok, Map.take(requested, ["resourceSubscriptions"])}
        end,
        authorize_publication: fn _method, _params, context ->
          context.principal_id == "principal-1" and :atomics.get(gate, 1) == 1
        end
      )

    assert {:ok, entry} =
             Subscriptions.listen(
               "subscription-a",
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["test://private"]
               },
               self(),
               registry: registry,
               principal_id: "principal-1",
               tenant_id: "tenant-1"
             )

    assert entry.filter == %{"resourceSubscriptions" => ["test://private"]}
    assert entry.principal_id == "principal-1"
    assert entry.tenant_id == "tenant-1"

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, acknowledged}
    assert acknowledged["params"]["notifications"] == entry.filter
    Subscriptions.delivered(listener)

    :atomics.put(gate, 1, 0)

    assert %{subscribers: 1, closed: 1} =
             publish(
               registry,
               "notifications/resources/updated",
               %{"uri" => "test://private"}
             )

    assert_receive {:ex_mcp_subscription_message, ^listener, :complete, completed}
    assert completed["id"] == "subscription-a"
    assert completed["result"]["_meta"][@subscription_id_key] == "subscription-a"
  end

  test "PubSub adapter fans publications out to remote registries and rechecks authorization" do
    pubsub = start_supervised!({TestPubSub, []}, id: make_ref())
    topic = "subscriptions:#{System.unique_integer([:positive])}"

    adapter =
      {PubSub, pubsub_server: pubsub, pubsub_module: TestPubSub, topic: topic}

    registry_a = start_registry(adapter: adapter)

    gate = :atomics.new(1, signed: false)
    :atomics.put(gate, 1, 1)

    registry_b =
      start_registry(
        adapter: adapter,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, context ->
          context.principal_id == "principal-b" and :atomics.get(gate, 1) == 1
        end
      )

    assert {:ok, entry} =
             Subscriptions.listen(
               "remote-listener",
               %{"toolsListChanged" => true},
               self(),
               registry: registry_b,
               principal_id: "principal-b",
               tenant_id: "tenant-b"
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}
    Subscriptions.delivered(listener)

    assert %{subscribers: 0, enqueued: 0} =
             publish(registry_a, "notifications/tools/list_changed")

    assert_receive {:ex_mcp_subscription_message, ^listener, :notification, notification}
    assert notification["params"]["_meta"][@subscription_id_key] == entry.subscription_id
    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _duplicate}, 25

    Subscriptions.delivered(listener)
    :atomics.put(gate, 1, 0)

    assert %{subscribers: 0} = publish(registry_a, "notifications/tools/list_changed")
    assert_receive {:ex_mcp_subscription_message, ^listener, :complete, _completed}
    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _unauthorized}, 25
  end

  test "enforces global, principal, and tenant listener limits atomically" do
    registry =
      start_registry(
        max_global: 3,
        max_per_principal: 1,
        max_per_tenant: 2,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, _context -> true end
      )

    assert {:ok, _entry} =
             listen(registry, 1, principal_id: "p1", tenant_id: "shared")

    assert {:error, {:subscription_limit_exceeded, :principal}} =
             listen(registry, 2, principal_id: "p1", tenant_id: "shared")

    assert {:ok, _entry} =
             listen(registry, 3, principal_id: "p2", tenant_id: "shared")

    assert {:error, {:subscription_limit_exceeded, :tenant}} =
             listen(registry, 4, principal_id: "p3", tenant_id: "shared")

    assert {:ok, _entry} =
             listen(registry, 5, principal_id: "p3", tenant_id: "other")

    assert {:error, {:subscription_limit_exceeded, :global}} =
             listen(registry, 6, principal_id: "p4", tenant_id: "other-2")
  end

  test "coalesces safe updates and closes a listener whose bounded queue overflows" do
    registry =
      start_registry(
        max_queue: 1,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, _context -> true end
      )

    assert {:ok, entry} =
             Subscriptions.listen(
               9,
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["test://one"]
               },
               self(),
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}

    assert %{enqueued: 1} =
             publish(registry, "notifications/resources/updated", %{"uri" => "test://one"})

    assert %{coalesced: 1} =
             publish(registry, "notifications/resources/updated", %{"uri" => "test://one"})

    assert %{closed: 1} = publish(registry, "notifications/tools/list_changed")

    Subscriptions.delivered(listener)
    assert_receive {:ex_mcp_subscription_message, ^listener, :complete, completed}
    assert completed["id"] == entry.subscription_id
    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _message}
  end

  test "accepts a message at the encoded byte cap and closes at one byte over" do
    subscription_id = "message-byte-cap"
    uri = "test://byte-cap"
    payload = String.duplicate("x", 1_024)
    exact_params = %{"uri" => uri, "value" => payload}
    one_over_params = %{"uri" => uri, "value" => payload <> "x"}
    exact_bytes = notification_bytes(subscription_id, exact_params)

    assert notification_bytes(subscription_id, one_over_params) == exact_bytes + 1

    registry =
      start_registry(
        max_queue: 10,
        max_message_bytes: exact_bytes,
        max_queue_bytes: exact_bytes * 2,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, _context -> true end
      )

    assert {:ok, _entry} =
             Subscriptions.listen(
               subscription_id,
               %{"resourceSubscriptions" => [uri]},
               self(),
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}
    assert %{enqueued: 1} = publish(registry, "notifications/resources/updated", exact_params)

    assert %{closed: 1} =
             publish(registry, "notifications/resources/updated", one_over_params)

    Subscriptions.delivered(listener)
    assert_receive {:ex_mcp_subscription_message, ^listener, :complete, _completed}
    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _message}
  end

  test "accounts coalesced queue bytes and closes when a replacement is one byte over budget" do
    subscription_id = "queue-byte-cap"
    uri = "test://queue-byte-cap"
    payload = String.duplicate("x", 1_024)
    exact_params = %{"uri" => uri, "value" => payload}
    one_over_params = %{"uri" => uri, "value" => payload <> "x"}
    exact_bytes = notification_bytes(subscription_id, exact_params)

    assert notification_bytes(subscription_id, one_over_params) == exact_bytes + 1

    registry =
      start_registry(
        max_queue: 10,
        max_message_bytes: exact_bytes + 1,
        max_queue_bytes: exact_bytes,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, _context -> true end
      )

    assert {:ok, _entry} =
             Subscriptions.listen(
               subscription_id,
               %{"resourceSubscriptions" => [uri]},
               self(),
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}
    assert %{enqueued: 1} = publish(registry, "notifications/resources/updated", exact_params)

    assert %{closed: 1} =
             publish(registry, "notifications/resources/updated", one_over_params)

    Subscriptions.delivered(listener)
    assert_receive {:ex_mcp_subscription_message, ^listener, :complete, _completed}
    refute_receive {:ex_mcp_subscription_message, ^listener, :notification, _message}
  end

  test "authorizes task IDs against the task owner and coalesces full-state updates" do
    task_store = start_supervised!({Store.ETS, name: nil}, id: make_ref())

    registry =
      start_registry(
        max_queue: 1,
        authorize_filter: fn requested, _context -> {:ok, requested} end,
        authorize_publication: fn _method, _params, _context -> true end
      )

    alice = %{principal_id: "alice", tenant_id: "acme", audience: "mcp://tasks"}
    bob = %{principal_id: "bob", tenant_id: "acme", audience: "mcp://tasks"}

    alice_opts = [store: Store.ETS, server: task_store, owner: alice, notify: false]
    bob_opts = [store: Store.ETS, server: task_store, owner: bob, notify: false]

    assert {:ok, alice_task} = Tasks.create("deploy", %{}, alice_opts)
    assert {:ok, bob_task} = Tasks.create("deploy", %{}, bob_opts)

    listen_opts = [
      registry: registry,
      principal_id: alice.principal_id,
      tenant_id: alice.tenant_id,
      audience: alice.audience,
      client_capabilities: Extension.put_capability(%{}),
      task_store_opts: [store: Store.ETS, server: task_store]
    ]

    assert {:ok, entry} =
             Subscriptions.listen(
               "tasks",
               %{"taskIds" => [alice_task["taskId"], bob_task["taskId"], "missing"]},
               self(),
               listen_opts
             )

    assert entry.filter == %{"taskIds" => [alice_task["taskId"]]}

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, acknowledged}
    assert acknowledged["params"]["notifications"] == entry.filter

    assert {:ok, working} = Tasks.get(alice_task["taskId"], alice_opts)

    completed =
      working
      |> Map.put("status", "completed")
      |> Map.put("result", %{"content" => []})

    assert %{enqueued: 1} = publish(registry, "notifications/tasks", working)
    assert %{coalesced: 1} = publish(registry, "notifications/tasks", completed)
    assert %{subscribers: 0} = publish(registry, "notifications/tasks", bob_task)

    Subscriptions.delivered(listener)

    assert_receive {:ex_mcp_subscription_message, ^listener, :notification, notification}
    assert notification["method"] == "notifications/tasks"
    assert notification["params"]["taskId"] == alice_task["taskId"]
    assert notification["params"]["status"] == "completed"
  end

  test "task filters require the extension and an authorization source" do
    registry = start_registry()

    assert {:error, %Arbor.MCP.Error.ProtocolError{} = error} =
             Subscriptions.listen(
               1,
               %{"taskIds" => ["task-1"]},
               self(),
               registry: registry
             )

    assert error.code == Arbor.MCP.Protocol.ErrorCodes.missing_required_client_capability()
    assert error.data == %{"requiredCapabilities" => Extension.required_capabilities()}

    assert {:error, :task_subscription_authorizer_required} =
             Subscriptions.listen(
               2,
               %{"taskIds" => ["task-1"]},
               self(),
               registry: registry,
               client_capabilities: Extension.put_capability(%{})
             )

    assert Subscriptions.entries(registry: registry) == []
  end

  test "owner termination removes registrations and internal tokens are distinct from wire ids" do
    registry = start_registry()
    owner = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, entry} =
             Subscriptions.listen("client-visible", %{}, owner, registry: registry)

    assert entry.token != "client-visible"
    assert byte_size(entry.token) >= 20
    assert length(Subscriptions.entries(registry: registry)) == 1

    Process.exit(owner, :kill)
    assert_eventually(fn -> Subscriptions.entries(registry: registry) == [] end)
  end

  test "rejects authorizers that broaden the requested filter" do
    registry =
      start_registry(
        authorize_filter: fn _requested, _context ->
          {:ok, %{"toolsListChanged" => true}}
        end
      )

    assert {:error, :authorizer_broadened_filter} =
             Subscriptions.listen(1, %{}, self(), registry: registry)
  end

  test "rejects invalid publication authorizers before starting a listener" do
    registry = start_registry()

    assert {:error, :invalid_publication_authorizer} =
             Subscriptions.listen(1, %{}, self(),
               registry: registry,
               authorize_publication: :not_a_callback
             )

    assert Subscriptions.entries(registry: registry) == []
  end

  test "requires both authorizers for identity-bound subscriptions" do
    registry = start_registry()

    assert {:error, :subscription_filter_authorizer_required} =
             Subscriptions.listen(1, %{}, self(),
               registry: registry,
               principal_id: "principal-1",
               tenant_id: "tenant-1"
             )

    assert Subscriptions.entries(registry: registry) == []
  end

  test "terminates a listener when adapter registration fails" do
    registry = start_registry(adapter: {RejectingAdapter, test_pid: self()})

    assert {:error, :storage_unavailable} =
             Subscriptions.listen(1, %{}, self(), registry: registry)

    assert_receive {:listener_started, listener}
    refute Process.alive?(listener)
    assert Subscriptions.entries(registry: registry) == []
  end

  defp start_registry(opts \\ []) do
    child = Supervisor.child_spec({Subscriptions, Keyword.put(opts, :name, nil)}, id: make_ref())
    start_supervised!(child)
  end

  defp listen(registry, id, opts) do
    Subscriptions.listen(id, %{}, self(), Keyword.put(opts, :registry, registry))
  end

  defp publish(registry, method, params \\ %{}) do
    Subscriptions.publish(method, params, registry: registry)
  end

  defp notification_bytes(subscription_id, params) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => Map.put(params, "_meta", %{@subscription_id_key => subscription_id})
    }

    message |> Jason.encode!() |> byte_size()
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
