# Test and BEAM handler runtime migration

This implemented slice routes `HandlerServer` and the DSL's `:test` / `:beam`
transports through the common runtime. Stdio, HTTP, public store ownership and
the complete cross-transport matrix remain required v2 work. The full accepted
design is [V2_RUNTIME_CONTRACT.md](./V2_RUNTIME_CONTRACT.md).

## Startup and custom callbacks

`HandlerServer.start_link/1` now returns the runtime supervisor. The DSL's child
specification is a supervisor specification too. Existing client startup keeps
using `server: root`; public server helpers accept the root, its registered name
or `Runtime.ref(root)`.

```elixir
{:ok, root} = Arbor.MCP.Server.HandlerServer.start_link(
  handler: MyHandler,
  transport: :beam
)
{:ok, runtime} = Arbor.MCP.Server.Runtime.ref(root)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: runtime)

# Before: GenServer.call(server, :read)
Arbor.MCP.Server.call(runtime, :read)
Arbor.MCP.Server.cast(runtime, {:add, 1})
```

Custom calls return `{:reply, reply, state}`; custom casts return
`{:noreply, state}`. Deferred `GenServer.reply`, stop and continuation forms are
not supported by scheduled handler work. If a handler uses the default
`use Arbor.MCP.Server.Handler` call implementation, override that implementation
before defining custom call clauses (`defoverridable handle_call: 3`).

`Runtime.edge/1` explicitly resolves the protocol edge for direct edge controls
or diagnostics. Direct `GenServer` calls and arbitrary Erlang sends bypass the
supported ingress boundary. The root's `:sys.get_state` is supervisor state;
the edge contains protocol state, not handler state.

## Callback and cancellation behavior

The scheduler owns handler `init/1`, committed state and `terminate/2`. Each
callback executes in a supervised task. `self()` inside a callback identifies
that task, so callback-created private ETS tables and linked children inherit
the task's lifetime. Private ETS created in `init/1` belongs to the scheduler,
so callback tasks cannot read it; protected ETS cannot be written by those tasks.
Prefer explicit handler state or an owned process for long-lived state, or public
ETS when its access semantics are appropriate. Stateful work is serialized; stateless concurrent
work must explicitly configure `execution: :stateless` and cannot change state.

Use `Arbor.MCP.Server.Context.cancelled?/0` inside the active callback. The signal
is scoped to runtime, connection/session, direction and invocation token.
Cancellation can reach accepted work while the protocol edge is suspended,
prevents that invocation's state commit and kills an unresponsive callback after
the configured grace period. Unknown wire IDs allocate no cancellation tombstone.
The default cancellation tracker stores `{scope, request_id}` in handler state
after cancelled work finishes; custom trackers can read the active
`Arbor.MCP.Server.Context.scope/0`. Treat its value as an opaque identity; it
returns `nil` outside runtime callback work.

Test and BEAM currently serve one peer per runtime. Connecting a replacement
peer retires the old connection and permits wire-ID reuse. Retired completions,
subscription events and callback-originated reverse requests, notifications and
cancel controls cannot reach the new peer. The handler's committed state remains
owned by the same runtime. An edge restart preserves the runtime reference and
committed state; a scheduler restart reinitializes the handler and invalidates
the old generation's completions.

## Admission and deadlines

Supported Test/Local ingress and public Server helpers reserve serialized input
bytes and count before placing payloads in ETS. The protocol edge receives one
coalesced wake and checks out bounded payloads from ETS. Data envelopes share
`max_concurrency + max_queue` slots and `max_pending_bytes`. Each legacy batch is
one envelope with one absolute deadline; its entries remain ahead of later RPC,
custom-call and custom-cast envelopes. Reverse controls bypass the batch barrier.

Reservation candidates and confirmed work share the same atomic byte ledger.
Batch wire-ID metadata stays in bounded ETS candidates; the admission owner's
mailbox receives a token-only confirmation. A producer killed before confirmation
leaves a reapable token claim, and runtime generation changes clear stale claims.
Already admitted callback controls retain their origin's terminal outcome while
they hold a control slot: normal completion permits delivery; cancellation,
deadline, owner death and retired connection scope invalidate delivery.

Outgoing helper controls and incoming reverse responses each have independent
`max_control_queue` count and `max_control_bytes` budgets. The aggregate control
bound is **2 × each configured control limit**, in addition to data admission.
A reverse request retains its outgoing credit until reply or expiry, while its
response can use the independently bounded incoming lane. Count or byte pressure
returns `{:error, :server_busy}`; Test/Local wrap it as a transport error.

These bounds cover supported input/context payload admission, not arbitrary
Erlang sends, process-memory overhead, handler state, arbitrary callback output
or a batch's accumulated responses. Output and aggregate-batch pressure still
need explicit qualification before v2 is release-ready.

`Runtime.request/3` uses a temporary process alias. A caller `await_timeout` stops
waiting and discards late replies; accepted work continues. The server's absolute
deadline starts at acceptance and includes time before edge processing and in
the callback queue. Expired native subscriptions cannot create listeners.

Runtime shutdown uses an overall finite budget and forced cleanup of explicitly
registered descendants. Forced cleanup can interrupt termination/persistence
hooks. A parent supervisor still applies its restart policy; remove a managed
endpoint with `Supervisor.terminate_child(parent, id)` when it must remain stopped.

## Qualification evidence

The focused runtime, handler-edge and subscription suite covers pre-edge count
and byte pressure, queued-ID cancellation, single-slot reverse control pressure,
held-batch ordering, queued subscription expiry, stale subscription delivery,
old callback controls, state commits after owner death, edge/root lifecycle and
two-runtime isolation. Retained context, cancellation, DSL, client/BEAM, protocol
era and legacy batch suites also run against this implementation. Release-wide
pressure/default, store-recovery and cross-transport evidence remain separate
gates in [V2_RELEASE_PLAN.md](./V2_RELEASE_PLAN.md).
