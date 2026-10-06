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
`Arbor.MCP.Server.HandlerServer.start_link(handler: MyHandler, transport: :test)`
also return Runtime supervisor PIDs. Treat those PIDs as server handles, not
as GenServers containing handler state.

For multiple servers, give each supervised child a distinct `:id` and any
registered server a distinct `:name`. Configuration and runtime-owned state
are scoped to that server.

## Stateful and stateless callbacks

The default is `execution: :stateful, max_concurrency: 1`. Callbacks execute
serially in supervised workers and return the next handler state. A callback's
`self()` is a worker PID, not the server handle; pass explicit server/context
references to work that needs them.

Opt into concurrency only when callbacks do not update initialized state:

```elixir
{Arbor.MCP.Server.Runtime,
 handler: MyApp.ReadOnlyMCPServer,
 transport: :mounted_http,
 execution: :stateless,
 max_concurrency: 4,
 max_queue: 32}
```

Stateless callbacks must return unchanged handler state. External effects are
still the application's responsibility; concurrency does not make those effects
transactional or safe to retry.

## Bound admission and waiting

These are separate settings, not interchangeable timeouts:

| Setting | Default | Purpose |
| --- | --- | --- |
| `init_timeout_ms` | 10,000 ms | One budget for Runtime startup and handler initialization |
| `request_timeout_ms` | 10,000 ms | Server work deadline |
| `max_queue` | 128 | Queued data work beyond active callback capacity |
| `max_request_bytes` | 1,000,000 | Per-request retained input limit |
| `max_pending_bytes` | 8,000,000 | Aggregate admitted input/context/options budget |
| `max_output_frames` | 128 | Retained output frame count |
| `max_output_bytes` | 4,194,304 | Aggregate retained output budget |
| `output_timeout_ms` | 5,000 ms | Output lifetime budget |
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

## Connections and stores

Clients borrow existing BEAM/test servers. Stopping a client does not stop that
server. `Arbor.MCP.Client.with_connection/3` owns a newly created client for a
callback and reports its cleanup outcome; see the
[connection guide](V2_CLIENT_CONNECTION_SCOPE.md).

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
[runtime diagnostics](V2_RUNTIME_DIAGNOSTICS.md).
