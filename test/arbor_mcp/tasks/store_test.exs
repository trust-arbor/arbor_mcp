defmodule Arbor.MCP.Tasks.StoreTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Subscriptions
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Extension
  alias Arbor.MCP.Tasks.Store.ETS

  @alice %{principal_id: "alice", tenant_id: "acme", audience: "https://mcp.example"}
  @bob %{principal_id: "bob", tenant_id: "acme", audience: "https://mcp.example"}

  setup do
    start_supervised!({ETS, name: nil})
    |> then(&{:ok, server: &1})
  end

  test "persists a task before returning its create result", %{server: server} do
    opts = store_opts(server, @alice)

    assert {:ok, created} =
             Tasks.create(
               "deploy",
               %{"environment" => "production"},
               opts ++ [ttl: 60_000, poll_interval: 2_000]
             )

    assert created["resultType"] == "task"
    assert created["status"] == "working"
    assert created["ttlMs"] == 60_000
    assert created["pollIntervalMs"] == 2_000

    assert {:ok, stored} = Tasks.get(created["taskId"], opts)
    assert stored["taskId"] == created["taskId"]
    assert stored["status"] == "working"
  end

  test "uses the same not-found response for missing and unauthorized task IDs", %{server: server} do
    alice_opts = store_opts(server, @alice)
    bob_opts = store_opts(server, @bob)

    assert {:ok, created} = Tasks.create("deploy", %{}, alice_opts)

    assert {:error, :not_found_or_unauthorized} = Tasks.get(created["taskId"], bob_opts)
    assert {:error, :not_found_or_unauthorized} = Tasks.get("task_missing", bob_opts)
    assert {:error, :not_found_or_unauthorized} = Tasks.cancel(created["taskId"], bob_opts)
  end

  test "accepts each outstanding input response at most once", %{server: server} do
    opts = store_opts(server, @alice)
    assert {:ok, created} = Tasks.create("deploy", %{}, opts)
    task_id = created["taskId"]

    requests = %{
      "approval" => %{"method" => "elicitation/create"},
      "region" => %{"method" => "elicitation/create"}
    }

    assert {:ok, waiting} = Tasks.require_input(task_id, requests, opts)
    assert waiting.state == :input_required

    assert :ok =
             Tasks.update(
               task_id,
               %{"approval" => %{"action" => "accept"}, "unknown" => %{}},
               opts
             )

    assert {:ok, current} = Tasks.get(task_id, opts)
    assert current["status"] == "input_required"
    assert Map.keys(current["inputRequests"]) == ["region"]

    assert :ok = Tasks.update(task_id, %{"approval" => %{"action" => "decline"}}, opts)

    assert {:ok, accepted} = Tasks.take_input_responses(task_id, opts)
    assert accepted == %{"approval" => %{"action" => "accept"}}
    assert {:ok, %{}} = Tasks.take_input_responses(task_id, opts)

    assert :ok = Tasks.update(task_id, %{"region" => %{"value" => "us-east"}}, opts)
    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id, opts)

    assert {:ok, completed} = Tasks.complete(task_id, %{"deploymentId" => "dep-1"}, opts)
    assert completed.state == :completed

    assert {:ok, final} = Tasks.get(task_id, opts)
    assert final["result"] == %{"deploymentId" => "dep-1"}
    assert {:error, :invalid_transition} = Tasks.mark_cancelled(task_id, opts)
  end

  test "records cooperative cancellation separately from terminal state", %{server: server} do
    opts = store_opts(server, @alice)
    assert {:ok, created} = Tasks.create("deploy", %{}, opts)
    task_id = created["taskId"]

    assert :ok = Tasks.cancel(task_id, opts)
    assert :ok = Tasks.cancel(task_id, opts)
    assert {:ok, true} = Tasks.cancellation_requested?(task_id, opts)
    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id, opts)

    assert {:ok, cancelled} = Tasks.mark_cancelled(task_id, opts)
    assert cancelled.state == :cancelled
    assert :ok = Tasks.cancel(task_id, opts)
  end

  test "expires entries using their creation TTL" do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)

    server =
      start_supervised!(
        {ETS, name: nil, now_fun: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    opts = store_opts(server, @alice)
    assert {:ok, created} = Tasks.create("deploy", %{}, opts ++ [ttl: 50])
    assert {:ok, _task} = Tasks.get(created["taskId"], opts)

    Agent.update(clock, fn _ -> 1_050 end)
    assert {:error, :not_found_or_unauthorized} = Tasks.get(created["taskId"], opts)
  end

  test "bounds capacity and TTL", %{server: _default_server} do
    server =
      start_supervised!({ETS, name: nil, max_tasks: 1, max_ttl_ms: 100}, id: make_ref())

    opts = store_opts(server, @alice)

    assert {:ok, _created} = Tasks.create("one", %{}, opts ++ [ttl: 100])
    assert {:error, :store_full} = Tasks.create("two", %{}, opts ++ [ttl: 100])
    assert {:error, :ttl_out_of_range} = Tasks.create("three", %{}, opts ++ [ttl: 101])
  end

  test "maps unavailable custom stores to a stable error" do
    assert {:error, :task_store_unavailable} =
             Tasks.create("deploy", %{}, store: MissingTaskStore, owner: @alice)
  end

  test "publishes full task state after a durable transition", %{server: server} do
    registry =
      start_supervised!(
        {Subscriptions, name: nil, max_lifetime_ms: 5_000},
        id: make_ref()
      )

    opts = store_opts(server, @alice) ++ [subscription_registry: registry, notify: false]
    assert {:ok, created} = Tasks.create("deploy", %{}, opts)

    assert {:ok, _entry} =
             Subscriptions.listen(
               "task-events",
               %{"taskIds" => [created["taskId"]]},
               self(),
               registry: registry,
               principal_id: @alice.principal_id,
               tenant_id: @alice.tenant_id,
               audience: @alice.audience,
               client_capabilities: Extension.put_capability(%{}),
               authorize_filter: fn requested, _context -> {:ok, requested} end,
               authorize_publication: fn _method, _params, _context -> true end,
               task_store_opts: [store: ETS, server: server]
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}
    Subscriptions.delivered(listener)

    transition_opts = Keyword.put(opts, :notify, true)

    assert {:ok, completed} =
             Tasks.complete(created["taskId"], %{"deploymentId" => "dep-1"}, transition_opts)

    assert completed.state == :completed

    assert_receive {:ex_mcp_subscription_message, ^listener, :notification, notification}
    assert notification["method"] == "notifications/tasks"

    assert notification["params"] == %{
             "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "task-events"},
             "taskId" => created["taskId"],
             "status" => "completed",
             "createdAt" => created["createdAt"],
             "lastUpdatedAt" => completed.last_updated_at,
             "ttlMs" => created["ttlMs"],
             "pollIntervalMs" => created["pollIntervalMs"],
             "result" => %{"deploymentId" => "dep-1"}
           }
  end

  defp store_opts(server, owner), do: [store: ETS, server: server, owner: owner]
end
