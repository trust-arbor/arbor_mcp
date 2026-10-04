# Initialization claim lifetime

This slice separates retained initialization authority from the finite wait for
one store operation. It preserves addressed SessionManager arities and result
shapes and does not change standalone APIs or HTTP production routing.

Within a runtime callback, ServiceOperation captures an immutable private
ServiceInvocation capability from the authoritative admission reservation. It
binds the runtime, service cohort, original request owner, request generation,
scope, token, per-member output phase and original request cutoff. The store call still has its existing
finite caller/configured wait, normally at most one second. A callback that
initializes for longer than that store wait can complete the same claim before
its actual request cutoff. Explicit `:deadline` only shortens authority, and an
explicit callback claim owner must match the admitted owner.

The session backend retains the invocation capability with its token and session
epoch. The per-operation CAS phase is deliberately absent from that retained
capability: returning from the claim RPC must not immediately revoke it.
Cancellation, failed retirement, owner exit, service-cohort replacement, session TTL and
the original cutoff still prevent completion. The same proof is checked again
at the final mutation boundary and during bounded maintenance/read validation.
Owner-down cleanup matches the captured session epoch rather than treating a
filtered read as proof that the underlying row is absent.

The callback captures its authoritative output phase when scheduling begins.
Pending service operations require the same phase in the current reservation;
a deferred callback cannot borrow a later batch member's reused envelope token.
Successful completion retains the immutable outcome cell through the original
cutoff and live owner/current generation checks, even after callback exit.
Cancellation of a later member or reused wire ID cannot revoke that success.
A cancelled or failed phase cannot become valid again on batch promotion.

Every completion attempt has a fresh short operation wait bounded by the
unchanged claim cutoff. A supplied shorter caller deadline is preserved instead
of overwritten. Expired or abandoned operations cannot later commit, while a
failed attempt may retry the still-valid original claim. A mutation already
committed is not rolled back when its caller times out.

Outside callbacks claims keep the existing finite operation lifetime. A future
integer cannot establish authenticated request authority. The separate HTTP
follow-up will consume an opaque HTTPWriterBinding authenticated by a bounded
root-owned gateway registry, capturing the actual socket owner and original
cutoff once before scheduling. This patch accepts no hypothetical HTTP binding,
unbounded registry, caller-selected validator or manufactured longer deadline.

Regressions cover initialization beyond the default one-second store wait,
short-wait retries, shorter caller cutoffs, cancellation and session-ID reuse,
original request expiry with a live owner, borrowed-store cohort replacement
with maintenance held, conflicting owners, finite outside-callback authority,
retired deferred batch callbacks and completed-success lifetime across ID reuse.
