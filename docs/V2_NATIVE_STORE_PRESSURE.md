# Native store and retained payload bounds

This v2 candidate reserves native Tasks and replay operations through the same
private operation ledger used by addressed session services. Full operation data
is retained only after count and byte admission; the owner receives a coalesced
wake. A suspended or busy owner does not admit an unbounded payload mailbox.
Operations preserve one finite cutoff, caller alias, owner and monotonic phase.
Immediately before mutation, runtime operations recheck service generation,
request origin, current batch member/output phase and original deadline. An
operation queued by a callback cannot newly commit after that callback's
invocation expires or retires. A commit completed before the cutoff remains
committed if a caller later times out; timeout is not rollback.

Native `Tasks.Store.ETS` and `Server.ReplayCache.ETS` preserve their existing
standalone operation arities and result shapes. Native operations now use finite
admission defaults, including outside Runtime:

| Option | Default | Meaning |
| --- | ---: | --- |
| `max_operations` | 64 | Concurrent retained operation claims. |
| `max_operation_bytes` | 1,000,000 | Aggregate retained operation data and metadata. |
| `max_operation_payload_bytes` | 65,536 | One operation's retained charge. |
| `operation_timeout_ms` | 1,000 | Maximum synchronous operation wait. A call's `timeout:` may shorten it. |
| Tasks `max_tasks` | 10,000 | Retained task entries. |
| Tasks `max_entry_bytes` | 1,000,000 | One full task entry, including owner, inputs, result and metadata. |
| Tasks `max_retained_bytes` | 8,000,000 | Aggregate task entries. |
| Tasks `max_ttl_ms` | 2,592,000,000 | Maximum task TTL (30 days). |
| Replay `max_replay_entries` | 10,000 | Retained consumed identifiers. |
| Replay `max_replay_bytes` | 8,000,000 | Aggregate consumed identifiers and expiry values. |
| Replay `max_replay_id_bytes` | 4,096 | One continuation identifier. |
| Replay `max_replay_ttl_ms` | 2,592,000,000 | Maximum future expiry interval (30 days). |

Capacity is explicit: operations can return `:operation_capacity_exhausted`,
`:operation_payload_too_large`, `:operation_contention` or `:operation_timeout`.
Task retained exhaustion returns `:store_full` without changing the previous
committed lifecycle. Replay exhaustion returns `:replay_cache_full`; previously
consumed identifiers remain consumed. Invalid identifier/expiry limits return
`:invalid_replay_id` / `:invalid_replay_expiry`. Idle expiry reclaims native task
and replay retention without waiting for another public operation. The idle reaper removes at most 32 expired entries and checks a 5 ms cutoff
between entries; an operation also removes its own expired identifier before lookup. Expiry
index and map overhead are bounded by the configured entry count, while payload
counters measure retained serialized data rather than allocator overhead.
These cooperative checks do not provide CPU preemption or an absolute VM RSS cap. Native ETS
addresses are local; remote or retired native owners fail unavailable.

Generic standalone custom Task store adapters keep their existing callbacks and
options. When selected as a Runtime Tasks/replay descriptor, an adapter must now
explicitly declare `bounded_operations: 1` and implement
`runtime_service_binding/2` plus `operate/4`. Startup rejects an adapter lacking
that contract with `{:invalid_service, kind, :bounded_operations_required}`.
The adapter owns its bounded pre-mailbox admission and must revalidate the
supplied operation context immediately before mutation; supplying a namespace or
checking it only in the caller is insufficient. Existing borrowed namespaces,
logical ServiceRefs and borrowed shutdown ownership remain unchanged. A custom
adapter's arbitrary effects are not made reversible by this interface.

Managed input/control/scope metadata, prepared output and addressed store data
are materialized after their size checks and before retention. This detaches
ordinary subbinary/bitstring backing while preserving structs, tuples, improper
lists and native PID/reference/port identities. Host functions retain their
original identity; captured backing bytes that cannot be detached safely are
charged to the managed budget and can cause rejection. Newly admitted function
closures must fit these limits. Static handler/configuration closures and
borrowed native handle bodies remain host-managed state; these counters do not
claim an absolute VM RSS or arbitrary native resource bound.

Legacy DETS store instances now use four reference table names instead of atoms
created on each open. The existing files, wire identifiers, all-four-table
persistence, exclusive storage path and sync-before-success behavior remain.
This removes permanent atom growth across reopen. Runtime durable session
backends remain explicitly unqualified: bounded filesystem open/repair/sync/
close, failure reporting, durable isolation and cleanup need separate evidence.
Standalone legacy DETS support is retained during that transition.


## Reproduce the default-limit measurement

Run the supporting probe in its own fresh VM:

```sh
MIX_ENV=test mix run --no-start scripts/measure_native_store.exs
```

The probe starts four private unnamed owners, uses the public Tasks/Replay
operations, submits a 2x nominal count/byte wave and then an additional 8x wave
(10x total submissions), and asserts positive admission, explicit capacity
rejection, unchanged retained plateaus and drained operation credits. Production
limits are unchanged. Tasks uses its supported supplied clock only to advance
idle expiry; replay identifiers expire through actual wall time. All four owners
are stopped and confirmed dead. The default JSON report is
`tmp/native-store-default-measurement.json`; set `ARBOR_STORE_MEASUREMENT_REPORT`
to choose its destination.

The integrated minimum/current measurements both reach these same plateaus:

| Case | Entries after either wave | Retained bytes after either wave |
| --- | ---: | ---: |
| Tasks, small inputs/count pressure | 10,000 | 6,029,235 |
| Tasks, 32 KiB inputs/byte pressure | 239 | 7,974,713 |
| Replay, small identifiers/count pressure | 10,000 | 198,894 |
| Replay, 4,000-byte identifiers/byte pressure | 1,993 | 7,997,909 |

Idle expiry returns every count, retained-byte counter, expiry index and operation
credit to zero. Reports also sample owner heap, mailbox, binary references and
owned ETS, plus whole-VM binary/ETS/total memory, process count and the VM's own
OS RSS after garbage collection. These are supporting steady samples, not
transient peak measurements or a fixed VM/RSS guarantee. Exact payload charges
can change with documented task shapes; the asserted production limits remain
the contract.
