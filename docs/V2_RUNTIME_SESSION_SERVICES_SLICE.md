# Addressed session and resource services candidate

This slice adds ETS-backed domain services. HTTP routing, SSE writers, progress,
pending reverse requests and native output-ledger integration remain separate
release gates. Standalone SessionManager and SubscriptionRegistry functions,
their existing arities and their return shapes remain available during migration.
The application still starts their standalone owners. Addressed operations never
fall back to those owners.

## Configuration and addresses

`Arbor.MCP.Server.Runtime.Config` remains the configuration authority. Both new
services are opt in:

```elixir
{:ok, root} = Arbor.MCP.Server.Runtime.start_link(
  handler: Handler,
  handler_args: [],
  services: [
    sessions: [options: [max_sessions: 128, max_metadata_bytes: 1_000_000]],
    resource_subscriptions: [options: [max_subscriptions: 1_024]]
  ]
)
{:ok, sessions} = Arbor.MCP.Server.Runtime.service(root, :sessions)
{:ok, resources} = Arbor.MCP.Server.Runtime.service(root, :resource_subscriptions)
{:ok, lease} = Arbor.MCP.SessionManager.create_session(sessions, %{principal_id: "alice"}, [])
session_id = Arbor.MCP.SessionManager.SessionLease.id(lease)
:ok = Arbor.MCP.SubscriptionRegistry.subscribe(resources, lease, "file://resource", [])
```

The runtime owns unnamed store instances. Resource subscriptions start before
sessions, and a service failure reaches the existing fail-stop cohort boundary.
Logical ServiceRefs follow child replacement. A whole-runtime replacement
invalidates them. Session leases also bind the service cohort, namespace and
session epoch, so callers must validate the wire session ID again after cohort
replacement. Explicit wrong-kind, foreign and stale inputs fail without fallback.

Borrowed descriptors require a stable binary namespace, a live local server,
namespace-aware operations and the adapter's `bounded_operations: 1` declaration,
in addition to the existing lifecycle contract. The native operation address is
obtained once within startup's remaining deadline. Capability declarations are
adapter contracts, not certification of an arbitrary backend. Every domain
operation, lease read and retained key includes its supplied namespace. A borrowed
process survives runtime stop; its namespace's retained sessions expire under its
own policy. Resource entries with retired runtime leases are removed separately.

Runtime session descriptors reject a storage backend other than ETS with
`runtime_durable_sessions_unqualified`. Standalone DETS remains available with
its existing behavior. Durable qualification still requires stable logical keys,
bounded static DETS names, exclusive files, finite open/sync/close with observed
errors and recovery tests. PID, reference and cohort values are process-local
capabilities and are not durable session keys.

## Explicit addressed APIs

New APIs use a ServiceRef as their first argument. Options are explicit; they do
not overload the standalone default arities.

| SessionManager operation | Addressed result |
| --- | --- |
| `create_session(service, metadata, opts)` | `{:ok, SessionLease}` |
| `ensure_session(service, id, metadata, opts)` | `{:ok, SessionLease}` |
| `ensure_initialized_session(service, id, metadata, opts)` | `{:ok, SessionLease}` |
| `claim_request_id(service, lease, wire_id, opts)` | `:ok` or tagged error |
| `claim_initialization(service, lease, opts)` | `{:ok, InitializationClaim}` |
| `complete_initialization(service, claim, version, opts)` | `:ok` or tagged error |
| `append_event(service, lease, type, data, opts)` | `{:ok, event}` |
| `replay_page(service, lease, cursor, opts)` | `{:ok, %{events: events, next_cursor: cursor, more?: boolean}}` |
| `get_session(service, lease, opts)` | `{:ok, session}` |
| `terminate_session(service, lease, opts)` | `:ok` or tagged error |
| `get_stats(service, opts)` | `{:ok, aggregate_accounting}` |

Resource subscribe/unsubscribe take `(service, lease, uri, opts)`; subscriptions
and remove_session take `(service, lease, opts)`. `sessions(service, uri, opts)`
returns a bounded list of session-ID/epoch keys for later gateway resolution.
Oversized lookup results return `lookup_page_required` rather than an unbounded
reply. Resource get_stats returns aggregate retained accounting.

Creation accepts an optional server-chosen `session_id` for applications that
issue their own IDs. Transport code must never forward an untrusted client ID
as that option. Authorization identity is immutable, and identity validation
requires the same bound facts. Metadata retains only identity, transport and
client-info fields.

Initialization claims retain an explicit live local `owner` (default caller)
and their original absolute deadline. Inside a runtime callback, the claim's
owner and cutoff come from the actual admitted invocation, independently of the
service RPC's shorter wait budget. `:timeout` bounds the individual store call;
`:deadline` may shorten the retained cutoff. An explicit callback `:owner` must
match the actual invocation owner. Cancellation, request retirement or cohort
replacement revoke that proof. Outside callbacks claims retain their finite
service-operation cutoff; an arbitrary future integer cannot extend it. A
scheduled callback can complete a claim from another PID; it does not impersonate
its caller. Completion respects any shorter caller deadline, and retries never
renew the original claim cutoff. Owner exit or claim expiry
retires the uninitialized session epoch. A lease itself remains independent of
a GET process so future HTTP GET disconnects can preserve session resumability.

## Bounds, deadlines and cleanup

Each service has `max_operations`, `max_operation_bytes`,
`max_operation_payload_bytes` and `operation_timeout_ms`. One ETS CAS publishes
the operation payload, producer and count/byte credits together. A coalesced
wake sends no payload into the owner mailbox. Producer exit, expiry, completion
and caller timeout retire work idempotently. Each entry has a separate monotonic
phase, so delayed ledger cleanup cannot execute a completed mutation again or
send its reply twice. Claim and release CAS loops have at most 32 attempts and an
absolute deadline. Contention returns `operation_contention`; incomplete cleanup
retains count/byte credits until finite owner maintenance reaps the terminal
entry. A terminal entry cannot be readmitted as unused capacity.

Temporary reply aliases are deactivated and flushed on return. Operation deadlines
take the earliest caller, callback and configured deadline, including time spent
resolving the service address. Callers check the original cutoff after receiving
a reply, so a caller suspended past its deadline returns `operation_timeout`
even when a success was queued earlier. A mutation already committed remains;
timeout is not a rollback promise. Queued abandoned work cannot pass the final
mutation guard. Finite wait values are positive integers at most 4,294,967,295ms;
absolute deadline metadata must fit a signed 64-bit integer. `deadline: :infinity`
still uses the finite caller/configured limit; `timeout: :infinity` is rejected.

The current runtime generation, service cohort and cancellation state are checked
again before committing a mutation. These are accepted-operation bounds, not a
bound on arbitrary raw Erlang messages or memory retained by application callers.
Owner maintenance rotates through at most 32 ledger entries and 32 retained
session/resource entries per turn, checking its remaining deadline between entries.
A backend operation already running is not preempted by that maintenance budget.

Sessions bound aggregate metadata bytes and count, aggregate/per-session claimed
ID counts and aggregate ID bytes, and aggregate/per-session replay event counts
and bytes. Session/claim metadata and request IDs use serialized record sizes;
replay charges at least both its serialized retained record and encoded wire size.
These accounting limits do not represent exact ETS allocator or VM heap sizes.
Resource entries likewise charge their retained lease/key record and bound URI
bytes, entry count, aggregate bytes and lookup reply count/bytes.

Per-session replay eviction occurs only if the prospective append also fits the
aggregate ledger. A rejected append neither evicts another session nor advances
the stored cursor. Replay uses exact canonical store-owned cursors; foreign,
evicted and unknown values have separate tagged outcomes. Pages have explicit
event/byte limits; a page too small for the next event fails without advancement.

Session close and TTL remove the epoch's session row, replay and ID claims.
Resource ownership validates that epoch on reads and subscription mutation, and
reaps retired leases through its rotating 25ms maintenance cycle when responsive. This avoids
nested blocking cleanup calls between owners. Retained resource credits can
remain until that owner reaches them in maintenance. Stale cleanup cannot remove
a recreated session with the same wire ID. No global registry cleanup is called.
Resource subscription reads validate each stored lease against the current
endpoint, rather than accepting only a renewed caller lease with the same wire
ID and epoch. A borrowed backend can retain rows across cohort replacement;
those rows do not expose subscriptions captured by the retired cohort. Reads
prune retired entries before returning, and subscribe prunes them before its
existing-key check. Repeating a valid current subscription remains idempotent.

Owned processes use the existing shutdown guard. Borrowed processes are monitored
and never forcefully terminated by the runtime. A managed runtime still needs
its supervising parent to terminate its child if permanent restart is configured.
One original StoreSupervisor cohort deadline now covers guard registration,
owned/borrowed service startup, binding hooks, listener startup and generation
publication. An independent observer is armed before cohort startup can block.
Each owned process records its provenance and is acknowledged by that observer
before proceeding to finite guard registration. On cutoff, the observer marks
that generation failed before killing only its registered owned processes;
borrowed targets survive. Startup still runs under the real OTP parent, so
ordinary owned shutdown and termination hooks retain their parent semantics.
The observer and monitors retire on success and failure. Owned provenance
remains until PID/cohort retirement so failed cohort shutdown also clears its
registered descendants.

Custom `bounded_startup: 1` adapters must call `watch_owned/1` before blocking
initialization, pass its options to additional owned children, and use finite
OTP startup timeouts. The watchdog bounds an adapter blocked in its supervisor's
start call or binding hook. Unregistered or detached processes and arbitrary
effects before registration remain outside this contract. Durable hooks still
require separate qualification.

Overall Runtime initialization remains a release gate: Runtime, Admission,
ExecutionSupervisor, Scheduler handler initialization and the edge currently do
not all consume one root deadline. A genuine cohort restart must get one fresh
budget shared with replacement execution/handler startup. Normal lifetime
shutdown-guard control also retains its existing contract; the new finite watch
interface applies to startup. HTTP initialization claims need a separate bounded
claim lifetime derived from the original invocation proof: their current lifetime
inherits the shorter service operation wait (default 1s), while handler requests
may run longer. An arbitrary caller may not extend a claim past its invocation.
That distinction must be settled before HTTP initialization routing is enabled.

## Qualification

Focused regressions cover siblings with equal wire IDs, immutable identity,
cross-worker claims, abandoned claims, TTL/recreation, metadata deltas, aggregate
ID/replay/resource limits, exact replay outcomes, suspended-owner admission,
timeouts and producer death, borrowed namespaces/survival, blocked startup,
cohort restart and stale callback work, real concurrent producer contention,
suspended callers with queued successes, deferred terminal cleanup and expired
resource removals. Existing standalone session/store tests
remain part of qualification. Current/minimum full/static results are recorded
in the handoff evidence after the source freezes.

The qualified phase implementation is integrated in the unpublished v2 draft. Before the borrowed-cohort correction, the combined current full selection passed 20 doctests, 34 properties and 3,937 executed tests (82 excluded), zero failures. The separately qualified correction rejects retired resource rows before URI lookup/re-subscription; both supported toolchains pass its 27 domain cases. At that checkpoint, the cohort startup budget and HTTP routing remained open slices.

Final combined qualification with native RPC `0e4cfd1`: minimum/current full selections each pass 20 doctests, 34 properties and 3,938 executed tests, zero failures (82 excluded; minimum displays the 4,020-test inventory). Minimum merged Dialyzer passes all 67 existing filtered warnings with no new filters. Native RPC also passed 74 current stdio/framing cases and all nine Linux ACP package/SDK/archive jobs. That checkpoint left startup cutoff and production output/HTTP open.

The startup follow-up is integrated into the unpublished v2 draft. It passes 100 runtime/services/startup regressions on both supported toolchains with independently source-built RPC `0e4cfd1`, including eight new startup cases. Whole-runtime initialization and production output/HTTP still require their separate integration gates.
