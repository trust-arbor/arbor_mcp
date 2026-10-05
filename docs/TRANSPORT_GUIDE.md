# Arbor.MCP Transport Guide

Arbor.MCP supports stdio, Streamable HTTP, BEAM-local, and test transports. The
deprecated MCP 2024-11-05 HTTP+SSE transport is an explicit compatibility
option, not a new-server default.

## Overview

| Transport | Identifier | Best For |
|-----------|------------|----------|
| stdio | `:stdio` | Official MCP subprocess transport |
| Streamable HTTP | `:http` | Remote servers and Phoenix apps |
| Legacy HTTP+SSE | `:sse` | Deprecated 2024-11-05 `GET /sse` + `POST /message` |
| BEAM-local | `:beam` | Local Elixir client/server pairs |
| Test | `:test` | In-memory tests |

## stdio

The stdio transport spawns an external MCP server process and exchanges
newline-delimited JSON-RPC.

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["node", "server.js"],
    cd: "/path/to/project",
    env: [{"NODE_ENV", "production"}]
  )
```

Supported options:

- `:command` - executable plus arguments as a list.
- `:cd` - subprocess working directory.
- `:env` - environment variables as `{"KEY", "VALUE"}` tuples.
- `:timeout` - client operation timeout.

Stdio servers must write only JSON-RPC to stdout. Arbor.MCP 2.0 preserves
VM-global Logger and Application settings. The host configures diagnostics to
stderr or another non-protocol sink before application startup. See
[Configuration — Logging](CONFIGURATION.md#logging) for release configuration
and the retained explicit legacy suppression utility.

Stdio frames are UTF-8 bytes. The process locale decides whether the VM
opens stdio as a character device (UTF-8 locales) or a byte device (any
other locale, or none), and the stdio transports read and write it the
matching way: characters on a character device, bytes on a byte device.
Both are byte-exact for UTF-8, so a server launched with no locale
(launchd, systemd, a host that passes a minimal environment) and a server
launched from a UTF-8 shell behave identically. The transports do not change
the device's mode; OTP 27 cannot switch a unicode-mode stdin after startup,
and the device is shared with the rest of the VM. They do consult it on
every read and write, because OTP switches a unicode-mode stdio to latin1
for good when it meets input it cannot decode, and one bad line from a peer
must not corrupt every frame after it. A byte-order mark at the start of the
stream is stripped from the first frame.

One limitation remains on OTP 27 under a UTF-8 locale: if a peer sends
bytes that are not valid UTF-8, the OTP 27 io server leaves its input buffer
half decoded and reports a mode that matches neither half, and the session
ends at that point. OTP 28 and newer drop the bad line and continue. Peers
that speak MCP send UTF-8, so this only matters with a hostile or broken
peer; deployments on OTP 27 that must survive it should run under a C
locale, where stdio is a byte device from the start.

The VM's filename encoding is a separate setting and is locale-driven on
Linux (always UTF-8 on macOS). A Linux release whose resource handlers list
or open files with non-ASCII names should set `+fnu` in `vm.args`; that is
an application concern, not a transport one.

## Streamable HTTP

HTTP clients and the mounted `Arbor.MCP.HttpPlug` remain core. A standalone
server needs the qualified backend dependencies listed in the
[HTTP listener guide](HTTP_LISTENERS.md) and uses
`http_adapter: :cowboy` (the default) or `:bandit`. See the
[HTTP listener guide](HTTP_LISTENERS.md) for version floors and lifecycle.

The HTTP transport supports two wire shapes on one MCP POST endpoint. A
protocol mode determines how the client establishes the era; it is not a
choice between separate `:http` transport modules.

| Behavior | Legacy Streamable HTTP (2025-03-26–2025-11-25) | Modern Streamable HTTP (2026-07-28) |
|---|---|---|
| Establishment | `initialize`; server may mint `Mcp-Session-Id` | `server/discover`; no protocol session |
| Client messages | POST; session header after initialization | A fresh stateless POST for every message |
| Ordinary response | JSON or request-owned SSE | JSON or request-owned SSE |
| Independent notifications | Optional standalone GET SSE stream | `subscriptions/listen` POST response stream |
| Server needs client input | JSON-RPC request on an SSE stream | `input_required` result followed by a new client POST |
| Resume/termination | `Last-Event-ID`; DELETE session | Not resumable; close the owning response stream |

The client's `use_sse` option controls the standalone GET stream used by
legacy Streamable HTTP. Arbor.MCP disables it, clears any session ID, and stops
sending `Last-Event-ID` after a connection settles modern. Modern request and
subscription streams use SSE on the owning POST response automatically and do
not require `use_sse: true`.

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    protocol_mode: :prefer_modern,
    use_sse: true,
    headers: [{"Authorization", "Bearer #{token}"}],
    request_timeout: 30_000,
    stream_handshake_timeout: 15_000,
    stream_idle_timeout: 60_000,
    dns_timeout_ms: 1_000,
    max_request_bytes: 8_388_608,
    max_response_bytes: 8_388_608,
    max_stream_buffer_bytes: 1_048_576
  )
```

Supported client options include:

- `:url` - base URL or full MCP endpoint URL.
- `:endpoint` - endpoint path when it is not included in `url`.
- `:headers` - additional request headers.
- `:protocol_mode` - `:legacy_only`, `:prefer_legacy`, `:prefer_modern`, or
  `:modern_only`; see the [Configuration Guide](CONFIGURATION.md#protocol-eras-and-modes).
- `:use_sse` - enable the legacy Streamable HTTP GET stream, defaults to `true`.
- `:session_id` - resume an existing streamable HTTP session.
- `:protocol_version` - requested legacy revision, or a modern probe revision
  when the selected mode enables it.
- `:timeout` - connect timeout.
- `:request_timeout` - single request timeout.
- `:stream_handshake_timeout` - wait for SSE stream startup.
- `:stream_idle_timeout` - allowed SSE idle time.
- `:dns_timeout_ms` - DNS-resolution deadline, defaults to one second.
- `:dns_resolver` - injectable resolver used primarily for controlled testing.
- `:allowed_private_hosts` - exact hostnames intentionally permitted to resolve
  to RFC 1918 or IPv6 ULA addresses. Wildcards are rejected; loopback hostnames
  and literals are supported without an exception for local MCP servers.
- `:max_retry_delay` - cap for SSE reconnect delay.
- `:max_request_bytes` - maximum encoded HTTP request body.
- `:max_response_bytes` - maximum JSON or complete streamed response body.
- `:max_stream_buffer_bytes` - maximum incomplete SSE data retained while
  waiting for a frame delimiter.
- `:security` - client-side security validation configuration.
- `:auth` / `:auth_provider` - OAuth/auth provider integration.

HTTP requests use finite absolute deadlines, identity encoding, redirect-free
clients, and incremental response limits. A delimiter-free SSE slow drip cannot
extend the idle deadline indefinitely; the peer must complete a frame within
the configured timeout and buffer limit. Before every connection Arbor.MCP validates
the complete DNS answer and pins the socket to an approved address while keeping
the original hostname for HTTP Host, TLS SNI, and certificate validation. Mixed
public/private answers, link-local addresses, and reserved ranges fail closed.

For OAuth client registration, configure one explicit strategy:

```elixir
auth: %{
  client_registration:
    {:pre_registered, "client-id", {:env, "MCP_CLIENT_SECRET"}},
  credential_issuer: "https://auth.example.com",
  redirect_port: 8080
}

# Or a self-hosted Client ID Metadata Document:
auth: %{
  client_registration:
    {:cimd, "https://client.example/oauth/metadata.json"}
}
```

`:auto` uses pre-existing compatibility keys first, then a configured
`client_metadata_url` when the authorization server advertises CIMD, then
deprecated DCR only when `registration_endpoint` is advertised. DCR requires
an explicit `application_type: :native | :web` and a stable `redirect_port`;
Arbor.MCP never invents a CIMD URL or guesses the application type. A missing
strategy returns an actionable registration error.

Modern pre-registered credentials must include `credential_issuer`, which is
compared exactly with discovered AS metadata. To retain DCR credentials and
tokens safely across flows, configure an adapter implementing
`Arbor.MCP.Authorization.CredentialStore`; registrations are issuer + client-ID
bound and tokens use the complete authorization partition. See the
[Configuration Guide](CONFIGURATION.md#issuer-bound-credential-persistence).

### Modern POST shape

Every modern request is a new POST whose body contains one JSON-RPC request.
The client advertises both response types:

```http
POST /mcp HTTP/1.1
Accept: application/json, text/event-stream
Content-Type: application/json
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/call
Mcp-Name: weather

{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{...}}
```

Arbor.MCP derives the routing headers from the validated body. It strips custom
values for reserved MCP headers before sending a modern request, so callers
cannot create a header/body disagreement.

| Header | When sent | Meaning |
|---|---|---|
| `MCP-Protocol-Version` | Every modern request | Mirrors modern `_meta.protocolVersion` |
| `Mcp-Method` | Every modern request | Mirrors the JSON-RPC method |
| `Mcp-Name` | `tools/call`, `resources/read`, and `prompts/get` | Mirrors the addressed tool, resource, or prompt |
| `Mcp-Param-*` | Annotated `tools/call` inputs | Mirrors schema-selected routing parameters |

Header names are case-insensitive on the wire. `Mcp-Param-*` values may
contain sensitive routing data; redact them in reverse-proxy, load-balancer,
and APM logs as well as application logs.

The server returns one of these shapes:

- `application/json` with the final JSON-RPC response;
- `text/event-stream` with request-related notifications and then the final
  response; or
- `202 Accepted` with no body for an accepted notification POST.

A modern result always has `resultType: "complete"` or
`resultType: "input_required"`. For `input_required`, the client satisfies the
embedded elicitation, sampling, or roots requests and sends the original
operation again as a new POST with `inputResponses` and the opaque
`requestState`. Arbor.MCP never turns those inputs into independent server-to-client
JSON-RPC requests on the HTTP stream.

Long-lived notifications use a `subscriptions/listen` request. Its POST
response stays open as SSE, begins with the subscription acknowledgement, and
then carries only the notification categories selected by that request.
Closing a modern request/subscription response stream is the cancellation
signal; there is no session DELETE and no resumable `Last-Event-ID` cursor.

A `:modern_only` HTTP mount returns `405 Method Not Allowed` for GET or DELETE
on the MCP endpoint, ignores legacy session headers, and never exposes the
deprecated HTTP+SSE endpoints. A dual-era mount must retain whatever legacy
GET/DELETE behavior its enabled legacy clients need, so use request metadata
and the settled client era—not the mere presence of HTTP—to reason about the
wire shape.

### Safe era fallback

With `:prefer_modern`, Arbor.MCP sends a bounded `server/discover` probe first. It
falls back to `initialize` only when the response is recognized as evidence of
a legacy peer and the transport is still usable. A recognized modern error,
unsupported modern revision, timeout, authentication failure, or broken
transport is surfaced instead of being silently downgraded. `:modern_only`
never falls back.

Successful modern observations are pinned by endpoint and relevant transport
configuration. Legacy observations expire (five minutes by default) so an
upgraded endpoint is eventually probed again. Pass `reset_era_cache: true` for
an intentional re-probe after an operator-controlled deployment change.

### Phoenix/Plug Server

```elixir
scope "/mcp" do
  pipe_through [:api, :mcp_auth]

  forward "/", Arbor.MCP.HttpPlug,
    handler: MyApp.MCPServer,
    server_info: %{name: "my-app", version: "1.0.0"},
    protocol_mode: :prefer_modern,
    cors_enabled: true
end
```

Put HTTP concerns in Plug pipelines before `Arbor.MCP.HttpPlug`: authentication,
request signing, rate limiting, CORS/origin decisions, and DNS rebinding checks.

### Deprecated MCP 2024-11-05 HTTP+SSE

Existing deployments can retain the old two-endpoint transport throughout
Arbor.MCP 1.x by opting in:

```elixir
forward "/mcp", Arbor.MCP.HttpPlug,
  handler: MyApp.MCPServer,
  legacy_http_sse: true
```

The GET endpoint defaults to `/sse`; its first event is `endpoint`, containing
the POST URI (default `/message`) and session ID. Configure those paths with
`:legacy_http_sse_path` and `:legacy_http_sse_post_path`. The rc.5
`:sse_enabled` option remains a deprecated alias until Arbor.MCP 2.0. New servers
should use Streamable HTTP and leave this option off. Selecting
`:prefer_legacy` or `:prefer_modern` does not enable this transport;
`:modern_only` disables it even if the compatibility flag is present.

### Client: GET `/sse` + POST `/message`

A 2024-11-05 client opens **GET `/sse` first**. The first event is
`endpoint`; its data is the POST URI (default `/message`) plus `sessionId`.
JSON-RPC then goes to that POST path. Responses and server requests arrive
on the GET stream.

```elixir
# Server — two-endpoint transport (not Streamable HTTP)
{:ok, _} =
  Plug.Cowboy.http(
    Arbor.MCP.HttpPlug,
    [
      handler: MyApp.MCPServer,
      protocol_mode: :legacy_only,
      legacy_http_sse: true,
      legacy_http_sse_path: "/sse",
      legacy_http_sse_post_path: "/message"
    ],
    port: 4000
  )

# Client — GET /sse first, then POST to the advertised /message URI
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :sse,
    url: "http://localhost:4000"
  )

# If the plug is forwarded under a prefix, include that prefix in url.
# Custom GET/POST paths match :legacy_http_sse_path / :legacy_http_sse_post_path.
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :sse,
    url: "http://localhost:4000/mcp",
    sse_path: "/events",
    post_path: "/inbox"
  )
```

Open GET `/sse` with `Accept: text/event-stream` first. The first event is
`endpoint`; JSON-RPC then goes to the advertised POST URI (default
`/message?sessionId=...`). This is **not** Streamable HTTP.
`Arbor.MCP.Client.start_link(transport: :http, use_sse: true)` GETs the same MCP
endpoint after `initialize`; `use_sse: false` disables that standalone GET.
`transport: :sse` is the 2024-11-05 two-endpoint client.

## BEAM-Local

The BEAM-local transport carries MCP-shaped maps/lists as Elixir terms between
local processes. It does not JSON encode/decode in the transport, but it still
uses the MCP lifecycle, request IDs, capabilities, and handler callbacks. Its
protocol mode selects legacy `initialize` or modern `server/discover` plus
per-request context, exactly as stdio does.

```elixir
{:ok, server} =
  MyServer.start_link(
    transport: :beam,
    protocol_mode: :prefer_modern
  )

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :beam,
    server: server,
    protocol_mode: :prefer_modern
  )
```

Supported options:

- server side: `transport: :beam` on a DSL/handler server, with optional
  `protocol_mode`.
- client side: `transport: :beam`, `server: pid`, optional `protocol_mode` and
  `timeout`.

**Tip:** For a fast local verification of these BEAM + DSL + Client patterns (no re-installs), run `mix examples.getting_started` from the project root after `mix compile`.

BEAM-local does not provide service discovery or distributed registry behavior.
If you need a pool or registry of server processes, keep that in your
application supervision layer and pass the selected server PID to the client.

## Test Transport

Use `:test` for in-memory tests where both endpoints are in the same process
tree:

```elixir
{:ok, server} =
  Arbor.MCP.Server.HandlerServer.start_link(
    transport: :test,
    handler: MyServer
  )

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :test,
    server: server
  )
```

## Reliability

Client retries:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  retry_policy: [max_attempts: 3, initial_delay: 100, max_delay: 2_000]
)
```

Transport wrapper:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  reliability: [
    circuit_breaker: [failure_threshold: 5, reset_timeout: 30_000],
    health_check: [check_interval: 60_000]
  ]
)
```

## Telemetry

Transports emit connection and message telemetry. BEAM-local events use the
generic transport event names with `metadata.transport == :beam`:

- `[:arbor_mcp, :transport, :connection, :opened]`
- `[:arbor_mcp, :transport, :message, :sent]`
- `[:arbor_mcp, :transport, :message, :received]`

## Selection Guide

- Use `:stdio` for official subprocess MCP servers.
- Use `:http` for network boundaries and Phoenix integrations.
- Use `:beam` for trusted local Elixir processes.
- Use `:test` for tests.
