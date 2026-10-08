defmodule Arbor.MCP.Client.ModernHTTPSubscriptionTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.{Runtime, Subscriptions}
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Extension

  defmodule Handler do
    use Arbor.MCP.Server.Handler, tasks: :store

    @impl true
    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:subscription_handler_initialized, self()})
      {:ok, %{observer: observer}}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["publish", "complete"] do
          %{
            name: name,
            description: "Exercises an owned Runtime service",
            inputSchema: %{"type" => "object"}
          }
        end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("publish", arguments, state) do
      result = Subscriptions.publish(arguments["method"], arguments["params"])
      send(state.observer, {:subscription_publication, result})
      {:ok, %{"content" => []}, state}
    end

    def handle_call_tool("complete", arguments, state) do
      result = Tasks.complete(arguments["taskId"], arguments["result"])
      send(state.observer, {:subscription_task_completed, result})
      {:ok, %{"content" => []}, state}
    end
  end

  setup do
    runtime =
      start_supervised!(
        {Runtime, handler: Handler, handler_args: [observer: self()], transport: :mounted_http}
      )

    assert_receive {:subscription_handler_initialized, _scheduler}, 1_000
    port = free_port()
    ranch_ref = {:modern_http_subscription_test, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        HttpPlug,
        [
          runtime: runtime,
          path: "/mcp",
          protocol_mode: :modern_only,
          subscription_keepalive_interval_ms: 25,
          subscription_max_lifetime_ms: 5_000,
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        capabilities: Extension.put_capability(%{}),
        use_sse: false,
        health_check_interval: nil,
        stream_idle_timeout: 1_000
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, runtime: runtime, client: client}
  end

  test "opens, receives, and cancels a literal modern HTTP subscription", %{
    runtime: runtime,
    client: client
  } do
    assert {:ok, subscription} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 2_000)

    assert %Subscription.Ref{} = subscription
    assert subscription.acknowledged_filter == %{"toolsListChanged" => true}

    assert [%{subscription_id: subscription_id}] = Subscriptions.entries(runtime: runtime)
    assert subscription_id == subscription.request_id

    assert %{enqueued: 1} = publish(client, "notifications/tools/list_changed", %{})

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                    params},
                   1_000

    assert params["_meta"]["io.modelcontextprotocol/subscriptionId"] ==
             subscription.request_id

    assert :ok = Subscription.cancel(subscription, "test complete")
    assert_eventually(fn -> Subscriptions.entries(runtime: runtime) == [] end)
  end

  test "reopens and resynchronizes after an abrupt HTTP response-stream close", %{
    runtime: runtime,
    client: client
  } do
    assert {:ok, initial} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 2_000)

    assert [entry] = Subscriptions.entries(runtime: runtime)

    assert :ok =
             Subscriptions.cancel(
               entry.transport_ref,
               entry.subscription_id,
               runtime: runtime
             )

    assert_receive {:ex_mcp_subscription_resync, subscription_pid, :started}, 1_000
    assert subscription_pid == initial.pid

    assert_eventually(fn ->
      case Subscriptions.entries(runtime: runtime) do
        [%{subscription_id: new_id}] -> new_id != initial.request_id
        _other -> false
      end
    end)

    assert_receive {:ex_mcp_subscription_resync, current, {:complete, snapshot}}, 2_000
    assert current.pid == initial.pid
    assert {:ok, %{"resultType" => "complete"}} = snapshot["tools"]

    assert %{enqueued: 1} = publish(client, "notifications/tools/list_changed", %{})

    assert_receive {:ex_mcp_subscription, delivered_on, "notifications/tools/list_changed",
                    _params},
                   1_000

    assert delivered_on.request_id == current.request_id
    assert :ok = Subscription.cancel(current)
    assert_eventually(fn -> Subscriptions.entries(runtime: runtime) == [] end)
  end

  test "delivers owner-authorized task transitions and rejects malformed task events", %{
    runtime: runtime,
    client: client
  } do
    owner = %{principal_id: nil, tenant_id: nil, audience: "/mcp"}

    assert {:ok, created} =
             Tasks.create("deploy", %{}, runtime: runtime, owner: owner, notify: false)

    assert {:ok, subscription} =
             Client.listen(client, %{"taskIds" => [created["taskId"]]}, timeout: 2_000)

    assert subscription.acknowledged_filter == %{"taskIds" => [created["taskId"]]}

    assert {:ok, _response} =
             Client.call_tool(
               client,
               "complete",
               %{
                 "taskId" => created["taskId"],
                 "result" => %{"content" => [%{"type" => "text", "text" => "done"}]}
               },
               timeout: 2_000
             )

    assert_receive {:subscription_task_completed, {:ok, _completed}}, 1_000

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tasks", params},
                   1_000

    assert params["taskId"] == created["taskId"]
    assert params["status"] == "completed"
    assert params["result"] == %{"content" => [%{"type" => "text", "text" => "done"}]}

    assert %{enqueued: 1} =
             publish(client, "notifications/tasks", %{
               "taskId" => created["taskId"],
               "status" => "completed"
             })

    refute_receive {:ex_mcp_subscription, ^subscription, "notifications/tasks", _params}, 100
    assert :ok = Subscription.cancel(subscription)
  end

  defp publish(client, method, params) do
    assert {:ok, _response} =
             Client.call_tool(client, "publish", %{"method" => method, "params" => params},
               timeout: 2_000
             )

    assert_receive {:subscription_publication, result}, 1_000
    result
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
