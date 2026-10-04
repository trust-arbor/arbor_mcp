# HTTP borrowed-writer liability prerequisite

This isolated candidate is based on MCP commit
`7b71184e8903671beb04e3698b9d47afc2e9e1aa`. It adds a private writer accounting
core and standalone tests. It does not mount HTTP on Runtime, change HttpPlug,
wire Config/Scheduler/OutputController, or give existing HTTP paths new output
bounds. Startup, stdio and initialization-claim changes remain separate
prerequisites for that integration.

## Lifetime and accounting

The Plug connection process performs `send_resp`/`chunk`. In the locked Bandit
adapter, `validate_calling_process!/1` requires the adapter's owner PID to equal
`self()`. Moving Conn IO to a library worker therefore changes a real adapter
contract. The library must borrow the socket writer and monitor it without
terminating it.

`Runtime.HTTPWriterRegistry.start(root, opts)` creates one unlinked guardian and
opaque domain. The planned root-owned proxy retains this same domain across
proxy/execution replacement. The guardian is **not yet installed** in Runtime.
It must be excluded from ordinary forced-child kill provenance while borrowed
IO remains outstanding. Root death seals new admission and retires queued
output; checked-out liabilities survive until the actual writer reports its IO
return or that monitored writer dies. After a sealed domain has no remaining
frame claims, the guardian exits after its finite idle interval. Unexpected
guardian death permanently invalidates that domain; a proxy must fail closed
instead of allocating replacement credits. Distinct runtime roots have distinct
domains. These are per-root bounds, not a global bound across application-created
roots or indefinitely blocked borrowed hosts.

Preparation atomically claims count and serialized byte credits before its wire
binary enters the ETS row. Prepared output is invisible until owner publication.
Candidates, prepared, handed-off, queued and in-flight frames share the same
count/byte budget. Checkout authenticates the actual writer and permits one
in-flight frame per writer. It marks potential IO before returning the binary.
Retirement, scope expiry, owner death and generation retirement cannot release
that frame. There is no timed auto-ACK or automatic retry after IO uncertainty.

An IO return sets a fixed-size, authenticated atomics receipt before cleanup.
The guardian reaper can finish byte reclamation under contention; an actual
completion is never lost because a CAS retry budget expires. Completion is
idempotent and cannot release a newly admitted token. Hidden-output release and
failed preparation similarly retain a bounded cleanup receipt until reaped.
All CAS loops have an original absolute deadline and a 512-attempt cap; cleanup
and each guardian turn use a separate finite control budget.

The actor receives a coalesced wake without payload. A socket receives only
`{:mcp_http_output_wake, domain, nonce}`. One outstanding wake is retained per
writer PID **across binding lifetimes**, including retired idle writers. The
socket acknowledges the nonce it actually received using `acknowledge_wake/2`.
An old nonce cannot clear a later wake. Retirement acknowledgement is separate
and does not clear a pending wake. Pending idle slots remain count/metadata
charged until acknowledgement or writer DOWN. Callers must not assume that
retiring a binding drains their mailbox.

## Private API

All types below are private opaque handles; these are not new public server APIs.

| Function | Contract |
| --- | --- |
| `start(root_pid, opts \\ [])` | `{:ok, domain}` or fixed error; deliberately unlinked. Optional `runtime: ref` must match this root. |
| `ref(guardian_pid)` / `guardian(domain)` | Recover the same domain / its guardian address for the future proxy and monitoring. |
| `register(domain, writer_pid, proof, owner: pid)` | Create one binding per writer; bounded immutable proof requires invocation token, runtime generation, scope, lease and signed finite original deadline. |
| `prepare(binding, framed_binary, owner: pid, deadline: cutoff)` | `{:ok, ticket}` or fixed error. A supplied cutoff can only shorten the invocation cutoff. No iodata or custom encoder is called. |
| `handoff(ticket)` | Producer transfers to the recorded persistent owner before Task return; that owner may also accept while the producer lives. |
| `publish(ticket)` | Recorded owner only; makes already admitted output visible. |
| `checkout(binding)` | Actual writer only; `:empty`, error, or `{:ok, ticket, framed_binary}`. One outstanding physical handoff per writer. |
| `complete(ticket, :ok \| {:error, term})` | Actual writer only, after the IO return. Fixed failure/uncertainty result; arbitrary adapter errors are neither retained nor inspected. |
| `release(ticket)` | Producer/owner releases hidden or queued output; rejects in-flight release. Reclamation may finish in the reaper. |
| `retire(binding, reason)` / `retire_generation(domain, generation)` | Logical retirement; preserve checked-out liabilities. |
| `acknowledge_wake(domain, received_nonce)` | Authenticated socket consumes its outstanding wake. |
| `acknowledge_retirement(binding)` | Socket acknowledges logical closure; never substitutes for an IO return. |
| `seal(domain)` | Fence new admission and retire non-in-flight output; `:ok` does not mean borrowed IO has settled. |
| `proof(binding)` / `stats(domain)` | Bounded diagnostics without response payload. |
| `HTTPWriterBinding.validate(binding, runtime_ref)` | Matching live Runtime.Ref and current authoritative route generation required. Returns immutable runtime/socket-owner/deadline/scope/generation/lease/invocation snapshot; generic standalone domains cannot authenticate service origins. |

The HTTP gateway must capture the original request cutoff once at entry. It
will own the binding; the socket owns physical writes. Its validated binding
origin can feed ServiceOperation's independent invocation lifetime while the
service RPC retains its own short wait. One-time session-lease binding and a
positive real-runtime/service origin fixture are still integration work.
The standalone `register/4` accepts a private caller's bounded proof. Its
validator authenticates the retained row, live parties and runtime generation;
it does not yet prove that a cutoff was captured at HTTP entry. The root-owned
proxy/gateway must own registration and original-cutoff capture before this
binding is accepted as a ServiceInvocation origin.

## Proposed Config mapping

These names/defaults are a concrete integration proposal. Config is unchanged.

| Proposed Runtime option | Private core option | Default |
| --- | --- | ---: |
| `max_http_writers` | `max_writers` | 128 |
| `max_http_writer_metadata_bytes` | `max_writer_metadata_bytes` | 65,536 |
| `max_http_io_frames` | `max_io_frames` | 128 |
| `max_http_io_bytes` | `max_io_bytes` | 4,194,304 |
| `max_http_io_frame_bytes` | `max_io_frame_bytes` | 1,048,576 |

`max_io_frame_bytes` includes every actual JSON/SSE framing byte, not only
encoded content. A frame charge is `byte_size(wire) + external_size(wire) +
external_size(claim_metadata) + 256`; binding and writer-slot metadata are
separately charged using their serialized size plus fixed bookkeeping reserve.
The registry also caps proof metadata at 4,096 bytes. The defaults are ceilings:
the metadata/byte limit may bind before the writer/frame count limit.

This is a conservative **separate** IO budget. With the proposed defaults,
primary output-ledger credits can total 4 MiB and HTTP IO liability credits can
total another 4 MiB, plus 64 KiB of registry metadata. It is not a shared 4 MiB
aggregate. These account serialized data, wire and bookkeeping, not total BEAM
heap, producer transient allocations, Plug/kernel buffers, or all application
memory. Whole-row ETS CAS can transiently copy the admitted row and has a real
throughput cost. Final same-runner throughput, queue pressure and memory
qualification must measure this representation before release.

## Next integration and migration gates

1. Install a root-lifetime proxy/domain once, using the qualified startup ready
   barrier and explicit guardian lifetime exception. Expose outstanding borrowed
   IO uncertainty through shutdown instead of treating logical seal as cleanup.
2. Generalize OutputController to scoped HTTP writer bindings. Preserve its
   Test/BEAM and owned-stdio paths. Do not replace its singleton peer per POST.
   Reserve the complete framed output and its IO liability before handler-state
   commit; publish after commit. Failed post-commit IO settles the original
   invocation, without retries or rollback.
3. Add a root-owned gateway and bounded stream registry. Reuse ingress admission,
   Scheduler, Dispatch, CallbackContext and addressed services. Socket IO remains
   in the borrowed request process. Apply original cutoff/generation/session
   proof immediately before physical handoff; release only authoritative IO
   completion/DOWN. Terminal replies and pre-admission HTTP errors need an
   explicit bounded policy; this core does not implement that policy.
4. Preserve host/origin/body/auth/era validators and wire/storage identifiers.
   Modern POST is stateless and must not add session headers or GET/DELETE.
   Legacy initialization/version, MRTR, replay and GET disconnect remain scoped
   to the authorized session lease. Socket failure cancels only its invocation,
   not stdin, other writers, or a shared session's unrelated work.
5. Static `handler_opts` become one root initialization value. Function/MFA
   request options may supply bounded request/auth context but must not call
   `handler.init` again. An explicit request-context mapper and a compatibility
   error/shim policy need public migration examples before cutover. Mounted
   borrowed hosts and standalone owned listeners need separate lifecycle tests.
   Session/replay streams and modern subscriptions remain separate convergence
   gates. Notification-only 202 ownership must preserve already accepted work.

## Qualification

The tracked, dependency-free runner is `elixir scripts/check_http_writer_core.exs`;
it avoids the global test helper and opens no ports. Focused cases cover actual
blocked `IO.binwrite`, real concurrent producer pressure, a suspended guardian,
producer-to-owner handoff, count/byte/frame edges, root/owner/writer death,
generation retirement, duplicate completion, original deadlines, 140 sequential
connection lifetimes, and same-PID churn with an old wake already queued.
The exact final source passed 26 cases on Elixir 1.17.3/OTP 27.0.1,
1.19.5/OTP 28.4.1 and 1.20.3/OTP 29.0.5, with warning-free standalone compilation
and formatting on each. Actual Mix warnings-as-errors compilation also passed
on minimum/current using separate copied dependency/native sources and builds.
Strict current Credo checked the five new code paths without new filters or
issues. Raw scoped Dialyzer checked the three modules plus Ref/Deadline on
minimum/current without filters. The accompanying immutable manifest records
source and evidence hashes. This evidence does not qualify Bandit/Cowboy socket
integration, session ownership or production HTTP output bounds.
