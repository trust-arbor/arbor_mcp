# Shared runtime initialization deadline

This candidate extends the store-cohort watchdog with one shared runtime
startup cutoff and matching readiness barriers. Qualification evidence is
recorded separately; HTTP routing and durable backend guarantees remain gates.

`Runtime.Config` remains the configuration authority. One original
`init_timeout_ms` cutoff covers configuration/startup, owned shutdown-guard and
admission startup, store bindings and listeners, additional owned stores,
execution and callback supervisors, the output controller and ledger, handler
initialization, the protocol edge and the final ready publication. Each native
owner registers before work that can block. Successful constructors check the
same cutoff again before returning. A suspended caller cannot consume a queued
successful startup after that cutoff.

An internal `Initialization` epoch distinguishes initial runtime startup,
store-cohort replacement, execution replacement and Test/BEAM edge replacement. A genuine replacement
starts one fresh budget. Later children and repeated startup attempts join that
budget; they do not reset it. Fixed OTP child specifications therefore carry
logical runtime/configuration information, while the active epoch and deadline
come from the runtime's table. Admission restart preserves the initialization
and proven ownership records needed by its surrounding cohort.

The constructor bridge supports unnamed, local, global and standard `Registry`
via names. A custom via module must declare
`runtime_name_capabilities/0 => %{finite_lookup: 1}`. Its initiating-caller
`whereis_name/1` callback must be pure and finite; native timeout cannot bound an
arbitrary callback before OTP spawns the child. This declaration is a supported
configuration precondition, not certification of a custom registry. Unqualified
custom via modules fail validation before lookup. The child's `register_name/2`
and subsequent initialization are inside the native constructor timeout.

An independent observer is armed before startup effects. It acknowledges proven
owned PIDs before an owner can block on guard registration. It marks the matching
epoch failed and closes admission before terminating only registered owned
processes. A stored proof set survives generation changes until PID retirement;
borrowed services and external mounted HTTP/listener processes never join that
set. Ordinary startup executes under the actual OTP parent. A helper that creates
an owner and transfers its links would not preserve this lifecycle contract.

Admission activation prepares a fresh scheduler generation while keeping the
public route closed. A final readiness barrier publishes only a matching,
unexpired epoch whose required owners completed startup. The root barrier runs
after the edge. An execution barrier runs after handler/output initialization
under `one_for_all`, so a scheduler or output-controller replacement can complete
without restarting a surviving edge. Whole execution-supervisor replacement
waits for the following edge and root barrier. A Test/BEAM edge-only replacement
keeps the healthy handler state, callback owner, runtime reference and scheduler
generation; it starts one fresh edge cutoff, retires dead-edge reservations and
old peer output scopes, then republishes the retained route after the root
barrier. An uncertain stdio writer/edge replacement is separately qualified and
may fail-stop instead. Healthy Test/BEAM disconnect/reconnect semantics remain.
Pending and failed epochs cannot reopen
old output scopes. The publication checks the original cutoff inside the
admission owner, and returning callers check it again.

## Additional owned children

Version 2 replaces opaque generic `store_children` specifications with validated
owned descriptors. The intended configuration is:

```elixir
store_children: [
  [adapter: MyStore, options: [ttl_ms: 60_000], id: :my_store]
]
```

The module declares `bounded_startup: 1`, implements `start_link/1`, calls
`ServiceAdapter.watch_owned/1` before initialization can block, passes those
runtime options to any additional owned children, and supplies the remaining
finite timeout to its OTP constructor. Supervisor adapters call
`ServiceAdapter.start_supervisor(__MODULE__, opts)` because Elixir
`Supervisor.start_link/3` forwards only names and ignores timeout options.
The helper uses OTP's native `:supervisor` GenServer callback protocol with the
actual initiating parent; it preserves `proc_lib` identity, links and ordinary
supervisor child behavior. It starts inside `StoreSupervisor` before
execution and follows the store cohort's failure boundary. Module declarations
and child-spec construction must be side-effect-free; arbitrary unregistered
work is outside the owned lifecycle contract.

The initiating process temporarily traps exits only across the
native constructor and original-cutoff result cleanup. This lets a timeout
observer kill an owned startup supervisor without killing its non-trapping
caller before the native handshake can return the explicit timeout. The prior
exit mode is restored on every path. Late successful ownership is unlinked and
its queued EXIT is flushed before forced cleanup. Originally trapping callers
retain unrelated EXIT messages; originally non-trapping callers still terminate
on unrelated abnormal link exits, after constructor cleanup, and ignore normal
link exits. No temporary process becomes the supervisor's parent.

An old configuration such as `store_children: [{MyStore, some_argument}]` must
move its arguments into the descriptor's keyword options and adopt the early
registration contract. Arbitrary MFA/map/argument shapes are rejected during
configuration validation, before supported startup effects. This is a deliberate
nonsymbol configuration change for the major release; standalone child APIs are
not implicitly removed.

## Verification and remaining boundaries

The focused regressions cover combined service-plus-handler cutoff, blocked guard and
admission startup, delayed edge startup, late queued success after caller
suspension, a genuinely fresh replacement budget shared by its following
children, execution-only recovery without stale output delivery, sibling
isolation, borrowed survival, and retirement of failed startup observers and
owned processes. They retain the original edge-recovery characterization and
also prove a prepared old-peer proposal cannot publish or change retained
handler state after recovery. A non-trapping caller receives an explicit timeout
for late queued successful startup: only that newly returned owned root is
unlinked before forced cleanup. Ordinary successful startup links are preserved.
Native blocked via registration is also tested before runtime initialization,
with a non-trapping caller and no orphan or late startup reply. Named and unnamed
runtimes started by real OTP parents retain supervisor identity and links.
Original cohort tests remain part of qualification.

The observer keeps a current PID-to-monitor map and removes retired PIDs. ETS
ownership proofs survive Admission reset but retire on the shutdown guard's
monitor notifications. Each replacement removes prior epoch completion records;
old epoch aborts and readiness messages cannot affect a newer cohort. The
pre-publication observer gap has both a root monitor and a finite original-cutoff
path even when its ETS context has not yet been inserted.

A genuine store or execution replacement establishes its new initialization
cutoff when new startup begins. Prior owners' termination has the separately
configured OTP/owned shutdown policy; this cutoff does not retrospectively
include an earlier teardown phase. Handler state reinitializes on store/execution
replacement or whole-runtime replacement, while Test/BEAM edge-only replacement
retains it.

HTTP initialization-claim lifetime remains a later integration decision: its
finite service-operation wait must be distinguished from a claim lifetime
bounded by the original request invocation. No caller may extend that proof
arbitrarily. Normal lifetime shutdown-control budgets and durable backend hooks
also retain their separately recorded qualification gates.
