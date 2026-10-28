defmodule ExMCP.Client.AsyncPostResultTest do
  @moduledoc """
  Unit tests for the client side of the async POST flow (HTTP/SSE transport):
  task registration, crash handling via monitors, and merging the durable
  transport-state changes computed by the async task.

  These exercise `ExMCP.Client.handle_info/2` directly on a constructed state,
  so no transport or server is required.
  """
  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Transport.HTTP

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

    test "handshake starts the task after registration" do
      ref = make_ref()
      state = client_state(connection_status: :connected, transport_state: %HTTP{})

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_task, ref, 42, self()}, state)

      assert new_state.async_post_tasks == %{ref => {self(), 42}}
      assert_receive {:start_async_post, ^ref}
    end

    test "registration when disconnected terminates task without starting it" do
      ref = make_ref()
      task_pid = spawn(fn -> receive do: (_ -> :ok) end)
      state = client_state(connection_status: :disconnected, transport_state: nil)

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_task, ref, 42, task_pid}, state)

      assert new_state.async_post_tasks == %{}
      refute_receive {:start_async_post, ^ref}
      refute Process.alive?(task_pid)
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

    test "delayed older retry credentials do not overwrite newer credentials" do
      task_ref = make_ref()

      ts = %HTTP{
        session_id: "s1",
        access_token: "T2",
        headers: [{"Authorization", "Bearer T2"}],
        auth_version: 2
      }

      state =
        client_state(
          transport_mod: HTTP,
          transport_state: ts,
          async_post_tasks: %{task_ref => 42}
        )

      # Task A was delayed and completed with older credentials T1 (auth_version 1)
      meta = %{
        request_id: 42,
        state_changes: %{
          session_id: "rotated_by_a",
          access_token: "T1",
          headers: [{"Authorization", "Bearer T1"}],
          auth_version: 1
        }
      }

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:ok, ts}, meta}, state)

      # Non-credential changes are merged
      assert new_state.transport_state.session_id == "rotated_by_a"
      # Newer credentials (T2, version 2) are preserved and NOT overwritten by T1
      assert new_state.transport_state.access_token == "T2"
      assert new_state.transport_state.headers == [{"Authorization", "Bearer T2"}]
      assert new_state.transport_state.auth_version == 2
    end

    test "client process allocates monotonically increasing auth versions" do
      task_ref1 = make_ref()
      task_ref2 = make_ref()
      task_pid = self()

      ts = %HTTP{auth_version: 0, auth_version_allocator: 0}

      state =
        client_state(
          connection_status: :connected,
          transport_mod: HTTP,
          transport_state: ts,
          async_post_tasks: %{task_ref1 => {task_pid, 1}, task_ref2 => {task_pid, 2}}
        )

      req_ref1 = make_ref()

      assert {:noreply, state1} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid, req_ref1}, state)

      assert_receive {:http_post_auth_version, ^req_ref1, 1}
      assert state1.transport_state.auth_version_allocator == 1

      req_ref2 = make_ref()

      assert {:noreply, state2} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid, req_ref2}, state1)

      assert_receive {:http_post_auth_version, ^req_ref2, 2}
      assert state2.transport_state.auth_version_allocator == 2
    end

    test "A commits v2 then B commits newer client-allocated v3 without discarding T3" do
      task_ref_a = make_ref()
      task_ref_b = make_ref()
      task_pid_a = self()
      task_pid_b = self()

      ts = %HTTP{
        session_id: "s1",
        access_token: nil,
        headers: [],
        auth_version: 0,
        auth_version_allocator: 0
      }

      state =
        client_state(
          connection_status: :connected,
          transport_mod: HTTP,
          transport_state: ts,
          async_post_tasks: %{
            task_ref_a => {task_pid_a, 101},
            task_ref_b => {task_pid_b, 102}
          }
        )

      # Task A hits 401, allocates v1
      ref_a1 = make_ref()

      assert {:noreply, state} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid_a, ref_a1}, state)

      assert_receive {:http_post_auth_version, ^ref_a1, 1}

      # Task A hits 403, allocates v2
      ref_a2 = make_ref()

      assert {:noreply, state} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid_a, ref_a2}, state)

      assert_receive {:http_post_auth_version, ^ref_a2, 2}

      # Task A completes and commits T2 with version 2
      meta_a = %{
        request_id: 101,
        state_changes: %{
          access_token: "T2",
          headers: [{"Authorization", "Bearer T2"}],
          auth_version: 2
        }
      }

      assert {:noreply, state} =
               Client.handle_info(
                 {:async_post_result, {:ok, state.transport_state}, meta_a},
                 state
               )

      assert state.transport_state.access_token == "T2"
      assert state.transport_state.auth_version == 2

      # Task B (started at v0 snapshot) hits 401, allocates version from client
      ref_b = make_ref()

      assert {:noreply, state} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid_b, ref_b}, state)

      assert_receive {:http_post_auth_version, ^ref_b, 3}

      # Task B obtains newer token T3 with version 3
      meta_b = %{
        request_id: 102,
        state_changes: %{
          access_token: "T3",
          headers: [{"Authorization", "Bearer T3"}],
          auth_version: 3
        }
      }

      assert {:noreply, state} =
               Client.handle_info(
                 {:async_post_result, {:ok, state.transport_state}, meta_b},
                 state
               )

      # T3 is accepted and becomes active!
      assert state.transport_state.access_token == "T3"
      assert state.transport_state.auth_version == 3
      assert state.transport_state.headers == [{"Authorization", "Bearer T3"}]
    end

    test "two single-step flows: delayed older v1 result cannot overwrite newer v2 credentials" do
      task_ref_a = make_ref()
      task_ref_b = make_ref()
      task_pid_a = self()
      task_pid_b = self()

      ts = %HTTP{
        session_id: "s1",
        access_token: nil,
        headers: [],
        auth_version: 0,
        auth_version_allocator: 0
      }

      state =
        client_state(
          connection_status: :connected,
          transport_mod: HTTP,
          transport_state: ts,
          async_post_tasks: %{
            task_ref_a => {task_pid_a, 101},
            task_ref_b => {task_pid_b, 102}
          }
        )

      # Task A hits 401, allocates v1 from client
      ref_a = make_ref()

      assert {:noreply, state} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid_a, ref_a}, state)

      assert_receive {:http_post_auth_version, ^ref_a, 1}

      # Task B hits 401, allocates v2 from client
      ref_b = make_ref()

      assert {:noreply, state} =
               Client.handle_info({:http_post_allocate_auth_version, task_pid_b, ref_b}, state)

      assert_receive {:http_post_auth_version, ^ref_b, 2}

      # Task B completes first with T2 at version 2
      meta_b = %{
        request_id: 102,
        state_changes: %{
          access_token: "T2",
          headers: [{"Authorization", "Bearer T2"}],
          auth_version: 2
        }
      }

      assert {:noreply, state} =
               Client.handle_info(
                 {:async_post_result, {:ok, state.transport_state}, meta_b},
                 state
               )

      assert state.transport_state.access_token == "T2"
      assert state.transport_state.auth_version == 2

      # Delayed Task A arrives later with older token T1 at version 1
      meta_a = %{
        request_id: 101,
        state_changes: %{
          session_id: "session_by_a",
          access_token: "T1",
          headers: [{"Authorization", "Bearer T1"}],
          auth_version: 1
        }
      }

      assert {:noreply, state} =
               Client.handle_info(
                 {:async_post_result, {:ok, state.transport_state}, meta_a},
                 state
               )

      # T1 does NOT overwrite T2; T2 and version 2 remain active
      assert state.transport_state.access_token == "T2"
      assert state.transport_state.auth_version == 2
      assert state.transport_state.headers == [{"Authorization", "Bearer T2"}]
      # Non-credential changes are merged
      assert state.transport_state.session_id == "session_by_a"
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

    test "401 challenge on notification POST after disconnect is ignored and does not crash" do
      state =
        client_state(
          connection_status: :disconnected,
          transport_state: nil,
          async_post_tasks: %{}
        )

      meta = %{task_ref: make_ref(), request_id: nil}
      challenge = {:error, {:reauthenticate, %{"method" => "notifications/cancelled"}}}

      assert {:noreply, ^state} =
               Client.handle_info({:async_post_result, challenge, meta}, state)
    end

    test "old tools/list result with untracked task_ref does not overwrite header cache" do
      ts = %HTTP{tool_headers: %{"tool_new" => [%{}]}}
      state = client_state(transport_mod: HTTP, transport_state: ts, async_post_tasks: %{})

      old_response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{
            "tools" => [%{"name" => "tool_old", "inputSchema" => %{"type" => "object"}}]
          }
        })

      meta = %{task_ref: make_ref(), request_id: 1, tool_list: {:first, 1}}

      assert {:noreply, new_state} =
               Client.handle_info({:async_post_result, {:ok, ts, old_response}, meta}, state)

      assert Map.has_key?(new_state.transport_state.tool_headers, "tool_new")
      refute Map.has_key?(new_state.transport_state.tool_headers, "tool_old")
    end
  end

  describe "tools/list header cache generation handling" do
    test "cursor page completing before first page retains both pages' tools" do
      ts = %HTTP{}

      cursor_response =
        Jason.encode!(%{
          "result" => %{
            "tools" => [%{"name" => "tool_page2", "inputSchema" => %{"type" => "object"}}]
          }
        })

      ts = HTTP.cache_tool_list(ts, {:cursor, 1}, cursor_response)
      assert Map.has_key?(ts.tool_headers, "tool_page2")

      first_response =
        Jason.encode!(%{
          "result" => %{
            "tools" => [%{"name" => "tool_page1", "inputSchema" => %{"type" => "object"}}]
          }
        })

      ts = HTTP.cache_tool_list(ts, {:first, 1}, first_response)
      assert Map.has_key?(ts.tool_headers, "tool_page1")
      assert Map.has_key?(ts.tool_headers, "tool_page2")
    end

    test "fresh first page resets tool headers cache and discards stale pages" do
      ts = %HTTP{}

      # Generation 1
      gen1_response =
        Jason.encode!(%{
          "result" => %{
            "tools" => [%{"name" => "tool_gen1", "inputSchema" => %{"type" => "object"}}]
          }
        })

      ts = HTTP.cache_tool_list(ts, {:first, 1}, gen1_response)
      assert Map.has_key?(ts.tool_headers, "tool_gen1")

      # Generation 2 fresh first page legitimately resets
      gen2_response =
        Jason.encode!(%{
          "result" => %{
            "tools" => [%{"name" => "tool_gen2", "inputSchema" => %{"type" => "object"}}]
          }
        })

      ts = HTTP.cache_tool_list(ts, {:first, 2}, gen2_response)
      assert Map.has_key?(ts.tool_headers, "tool_gen2")
      refute Map.has_key?(ts.tool_headers, "tool_gen1")

      # Stale cursor page from generation 1 arrives late
      stale_response =
        Jason.encode!(%{
          "result" => %{
            "tools" => [%{"name" => "tool_stale", "inputSchema" => %{"type" => "object"}}]
          }
        })

      ts = HTTP.cache_tool_list(ts, {:cursor, 1}, stale_response)
      refute Map.has_key?(ts.tool_headers, "tool_stale")
      assert Map.has_key?(ts.tool_headers, "tool_gen2")
    end
  end
end
