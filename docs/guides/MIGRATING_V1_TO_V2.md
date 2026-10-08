# Migrating from ExMCP 1.x to ArborMCP 2.x and ArborACP 1.x

The final facade boundary removes hidden Client parsing/request/startup helpers,
DSL argument validators, Result normalizers, Runtime configured-startup/ingress
hooks and RPC generic actor calls. They were implementation exports, rather than
supported user operations. Use Client protocol/scoped-connection operations,
Handler callbacks and Result constructors, Runtime's documented advanced
operations, or RPC Subprocess/FramedStream operations. Internal modules are not
application extension APIs.

DSL declarations now fail on duplicate names/instructions/options, unknown
options, stray instructions and metadata unsupported by that primitive. Keep
one declaration per parameter/argument, one scalar instruction per block and
only documented `use` options. Tool/prompt identifiers replace ignored `name`
metadata; prompts do not accept `annotations`.

`Arbor.MCP.disconnect/1` still returns `:ok` for a successful or already-stopped
client, but now returns cleanup errors instead of suppressing them.
`Arbor.MCP.ping/2` reports `{:error, {:cleanup_failed, reason, connectivity_result}}`
if its temporary client's cleanup cannot be confirmed. Handle these results;
process death alone does not certify physical IO cleanup.

ExMCP 1.x splits into **ArborMCP** for MCP and **ArborACP** for ACP, with
independently installable ArborRPC and optional ArborACP adapter packages.
This guide covers the prepared ArborMCP `2.0.0-rc.2` and ArborACP, ArborRPC
and adapter `1.0.0-rc.1` combination. Library versions are independent; ACP
protocol versions are a separate upstream concern.

| Library name | Hex package / OTP application | Elixir module namespace |
| --- | --- | --- |
| ArborMCP | `arbor_mcp` / `:arbor_mcp` | `Arbor.MCP.*` |
| ArborACP | `arbor_acp` / `:arbor_acp` | `Arbor.ACP.*` |
| ArborACP adapters | `arbor_acp_adapters` / `:arbor_acp_adapters` | `Arbor.ACP.Adapters.*` |
| ArborRPC | `arbor_rpc` / `:arbor_rpc` | `Arbor.RPC.*` |

Library names in prose use ArborMCP, ArborACP and ArborRPC. Code uses the dotted module
namespaces above; dependency and application configuration uses the lowercase
package names.

**RC status:** the original four `2.0.0-rc.1` packages are published. Their
replacement versions above are prepared but unpublished; the dependency examples
below apply after replacement publication. Continuous 48-hour qualification is still incomplete: the
latest continuous harness attempt reached the documented request-ID capacity of
a persistent test/BEAM peer. That finite limit remains the intended API
contract. An RC is for downstream testing; it does not establish stable
release or sustained-run qualification.

## Canonical role entrypoints

Use `Arbor.MCP.Client` for connections and client operations, and
`Arbor.MCP.Server` for server startup, supervision, controls, statistics and
shutdown. `Server.Handler` defines callbacks; `Server.DSL` adds declarations.
Plain and generated handlers share `Server.start_link/1` and return a runtime
supervisor for BEAM, test, stdio and HTTP. The canonical default is `:beam`.

```elixir
children = [{Arbor.MCP.Server, handler: MyHandler, transport: :beam}]
{:ok, client} = Arbor.MCP.Client.connect({:beam, server: server})
{:ok, response} = Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello"})
text = Arbor.MCP.Response.text_content(response)
{:ok, status} = Arbor.MCP.Client.status(client)
{:ok, statistics} = Arbor.MCP.Server.stats(server)
```

Root client operations remain compatibility wrappers with their existing
behavior. They are not interchangeable with similarly named Client methods:

| Existing root call | Canonical choice and behavior |
| --- | --- |
| `Arbor.MCP.connect/2` | `Client.connect/2`; accepts ClientConfig, URL or transport spec. The root retains legacy bare-command parsing. Neither currently implements transport-list fallback. |
| `Arbor.MCP.call/4` | `Client.call_tool/4` / `call/4` keep the full Response; `Client.call_content/4` deliberately extracts and normalizes tool errors. |
| `Arbor.MCP.tools/2` | `Client.list_tools/2` / `tools/2` keep the page; `Client.tool_definitions/2` extracts the list. |
| `Arbor.MCP.resources/2` / `read/3` | `Client.list_resources/2` / `read_resource/3` keep full responses; `resource_definitions/2` / `read_content/3` extract. |
| `Arbor.MCP.disconnect/1` | `Client.stop/1` terminates; `Client.disconnect/1` retains the disconnected process. |
| `Arbor.MCP.ping/2` | `Client.probe/2` checks a temporary connection with scoped cleanup; `Client.ping/2` operates on an existing client. |
| `Arbor.MCP.status/1` | `Client.status/2` returns tagged status or timeout/unavailable errors; `status!/2` raises explicitly. |

`Client.all_tools/2`, `all_resources/2`, `all_resource_templates/2` and
`all_prompts/2` explicitly collect lists across pages. Their defaults are a
30-second total timeout, 64 pages, 10,000 items and 8 MiB of cumulative response
terms. The final options can lower or raise those finite limits, and `:cursor`
can select a starting page. Cyclic cursors and exceeded limits return errors;
page metadata is discarded. Keep `list_*` when you need the complete page.

`Arbor.MCP.start_server/1` retains its legacy `:test` default and now routes
explicit stdio/HTTP correctly. New code should use `Server.start_link/1` with
an explicit transport. `Server.stop/2` uses Runtime's existing overall shutdown
budget and ownership receipts; it does not stop a borrowed Phoenix listener or
borrowed IO devices. A supervisor still applies its child restart policy.

ArborACP follows the same role convention with `Arbor.ACP.Client` and
`Arbor.ACP.Agent` (ACP's protocol term). Root ACP startup functions remain thin
shorthand. `Agent.stop/3` now accepts a reason and timeout like `Client.stop/3`;
the previous `Agent.stop(agent, timeout: ...)` form remains supported. Vendor
adapters supply implementations under `Arbor.ACP.Adapters.*`; session workflows
stay in the core Client. ArborRPC retains resource APIs such as
`Subprocess.open/close` and its framing/envelope modules.

## 1. Replace the dependency with the packages you use

Remove `{:ex_mcp, ...}` from `mix.exs`. For an MCP application, use an exact RC
pin so downstream test results are reproducible:

```elixir
defp deps do
  [
    {:arbor_mcp, "== 2.0.0-rc.2"}
  ]
end
```

Choose additional packages by ownership:

| What your application uses | Direct dependency |
| --- | --- |
| MCP clients, handlers, tools, resources or prompts | `{:arbor_mcp, "== 2.0.0-rc.2"}` |
| Native ACP agents/controllers or the generic adapter contract | `{:arbor_acp, "== 1.0.0-rc.1"}` |
| Built-in Claude, Codex, Pi or ZCode adapters | `{:arbor_acp_adapters, "== 1.0.0-rc.1"}` |
| Shared JSON-RPC/framing/subprocess APIs called directly | `{:arbor_rpc, "== 1.0.0-rc.1"}` |

MCP and ACP each bring in `arbor_rpc`; neither brings in the other protocol.
The adapter bundle brings in ACP and RPC. Native ACP users do not need the
bundle, and vendor CLI executables remain separate prerequisites. Add a direct
RPC dependency only when your code uses its API. A compatible prerelease range
is `~> 2.0.0-rc.2` for MCP or `~> 1.0.0-rc.1` for the new packages;
an ordinary stable-only constraint does not select these RCs.

For a normal Hex consumer, unset development overrides such as
`ARBOR_RPC_PATH` and `ARBOR_V2_LOCAL`; do not copy isolated QA build/cache
settings into the application. Then resolve dependencies, review the lockfile
changes and compile your application normally.

ArborMCP requires Elixir 1.17 and Erlang/OTP 27 or newer; protocol output uses
OTP's JSON encoder. On qualified macOS/Darwin and Linux platforms, source
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

ArborMCP version `2.0.0-rc.2` and the MCP wire revision are separate identifiers.
The latest stable wire revision in this source is `2026-07-28`.
`:prefer_modern` permits evidence-based legacy fallback; `:modern_only` and
`:legacy_only` select an era explicitly. Retained legacy Roots, Sampling and
protocol Logging APIs still serve pinned legacy revisions.

## Public operation contracts in the replacement candidate

Canonical MCP Client operations return `{:ok, %Arbor.MCP.Response{}}` by default,
or `{:ok, wire_map}` with `format: :map`. A tool result with `isError: true`
is still a successfully delivered protocol result at this layer. Inspect
`Response.error?/1` and choose an explicit projection such as
`Response.text_content/1`, `all_text_content/1` or `structured_content/1`.
`Response.to_raw/1` preserves decoded response fields, pagination, structured
values, metadata, content extensions and false/null field presence. Locally
constructed responses use canonical `_meta` and `structuredContent` keys and
retain `isError: false`. The unused `Response.to_test_map/1` export is removed;
use `to_raw/1` or an application-owned projection.

The top-level convenience APIs keep text/list extraction by default.
`Arbor.MCP.read/3` recognizes standard resource `contents`; text entries are
joined with newlines, and a nontext-only result is returned intact rather than
`nil`. `parse_json: true` parses extracted text. Supply `format: :map` or
`:struct` to `read/3`, `tools/2`, `resources/2` or `call/4` for a complete result,
including cursors. Format selection cannot be combined with `parse_json: true`
or `normalize: true`. `call/4` with `normalize: false` returns a complete
Response struct by default; it never meant a raw map. Normalized tool failures
now return `{:error, %Arbor.MCP.Error.ToolError{reason: full_result}}`.

The facade forwards the documented request controls, including tool progress,
metadata and idempotency keys, instead of discarding them. Unsupported facade
options raise `ArgumentError`. MCP request timeouts must be finite non-negative
milliseconds; a local timeout returns `{:error, :timeout}` in either response
format. A server JSON-RPC error remains a protocol error.

Operational inspection uses tagged success consistently:

```elixir
{:ok, status} = Arbor.ACP.Client.status(client, timeout: 1_000)
{:ok, status} = Arbor.ACP.Agent.status(agent, timeout: 1_000)
{:ok, statistics} = Arbor.MCP.Server.stats(runtime)
{:ok, statistics} = Arbor.RPC.Subprocess.stats(handle)
```

Each also has a `status!` or `stats!` counterpart for explicit value-or-raise
inspection. Pure constructors, predicates and response accessors keep bare
values. Handle operational failure with the tagged API.

ACP setters accept a final keyword list: `set_mode/4`, `set_model/4` and
`set_config_option/5`, with `timeout: 30_000` by default. Existing shorter
arities remain available. Caller timeout returns `{:error, :timeout}`; it does
not certify cancellation or extend the separately bounded pending-request
lifetime. `Client.cancel/2` and `cancel_request/2` return `:ok` when queued,
without confirming that the remote agent has acted.

ACP `Client.disconnect/1` closes the transport and retains the client process.
Use `Client.stop(client, :normal, timeout: 5_000)` to clean up and wait for
termination. The one finite caller budget covers both phases; known cleanup
failure remains an error even if the process exits. Already-stopped clients
return `:ok`. `Agent.stop/2` also accepts a finite timeout. Start functions
return linked OTP processes; supervise long-lived clients/agents and apply the
parent's restart policy deliberately.

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

### ACP prompt results and temporary connections

`Arbor.ACP.Client.prompt/4` now returns the peer's JSON result unchanged. The
original published RC synthesized `result["text"]` from streamed updates.
Migrate that usage to `Client.prompt_text/4`, which returns
`{:ok, %{result: peer_result, text: text, truncated?: boolean}}`. Check the
truncation flag; message collection has a finite UTF-8 byte cap and excludes
thought chunks. A collecting prompt cannot overlap another prompt in its session.

`Client.with_connection/2,3` opens an initialized temporary ACP client, runs its
callback in the caller, and wraps its value after cleanup. Positive finite
startup and cleanup budgets cover handler/transport initialization, negotiation
and shutdown; a guardian also handles abrupt caller death. Continue to supervise
long-lived clients. See ArborACP's `docs/ACP_GUIDE.md` for complete examples.
