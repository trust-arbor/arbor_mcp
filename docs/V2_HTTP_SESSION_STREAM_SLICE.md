# Mounted HTTP session streams

This isolated slice adds root-addressed legacy GET, replay and DELETE to the
mounted HTTP Gateway checkpoint. It does not complete HTTP convergence or retire
the deprecated HTTP API. Its source base is canonical `8ffa713`, the exact frozen
13-path writer installation, the exact frozen 26-path Gateway, and the separately
qualified initialization ownership fixture. The Gateway freeze remains unchanged.

## Implemented behavior

An initialized legacy session can GET the mounted MCP endpoint with its
`MCP-Session-Id`, negotiated `MCP-Protocol-Version`, and `Accept: text/event-stream`.
The actual Plug process validates addressed identity and a typed session epoch,
then writes the handshake and each bounded replay frame itself. It uses the root's
existing writer domain; it does not create a per-GET handler or use a global SSE
registry. The response preserves legacy `event`, JSON `data`, and durable store
cursor `id` framing.

Without `Last-Event-ID`, GET captures the latest store-owned cursor before opening
the response and sends a `connected` handshake. It delivers subsequent events;
old history requires an explicit cursor. Supplied cursors have tagged unknown,
foreign and evicted outcomes before response headers: unknown/foreign/invalid
headers yield 400 and evicted cursors yield 410. Pages use at most 32 events and
64 KiB, further restricted by the configured addressed store limits. Each actual
frame is separately pre-admitted, published, checked out and acknowledged only
after the adapter returns. A sequential frame can reclaim a prior returned
receipt while Guardian notification processing is paused; an unresolved physical
write retains its count and bytes.

`:sse_mode: :oneshot` sends the handshake and all currently pending bounded pages
and returns. `:stream` polls the addressed store at up to 50 ms intervals. It
retains the original HTTP entry cutoff (`request_timeout_ms`, default 10 seconds)
and does not renew work or IO authority on a poll. Connection expiry or normal
GET disconnection preserves the initialized session for reconnect. The existing
charged writer row also holds the stream registration. A new persistent stream
for the same typed lease retires the previous binding without killing its
borrowed socket or reusing outstanding actual IO credits.

DELETE reserves its empty 204 response before terminating one addressed epoch.
The response keeps entry authority separate from the lease being deleted. The
store's final mutation guard still checks the original cutoff, owner, service
namespace and epoch. Saturated IO capacity rejects before deletion; a delayed
operation cannot terminate the session after its cutoff. Successful termination
clears that epoch's replay and wire request-ID credits. A different identity
cannot read or delete it. Modern GET/DELETE remain sessionless 405, including
auto-mode requests bearing the modern protocol version.

## Store and private API changes

`SessionManager.replay_cursor(service, lease, opts)` returns the current opaque
store-owned cursor or nil. The addressed append/replay/get/terminate facades now
have explicit opaque service/lease specs and do not destructure a service outside
its defining module. Native store identity and initialization errors retain
distinct tags; repeated HTTP initialization maps to the existing scoped 400
lifecycle response.

Replay append uses the bounded native protocol codec, without invoking arbitrary
Jason/Enumerable/Inspect implementations. It requires plain JSON and checks both
encoded event content and serialized retained term against `max_event_bytes`.
The latter is an explicit memory constraint; a compact JSON value with a larger
retained BEAM representation may now be rejected. Durable page bytes and the
writer's IO credits remain separate bounds, and transient producer/page copies,
HTTP headers, adapter/socket buffers and total VM memory are not included in the
IO ledger bound.

The event keeps the codec's prepared original-shaped term, which allows the
separate retained-binary materialization overlay to detach backing storage before
durable retention. This base snapshot predates that overlay; its focused results
do not qualify the later backing-binary pressure gate.

The included `OutputController` hunk corrects an optional `edge_ticket` insertion
on authenticated control jobs. It uses `Map.put` on the existing job so stdio and
subscription job maps lacking that optional field do not crash. The immutable
Gateway freeze is not rewritten by this correction.

## Qualification

Exact final current and minimum source passed 19 focused cases each (15 lifecycle
and fake-IO cases plus four real Cowboy/random-loopback wire cases). The physical
proof checks replay ordering and IDs, live stream updates, DELETE response
termination, reconnectable sessions, cursor rejection and listener survival.
The lifecycle proof includes paused Guardian receipt reclamation, IO pressure
before DELETE, original-cutoff checks at the final mutation guard, stream
replacement with unresolved IO, and arbitrary encoder rejection.

The prior immutable Gateway26 was rerun separately after freeze and passed its
40-case physical selection on both supported toolchains. These are independent
source/build/native dependency copies. No global test helper or shared port
cleanup was used. The prior 35-case pure Gateway selection and 39 addressed-store
and initialization-claim cases also passed on both supported toolchains. The
store runner supplies its own standalone-store fixture solely to verify that an
unconfigured runtime does not fall back to it.

Warnings-as-errors compilation and full formatting pass on Elixir 1.17.3/OTP
27.0.1 and 1.19.5/OTP 28.4.1. Strict Credo checked 706 files with 64 checks and
11,807 modules/functions, with no issues. ExDoc succeeds on the current toolchain.
Normal Dialyzer reports 67 minimum and 73 current warnings, all covered by the
unchanged existing filters. Independent raw diagnostics report zero warnings in
the owned source paths; no filter was added. Full canonical application, newest
toolchain and SDK qualification belongs to integration and is not implied by
these focused results.

## Remaining HTTP release gates

- Mounted deprecated `/sse` endpoint advertisement and `/message` 202/durable
  response delivery still require runtime-owned integration; the explicit 501
  fence on this optional alias is retained.
- Addressed resource subscriptions and modern subscription origin delivery must
  use the mounted runtime and store/IO source proofs. Polling persisted events is
  implemented; automatic publication and subscription lifecycle are not.
- Session-specific cancellation must match captured epoch and request ID without
  cancelling another session's same ID. Full MRTR context/protection and mixed
  or initialization arrays need actual runtime/wire proofs.
- A deterministic probe also found that an accepted notification-only array stops
  after its first member when its socket returns after 202. The Gateway must keep
  the whole accepted notification envelope alive under its original deadline;
  this separate fix is the first task in the next convergence overlay.
- Owned listener startup/stop and supported external consumers must migrate
  before the six deprecated HTTP callables/two wrapper modules are retired.
- The separate upstream native helper, stdio endpoint-domain, retained-binary
  pressure and runtime crash-privacy work is preserved by narrow integration;
  this source base predates those parent overlays.

None of these gates is deferred to v3. They are the next HTTP convergence slices.
