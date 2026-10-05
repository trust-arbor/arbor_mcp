# Standalone DETS lifecycle qualification

This is the finite ownership layer for the existing opt-in standalone
`Arbor.MCP.SessionManager` DETS backend. It is not a Runtime durable-session
adapter or a new persistence format. Runtime sessions still use the qualified
ETS service; `storage_backend: :dets` in a Runtime service configuration is
explicitly rejected as `:runtime_durable_sessions_unqualified`.

The accepted scope is [roadmap Phase 4](https://github.com/trust-arbor/arbor_mcp/blob/5fd327fc8be6459d0d0d0e8d4c7a35da68259d2b/docs/V2_ROADMAP.md#phase-4--define-state-and-replay-adapters)
and the existing [store contract](https://github.com/trust-arbor/arbor_mcp/blob/5fd327fc8be6459d0d0d0e8d4c7a35da68259d2b/docs/STORE_ADAPTER.md). Other database or filesystem
adapters can be supplied separately once they satisfy that contract. Existing
standalone DETS persistence remains supported.

## Configuration and success semantics

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

## Owners and exclusive claims

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

## Timeout, failure and late physical outcomes

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

## Qualification and remaining gates

The focused suite retains all 36 prior store-contract cases and adds 16
lifecycle cases. It covers all four held table workers for write and close,
foreign-caller close, original cutoff, late persisted bytes, caller death,
sibling survival, normal restart/claim repair and explicit SessionManager
storage failure and opening/retirement races. A native-alias regression proves
that timeout cleanup removes
an already queued processing reply and rejects later sends. Reproducible
additional checks are:

```sh
elixir scripts/check_dets_authority.exs
MIX_ENV=test mix run --no-start scripts/check_dets_application.exs
```

The authority probe uses a fresh VM. It checks count overload, detached metadata,
128 retained controls with at most a token wake and timer in a suspended mailbox,
expired admission/open, abrupt Owner loss and fail-closed authority loss. It
only suspends the global DETS server inside that isolated test VM and never
adopts or kills it. The application probe checks actual managed-store shutdown,
all four table-process exits, application restart and durable row recovery.

Finite caller waits do not make filesystem I/O preemptible. A permanently
blocked physical operation can retain one tracked Owner and its bounded path
claim until it settles or the VM stops. There is no claim of an OS/RSS bound,
arbitrary-process reclamation, exactly-once disk transactions, or immunity to
power loss/filesystem corruption. Row reads/enumerations and native mailboxes
outside the managed admission path still require workload qualification.

Local lifecycle evidence is macOS on the minimum/current supported toolchains.
Linux CI, final combined source qualification, durable Runtime integration if
subsequently selected, and RC pressure/reconnect gates remain explicit. This
checkpoint does not declare a v2 release complete.
