defmodule Arbor.MCP.SessionStoreContractTest do
  @moduledoc """
  Event-store contract suite for the default ETS backend and opt-in DETS.

  Pins current `Arbor.MCP.SessionManager` behavior as the accepted 1.x store
  contract from `https://github.com/trust-arbor/arbor_mcp/blob/v1.6.0/docs/STORE_ADAPTER.md`. Isolated managers use unique names
  so they do not fight the explicitly supervised standalone SessionManager.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionStoreContract

  describe "atomic append returning a store-owned opaque event ID" do
    test "append_event assigns unique store-owned IDs and returns the retained event" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      assert {:ok, first} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{index: 1})

      assert {:ok, second} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{index: 2})

      assert first.session_id == session_id
      assert second.session_id == session_id
      assert first.type == "message"
      assert first.data == %{index: 1}
      assert is_binary(first.id)
      assert is_binary(second.id)
      assert first.id != second.id
      assert is_integer(first.timestamp)

      # Current ETS representation. Clients must still treat IDs as opaque.
      assert first.id == "1-0"
      assert second.id == "2-0"

      assert [^first, ^second] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "serialized concurrent appends each receive a distinct store-owned ID" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn ->
            SessionStoreContract.append_event(store.name, session_id, "message", %{i: i})
          end)
        end)
        |> Task.await_many()

      events = Enum.map(results, fn {:ok, event} -> event end)
      ids = Enum.map(events, & &1.id)

      assert length(events) == 8
      assert ids == Enum.uniq(ids)

      replayed = SessionStoreContract.replay_events_after(store.name, session_id, nil)
      assert Enum.map(replayed, & &1.id) == Enum.sort_by(ids, &parse_store_id/1)
    end

    test "append_event refuses unknown or terminated sessions" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      :ok = SessionStoreContract.terminate_session(store.name, session_id)

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, "missing", "message", %{})

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{})
    end
  end

  describe "ordered replay after an exact cursor" do
    test "replays the suffix after an exact store-owned cursor" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})

      {:ok, third} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 3})

      assert [] == SessionStoreContract.replay_events_after(store.name, session_id, third.id)

      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, first.id)

      assert [^first, ^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "unknown session returns session_not_found" do
      store = SessionStoreContract.start_isolated!()

      assert {:error, :session_not_found} =
               SessionStoreContract.replay_events_after(store.name, "missing", nil)
    end

    test "an unretained cursor uses compare-id fallback rather than resurrecting events" do
      store = SessionStoreContract.start_isolated!(max_events_per_session: 2)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})

      {:ok, third} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 3})

      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)

      # first.id is no longer retained; current fallback still returns later IDs.
      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, first.id)

      assert [^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, second.id)
    end
  end

  describe "bounded retention and cursor-eviction" do
    test "keeps only the newest events when the count bound is exceeded" do
      store = SessionStoreContract.start_isolated!(max_events_per_session: 2)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      Enum.each(1..4, fn n ->
        assert {:ok, _} =
                 SessionStoreContract.append_event(store.name, session_id, "message", %{n: n})
      end)

      replayed = SessionStoreContract.replay_events_after(store.name, session_id, nil)
      assert Enum.map(replayed, & &1.data.n) == [3, 4]

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.event_count == 2
    end

    test "rejects a single event over the encoded byte cap" do
      payload = String.duplicate("x", 64)
      template = caller_event(String.duplicate("s", 22), "event-1", payload)
      exact_bytes = encoded_bytes(template)

      store =
        SessionStoreContract.start_isolated!(
          max_event_bytes: exact_bytes,
          max_replay_bytes_per_session: exact_bytes * 4
        )

      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      exact = caller_event(session_id, "event-1", payload)
      one_over = caller_event(session_id, "event-2", payload <> "x")

      assert encoded_bytes(exact) == exact_bytes
      assert :ok = SessionStoreContract.store_event(store.name, session_id, exact)

      assert {:error, :event_too_large} =
               SessionStoreContract.store_event(store.name, session_id, one_over)

      assert [^exact] = SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end
  end

  describe "session TTL and explicit deletion" do
    test "created_at and last_activity are wall-clock system_time timestamps" do
      store = SessionStoreContract.start_isolated!()
      before = System.system_time(:microsecond)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      after_create = System.system_time(:microsecond)
      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)

      assert session.created_at >= before
      assert session.created_at <= after_create
      assert session.last_activity >= before
      assert session.last_activity <= after_create

      # Monotonic time uses a different epoch; TTL must not switch to it.
      monotonic = System.monotonic_time(:microsecond)
      assert abs(session.last_activity - before) < abs(session.last_activity - monotonic)
    end

    test "explicit terminate clears events and refuses further appends" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, _event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      assert :ok = SessionStoreContract.terminate_session(store.name, session_id)
      assert :ok = SessionStoreContract.terminate_session(store.name, "never-existed")

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.status == :terminated
      assert session.event_count == 0
      assert session.replay_bytes == 0

      assert [] = SessionStoreContract.replay_events_after(store.name, session_id, nil)

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})
    end

    test "wall-clock idle TTL expires the session and drops its events" do
      store =
        SessionStoreContract.start_isolated!(
          session_ttl_seconds: 0,
          cleanup_interval_ms: 60_000
        )

      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, _event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      # TTL 0 expires on any later wall-clock sample; do not race the timer
      # between create and append under coverage load.
      Process.sleep(1)
      send(store.pid, :cleanup_expired_sessions)

      assert_eventually(fn ->
        match?(
          {:ok, %{status: :terminated, event_count: 0}},
          SessionStoreContract.get_session(store.name, session_id)
        )
      end)

      assert [] = SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end
  end

  describe "idempotent overwrite and deduplication" do
    test "store_event overwrites the same caller-supplied event ID in place" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      first = caller_event(session_id, "same-id", "one")
      second = caller_event(session_id, "same-id", "two")

      assert :ok = SessionStoreContract.store_event(store.name, session_id, first)
      assert :ok = SessionStoreContract.store_event(store.name, session_id, second)

      assert [^second] = SessionStoreContract.replay_events_after(store.name, session_id, nil)

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.event_count == 1
    end

    test "append_event is not content-addressed; duplicates allocate new IDs" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      payload = %{same: "payload"}

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", payload)

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", payload)

      assert first.id != second.id
      assert first.data == second.data

      assert [^first, ^second] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "claim_request_id is the JSON-RPC dedup story" do
      store = SessionStoreContract.start_isolated!(max_request_ids: 1)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :http})

      assert :ok = SessionStoreContract.claim_request_id(store.name, session_id, "req-1")

      assert {:error, :duplicate_request_id} =
               SessionStoreContract.claim_request_id(store.name, session_id, "req-1")

      assert {:error, :request_id_limit_exceeded} =
               SessionStoreContract.claim_request_id(store.name, session_id, "req-2")

      other = SessionStoreContract.create_session(store.name, %{transport: :http})
      assert :ok = SessionStoreContract.claim_request_id(store.name, other, "req-1")
    end
  end

  describe "adapter ownership and restart" do
    test "ETS tables are process-owned and a restart starts empty" do
      store = SessionStoreContract.start_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      state = :sys.get_state(store.pid)
      assert is_reference(state.sessions_table)
      assert is_reference(state.events_table)
      assert is_reference(state.request_ids_table)
      assert :ets.info(state.sessions_table, :owner) == store.pid

      name = store.name
      sessions_table = state.sessions_table
      :ok = ExUnit.Callbacks.stop_supervised(store.id)

      refute Process.alive?(store.pid)
      assert :ets.info(sessions_table) == :undefined

      restarted = SessionStoreContract.start_isolated!(name: name)

      assert {:error, :session_not_found} =
               SessionStoreContract.get_session(restarted.name, session_id)

      assert {:error, :session_not_found} =
               SessionStoreContract.replay_events_after(restarted.name, session_id, event.id)
    end

    test "storage_backend :persistent_term is accepted, warns, and still uses ETS" do
      log =
        capture_log(fn ->
          store = SessionStoreContract.start_isolated!(storage_backend: :persistent_term)
          state = :sys.get_state(store.pid)

          assert state.config.storage_backend == :persistent_term
          assert is_reference(state.sessions_table)
          assert :ets.info(state.sessions_table) != :undefined

          session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

          assert {:ok, event} =
                   SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

          assert [^event] =
                   SessionStoreContract.replay_events_after(store.name, session_id, nil)

          name = store.name
          :ok = ExUnit.Callbacks.stop_supervised(store.id)

          restarted =
            SessionStoreContract.start_isolated!(storage_backend: :persistent_term, name: name)

          assert {:error, :session_not_found} =
                   SessionStoreContract.get_session(restarted.name, session_id)
        end)

      assert log =~ "persistent_term"
      assert log =~ "ETS"
      assert log =~ "no-op durability"
    end
  end

  describe "telemetry and logs exclude event payloads by default" do
    test "SessionManager emits no store telemetry and does not log payloads" do
      handler_id = "session-store-contract-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:arbor_mcp, :session_manager],
            [:arbor_mcp, :session_store],
            [:arbor_mcp, :session, :event],
            [:arbor_mcp, :store]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:store_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      secret = "session-store-contract-secret-payload"

      log =
        capture_log(fn ->
          store = SessionStoreContract.start_isolated!()
          session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

          {:ok, event} =
            SessionStoreContract.append_event(store.name, session_id, "message", %{
              secret: secret
            })

          assert [^event] =
                   SessionStoreContract.replay_events_after(store.name, session_id, nil)

          stats = SessionStoreContract.get_stats(store.name)
          assert stats.total_sessions == 1
          assert stats.active_sessions == 1
          assert stats.total_events == 1
          assert is_integer(stats.memory_usage)
          refute Map.has_key?(stats, :events)
          refute Map.has_key?(stats, :payloads)
        end)

      refute_received {:store_telemetry, _, _, _}
      refute log =~ secret
    end
  end

  describe "standalone SessionManager public API" do
    setup do
      start_supervised!({SessionManager, []}, id: make_ref())
      :ok
    end

    test "global public functions still implement the same append/replay contract" do
      # Uses this describe's explicitly supervised standalone owner.
      session_id = SessionManager.create_session(%{transport: :sse})

      assert {:ok, first} = SessionManager.append_event(session_id, "message", %{n: 1})
      assert {:ok, second} = SessionManager.append_event(session_id, "message", %{n: 2})
      assert is_binary(first.id)
      assert first.id != second.id
      assert [^second] = SessionManager.replay_events_after(session_id, first.id)

      :ok = SessionManager.terminate_session(session_id)
      {:ok, session} = SessionManager.get_session(session_id)
      assert session.status == :terminated
    end
  end

  describe "DETS opt-in backend" do
    test "append_event assigns unique store-owned IDs and returns the retained event" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      assert {:ok, first} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{index: 1})

      assert {:ok, second} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{index: 2})

      assert first.session_id == session_id
      assert second.session_id == session_id
      assert first.type == "message"
      assert first.data == %{index: 1}
      assert is_binary(first.id)
      assert is_binary(second.id)
      assert first.id != second.id
      assert is_integer(first.timestamp)
      assert first.id == "1-0"
      assert second.id == "2-0"

      assert [^first, ^second] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "serialized concurrent appends each receive a distinct store-owned ID" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn ->
            SessionStoreContract.append_event(store.name, session_id, "message", %{i: i})
          end)
        end)
        |> Task.await_many()

      events = Enum.map(results, fn {:ok, event} -> event end)
      ids = Enum.map(events, & &1.id)

      assert length(events) == 8
      assert ids == Enum.uniq(ids)

      replayed = SessionStoreContract.replay_events_after(store.name, session_id, nil)
      assert Enum.map(replayed, & &1.id) == Enum.sort_by(ids, &parse_store_id/1)
    end

    test "append_event refuses unknown or terminated sessions" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      :ok = SessionStoreContract.terminate_session(store.name, session_id)

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, "missing", "message", %{})

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{})
    end

    test "replays the suffix after an exact store-owned cursor" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})

      {:ok, third} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 3})

      assert [] == SessionStoreContract.replay_events_after(store.name, session_id, third.id)

      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, first.id)

      assert [^first, ^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "unknown session returns session_not_found" do
      store = SessionStoreContract.start_dets_isolated!()

      assert {:error, :session_not_found} =
               SessionStoreContract.replay_events_after(store.name, "missing", nil)
    end

    test "an unretained cursor uses compare-id fallback rather than resurrecting events" do
      store = SessionStoreContract.start_dets_isolated!(max_events_per_session: 2)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})

      {:ok, third} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 3})

      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)

      assert [^second, ^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, first.id)

      assert [^third] =
               SessionStoreContract.replay_events_after(store.name, session_id, second.id)
    end

    test "keeps only the newest events when the count bound is exceeded" do
      store = SessionStoreContract.start_dets_isolated!(max_events_per_session: 2)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      Enum.each(1..4, fn n ->
        assert {:ok, _} =
                 SessionStoreContract.append_event(store.name, session_id, "message", %{n: n})
      end)

      replayed = SessionStoreContract.replay_events_after(store.name, session_id, nil)
      assert Enum.map(replayed, & &1.data.n) == [3, 4]

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.event_count == 2
    end

    test "rejects a single event over the encoded byte cap" do
      payload = String.duplicate("x", 64)
      template = caller_event(String.duplicate("s", 22), "event-1", payload)
      exact_bytes = encoded_bytes(template)

      store =
        SessionStoreContract.start_dets_isolated!(
          max_event_bytes: exact_bytes,
          max_replay_bytes_per_session: exact_bytes * 4
        )

      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      exact = caller_event(session_id, "event-1", payload)
      one_over = caller_event(session_id, "event-2", payload <> "x")

      assert encoded_bytes(exact) == exact_bytes
      assert :ok = SessionStoreContract.store_event(store.name, session_id, exact)

      assert {:error, :event_too_large} =
               SessionStoreContract.store_event(store.name, session_id, one_over)

      assert [^exact] = SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "created_at and last_activity are wall-clock system_time timestamps" do
      store = SessionStoreContract.start_dets_isolated!()
      before = System.system_time(:microsecond)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      after_create = System.system_time(:microsecond)
      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)

      assert session.created_at >= before
      assert session.created_at <= after_create
      assert session.last_activity >= before
      assert session.last_activity <= after_create

      monotonic = System.monotonic_time(:microsecond)
      assert abs(session.last_activity - before) < abs(session.last_activity - monotonic)
    end

    test "explicit terminate clears events and refuses further appends" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, _event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      assert :ok = SessionStoreContract.terminate_session(store.name, session_id)
      assert :ok = SessionStoreContract.terminate_session(store.name, "never-existed")

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.status == :terminated
      assert session.event_count == 0
      assert session.replay_bytes == 0

      assert [] = SessionStoreContract.replay_events_after(store.name, session_id, nil)

      assert {:error, :session_not_found} =
               SessionStoreContract.append_event(store.name, session_id, "message", %{n: 2})
    end

    test "wall-clock idle TTL expires the session and drops its events" do
      store =
        SessionStoreContract.start_dets_isolated!(
          session_ttl_seconds: 0,
          cleanup_interval_ms: 60_000
        )

      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, _event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      # TTL 0 expires on any later wall-clock sample; do not race the timer
      # between create and append under coverage load.
      Process.sleep(1)
      send(store.pid, :cleanup_expired_sessions)

      assert_eventually(fn ->
        match?(
          {:ok, %{status: :terminated, event_count: 0}},
          SessionStoreContract.get_session(store.name, session_id)
        )
      end)

      assert [] = SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "store_event overwrites the same caller-supplied event ID in place" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      first = caller_event(session_id, "same-id", "one")
      second = caller_event(session_id, "same-id", "two")

      assert :ok = SessionStoreContract.store_event(store.name, session_id, first)
      assert :ok = SessionStoreContract.store_event(store.name, session_id, second)

      assert [^second] = SessionStoreContract.replay_events_after(store.name, session_id, nil)

      {:ok, session} = SessionStoreContract.get_session(store.name, session_id)
      assert session.event_count == 1
    end

    test "append_event is not content-addressed; duplicates allocate new IDs" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})
      payload = %{same: "payload"}

      {:ok, first} =
        SessionStoreContract.append_event(store.name, session_id, "message", payload)

      {:ok, second} =
        SessionStoreContract.append_event(store.name, session_id, "message", payload)

      assert first.id != second.id
      assert first.data == second.data

      assert [^first, ^second] =
               SessionStoreContract.replay_events_after(store.name, session_id, nil)
    end

    test "claim_request_id is the JSON-RPC dedup story" do
      store = SessionStoreContract.start_dets_isolated!(max_request_ids: 1)
      session_id = SessionStoreContract.create_session(store.name, %{transport: :http})

      assert :ok = SessionStoreContract.claim_request_id(store.name, session_id, "req-1")

      assert {:error, :duplicate_request_id} =
               SessionStoreContract.claim_request_id(store.name, session_id, "req-1")

      assert {:error, :request_id_limit_exceeded} =
               SessionStoreContract.claim_request_id(store.name, session_id, "req-2")

      other = SessionStoreContract.create_session(store.name, %{transport: :http})
      assert :ok = SessionStoreContract.claim_request_id(store.name, other, "req-1")
    end

    test "restarting SessionManager with the same path retains sessions and events" do
      store = SessionStoreContract.start_dets_isolated!()
      session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

      {:ok, event} =
        SessionStoreContract.append_event(store.name, session_id, "message", %{n: 1})

      assert :ok = SessionStoreContract.claim_request_id(store.name, session_id, "req-1")

      name = store.name
      path = store.storage_path
      :ok = ExUnit.Callbacks.stop_supervised(store.id)
      refute Process.alive?(store.pid)

      restarted =
        SessionStoreContract.start_dets_isolated!(name: name, storage_path: path)

      assert {:ok, session} = SessionStoreContract.get_session(restarted.name, session_id)
      assert session.status == :active
      assert [^event] = SessionStoreContract.replay_events_after(restarted.name, session_id, nil)

      assert {:error, :duplicate_request_id} =
               SessionStoreContract.claim_request_id(restarted.name, session_id, "req-1")

      {:ok, next} =
        SessionStoreContract.append_event(restarted.name, session_id, "message", %{n: 2})

      assert next.id != event.id

      assert [^event, ^next] =
               SessionStoreContract.replay_events_after(restarted.name, session_id, nil)
    end

    test "two SessionManagers must not share the same DETS path" do
      store = SessionStoreContract.start_dets_isolated!()
      Process.flag(:trap_exit, true)

      assert {:error, reason} =
               SessionManager.start_link(
                 storage_backend: :dets,
                 storage_path: store.storage_path,
                 name: nil
               )

      assert init_error_message(reason) =~ "already open" or
               init_error_message(reason) =~ "storage_backend: :dets path"
    end

    test "storage_backend :dets requires a directory path" do
      Process.flag(:trap_exit, true)

      assert {:error, reason} =
               SessionManager.start_link(storage_backend: :dets, name: nil)

      assert init_error_message(reason) =~ "storage_path"
    end

    test "emits no store telemetry and does not log payloads" do
      handler_id = "session-store-dets-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:arbor_mcp, :session_manager],
            [:arbor_mcp, :session_store],
            [:arbor_mcp, :session, :event],
            [:arbor_mcp, :store]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:store_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      secret = "session-store-dets-secret-payload"

      log =
        capture_log(fn ->
          store = SessionStoreContract.start_dets_isolated!()
          session_id = SessionStoreContract.create_session(store.name, %{transport: :sse})

          {:ok, event} =
            SessionStoreContract.append_event(store.name, session_id, "message", %{
              secret: secret
            })

          assert [^event] =
                   SessionStoreContract.replay_events_after(store.name, session_id, nil)

          stats = SessionStoreContract.get_stats(store.name)
          assert stats.total_sessions == 1
          assert stats.active_sessions == 1
          assert stats.total_events == 1
          assert is_integer(stats.memory_usage)
          refute Map.has_key?(stats, :events)
          refute Map.has_key?(stats, :payloads)
        end)

      refute_received {:store_telemetry, _, _, _}
      refute log =~ secret
    end
  end

  defp init_error_message({exception, _stack}) when is_exception(exception) do
    Exception.message(exception)
  end

  defp init_error_message(exception) when is_exception(exception) do
    Exception.message(exception)
  end

  defp init_error_message(other), do: inspect(other)

  defp caller_event(session_id, event_id, payload) do
    %{
      id: event_id,
      session_id: session_id,
      type: "notification",
      data: %{"payload" => payload},
      timestamp: 1
    }
  end

  defp encoded_bytes(event), do: event |> Jason.encode!() |> byte_size()

  defp parse_store_id(event_id) do
    case String.split(event_id, "-", parts: 2) do
      [left, right] ->
        {String.to_integer(left), String.to_integer(right)}

      _other ->
        event_id
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
