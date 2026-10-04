# Ordinary Client lifetime and connection events

This isolated slice builds on `f4d85342ba53e58f3d67ab12294a4eb0b87392fc`
and the exact, separately frozen thirteen-file scoped connection helper. It
changes ordinary Client ownership; the explicit connection bracket keeps its
native construction guardian and inline close-callback contract.

## Native topology

`Client.start_link/1` still starts the native GenServer under its original caller.
Its parent, links and ancestors are not replaced by a supervisor or bracket.
Before transport construction, Client installs a private bounded Lifetime
observer. The observer monitors Client and its original parent; a constant
independent owner watchdog bounds blocked construction even when the observer
is suspended. Native parent termination normally retains its original exit
reason. Forced termination after an exhausted cleanup budget is explicit.

Each library worker reserves a slot before construction and registers before
callback or network effects. Registration validates the private nonce, actual
worker identity and generation. An independent worker watchdog is armed before
the registration ACK. Owner, creator or observer death stops that known worker,
including callbacks that trap exits. Arbitrary returned PIDs, servers, socket
listeners, borrowed devices and HTTP pools are never adopted.

The managed paths include reverse requests, MRTR fulfillment and concurrent
inputs, resource subscription replacement, receiver work, discovery receive
fallback, DNS work, legacy POST workers and modern/SSE HTTP actors. Scoped helper
hooks compose beneath this mechanism rather than replacing it.

## Bounds and shutdown results

| Option | Default | Accepted values |
| --- | --- | --- |
| `max_client_workers` | 256 | integers 1–4096 |
| `client_cleanup_timeout` | 1000 ms | integers 1–4294967295 |

Workers plus pending construction reservations share the configured cap. One
extra reserved cleanup-worker slot permits shutdown when the normal cap is full.
Each active worker has fixed monitor/watchdog metadata; Client also has one
observer and one independent owner watchdog. Construction reservations expire
within one second. There is no permanent generation tombstone or PID index.
Effect-free rejection tasks and OTP Task implementation processes are transient;
this is not a hard bound on every process or native mailbox allocation.

`disconnect/1` and `stop/2` capture one cleanup cutoff before waiting for Client.
The observer retires admission independently of Client's mailbox. Stream stops,
receiver/callback cleanup, transport close and remote best-effort session DELETE
share the remaining budget. Actual worker DOWN is required for a confirmed local
success. The operation returns a cleanup error for exhausted or unconfirmed
cleanup; no stage receives a fresh cleanup timeout. Repeated disconnect retains
a known failure until a successful new connection.

A failed legacy SSE endpoint handshake also stops its registered actor under
a finite cleanup cutoff. An unresponsive actor returns the original typed
`{:cleanup_failed, reason, {:error, cleanup_reason}}` through Client startup;
the endpoint error cannot overwrite a known cleanup failure.

Ordinary custom transport `close/1` now runs in a registered cleanup worker,
which may be forcibly stopped after the original cutoff. Its `self()` is not the
native Client. The transport state still belongs to the connected native owner.
The explicit scoped helper retains inline `close/1` in Client, as qualified by
its existing tests. Custom transport effects that deliberately create unregistered
children remain outside this ownership proof.

An observer failure fail-stops the native Client and its known workers. This
retains native link behavior: a linked caller observes an abnormal Client exit.
A cleanup timeout does not imply remote rollback, confirmed OS child reaping,
or completed work on a borrowed network peer. RPC typed Guardian receipts remain
the authority for native child cleanup; Client/Actor DOWN alone is insufficient.
Direct raw `GenServer.stop/3` cannot report a transport's terminate-time result.

## Connection and resource state

Retirement clears reverse task, MRTR task and legacy POST task maps before a new
connection is opened. Pending MRTR callers settle with `:client_disconnected`.
Completions authenticate captured generation and exact tracked worker PID/ref;
old results cannot update a reconnected handler or its pending request state.
An actual connection opening installs a fresh epoch after confirmed retirement.

An acknowledged internal resource Subscription transfers from its short-lived
opening worker into Client-owned logical lifetime. The transfer is explicit and
bounded by the same worker cap; it happens before the opening worker can return.
That logical actor survives transport loss to resubscribe, while opening and
replacement workers are retired. Explicit disconnect, stop and owner death stop
both. Reconnection does not adopt arbitrary externally supplied subscription PIDs.

## Test/BEAM event-context overlay

Native Test/BEAM connections pass a private optional event context once through
transport connect, HandlerServer connection admission and the existing output
peer context. Its owner must equal both peer and connection caller. The context
has constant metadata and does not create relay processes or per-output rows.

Controller replies and direct server transport controls carry an internal
lifetime envelope. Native Client accepts only its active epoch; handshake reads
filter old envelopes under their original absolute deadline. Already-enqueued
old controls therefore cannot execute against a new handler generation. Raw
non-Client process peers keep their existing two-element transport tuple.
Wire JSON, protocol IDs and stored identifiers are unchanged.

## Qualification and limits

The source manifest identifies the exact base, scoped prerequisite, ordinary
lifetime overlay and separate connection event-context hunks. Real tests cover
held reverse/MRTR descendants, blocked construction with suspended observer,
creator handoff, parent-exit reasons, bounded close admission, old queued
completions, suspended modern HTTP actors, held legacy POST requests and actual
Test/BEAM reconnect with an already-enqueued old server control. Retained scope,
typed stdio, protocol-era and HTTP security tests are run on both toolchains.

The exact final combination passes 201 affected standalone cases on Elixir
1.19.5/OTP 28.4.1 and Elixir 1.17.3/OTP 27.0.1. This includes 23 new lifecycle
and peer-generation cases. The preceding native/scoped affected selection
passes 229 cases on each toolchain; its last narrow change is typed failed-SSE
startup cleanup. Production compilation treats warnings as errors, both
formatters pass, strict Credo reports no issues, and minimum Dialyzer adds no
warnings to its existing filter set.

The private base's full default selections each execute 4904 tests, 20 doctests
and 34 properties. Both retain two inherited obsolete `Content.Builders` media
placeholder failures; canonical commit `f166` already retired those fixtures.
There are 207 default exclusions. Those runs establish the classification of
the private base, and do not claim the eventual canonical combination is green.

Raw same-VM sends, kernel/socket/Port buffers, OS cleanup and remote request
outcomes have separate limits. Cleanup does not undo a callback already accepted
by a borrowed server. Physical network and same-runner pressure qualification
remain part of release qualification; these tests establish lifecycle behavior,
not a hard whole-VM RSS or mailbox cap.
