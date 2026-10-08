# Test/BEAM and custom-call output integration

This slice is integrated into the unpublished MCP v2 draft after review against
`fd11532` and the earlier runtime slices. It integrates the private output ledger into callback completion for Test/BEAM
requests and synchronous custom calls. Server stdio, HTTP, helper notifications,
reverse requests, subscription delivery and the full EOF drain remain later
release gates. It is not a claim that every server output path is bounded.

## Ownership and completion

`ExecutionSupervisor` starts callback tasks, `OutputController`, then Scheduler
under `one_for_all`. The Controller owns a linked Ledger; both register with the
runtime shutdown guard. Losing an execution child retires its execution
generation. The Controller can reconnect to the still-current edge peer after
restart. A peer is borrowed: retirement and shutdown never kill it.

The callback task validates its result and prepares a hidden ticket before
returning a state proposal. The Ledger atomically transfers the producer lease
to Scheduler while the ticket remains hidden. The producer's subsequent DOWN
cannot discard a ticket awaiting Scheduler completion. Scheduler rechecks the
original deadline, cancellation, owner and proposal before committing state.
Rejected preparation or validation leaves handler state unchanged.

After commit, Scheduler publishes the ticket and retains the stateful slot until
the output's terminal handoff. Worker DOWN and output completion are separate
events. A lost Task result, cancellation, expiry or generation retirement releases
the transferred ticket. Delivery failure after commit is explicit and never
re-executes the callback or rolls back an earlier effect.
Scheduler writes a fixed-size token/ticket publication proof before publish;
the writer consults it even if queued output expires before its first checkout.
That path sends an explicit terminal failure before releasing work or retained
envelope input, so a committed response cannot silently disappear.

The Controller receives token/ticket control messages, not response payloads. It
pulls the already charged immutable term and wire from Ledger. Local delivery ACK
means `Kernel.send/2` returned. It does not prove peer processing, and an inactive
custom-call alias can discard the sent reply. A peer's mailbox is not bounded by
this ledger. The existing original-caller custom callback proxy remains intact.

## Codec and budgets

| Setting | Default | Meaning |
| --- | ---: | --- |
| `max_output_frame_bytes` | 1,048,576 | Prepared wire bytes, including reserved LF |
| `max_output_term_bytes` | 1,048,576 | External-size charge of the retained decoded term |
| `max_output_bytes` | 4,194,304 | Combined hidden, held, queued and in-flight claims |
| `max_output_frames` | 128 | Combined frame claims across all stages |
| `max_output_scope_bytes` | 65,536 | Explicit scope/control metadata, including direct calls |
| `output_timeout_ms` | 5,000 | Finite output control/terminal-error handoff budget |

Protocol replies accept plain JSON terms after Dispatch result normalization;
ordinary atom values such as `Content.text/1`'s `:text` normalize for wire encoding.
PID/ref/struct/non-UTF8 nested protocol values reject before state commit. No
user-defined Enumerable, Jason or Inspect protocol executes during preparation.
Explicit authored `isError` tool results remain normal results and can commit.

Custom replies use a separate term policy: PID/ref/struct/function/improper-list
and arbitrary-byte replies retain their exact terms. A deadline-aware native-term
walker checks a finite lower bound before `external_size/1`; this channel does not
JSON-encode or serialize the reply. Wire output and decoded terms have separate
caps. Handler state and the arbitrary work a callback performs remain outside
these output bounds.

Request, initialization, shutdown, cancellation-grace and output-control timers
validate against the finite uint32 range before children start. Zero remains valid
for cancellation grace; other timer budgets must be positive.

## Legacy batch policy

Every response member reserves its retained term/wire plus prospective aggregate
charge before that member's state commit. Its ACK means **staged handoff into a
charged group**, not peer delivery. Notifications add no output member. The
envelope input permits and held output claims survive between member callbacks.

Final consolidation atomically replaces the charged members with one charged
array; it has no interval with zero credit and no duplicate credit release. The
Test peer receives one encoded array; BEAM receives one decoded array. If a later
member cannot prepare output, earlier sequential effects remain committed, the
whole envelope fails explicitly, and no partial array is sent. An expired batch
also fails as a whole envelope.

Server-authored timeout/cancellation/crash responses use one immutable finite
terminal-error lease tied to the original reservation generation, scope and
caller. This allows the existing wire failure after the callback deadline without
extending a success deadline or re-running work. The error still consumes ordinary
ledger count/byte credit. A retired connection cannot reopen through that lease.
Late worker cleanup cannot retire the separate terminal-error lease.
Managed scopes retain an immutable original deadline even if registration fails
between scope creation and subscription. Empty scopes reap independently of the
Controller job map; registration retries can shorten that deadline but cannot
renew it. Explicit standalone Ledger scopes opened without a deadline remain
tied to their lifetime owner.

## Qualification and remaining gates

The isolated candidate uses independently copied dependency/build caches and
immutable RPC framing source `b46cbfe8ced0d29519462f8a83b64e5750caaa92`.
No native helper is needed by the standalone output tests. Evidence logs are
outside the package under the parent checkout's `tmp/mcp-output-*` paths.
Combined pipeline qualification also copies the separately reviewed additive
`Server.DSL.Result` and collision-rejecting `Server.ResultNormalizer` sources;
those producer files are identified separately in the source manifest and are
not owned by this output slice.

The focused suite covers exact custom terms, precommit rejection, ordinary public
RPC wrappers, producer death before publish, prospective aggregate overflow,
single array handoff, credit release, worker DOWN versus delivery, transferred
proposal cancellation, authored versus invalid nested protocol results, expired
queued batches and timer validation. Retained runtime tests cover cancellation
scope, callback controls and sequential batch behavior. Full default and CI-tag
qualification, minimum toolchain checks and independent race review are recorded
with the final source manifest; this document alone does not certify those runs.

Remaining gates include stdio/HTTP writers and their actual transport ACK/pressure
contracts; helper/subscription output admission; clean EOF sealing/draining;
throughput/RSS qualification of producer codec allocations, whole-row ETS CAS
copies and retained term/wire duplication;
and raw same-VM mailbox/control sends. Local peer mailboxes and VM/OS buffers are
not hard memory bounds. No new deadline or pressure outcome claims peer processing
or side-effect rollback.

Root combined qualification includes native RPC `0e4cfd1`, finite input cleanup,
addressed session/resource phases, original cohort startup and collision-safe
result normalization. Current/minimum full CI selections each pass 20 doctests,
34 properties and 3,991 executed tests, zero failures (82 excluded; minimum
displays the 4,073-test inventory). Current final-codec checks pass all 39
standalone cases after an unreachable private guard was removed for Dialyzer.
That guard removal followed the current full run; minimum full qualification
uses the final codec source. Fresh final-commit CI remains separately required.
