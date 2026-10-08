defmodule Arbor.MCP.Client.SubscriptionFilterAckTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Subscription

  defmodule AckClient do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         observer: Keyword.fetch!(opts, :observer),
         acknowledgments: opts[:acknowledgments],
         next_id: 1
       }}
    end

    @impl true
    def handle_call({:open_subscription, subscription, requested}, _from, state) do
      id = state.next_id
      acknowledged = Enum.at(state.acknowledgments, id - 1, requested)

      send(state.observer, {:subscription_opened, id})

      send(subscription, {
        :client_subscription_acknowledged,
        id,
        %{
          "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
          "notifications" => acknowledged
        }
      })

      {:reply, {:ok, id}, %{state | next_id: id + 1}}
    end

    def handle_call({:request, "resources/read", %{"uri" => uri}, _opts}, _from, state) do
      send(state.observer, {:resource_read, uri})
      {:reply, {:error, :not_found}, state}
    end

    @impl true
    def handle_cast({:close_subscription, _subscription, id, _reason}, state) do
      send(state.observer, {:subscription_closed, id})
      {:noreply, state}
    end
  end

  test "rejects a server acknowledgment that adds an unrequested resource" do
    requested = %{"resourceSubscriptions" => ["review://allowed"]}

    expanded = %{
      "resourceSubscriptions" => ["review://allowed", "review://private"]
    }

    {:ok, client} = AckClient.start_link(observer: self(), acknowledgments: [expanded])

    assert {:error, :invalid_subscription_acknowledgment} =
             Subscription.open(client, requested, timeout: 1_000)

    assert_receive {:subscription_opened, 1}
    assert_receive {:subscription_closed, 1}
  end

  test "reconnect cannot resynchronize an expanded resource filter" do
    requested = %{"resourceSubscriptions" => ["review://allowed"]}
    expanded = %{"resourceSubscriptions" => ["review://allowed", "review://private"]}
    {:ok, client} = AckClient.start_link(observer: self(), acknowledgments: [requested, expanded])

    assert {:ok, subscription} = Subscription.open(client, requested, timeout: 1_000)
    assert_receive {:subscription_opened, 1}

    send(subscription.pid, {:client_subscription_disconnected, :transport_closed})
    assert_receive {:ex_mcp_subscription_resync, subscription_pid, :started}
    assert subscription_pid == subscription.pid

    send(subscription.pid, :client_subscription_reconnect)
    assert_receive {:subscription_opened, 2}

    assert_receive {:ex_mcp_subscription_resync, ^subscription_pid,
                    {:failed, :invalid_subscription_acknowledgment}}

    assert_receive {:subscription_closed, 2}
    refute_receive {:ex_mcp_subscription_resync, _, {:complete, _}}, 100
    refute_receive {:resource_read, _uri}, 100
    refute Process.alive?(subscription.pid)
  end

  test "equal and narrower acknowledgments remain active" do
    requested = %{
      "toolsListChanged" => true,
      "resourceSubscriptions" => ["review://a", "review://b"],
      "taskIds" => ["task-a", "task-b"]
    }

    narrower = %{"resourceSubscriptions" => ["review://a"], "taskIds" => ["task-a"]}

    for acknowledged <- [requested, narrower] do
      {:ok, client} = AckClient.start_link(observer: self(), acknowledgments: [acknowledged])
      assert {:ok, subscription} = Subscription.open(client, requested, timeout: 1_000)
      assert subscription.acknowledged_filter == acknowledged
      assert :ok = Subscription.cancel(subscription)
      assert_receive {:subscription_opened, 1}
      assert_receive {:subscription_closed, 1}
    end
  end

  test "rejects new task IDs, enabled categories, and malformed fields" do
    requested = %{"taskIds" => ["task-a"], "toolsListChanged" => true}

    for acknowledged <- [
          %{"taskIds" => ["task-a", "task-private"]},
          %{"toolsListChanged" => true, "promptsListChanged" => true},
          %{"toolsListChanged" => true, toolsListChanged: false},
          %{"resourceSubscriptions" => "review://private"},
          %{"unknownCategory" => true}
        ] do
      {:ok, client} = AckClient.start_link(observer: self(), acknowledgments: [acknowledged])

      assert {:error, :invalid_subscription_acknowledgment} =
               Subscription.open(client, requested, timeout: 1_000)

      assert_receive {:subscription_opened, 1}
      assert_receive {:subscription_closed, 1}
    end
  end

  test "forwards only events inside the acknowledged filter" do
    requested = %{"resourceSubscriptions" => ["review://a", "review://b"]}
    acknowledged = %{"resourceSubscriptions" => ["review://a"]}
    {:ok, client} = AckClient.start_link(observer: self(), acknowledgments: [acknowledged])
    assert {:ok, subscription} = Subscription.open(client, requested, timeout: 1_000)

    send(subscription.pid, {
      :client_subscription_event,
      subscription.request_id,
      "notifications/resources/updated",
      %{"uri" => "review://b"}
    })

    send(subscription.pid, {
      :client_subscription_event,
      subscription.request_id,
      "notifications/tools/list_changed",
      %{}
    })

    send(subscription.pid, {
      :client_subscription_event,
      subscription.request_id,
      "notifications/resources/updated",
      %{"uri" => "review://a"}
    })

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/resources/updated",
                    %{"uri" => "review://a"}}

    refute_receive {:ex_mcp_subscription, ^subscription, _method, _params}, 100
    assert :ok = Subscription.cancel(subscription)
  end
end
