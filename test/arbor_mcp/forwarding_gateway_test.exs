Code.require_file("../../examples/forwarding_gateway/gateway.exs", __DIR__)
Code.require_file("../../examples/forwarding_gateway/support.exs", __DIR__)

defmodule Arbor.MCP.ForwardingGatewayTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.Examples.ForwardingGateway.Demo
  alias Arbor.MCP.Server.Subscriptions
  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  @moduletag :capture_log
  @moduletag :integration

  setup context do
    owner =
      start_supervised!({Demo, observer: self(), call_timeout: context[:call_timeout] || 5_000})

    demo = Demo.fixture(owner)

    {:ok, demo: demo}
  end

  test "one HTTP endpoint aggregates aliases and keeps callers and argument metadata isolated", %{
    demo: demo
  } do
    for principal <- ~w(alice bob) do
      {:ok, client} = Demo.connect(demo, principal)
      {:ok, tools} = Client.list_tools(client, format: :map)

      assert Enum.map(tools["tools"], & &1["name"]) ==
               ~w(alpha__ask alpha__echo alpha__hold beta__ask beta__echo beta__hold)

      for source <- ~w(alpha beta) do
        args = %{"value" => "hello", "_meta" => %{"caller" => principal}}

        assert {:ok, %{"structuredContent" => result}} =
                 Client.call_tool(client, source <> "__echo", args, format: :map)

        assert result == %{"source" => source, "principal" => principal, "arguments" => args}
      end
    end

    assert {:error, _reason} =
             Client.start_link(
               transport: :http,
               url: demo.url,
               headers: [{"authorization", "Bearer not-a-fixture-identity"}],
               protocol_mode: :modern_only
             )
  end

  for mode <- [:modern_only, :legacy_only] do
    test "interactive HTTP forwarding relays downstream input/progress for #{mode}", %{demo: demo} do
      {:ok, client} = Demo.connect(demo, "alice", protocol_mode: unquote(mode), observer: self())

      assert {:ok, %{"structuredContent" => result}} =
               Client.call_tool(client, "alpha__ask", %{},
                 progress_token: "downstream",
                 format: :map,
                 timeout: 5_000
               )

      assert result["arguments"] == %{"greeting" => "Hello, alice"}
      assert_receive {:upstream_round, "alice", "alpha", upstream_token}
      assert_receive {:upstream_round, "alice", "alpha", ^upstream_token}
      assert upstream_token != "downstream"

      assert_receive {:downstream_progress, "alice",
                      %{"progressToken" => "downstream", "progress" => 1}}

      assert_receive {:downstream_progress, "alice",
                      %{"progressToken" => "downstream", "progress" => 2}}
    end
  end

  test "a cancelled caller closes only its upstream operation while a sibling completes", %{
    demo: demo
  } do
    {:ok, client} = Demo.connect(demo, "alice")
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        Client.call_tool(client, "alpha__hold", %{}, timeout: 5_000)
        send(parent, :hold_finished)
      end)

    assert_receive {:upstream_holding, "alice", "alpha", worker}, 2_000
    worker_monitor = Process.monitor(worker)
    assert {:ok, _result} = Client.call_tool(client, "beta__echo", %{}, timeout: 2_000)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:upstream_cancelled, "alice", "alpha", _reason}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 2_000
    refute_received :hold_finished
    assert {:ok, _result} = Client.call_tool(client, "alpha__echo", %{}, timeout: 2_000)
  end

  @tag call_timeout: 1_000
  test "the gateway deadline cancels upstream work even when the downstream wait is longer", %{
    demo: demo
  } do
    {:ok, client} = Demo.connect(demo, "alice")
    call = Task.async(fn -> Client.call_tool(client, "alpha__hold", %{}, timeout: 5_000) end)
    assert_receive {:upstream_holding, "alice", "alpha", worker}, 2_000
    monitor = Process.monitor(worker)
    assert {:error, _reason} = Task.await(call, 2_000)
    assert_receive {:upstream_cancelled, "alice", "alpha", _reason}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
  end

  test "unbound input responses cannot skip the initial interactive round", %{demo: demo} do
    {:ok, client} = Demo.connect(demo, "alice")
    answers = %{"name" => %{"action" => "accept", "content" => %{"name" => "Unbound"}}}

    assert {:error, _reason} =
             Client.call_tool(client, "alpha__ask", %{},
               mrtr: :manual,
               input_responses: answers,
               format: :map
             )

    refute_receive {:upstream_round, _, _, _}, 100
  end

  test "manual downstream retries can change progress tokens but cannot replay or change arguments",
       %{demo: demo} do
    {:ok, client} = Demo.connect(demo, "alice")
    args = %{"value" => "original"}

    assert {:input_required, round} =
             Client.call_tool(client, "alpha__ask", args,
               mrtr: :manual,
               progress_token: "down-1",
               progress_to: self(),
               timeout: 5_000
             )

    assert_receive {:upstream_round, "alice", "alpha", token}
    assert_receive {:arbor_mcp_progress, ^client, "down-1", %{"progress" => 1}}

    next = [
      mrtr: :manual,
      request_state: round.request_state,
      input_responses: %{"name" => %{"action" => "accept", "content" => %{"name" => "Lin"}}},
      progress_token: "down-2",
      progress_to: self(),
      format: :map,
      timeout: 5_000
    ]

    assert {:error, _reason} =
             Client.call_tool(client, "alpha__ask", %{"value" => "changed"}, next)

    assert {:ok, %{"structuredContent" => result}} =
             Client.call_tool(client, "alpha__ask", args, next)

    assert result["arguments"] == %{"greeting" => "Hello, Lin"}
    assert_receive {:upstream_round, "alice", "alpha", ^token}
    assert_receive {:arbor_mcp_progress, ^client, "down-2", %{"progress" => 2}}
    assert {:error, _reason} = Client.call_tool(client, "alpha__ask", args, next)
    refute_receive {:upstream_round, _, _, _}, 100
  end

  test "legacy initialization refuses a profile different from its fixed upstream capabilities",
       %{demo: demo} do
    assert {:error, _reason} =
             Client.start_link(
               transport: :http,
               url: demo.url,
               protocol_mode: :legacy_only,
               capabilities: %{},
               headers: [{"authorization", "Bearer fixture-gateway-alice"}]
             )
  end

  test "modern upstream catalog changes reach legacy downstream notification listeners", %{
    demo: demo
  } do
    {:ok, legacy} = Demo.connect(demo, "alice", protocol_mode: :legacy_only)
    {:ok, listener} = Client.subscribe_notifications(legacy, %{"toolsListChanged" => true})
    :ok = Demo.notify(demo, "alice", "beta")

    assert_receive {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _params},
                   2_000

    :ok = Client.unsubscribe_notifications(listener)
  end

  test "tool-change feeds are identity scoped and gateway retirement releases them", %{demo: demo} do
    {:ok, alice} = Demo.connect(demo, "alice")
    {:ok, bob} = Demo.connect(demo, "bob")
    {:ok, alice_feed} = Client.listen(alice, %{"toolsListChanged" => true})
    {:ok, bob_feed} = Client.listen(bob, %{"toolsListChanged" => true})
    :ok = Demo.notify(demo, "alice", "alpha")

    assert_receive {:ex_mcp_subscription, ^alice_feed, "notifications/tools/list_changed",
                    _params},
                   2_000

    refute_receive {:ex_mcp_subscription, ^bob_feed, _, _}, 100

    :ok = Subscription.cancel(alice_feed)
    :ok = Demo.notify(demo, "bob", "beta")

    assert_receive {:ex_mcp_subscription, ^bob_feed, "notifications/tools/list_changed", _params},
                   2_000

    :ok = Demo.stop_identity(demo, "alice")

    for source <- ~w(alpha beta) do
      runtime = demo.upstreams[source].identities["fixture-#{source}-alice"].runtime
      wait_until(fn -> Subscriptions.entries(runtime: runtime) == [] end, timeout: 2_000)
    end

    assert {:ok, _result} = Client.call_tool(bob, "beta__echo", %{}, format: :map)
    :ok = Subscription.cancel(bob_feed)
  end
end
