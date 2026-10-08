defmodule Arbor.MCP.Client.NotificationListenerTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.NotificationListener
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.HandlerServer

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{observer: Keyword.fetch!(opts, :observer)}}

    @impl true
    def handle_subscribe_resource("test://missing", state) do
      {:error, "Resource not found: test://missing", state}
    end

    def handle_subscribe_resource(uri, state) do
      send(state.observer, {:server_subscribe, uri})
      {:ok, %{}, state}
    end

    @impl true
    def handle_unsubscribe_resource(uri, state) do
      send(state.observer, {:server_unsubscribe, uri})
      {:ok, %{}, state}
    end
  end

  defmodule RecordingTransport do
    @moduledoc """
    Push-model transport for reconnect tests, after `Arbor.MCP.Client.ReconnectTest`.

    Answers the handshake synchronously, answers `resources/subscribe`,
    `resources/unsubscribe`, and `ping` by pushing a response to the client,
    reports every subscribe/unsubscribe request to the test process, and fails
    subscribe requests for URIs listed in the agent's `:failing_uris`.
    """

    @behaviour Arbor.MCP.Transport

    defstruct [:agent, :test_pid, :pending]

    @impl true
    def connect(opts) do
      agent = Keyword.fetch!(opts, :agent)
      test_pid = Keyword.fetch!(opts, :test_pid)

      {attempt, allowed} =
        Agent.get_and_update(agent, fn state ->
          attempt = state.connects + 1
          {{attempt, state.allowed_connects}, %{state | connects: attempt}}
        end)

      send(test_pid, {:transport_connect, attempt})

      if attempt <= allowed do
        {:ok, %__MODULE__{agent: agent, test_pid: test_pid, pending: nil}}
      else
        {:error, :connection_refused}
      end
    end

    @impl true
    def send_message(message, %__MODULE__{} = state) do
      case Jason.decode!(message) do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pending: initialize_response(id)}}

        %{"method" => method, "id" => id, "params" => params}
        when method in ["resources/subscribe", "resources/unsubscribe"] ->
          send(state.test_pid, {:transport_request, method, params})
          failing = Agent.get(state.agent, & &1.failing_uris)

          if method == "resources/subscribe" and params["uri"] in failing,
            do: push(state, error_response(id)),
            else: push(state, result_response(id))

          {:ok, state}

        %{"method" => "ping", "id" => id} ->
          push(state, result_response(id))
          {:ok, state}

        _other ->
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%__MODULE__{pending: nil}), do: {:error, :closed}

    def receive_message(%__MODULE__{pending: response} = state),
      do: {:ok, response, %{state | pending: nil}}

    @impl true
    def close(_state), do: :ok

    @impl true
    def connected?(_state), do: true

    @impl true
    def subscribe(pid, %__MODULE__{} = state) do
      Agent.update(state.agent, &Map.put(&1, :client, pid))
      {:ok, state}
    end

    @impl true
    def capabilities(_state), do: [:push]

    defp push(state, response) do
      client = Agent.get(state.agent, & &1.client)
      send(client, {:transport_message, response})
    end

    defp initialize_response(id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"resources" => %{"subscribe" => true, "listChanged" => true}},
          "serverInfo" => %{"name" => "recording-server", "version" => "1.0.0"}
        }
      })
    end

    defp result_response(id),
      do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

    defp error_response(id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_602, "message" => "Resource not found"}
      })
    end
  end

  describe "against a legacy server" do
    setup do
      {server, client} = start_pair(:legacy_only)
      %{server: server, client: client}
    end

    test "delivers only the notifications the filter names", %{server: server, client: client} do
      {:ok, listener} =
        Client.subscribe_notifications(client, %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["test://watched"]
        })

      assert %NotificationListener.Ref{client: ^client, subscriber: subscriber} = listener
      assert subscriber == self()
      assert_receive {:server_subscribe, "test://watched"}

      :ok = Server.notify_tools_changed(server)

      assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed",
                      _params},
                     1_000

      :ok = Server.notify_prompts_changed(server)
      :ok = Server.notify_resources_changed(server)
      :ok = Server.notify_resource_update(server, "test://other")
      :ok = Server.notify_resource_update(server, "test://watched")

      assert_receive {:ex_mcp_notification, ^listener, "notifications/resources/updated",
                      %{"uri" => "test://watched"}},
                     1_000

      # The update above was queued after the three unwanted notifications, so
      # by now they have all been processed and dropped.
      refute_received {:ex_mcp_notification, _, "notifications/prompts/list_changed", _}
      refute_received {:ex_mcp_notification, _, "notifications/resources/list_changed", _}
      refute_received {:ex_mcp_notification, _, _, %{"uri" => "test://other"}}
    end

    test "shares one server subscription per URI and releases it with the last listener",
         %{server: server, client: client} do
      {:ok, first} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://shared"]})

      assert_receive {:server_subscribe, "test://shared"}

      {:ok, second} =
        Client.subscribe_notifications(client, %{
          "resourceSubscriptions" => ["test://shared", "test://second-only"]
        })

      assert_receive {:server_subscribe, "test://second-only"}
      refute_received {:server_subscribe, "test://shared"}

      :ok = Server.notify_resource_update(server, "test://shared")
      assert_receive {:ex_mcp_notification, ^first, _, %{"uri" => "test://shared"}}, 1_000
      assert_receive {:ex_mcp_notification, ^second, _, %{"uri" => "test://shared"}}, 1_000

      assert :ok = Client.unsubscribe_notifications(second)
      assert_receive {:server_unsubscribe, "test://second-only"}
      refute_received {:server_unsubscribe, "test://shared"}

      assert :ok = Client.unsubscribe_notifications(first)
      assert_receive {:server_unsubscribe, "test://shared"}
      assert {:error, :not_found} = Client.unsubscribe_notifications(first)

      :ok = Server.notify_resource_update(server, "test://shared")
      assert {:ok, _pong} = Client.ping(client)
      refute_received {:ex_mcp_notification, _, _, _}
    end

    test "a subscriber exit releases its listener and server subscriptions",
         %{client: client} do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, listener} =
        Client.subscribe_notifications(
          client,
          %{"resourceSubscriptions" => ["test://owned"]},
          subscriber: subscriber
        )

      assert listener.subscriber == subscriber
      assert_receive {:server_subscribe, "test://owned"}

      monitor = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^subscriber, _reason}

      assert_receive {:server_unsubscribe, "test://owned"}, 1_000
      assert {:error, :not_found} = Client.unsubscribe_notifications(listener)
    end

    test "a failed resource subscribe rolls the registration back",
         %{server: server, client: client} do
      assert {:error, {:subscribe_failed, "test://missing", _reason}} =
               Client.subscribe_notifications(client, %{
                 "resourceSubscriptions" => ["test://ok", "test://missing"]
               })

      assert_receive {:server_subscribe, "test://ok"}
      assert_receive {:server_unsubscribe, "test://ok"}, 1_000

      :ok = Server.notify_resource_update(server, "test://ok")
      assert {:ok, _pong} = Client.ping(client)
      refute_received {:ex_mcp_notification, _, _, _}
    end

    test "a rolled-back registration cannot release a URI another listener holds",
         %{server: server, client: client} do
      {:ok, holder} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://shared"]})

      assert_receive {:server_subscribe, "test://shared"}

      assert {:error, {:subscribe_failed, "test://missing", _reason}} =
               Client.subscribe_notifications(client, %{
                 "resourceSubscriptions" => ["test://shared", "test://missing"]
               })

      # The failed registration shared test://shared rather than subscribing
      # it again, and its rollback must not take the holder's subscription.
      refute_received {:server_subscribe, "test://shared"}
      refute_received {:server_unsubscribe, "test://shared"}

      :ok = Server.notify_resource_update(server, "test://shared")
      assert_receive {:ex_mcp_notification, ^holder, _, %{"uri" => "test://shared"}}, 1_000
    end

    test "a subscriber exit racing a new listener leaves the URI subscribed",
         %{server: server, client: client} do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, first} =
        Client.subscribe_notifications(
          client,
          %{"resourceSubscriptions" => ["test://raced"]},
          subscriber: subscriber
        )

      assert_receive {:server_subscribe, "test://raced"}

      # Kill the first subscriber and register a second listener for the same
      # URI without waiting for the asynchronous release to run.
      send(subscriber, :stop)

      {:ok, second} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://raced"]})

      :ok = Server.notify_resource_update(server, "test://raced")
      assert_receive {:ex_mcp_notification, ^second, _, %{"uri" => "test://raced"}}, 1_000

      # Whichever order the release and the new acquisition ran in, every
      # subscribe is paired with one unsubscribe and the URI ends unsubscribed.
      assert :ok = Client.unsubscribe_notifications(second)

      # The client has handled the first subscriber's exit once its listener
      # is gone from client state; by then the release is queued at the
      # worker, and a synchronous call to the worker drains it.
      Arbor.MCP.TestHelpers.wait_until(
        fn -> not Map.has_key?(:sys.get_state(client).notification_listeners, first.id) end,
        timeout: 1_000
      )

      %{notification_worker: worker} = :sys.get_state(client)
      _drained = :sys.get_state(worker)

      # The first subscribe was consumed by the assertion above.
      ops = [:subscribe | collect_server_ops("test://raced")]
      assert Enum.count(ops, &(&1 == :subscribe)) == Enum.count(ops, &(&1 == :unsubscribe))
      assert List.last(ops) == :unsubscribe
    end

    test "a dead subscriber is refused before any server subscription", %{client: client} do
      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

      assert {:error, :subscriber_not_alive} =
               Client.subscribe_notifications(
                 client,
                 %{"resourceSubscriptions" => ["test://never"]},
                 subscriber: dead
               )

      refute_received {:server_subscribe, "test://never"}
    end

    test "rejects invalid, empty, and task filters", %{client: client} do
      assert {:error, :unknown_subscription_filter} =
               Client.subscribe_notifications(client, %{"bogus" => true})

      assert {:error, :invalid_subscription_filter} =
               Client.subscribe_notifications(client, %{"toolsListChanged" => "yes"})

      assert {:error, :empty_subscription_filter} =
               Client.subscribe_notifications(client, %{"toolsListChanged" => false})

      assert {:error, :empty_subscription_filter} =
               Client.subscribe_notifications(client, %{"resourceSubscriptions" => []})

      assert {:error, :task_subscriptions_require_mcp_2026_07_28} =
               Client.subscribe_notifications(client, %{"taskIds" => ["task-1"]})

      assert {:error, :subscription_filter_required} =
               Client.subscribe_notifications(client, :not_a_filter)

      refute_received {:server_subscribe, _}
    end

    test "an explicit disconnect closes listeners", %{client: client} do
      {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      :ok = Client.disconnect(client)
      assert_receive {:ex_mcp_notification_closed, ^listener, :disconnected}
    end

    test "stopping the client closes listeners", %{client: client} do
      {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      :ok = GenServer.stop(client)
      assert_receive {:ex_mcp_notification_closed, ^listener, {:shutdown, :normal}}
    end
  end

  describe "against a modern server" do
    test "refuses legacy listeners and points at listen/3" do
      {_server, client} = start_pair(:modern_only)
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)

      assert {:error, :use_listen} =
               Client.subscribe_notifications(client, %{"toolsListChanged" => true})
    end
  end

  describe "across a reconnect" do
    test "re-subscribes listened URIs and keeps delivering" do
      agent = start_agent(allowed_connects: 10)
      client = start_recording_client(agent)
      assert_receive {:transport_connect, 1}

      {:ok, listener} =
        Client.subscribe_notifications(client, %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["test://a", "test://b"]
        })

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://a"}}
      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://b"}}

      send(client, {:transport_closed, :connection_lost})
      assert_receive {:transport_connect, 2}, 1_000

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://a"}}, 1_000
      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://b"}}, 1_000

      assert_receive {:ex_mcp_notification_reconnected, ^listener,
                      %{resubscribed: ["test://a", "test://b"], failed: []}},
                     1_000

      push_notification(client, "notifications/tools/list_changed", %{})
      assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _}

      push_notification(client, "notifications/resources/updated", %{"uri" => "test://b"})
      assert_receive {:ex_mcp_notification, ^listener, _, %{"uri" => "test://b"}}
    end

    test "reports only to the listeners that existed when the reconnect happened" do
      agent = start_agent(allowed_connects: 10)
      client = start_recording_client(agent)
      assert_receive {:transport_connect, 1}

      {:ok, before} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://before"]})

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://before"}}

      send(client, {:transport_closed, :connection_lost})
      assert_receive {:transport_connect, 2}, 1_000

      # Registered while the reconnect is completing: its own subscribe is
      # serialized behind the re-subscription, and it is not in the report.
      {:ok, after_reconnect} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://after"]})

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://before"}},
                     1_000

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://after"}},
                     1_000

      assert_receive {:ex_mcp_notification_reconnected, ^before,
                      %{resubscribed: ["test://before"], failed: []}},
                     1_000

      refute_received {:ex_mcp_notification_reconnected, ^after_reconnect, _}
    end

    test "reports URIs the server refused after reconnect" do
      agent = start_agent(allowed_connects: 10)
      client = start_recording_client(agent)
      assert_receive {:transport_connect, 1}

      {:ok, listener} =
        Client.subscribe_notifications(client, %{
          "resourceSubscriptions" => ["test://keeps", "test://goes-away"]
        })

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://goes-away"}}
      Agent.update(agent, &Map.put(&1, :failing_uris, ["test://goes-away"]))

      send(client, {:transport_closed, :connection_lost})
      assert_receive {:transport_connect, 2}, 1_000

      assert_receive {:ex_mcp_notification_reconnected, ^listener,
                      %{resubscribed: ["test://keeps"], failed: [{"test://goes-away", _reason}]}},
                     1_000

      # The URI is still held but lost. A later listener naming it must go to
      # the wire rather than trust the count, and once the server accepts
      # again the subscription is restored for both listeners.
      Agent.update(agent, &Map.put(&1, :failing_uris, []))

      {:ok, later} =
        Client.subscribe_notifications(client, %{"resourceSubscriptions" => ["test://goes-away"]})

      assert_receive {:transport_request, "resources/subscribe", %{"uri" => "test://goes-away"}}

      push_notification(client, "notifications/resources/updated", %{"uri" => "test://goes-away"})
      assert_receive {:ex_mcp_notification, ^listener, _, %{"uri" => "test://goes-away"}}
      assert_receive {:ex_mcp_notification, ^later, _, %{"uri" => "test://goes-away"}}
    end

    test "closes listeners when reconnection gives up" do
      agent = start_agent(allowed_connects: 1)
      client = start_recording_client(agent, max_reconnect_attempts: 1)
      assert_receive {:transport_connect, 1}

      {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      send(client, {:transport_closed, :connection_lost})
      assert_receive {:transport_connect, 2}, 1_000

      assert_receive {:ex_mcp_notification_closed, ^listener,
                      {:reconnect_exhausted, :connection_refused}},
                     1_000
    end

    test "closes listeners when the transport closes with reconnection disabled" do
      agent = start_agent(allowed_connects: 1)
      client = start_recording_client(agent, reconnect: false)
      assert_receive {:transport_connect, 1}

      {:ok, listener} = Client.subscribe_notifications(client, %{"toolsListChanged" => true})

      send(client, {:transport_closed, :connection_lost})

      assert_receive {:ex_mcp_notification_closed, ^listener,
                      {:transport_closed, :connection_lost}},
                     1_000
    end
  end

  defp start_pair(protocol_mode) do
    {:ok, server} =
      HandlerServer.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        transport: :test,
        protocol_mode: protocol_mode
      )

    Arbor.MCP.TestHelpers.stop_on_exit(server)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: protocol_mode,
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

    {server, client}
  end

  defp start_agent(allowed_connects: allowed) do
    initial = %{connects: 0, allowed_connects: allowed, failing_uris: [], client: nil}
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp start_recording_client(agent, opts \\ []) do
    {:ok, client} =
      Client.start_link(
        [
          transport: RecordingTransport,
          agent: agent,
          test_pid: self(),
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect_backoff: [initial: 10, max: 20, multiplier: 2]
        ] ++ opts
      )

    client
  end

  defp collect_server_ops(uri, acc \\ []) do
    receive do
      {:server_subscribe, ^uri} -> collect_server_ops(uri, [:subscribe | acc])
      {:server_unsubscribe, ^uri} -> collect_server_ops(uri, [:unsubscribe | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp push_notification(client, method, params) do
    send(
      client,
      {:transport_message,
       Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})}
    )
  end
end
