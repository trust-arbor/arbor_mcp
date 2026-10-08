defmodule Arbor.MCP.SessionManagerTest do
  @moduledoc """
  Tests for Arbor.MCP.SessionManager.

  Tests session lifecycle management, event storage and replay,
  session expiration, and integration with SSE transport.
  """
  use ExUnit.Case, async: false

  alias Arbor.MCP.SessionManager

  setup do
    # Generate a unique name for this test's session manager
    name = :"test_session_manager_#{System.unique_integer([:positive])}"

    # Start a separate session manager under ExUnit's per-test supervisor.
    # This avoids racing a linked process exit against an on_exit/1 stop call.
    pid =
      start_supervised!({
        SessionManager,
        [
          name: name,
          max_events_per_session: 100,
          session_ttl_seconds: 1,
          cleanup_interval_ms: 100
        ]
      })

    {:ok, session_manager: pid, session_manager_name: name}
  end

  describe "session lifecycle" do
    test "creates new sessions with unique IDs", %{session_manager_name: name} do
      session_id1 = GenServer.call(name, {:create_session, %{transport: :sse}})
      session_id2 = GenServer.call(name, {:create_session, %{transport: :http}})

      assert is_binary(session_id1)
      assert is_binary(session_id2)
      assert session_id1 != session_id2
    end

    test "stores session metadata", %{session_manager_name: name} do
      metadata = %{
        transport: :sse,
        client_info: %{user_agent: "test-client/1.0", ip: "127.0.0.1"}
      }

      session_id = GenServer.call(name, {:create_session, metadata})
      {:ok, session} = GenServer.call(name, {:get_session, session_id})

      assert session.id == session_id
      assert session.transport == :sse
      assert session.client_info == metadata.client_info
      assert session.status == :active
      assert is_integer(session.created_at)
      assert is_integer(session.last_activity)
      assert session.event_count == 0
    end

    test "updates session metadata and activity", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})
      {:ok, original_session} = GenServer.call(name, {:get_session, session_id})

      # Sleep briefly to ensure timestamp difference
      Process.sleep(1)

      updates = %{client_info: %{version: "2.0"}}
      :ok = GenServer.call(name, {:update_session, session_id, updates})

      {:ok, updated_session} = GenServer.call(name, {:get_session, session_id})
      assert updated_session.client_info == updates.client_info
      assert updated_session.last_activity > original_session.last_activity
    end

    test "terminates sessions", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})
      :ok = GenServer.call(name, {:terminate_session, session_id})

      {:ok, session} = GenServer.call(name, {:get_session, session_id})
      assert session.status == :terminated
    end

    test "handles non-existent sessions gracefully", %{session_manager_name: name} do
      assert {:error, :session_not_found} = GenServer.call(name, {:get_session, "non-existent"})

      assert {:error, :session_not_found} =
               GenServer.call(name, {:update_session, "non-existent", %{}})

      assert :ok = GenServer.call(name, {:terminate_session, "non-existent"})
    end

    test "does not create caller-selected session IDs", %{session_manager_name: name} do
      assert {:error, :session_not_found} =
               GenServer.call(name, {
                 :ensure_session,
                 "caller-selected",
                 %{transport: :http, principal_id: "principal-1"}
               })

      assert {:error, :session_not_found} =
               GenServer.call(name, {:get_session, "caller-selected"})
    end

    test "binds authorization identity immutably", %{session_manager_name: name} do
      identity = %{
        transport: :http,
        principal_id: "principal-1",
        tenant_id: "tenant-1",
        issuer: "https://auth.test",
        audience: "https://mcp.test/mcp"
      }

      session_id = GenServer.call(name, {:create_session, identity})

      assert :ok = GenServer.call(name, {:ensure_session, session_id, identity})

      assert {:error, :session_identity_mismatch} =
               GenServer.call(name, {:ensure_session, session_id, %{transport: :http}})

      assert {:error, :session_identity_mismatch} =
               GenServer.call(
                 name,
                 {:ensure_session, session_id, %{identity | principal_id: "principal-2"}}
               )

      assert {:error, :session_identity_mismatch} =
               GenServer.call(name, {
                 :update_session,
                 session_id,
                 %{principal_id: "principal-2"}
               })

      assert {:ok, session} = GenServer.call(name, {:get_session, session_id})
      assert session.principal_id == "principal-1"
    end

    test "binds a protocol version only through completed initialization", %{
      session_manager_name: name
    } do
      session_id =
        GenServer.call(name, {
          :create_session,
          %{transport: :http, protocol_version: "2025-11-25"}
        })

      assert {:ok, %{initialized: false, protocol_version: nil}} =
               GenServer.call(name, {:get_session, session_id})

      assert :ok = GenServer.call(name, {:claim_initialization, session_id})

      assert :ok =
               GenServer.call(name, {
                 :complete_initialization,
                 session_id,
                 "2025-11-25"
               })

      assert :ok =
               GenServer.call(name, {
                 :ensure_session,
                 session_id,
                 %{transport: :sse, client_info: %{name: "resumed"}}
               })

      assert {:ok, %{protocol_version: "2025-11-25"}} =
               GenServer.call(name, {:get_session, session_id})

      assert :ok =
               GenServer.call(name, {
                 :update_session,
                 session_id,
                 %{protocol_version: "2025-11-25"}
               })

      assert {:error, :session_protocol_version_mismatch} =
               GenServer.call(name, {
                 :update_session,
                 session_id,
                 %{protocol_version: "2025-03-26"}
               })

      unbound = GenServer.call(name, {:create_session, %{transport: :http}})

      assert {:error, :session_protocol_version_mismatch} =
               GenServer.call(name, {
                 :update_session,
                 unbound,
                 %{protocol_version: "2025-03-26"}
               })

      assert {:ok, %{initialized: false, protocol_version: nil}} =
               GenServer.call(name, {:get_session, unbound})
    end

    test "claims and completes initialization exactly once", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :http}})

      assert :ok = GenServer.call(name, {:claim_initialization, session_id})

      assert {:error, :initialization_in_progress} =
               GenServer.call(name, {:claim_initialization, session_id})

      assert :ok =
               GenServer.call(name, {
                 :complete_initialization,
                 session_id,
                 "2025-11-25"
               })

      assert {:ok,
              %{
                initialized: true,
                initialization_claimed: false,
                protocol_version: "2025-11-25"
              }} = GenServer.call(name, {:get_session, session_id})

      assert {:error, :session_already_initialized} =
               GenServer.call(name, {:claim_initialization, session_id})

      assert :ok =
               GenServer.call(name, {:update_session, session_id, %{initialized: false}})

      assert {:ok, %{initialized: true}} = GenServer.call(name, {:get_session, session_id})
    end

    test "refuses to complete an initialization that was not claimed", %{
      session_manager_name: name
    } do
      session_id = GenServer.call(name, {:create_session, %{transport: :http}})

      assert {:error, :initialization_not_claimed} =
               GenServer.call(name, {
                 :complete_initialization,
                 session_id,
                 "2025-11-25"
               })
    end

    test "terminates an uncompleted initialization when its request process dies", %{
      session_manager_name: name
    } do
      session_id = GenServer.call(name, {:create_session, %{transport: :http}})
      parent = self()

      owner =
        spawn(fn ->
          result = GenServer.call(name, {:claim_initialization, session_id})
          send(parent, {:initialization_claimed, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:initialization_claimed, :ok}
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

      assert_eventually(fn ->
        match?(
          {:ok, %{status: :terminated, initialization_claimed: false}},
          GenServer.call(name, {:get_session, session_id})
        )
      end)
    end

    test "bounds session allocation and reclaims terminated entries" do
      name = :"bounded_session_manager_#{System.unique_integer([:positive])}"

      manager =
        start_supervised!(
          {
            SessionManager,
            [name: name, max_sessions: 1, cleanup_interval_ms: 60_000]
          },
          id: make_ref()
        )

      first = GenServer.call(manager, {:create_session, %{transport: :http}})
      assert is_binary(first)

      assert {:error, :session_limit_exceeded} =
               GenServer.call(manager, {:create_session, %{transport: :http}})

      assert :ok = GenServer.call(manager, {:terminate_session, first})

      replacement = GenServer.call(manager, {:create_session, %{transport: :http}})
      assert is_binary(replacement)
      assert replacement != first
      assert {:error, :session_not_found} = GenServer.call(manager, {:get_session, first})
    end
  end

  describe "request ID claims" do
    test "atomically rejects duplicate IDs within one session", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :http}})

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> GenServer.call(name, {:claim_request_id, session_id, "same-id"}) end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :duplicate_request_id})) == 7

      other_session = GenServer.call(name, {:create_session, %{transport: :http}})
      assert :ok = GenServer.call(name, {:claim_request_id, other_session, "same-id"})
    end

    test "fails closed at the configured per-session request ID cap" do
      name = :"request_id_cap_#{System.unique_integer([:positive])}"

      manager =
        start_supervised!(
          {SessionManager, name: name, max_request_ids: 1, cleanup_interval_ms: 60_000},
          id: make_ref()
        )

      session_id = GenServer.call(manager, {:create_session, %{transport: :http}})

      assert :ok = GenServer.call(manager, {:claim_request_id, session_id, 1})

      assert {:error, :duplicate_request_id} =
               GenServer.call(manager, {:claim_request_id, session_id, 1})

      assert {:error, :request_id_limit_exceeded} =
               GenServer.call(manager, {:claim_request_id, session_id, 2})

      assert {:ok, %{request_id_count: 1}} =
               GenServer.call(manager, {:get_session, session_id})
    end
  end

  describe "event storage and replay" do
    test "append_event assigns monotonic store-owned IDs", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      assert {:ok, first} =
               GenServer.call(name, {:append_event, session_id, "message", %{index: 1}})

      assert {:ok, second} =
               GenServer.call(name, {:append_event, session_id, "message", %{index: 2}})

      assert first.id != second.id
      assert first.id == "1-0"
      assert second.id == "2-0"

      assert [^second] =
               GenServer.call(name, {:replay_events_after, session_id, first.id})
    end

    test "stores events for sessions", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      event = %{
        id: "event-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      assert :ok = GenServer.call(name, {:store_event, session_id, event})

      # Verify session event count is updated
      {:ok, session} = GenServer.call(name, {:get_session, session_id})
      assert session.event_count == 1
    end

    test "stores multiple events and maintains order", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      events = [
        %{
          id: "event-1",
          session_id: session_id,
          type: "notification",
          data: %{message: "First"},
          timestamp: System.system_time(:microsecond)
        },
        %{
          id: "event-2",
          session_id: session_id,
          type: "notification",
          data: %{message: "Second"},
          timestamp: System.system_time(:microsecond) + 1000
        },
        %{
          id: "event-3",
          session_id: session_id,
          type: "notification",
          data: %{message: "Third"},
          timestamp: System.system_time(:microsecond) + 2000
        }
      ]

      Enum.each(events, &GenServer.call(name, {:store_event, session_id, &1}))

      # Verify all events can be replayed
      replayed_events = GenServer.call(name, {:replay_events_after, session_id, nil})
      assert length(replayed_events) == 3

      # Events should be in timestamp order
      messages = Enum.map(replayed_events, & &1.data.message)
      assert messages == ["First", "Second", "Third"]
    end

    test "replays events after specific event ID", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      # Create events with sortable IDs
      base_time = System.system_time(:microsecond)

      events = [
        %{
          id: "#{base_time}-1",
          session_id: session_id,
          type: "notification",
          data: %{message: "First"},
          timestamp: base_time
        },
        %{
          id: "#{base_time}-2",
          session_id: session_id,
          type: "notification",
          data: %{message: "Second"},
          timestamp: base_time + 1000
        },
        %{
          id: "#{base_time}-3",
          session_id: session_id,
          type: "notification",
          data: %{message: "Third"},
          timestamp: base_time + 2000
        }
      ]

      Enum.each(events, &GenServer.call(name, {:store_event, session_id, &1}))

      # Replay events after the first event
      replayed_events = GenServer.call(name, {:replay_events_after, session_id, "#{base_time}-1"})
      assert length(replayed_events) == 2

      messages = Enum.map(replayed_events, & &1.data.message)
      assert messages == ["Second", "Third"]
    end

    test "handles event replay for non-existent sessions", %{session_manager_name: name} do
      result = GenServer.call(name, {:replay_events_after, "non-existent", nil})
      assert result == {:error, :session_not_found}
    end

    test "prevents storing events for terminated sessions", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})
      :ok = GenServer.call(name, {:terminate_session, session_id})

      event = %{
        id: "event-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      assert {:error, :session_not_found} =
               GenServer.call(name, {:store_event, session_id, event})
    end
  end

  describe "SSE handler integration" do
    setup do
      start_supervised!(SessionManager, id: make_ref())
      :ok
    end

    test "replays events to SSE handler process" do
      # Explicit host supervision supplies the retained default-name façade.
      # The 3-argument replay API intentionally addresses that standalone owner.
      session_id = SessionManager.create_session(%{transport: :sse})

      # Create a mock SSE handler process
      test_pid = self()

      mock_handler =
        spawn_link(fn ->
          receive do
            {:"$gen_cast", {:send_event, type, data, opts}} ->
              send(test_pid, {:received_event, type, data, opts})
          after
            1000 -> :timeout
          end
        end)

      # Store an event
      event = %{
        id: "event-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      SessionManager.store_event(session_id, event)

      # Replay events to the handler (this function exists in the module API)
      :ok = SessionManager.replay_events_after(session_id, nil, mock_handler)

      # Verify the handler received the event
      assert_receive {:received_event, "notification", %{message: "Hello"},
                      [event_id: "event-1", persist: false]},
                     1000
    end

    test "handles dead handler processes gracefully" do
      session_id = SessionManager.create_session(%{transport: :sse})

      # Create and kill a handler process
      dead_handler = spawn(fn -> :ok end)
      Process.exit(dead_handler, :kill)
      # Ensure process is dead
      Process.sleep(10)

      # Store an event
      event = %{
        id: "event-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      SessionManager.store_event(session_id, event)

      # Should not crash when trying to send to dead process
      assert :ok = SessionManager.replay_events_after(session_id, nil, dead_handler)
    end
  end

  describe "session management" do
    test "lists active sessions", %{session_manager_name: name} do
      session_id1 = GenServer.call(name, {:create_session, %{transport: :sse}})
      session_id2 = GenServer.call(name, {:create_session, %{transport: :http}})
      session_id3 = GenServer.call(name, {:create_session, %{transport: :sse}})

      # Terminate one session
      GenServer.call(name, {:terminate_session, session_id2})

      sessions = GenServer.call(name, :list_sessions)
      active_ids = Enum.map(sessions, & &1.id)

      assert length(sessions) == 2
      assert session_id1 in active_ids
      assert session_id3 in active_ids
      assert session_id2 not in active_ids
    end

    test "provides session statistics", %{session_manager_name: name} do
      # Create some sessions and events
      session_id1 = GenServer.call(name, {:create_session, %{transport: :sse}})
      session_id2 = GenServer.call(name, {:create_session, %{transport: :http}})

      # Add events to first session
      for i <- 1..3 do
        event = %{
          id: "event-#{i}",
          session_id: session_id1,
          type: "notification",
          data: %{counter: i},
          timestamp: System.system_time(:microsecond)
        }

        GenServer.call(name, {:store_event, session_id1, event})
      end

      # Terminate second session
      GenServer.call(name, {:terminate_session, session_id2})

      stats = GenServer.call(name, :get_stats)
      assert stats.total_sessions == 2
      assert stats.active_sessions == 1
      assert stats.total_events == 3
      assert is_integer(stats.memory_usage)
      assert stats.memory_usage > 0
    end
  end

  describe "event limits and cleanup" do
    test "accepts an exactly-sized replay event and rejects one encoded byte over" do
      placeholder_session_id = String.duplicate("s", 22)
      payload = String.duplicate("x", 128)
      template = replay_event(placeholder_session_id, "event-1", payload)
      exact_bytes = encoded_bytes(template)
      name = :"event_byte_limit_#{System.unique_integer([:positive])}"

      manager =
        start_supervised!(
          {SessionManager,
           name: name,
           max_event_bytes: exact_bytes,
           max_replay_bytes_per_session: exact_bytes * 2,
           cleanup_interval_ms: 60_000},
          id: make_ref()
        )

      session_id = GenServer.call(manager, {:create_session, %{transport: :sse}})
      exact = replay_event(session_id, "event-1", payload)
      one_over = replay_event(session_id, "event-2", payload <> "x")

      assert encoded_bytes(exact) == exact_bytes
      assert encoded_bytes(one_over) == exact_bytes + 1
      assert :ok = GenServer.call(manager, {:store_event, session_id, exact})

      assert {:error, :event_too_large} =
               GenServer.call(manager, {:store_event, session_id, one_over})

      assert [^exact] = GenServer.call(manager, {:replay_events_after, session_id, nil})

      assert {:ok, %{event_count: 1, replay_bytes: ^exact_bytes}} =
               GenServer.call(manager, {:get_session, session_id})
    end

    test "evicts oldest replay events when a replacement exceeds the byte budget by one" do
      placeholder_session_id = String.duplicate("s", 22)
      payload = String.duplicate("x", 128)
      template = replay_event(placeholder_session_id, "event-1", payload)
      event_bytes = encoded_bytes(template)
      replay_budget = event_bytes * 2
      name = :"replay_byte_budget_#{System.unique_integer([:positive])}"

      manager =
        start_supervised!(
          {SessionManager,
           name: name,
           max_event_bytes: event_bytes + 1,
           max_replay_bytes_per_session: replay_budget,
           cleanup_interval_ms: 60_000},
          id: make_ref()
        )

      session_id = GenServer.call(manager, {:create_session, %{transport: :sse}})
      first = replay_event(session_id, "event-1", payload)
      second = replay_event(session_id, "event-2", payload)
      replacement = replay_event(session_id, "event-2", payload <> "x")

      assert :ok = GenServer.call(manager, {:store_event, session_id, first})
      assert :ok = GenServer.call(manager, {:store_event, session_id, second})

      assert {:ok, %{event_count: 2, replay_bytes: ^replay_budget}} =
               GenServer.call(manager, {:get_session, session_id})

      assert encoded_bytes(first) + encoded_bytes(replacement) == replay_budget + 1
      assert :ok = GenServer.call(manager, {:store_event, session_id, replacement})

      assert [^replacement] =
               GenServer.call(manager, {:replay_events_after, session_id, nil})

      replacement_bytes = event_bytes + 1

      assert {:ok, %{event_count: 1, replay_bytes: ^replacement_bytes}} =
               GenServer.call(manager, {:get_session, session_id})

      assert :ok = GenServer.call(manager, {:terminate_session, session_id})

      assert {:ok, %{event_count: 0, replay_bytes: 0}} =
               GenServer.call(manager, {:get_session, session_id})
    end

    test "trims old events when limit is exceeded" do
      # Use a small event limit for testing
      name = :"test_event_limit_#{System.unique_integer([:positive])}"
      {:ok, manager} = SessionManager.start_link(name: name, max_events_per_session: 2)

      session_id = GenServer.call(manager, {:create_session, %{transport: :sse}})

      # Store enough events to catch counters that repeatedly over-trim after
      # the first eviction.
      events =
        for i <- 1..5 do
          %{
            id: "event-#{i}",
            session_id: session_id,
            type: "notification",
            data: %{message: "event-#{i}"},
            timestamp: System.system_time(:microsecond) + i * 1000
          }
        end

      Enum.each(events, &GenServer.call(manager, {:store_event, session_id, &1}))

      # Should only have the latest 2 events
      replayed_events = GenServer.call(manager, {:replay_events_after, session_id, nil})
      assert length(replayed_events) == 2

      messages = Enum.map(replayed_events, & &1.data.message)
      assert messages == ["event-4", "event-5"]

      GenServer.stop(manager)
    end

    test "cleans up expired sessions" do
      # Use very short TTL for testing
      name = :"test_session_manager_cleanup_#{System.unique_integer([:positive])}"

      {:ok, manager} =
        SessionManager.start_link(
          name: name,
          # Immediate expiration
          session_ttl_seconds: 0,
          cleanup_interval_ms: 50
        )

      session_id = GenServer.call(manager, {:create_session, %{transport: :sse}})

      # Add an event
      event = %{
        id: "event-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      GenServer.call(manager, {:store_event, session_id, event})

      # Wait for cleanup to run
      Process.sleep(100)

      # Session should be terminated
      {:ok, session} = GenServer.call(manager, {:get_session, session_id})
      assert session.status == :terminated

      GenServer.stop(manager)
    end
  end

  describe "edge cases" do
    test "handles empty event replay", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})
      events = GenServer.call(name, {:replay_events_after, session_id, nil})
      assert events == []
    end

    test "handles event replay with future event ID", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      # Store one event
      event = %{
        id: "#{System.system_time(:microsecond)}-1",
        session_id: session_id,
        type: "notification",
        data: %{message: "Hello"},
        timestamp: System.system_time(:microsecond)
      }

      GenServer.call(name, {:store_event, session_id, event})

      # Request events after a future ID
      future_id = "#{System.system_time(:microsecond) + 10000}-999"
      events = GenServer.call(name, {:replay_events_after, session_id, future_id})
      assert events == []
    end

    test "handles invalid event ID formats", %{session_manager_name: name} do
      session_id = GenServer.call(name, {:create_session, %{transport: :sse}})

      # Store events with non-standard IDs
      events = [
        %{
          id: "custom-event-1",
          session_id: session_id,
          type: "notification",
          data: %{message: "First"},
          timestamp: System.system_time(:microsecond)
        },
        %{
          id: "custom-event-2",
          session_id: session_id,
          type: "notification",
          data: %{message: "Second"},
          timestamp: System.system_time(:microsecond) + 1000
        }
      ]

      Enum.each(events, &GenServer.call(name, {:store_event, session_id, &1}))

      # Should fallback to string comparison
      replayed_events = GenServer.call(name, {:replay_events_after, session_id, "custom-event-1"})
      assert length(replayed_events) == 1
      assert hd(replayed_events).data.message == "Second"
    end
  end

  defp replay_event(session_id, event_id, payload) do
    %{
      id: event_id,
      session_id: session_id,
      type: "notification",
      data: %{"payload" => payload},
      timestamp: 1
    }
  end

  defp encoded_bytes(event), do: event |> Jason.encode!() |> byte_size()

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
