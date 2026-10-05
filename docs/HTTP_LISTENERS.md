# Standalone HTTP listeners

`arbor_mcp` keeps its HTTP client and `Arbor.MCP.HttpPlug` in core. Cowboy and
Bandit remain optional host dependencies. Mounting the Plug in Phoenix does not
create, adopt or stop the host listener. Unix source installation still builds
the transitive Arbor.RPC native helper and requires a C17 compiler; an installed
release does not require a compiler at runtime.

## A runtime that owns its listener

Add `{:plug_cowboy, "~> 2.7"}` to the host dependencies, then supervise one root:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   handler: MyHandler,
   name: MyApp.MCPRuntime,
   transport: :http,
   http: [adapter: :cowboy, host: {127, 0, 0, 1}, port: 4000]}
]
```

The returned PID and `:name` identify the runtime supervisor. The handler
initializes once; every POST uses the installed Gateway and Scheduler. The
listener is a real child under the runtime's HTTP supervisor, after the Gateway
and before the root readiness barrier. Configuration, owned services, handler
initialization and listener construction share the original `:init_timeout_ms`
cutoff. An owned listener failure retires this runtime instance; its parent may
restart the endpoint with a fresh reference and handler state. The parent must
terminate/remove its child when the endpoint should remain stopped.

DSL `MyServer.start_link(transport: :http, ...)` and
`Server.Transport.start_server/4` return the same runtime root. The positional
`server_info` and `tools` compatibility arguments do not create another handler;
metadata and tools come from the handler/DSL callbacks. Top-level listener
options (`:http_adapter`, `:port`, `:host`, `:http_listener_options`, `:ranch_ref`)
remain supported; nested `http: [adapter: ..., listener_options: ...]` is the
Runtime form.

```elixir
{:ok, %{listener: listener, adapter: :cowboy, ranch_ref: ref}} =
  Arbor.MCP.Server.Transport.http_listener(MyApp.MCPRuntime)
port = :ranch.get_port(ref)
:ok = Supervisor.terminate_child(MyApp.Supervisor, Arbor.MCP.Server.Runtime)
```

Cowboy owned endpoints use distinct opaque Ranch references by default, so
sibling roots can bind different ports. An explicit `:ranch_ref` keeps its
identity. Arbor's owned constructor and lower Cowboy adapter/helper share an
atomic reference claim before listener effects; a competing Arbor constructor
returns `:http_listener_reference_in_use`. Default references stay independent.
Raw third-party Ranch mutation is outside this exclusion contract. Backend startup
can fail after handler initialization (for example, an occupied port); runtime
startup is not a transaction that rolls back arbitrary handler effects.

Owned Cowboy setup qualifies Ranch **1.8.1** only. The optional package requirement
pins that version, and startup checks its version, required exports and child-spec
shape before handler/listener effects. Arbor uses its own real native callback
modules for listener, connection and acceptor roles; it delegates the qualified
Ranch `init` functions while preserving their actual OTP parent links and startup
acknowledgments. The owned listener's initial call identifies
Arbor.MCP.Server.HTTP.Cowboy.Owned, rather than `:ranch_listener_sup`. Future
Ranch versions need constructor qualification before widening this requirement.
Owned Bandit setup qualifies **Bandit 1.12.5** and **Thousand Island 1.5.0** only,
with optional exact package requirements and pre-effect version/export checks.
Arbor's real native supervisor, worker and acceptor callbacks register each
startup role before delegated Thousand Island initialization or socket work.
The owned listener's initial call identifies
Arbor.MCP.Server.HTTP.Bandit.Owned; its nested listener uses Arbor's worker
callback. Original native parent links and child IDs remain real, so
`ThousandIsland.listener_info/1` keeps its meaning. The HTTP option transformation
is adapted from the pinned Bandit implementation under its MIT license and
preserves admitted upstream option defaults and validation. Owned startup logs
retain the configured level/disabled setting but use fixed text without raw Plug
options. Borrowed Bandit listeners retain the stock constructor and logs.
Future backend versions require constructor qualification before widening the
package requirements.

Owned Bandit admits **1..128 acceptors** (upstream default **100**) and at most
**1,024** pending/active connection constructions across the runtime, including
cohort replacement. Fixed token/PID slots precede the ShutdownGuard mailbox;
unknown pending construction retains credit, and bound credit is reaped only
after actual child DOWN. A saturated/stalled registration path fails closed
before socket/request processing through the backend's max-children path.
Connections use one finite original constructor timeout from
`thousand_island_options[:genserver_options][:timeout]` (default **10,000 ms**,
maximum **4,294,967,295**); `:infinity` is rejected for owned constructors.
Native `num_connections` still has its upstream meaning, including `:infinity`,
subject to this independent runtime cap. Each future connection registers before
upstream handler initialization/accepted socket work. These limits bound Arbor's
PID/control obligations; native socket buffers and other host/library data are
separate. Borrowed Bandit constructors retain upstream options and lifetimes.

The VM-lifetime Cowboy claim authority admits at most **128** reference domains
and **128** controls before its mailbox. Each retained reference is limited to
**4,096 bytes** and each control to **8,192 bytes**, including referenced binary
and closure storage measured by the managed retained-term policy. Controls use
original finite deadlines, detached admitted terms, token-only coalesced wakes
and abandoned-reply cleanup. A failed owned constructor keeps its claim until
all registered startup roles are dead and the captured Ranch server acknowledges
settlement. Cleanup authenticates the lease marker and actual native role PIDs,
then deletes only unchanged exact owned setup objects. Partial, untagged or
externally replaced metadata quarantines that reference's bounded claim until
VM restart; it cannot authorize deletion of a host replacement's objects.
Timed-out borrowed constructors also retain exclusion until actual constructor
and Ranch-server receipts, and Arbor never deletes their host-owned metadata.
These are bounded retained obligations, not proof that a stalled host settles
within the API deadline. Capacity exhaustion returns an explicit error.

Authority/Ranch-server loss fails new constructors closed and retires live owned
endpoints. The authority does not restart empty after failure; there is no unsafe
library reset shortcut. A host must restart the VM to reestablish that authority.
Borrowed listeners remain host-owned. Normal service/execution-cohort replacement
under a healthy root may create a new listener after the previous registered
roles and metadata settle, using that replacement's original startup cutoff.
Unexpected listener failure retires the whole root instead.

For Bandit, add `{:bandit, "== 1.12.5"}` and select it explicitly:

```elixir
{:ok, root} = Arbor.MCP.Server.Runtime.start_link(
  handler: MyHandler,
  transport: :http,
  http: [adapter: :bandit, port: 4000,
         listener_options: [startup_log: false]]
)
{:ok, %{listener: listener, adapter: :bandit}} =
  Arbor.MCP.Server.Transport.http_listener(root)
{:ok, {_address, port}} = ThousandIsland.listener_info(listener)
:ok = Arbor.MCP.Server.Runtime.stop(root)
```

Bandit rejects `:ranch_ref`. Neither constructor accepts backend Plug/dispatch
replacement, custom handler/transport modules, an owned Cowboy borrowed `:socket`,
or Thousand Island supervisor options: those would bypass the fixed owned listener boundary. Mount the MCP
Plug in a host-managed listener for custom transports or listener supervision.

## An existing runtime with a borrowed listener

The lower-level `start_http_server/4` retains its listener-PID return shape and
requires `:runtime`. The initialized runtime must use the matching handler.

```elixir
{:ok, runtime} = Arbor.MCP.Server.Runtime.start_link(
  handler: MyHandler,
  transport: :mounted_http,
  name: MyApp.MCPRuntime
)
{:ok, listener} = Arbor.MCP.Server.Transport.start_http_server(
  MyHandler, %{name: "compatibility-argument", version: "2.0.0"}, [],
  runtime: runtime,
  http_adapter: :cowboy,
  port: 4000,
  ranch_ref: MyApp.MCPListener
)
:ok = Arbor.MCP.Server.Transport.stop_http_server(MyApp.MCPListener)
```

This listener belongs to its existing backend supervision/caller, and its
lifetime is independent of the borrowed runtime. Stopping the runtime leaves
the listener alive; subsequent MCP requests fail when the runtime is unavailable.
Stopping the listener leaves the runtime alive. For borrowed Cowboy startup,
the absent/false reference keeps `Arbor.MCP.HttpPlug.HTTP` and an already-started
reference keeps the existing listener-PID result. Distinct listeners require
distinct references. Borrowed Bandit startup returns its supervisor linked to
the helper's caller. Hosts retain the backend's constructor contract for these
borrowed lifetimes; the runtime's initialization deadline does not own them.

## Options, stores and shutdown

Top-level `:port`, `:host` and Cowboy `:ranch_ref` replace the corresponding
outer listener options. Bandit retains its upstream Thousand Island semantics:
a nested `thousand_island_options[:port]` takes precedence over the outer port,
and nested transport options precede the appended outer IP option. Avoid
conflicting binding options; Host/Origin defaults derive from the outer binding. Localhost binds retain the Host/Origin allow-list defaults.
CORS stays disabled by default. `:legacy_http_sse` stays disabled by default;
the removed server aliases `:sse_enabled` and `:use_sse` return explicit errors.
These removals do not change the HTTP client's separate `:use_sse` option.
`handler_opts` stays static/function/MFA request application context, never
per-request handler initialization. Configure callback timeouts on the root with
`:request_timeout_ms`; the constructor rejects `:handler_call_timeout`.

Explicit `:http` and `:mounted_http` runtimes enable unnamed owned ETS sessions
and resource-subscription services in legacy-capable protocol modes. Explicit
service descriptors or `false`/`nil` win; `:modern_only` does not enable these
services. Generic runtimes retain their opt-in session defaults. Replay stays
opt-in. Configure addressed `:services`; raw global session/replay/registry
options are rejected. This checkpoint does not qualify non-ETS runtime sessions;
standalone DETS remains a separate API.

A missing selected package returns
`{:error, {:missing_http_listener_dependency, backend, package}}`; unsupported
selection returns `{:error, {:unsupported_http_adapter, selection}}`.
`Server.Transport.list_transports/0` reports each backend independently.

Stop an owned endpoint with `Runtime.stop/1`, `Transport.stop_server/1`, or its
parent supervisor. The runtime's overall shutdown guard covers proven owned
children, with the usual qualification for forced interruption of callbacks.
Stop a borrowed listener with `stop_http_server/2`: Cowboy accepts its Ranch
reference or global Ranch listener PID, and Bandit accepts its returned PID.
Both use positive finite `:http_shutdown_timeout` (default `5_000`, maximum
`4_294_967_295`). A timeout
returns `{:error, {:http_listener_operation_timeout, backend, :shutdown}}` and
does not certify physical listener/connection closure. Retain the identity and
complete or check cleanup through its owning host.

## Mounting in an existing host

```elixir
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

The named runtime owns handler state and configured services. The Phoenix/Plug
host owns its listener, sockets and TLS. Use the same authenticated mounted
options and request-owned output rules for either optional standalone backend.
The constructor/wrapper migration is a separate checkpoint from remaining live
HTTP subscriptions and reverse-helper convergence; those remain release gates
until their own implementation and physical-ACK qualification land.
