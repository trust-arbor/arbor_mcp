# Stdio output liability across runtime replacement

This candidate closes a retained-write gap in the v2 stdio edge. Killing the
runtime's Writer during `IO.binwrite/2` did not revoke the borrowed IO device's
request. A fresh runtime previously opened a fresh output ledger and could
submit another frame to that same device. A held fake device reproduced four
retained frames across four supervisor replacements with a one-frame limit.

The runtime now acquires an exclusive output-device lease before constructing
its supervision tree. Configuration, lease acquisition, native construction,
and final readiness use the same original initialization deadline. An active
endpoint returns `:stdio_output_in_use`; a retired endpoint with unresolved IO
waits only until that original cutoff and returns `:stdio_output_timeout`.
Neither case invokes handler initialization or starts the Reader. Normal
successful startup still links the actual Runtime supervisor to its native
caller.

## Ownership and completion

`Stdio.Writer` remains an owned runtime child and proxies the physical write.
A private, unlinked endpoint authority records the lease and the owned physical
sender before allowing any IO. That sender performs the existing
`Arbor.RPC.StdioFraming.write_frame/2` operation. It survives runtime or proxy
death so it can receive the actual borrowed device's IO result.

An authenticated result, followed by actual physical-sender `DOWN`, releases
the write. Runtime, Writer, or caller `DOWN` alone never does. The authority
can terminate its own sender after receiving its actual result; it never kills,
links to, reparents, or adopts the borrowed IO device. A writer timeout may
therefore return while the endpoint retains its physical liability. A later
successful receipt releases that liability, and a waiting fresh runtime may
then start. This proves local IO completion only; it does not prove a remote
peer consumed the frame.

The root ETS table preserves only the opaque stdio lease identity across
Admission replacement. Before new service or execution-cohort children start,
the existing Initialization epoch asks the authority to fence that lease under
its original finite replacement cutoff. Pending physical IO, a published write,
or an unknown authority returns `:stdio_output_unsettled` and aborts the owning
root before fresh handler initialization or a fresh output ledger. The physical
sender and borrowed device remain alive. Completed idle output permits genuine
cohort replacement with the same Runtime reference. Writer payloads also carry
their captured initialization epoch; a cached payload from the old epoch cannot
start IO after that transition. Test/BEAM edge recovery is unaffected.

Sender death without an authenticated result and IO errors fail closed. The
device remains poisoned and no later runtime may use it. Logical local names
are retained alongside the captured device PID, so retargeting a poisoned name
cannot acquire a fresh lease. Device or authority death also fails closed.
Distinct actual devices are independent.

The default authority is outside the Runtime tree and has a retained VM-local
identity anchor. It cannot restart with an empty ledger after losing its state.
There is no reset API: this candidate provides no host proof that would make
such a reset safe. Losing the default authority requires a fresh host VM before
new stdio endpoints can start. Private unnamed authorities exist solely for
isolated fixtures, and a dead private reference never falls back to the default
authority.

## Bounds

The authority admits at most 64 device domains and 64 logical aliases. Each
domain permits at most one physical sender and one unresolved frame. The
endpoint leases its entire configured output budget exclusively, so an old
root's unresolved write prevents a new root from acquiring a fresh queue or
executing a new callback against that device. Within a healthy root, the
existing output ledger still charges prepared, queued, and in-flight output
before state commit. The physical frame, including its newline, must fit both
that endpoint's frame and aggregate byte limits.

The authority has 128 fixed ETS control slots. Supported producers claim a
slot before publishing; the mailbox receives a coalesced wake rather than a
frame payload. Only the currently bound native Writer may publish a frame, and
it has at most one synchronous call outstanding. Published control phases are
monotonic; deadline expiry or caller death abandons a reapable slot without
repeating a completed mutation. Finite waits use temporary aliases and reject
queued success received after the caller's original cutoff.

Idle, proven retired domains remove their monitor, alias, and lease records.
Each domain retains at most one monitor for each of its five roles; a genuine
writer replacement retires its prior monitor before adding the new one, and a
delayed old `DOWN` cannot clear the current writer.
Uncertain domains remain within the fixed 64-domain limit; they cannot be
evicted to admit potentially overlapping IO. All bounds describe supported
library paths, rather than arbitrary raw Erlang messages or effects internal
to a borrowed device.

## Compatibility and remaining gates

Wire encoding, Unicode-mode negotiation, callback scheduling, output-before-
commit, input-first EOF, and the finite Runtime shutdown policy are unchanged.
Supported output addresses are a local live PID, a local registered atom, or
`:stdio`/`:standard_io` resolved to the initiating caller's group leader.
Custom `:via` IO addresses are rejected before handler effects because their
identity and lookup lifetime have not been qualified. A second runtime sharing
one live output device now fails explicitly instead of interleaving writes.

This slice owns only stdio endpoint liability. HTTP writer/gateway domains,
ordinary client worker ownership, session/store convergence, and durable-store
qualification remain separate release gates. The authority's intentionally
conservative poison policy and fixed device limit must remain visible in the
release migration guide.

## Regression evidence

The focused harness includes the retained stdio and initialization suites plus
authority cases for four real supervisor replacements, normal stop with a held
frame, original startup cutoff, independent devices, sender/authority loss,
named retargeting, the 64-domain bound, 128 producers behind a suspended
authority, and queued-success rejection after caller suspension. It uses held
fake IO devices, preserves actual native parent and borrowed-device lifetime
assertions, and does not load repository port cleanup hooks.

Additional cases kill the actual Controller, Scheduler, and Admission while
the borrowed device holds a frame, proving no fresh handler initialization or
output credit. Completed Controller and Admission replacements prove healthy
recovery retains the same logical Runtime reference. A suspended-authority case
proves a published but not yet physical write cannot cross the restart boundary.
