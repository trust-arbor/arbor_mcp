defmodule Arbor.MCP.Server.SubscriptionPublicationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Subscriptions
  alias Arbor.MCP.Server.Subscriptions.Mailbox

  test "public publication rejects invalid and excessive JSON before payload handoff" do
    registry = start_supervised!({Subscriptions, name: nil, max_publication_message_bytes: 128})

    assert {:error, :output_term_too_large} =
             Subscriptions.publish_async(
               "notifications/tools/list_changed",
               %{"data" => String.duplicate("x", 200)},
               registry: registry
             )

    assert {:error, :invalid_output} =
             Subscriptions.publish_async("notifications/tools/list_changed", %{"pid" => self()},
               registry: registry
             )

    assert %{count: 0, bytes: 0} = Mailbox.stats(:sys.get_state(registry).publication_mailbox)
  end

  test "synchronous and asynchronous public results preserve their existing shapes" do
    registry = start_supervised!({Subscriptions, name: nil})

    assert %{subscribers: 0, enqueued: 0, coalesced: 0, closed: 0} =
             Subscriptions.publish("notifications/tools/list_changed", %{}, registry: registry)

    assert :ok =
             Subscriptions.publish_async("notifications/tools/list_changed", %{},
               registry: registry
             )

    assert %{count: 0, bytes: 0} = Mailbox.stats(:sys.get_state(registry).publication_mailbox)
  end

  test "invalid publication and finite timer limits fail at the public boundary" do
    assert {:error, :invalid_subscription_publication} = Subscriptions.publish(:invalid, %{})
    assert {:error, :invalid_subscription_publication} = Subscriptions.publish("method", [])

    assert {:error, :invalid_subscription_limits} =
             Subscriptions.start_link(name: nil, publication_timeout_ms: 4_294_967_296)

    assert {:error, :invalid_subscription_limits} =
             Subscriptions.start_link(name: nil, max_lifetime_ms: 4_294_967_296)

    assert {:error, :invalid_subscription_limits} =
             Subscriptions.start_link(name: nil, max_publications: 0)
  end

  test "paused registry reference lookups never carry a publication payload" do
    registry = start_supervised!({Subscriptions, name: nil, publication_timeout_ms: 60})
    :ok = :sys.suspend(registry)

    caller =
      spawn(fn ->
        Subscriptions.publish_async("notifications/tools/list_changed", %{}, registry: registry)
      end)

    Process.sleep(20)
    assert {:messages, messages} = Process.info(registry, :messages)

    assert Enum.any?(messages, fn
             {:"$gen_call", _, :publication_mailbox} -> true
             _ -> false
           end)

    assert Enum.all?(messages, fn
             {:"$gen_call", _, :publication_mailbox} -> true
             :publication_reap -> true
             _ -> false
           end)

    Process.exit(caller, :kill)
    :ok = :sys.resume(registry)
    assert %{count: 0, bytes: 0} = Mailbox.stats(:sys.get_state(registry).publication_mailbox)
  end
end
