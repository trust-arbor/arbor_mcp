# Migrating from ExMCP 1.x to ArborMCP and ArborACP 2.x

ExMCP 1.x splits into **ArborMCP** for MCP and **ArborACP** for ACP, with
independently installable ArborRPC and optional ArborACP adapter packages.
This guide covers the coordinated `2.0.0-rc.1` APIs at MCP
`eac1ddfa` and ACP/RPC/adapters `03cd82a9`.

| Library name | Hex package / OTP application | Elixir module namespace |
| --- | --- | --- |
| ArborMCP | `arbor_mcp` / `:arbor_mcp` | `Arbor.MCP.*` |
| ArborACP | `arbor_acp` / `:arbor_acp` | `Arbor.ACP.*` |
| ArborACP adapters | `arbor_acp_adapters` / `:arbor_acp_adapters` | `Arbor.ACP.Adapters.*` |
| ArborRPC | `arbor_rpc` / `:arbor_rpc` | `Arbor.RPC.*` |

Library names in prose use ArborMCP, ArborACP and ArborRPC. Code uses the dotted module
namespaces above; dependency and application configuration uses the lowercase
package names.

**RC status:** publication is pending. The dependency examples below apply once
RC1 is published. Continuous 48-hour qualification is still incomplete: the
latest continuous harness attempt reached the documented request-ID capacity of
a persistent test/BEAM peer. That finite limit remains the intended API
contract. An RC is for downstream testing; it does not establish stable
release or sustained-run qualification.

## 1. Replace the dependency with the packages you use

Remove `{:ex_mcp, ...}` from `mix.exs`. For an MCP application, use an exact RC
pin so downstream test results are reproducible:

```elixir
defp deps do
  [
    {:arbor_mcp, "== 2.0.0-rc.1"}
  ]
end
```

Choose additional packages by ownership:

| What your application uses | Direct dependency |
| --- | --- |
| MCP clients, handlers, tools, resources or prompts | `{:arbor_mcp, "== 2.0.0-rc.1"}` |
| Native ACP agents/controllers or the generic adapter contract | `{:arbor_acp, "== 2.0.0-rc.1"}` |
| Built-in Claude, Codex, Pi or ZCode adapters | `{:arbor_acp_adapters, "== 2.0.0-rc.1"}` |
| Shared JSON-RPC/framing/subprocess APIs called directly | `{:arbor_rpc, "== 2.0.0-rc.1"}` |

MCP and ACP each bring in `arbor_rpc`; neither brings in the other protocol.
The adapter bundle brings in ACP and RPC. Native ACP users do not need the
bundle, and vendor CLI executables remain separate prerequisites. Add a direct
RPC dependency only when your code uses its API. A compatible prerelease range
is `~> 2.0.0-rc.1`; an ordinary stable-only constraint does not select this RC.

For a normal Hex consumer, unset development overrides such as
`ARBOR_RPC_PATH` and `ARBOR_V2_LOCAL`; do not copy isolated QA build/cache
settings into the application. Then resolve dependencies, review the lockfile
changes and compile your application normally.

The Elixir floor is 1.17. On qualified macOS/Darwin and Linux platforms, source
installation requires a **C17 compiler**, including HTTP-only or BEAM-only
applications, because the transitive RPC package builds its helper. `CC`
selects one compiler executable. Source archives contain C source, not a
prebuilt helper. An assembled OTP release includes the built helper and needs
no compiler at runtime. Windows native subprocess operations are unsupported.

## 2. Move code and configuration to its owner

| 1.x reference | 2.x owner |
| --- | --- |
| `ExMCP` and MCP-only `ExMCP.*` | `Arbor.MCP` / `Arbor.MCP.*`, application `:arbor_mcp` |
| `ExMCP.ACP.*` | `Arbor.ACP.*`, application `:arbor_acp` |
| Vendor adapter implementations | `Arbor.ACP.Adapters.*`, application `:arbor_acp_adapters` |
| Shared framing, JSON-RPC and subprocess mechanisms | `Arbor.RPC.*`, application `:arbor_rpc` |
| `ExMCP.start_acp_client(opts)` | `Arbor.ACP.start_client(opts)` |

Update aliases, imports, behaviours, child specifications, dynamic module
references and module-valued configuration. Move `config :ex_mcp, ...` keys to
their owning application; host Logger and Phoenix settings stay host-owned.
A dependency's `config/config.exs` is not automatically loaded by its consumer.
Codex's `:codex_legacy_auth_methods` setting remains under `:arbor_acp` even
though its implementation is in the optional adapter bundle.

Do not rename persisted or wire identifiers as part of a source namespace
replacement. Legacy ACP `_meta.ex_mcp`, `_ex_mcp.pi/*`, existing generated IDs,
Pi's `~/.ex_mcp/pi/session-map.json` and the OAuth credential storage identity
are retained. See the [behavior migration record](../V2_NON_SYMBOL_MIGRATION.md)
for the complete ownership and persistence inventory.

## 3. Keep clients on the public API

The MCP client shape remains familiar:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["mcp-server"],
    protocol_mode: :prefer_modern
  )

{:ok, tools} = Arbor.MCP.Client.list_tools(client, format: :map)
{:ok, result} =
  Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello"}, format: :map)

:ok = Arbor.MCP.Client.stop(client)
```

For an agent that speaks ACP natively, replace the old MCP-owned ACP facade:

```elixir
{:ok, client} = Arbor.ACP.start_client(command: ["gemini", "--acp"])
{:ok, %{"sessionId" => session_id}} =
  Arbor.ACP.Client.new_session(client, "/absolute/path/to/project")

{:ok, result} = Arbor.ACP.Client.prompt(client, session_id, "Explain this project")
Arbor.ACP.Client.disconnect(client)
```

Library version `2.0.0-rc.1` and the MCP wire revision are separate identifiers.
The latest stable wire revision in this source is `2026-07-28`.
`:prefer_modern` permits evidence-based legacy fallback; `:modern_only` and
`:legacy_only` select an era explicitly. Retained legacy Roots, Sampling and
protocol Logging APIs still serve pinned legacy revisions.

## 4. Initialize each server once under a Runtime

Replace the retired Tools DSL with a handler plus the current DSL:

```elixir
defmodule MyApp.Echo do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "echo", version: "1.0.0"

  tool "echo", "Echo the supplied message" do
    param :message, :string, required: true

    run fn %{message: message}, state ->
      {:ok, ToolResult.text(message), state}
    end
  end
end
```

`ToolResult` is the DSL alias for `Arbor.MCP.Server.Result`. Its helpers return
complete result maps. Raw handlers can implement callbacks directly; for
example `handle_list_tools/2` returns
`{:ok, descriptors, next_cursor, state}`, and `handle_call_tool/3` returns
`{:ok, result, next_state}` or `{:error, reason, next_state}`.

For a Phoenix mount, start the Runtime before the Endpoint in your application's
supervision tree:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   handler: MyApp.Echo,
   name: MyApp.MCPRuntime,
   transport: :mounted_http,
   request_timeout_ms: 30_000},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

Pass initialization data with root `:handler_args`. The returned PID and name
identify a supervisor, not the handler GenServer. Stateful callbacks are
serialized through the Runtime; they run in managed callback Tasks. Keep
long-lived resources under supervision and do not depend on a callback running
in the same process as initialization. Use `Arbor.MCP.Server.call/2,3` and
`cast/2` for custom handler controls instead of raw `GenServer.call/cast` on the
root. Use public Runtime APIs rather than inspecting private process state.

For a stdio server, supervise
`{Arbor.MCP.Server.StdioServer, module: MyApp.Echo}` instead. Keep diagnostic
output off protocol stdout. The host owns logging policy, for example:

```elixir
config :logger, :default_handler, config: [type: :standard_error]
```

Transport startup no longer silently changes VM-wide Logger policy.

## 5. Mount HTTP with an explicit Runtime

In your existing Phoenix router:

```elixir
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

Replace old `handler:`-only mounts and the retired `Transport.HTTPServer` /
`HTTPServerWithVersion` wrappers. `HttpPlug.init/1` requires `:runtime`; it does
not start global registries or initialize a handler on every request.
`:handler_opts` is per-request application context, not handler initialization.
Move `:handler_call_timeout` to root `:request_timeout_ms`.

Phoenix owns its listener, TLS configuration and socket lifetime. Stopping the
MCP Runtime does not stop that host listener. Use the host supervision tree to
manage it. Typical Runtime mounts do not require manually starting the old
global session, replay, progress or subscription owners. HTTP legacy-capable
profiles have owned ETS session/subscription defaults; explicit service
configuration wins, modern-only profiles differ and replay is opt-in.

For a standalone listener owned by the Runtime, add the qualified Cowboy host
dependencies `{:plug_cowboy, "~> 2.7"}` and `{:ranch, "== 1.8.1"}`, then use:

```elixir
{Arbor.MCP.Server.Runtime,
 handler: MyApp.Echo,
 name: MyApp.MCPRuntime,
 transport: :http,
 http: [adapter: :cowboy, host: {127, 0, 0, 1}, port: 4000]}
```

Cowboy and Bandit are optional host dependencies; MCP clients, stdio and BEAM
use need neither. Owned Bandit currently requires exact Bandit `1.12.5` and
Thousand Island `1.5.0`. Follow the [HTTP listener guide](../HTTP_LISTENERS.md)
for constraints and owned/borrowed shutdown rules rather than broadening the
backend versions during migration.

To retain the 2024 HTTP+SSE server transport, enable `:legacy_http_sse`
explicitly on the mount/listener configuration. Removed server aliases
`:sse_enabled` and `:use_sse` are rejected. The HTTP **client**'s separate
`:use_sse` option is retained.

## 6. Replace removed helpers by their current contracts

| Old usage | Migration |
| --- | --- |
| `Server.Tools` / `Tools.Simplified`, including `deftool` | `Server.Handler` + `Server.DSL`; use `tool` declarations as above. |
| Global Tools Registry, Tool/Builder structs | Handler-owned descriptors and list/call callbacks. There is no global-registry compatibility shim. |
| `Tools.Helpers` result helpers / `Tools.ResponseNormalizer` | `Arbor.MCP.Server.Result`; return complete result maps and use modern `structuredContent`, not `structuredOutput`. |
| Schema constructors and AST evaluation | Literal JSON Schema or DSL declarations. `Content.SchemaPolicy.compile/1,2` and `validate/2,3` return tagged results; old default insertion/coercion is not automatic. |
| `VersionNegotiator.build_capabilities/1` | Return capabilities/server information from `handle_initialize/2` and let dispatch normalize it; a capability-only map is not the old complete initialize wrapper. |
| Unimplemented image resize/compress/thumbnail helpers | Do media processing in your application, then use supported content constructors. Removed `:auto_resize` / `:quality` options are rejected. |
| Raw subprocess Port access or unmanaged cleanup | Opaque `Arbor.RPC.Subprocess` handles, public framing/ACK APIs and typed cleanup receipts. |

The [API migration inventory](../V2_API_MIGRATION.md) lists every accepted
retirement and owner move. Renaming a function is insufficient when its result
shape or lifecycle changed; test the consumer's real result/wire behavior.

## 7. Plan finite connection lifetimes and handle pressure

For a `HandlerServer` test/BEAM peer, `:max_request_ids` defaults to **10,000
distinct request IDs per connection**. IDs remain recorded after replies to
reject reuse; there is no automatic moving window or completion-based reset.
At capacity, a new request fails with a `ProtocolError` carrying
`request_id_capacity_exceeded`. A replacement peer connection starts a fresh
ID scope and cancels outstanding work for the retired connection.

Choose a finite capacity appropriate to the workload and handle connection
turnover at public lifecycle boundaries. Raising `:max_request_ids` alone does
not establish bounded whole-run resource use or a successful 48-hour run. HTTP session and
replay capacities have their own contracts.

For a test/BEAM peer, supported turnover stops the old Client and starts a new
Client against the retained HandlerServer/Runtime. `Client.connect(spec, opts)`
creates a new Client; it does not reconnect an existing Client PID after
`disconnect/1`. Retired-scope pending work is canceled when the new peer is installed.

Admission, output pressure, timeout and cleanup errors remain explicit. A
timeout is not proof that an entered side effect was rolled back, and a native
write ACK is not proof that the remote program consumed the bytes. Preserve
original deadlines and avoid blindly replaying non-idempotent work.

## 8. Cut over with a cold restart and retain a rollback path

1. Save the working 1.x application release, lockfile, configuration and any
   application-owned durable data before changing dependencies. Keep a separate
   build of the new release; do not replace a running VM's modules in place.
2. Compile the application against the selected v2 packages and review every
   dependency and configuration change. Test it with representative traffic,
   finite peer turnover, cancellation, and normal shutdown before routing users
   to it. Verify native helper installation on the target OS/architecture.
3. Stop admitting new work to the retiring application instance, drain entered
   operations within an explicit deadline, and reconcile any side effects whose
   outcome is unknown. Stop its Clients and Runtimes through their public APIs.
   A wait timeout does not make an operation safe to replay.
4. Start a fresh VM/application release with the v2 supervision tree. Create new
   runtime references and peer connections; do not deserialize old runtime
   handles, leases, tickets, in-flight requests or callback state into v2.
   Preserve documented wire/storage identities, but use a tested export/import
   or application recovery path for durable state; identity preservation is not
   a promise that every internal storage representation can be reused.
5. If rollback is needed, stop routing new work to v2, drain and reconcile it,
   then start the saved 1.x application release with its matching configuration,
   dependency lock and compatible data. Do not point 1.x blindly at state written
   by a changed application data model. Existing rollback protocol tests do not
   replace this application-specific rehearsal.

Hot code upgrade of 1.x process state into v2 is not supported. Whole-runtime
replacement creates new references even within v2; application supervision must
publish or resolve the replacement references. The maintained `ex_mcp` 1.x line
continues to receive applicable fixes and compatible minor releases; see the
[maintenance policy](https://github.com/trust-arbor/arbor_mcp/blob/codex/maintenance-1.x/docs/MAINTENANCE_POLICY.md).

## Consumer checklist

- Select only the protocol packages and optional adapters you use; pin RC1.
- Provide C17 at source-install time and verify the helper is in the release.
- Update module/application references while preserving wire/storage identities.
- Supervise one Runtime per server and give every HTTP mount its Runtime.
- Migrate removed helpers by result/schema/lifecycle semantics.
- Exercise startup, normal calls, pressure, peer turnover and public shutdown in
  your own application; report RC problems with the lockfile and platform.
