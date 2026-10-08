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

    {caller, monitor} =
      spawn_monitor(fn ->
        Subscriptions.publish_async("notifications/tools/list_changed", %{}, registry: registry)
      end)

    try do
      messages =
        await_publication_lookup(registry, caller, System.monotonic_time(:millisecond) + 1_000)

      assert Enum.all?(messages, fn
               {:"$gen_call", _, :publication_mailbox} -> true
               :publication_reap -> true
               _ -> false
             end)
    after
      try do
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^caller, _reason}, 1_000
      after
        :ok = :sys.resume(registry)
      end
    end

    assert %{count: 0, bytes: 0} = Mailbox.stats(:sys.get_state(registry).publication_mailbox)
  end

  defp await_publication_lookup(registry, caller, deadline) do
    assert Process.alive?(caller), "publication caller exited before the lookup was observed"
    assert {:messages, messages} = Process.info(registry, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, :publication_mailbox}, &1)) do
      messages
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "publication lookup was not enqueued within the observation deadline"
      Process.sleep(min(remaining, 5))
      await_publication_lookup(registry, caller, deadline)
    end
  end
end
