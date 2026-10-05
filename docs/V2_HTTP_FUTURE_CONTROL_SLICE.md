# Mounted HTTP queued and future controls

This private continuation is based on canonical `c1ae91b8132f2fb8b7a73d2bcaf24399860c256a`, the exact retained HTTP twelve-path packet, and the exact thirteen-path control packet. It leaves both prior packets immutable. It also carries the separately qualified parent correction restoring the default `/mcp` endpoint for legacy direct call maps that omit `:endpoint`.

## Implemented behavior

A same-lease legacy cancellation can suppress a Scheduler-queued current callback or a future member of an already admitted legacy array. IDs retain their types: integer `7` and string `"7"` are distinct. Initialization IDs remain protected. Modern arrays remain rejected by the unchanged HTTP validators.

This includes a cancellation notification followed by its target request in the same admitted array. It also covers the two member handoff windows: a prior completed phase becoming a fresh unbound holding phase, and a member promoted before Scheduler binding. The holding transition accepts only the same envelope's completed prior phase, matching scope, generation, owner and live lease; invalid phases cannot authorize it. Scheduler rechecks the authenticated marker immediately before starting the callback, after Gateway has promoted and dispatched it.

For a future ID, the actual current Scheduler makes one token-only call to Admission using the cancellation source's original cutoff. Admission verifies the installed Scheduler generation and consumed source phase, then rechecks source/target authority immediately before inserting a marker. Markers carry the accepted source token/phase, immutable earlier source/target cutoff, runtime generation, target envelope scope, original Gateway owner, typed lease or trusted modern identity. Gateway verifies that receipt after member promotion and again before dispatch. A retired phase, expired cutoff, replacement generation, dead owner, or stale session epoch cannot revive it.

A live marker fails the existing whole-envelope response before the targeted callback. Earlier successfully committed member state remains committed exactly once; there is no replay, rollback, callback retry, or partial success array. The targeted member's ID identifies the cancellation error. A marker which expires before promotion becomes advisory and cannot cause a late effect; the still-live admitted target follows its ordinary path.

One immutable receipt exists per target token/ID. Duplicate controls coalesce without extending the first receipt's cutoff. Gateway precharges additional receipt/key bytes once per wire ID through its existing ingress metadata reservation: `512 + external_size({runtime, scope, lease, identity, id})` per ID. This includes fixed owner/generation/phase/deadline fields and the retained ID key, in addition to the original request/options charge. Counts remain bounded by admitted member permits; payload bytes remain charged once for the original envelope. Receipts are removed on member settlement or whole-envelope retirement. This is logical retained-byte accounting, subject to the separately qualified canonical binary-materialization union.

A cancellation source keeps its admitted input permit while its marker call is queued or uncertain. Admission sends one token/generation/phase acknowledgement to the actual Scheduler only after evaluating the call. Scheduler consumes it once before notifying Gateway. Timeouts do not reuse the credit. If Scheduler dies, Gateway may clear the pending control only after Admission has actually removed or replaced that exact reservation; deadline or socket return alone cannot trigger this cleanup.

## Qualification

The exact final source passes 28 focused pure cases on Elixir 1.17.3 / OTP 27.0.1, Elixir 1.19.5 / OTP 28.4.1, and Elixir 1.20.3 / OTP 29.0.5. The supported minimum/current toolchains also pass 38 retained Gateway cases and 95 runtime/deadline/batch/input-byte-cleanup/service cases. These harnesses use no repository `test_helper` or global cleanup. The handoff regressions selectively process already-produced native messages on their actual suspended owner processes, leaving the queued control and next-member dispatch in the intended order; they do not fabricate lifecycle events.

Before the final phase-handoff correction, the broader selection passed 35 cases on each supported toolchain, including ten actual wire cases using owned random-loopback Cowboy listeners and independent sockets. That physical proof covers queued, future and same-array cancellation, but is not an exact final-source physical rerun. Integration must rerun those physical cases. The retained before-fix log demonstrates the missing marker in the actual unbound holding window.

Final source passes warnings-as-errors compilation on all three toolchains, full formatting on both supported toolchains, strict Credo (727 loaded files, 64 checks, no issues), ExDoc warnings-as-errors, and normal Dialyzer on both supported toolchains with no new filters. Existing filtered counts remain 72 current and 66 minimum; the independent unfiltered audit reports no warnings in the four owned production modules. All dependency sources, builds and PLTs are private to this stage. Frozen artifacts record the exact source, prerequisite and evidence hashes.

## Canonical integration qualification

The merged source retains canonical RetainedTerm materialization and input
accounting in Admission. Its minimum/current runs pass the exact 38 convergence
cases (28 pure plus ten actual sockets), 19 retained-session and 43 Gateway wire
cases. Both complete suites pass 5,207 executed tests, 20 doctests and 34
properties, with 82 exclusions; minimum ExUnit reports the 5,289-test inventory
including exclusions. Formatting, production warnings-as-errors, strict Credo,
current ExDoc and normal minimum Dialyzer pass. Actual local newest production
compilation also passes. These results qualify this merged checkpoint; final
HTTP subscription/endpoint changes and release artifacts require their own proof.

## Remaining full v2 gates

This slice does not qualify mounted `subscriptions/listen`, cross-invocation resource publication, live legacy resource subscriptions, reverse request helpers, default/alias listener routing, or retirement of the six legacy HTTP callables and two wrapper modules. Those remain implementation work. Modern anonymous independent cross-POST cancellation remains the documented advisory no-op; native Client cancellation still closes its own originating stream. The existing bare-modern-notification metadata validation remains unchanged. Public callable, option, listener-ownership and wire consumers must migrate before the remaining HTTP APIs are removed.
