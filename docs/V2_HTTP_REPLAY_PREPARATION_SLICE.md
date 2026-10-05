# HTTP replay preparation prerequisite

This private implementation reserves addressed session replay before a handler proposal commits. It is a prerequisite for the retained legacy `/sse` and `/message` routing cutover. This slice does not activate those aliases, change mounted GET lifetimes, remove HTTP APIs, or complete resource/reverse publication.

## Ownership and commit

`HTTPGateway` adds an addressed session companion only for its private `:legacy_sse` output format. `HTTPOutput` prepares it alongside the existing bounded primary output and physical IO companion. `OutputTicket` keeps both companions opaque. Preparation uses the original admitted token, cohort, scope, phase, owner, session epoch and captured socket cutoff.

The original callback context is installed around output preparation under the same worker invocation. The replay service rechecks the actual retained Task identity and fixed initialization flag through a Scheduler-owned protected metadata table. A token-only start gate releases the worker only after its proof is published. The flag comes from the Scheduler’s retained request, not caller-authored metadata. The proof carries no request or result payload. Gateway-authored invalid-member output is accepted only from the installed Gateway. No replay operation synchronously queries Scheduler, avoiding both same-worker and cross-worker Scheduler→Store→Scheduler wait cycles.

The worker transfers the invisible event to the current Controller before exiting. Scalar preparation is checked again before handler state commit. Each subsequent batch member replaces the one invisible candidate with the complete prospective decoded and encoded array. Earlier phases must be committed. The final ticket requires the installed Controller and the exact immutable final-array identity already authenticated by `HTTPWriterRegistry.finalize_batch/3`; an earlier member cannot authorize a failed aggregate.

The actual recorded socket alone publishes the event under the same original binding/phase/lease. A successful initialization result must match the exact addressed session’s completed protocol-version claim before publication; an unsettled claim leaves the invisible reservation intact. Publication is single use. Physical IO remains separately charged and releases only on its actual return or socket DOWN. A successful replay insert is an explicit callback/output effect; a later IO failure does not repeat the callback or erase the committed event.

The current addressed session backend is Runtime-owned ETS. “Durability” here means acknowledged publication into that retained session replay store, not disk persistence or survival across a fresh Runtime/cohort. The receipt enters an unconfirmed state before the native insert. If insertion or the actor fails after entry, the opaque receipt survives and reports `:session_event_durability_unconfirmed`; event and output release both preserve that error rather than manufacture confirmation. No callback retry or deadline renewal is allowed.

## Bounds and cleanup

Visible and pending events share `max_events`, `max_events_per_session`, `max_replay_bytes` and `max_replay_bytes_per_session`. A pending candidate charges its full retained decoded term, prospective wire, member wire/index/phase metadata, source proof, ticket and maximum monitor representation. This is conservative: a pending candidate can cost substantially more than its eventual visible event. Preparation rejects when combined capacity is unavailable; it does not evict replay before a handler commits. Direct append retains rolling per-session eviction but cannot steal pending credits.

Pending replay also reserves the session metadata growth needed by a finite 64-bit sequence cursor. Every session mutation respects that reserved headroom. Original operation payload limits still apply before the service actor receives data. Whole-model copies and encoding working memory are transient costs, rather than an additional total-process-memory guarantee.

A fixed producer row, limited to 512 charged bytes, is reserved once in the original HTTP ingress metadata budget and capped by live admitted callback work. Completion, Task DOWN and work retirement remove it; Scheduler replacement destroys the protected table. One monitor owns each pending candidate. Worker/Controller death, original cutoff expiry or exact session-epoch retirement reclaim non-entered reservations. Replacement uses a fresh token/version, so duplicate or late release of an older member cannot remove the newer candidate. Reaping processes at most 32 candidates in a finite service maintenance turn. An entered, unconfirmed durability obligation is not reclaimed as confirmed. A stopped owned ETS service retires ordinary pending receipts; entered receipts remain uncertain.

## Private seams

`SessionManager.RuntimeEvents.prepare(context, primary)` returns a primary ticket with its opaque event companion. `handoff/1`, `valid?/1` and `release/1` maintain the producer/Controller lifetime. `finalize(final_primary, latest_member)` authenticates a complete aggregate. `publish/1` accepts only the actual captured socket and returns `:ok` or an explicit error.

These internal functions do not add public `SessionManager` exports. Existing addressed `get_stats/2` adds `pending_events` and `pending_event_bytes` alongside visible event accounting. `HTTPWriterRegistry.response_primary/1` gives only the matching actual socket its queued opaque response companion; it does not expose a payload or bypass publication validation.

## Qualification and remaining work

The tracked `test/arbor_mcp/runtime/http_replay_reservation_test.exs` exercises real Runtime/worker/Controller/service transitions: invisible scalar handoff and publication, complete ordered legacy arrays with invalid members and notification omission, combined count and prospective term/wire pressure before state commit, direct append conservation, failed-array handling, producer death during handoff, Controller death/cohort replacement and capacity readmission, different-writer and forged-producer rejection, original-cutoff expiry, stale member release, session ID/epoch reuse, exact initialization settlement and altered-flag rejection before state commit, a deterministic two-worker interleaving with the Scheduler suspended, and an actual ETS insert failure after publication entry.

The standalone pure selection runs without repository `test_helper`, sockets, native helpers or global cleanup. It has 17 passing cases on Elixir 1.17.3/OTP 27.0.1, 1.19.5/OTP 28.4.1 and 1.20.3/OTP 29.0.5. The combined replay/Gateway/retained-session selection has 47 passing cases on both supported toolchains. Final static receipts are associated with the immutable handoff manifest. No physical legacy alias behavior is claimed by this prerequisite.

Remaining release work includes actual `/sse` and `/message` routes and immutable live-stream lifetime, actual wire initialization settlement plus reserved replay publication, addressed resource subscription fanout, reverse/progress helpers, real socket ACK/uncertainty and reconnect/replay tests, optional listener/Phoenix consumers, and retirement of the accepted `HttpPlug.start_link/0,1` exports. `HttpPlug.init/1` and `call/2`, `Server.notify_resource_update/1` and `HttpPlug.broadcast_resource_update/1` remain retained contracts.
