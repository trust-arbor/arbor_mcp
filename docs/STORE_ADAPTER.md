# ExMCP 1.x Store Adapter (historical design)

This document records the pre-split 1.x design. Its global owners and planned
follow-ups do not describe v2 startup. For current configuration, use the
[runtime guide](RUNTIME_GUIDE.md), [configuration guide](CONFIGURATION.md) and
[v1-to-v2 migration guide](guides/MIGRATING_V1_TO_V2.md).

- **Status:** Accepted — unpublished `ExMCP.Internal.SessionStore` seam
  with default ETS and opt-in DETS
- **Baseline:** ExMCP 1.x after `b62eca2` (the `storage_backend:
  :persistent_term` warning and wall-clock TTL notes)
- **Scope:** lock the 1.x event-store contract and introduce one opt-in
  durable backend without changing default ETS behavior
- **Last updated:** 2026-08-27
- **Related:** [`V2_ROADMAP.md`](./V2_ROADMAP.md) §8.2 and Phase 4;
  [`POST_1_0_MAINTENANCE_PLAN.md`](./POST_1_0_MAINTENANCE_PLAN.md)
  session-storage option

This is a repository design record, not user-facing Hex documentation.
SessionManager remains the public facade. The behaviour lives under
`ExMCP.Internal` so `filter_modules` keeps it out of the Hex sidebar.

## 1. Purpose

[`V2_ROADMAP.md` §8.2](./V2_ROADMAP.md#82-current-classifications)
allows a store-adapter seam in a later 1.x minor **only after** a
standalone store ADR and contract suite are accepted in-tree. ETS must
remain the default and current behavior must stay unchanged. Phase 4
lists the event-store bullets this record pins.

This ADR:

- records what `ExMCP.SessionManager` actually does today;
- locks the 1.x decisions that a later seam must not break;
- proposes a future behaviour surface without adding it to the public
  API; and
- names the gaps that tests pin as current behavior rather than
  inventing new runtime semantics.

The first extra backend is opt-in DETS (`storage_backend: :dets` plus
`:storage_path` or `:dets_path`). `:persistent_term` remains accepted
and still uses ETS (no-op durability) with the existing warning. Mnesia,
Postgres, and clustered adapters remain out of scope.

## 2. Current 1.x owner

Legacy Streamable HTTP and HTTP+SSE session state live in
`ExMCP.SessionManager`, which the application supervisor starts as a
singleton. MCP 2026-07-28 HTTP is stateless and does not use this
manager, `Mcp-Session-Id`, `Last-Event-ID`, GET streams, or DELETE
termination.

The process always creates three **unnamed, process-owned ETS tables**
in `init/1`:

- sessions (`:set`)
- events (`:ordered_set`)
- claimed JSON-RPC request IDs (`:set`)

`storage_backend: :persistent_term` is accepted for 1.x compatibility
and still uses those ETS tables. `init/1` logs a warning that the
option is a no-op for durability. That warning landed in `b62eca2`.
There is no `persistent_term` write path.

`terminate/2` deletes the three tables. Restarting the GenServer starts
empty. Transports (`ExMCP.HttpPlug`, `HttpPlug.SSEHandler`) call the
SessionManager public functions (`append_event/3`, `store_event/2`,
`replay_events_after/2`, create/ensure/terminate). They do not select
tables, backends, or cursors beyond the opaque event ID they already
put on the wire.

Session TTL is wall-clock idle expiry on purpose. `created_at` and
`last_activity` are absolute `System.system_time(:microsecond)`
timestamps. Cleanup expires an active session when that wall clock is
more than `:session_ttl_seconds` after `last_activity`. A backwards
wall clock yields a negative difference and does not expire the
session. This is not monotonic elapsed time; changing it would change
the meaning of the public timestamps and of `:session_ttl_seconds`.

## 3. Decisions locked for 1.x

| Decision | Lock |
|---|---|
| Default store | ETS remains the default. Current ETS results, clocks, and restart-empties stay unchanged. |
| Public API | Current `ExMCP.SessionManager` function names, arities, return shapes, and error atoms stay unchanged. |
| Wire / SSE replay | Persist-before-delivery, `Last-Event-ID` exact-cursor replay, gap retention across disconnect, and opaque event IDs stay unchanged. |
| `storage_backend: :persistent_term` | Remains accepted. Still uses ETS (no-op durability) and still warns. Do not give it real durability. Option removal is 2.0-only. |
| Seam | Unpublished `ExMCP.Internal.SessionStore`. SessionManager remains the public facade. Do not Hex-group or extras-link Internal modules. |
| Transport isolation | Transports must not learn backend details. They keep calling SessionManager. No table names, adapter modules, or cursor encodings leak into Plug/SSE. |
| Session TTL | Wall-clock idle expiry stays. Do not "fix" it to `System.monotonic_time/1` in 1.x. |
| Public behaviour | Not published. Internal for this cut; a later 1.x minor may promote a public module if needed. |
| Second backend | Opt-in DETS only. Mnesia, Postgres, durable `persistent_term`, and clustered adapters stay out of scope. |

These are compatibility locks. The follow-up that this ADR authorized
adds the Internal seam and opt-in DETS without changing default ETS
results.

## 4. Event-store contract (current ETS behavior)

Phase 4 requires the event-store contract to cover the bullets below.
The accepted 1.x meaning of each bullet is **what SessionManager does
today**. The suite in
`test/arbor_mcp/session_store_contract_test.exs` pins that meaning against
ETS (including restart-empties) and DETS (same public outcomes except
restart/ownership).
Documented gaps are called out here and in the tests; they are not
silently implemented.

### 4.1 Atomic append returning a store-owned opaque event ID

`append_event/3` is the persist-before-delivery path. It assigns the
ID, retains the event, then returns `{:ok, event_data}` with that ID.
The caller does not choose the ID. Concurrent appends are serialized
by the GenServer, so each retained event has a unique store-owned ID.

Current ETS IDs look like `"#{sequence}-0"`. Clients and transports
must treat them as opaque (`V2_ROADMAP.md` §8.3). A later adapter may
use a different representation. Losing events, replaying duplicates, or
changing cursor identity is observable and is not allowed as a silent
1.x change.

`store_event/2` remains the caller-supplied-ID path for tests and older
custom managers. It is not the SSE persist-before-delivery contract.

### 4.2 Ordered replay after an exact cursor

`replay_events_after/2` is the `Last-Event-ID` contract.

- `nil` replays every retained event for the session.
- When the cursor equals a retained event ID, replay is the suffix
  after that exact event (the cursor event itself is not replayed).
- Managed `append_event/3` sessions replay in store-sequence order,
  not wall-clock timestamp order.
- `store_event/2` sessions replay by `{timestamp, sequence, id}` so
  existing caller-supplied IDs keep their historical order.

If the cursor is not retained (evicted, or a custom `store_event/2`
ID), replay falls back to `compare_event_ids/2`: parse
`"integer-integer"` when both sides match that shape, otherwise
string-compare. That fallback is current compatibility behavior, not
a new guarantee for adapters.

Replay of an unknown session returns `{:error, :session_not_found}`.
A terminated session that is still in the table replays its remaining
events (usually none after cleanup).

### 4.3 Bounded retention and cursor-eviction

Retention is fail-closed and newest-preserving:

- a single JSON-encoded event larger than
  `min(:max_event_bytes, :max_replay_bytes_per_session)` is rejected
  with `{:error, :event_too_large}`;
- non-JSON-encodable payloads return
  `{:error, :event_not_json_encodable}`;
- after a successful store, oldest events are discarded until both
  `:max_events_per_session` and `:max_replay_bytes_per_session` hold.

Replaying after an evicted cursor uses the §4.2 fallback. It does not
resurrect discarded events and must not invent replacements. Counts
and byte totals reset when a session is terminated or expires.

### 4.4 Session TTL and explicit deletion

- **TTL** is wall-clock idle expiry on `last_activity`, as locked in
  §3. Append, store, ensure, claim, and other activity refresh that
  timestamp. Cleanup is periodic (`:cleanup_interval_ms`).
- **Explicit deletion** is `terminate_session/1`. It marks the session
  `:terminated`, clears events and request IDs, releases an
  initialization claim, and asks `SubscriptionRegistry` to drop the
  session. A transient SSE disconnect does not terminate the session.
- Terminated rows remain until the next `create_session/1` prunes them
  to free capacity. `get_session/1` still returns the terminated
  record. Further `store_event/2` / `append_event/3` calls return
  `{:error, :session_not_found}`.
- Terminating an unknown session is `:ok`.

Do not change these shapes to make TTL monotonic or to drop terminated
rows immediately.

### 4.5 Idempotent overwrite and deduplication

There are two different stories. Do not collapse them.

| Path | Current expectation |
|---|---|
| `append_event/3` | Not idempotent. Each call allocates a new store-owned ID. |
| `store_event/2` with the same `{session_id, event.id}` | Overwrite in place. The existing store sequence is reused; the payload is replaced. |
| `claim_request_id/2` | The JSON-RPC dedup story. First claim wins (`:ok`). A second claim of the same ID in the same session returns `{:error, :duplicate_request_id}`. The per-session cap fails closed with `{:error, :request_id_limit_exceeded}`. Claims live until the session is terminated or expires. |

A later adapter must preserve these outcomes for the same public
calls. It must not treat `append_event/3` as content-addressed
dedup unless a separate, documented option is added.

### 4.6 Adapter ownership and restart

Today the store **is** the SessionManager process:

- tables are unnamed and owned by that process;
- `terminate/2` deletes them;
- a supervisor restart starts empty tables;
- `storage_backend: :persistent_term` does not change that.

This is the accepted 1.x **default ETS** restart behavior. The contract
suite still pins "stop + start with the same registered name loses
sessions and events" for ETS and for `:persistent_term`.

Opt-in DETS documents a different ownership split:

- `:storage_path` (or `:dets_path`) is a directory owned by one
  SessionManager. Files inside it (`sessions.dets`, `events.dets`,
  `request_ids.dets`, `meta.dets`) are an implementation detail.
- Restarting SessionManager with the same path **must not** discard
  the durable store. Sessions, events, claimed request IDs, and the
  event clock are reopened.
- Two runtimes must not share the same files. A second open fails
  (`:storage_in_use`); DETS is single-writer.
- Process-local initialization claims (owner monitors) cannot survive
  a restart. DETS clears `initialization_claimed` on open when the
  session is not yet initialized so a later initialize can proceed.
- Isolated tests use unique temp directories and delete them on exit.

DETS is used instead of a custom file-backed term store because the
three tables are `:set`/`:ordered_set` with Elixir-side replay
ordering. DETS has no `:ordered_set`, but SessionManager already sorts
in process, so `:set` files are enough. No new Hex dependency.

### 4.7 Telemetry that excludes event payloads by default

**Gap (pinned, not implemented):** SessionManager emits no
`:telemetry` events today. Logs use `LogSummary.fingerprint/1` for
session IDs and do not write event payloads.

Phase 4 wants store telemetry that excludes payloads by default, with
opt-in payload capture. That is an eligible 1.x-minor follow-up
(additive events, bounded metadata) once this ADR is accepted. It is
not part of this change. The contract suite attaches handlers for
plausible store prefixes and asserts they stay silent, and it asserts
that logs from append/store do not contain the event payload.

`get_stats/0` remains the public observation surface: session counts,
event count, and ETS memory words. It does not return payloads.

## 5. 1.x behaviour (unpublished Internal)

The 1.x seam is `ExMCP.Internal.SessionStore`. It is not Hex-grouped
and must not be linked from extras. Working name `ExMCP.SessionStore`
stays reserved if a later cut publishes the facade.

One behaviour covers the state SessionManager's three tables already
own — sessions, replay events, and claimed request IDs. Do not split
session / event / request-id / subscription behaviours until another
backend exists and the split removes real duplication. Subscriptions
stay on `ExMCP.SubscriptionRegistry`.

Implementations:

- `ExMCP.Internal.SessionStore.ETS` — default; unnamed process-owned
  tables; `close/1` deletes them; restart starts empty.
- `ExMCP.Internal.SessionStore.DETS` — opt-in; directory of DETS
  files; `close/1` closes without deleting; restart reopens.

Initialization claims, identity binding, and protocol-version
immutability stay SessionManager (or later server-runtime) **policy**.
A store adapter stores the resulting session record; it does not
reimplement those rules.

Proposed callbacks, matching today's public shapes:

```text
create_session(metadata) ->
  session_id | {:error, :session_limit_exceeded}

get_session(session_id) ->
  {:ok, session_data} | {:error, :session_not_found}

terminate_session(session_id) -> :ok

append_event(session_id, type, data) ->
  {:ok, event_data}
  | {:error, :session_not_found | :event_too_large | :event_not_json_encodable}

store_event(session_id, event_data) ->
  :ok | {:error, :session_not_found | :event_too_large | :event_not_json_encodable}

replay_events_after(session_id, cursor) ->
  [event_data] | {:error, :session_not_found}

claim_request_id(session_id, request_id) ->
  :ok | {:error, :session_not_found | :duplicate_request_id | :request_id_limit_exceeded}

get_stats() ->
  %{total_sessions, active_sessions, total_events, memory_usage}
```

Not part of the store behaviour:

- `replay_events_after/3` (transport helper that casts to an SSE
  handler);
- `ensure_session/2`, `ensure_initialized_session/2`,
  `claim_initialization/1`, `complete_initialization/2`,
  `update_session/2` (policy on top of the session record);
- table names, ETS types, or backend atoms.

SessionManager injects the store so HttpPlug keeps calling the same
functions. The default implementation remains ETS. `:persistent_term`
stays accepted and remains a no-op for durability. `:dets` is the
opt-in durable backend, not a replacement for that option.

`V2_ROADMAP.md` §10.2 item 3 (one behaviour vs a split) is resolved
for 1.x as: one session/event/request-id behaviour. Revisit the split
in 2.0 if per-server runtimes need independently owned stores.

## 6. Gaps versus Phase 4 (follow-up vs 2.0)

| Gap | Today | Lane |
|---|---|---|
| Store telemetry | None. Logs omit payloads. | Additive 1.x minor after this ADR: bounded metadata, payload capture opt-in. |
| Durable second backend | Opt-in DETS. `:persistent_term` still ETS + warning. | Further adapters (Mnesia/Postgres/cluster) remain later; option removal is 2.0-only. |
| Adapter ownership independent of SessionManager | Default ETS still process-owned and restart-empty. DETS owns a directory. | Changing default ETS restart semantics is 2.0 unless an opt-in adapter is used. |
| Per-server store isolation | One application-wide SessionManager. | 2.0 runtime ownership (`V2_ROADMAP.md` §8.2). |
| Public behaviour module | `ExMCP.Internal.SessionStore` only. | Publish only if a later 1.x cut needs a Hex-documented seam. |

## 7. Out of scope

This change does not:

- give `:persistent_term` durability;
- change default ETS clocks, table types, or restart-empty semantics;
- publish `ExMCP.SessionStore` or any Hex-documented behaviour;
- alter SSE wire/replay behavior or transport modules;
- move session policy (identity, initialization) into a store;
- "fix" wall-clock TTL to monotonic time;
- implement Postgres, Mnesia, or clustered adapters;
- bump `mix.exs`.

## 8. Acceptance

The ADR-and-ETS-suite cut is accepted in-tree. This follow-up is
accepted when:

1. `ExMCP.Internal.SessionStore` exists and is not Hex-grouped;
2. ETS remains the default and the contract suite still pins ETS
   restart-empties and `:persistent_term` no-op durability;
3. opt-in DETS passes the same Phase 4 bullets except restart
   (retains across SessionManager restart; one owner per path); and
4. existing SessionManager tests remain green and are not weakened.
