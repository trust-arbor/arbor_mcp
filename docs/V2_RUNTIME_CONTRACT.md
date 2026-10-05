# V2 runtime and scheduler contract

- **Status:** Implementation proposal; the complete runtime/scheduler redesign is required for v2.
- **Reviewed:** 2026-10-03.
- **Source:** Current MCP implementation following the integrated `v1.5.0` maintenance work.
- **Scope:** MCP server ownership, dispatch, callback execution, stores, and migration.
- **Names:** Public v2 APIs use the accepted `Arbor.MCP` namespace. `ExMCP` identifies current source modules and the 1.x migration baseline; ACP APIs move to `Arbor.ACP` separately.
- **Release target:** Friday, 2026-10-09; qualify a midweek RC before the remaining soak. The full redesign must pass its gates before the RC.
- **Related:** [V2_ROADMAP.md](./V2_ROADMAP.md), [V2_RELEASE_ASSESSMENT.md](./V2_RELEASE_ASSESSMENT.md), [STORE_ADAPTER.md](./STORE_ADAPTER.md).

## 1. Decision

Each logical MCP server owns a supervision subtree, scoped stores and
registries, and one common request scheduler. Transports perform framing and
delivery; application callbacks execute in bounded supervised workers. The
default remains serialized stateful execution. Concurrent callback execution
requires an explicit stateless configuration and cannot commit handler state.

The redesign is a v2 release gate, including stdio, test, BEAM-local, mounted
HTTP, standalone HTTP, legacy HTTP+SSE, modern request streams, and modern
subscriptions. Introducing a runtime module without cutting every transport
over to the common lifecycle does not complete this work.

## 2. Current behavior and concrete cutover points

| Current code | Observed contract | Required change |
|---|---|---|
| `server/handler_server.ex`: `do_init/1`, `handle_info({:transport_message, ...})`, `process_mcp_request/2`, `dispatch/2` | Initializes handler state inside the transport GenServer; callbacks run inline and block request/cancellation processing. Client timeout leaves work running. | Become a transport adapter for an explicit runtime. Move state, protocol validation, request claims, dispatch, lifecycle telemetry, and callback work into that runtime. |
| `server/stdio_server.ex`: `do_init/1`, `read_stdin_loop/2`, `dispatch/2`, `handle_custom_request/2` | Separate inline callback owner; a linked stdin reader records cancellation before sending a line. Locally creates subscription children when needed. | Keep byte framing/stdout delivery and a supervised reader; submit through runtime admission. Remove separate callback/state ownership and local subscription-runtime fallback. |
| `server/dispatch.ex`: `dispatch/4`, `call/6`, `paginated/6`, `do_dispatch/3` | Canonical method callback table for stdio/test/BEAM; context, method checks, MRTR preparation and normalization are coupled to invocation. | Retain the canonical method table; separate bounded admission/policy preparation from worker invocation and validated completion. Expand it for lifecycle methods currently handled by transports. |
| `message_processor.ex`: `process_validated_request/2`, `process_with_handler_genserver/4`, `start_handler_watchdog/1`, `dispatch_to_method_handlers/2` | HTTP creates an unlinked temporary handler GenServer for each request, with a separate watchdog and call timeout. Optional `:server` invokes an existing GenServer. | Route HTTP into the same runtime and dispatch table. Remove per-request handler startup/watchdog and the second method invocation lifecycle. |
| `message_processor/method_handlers.ex`: `safe_call`, `call_timeout/1` | Handler GenServer bridge and HTTP-specific result/error conversion. Default timeout is 10,000 ms. | Eliminate duplicate callback invocation/result semantics; retain only temporary migration wrappers if deliberately supported. |
| `http_plug.ex`: `init/1`, `process_mcp_request/2`, `process_or_open_request_stream/3`, session registration and resource publication | Compile-time options contain handler configuration; runtime side effects resolve global session owners. `:handler_opts` can be computed from each request. | Mount a named/runtime reference; keep HTTP checks and response decisions at the edge. Pass authenticated request facts as context, resolve all stores through the runtime, and never initialize another handler per POST. |
| `http_plug/request_stream.ex`: `serve/4`, `start_owner_watchdog/2`, `stop_worker/1` | Spawns a processing worker plus watchdog for each stream, independently of any server scheduler. | Subscribe to runtime-owned completion/notification delivery. Monitor the HTTP owner and cancel the runtime invocation on disconnect; remove unmanaged callback workers. |
| `http_plug/modern_stream.ex`, `http_plug/sse_handler.ex`, `server/sse_session.ex` | Stream/session shells own framing and connection loops. | Keep these responsibilities; resolve registration, replay, subscriptions and shutdown through the runtime. |
| `server/context.ex`: `cancelled?/0`, `with_context/2` | Process dictionary holds callback context; cancellation lookup/cleanup uses only the JSON-RPC request ID. | Install context inside each worker and consult its invocation token. Completion cleanup belongs to the scheduler, including forced exits. |
| `server/cancellation.ex` | One named public ETS table keyed only by request ID. Unknown IDs can accumulate, and equal IDs in sibling servers alias. | Runtime-owned cancellation state keyed by active invocation; scope wire cancel lookup to the authenticated session/connection. |
| `http_plug/session_registry.ex` | Named public table `:http_plug_sessions` maps session IDs to SSE PIDs. | Unnamed/runtime-owned indexes; registration and conditional unregister must use the same runtime. |
| `subscription_registry.ex` | Named URI/session ETS indexes; configuring another process name does not isolate table names. | Runtime-owned indexes and explicit publication scope. |
| `session_manager.ex` | Can start under another name, but its public facade still calls `__MODULE__`; termination/expiry cleanup calls global subscription indexes. | Explicit runtime/store reference throughout all session, initialization-claim, ID-claim, replay and cleanup paths. |
| `server/subscriptions.ex`, `server/subscription_listener.ex` | Already support some explicit owners/registries and bounded listener queues. | Start one registry/listener supervisor per runtime; include runtime identity in any cluster topic and preserve existing queue/delivery contracts. |
| `progress_tracker.ex`, `server/replay_cache.ex`, `tasks/store/ets.ex` | Progress has a named table; replay and task owners default to application singletons. | Scope server-owned progress, continuation consumption and task handles to their runtime, preserving principal/tenant/audience checks. |
| `internal/session_store.ex`, `internal/session_store/{ets,dets,factory}.ex` | Internal table-level seam; ETS is already unnamed/process-owned. DETS uses unique table names and exclusive files. | Retain the seam internally while adding domain-level store contracts and explicit runtime ownership. Fix DETS table-name allocation before repeated runtime restart tests. |
| `application.ex` | Starts all these server owners globally when the package application starts. | Keep package-wide client/security facilities where appropriate; server state starts only beneath an explicit server runtime. |
| `server/dsl.ex`: generated `child_spec/1`, `start_link/1`; `server/transport.ex` | Transport selects distinct ownership/start/stop implementations. | Delegate every generated startup path to the runtime and its selected transport adapter. |

Paths in this table are relative to `lib/ex_mcp/`. None of these current
internals establishes the proposed new behavior by itself.

## 3. Public startup and reference contract

The stable initial surface is deliberately small:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   id: :public_mcp,
   name: MyApp.PublicMCP,
   handler: MyApp.Tools,
   handler_args: [],
   transport: :http,
   http: [adapter: :bandit, port: 4000]}
]

# Mounted HTTP uses a supervised runtime without owning the host's listener.
{Arbor.MCP.Server.Runtime,
 id: :mounted_mcp,
 name: MyApp.MountedMCP,
 handler: MyApp.Tools,
 transport: :mounted_http}

forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MountedMCP

{:ok, supervisor_pid} = Arbor.MCP.Server.Runtime.start_link(handler: MyApp.Tools, transport: :test)
{:ok, runtime_ref} = Arbor.MCP.Server.Runtime.ref(supervisor_pid)
```

- `child_spec/1` accepts `:id` so two servers using the same handler coexist
  under one host supervisor. It specifies `type: :supervisor`.
- `start_link/1` returns the runtime supervisor PID with ordinary OTP links.
- `ref/1` accepts that PID, a runtime name, or an existing opaque runtime
  reference and returns `{:ok, ref}` or `{:error, :runtime_unavailable}`.
- `stop/2` captures one original `shutdown_timeout_ms` budget at API entry.
  A persistent runtime-owned observer enforces that cutoff independently of the
  graceful shutdown guard. Concurrent stops coalesce into one detached reason
  (at most 4,096 retained bytes) and one token wake per actor; later calls cannot
  renew the cutoff. Ownership registration has a fixed 16,384 live-PID inventory
  plus the one observer; registration is rejected before owned work if full.
  Native children and registered adapter processes retain their actual parents.
  The observer uses only those authenticated identities, never a link graph or
  caller-supplied borrowed PID. A small forced-cleanup allowance is reserved
  inside the original budget. `:ok` requires actual root, registered-owned and
  observer DOWN receipts before the caller's original cutoff. A late or incomplete
  result is `{:error, :shutdown_cleanup_unconfirmed}`. Loss of the authority fails the
  runtime closed with `{:error, :shutdown_control_unavailable}` and never creates
  an empty replacement authority. Entered borrowed IO retains its existing
  transport liabilities and receipts; root DOWN does not prove that IO settled.
  Registered-name lookups retain the documented trusted finite lookup contract.
  Host supervisors retain their child restart policy and borrowed services or
  mounted listeners survive. Use `Supervisor.terminate_child/2` to remove a
  managed endpoint rather than allowing a permanent child to restart.
- The opaque reference identifies the supervisor instance, not a scheduler
  child PID. Internal child restart does not require a new reference; replacing
  the whole supervisor does. A registered name can resolve a replacement.
- Core APIs never choose a default server from a process-global registry.
  Explicit names are convenience addresses owned by the host, not library
  requirements. Do not generate atoms from runtime IDs or session IDs.
- Generated Handler/DSL startup delegates to this surface and returns the
  runtime supervisor PID. `Client.start_link(server: runtime_ref)` and the
  existing `server: supervisor_pid` shorthand resolve the test/BEAM adapter.
- Request admission, scheduler reducers, effect schemas and child lookup are
  internal APIs initially. Do not expose a public middleware framework as part
  of this migration.

`HttpPlug.init/1` must remain safe when its value is escaped into a compiled
Phoenix router. Prefer a named runtime in mounted HTTP options and resolve it
at request time; never start a runtime from `init/1` or `call/2`. Missing runtime
is a clear service-unavailable response, not a fallback to a global owner.

## 4. Ownership, restart and stop

Use a runtime root with dependency-ordered subtrees:

```text
Runtime supervisor (:rest_for_one)
├── Store supervisor
│   ├── session/event adapter owners
│   ├── scoped HTTP session + resource subscription indexes
│   ├── task store + MRTR replay cache
│   └── modern subscription registry + listener supervisor
├── Execution supervisor (:one_for_all)
│   ├── Task.Supervisor
│   └── scheduler / handler state owner / admission generation
└── Transport supervisor (:one_for_one)
    ├── selected standalone listener, or test/BEAM transport process
    └── stdio reader/writer, when selected
```

One responsive scheduler/state-owner process is sufficient initially. It
stores the latest committed handler state but does not execute protocol
callbacks inline. Workers are `Task.Supervisor` children monitored without
linking them to request/transport processes. `handler.init(handler_args)` runs
once in the state-owner lifecycle; it is not called on each HTTP request.
Startup is not considered ready until initialization succeeds. Bound startup
with `init_timeout_ms`, and bound shutdown with `shutdown_timeout_ms`.

Owned Cowboy startup uses the qualified native callbacks described in
[HTTP_LISTENERS.md](./HTTP_LISTENERS.md), including real acceptor parent links
and registration before startup ACK or stock Ranch IO. A normal acceptor child
restart inside a healthy listener captures one new finite constructor cutoff
without reinitializing handler state. Constructor return checks the same runtime
epoch and original cutoff. A late queued ACK is rejected; the exact owned child
is signalled for termination and remains registered until actual DOWN. Native
restart escalation follows the owned listener failure policy below. Borrowed
stock listener constructors remain host-owned.

| Failure | Required outcome |
|---|---|
| Callback exception/exit | Fail that invocation; release its reservation after its worker is down; retain committed state; no sibling request or runtime crash. |
| Scheduler or task-supervisor crash | Restart the execution subtree together so orphan workers cannot commit into replacement state. New handler state is initialized; pending requests fail, without automatic replay. |
| Test/BEAM edge or HTTP request-stream crash | Cancel work owned by the lost connection; restart the edge where applicable. Keep the healthy runtime state, sessions and replay store. |
| Owned standalone HTTP listener failure | Fail-stop this runtime instance. Its host supervisor applies the configured restart policy; a replacement has a new runtime reference and initializes new handler state. Borrowed host listeners survive. |
| ETS session/event owner crash | Invalidate affected sessions/indexes and restart dependent execution/transports. Never retain indexes pointing to vanished tables. The other runtime is untouched. |
| Durable adapter owner crash | Fail closed until reopened. Recovered data follows adapter contracts; do not acknowledge an append before durability is confirmed. Dependent execution/transports restart; no callback replay. |
| Whole runtime stop | Close admission, cancel queued work, signal running work, reap workers/listeners/transports, close stores, and leave other runtimes running. |
| Mounted HTTP runtime stop | Host Phoenix/Bandit/Cowboy listener stays running. Requests to the stopped runtime receive service unavailable. |
| Stdio EOF | Close its connection and stop its owned runtime normally; reader/writer and callback tasks must exit. |

External adapters may be supplied as an owned child specification or as an
explicit borrowed reference. The ownership flag is mandatory for borrowed
processes: stopping a runtime never stops a host-owned listener/store. Store
isolation remains mandatory; a shared external backend must namespace its data
with an explicitly configured durable runtime key.

Do not persist a PID or an ephemeral `make_ref()` as the durable namespace.
In-memory runtime identity and a configured persistence key serve different
purposes. Two runtimes cannot concurrently open the same local DETS directory.

## 5. One request pipeline

All transports submit an envelope containing a decoded message, trusted
transport/session ownership, authenticated identity, accepted monotonic time,
reply target and bounded request context. The runtime performs these phases:

1. Admit within count/byte bounds; reject before retaining the request payload
   when pressure limits are exceeded.
2. Validate JSON-RPC shape/params, protocol mode/version, session initialization
   and duplicate IDs. Pin protocol era and consume an ID at the same point for
   every applicable connection/session.
3. Bind principal, tenant, audience and endpoint from trusted transport facts;
   apply common method authorization and MRTR validation/replay policy. Wire
   `_meta` cannot supply authenticated ownership.
4. Handle built-in lifecycle/control transitions or enqueue a callback with a
   deadline and unique invocation token.
5. Execute the canonical dispatch table in a supervised worker with installed
   request context. Normalize callback shapes through the common result
   contract; return a completion proposal, not a transport write.
6. In the scheduler, validate invocation generation, terminal state and
   deadline; commit eligible state; record one terminal outcome; emit delivery
   and payload-safe telemetry effects.
7. Let the transport encode/deliver the outcome. A delivery failure feeds back
   as a tagged lifecycle event; it cannot replay the callback or undo committed
   state.

HTTP-specific Origin/Host/body/header checks, OAuth token verification and
`Plug.Conn` access stay at the transport edge. Their authenticated outcome
enters the common policy phase. Stdio framing and supported legacy batch
encoding also stay at the edge. The protocol capability/version policy does
not change merely because the package major changes.

Legacy batches reserve capacity for their individual work and retain the
existing response-array/notification rules. Modern versions continue to
reject batches. A batch may not bypass request/byte limits by counting as one
queue entry. Shared dispatch adds custom-request invocation and notifications
with the same context/error policy, replacing transport-only behavior.

## 6. Callback PID and state semantics

### Default stateful mode

- `execution: :stateful` is the default, with one callback worker active per
  runtime. This serializes *all* callbacks that can return handler state,
  including initialization negotiation, lists, tools, resources, custom
  requests and application notifications.
- Accepted callback work enters one FIFO queue. Ordering is scheduler
  acceptance order, not wall-clock order between simultaneous connections.
- Each worker receives the latest committed state. Callback return values are
  completion proposals. Only the state owner commits them.
- A well-formed application success, application error or MRTR input-required
  return can commit its returned state. A crash, malformed return, failed
  result validation, cancellation or expired deadline cannot commit it.
- State commits precede final-response delivery. The next stateful callback
  can begin after commit and worker termination; it does not wait indefinitely
  for a slow client's socket. No global wire ordering is promised across
  separate connections. Per-connection final effects preserve scheduler order.
- Built-in cancellation, deadlines, disconnects, client replies and shutdown
  continue to be processed while a callback blocks. They must not wait in the
  callback FIFO.

Callbacks now run in a temporary worker PID. They do not inherit the starter's
links, transport mailbox, process dictionary or process-local ownership. That
is an intentional v2 breaking change. `Context.current()` is installed by the
worker wrapper and restored on its normal exit paths. Children spawned by a
callback do not inherit the context or gain runtime lifecycle management.

Handlers that put `self()` in initial state, send messages to their former
server PID, write process-owned protected ETS tables, use process dictionary
state or rely on GenServer callback ordering must migrate those resources to
explicit supervised application processes. The protocol state term should
hold references to such owners. Callback PID is not a public server address.
Generic `GenServer.call(runtime_pid, application_message)` is not a handler
extension API; use an application-owned process, or the supported protocol
custom-request callback. Handler lifecycle `terminate/2` receives the latest
committed state during orderly state-owner shutdown, with its configured
budget; brutal termination cannot promise it runs.

### Explicit stateless mode

`execution: :stateless` enables bounded concurrency with a configured
`max_concurrency`. Handler initialization still runs once. Each callback gets
the immutable initialized state. Any callback return that changes that state
fails as `invalid_handler_state` and commits nothing. Legacy tuple callback
forms remain usable when their returned state is strictly identical to the
input state. Compare normalized completion state with `===`.

Stateless mode is an application promise about state ownership and effects;
it cannot prevent an adapter from mutating an external database. Stateful
handlers using external owners still need explicit opt-in before concurrent
invocation. Do not infer safety from a callback name, DSL metadata, absence of
state changes observed in tests, or `max_concurrency > 1`.

No speculative state merging, last-writer-wins commit, or retry after worker
failure is provided. Replies in stateless mode can complete out of submission
order; JSON-RPC IDs correlate them. A later compatible per-method execution
policy can be added only if it preserves these v2 defaults and guarantees.

## 7. Bounded admission and pressure

Proposed validated defaults:

| Setting | Default | Meaning |
|---|---|---|
| `execution` | `:stateful` | Serialized by default; `:stateless` requires explicit opt-in. |
| `max_concurrency` | `1` | Active callback slots; values above one require stateless mode. |
| `max_queue` | `128` | Waiting callback entries; zero rejects when all active slots are occupied. |
| `max_request_bytes` | `1_000_000` | Accepted decoded request budget, aligned initially with current HTTP body limit. |
| `max_pending_bytes` | `8_000_000` | Combined retained queued/running request input budget, excluding user-managed state. |
| `request_timeout_ms` | `10_000` | Server deadline from runtime acceptance, including queue time. |
| `cancel_grace_ms` | `100` | Cooperative cancellation window before forced termination. |
| `init_timeout_ms` | `10_000` | Initialization/startup budget. |
| `shutdown_timeout_ms` | `5_000` | Total owned-runtime shutdown budget. |
| `pressure_policy` | `:reject` | Bounded FIFO wait while capacity exists; reject on limit. |

These are proposal values requiring pressure/baseline validation before freeze.
No infinite queue or fire-and-forget callback mode is supported. Per-connection
request-ID history retains its existing bounded fail-closed default unless a
separate migration decision changes it. Existing subscription queue/count/
byte/lifetime bounds also remain enforced within each runtime.

A bounded internal queue alone is insufficient: sending every request to a
GenServer first leaves its mailbox unbounded. Adapters reserve count/bytes
through a runtime-owned atomic admission gate **before** sending the full
payload to the scheduler. Reservation ownership and generation are tracked so
producer death, validation rejection, queue cancellation, worker failure and
runtime restart release or invalidate reservations exactly once. The gate is
never a permit for arbitrary callers to write scheduler state.

Control events use a separate bounded/coalesced path keyed by active work;
duplicate cancels cannot flood a full data queue. Stdio stops reading while a
bounded buffer is full or rejects the excess work; it must continue admitting
valid cancellation/control messages. Test/BEAM send returns a pressure result
before putting an unlimited payload backlog into the transport process.
HTTP host-level connection/request limits remain the host's responsibility;
runtime bounds cover admitted library work, not arbitrary HTTP processes.

Transport failures carry the same JSON-RPC error classification when a reply
can be delivered:

| Outcome | JSON-RPC classification | HTTP envelope |
|---|---|---|
| Queue/count/byte pressure | `-32603`, `data.type: "server_busy"` | `503` before a stream has opened; protocol error on an already-open stream. |
| Server deadline | `-32603`, `data.type: "handler_timeout"` | Valid accepted request returns its protocol outcome. |
| Worker crash | `-32603`, `data.type: "handler_crash"` | Same accepted-request outcome; redact exception/stack/payload details. |
| Invalid callback return/state | `-32603`, stable `invalid_handler_result` / `invalid_handler_state` type | Same accepted-request outcome. |
| Explicit cancellation | Existing `ErrorCodes.request_cancelled()` and stable cancellation type | One final protocol error if the response channel remains usable. |
| Owner disconnected/runtime stopping | Local tagged terminal failure; wire outcome only if a live authorized target remains | No response attempt to a closed socket. |

Do not add a new MCP protocol error number to encode internal queue policy.

## 8. Cancellation, deadlines and races

Each admitted invocation has an opaque token plus the current execution
generation. Its wire request lookup includes runtime, authenticated logical
owner/session or connection, direction and JSON-RPC ID. Equal IDs in different
servers, sessions and server-to-client/client-to-server directions are
independent. Unauthenticated cancellation cannot select another owner.

- Unknown/already-terminal cancellation is idempotent and creates no
  unbounded tombstone. Cancellation is validated before lookup/marking.
- Queued cancel removes work without invoking the callback and releases its
  reservation. Running cancel marks the invocation token immediately, emits a
  cooperative signal and starts the grace timer. `Context.cancelled?/0` reads
  that token without calling the busy callback process.
- After cancellation is accepted, no returned state or success can commit.
  Forced kill after grace guarantees callback work cannot continue forever;
  the active slot stays occupied until `DOWN` confirms the old worker ended.
- Cancellation becomes terminal immediately, allowing one timely final error.
  Worker cleanup and permit release finish separately. Cancel/timeout/result
  races cannot create another final response.
- A client-side waiting timeout is distinct from the server deadline. Only an
  accepted cancellation or observed owner disconnect aborts server work before
  its configured deadline; client timeout alone is not a rollback signal.
- Runtime deadlines use monotonic time and are computed on acceptance. A
  completion at or after the deadline is expired even if its result message
  arrived before the timer message. Wall-clock jumps cannot extend a request.
- Timer, worker-result and `DOWN` messages carry the invocation token and
  generation. Late results, duplicate results, stale timers and stale cancel
  events are ignored after the first terminal transition.
- A completed-and-committed callback wins over a later cancellation. A result
  merely computed in a worker has not committed until the scheduler accepts it.
- Disconnect removes only that owner's queued/running invocations and active
  stream registrations. Retained legacy session replay and task handles follow
  their explicit lifetime contract; they are not deleted because one GET ends.
- Cancellation stops local computation; it cannot undo already-issued external
  effects. The runtime never automatically retries such work after ambiguous
  delivery, crash or restart. MRTR replay protection remains an independent
  explicit policy.

Request progress/log notifications remain ordered before their final response
on the originating stream. Route acknowledgments through the stream owner;
backpressure waits count against the request deadline. A stream may never
fall back to another request/session's stream. Bound pending notification bytes
and coalesce progress; clear pending acknowledgments on cancellation/disconnect.

## 9. Stores and persistent contracts

The existing `Internal.SessionStore` table facade remains private. Public
adapter contracts should operate on sessions and events, not expose ETS/DETS
table names or term shapes. Session identity binding, initialization claims,
protocol immutability and request-ID limits remain policy owned by the runtime's
session manager.

Domain contract suites must establish:

- Atomic create/claim/update/delete with explicit runtime namespace; duplicate
  request-ID claim is rejected in the correct session and survives recovery
  when the selected durable session adapter promises persistence.
- Event append returns an opaque, store-owned cursor after the required write
  succeeds. The runtime does not parse/sort backend cursors as timestamps.
- Replay after an exact cursor returns ordered events. An unknown, foreign or
  evicted cursor has an explicit tagged outcome; it must not silently replay
  a partial suffix or another session's events.
- Per-session retention count/bytes, event size and TTL bounds, deterministic
  expiry, explicit deletion, cursor-eviction behavior and adapter shutdown.
- Append/replay registration is coordinated so publish during the reconnect
  gap is neither dropped nor duplicated; append-before-delivery permits replay
  when the socket fails immediately after persistence.
- Caller retry/idempotency policy is specified. The default must not claim
  exactly-once application effects merely because an event append is atomic.
- Persistence clocks/cursors survive reopen; ephemeral connected PIDs and
  abandoned initialization ownership do not. Recovery releases abandoned
  initialization claims without re-running application requests.
- Default telemetry includes backend, runtime identity, size/count, duration
  and safe outcome class; it excludes event bodies, credentials and arguments.

ETS remains the default. DETS remains supported for the existing persistence
lane after the new contract suite passes. Current DETS `table_names/0` creates
fresh atoms per open; the v2 implementation must use a bounded managed name
allocation strategy and test repeated reopen/restart without atom growth. A
shared durable path must fail clearly instead of aliasing another runtime.

Store ownership must be tested independently from listener ownership: crashing
a standalone HTTP listener cannot discard acknowledged durable events.

## 10. Configuration and migration defaults

Build a validated `Server.Config` once at runtime startup. Resolve explicit
startup options first, then deliberately supported application configuration,
then library defaults. Record current per-option/environment precedence in the
API manifest before changing it; preserve existing nonarchitectural defaults
unless explicitly listed in the migration guide. Runtime internals never
rediscover environment/configuration during each callback.

Migration changes requiring examples and API-diff entries:

| 1.x use | v2 replacement/change |
|---|---|
| Handler/DSL `start_link` returns callback/transport GenServer PID | Returns runtime supervisor PID; use runtime reference for library operations and a separate application process for custom GenServer calls. |
| Callback `self()` equals server PID and inherits starter links | Temporary supervised worker PID with installed request context. Move persistent process resources to explicit owners. |
| HTTP `handler: Module` initializes a temporary process per POST | Supervise a runtime and mount `HttpPlug` with `runtime: Name`. Handler initialization occurs once. |
| Request-derived `:handler_opts` for HTTP initialization | Static `handler_args` at startup; request-derived authenticated/application inputs enter callback context through an explicitly documented mapper. Never put `Plug.Conn` into retained handler state. |
| HTTP `:handler_call_timeout` | Runtime `request_timeout_ms`, including queue time, with the same deadline across transports. Supply an intentional migration error/warning if the old option is removed. |
| No HandlerServer server deadline | Default 10,000 ms deadline; long-running work must explicitly configure its budget or use supported Tasks/MRTR mechanisms. |
| Globally addressed SessionManager/SubscriptionRegistry/progress | Runtime-scoped facade; operations require the runtime or its opaque store reference. |
| Cancellation records any request ID globally | Cancels only active work in the runtime's authorized owner scope, and prevents state commit after acceptance. |
| `max_concurrency` expected to speed up an arbitrary stateful handler | Values above one require explicit stateless mode; state change returns fail closed. |
| Package startup implicitly starts HTTP/server state stores | Host supervises each logical runtime; package-only clients do not start unused server owners. |

The normalized `Server.Result` constructor/return contract and retained tuple
forms must agree with this completion/state-commit policy. Existing tool error
versus protocol error distinctions, MRTR capability checks, typed errors and
safe error redaction remain common behavior across transports. Remove old
parallel result facades only after their migration examples are qualified.

## 11. Implementation sequence and release gates

1. Freeze callback/API/default characterization from the final 1.x baseline.
   Add the config validation contract, runtime reference and ownership tests.
2. Add runtime-scoped stores/indexes and the supervision tree. Exercise two
   runtimes with colliding IDs, subscriptions, task handles and replay tokens.
3. Add a pure scheduler/request-lifecycle reducer with injected time, IDs and
   generation. Execute its tagged effects from the OTP state owner; feed
   task-start/store-write/delivery failures back into that reducer.
4. Implement admission reservation, supervised workers, serialized commits,
   stateless opt-in, cancellation/deadlines and pressure accounting. Prove
   bounded queues and absence of post-terminal commits before cutover.
5. Cut test/BEAM and stdio over together; preserve framing, modern/legacy
   protocol rules, subscriptions and reverse-direction requests.
6. Cut mounted/standalone HTTP and both SSE paths over to the same runtime.
   Remove temporary-handler and unmanaged-stream-worker lifecycles. Qualify
   optional Cowboy/Bandit adapters and borrowed host listeners.
7. Complete store contracts, Result facade, migrated Handler/DSL startup,
   docs/options/examples and removal manifest. Qualify packaged MCP-only and
   combined consumers, then run RC/soak and release gates.

Steps may be developed in parallel after their contracts are fixed, but v2
does not ship with one transport left on the previous scheduler.

### Existing evidence to preserve

- `test/ex_mcp/server/runtime_characterization_test.exs`: callback PID/links,
  in-process timeout, cancel polling, sequential commits, sibling stop.
- `test/ex_mcp/server/context_cancelled_integration_test.exs` and
  `test/ex_mcp/cancellation_test.exs`: cancellation context/polling.
- `test/ex_mcp/server/dispatch_test.exs`, `server/mrtr_dispatch_test.exs`,
  `message_processor_test.exs`, `message_processor_mrtr_test.exs`: method and
  result/error equivalence; HTTP timeout/crash redaction and old per-request
  process cleanup are the explicit before/after comparison.
- `test/ex_mcp/http_plug_test.exs`, `http_plug/{core,sse_handler}_test.exs`,
  `session_manager*_test.exs`, `session_store_contract_test.exs`,
  `server/sse_session_test.exs`: HTTP security, session initialization/replay,
  TTL/retention, adapter ownership and failure behavior.
- `test/ex_mcp/client/modern_http_request_stream_test.exs`,
  `server/handler_server_subscriptions_test.exs`, `subscription_registry_test.exs`,
  `server/replay_cache_test.exs`: scoped streams/subscriptions and continuation
  replay. Keep modern subscription/task tests as additional required lanes.
- `test/support/session_store_contract.ex`: reusable current ETS/DETS baseline;
  extend domain-level suites rather than making backend-specific assertions.

### New acceptance suites

| Suite | Required observations |
|---|---|
| Runtime ownership/isolation | Start two instances with the same handler and same wire IDs; stop/crash/restart each child category; no cross-server cancellation, publication, cleanup, store lookup or task/replay access. |
| Worker PID/lifecycle | Callback differs from runtime/transport PID; no request/starter links; runtime-owned worker reaped on success, crash, cancel, deadline, disconnect and shutdown. No detached watchdog leak. |
| Serialized state | Concurrent counter calls commit 1, 2, 3; a gated error return commits its valid state; invalid/crashed/cancelled/expired returns do not; next worker begins only after previous worker termination. |
| Stateless safety | Explicit concurrency reaches its bound, replies correlate out of order, unchanged state is accepted, changed state is rejected, and missing opt-in rejects concurrency configuration. |
| Terminal races | Inject result/cancel/deadline/`DOWN` in every order; exactly one terminal response, telemetry outcome and reservation release; stale-generation events cannot mutate a restarted runtime. |
| Pressure | Saturate count and byte budgets under every transport; assert bounded scheduler/transport mailboxes, worker count and retained bytes; queued timeout/cancel frees capacity; cancel storms remain bounded. |
| Reverse requests | Callback can await authorized sampling/roots/input responses while the runtime processes client replies; direction-scoped ID equality does not cancel/complete inbound work. |
| Cross-transport golden | Same request/handler/context yields the same result, error type, authorization denial, deadline and cancellation outcome over test, BEAM, stdio and each HTTP adapter. |
| Stream delivery | Progress/log ack precedes final response; disconnect cancels only its work; final chunk failure does not repeat state commit; no notification escapes to a sibling stream. |
| Store contract/recovery | Exact/evicted/foreign cursor replay, append then disconnect, publish during replay gap, TTL/delete, initialization claim recovery, durable listener restart, duplicate-ID recovery and DETS reopen/atom bounds. |
| Migration examples | Supervised unnamed/named servers, two servers with one handler, mounted Phoenix HTTP, optional Bandit/Cowboy, stdio without HTTP packages, stateful and stateless tools, and application resource owners. |

Use deterministic barriers and injected monotonic time for ordering/race
contracts. Real timers and subprocess/network paths remain integration tests
with bounded tolerances. Record process/queue/retained-byte and cancellation
latency measurements against final 1.x artifacts; passing unit tests alone is
insufficient release evidence.
