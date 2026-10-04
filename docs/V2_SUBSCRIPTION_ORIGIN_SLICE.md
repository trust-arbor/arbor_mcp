# Bounded subscription publication and retained origin

Status: independent overlay, 2026-10-04. Based on MCP
`e0f1c9a6bbe1d239da0918e2cf9e0378802ba7bb` plus the immutable 22-path
stdio checkpoint (`mcp-server-stdio-source-manifest.json`, version 2).
Shared RPC remains `0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb`.
The earlier stdio source and its evidence are unchanged.

## Authoritative source and original cutoff

`Subscriptions.publish/3` and `publish_async/3` capture the active
CallbackContext reservation before resolving the service address. Edge helpers
pass their own admitted control token; the registry verifies the token's owner
and captures its authoritative source proof. Public options never accept a
caller-authored source proof.

An internal `Subscriptions.Origin` carries the original outcome cell, token,
scope, generation, edge, connection and cutoff through registry admission,
listener admission, token-only checkout and output admission. The same proof is
checked again at Writer claim. A successful completed source stays valid until
its original cutoff; active cancellation, expiry or peer/generation retirement
suppresses queued effects. Reused request IDs have distinct outcome cells. No
permanent cancellation index or tombstone is added.

The publication lease is the earliest of the original source cutoff and the
configured finite publication budget, measured from entry to the public call.
Service/reference lookup has a maximum five-second budget and cannot renew
that entry time. Listener registration lifetime also caps retained publication
records. Server-authored acknowledgment/completion has a separate finite
lease, with the same current connection/generation validation; it cannot renew
a callback's success or commit deadline.

## Bounded ownership and delivery

The default registry precharges validated plain JSON plus metadata in an
owner-held ETS mailbox before sending publication controls. Its defaults are
128 records, 8 MiB total charged bytes and a 2 MiB message/term limit.
Rejected publications return explicit errors. A synchronous publication keeps
its existing subscriber/enqueued/coalesced/closed map; asynchronous success
means accepted admission, rather than confirmed socket delivery.

Runtime listeners use the same bounded mailbox with their configured queue,
message and wire-byte limits. Their bound also reserves one in-flight loan and
one admission candidate, plus charged JSON terms, source proofs and fixed
metadata allowances. Queues contain record IDs, semantic coalescing keys and
sizes. Control mailboxes carry only fixed-size reference lookups, IDs and
coalesced wakes; payloads live in the charged ETS row until completion.
Producer timeout cannot release a payload while authorization is processing,
or a checked-out output while delivery remains in flight. Owner death deletes
the mailbox. Expired unclaimed records are reaped independently.

Coalescing is restricted to one source outcome cell, or to unscoped
registration publications. A later canceled source cannot overwrite an earlier
completed source's pending effect. Different origins use separate records and
ordinary overload handling. Slow-consumer pressure retains the bounded
completion loan and releases discarded queued data exactly once.

Listener-to-edge messages carry only an opaque delivery ID and original
cutoff. The authenticated edge checks out the charged payload. Test/BEAM ACK
means send-return; stdio ACK means actual IO completion plus ledger ACK.
Stale source effects are discarded without closing a healthy subscription;
known live-source delivery failures close it. The old unqualified ACK API
cannot release runtime loans. Standalone listeners retain their existing
legacy message/ACK compatibility and wire JSON shapes are unchanged.

`OutputController.emit_origin(table, connection, value, origin)` is the narrow
stdio integration seam. Its registration, scope metadata and Writer validation
retain the source proof. It preserves the reviewed singleton Writer ownership
and nonretryable in-flight write uncertainty. HTTP's independent borrowed
writer bindings must retain equivalent proof and liability handling.

## Qualification and remaining integration

Current Elixir 1.19.5/OTP 28.4.1 and minimum Elixir 1.17.3/OTP 27.0.1 use
independent source/build caches. Standalone selections cover 23 new cases,
14 retained standalone subscription cases, nine retained Test/BEAM subscription
cases, 19 retained stdio Runtime cases and 20 retained output integration cases:
85 cases per toolchain, zero failures.
Project warnings-as-errors compilation and owned formatting pass both;
current strict Credo reports no issues. Minimum Dialyzer passes with 67
preexisting filtered warnings and no new filters. Its standalone harness
preloads the installed OTP pretty-printer, which Mix load-path pruning otherwise
leaves unavailable when Dialyzer formats a diagnostic. The final manifest records
source hashes, exact commands and type-analysis evidence.

This overlay must be merged additively into the Initialization-integrated
candidate. Handler/Controller startup sections must be preserved. The shared
Device fixture is the root-owned compiled
`Arbor.MCP.Test.StdioRuntimeFixture.Device`, recorded as a dependency in the
manifest. Combined canonical tests, newest toolchain, actual SDK and release
qualification remain required after that merge.

Raw same-VM sends, host process mailboxes, kernel/IO buffers, transient producer
encoding/CAS copies and VM RSS are outside a hard memory bound. Blocking user
authorization functions retain bounded charged records until they return or
their owned listener dies; timeout does not fabricate their completion.
Standalone/custom publication adapters retain their historical behavior for
unscoped calls; scoped calls through a custom service adapter fail explicitly
with `:bounded_publication_required`. Remote PubSub delivery retains its
existing external ingress contract; it is not qualified as a bounded transport
by this slice. Scoped publications are constrained to their original local
edge. Borrowed IO can complete an irreversible write after owner termination;
no committed callback or uncertain write is retried.
