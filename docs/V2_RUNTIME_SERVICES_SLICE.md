# Runtime-owned services: first v2 slice

This slice gives Runtime-backed Test/BEAM servers their own Tasks store and
modern Subscriptions domain. Replay protection remains opt in. `Runtime.Config`
validates the configuration before the runtime starts; there is no second server
configuration authority.

## Configuration and references

The default is equivalent to:

```elixir
services: [tasks: [], subscriptions: [], replay_cache: nil]
```

An empty descriptor selects an unnamed owned built-in service. `nil` or `false`
disables that service. Adapter options go inside the descriptor:

```elixir
services: [
  tasks: [options: [max_tasks: 5_000]],
  subscriptions: [options: [max_queue: 32, max_lifetime_ms: 60_000]],
  replay_cache: []
]
```

`Runtime.service(server, :tasks | :subscriptions | :replay_cache)` returns an
opaque `ServiceRef`. Each operation resolves the current service generation.
The reference follows service/execution child restarts, but cannot follow a
replacement of the entire runtime. Unavailable explicit references fail closed;
they never select an application singleton. A disabled kind returns
`:service_not_configured`; a configured service temporarily restarting returns
`:service_unavailable`.

Callbacks automatically use their runtime's Tasks, Subscriptions and configured
Replay service. Runtime addresses override legacy handler task-store addresses.
Workers capture the logical service and authorization owner before spawning:

```elixir
{:ok, service} = Runtime.service(:tasks)
owner = Tasks.owner()
# Pass these values to the host's supervised task worker.
Tasks.complete(task_id, result, service: service, owner: owner)
```

`Runtime.service/1` returns `:no_runtime_context` outside callback work. Callback
context is not inherited by spawned processes. Callers that already hold a
runtime can use `runtime: runtime` directly on Tasks or Subscriptions operations;
an explicit logical service uses `service: service`. Replay uses
`ReplayCache.consume(service, token_id, expires_at)`.

Tasks workers need both the captured service and owner. Retaining the owner alone
does not identify a runtime. The wire task ID remains unchanged and contains no
runtime PID, generation or namespace.

## Owned and borrowed descriptors

Owned descriptors accept `ownership: :owned`, `adapter: module` and
`options: keyword`. They reject address/namespace overrides. Owned adapters
declare `runtime_service_capabilities/0` with `%{bounded_startup: 1}`, implement
their service's operation callbacks, and implement `start_link/1` with a finite
OTP startup timeout from `:init_timeout_ms`. Their owner must call
`ServiceAdapter.watch_owned(opts)` before initialization can block. This registers
it with the shutdown guard before `start_link/1` returns. Detached descendants
are unsupported; additional owned descendants must be explicitly registered.

Borrowed descriptors require `ownership: :borrowed`, `adapter: module`, a live
local process address in `server:`, and a stable nonempty binary `namespace:` of
at most 256 bytes. `persistence_key:` on the runtime can supply the namespace
when the descriptor omits it. The borrowed adapter must explicitly declare
`%{namespace: 1}` and apply the namespace to **every** service operation:

```elixir
services: [tasks: [
  ownership: :borrowed,
  adapter: MyNamespacedTaskStore,
  server: MySharedDatabaseOwner,
  namespace: "deployment/endpoint-a"
]]
```

Borrowed backends are monitored and never stopped by Runtime. Borrowed service
loss fails the service cohort closed; restart can resolve a replacement through
an explicit registered address. A PID descriptor identifies that exact process.
Separate logical endpoints must use separate stable namespaces. A shared
namespace deliberately shares the logical data domain across runtime replacement.
Use durable application identities for namespace and Tasks owner fields such as
audience; PIDs, references and runtime generations are not durable keys.

The existing unnamed Task ETS, Replay ETS and Subscriptions implementations do
not declare namespaced operations and cannot be borrowed. Supplying a namespace
string cannot retrofit isolation onto their unnamespaced operations. Capability
declarations are trusted adapter contracts, not certification of third-party
backend implementations.

Names, server addresses, namespace, listener supervisor and runtime startup
metadata are reserved adapter options. Put a borrowed address/namespace on the
descriptor rather than hiding it inside `options:`. Duplicate/unknown descriptor
keys and unknown service kinds are rejected.

Raw Runtime startup `subscription_registry:` fails with
`{:subscription_registry_requires_service_descriptor,
:configure_owned_subscriptions_or_namespaced_borrowed_service}`. Use an owned
Subscriptions descriptor or an explicitly namespace-aware borrowed adapter.
Raw startup `replay_cache:` fails with `:replay_cache_requires_service_descriptor`.
Use `services: [replay_cache: ...]`; `require_replay_protection: true` also requires
that service to be enabled.

## Lifecycle and effects

Child order is Admission, the service StoreSupervisor, generic owned
`store_children`, the ExecutionSupervisor and the protocol edge. StoreSupervisor
contains Tasks, optional Replay and owned Subscriptions/listener supervision.
It is fail-stop: permanent service failure stops the cohort so the Runtime's
`rest_for_one` boundary also replaces execution and the edge. Old invocation
completions cannot commit to the replacement execution generation. A sibling
runtime keeps its own services and work.

Service operations from a callback preflight the active generation, owner,
deadline and cancellation state. This prevents already retired invocations from
starting new service effects. An accepted store mutation is a separate backend
commit; cancellation or a later delivery failure does not roll it back. Outside
callback work, a captured service intentionally remains usable by authorized
durable task workers until the runtime ends.

Owned startup uses one service-cohort initialization deadline. Already started
and initializing service owners are covered by the runtime shutdown guard.
Shutdown retains the total runtime deadline; forced cleanup can interrupt store
termination/persistence hooks. It does not promise durability of ETS, successful
backend close hooks or cleanup of arbitrary detached processes. Borrowed owners
remain alive on runtime shutdown.

## Scope and remaining release gates

This slice does not cut over HttpPlug, legacy SessionManager, HTTP session or
resource-subscription globals. Those still require addressed multi-session
runtime admission, owners, reply sinks and stable-key session/store operations.
Standalone Tasks/Subscriptions facades outside Runtime retain their legacy
application-default paths for that transition; an explicit runtime never falls
back to them.

Tasks notification routing now selects the matching runtime subscription domain.
The asynchronous publication hop itself is not yet protected by the new output
ledger, so this slice does not claim bounded notification producer ingress.
Retained Tasks/Replay byte budgets, DETS lifecycle and durable replay cursor
qualification remain release gates. Batch member counting and custom-call caller
identity are separate slices; this patch does not alter either contract.

Regression coverage includes equal task/token IDs across siblings, Test/BEAM
callback injection, task authorization and publication domain matching, disabled
and stale explicit references, service cohort failure and stale completions,
logical replacement, borrowed data/owner survival, borrowed loss, blocked/failed
startup cleanup and blocked owned termination within the total shutdown budget.
