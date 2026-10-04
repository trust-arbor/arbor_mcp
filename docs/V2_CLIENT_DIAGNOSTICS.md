# Native Client diagnostic privacy checkpoint

This source checkpoint builds on `40f65d14b437c8da1cb1b0ac55f761980ca1fa70`
and the independently frozen ordinary Client lifetime/event-context followup.
It complements [Runtime diagnostics](V2_RUNTIME_DIAGNOSTICS.md) and
[ordinary Client ownership](V2_ORDINARY_CLIENT_LIFETIME.md). It is not a claim
that every application process or log handler has been qualified for v2.

## Supported diagnostic boundary

Built-in Client, connection-scope observer, lifetime observer, modern HTTP
stream actor, legacy SSE actor and subscription owner implement closed
`format_status/1` summaries. Managed state, message, arbitrary exit reason,
debug events and unknown future status fields are omitted. Summary counts
describe maps without enumerating their contents or invoking user callbacks.
Known fixed shutdown reasons can remain visible.

Native startup arguments and default child specifications are opaque for
these cooperative built-ins. The actual native GenServer/Supervisor parent,
module identity, links, original constructor wait and options received by the
child remain unchanged. `Lifetime.native_start` still supplies the exact
original initialization term to a custom module; it does not require custom
modules to interpret the private built-in constructor.

Built-in initialization failures use OTP's distinct failure acknowledgement
and exception channels: the caller receives its original typed error, while
the child's native exception reason is the fixed `:client_init_failed`.
For example, `{:transport_connect_failed, supplied_detail}` is preserved in
`Client.start_link/1` and `Supervisor.start_child/2` results. This does not
add a process, retry, alternate parent, logger filter or new time budget.

Client connection, receive, reconnect and OAuth failure logs retain a fixed
message plus a bounded description of the failure's shape. The default
sampling handler's rescue follows the same policy. Explicit returned protocol
errors and cleanup results keep their supported meanings. These changes do
not turn uncertain cleanup into success or replace the native subprocess
cleanup receipt with a process-DOWN assumption.

## Private callback worker change

Reverse-request handlers already capture ordinary raised/thrown/exited
callback failures and return a fixed internal protocol error. Concurrent
MRTR input callbacks now capture those failures inside their private Task
before the native Task worker can emit an exception report. The fulfillment owner
can inspect the original private failure tuple; the public Client response
remains code `-32603`, message `"MRTR input handler failed"`, with the
unchanged original handler state.

Consequently, a converted callback failure's private native Task now completes
with DOWN reason `:normal`. This is a deliberate private-worker semantic
change. Callback `self()`, native Task/stream-helper parent topology, pre-effect
ownership registration, concurrency, original deadlines and bounds remain
unchanged. Arbitrary external hard exits are not converted or retried.

Managed `Lifetime.async_stream` item/reservation arguments use opaque
constructors, so a native Task report does not print input payloads. Its
generic value and exit results retain their existing stream semantics; the
failure conversion belongs specifically to the MRTR callback boundary.

## Trusted host boundaries and limits

Returned errors can contain private values. A host that logs them deliberately
can reveal those values. In particular, when an initial child fails, the host
Supervisor can report the original typed reason returned by the child even
though the child's own native exception is fixed and its child specification
is opaque. Qualification includes this actual failed-child report; it does
not assert that all host Supervisor reports are redacted.

`:sys.get_state/1`, raw process dictionary/closure introspection, explicit sys
debugging, application callbacks and custom module/transport logs remain
trusted operations. The existing credential-aware Inspect implementation
does not promise to hide arbitrary application handler state. Applications
must avoid emitting confidential values from their own callbacks, exception
reports or returned-error logging policy.

This checkpoint installs no global logger policy or suppression. The host
continues to own stdout/stderr routing and its logger handlers. Qualification
covers the inspected built-in constructor/status/logging and callback seams;
whole-library report privacy, custom implementations and external hard exits
remain separate release/application qualification boundaries.

## Evidence

The isolated source manifest records the prerequisite and final hash of each
owned path. The standalone runner enables native SASL reports for the probes
and restores logger configuration afterward; production code adds no filter.
Tests prove native parent and custom-option identity, exact typed init errors,
actual failed Supervisor child startup, trusted state inspection, fixed status
summaries, ordinary reverse callback failures and MRTR raise/throw/exit mapping.
They also retain credential redaction, generic stream outcomes and the
ordinary Client/HTTP lifecycle/deadline regression selection.

The final checkpoint evidence, rather than this document alone, records the
toolchains, executed counts and static gates. Combined canonical qualification
and the final API/semantic census remain release gates.
