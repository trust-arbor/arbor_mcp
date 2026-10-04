# Server stdio runtime and output slice

Status: isolated implementation checkpoint, 2026-10-04. Based on MCP
`e0f1c9a6bbe1d239da0918e2cf9e0378802ba7bb`, with shared RPC
`0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb`. This does not finish HTTP,
initialization-barrier integration, or all release qualification.

## Production ownership and delivery

`StdioServer.start_link/1` now returns the Runtime supervisor. Its edge is an
owned `Stdio.Supervisor` containing one Writer, shared HandlerServer, and one
Reader. Handler callbacks use the same Scheduler and precommit OutputLedger
as Test/BEAM. The existing handler `init/1` option input is preserved unless
`:handler_args` is explicit. Supported `Server` helpers replace direct custom
GenServer calls against the old inline stdio process.

The Reader reads one character/byte at a time and checks `:max_request_bytes`
before accumulating another unit. It retains at most one bounded physical
line outside admitted input. Blank or non-JSON lines are ignored. The first
physical line may contain a UTF-8 BOM; CRLF, Unicode and a valid unterminated
final JSON frame retain their prior framing behavior.

Responses are normalized, encoded and charged before callback state commits.
The Controller holds a bounded FIFO of opaque tickets and sends the Writer
only a ticket. Exactly one write is in flight. The Writer claims already
charged bytes from the Controller; the ticket remains charged until actual
IO completion and ledger ACK. No callback or committed side effect is retried
when publication, output or ACK fails. Batch member ACK still means staged
handoff into the charged group; only the aggregate's actual write settles the
envelope's terminal output credit.

The stdio-only envelope barrier holds later data envelopes behind the prior
response's actual completion. Reverse responses and the separately bounded
helper control lane remain responsive. Notification-only envelopes also
release the barrier. This intentionally serializes stdio envelopes even when
callback execution is configured stateless.

Callback helpers using `self()` resolve through the active CallbackContext
runtime. Their source generation/scope is preserved. Explicit other runtime
addresses and `self()` outside callbacks retain their prior resolution.

## Retained source proofs

Each confirmed invocation retains a monotonic outcome cell: active becomes
completed success or invalid once. A committed success is fixed at Scheduler
publication proof; later cancellation cannot undo that state or invalidate a
completed cell. Each promoted batch member gets a fresh cell.

Admission charges a fixed 64-byte cell/metadata allowance per retained
invocation and serialized nonempty source-proof bytes for helper controls.
Cells are allocated only by serialized successful confirmation or retained
batch advancement, never during failed producer CAS retries. A queued direct
control frame retains its source cell, token, scope, generation and original
cutoff inside the charged output scope metadata. There are no permanent
cancellation tombstones. References retire with bounded input/output records.

The control lease is the earliest of its original source cutoff and its own
finite output cutoff. Queue promotion and Writer claim revalidate source
outcome and current peer/generation. Active-source cancellation suppresses a
queued effect; successful source completion permits it until the original
cutoff. Peer retirement suppresses it independently. An actual in-flight
write cannot be recalled or retried.

**Release-critical residual:** modern `notify_*` helpers that publish into
SubscriptionListener queues lose their optional callback source proof before
listener-to-edge-to-ledger delivery. Their queue limits and connection checks
remain, but the source cutoff/cancellation proof must be carried through the
owned registry/listener metadata in a separate slice, without changing wire
shapes. Direct queued helper frames are qualified here; those subscription
publication effects are not yet qualified under the retained-source contract.

## EOF and failure

The same Reader confirms and publishes the final input before sealing input.
New data/custom admissions are fenced. Already admitted work retains its
original deadlines; active scoped controls can still finish accepted work.
EOF also closes unanswered reverse requests and subscription streams.

One `:stdio_eof_timeout_ms` cutoff is established before the input fence and
never refreshed by polling or writing. Its default is request timeout plus
output timeout, capped at the finite OTP timer limit. HandlerServer waits for
input reservations, Scheduler work and output credit to drain before requesting
normal Runtime stop. ShutdownGuard separately observes the original edge and
connection, so an unresponsive edge cannot prolong EOF or let a stale drain
timer stop a replacement peer. The guard stops only proven owned children.

A write timeout after Writer claim is `:output_write_uncertain`; known ledger
ACK failure is terminal too. Borrowed IO devices and group leaders are never
registered as owned or killed. They can complete an old irreversible request
later, so Runtime death does not prove that no bytes subsequently escaped.
Raw OS buffers, borrowed device buffers, arbitrary same-VM raw messages,
transient term/list copies and write-side blocking are outside hard mailbox or
RSS guarantees. Throughput/RSS, sustained pressure and platform tests remain
release qualification gates.

## Startup and host migration

The server no longer changes VM-global Logger/application configuration.
Configure the host's Logger to stderr before starting stdio and route handler
diagnostic IO explicitly to stderr. `:stdio_input` and `:stdio_output` are
borrowed devices, defaulting to the starting caller's group leader.

This checkpoint uses the existing early ShutdownGuard ownership registration.
The separately frozen Initialization slice must supply `watch`, `remaining`,
`edge_start` and the final ready gate at merge. Reader IO/admission and initial
stdio peer/scope activation must wait for that original startup epoch to be
ready; fresh constructor timeouts or pretend readiness are not acceptable.
Uncertain stdio edge/writer failure fail-stops rather than silently reopening.

## Evidence and remaining gates

The owned source manifest and tracked patch are stored under root `tmp` as
`mcp-server-stdio-source-manifest.json` and `mcp-server-stdio-tracked.patch`.
All dependency sources/builds are private per toolchain. `MIX_DEPS_PATH` selects
transitive sources; fixture-only TS environment forwarding retains it alongside
the existing split-development overrides. SDK fixtures launch the parent's
already-compiled build with `mix run --no-compile --no-deps-check`; the manual
`mix interop_server` task retains compilation by default. A cold child bootstrap
otherwise rebuilt dependencies before discovery could reach the server. No
protocol timeout or SDK/golden transcript bytes change.

The final combined selection passed on Elixir 1.19.5/OTP 28.4.1 and
Elixir 1.17.3/OTP 27.0.1: 184 executed tests, zero failures, four exclusions,
including all 13 official SDK lanes and 19 new stdio lifecycle cases. It covers
actual IO/ACK, bounded raw reads, original-cutoff EOF, cancellation accepted
before releasing Writer credit, retained source proofs, batch ordering,
reverse-response progress and existing Runtime/output/edge behavior. Logs are
`tmp/mcp-server-stdio-{current,min}-final-combined.log`. The accompanying
version-2 manifest records exact source hashes and separate project compilation,
dual-formatter and strict-Credo outcomes; these checks do not claim that
third-party dependencies or runtime-evaluated fixture modules are warning-free.

Release qualification still includes the exact merged Initialization/stdio
combination, the subscription source-proof residual above, HTTP/mounted writer
ownership, newest-toolchain checks, full package/archive consumers, Linux/macOS
lifecycle/pressure tests and any unsupported-platform safe-failure gates.
EOF drain and local IO return acknowledge the borrowed IO boundary; neither is
remote peer application acknowledgement.
