# HTTP writer installation and authenticated lifetime

This private prerequisite installs the borrowed-writer core in Runtime. Its
source base is `12b523f2ff91ac6279fa4c2a2f45f6d878d66e8f` plus the captured
startup, stdio, initialization-claim and native-RPC overlays; the prerequisite
manifest records their exact hashes. It does not route HttpPlug, Gateway or
OutputController through HTTP writer bindings. Existing HTTP paths therefore
do not gain shared Scheduler state or production output bounds from this slice.

## Owned proxy and retained IO

Runtime starts `HTTPWriterProxy` before Admission. The proxy uses the original
Initialization epoch/cutoff and early-watch barrier, then retains one opaque
writer domain in root-owned ETS. Admission cleanup preserves the domain/proxy
records. Proxy, Admission and Execution replacement reuse the domain; they do
not allocate another IO budget. Old generation or owner proofs fail closed.

The unlinked guardian monitors the root. It is deliberately excluded from
ordinary forced-child shutdown provenance: killing it while a borrowed socket
is blocked would erase a physical IO liability. Root stop logically seals
bindings, releases hidden/queued output and stops owned children. A checked-out
ticket stays charged until the actual writer returns from IO or its monitored
process dies, even after root ETS is gone. Completion uses its retained receipt
and domain, so it can settle afterward. A sealed, settled guardian exits after
its finite idle interval. Unexpected guardian death poisons the retained domain
and cannot create replacement credits.

`Runtime.stop/2` now returns `:ok | {:error, term()}`. Successful owned shutdown
with outstanding borrowed IO returns `{:error, {:http_io_unsettled, count,
bytes}}`; loss of the guardian without a normal settled receipt returns
`{:error, :http_io_cleanup_unconfirmed}`. A logical seal alone never reports
physical completion. Runtime does not kill the socket writer or its host
listener. These are per-root limits; separate roots have separate domains.

## Captured invocation and session authority

All interfaces below are internal. An HTTP entry must call
`HTTPWriterProxy.capture(runtime_ref, opts \\ [])` once in the actual Plug/socket
process, before body reads, authentication and era validation. The facade
captures one monotonic entry cutoff, bounded by root `request_timeout_ms`.
Optional `:timeout` and `:deadline` only shorten it; duplicate, unknown, improper
and out-of-range options fail with a fixed error. A gateway must retain this
binding through the request; recapturing after body/auth work would refresh the
budget and is prohibited by the integration contract.

The installed factory derives the actual writer PID, current proxy owner,
runtime generation, fresh invocation/scope and original cutoff. Raw core
`register/4` remains available for generic accounting tests but cannot
authenticate a ServiceInvocation. A matching opaque Runtime.Ref, installed
domain/proxy, live writer, current generation, original cutoff and retained
phase are checked on validation, preparation, publication and physical
checkout. This is library provenance within one trusted BEAM VM, not a sandbox
against arbitrary application code altering public ETS or invoking private APIs.

| Private interface | Contract |
| --- | --- |
| `HTTPWriterProxy.domain(runtime)` / `active_proxy(runtime)` | Recover the installed domain/current proxy, without allocating credits. |
| `HTTPWriterBinding.validate(binding, runtime)` | `{:ok, snapshot}` with matching runtime, actual socket owner, deadline, scope, generation, invocation and lease; otherwise a fixed closed error. |
| `HTTPWriterRegistry.bind_lease(binding, lease)` | Actual socket only, once before work binding; require the matching addressed session service/runtime. |
| `HTTPWriterRegistry.bind_work(binding, token)` | Actual socket only, once; require current scalar Admission token, matching proxy owner/scope/generation/output phase. Cancellation, failure or retirement revokes authority. |
| `HTTPWriterRegistry.cleanup_status(domain)` | Distinguish settled IO, retained count/byte liabilities and unavailable cleanup. |
| `SessionManager.claim_initialization(service, lease, invocation: binding)` | Accept only this installed, session-bound entry proof and the actual socket caller. Existing non-HTTP callback/default behavior is unchanged. |

HTTP claims retain the original invocation cutoff independently from the short
service RPC wait. The operation wait is still bounded by its own configured
limit and by the entry cutoff. Explicit caller deadlines only shorten both.
The model revalidates runtime, owner, current session lease/epoch and invocation
proof before claiming and before completing initialization. A different session,
another runtime or a recreated session ID cannot reuse the old claim. Existing
capability-based claim completion may run in a different completing worker;
that worker cannot invent an entry origin.

`bind_work/2` deliberately rejects `batch?` reservations in this installation
slice. A legacy member's successful output phase cannot authorize a failed
aggregate after phase promotion. Legacy batch HTTP remains a required full-v2
Gateway/Controller gate: every member must retain work capacity, outputs must
prepare before state commit, and an atomic final array outcome must authorize
physical publication. Modern array rejection and existing legacy behavior are
unchanged because no HTTP routing is switched here.

## Bounds and accounting

Runtime validates these new options as positive integers at most `0xFFFFFFFF`.

| Runtime option | Default |
| --- | ---: |
| `max_http_writers` | 128 |
| `max_http_writer_metadata_bytes` | 65,536 |
| `max_http_io_frames` | 128 |
| `max_http_io_bytes` | 4,194,304 |
| `max_http_io_frame_bytes` | 1,048,576 |

The IO frame limit includes JSON/SSE framing bytes. Candidate, prepared,
handed-off, queued and in-flight tickets share the IO count/byte cap. One physical
frame can be in flight per writer. Metadata is independently charged and
bounded; binding mutations recalculate its serialized charge before retention.
The accounting core keeps its existing bounded CAS/reaper and coalesced wake
protocol, including one outstanding acknowledged nonce per writer across
sequential bindings. Retirement cannot silently clear an unconsumed wake.

The IO budget is separate from primary OutputLedger capacity. Defaults permit
up to 4 MiB of primary output credits plus 4 MiB of HTTP IO credits and 64 KiB
of writer metadata. These serialized-data/accounting bounds do not bound total
BEAM heap, transient producer/whole-row CAS copies, socket buffers or arbitrary
host memory. Same-runner throughput and pressure qualification remain required.

## Qualification and next integration

The tracked installation runner loads the independently compiled project from
`ARBOR_V2_BUILD`, starts only telemetry/crypto and runs the unchanged 26 core
cases plus 15 installation cases. It does not use the global test helper,
listeners or Ports. Actual blocked `IO.binwrite` is exercised with a private
fake IO device: Runtime.stop reports unsettled credit, the socket survives,
root ETS disappears, and only the real write return permits final reclamation.
Other cases cover root/proxy/Admission replacement, guardian loss, forged/raw
origins, one-time work/lease binding, canceled tokens, session/runtime/epoch
mismatch, original HTTP/service cutoffs, suspended service mutation and batch
authority rejection. With local source dependencies compiled independently:

| Gate | Elixir 1.17.3 / OTP 27.0.1 | Elixir 1.19.5 / OTP 28.4.1 |
| --- | --- | --- |
| `mix compile --warnings-as-errors` | Pass | Pass |
| `elixir scripts/check_http_writer_installation.exs` | 41 cases, zero failures | 41 cases, zero failures |
| Same runner with `--retained` | 84 runtime/claim/deadline/startup cases, zero failures | 84 cases, zero failures |
| Formatting of the 11 owned code paths | Pass | Pass |
| Raw project Dialyzer: owned module findings | Zero | Zero |

Current strict Credo checked those 11 paths with zero issues and no new filters.
Elixir 1.20.3/OTP 29.0.5 compiled the exact ten owned/prerequisite library modules
with zero compiler diagnostics, passed 41 focused cases, and passed formatting.
That newest source proof loads previously current-compiled dependency and other
prerequisite beams; it is not a full newest Mix/dependency qualification.

The raw Dialyzer audit used independently retained dependency PLTs, checked all
project beams without filters, and found 78 minimum / 84 current project
warnings. None refer to Runtime, Config, Initialization, the writer modules,
ServiceOperation, ServiceInvocation or the affected RuntimeStore. The raw
counts are not claimed to be the normal project graph's existing warning count
or a clean whole-project gate; canonical full-graph CI remains necessary. Exact
source/evidence hashes are recorded in the handoff manifest. These pure fixtures
do not qualify Bandit/Cowboy socket IO.

The next slice must mount an owned gateway, preserve entry capture before
validators, generalize Controller to multiple scoped writers without replacing
its Test/BEAM/stdio singleton per POST, and reserve complete response IO before
handler state commit. Terminal/pre-admission errors need bounded admission too.
Physical ACK must follow the actual `send_resp`/`chunk` return; post-commit IO
failure settles the original invocation without retry or rollback. Preserve
modern stateless POST semantics and legacy initialization/version, MRTR, replay,
GET disconnect and authorized session leases. Notification-only 202 must retain
already accepted work. Socket failure affects only its own invocation.

Static handler options initialize one runtime state once. Function/MFA request
options may provide bounded request/auth context and must not initialize a new
handler per POST. Public mounted-host versus owned-listener lifecycle, request
context migration examples, session/replay streams and modern subscriptions
remain required convergence work. This slice completes installation/provenance,
not the HTTP runtime cutover.
