defmodule Arbor.MCP.Client.AsyncPostResultTest do
  @moduledoc """
  Unit tests for the client side of the async POST flow (HTTP/SSE transport):
  task registration, crash handling via monitors, and merging the durable
  transport-state changes computed by the async task.

  These exercise `Arbor.MCP.Client.handle_info/2` directly on a constructed state,
  so no transport or server is required.
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Transport.HTTP

  defp client_state(overrides) do
    struct!(
      %Client{
        pending_requests: %{},
        pending_batches: %{},
        cancelled_requests: MapSet.new(),
        async_post_tasks: %{},
        protocol_version: "2025-11-25"
      },
      overrides
    )
  end

  describe "async POST task registration" do
    test "maps the task's monitor ref to the request id it serves" do
      ref = make_ref()
      state = client_state([])

      assert {:noreply, new_state} = Client.handle_info({:async_post_task, ref, 42}, state)

      assert new_state.async_post_tasks == %{ref => 42}
    end
  end

  describe "async POST task exits ({:DOWN, ...})" do
    test "abnormal exit fails the pending request with a transport error" do
      task_ref = make_ref()
      reply_tag = make_ref()

      state =
        client_state(
          pending_requests: %{42 => {{self(), reply_tag}, :single}},
          async_post_tasks: %{task_ref => 42}
        )

      assert {:noreply, new_state} =
               Client.handle_info({:DOWN, task_ref, :process, self(), :boom}, state)

      assert_receive {^reply_tag, {:error, {:transport_error, :boom}}}
      assert new_state.pending_requests == %{}
      assert new_state.async_post_tasks == %{}
    end

    test "normal exit only clears bookkeeping" do
      task_ref = make_ref()
      reply_tag = make_ref()
      pending = %{42 => {{self(), reply_tag}, :single}}

      state = client_state(pending_requests: pending, async_post_tasks: %{task_ref => 42})

      assert {:noreply, new_state} =
               Client.handle_info({:DOWN, task_ref, :process, self(), :normal}, state)

      refute_receive {^reply_tag, _}
      assert new_state.pending_requests == pending
      assert new_state.async_post_tasks == %{}
    end

    test "unrelated :DOWN messages are ignored" do
      state = client_state(async_post_tasks: %{make_ref() => 42})

      assert {:noreply, ^state} =
               Client.handle_info({:DOWN, make_ref(), :process, self(), :boom}, state)
    end
  end

  describe "async POST results" do
    test "merges durable state changes into the current transport state" do
      task_ref = make_ref()
      ts = %HTTP{session_id: "old", headers: [], base_url: "http://localhost"}

      state =
        client_state(
          transport_mod: HTTP,
          transport_state: ts,
          async_post_tasks: %{task_ref => 42}
        )

      meta = %{request_id: 42, state_changes: %{session_id: "rotated", access_token: "tok"}}

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:ok, ts}, meta}, state)

      assert new_state.transport_state.session_id == "rotated"
      assert new_state.transport_state.access_token == "tok"
      # Fields the task did not change are preserved
      assert new_state.transport_state.base_url == "http://localhost"
      assert new_state.transport_state.headers == []
    end

    test "stale results from untracked tasks do not touch the transport state" do
      ts = %HTTP{session_id: "fresh", headers: []}

      state = client_state(transport_mod: HTTP, transport_state: ts, async_post_tasks: %{})
      meta = %{request_id: 42, state_changes: %{session_id: "stale"}}

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:ok, ts}, meta}, state)

      assert new_state.transport_state.session_id == "fresh"
    end

    test "delivers the response and merges state in the same message" do
      task_ref = make_ref()
      reply_tag = make_ref()
      ts = %HTTP{session_id: "old", headers: []}

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 42, "result" => %{"ok" => true}})

      state =
        client_state(
          transport_mod: HTTP,
          transport_state: ts,
          pending_requests: %{42 => {{self(), reply_tag}, :single}},
          async_post_tasks: %{task_ref => 42}
        )

      meta = %{request_id: 42, state_changes: %{session_id: "rotated"}}

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:ok, ts, response}, meta}, state)

      assert_receive {^reply_tag, {:ok, %{"ok" => true}}}
      assert new_state.pending_requests == %{}
      assert new_state.transport_state.session_id == "rotated"
    end

    test "error results fail the pending request they served" do
      task_ref = make_ref()
      reply_tag = make_ref()

      state =
        client_state(
          pending_requests: %{42 => {{self(), reply_tag}, :single}},
          async_post_tasks: %{task_ref => 42}
        )

      meta = %{request_id: 42, state_changes: %{}}

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:error, :econnrefused}, meta}, state)

      assert_receive {^reply_tag, {:error, {:transport_error, :econnrefused}}}
      assert new_state.pending_requests == %{}
    end

    test "legacy 2-tuple result shape is still accepted" do
      ts = %HTTP{session_id: "s", headers: []}
      state = client_state(transport_mod: HTTP, transport_state: ts)

      assert {:noreply, ^state} = Client.handle_info({:async_post_result, {:ok, ts}}, state)
    end
  end
end
