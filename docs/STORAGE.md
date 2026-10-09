# Storage and retained payload limits

ArborMCP reserves native Tasks and replay operations through the same
private operation ledger used by addressed session services. Full operation data
is retained only after count and byte admission; the owner receives a coalesced
wake. A suspended or busy owner does not admit an unbounded payload mailbox.
Operations preserve one finite cutoff, caller alias, owner and monotonic phase.
Immediately before mutation, runtime operations recheck service generation,
request origin, current batch member/output phase and original deadline. An
operation queued by a callback cannot newly commit after that callback's
invocation expires or retires. A commit completed before the cutoff remains
committed if a caller later times out; timeout is not rollback.

Native `Tasks.Store.ETS` and `Server.ReplayCache.ETS` preserve their existing
standalone operation arities and result shapes. Native operations now use finite
admission defaults, including outside Runtime:

| Option | Default | Meaning |
| --- | ---: | --- |
| `max_operations` | 64 | Concurrent retained operation claims. |
| `max_operation_bytes` | 1,000,000 | Aggregate retained operation data and metadata. |
| `max_operation_payload_bytes` | 65,536 | One operation's retained charge. |
| `operation_timeout_ms` | 1,000 | Maximum synchronous operation wait. A call's `timeout:` may shorten it. |
| Tasks `max_tasks` | 10,000 | Retained task entries. |
| Tasks `max_entry_bytes` | 1,000,000 | One full task entry, including owner, inputs, result and metadata. |
| Tasks `max_retained_bytes` | 8,000,000 | Aggregate task entries. |
| Tasks `max_ttl_ms` | 2,592,000,000 | Maximum task TTL (30 days). |
| Replay `max_replay_entries` | 10,000 | Retained consumed identifiers. |
| Replay `max_replay_bytes` | 8,000,000 | Aggregate consumed identifiers and expiry values. |
| Replay `max_replay_id_bytes` | 4,096 | One continuation identifier. |
| Replay `max_replay_ttl_ms` | 2,592,000,000 | Maximum future expiry interval (30 days). |

Capacity is explicit: operations can return `:operation_capacity_exhausted`,
`:operation_payload_too_large`, `:operation_contention` or `:operation_timeout`.
Task retained exhaustion returns `:store_full` without changing the previous
committed lifecycle. Replay exhaustion returns `:replay_cache_full`; previously
consumed identifiers remain consumed. Invalid identifier/expiry limits return
`:invalid_replay_id` / `:invalid_replay_expiry`. Idle expiry reclaims native task
and replay retention without waiting for another public operation. The idle reaper removes at most 32 expired entries and checks a 5 ms cutoff
between entries; an operation also removes its own expired identifier before lookup. Expiry
index and map overhead are bounded by the configured entry count, while payload
counters measure retained serialized data rather than allocator overhead.
These cooperative checks do not provide CPU preemption or an absolute VM RSS cap. Native ETS
addresses are local; remote or retired native owners fail unavailable.

Generic standalone custom Task store adapters keep their existing callbacks and
options. When selected as a Runtime Tasks/replay descriptor, an adapter must now
explicitly declare `bounded_operations: 1` and implement
`runtime_service_binding/2` plus `operate/4`. Startup rejects an adapter lacking
that contract with `{:invalid_service, kind, :bounded_operations_required}`.
The adapter owns its bounded pre-mailbox admission and must revalidate the
supplied operation context immediately before mutation; supplying a namespace or
checking it only in the caller is insufficient. Existing borrowed namespaces,
logical ServiceRefs and borrowed shutdown ownership remain unchanged. A custom
adapter's arbitrary effects are not made reversible by this interface.

Managed input/control/scope metadata, prepared output and addressed store data
are materialized after their size checks and before retention. This detaches
ordinary subbinary/bitstring backing while preserving structs, tuples, improper
lists and native PID/reference/port identities. Host functions retain their
original identity; captured backing bytes that cannot be detached safely are
charged to the managed budget and can cause rejection. Newly admitted function
closures must fit these limits. Static handler/configuration closures and
borrowed native handle bodies remain host-managed state; these counters do not
claim an absolute VM RSS or arbitrary native resource bound.

## Standalone DETS

Standalone `SessionManager` DETS persistence remains supported. Runtime sessions
use ETS; selecting DETS for a Runtime service returns
`:runtime_durable_sessions_unqualified`.

### Configuration and success semantics

```elixir
{Arbor.MCP.SessionManager,
 name: MyApp.DurableSessions,
 storage_backend: :dets,
 storage_path: "/var/lib/my_app/mcp_sessions",
 storage_io_timeout_ms: 5_000}
```

`storage_io_timeout_ms` defaults to 5,000 and accepts integer milliseconds
1..4,294,967,295. ETS ignores it. Opening all tables and repairing local claim
flags share one original monotonic cutoff. A standalone SessionManager callback
shares one cutoff across its multiple store operations. Explicit close has one
cutoff across all four tables. A call cannot renew that cutoff between tables,
lookup/write/sync stages, or waits for a previous path owner.

The existing filenames, storage keys, session rows and opaque event IDs are
unchanged: `sessions.dets`, `events.dets`, `request_ids.dets`, `meta.dets`,
`:event_clock`, `:__ex_mcp_sequence__`, and `"<sequence>-0"`. Table names are
fresh references, preserving the separately qualified fix that avoids creating
per-open atoms. Each successful mutation still syncs before acknowledging
success. Reopening retains sessions, events, request-ID claims and the event
clock. Process-local initialization claims are repaired on reopen.

### Owners and exclusive claims

Each store has one native GenServer Owner, created by the opening process. It
monitors that lifetime owner, is registered with PathClaims before any blocking
open effect, and is the actual DETS user for all four tables. Other callers use
that Owner; they never call `:dets.close` as a different DETS user. Normal stop
and ordinary SessionManager crash clean up through the same tracked Owner.

The application supervises one node-local PathClaims authority before its other
children, so it shuts down after managed SessionManagers. It retains at most
128 active or quarantined store claims by default. Hosts may set a positive
`:max_stores` in the authority's application options:

```elixir
config :arbor_mcp, Arbor.MCP.Internal.SessionStore.DETS.PathClaims,
  max_stores: 128
```

Claim ingress has 128 fixed control slots, a round-robin 32-slot drain, one
coalesced token wake and one 25ms maintenance timer. Paths are detached binaries
capped at 4,096 bytes after expansion; each slot retains only that bounded path
plus fixed local PID/reference/deadline metadata. Full path data stays in the
charged slot rather than the authority mailbox. Expired controls retain their
slot until consumed. Overload returns `:storage_claim_overloaded`; store-count
exhaustion returns `:storage_claim_limit`. No storage effect starts for either.

One operation is admitted per store Owner. Simultaneous private store requests
return `:storage_busy`. Original caller/generation identities are validated
before the authority accepts a new store. No global DETS server, DETS supervisor,
unmanaged table user, or filesystem process is adopted or killed.

Exclusivity is for a managed expanded path on this node. Hosts must not share
those files with another VM, symlink aliases, or unmanaged concurrent writers.
This layer does not provide a distributed filesystem lock.

### Timeout, failure and late physical outcomes

An I/O timeout seals the Owner and returns `:storage_io_timeout`; it does not
prove rollback or cancellation of the already-started physical operation. That
operation may have persisted data before or after the caller cutoff. No new
normal operation is admitted, and an expired open cannot begin later tables or
repair mutations. Cleanup waits for the existing physical operation to settle,
then closes all owned tables. A second open cannot acquire that path while the
previous physical operation or cleanup remains unresolved.

The private adapter preserves its successful list/boolean/store return shapes.
Failures raise the fixed-message `DETS.Error` with a typed reason.
SessionManager catches that error, deliberately returns `{:error, reason}` for a
synchronous call and fail-stops with `:storage_io_failed`; timer-triggered store
failure also fail-stops. This is an intentional storage-failure boundary, not an
accidental tuple-pattern crash. A failed mutation must not be blindly retried:
a partially completed durable effect may be present after reopening.

`close/1` returns `:ok` only after confirmed all-table close success. It can
return `{:error, :storage_io_timeout}`, `{:error, :storage_cleanup_pending}` or
`{:error, :storage_cleanup_unconfirmed}`. A later repeated close may report
`:ok` after actual late cleanup has completed. Owner DOWN alone never establishes
that result. Missing table/owner proof is conservatively quarantined even if
DETS subsequently finishes automatic cleanup.

The claim authority observes shutdown cleanup for one original 5,000ms cutoff;
its native child shutdown allowance is 5,100ms. This observes cleanup rather
than extending any original caller I/O deadline. A clean application stop/start
is supported when all table cleanup is confirmed. Stop externally supervised
standalone managers before stopping the library application as well.

An abrupt authority identity loss, or termination with unresolved claims,
retains a VM-lifetime fail-closed latch. Restarting that authority in the same
VM returns `:storage_claims_identity_lost`; DETS admission is unavailable until
VM restart. An abrupt private Owner loss keeps its path quarantined as
`:storage_cleanup_unconfirmed`. A bounded claim cannot be discarded merely
because its caller timed out or died.

Native Owner/authority arguments are opaque and status summaries redact paths,
messages and payloads. Trusted `:sys.get_state`, raw same-VM sends, direct DETS
calls and host logging of returned errors remain outside that diagnostic policy.
