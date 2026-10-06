# Phoenix Integration Guide

Mount `Arbor.MCP.HttpPlug` through your Phoenix router and supervise one MCP
runtime separately from the host endpoint. The runtime initializes its handler
once and owns scheduled callbacks, bounded output and configured services. The
Phoenix request process owns its `Plug.Conn` and the host listener.

RC1 publication is pending. Until then, use a local `arbor_mcp`
checkout and set `ARBOR_RPC_PATH` to the sibling `arbor_rpc` package when fetching
dependencies. The released 1.x package remains `ex_mcp`. This guide describes
the Runtime mounting contract; see the [RC notes](V2_RELEASE_CANDIDATE.md) for
the qualified consumer scope and open stable-release gates.

## Dependencies

```elixir
# mix.exs, alongside your existing Phoenix dependencies
{:arbor_mcp, path: "../arbor_mcp"}
```

Use MCP's `codex/v2-migration` branch, not its still-1.x `master`, and the
separate ArborRPC `main` checkout. The [Quickstart](../getting-started/QUICKSTART.md)
shows the clone and path setup.

After publication, replace the path dependency with
`{:arbor_mcp, "== 2.0.0-rc.1"}` and remove the local RPC override. Source
installation still requires C17 even though Phoenix owns the listener.

Use your host application's HTTP adapter. A mounted plug does not require an
ArborMCP-owned Cowboy or Bandit listener. The consumer qualification fixture pins
Phoenix 1.8.15, whose package declares Elixir `~> 1.15`; that includes ArborMCP's
Elixir 1.17 minimum. Your application's own Phoenix, adapter and dependency
requirements still apply. This is a qualified consumer version, not a promise
that every Phoenix release works with every ArborMCP toolchain.

## Handler and runtime

A handler uses the same DSL as a standalone MCP server:

```elixir
defmodule MyApp.MCPHandler do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-phoenix-app", version: "1.0.0"

  @impl true
  def init(_application_opts), do: {:ok, %{calls: 0}}

  tool "search_posts", "Search blog posts" do
    param :query, :string, required: true
    param :limit, :integer, default: 10, minimum: 1, maximum: 50

    run fn %{query: query, limit: limit}, state ->
      posts = MyApp.Blog.search_posts(query, limit: limit)
      content = Enum.map(posts, &%{type: "text", text: &1.title})
      {:ok, %{content: content}, %{state | calls: state.calls + 1}}
    end
  end
end
```

Add a named runtime to the application supervisor before the endpoint:

```elixir
children = [
  # Your application's other children...
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   transport: :mounted_http,
   handler: MyApp.MCPHandler,
   handler_args: [],
   request_timeout_ms: 10_000,
   services: [replay_cache: []]},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

`handler_args` supplies application-level `init/1` arguments. `init/1` is not run
for every HTTP request. Stateful callbacks are serialized by the runtime; use
request context for identity and authorization, rather than putting the current
HTTP user into persistent handler state. The explicit `:mounted_http` mode selects legacy-capable runtime service defaults
for sessions and resource subscriptions; replay protection remains explicitly
configured above. A generic runtime keeps these services opt-in. Standalone
modern-only deployments should select only the services they use.

A supervised child follows its supervisor's restart policy. To leave it stopped,
terminate that child through its parent supervisor. `Runtime.stop/2` stops the
current runtime instance and its proven owned work; it does not stop the borrowed
Phoenix endpoint, socket pool or listener.

## Endpoint parser and router

Keep the host JSON parser before the router. Already parsed JSON is read from
`conn.body_params`; the plug does not require a second body read.

```elixir
# lib/my_app_web/endpoint.ex, before `plug MyAppWeb.Router`
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library()

plug MyAppWeb.Router
```

Mount the plug through `forward`:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  scope "/api" do
    forward "/mcp", Arbor.MCP.HttpPlug,
      runtime: MyApp.MCPRuntime,
      protocol_mode: :prefer_modern,
      path: "/mcp",
      allowed_hosts: ["mcp.example.com"],
      allowed_origins: ["https://app.example.com"]
  end
end
```

The public mount is `/api/mcp`. `forward` supplies relative `path_info` and the
mount prefix in `script_name`; the plug handles its mount root. `:path` is the
public option for the configured logical endpoint, defaulting to `/mcp`. That
configured value appears in `Context.current().endpoint`; it is not the Phoenix
mount prefix. HTTP correlation separately validates the actual mount identity.
The runtime name is resolved for each request, so the compiled router can remain
in place across runtime replacement.

Do not restrict this route to an `accepts` pipeline that excludes
`text/event-stream`. The same POST may return JSON or SSE, and legacy GET uses
SSE. Keep browser CORS, permitted origins, host validation and authentication
consistent with the host deployment. A request without `Origin` still needs
appropriate host and authentication policy.

`HttpPlug` responds and halts the connection. An unconditional endpoint plug
would consume unrelated routes. If OAuth protected-resource discovery is enabled,
mount `Arbor.MCP.Plugs.ProtectedResourceMetadata` at the host root for
`/.well-known/oauth-protected-resource/api/mcp`; the router forward cannot see
that host-root path.

## Request identity and application context

Authenticate in a host plug before the forward. Resolve trusted identity from
verified server-side facts, rather than from tool arguments or caller-supplied
identity headers. For example, after your authentication plug assigns
`:current_user` and `:current_tenant`:

```elixir
defmodule MyAppWeb.MCPContext do
  def application(conn, request) do
    %{
      user: conn.assigns[:current_user],
      tenant: conn.assigns[:current_tenant],
      request_id: request["id"]
    }
  end

  def principal(conn, _request, _token_info) do
    case conn.assigns[:current_user] do
      nil -> nil
      user -> to_string(user.id)
    end
  end

  def tenant(conn, _request, _token_info) do
    case conn.assigns[:current_tenant] do
      nil -> nil
      tenant -> to_string(tenant.id)
    end
  end
end
```

Add these options to the forward after your host authentication pipeline:

```elixir
[
  handler_opts: {MyAppWeb.MCPContext, :application, []},
  principal_id: {MyAppWeb.MCPContext, :principal, []},
  tenant_id: {MyAppWeb.MCPContext, :tenant, []}
]
```

For runtime mounting, `handler_opts` becomes the callback's per-request
`Arbor.MCP.Server.Context.current().application_context`. A static value, one-arity `conn` function,
two-arity `conn, request` function or MFA is supported. The application-context
MFA receives `[conn, request | extra_args]`; identity MFAs receive
`[conn, request, token_info | extra_args]`. A router can safely store these MFA
options without embedding a closure in its compiled configuration.

Use the context inside the callback:

```elixir
alias Arbor.MCP.Server.Context

# Inside a tool callback:
context = Context.current()
user = context.application_context.user
MyApp.Authorization.authorize!(user, :read_posts)

if Context.progress_token() do
  :ok = Context.report_progress(1, 2, "Searching")
end
```

Context and its origin proof are invocation-scoped. Retain neither the context
nor a `Plug.Conn` as handler state for a later request. Successful callbacks keep
admitted effects valid under their original cutoff; cancellation, expiry and
retired peers suppress queued effects. Completed callback state is not rolled
back by a later advisory cancellation.

## Modern HTTP requests

`:prefer_modern` accepts both eras. Modern requests use protocol `2026-07-28`,
per-request capability metadata and routing headers. They do not use a transport
session or an `initialize` handshake.

```bash
curl http://localhost:4000/api/mcp \
  -H 'Host: mcp.example.com' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'MCP-Method: tools/call' \
  -H 'MCP-Name: search_posts' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_posts","arguments":{"query":"elixir"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

The response contains a tool result with `content`; wire tool descriptors use
`inputSchema`, not `input_schema`. The DSL validates declared parameters and
inserts explicit defaults before calling the tool. Raw dynamic handlers must
provide their own compiled validation/default policy.

Progress and logs travel on the originating POST's SSE response when that
request selects SSE and supplies the required metadata. They are not delivered
through a separate modern `EventSource` connection. Modern GET and DELETE return
405. Use the ArborMCP client or an SDK that implements the selected protocol
era for full request/response-stream handling.

Anonymous cancellation sent from another POST is advisory and cannot authorize
cross-request cancellation. Closing the originating response stream can cancel
its own pending work. Cross-POST cancellation requires a matching trusted
principal/tenant, actual endpoint and request scope. Returning 202 for a
notification is not proof that a target was found or canceled.

## Legacy sessions and SSE

Legacy clients first POST `initialize` with a supported legacy revision, such
as `2025-11-25`, then retain the returned `Mcp-Session-Id`. Send the negotiated
`MCP-Protocol-Version` and that session ID on later session requests.

```bash
curl -i http://localhost:4000/api/mcp \
  -H 'Host: mcp.example.com' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}'

# Substitute the actual returned session ID:
curl http://localhost:4000/api/mcp \
  -H 'Host: mcp.example.com' \
  -H 'Content-Type: application/json' \
  -H 'Mcp-Session-Id: SESSION_ID' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl http://localhost:4000/api/mcp \
  -H 'Host: mcp.example.com' \
  -H 'Accept: text/event-stream' \
  -H 'Mcp-Session-Id: SESSION_ID' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -H 'Last-Event-ID: LAST_RECEIVED_EVENT_ID'

curl -X DELETE http://localhost:4000/api/mcp \
  -H 'Host: mcp.example.com' \
  -H 'Mcp-Session-Id: SESSION_ID' \
  -H 'MCP-Protocol-Version: 2025-11-25'
```

GET replay uses the runtime's addressed session service. Disconnecting an SSE
stream preserves the initialized session for reconnect; successful DELETE ends
that session and its stream without stopping the host listener. An unknown or
foreign replay cursor fails before an SSE response is started. The deprecated
2024-11-05 `/sse` and `/message` aliases require explicit
`legacy_http_sse: true`; they are a compatibility flow, not the modern transport.

The curl examples set `Host` to match the router's allowlist while connecting
to a local development socket. Use the actual deployment host in production.
Omit `Last-Event-ID` for a first GET; substitute only a cursor received from
this initialized session when reconnecting.

## Ownership, pressure and deployment

The runtime prepares bounded output before committing handler state. The HTTP
request process remains borrowed: the library does not kill the host process or
adopt its listener. A blocked or uncertain socket write remains charged until
actual completion or confirmed socket loss. A delivery ACK means the adapter
write returned, not that the client consumed the response. An in-flight write
may be irreversible; timeout does not promise rollback, retry or remote cleanup.

Set runtime input/output limits and finite request/output/cleanup budgets for
your workload. Apply host body limits, authentication and rate limits before
MCP admission. Handler state, custom side effects, kernel buffers and arbitrary
host mailbox sends are outside those managed limits.

Keep the host's Logger configuration under application control. Audit only
approved identifiers and timings; logging tool arguments, results, tokens,
`Plug.Conn` or trusted `sys` state exposes application data. An application that
logs returned typed errors is making its own trusted diagnostic decision.

For a standalone library-owned HTTP listener, use the runtime/listener startup
contract in [HTTP listeners](../HTTP_LISTENERS.md). Lower-level listener helpers
and a Phoenix-mounted borrowed endpoint have different ownership. Do not wrap a
host endpoint in library-owned shutdown machinery.

## Troubleshooting

- A missing named runtime is an admission failure. Check the runtime child and
  its name before changing routing or retrying a committed operation.
- A parser failure occurs before MCP dispatch. Check the endpoint JSON decoder,
  content type and host body limits.
- A 403 origin or 421 host response occurs before tool execution. Correct the
  deployment allowlists rather than disabling validation indiscriminately.
- A stalled SSE response needs proxy/adapter timeout and buffering checks. A
  timeout does not prove that an already-started write or application side
  effect was undone.

See [DSL guide](../DSL_GUIDE.md), [configuration](../CONFIGURATION.md),
[API migration](../V2_API_MIGRATION.md) and [security](../SECURITY.md) for the
remaining contracts. The [RC notes](V2_RELEASE_CANDIDATE.md) distinguish the
tested installed/Phoenix consumers from continuous-soak and stable-release gates.
