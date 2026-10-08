# Absolute admission and synchronous caller waits

This MCP v2 candidate builds on the owned runtime services and per-member batch
admission slices. It repairs two independent wait-budget refreshes without
changing the scheduler's serialized state commit or accepted-work lifetime.

`Runtime.request/3` captures one monotonic caller deadline at API entry, after
validating `await_timeout`. Resolving the runtime, sizing input, acquiring work
and byte credit, confirming admission, and waiting for the result consume that
same budget. A finite wait supports `0..4_294_967_295` milliseconds; zero admits
no new work. `:infinity` remains supported. The receive boundary checks the
original deadline both before waiting and when observing a result: a caller
suspended past its cutoff cannot consume a queued late success after resuming.

Admission retains a separately validated signed-64-bit caller deadline, charged
with retained options. Its original server deadline still starts at the work
claim and remains capped by the runtime request limit. Permit contention and
byte-claim retries recheck the earlier deadline. The token-only confirmation
call uses the minimum of remaining server time, remaining caller time, and its
existing five-second control limit. It reports `:handler_timeout`,
`:await_timeout`, or `:runtime_unavailable` according to the limiting budget.
The owner rejects an expired confirmation before registering work, monitoring
participants, or emitting admitted telemetry.

A confirmation timeout is uncertain: the owner may have confirmed before its
reply was lost. The producer sends an abandon control and retains the complete
count/byte claim until the admission owner releases it. It never permits early
count reuse alongside a still-live reservation. A candidate that has not sent
confirmation can be rolled back directly; token/producer ownership makes
duplicate cleanup safe. Expired multi-member input leaves no partial permit set.

Once accepted, work uses its server deadline and lifetime owner. A shorter
caller wait does not cancel that work or discard a valid later state commit.
The caller's reply alias is deactivated and any already queued token reply is
discarded. Low-level `submit/3` and `await/2` retain their existing retry and
delivery contract. Explicit cancellation and owner death still retire work.

The six new regression cases exercise suspended Admission with each limiting
deadline, conservative uncertain-confirm credit, no admitted telemetry or
callbacks after expiry, delayed confirmation consuming the original caller
wait, accepted work committing after caller expiry, replies queued while a
caller is suspended, empty late-reply mailboxes, zero/invalid waits, oversized
integer metadata, and whole-batch rollback/readmission. Qualification runs the
existing runtime, caller, batch, service, and handler-edge cases alongside them.
The final combined suite passes **110 tests** on Elixir 1.17.3/OTP 27.0.1 and
Elixir 1.19.5/OTP 28.4.1. Both pass warnings-as-errors application compilation;
current strict Credo passes without new filters. An independent read-only
probe confirms oversized metadata rejection with zero retained credit and the
already-queued late-reply case returning `:await_timeout` with an empty mailbox.

This slice establishes deadline checks and finite confirmation waits. The integrated
[input-byte cleanup slice](V2_INPUT_BYTE_CLEANUP_SLICE.md) adds finite contention handling with retained
reapable credit; its separate source/pressure limits remain explicit.
It does not certify a hard return-time bound during arbitrary VM suspension or
sustained cleanup contention. Store startup/control budgets, server stdio/HTTP,
output preparation before state commit, transport writers, grouped batch output,
EOF drain, and measured release pressure remain separate requirements.
