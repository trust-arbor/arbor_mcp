# Runtime supervision and limits

ArborMCP v2 gives each MCP server its own `Arbor.MCP.Server.Runtime` supervisor.
HTTP, stdio, BEAM and test transports submit callback work to that Runtime.
The handler initializes once, and its state belongs to the scheduler.

Use the [quickstart](getting-started/QUICKSTART.md) to define a handler first.
This guide explains how to host it and choose its operating limits.

## Supervise a server

For a Phoenix application, start the Runtime before the endpoint:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   id: :mcp,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http,
   request_timeout_ms: 10_000,
   max_queue: 128,
   max_pending_bytes: 8_000_000},
  MyAppWeb.Endpoint
]
```

Mount that Runtime in the router:

```elixir
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

The endpoint owns the HTTP listener; this Runtime borrows it. A standalone
server can own a Cowboy or Bandit listener instead; see
[HTTP listeners](HTTP_LISTENERS.md). For BEAM/test, the generated DSL
`MyServer.start_link(transport: :beam)` and
`Arbor.MCP.Server.start_link(handler: MyHandler, transport: :test)`
also return Runtime supervisor PIDs. Treat those PIDs as server handles, not
as GenServers containing handler state.

For multiple servers, give each supervised child a distinct `:id` and any
registered server a distinct `:name`. Configuration and runtime-owned state
are scoped to that server.

## Concurrent and stateful callbacks

Servers handle the requests on a connection concurrently by default, as the
other MCP SDKs do: a slow tool call doesn't hold up other calls, `ping` or
`notifications/cancelled`. The default is `execution: :stateless,
max_concurrency: 64`. `init/1` and `handle_initialize/2` may set up handler
state; initializations commit one at a time. Every other callback runs in its
own supervised worker against a snapshot of that state and must return the
snapshot unchanged. Keep counters, caches and other mutable data where
concurrent processes can share them: a GenServer, an Agent, an ETS table or
your database. A callback that returns a changed state fails its request with
`invalid_handler_state`, and the runtime logs a warning naming the handler the
first time.

Handlers that thread state through their callbacks, the way a GenServer does,
opt into one-at-a-time execution:

```elixir
{Arbor.MCP.Server.Runtime,
 handler: MyApp.CountingMCPServer,
 transport: :mounted_http,
 execution: :stateful}
```

Stateful callbacks run one at a time, in arrival order, and each commits the
state it returns. `max_concurrency` must stay 1. The runtime still answers
`ping` while a stateful callback runs, because answering it needs no handler
state. On stdio, a stateful server also waits until each response is written
before it starts the next callback.

Either way, a callback's `self()` is a worker PID, not the server handle; pass
explicit server/context references to work that needs them. External effects
are still the application's responsibility; concurrency does not make those
effects transactional or safe to retry.

## Middleware

`:middleware` wraps every request and notification dispatched to the handler,
like Python's `MCPServer(middleware=[...])` and Go's `AddReceivingMiddleware`.
List modules that implement `Arbor.MCP.Server.Middleware`, or `{module, opts}`
pairs, outermost first:

```elixir
{Arbor.MCP.Server.Runtime,
 handler: MyApp.MCPServer,
 transport: :mounted_http,
 middleware: [MyApp.MCPAudit, {MyApp.MCPRateLimit, per_minute: 60}]}
```

Each gets the request (`:method`, `:id`, `:params`, `:context`) and a `next`
function, and returns what `next` returned or its own `{:ok, result}` or
`{:error, %{"code" => code, "message" => message}}`. It can refuse a request
by not calling `next`, change the params it passes on (they are validated
again), or change the result. It runs in the callback worker, inside
`Arbor.MCP.Server.Context`, so `Context.auth_info/0` is available, and it
never sees the handler state. The chain also sees `initialize`,
`server/discover`, `ping` and notifications; it doesn't see
`notifications/cancelled` or messages rejected before dispatch.

## Bound admission and waiting

These are separate settings, not interchangeable timeouts:

| Setting | Default | Purpose |
| --- | --- | --- |
| `init_timeout_ms` | 10,000 ms | One budget for Runtime startup and handler initialization |
| `request_timeout_ms` | 3,600,000 ms (1 hour) | Server work deadline: a safety net, since callers end work with their own timeout |
| `max_concurrency` | 64 (1 with `execution: :stateful`) | Callbacks running at once |
| `max_queue` | 128 | Queued data work beyond active callback capacity |
| `max_request_bytes` | 1,000,000 | Per-request retained input limit |
| `max_pending_bytes` | 8,000,000 | Aggregate admitted input/context/options budget |
| `max_control_queue` | 32 | Retained control permits |
| `max_control_bytes` | 65,536 | Retained control bytes |
| `max_output_frame_bytes` | 1,048,576 | One encoded output frame |
| `max_output_term_bytes` | 1,048,576 | One retained output term |
| `max_output_frames` | 128 | Retained output frame count |
| `max_output_bytes` | 4,194,304 | Aggregate retained output budget |
| `max_output_scope_bytes` | 65,536 | Aggregate scope and pending-control metadata budget |
| `max_http_writers` | 128 | Concurrent HTTP writers |
| `max_http_writer_metadata_bytes` | 65,536 | Retained HTTP writer metadata byte budget |
| `max_http_io_frames` | 128 | Retained HTTP IO frame count |
| `max_http_io_bytes` | 4,194,304 | Aggregate retained HTTP IO bytes |
| `max_http_io_frame_bytes` | 1,048,576 | One retained HTTP IO frame |
| `output_timeout_ms` | 5,000 ms | Output lifetime budget |
| `cancel_grace_ms` | 100 ms | Cooperative callback cleanup before task kill |
| `shutdown_timeout_ms` | 5,000 ms | One budget for Runtime shutdown |

Admission fails explicitly when capacity is exhausted. Legacy batches consume
one data permit per member until the whole batch settles. Control and output
traffic have separate bounds. See `Arbor.MCP.Server.Runtime` for the complete
contract and the [configuration guide](CONFIGURATION.md) for transport options.

Client request/wait timeouts remain separate from the server deadline. A caller
stopping its wait does not establish that an accepted request was cancelled,
and cancellation cannot undo external effects already performed by a callback.

These limits cover library-owned work. They do not bound arbitrary handler
state, raw Erlang sends, peer mailboxes, external processes or OS buffers.

A cancelled callback receives `{:arbor_mcp_cancelled, token, reason}`, with
`:request_cancelled`, `:owner_down`, or `:handler_timeout` as the reason. It
may poll `Context.cancelled?/0` or handle that message while finishing cleanup.
After `cancel_grace_ms`, the Runtime kills a callback that has not stopped.
This applies to every Runtime-backed transport and cannot undo external effects.

For MRTR, configure `mrtr: true` and optionally `request_state: [...]` on the
Runtime itself. Missing or invalid key rings fail startup with
`{:error, {:mrtr_configuration_error, reason}}`, including mounted HTTP.
Unknown Runtime option names fail with `{:unknown_runtime_options, keys}`.

## Connections and stores

Clients borrow existing BEAM/test servers. Stopping a client does not stop that
server. `Arbor.MCP.Client.with_connection/3` owns a newly created client for a
callback and reports its cleanup outcome; see the
[connection guide](RUNTIME_GUIDE.md).

BEAM/test peers and stdio connections retain a finite set of request IDs to
prevent duplicate execution. The default is 10,000 distinct IDs. Plan connection
lifetimes and set `max_request_ids` for the workload instead of disabling the
bound. A new BEAM/test Client can connect to the retained server after the old
client is stopped. HTTP session ID limits have their own lifecycle.

HTTP Runtime services supply scoped session and subscription storage. Configure
them through the Runtime's `services:` descriptors; adding a standalone global
store does not reconfigure a mounted Runtime. Custom adapters must implement the
documented bounded lifecycle contract. See the
[session configuration](CONFIGURATION.md#session-storage) and
[migration guide](guides/MIGRATING_V1_TO_V2.md).

## Stop and diagnose

Use `Arbor.MCP.Server.Runtime.stop(server)` for an independently started Runtime.
It returns confirmed cleanup or an explicit unconfirmed/error result within its
shutdown budget. If a parent supervisor should keep the child stopped, use
`Supervisor.terminate_child(parent, child_id)` so the restart policy does not
bring it back.

Shutdown covers registered owned processes and callback work. Borrowed listeners
and services survive. Process death alone does not prove a subprocess was reaped,
an output was consumed, or a remote effect was rolled back.

Normal diagnostic reports omit handler payloads and retained request data. Trusted
in-VM inspection can still expose state, and application callbacks control their
own logging. See [troubleshooting](TROUBLESHOOTING.md) and
[runtime diagnostics](DIAGNOSTICS.md).
