defmodule Arbor.MCP.Client.ModernSubscriptionTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Subscriptions}

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  defmodule ReconnectClient do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, %{owner: owner, next_id: 1}}

    @impl true
    def handle_call({:open_subscription, subscription, filter}, _from, state) do
      id = state.next_id

      send(
        subscription,
        {:client_subscription_acknowledged, id,
         %{
           "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
           "notifications" => filter
         }}
      )

      send(state.owner, {:subscription_opened, id})

      {:reply, {:ok, id},
       Map.merge(state, %{next_id: id + 1, subscription: subscription, request_id: id})}
    end

    def handle_call({:request, "resources/read", %{"uri" => uri}, _meta}, _from, state) do
      send(
        state.subscription,
        {:client_subscription_event, state.request_id, "notifications/resources/updated",
         %{
           "uri" => uri,
           "_meta" => %{"io.modelcontextprotocol/subscriptionId" => state.request_id}
         }}
      )

      {:reply,
       {:ok,
        %{
          "resultType" => "complete",
          "contents" => [%{"uri" => uri, "text" => "fresh"}]
        }}, state}
    end

    def handle_call({:request, "tasks/get", %{"taskId" => task_id}, _meta}, _from, state) do
      task = %{
        "resultType" => "complete",
        "taskId" => task_id,
        "status" => "working",
        "createdAt" => "2026-08-05T00:00:00Z",
        "lastUpdatedAt" => "2026-08-05T00:00:01Z",
        "ttlMs" => 60_000,
        "pollIntervalMs" => 1_000
      }

      send(
        state.subscription,
        {:client_subscription_event, state.request_id, "notifications/tasks",
         Map.put(
           task,
           "_meta",
           %{"io.modelcontextprotocol/subscriptionId" => state.request_id}
         )}
      )

      {:reply, {:ok, task}, state}
    end

    @impl true
    def handle_cast({:close_subscription, _subscription, request_id, _reason}, state) do
      send(state.owner, {:subscription_cancelled, request_id})
      {:noreply, state}
    end
  end

  test "opens, routes, and cancels a correlated modern subscription" do
    {registry, server, client} = start_stack()

    assert {:ok, subscription} =
             Client.listen(
               client,
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["test://watched"]
               },
               timeout: 2_000
             )

    assert %Subscription.Ref{} = subscription
    assert subscription.acknowledged_filter == subscription.requested_filter

    assert [%{subscription_id: subscription_id}] =
             Subscriptions.entries(registry: registry)

    assert subscription_id == subscription.request_id

    :ok = Server.notify_resource_update(server, "test://watched")

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/resources/updated",
                    params}

    assert params["uri"] == "test://watched"
    assert params["_meta"][@subscription_id_key] == subscription.request_id

    :ok = Server.notify_prompts_changed(server)
    refute_receive {:ex_mcp_subscription, ^subscription, _method, _params}

    assert :ok = Subscription.cancel(subscription, "test complete")
    assert_eventually(fn -> Subscriptions.entries(registry: registry) == [] end)
  end

  test "surfaces graceful server closure to the subscriber" do
    {registry, server, client} = start_stack()

    assert {:ok, subscription} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 2_000)

    {:ok, edge} = Arbor.MCP.Server.Runtime.edge(server)

    assert :ok =
             Subscriptions.close(
               edge,
               subscription.request_id,
               :server_shutdown,
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_closed, ^subscription, {:complete, result}}
    assert result["resultType"] == "complete"
    assert result["_meta"][@subscription_id_key] == subscription.request_id
  end

  test "modern resource compatibility wrappers reference-count one desired subscription" do
    {registry, server, client} = start_stack()

    assert {:ok, first} = Client.subscribe_resource(client, "test://shared")
    assert {:ok, second} = Client.subscribe_resource(client, "test://shared")
    assert first.pid == second.pid
    assert length(Subscriptions.entries(registry: registry)) == 1

    assert {:ok, %{}} = Client.unsubscribe_resource(client, "test://shared")
    assert length(Subscriptions.entries(registry: registry)) == 1

    :ok = Server.notify_resource_update(server, "test://shared")

    assert_receive {:ex_mcp_resource_updated, "test://shared", _params}

    assert {:ok, %{}} = Client.unsubscribe_resource(client, "test://shared")
    assert_eventually(fn -> Subscriptions.entries(registry: registry) == [] end)
    assert {:error, :not_subscribed} = Client.unsubscribe_resource(client, "test://shared")
  end

  test "resource wrapper replaces immutable filters acknowledgment-first" do
    {registry, server, client} = start_stack()

    assert {:ok, first} = Client.subscribe_resource(client, "test://a")
    assert {:ok, replacement} = Client.subscribe_resource(client, "test://b")
    refute first.pid == replacement.pid

    assert_eventually(fn ->
      case Subscriptions.entries(registry: registry) do
        [%{filter: %{"resourceSubscriptions" => uris}}] ->
          Enum.sort(uris) == ["test://a", "test://b"]

        _other ->
          false
      end
    end)

    :ok = Server.notify_resource_update(server, "test://a")
    :ok = Server.notify_resource_update(server, "test://b")
    assert_receive {:ex_mcp_resource_updated, "test://a", _params}
    assert_receive {:ex_mcp_resource_updated, "test://b", _params}

    assert {:ok, %{}} = Client.unsubscribe_resource(client, "test://a")

    assert_eventually(fn ->
      case Subscriptions.entries(registry: registry) do
        [%{filter: %{"resourceSubscriptions" => ["test://b"]}}] -> true
        _other -> false
      end
    end)

    assert {:ok, %{}} = Client.unsubscribe_resource(client, "test://b")
  end

  test "resource wrapper removes dead subscribers and replaces the desired filter" do
    {registry, _server, client} = start_stack()
    owner = self()

    subscriber_a =
      spawn(fn ->
        send(owner, {:subscribed, :a, Client.subscribe_resource(client, "test://a")})
        Process.sleep(:infinity)
      end)

    subscriber_b =
      spawn(fn ->
        send(owner, {:subscribed, :b, Client.subscribe_resource(client, "test://b")})
        Process.sleep(:infinity)
      end)

    assert_receive {:subscribed, :a, {:ok, _subscription}}, 1_000
    assert_receive {:subscribed, :b, {:ok, _subscription}}, 1_000

    assert_eventually(fn ->
      case Subscriptions.entries(registry: registry) do
        [%{filter: %{"resourceSubscriptions" => uris}}] ->
          Enum.sort(uris) == ["test://a", "test://b"]

        _other ->
          false
      end
    end)

    Process.exit(subscriber_a, :kill)

    assert_eventually(fn ->
      case Subscriptions.entries(registry: registry) do
        [%{filter: %{"resourceSubscriptions" => ["test://b"]}}] -> true
        _other -> false
      end
    end)

    Process.exit(subscriber_b, :kill)
    assert_eventually(fn -> Subscriptions.entries(registry: registry) == [] end)
  end

  test "rejects the API on a legacy connection without sending subscriptions/listen" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: Handler,
        transport: :test,
        protocol_mode: :legacy_only
      )

    Arbor.MCP.TestHelpers.stop_on_exit(server)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    on_exit(fn ->
      if Process.alive?(client) do
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert {:error, :subscriptions_require_mcp_2026_07_28} =
             Client.listen(client, %{"toolsListChanged" => true})
  end

  test "surfaces the required-capability error for task subscriptions" do
    {_registry, _server, client} = start_stack()

    assert {:error, error} =
             Client.listen(client, %{"taskIds" => ["task-1"]}, timeout: 1_000)

    assert error["code"] == Arbor.MCP.Protocol.ErrorCodes.missing_required_client_capability()

    assert error["data"] == %{
             "requiredCapabilities" => Arbor.MCP.Tasks.Extension.required_capabilities()
           }
  end

  test "reconnect opens a fresh request, refetches affected state, then releases queued events" do
    {:ok, client} = ReconnectClient.start_link(self())

    assert {:ok, subscription} =
             Subscription.open(
               client,
               %{
                 "resourceSubscriptions" => ["test://resync"],
                 "taskIds" => ["task-resync"]
               },
               timeout: 1_000
             )

    assert_receive {:subscription_opened, first_id}
    assert first_id == subscription.request_id

    send(subscription.pid, {:client_subscription_disconnected, :transport_closed})
    assert_receive {:ex_mcp_subscription_resync, subscription_pid, :started}
    assert subscription_pid == subscription.pid

    send(subscription.pid, :client_subscription_reconnect)
    assert_receive {:subscription_opened, second_id}
    refute second_id == first_id

    assert_receive {:ex_mcp_subscription_resync, reconnected, {:complete, snapshot}}, 1_000
    assert reconnected.request_id == second_id

    assert snapshot["resources"]["test://resync"] ==
             {:ok,
              %{
                "resultType" => "complete",
                "contents" => [%{"uri" => "test://resync", "text" => "fresh"}]
              }}

    assert snapshot["tasks"]["task-resync"] ==
             {:ok,
              %{
                "resultType" => "complete",
                "taskId" => "task-resync",
                "status" => "working",
                "createdAt" => "2026-08-05T00:00:00Z",
                "lastUpdatedAt" => "2026-08-05T00:00:01Z",
                "ttlMs" => 60_000,
                "pollIntervalMs" => 1_000
              }}

    assert_receive {:ex_mcp_subscription, ^reconnected, "notifications/resources/updated",
                    queued_event}

    assert queued_event["uri"] == "test://resync"

    assert_receive {:ex_mcp_subscription, ^reconnected, "notifications/tasks", task_event}
    assert task_event["taskId"] == "task-resync"
    assert :ok = Subscription.cancel(reconnected)
    assert_receive {:subscription_cancelled, ^second_id}
  end

  defp start_stack do
    registry_child =
      Supervisor.child_spec(
        {Subscriptions, name: nil, max_lifetime_ms: 5_000},
        id: make_ref()
      )

    registry = start_supervised!(registry_child)

    {:ok, server} =
      HandlerServer.start_link(
        handler: Handler,
        transport: :test,
        protocol_mode: :modern_only,
        subscription_registry: registry
      )

    Arbor.MCP.TestHelpers.stop_on_exit(server)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        health_check_interval: nil
      )

    on_exit(fn ->
      if Process.alive?(client) do
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {registry, server, client}
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
