# Scoped HTTP notification slice

This slice follows the exact resource-publication checkpoint and the qualified
legacy-alias routing overlay. It adds callback-scoped progress and retained
Server notification helpers to the mounted HTTP runtime. It does not implement
HTTP reverse requests or remove any public export.

## Address and lifetime

An actual HTTP callback captures the existing protected Task producer proof:
Runtime, original invocation token/output phase, cohort generation, scope,
Gateway, private forward endpoint, principal/tenant, exact session lease and
original cutoff. A copied process dictionary or Source value cannot make a
different process a producer. The addressed session actor rechecks that proof
at the final store mutation using protected ETS metadata, without a synchronous
Store-to-Scheduler call.

`Server.notify_progress/3,4`, `send_log_message/4`, resource/list/roots change
helpers and `cancel_request/2,3` detect the actual HTTP invocation before the
existing native edge path. An HTTP callback cannot redirect these controls to a
different Runtime. Non-HTTP calls retain the bounded native control lane.

Request-owned SSE keeps the existing charged Controller output ticket and
waits for the actual adapter IO return. Legacy `/sse` → `/message` callbacks
instead append a bounded replay notification in their exact addressed session
before accepting the final reply. `:ok` on that path means **durable replay
acceptance**, not a receipt for client bytes. A currently live exact session GET
is required at producer-side admission to the bounded Store operation; there is
no fallback to another session or a global registry. GET retirement after that
admission does not revoke the queued replay operation: the final mutation still
requires the original live producer, phase, cutoff and exact lease. A reconnect
can replay the accepted event; no delivery to the retired socket is promised.
Primary JSON callbacks can use the retained Server helpers to address their
same-session GET without acquiring a request-owned stream.

Modern resource/tool/prompt topic changes use the Runtime's configured scoped
subscription service, preserving its publication authorizer, filters, source
outcome proof and target identity. Progress/log helpers do not fall back to a
modern listener. `Context.report_progress/3` still requires the request's
`_meta.progressToken`. Modern `Context.send_log_message/3` still requires an
explicit request log level. Legacy metadata does not establish that modern log
intent; legacy callbacks use `Server.send_log_message/4`.
An application that explicitly supplies its own legacy log intent also receives
the addressed replay target's typed capacity/operation/source failures.

## Bounds and effects

The existing input reservation charges notification-target metadata; the
existing ServiceOperation budget charges the complete callback notification and
Source before publication to the addressed store. The store uses the existing
native protocol codec, detached event term, prospective pending-plus-retained
replay caps and final mutation guard. Custom JSON/Inspect/Enumerable protocols
are not invoked. Invalid opaque nested protocol values return the existing fixed
event error. Resource URI notifications require nonempty UTF-8 up to 4,096 bytes.

There are no new producer tasks, mailbox payload relays, receipt pools, global
services, per-event deadline renewals or borrowed socket kills. The underlying
physical writer liability remains charged until an actual IO return or monitored
writer DOWN, including logical request retirement and Runtime replacement.

An accepted durable append is an entered service effect. Cancellation before
the final store guard prevents it. Cancellation after acceptance cannot roll it
back. Likewise, earlier progress/log events may consume replay capacity before
the callback's final output is known: if final output preparation then fails,
the earlier events remain, proposed handler state does not commit, and the
callback is never replayed. Fixed typed capacity/timeout/source errors are
returned without exposing the failed notification payload.

The `Context.report_progress/3` and `Context.send_log_message/3` error specs now
permit the existing typed atom errors from addressed replay/operation pressure,
as well as request intent, stream and cancellation errors. Their public callable
arities are unchanged.

## Qualification and remaining gates

The standalone suite covers legacy durable ordering, all retained notification
cast shapes, primary JSON-to-GET delivery, offline/cross-session isolation,
request intent, opaque nested values, copied/retired producer proofs,
cancellation before append, accepted append followed by cancellation, exact
replay and Context log pressure with no handler-state commit, admitted append
survival across GET retirement, wrong Runtime, retained native
controls and modern scoped topic publication. Retained mounted SSE tests also
exercise actual Plug adapter returns without network listeners.

The separate wire suite explicitly selects `sse_mode: :stream` on both forwards.
It checks legacy progress/log/final ordering after the GET's short entry cutoff,
modern request SSE progress/log/final IO ordering without session headers, and
same-era cross-forward/session isolation. Every owned listener is monitored DOWN
and its port must refuse a fresh TCP connection after shutdown.

Final qualification includes the 16 new pure cases in a 103-case retained
selection on Elixir 1.17.3/OTP 27.0.1, 1.19.5/OTP 28.4.1 and 1.20.3/OTP 29.0.5;
all pass. The first immutable packet's three physical wire cases passed serially
on both supported toolchains. The separate followup changes only Context's
error spec/prose and this document, and adds the log-pressure and queued GET
retirement regressions. Its production runtime bodies and wire fixture are
unchanged; the followup did not rerun physical listeners.
Warnings-as-errors compilation and full formatting pass
all three; supported-toolchain ExDoc and normal/raw Dialyzer pass with zero
warnings on the six owned production files, unchanged 72/current and
66/minimum baseline filters, and no added filters. Strict Credo checks 775 files
with 64 checks and no issues. Final wire teardown also verifies no known native
helper Port remains. Exact source hashes, commands and exit receipts are
recorded in the two immutable qualification packets. This slice does
not claim the continuous soak, final archive/Phoenix consumers, unresolved HTTP
timeout diagnosis, or mounted reverse-control gate is complete. The parent
integration must preserve the independent `HttpPlug.start_link/0,1` deletion,
public-stop followup and Client notification metadata fixes.
