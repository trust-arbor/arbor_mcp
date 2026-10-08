# ArborMCP Configuration Guide

This guide covers MCP configuration in the v2 source candidate. The Runtime
redesign is implemented; release qualification and publication remain open.
See the [runtime guide](RUNTIME_GUIDE.md) for supervision, scheduling and limits.

## Dependency

Version 2 is not yet published. Develop against a local MCP checkout:

```elixir
def deps do
  [
    {:arbor_mcp, path: "../arbor_mcp"}
  ]
end
```

On macOS/Darwin and Linux, the transitive `arbor_rpc` source package requires a
C17 compiler even for HTTP-only or BEAM-only use. `CC` selects one compiler
executable. It ships C source rather than a prebuilt helper; assembled releases
must include the built helper and do not invoke a runtime compiler. Windows
native subprocess operations are unsupported, while framing is separate. See
the [source-install policy](V2_PACKAGE_RELEASE.md).

For a standalone Cowboy HTTP server, add `{:plug_cowboy, "~> 2.7"}` and
`{:ranch, "== 1.8.1"}` to the host dependencies. For Bandit, add
`{:bandit, "== 1.12.5"}` and `{:thousand_island, "== 1.5.0"}`. Select Bandit
with `http_adapter: :bandit`; Cowboy remains the default. HTTP clients and
mounting `Arbor.MCP.HttpPlug` in an existing host need no additional listener.
See the [HTTP listener guide](HTTP_LISTENERS.md).

Set `ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc` while the shared dependency is
unpublished. The released 1.x package remains `ex_mcp`; its earlier
`1.0.0-rc.5` release is the legacy-only characterization baseline.
To preserve its connection policy after upgrading, set:

```elixir
config :arbor_mcp, protocol_mode: :legacy_only
```

## Protocol Eras and Modes

The MCP implementation supports two wire-incompatible eras:

- **Legacy:** `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`
  (the newest legacy revision).
- **Modern (latest stable):** `2026-07-28`, with stateless discovery and
  per-request context.

`protocol_mode` is the compatibility policy. Set it in application
configuration for a deployment default:

```elixir
config :arbor_mcp,
  protocol_mode: :prefer_modern,
  protocol_version: "2025-11-25"
```

The client defaults to `:prefer_modern`.
Production deployments should still set the mode explicitly when rollout
policy must not change with a dependency upgrade.

| Mode | Enabled versions, in preference order | Client establishment | Server acceptance |
|---|---|---|---|
| `:legacy_only` | 2025-11-25 → older legacy | `initialize` only | Legacy only |
| `:prefer_legacy` | Legacy revisions → 2026-07-28 | `initialize`, then a modern probe only after an eligible protocol failure on a live transport | Both eras |
| `:prefer_modern` | 2026-07-28 → legacy revisions | `server/discover`, then legacy fallback only with positive compatibility evidence on a live transport | Both eras |
| `:modern_only` | 2026-07-28 | `server/discover` only | Modern only |

The two preference modes differ when used by a client. On a server both accept
either era; their ordering controls the versions advertised by
`server/discover`. A stdio or BEAM connection pins its first valid modern
request or legacy `initialize` and rejects mixed-era traffic afterward.

Configure one client or server independently when canarying:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://mcp.example.com/mcp",
    protocol_mode: :prefer_modern,
    era_probe_timeout: 2_000,
    era_cache_legacy_ttl: 300_000
  )

{:ok, server} =
  MyServer.start_link(
    transport: :stdio,
    protocol_mode: :prefer_legacy
  )

# In Application.start/2, before the borrowed Phoenix endpoint:
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http,
   protocol_mode: :prefer_legacy}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  protocol_mode: :prefer_legacy
```

Client mode options:

- `:era_probe_timeout` bounds the side-effect-free `server/discover` probe
  exchange, including a synchronous HTTP POST; the default is `2_000`
  milliseconds.
- `:handshake_timeout` bounds the legacy `initialize` exchange the same way;
  the default is `10_000` milliseconds.
- `:establish_timeout` bounds establishing the connection as a whole, probe,
  fallback, handshake and connection retries included; the default is
  `:handshake_timeout` plus `:era_probe_timeout`, and on expiry
  `start_link/1` fails with `{:error, :establish_timeout}`.
- `:era_cache_legacy_ttl` controls how long a legacy observation is reused;
  the default is `300_000` milliseconds. Modern observations do not expire
  and cannot be replaced by automatic fallback.
- `:reset_era_cache` clears the observation for the exact transport identity
  before connecting. Use it after an intentional endpoint upgrade, not as an
  automatic retry strategy.
- `:era_cache_key` supplies a stable identity for a custom transport that
  cannot be identified from its connected state. Never include raw secrets;
  ArborMCP hashes the configured identity.

Fallback is deliberately narrow. A modern timeout, transport failure,
recognized modern error, authentication error, or cached-modern probe failure
does not trigger `initialize`. Similarly, `:prefer_legacy` probes modern only
after a protocol-level legacy failure while the transport remains usable.
Strict modes never fall back.

`protocol_version` is a legacy revision preference, not an era switch or a
statement of the latest upstream MCP revision. The
application-level value and the compatibility helper
`Arbor.MCP.protocol_version/0` retain their rc.5 legacy semantics during the soak;
use `protocol_mode` to enable modern negotiation. A per-client modern
`protocol_version` is honored only when its mode enables the modern era.

For legacy Streamable HTTP, `initialize` negotiates the version from
`params.protocolVersion`; it does not require an `MCP-Protocol-Version` HTTP
header. When `protocol_version_required: true`, every subsequent request must
carry exactly one header matching the version stored for that server-issued
session. ArborMCP always rejects an explicit malformed, unsupported, duplicate, or
session-mismatched header, even when missing-header enforcement is disabled.
Modern requests always carry matching HTTP and `_meta` protocol versions.

The server issues a legacy Streamable HTTP session only for `initialize` and
atomically allows one initialization attempt. It exposes the session ID only
after a successful response binds that exact negotiated version. Later POST
and GET/SSE requests require the issued initialized session; failed or
abandoned initialization is terminated. The deprecated 2024 HTTP+SSE endpoint
uses its separate endpoint-event handshake and is unaffected by this rule.

Use the public negotiator for legacy compatibility checks:

```elixir
Arbor.MCP.Protocol.VersionNegotiator.supported?("2025-11-25")
```

See the [migration rollout](getting-started/MIGRATION.md#recommended-rollout)
and the [architecture era model](ARCHITECTURE.md#protocol-era-model) before
changing a production default.

## OAuth Client Registration

Modern authorization uses an explicit client registration strategy in the
HTTP transport's `:auth` map. Choose one `auth` value below and pass it as
`auth: auth` when starting the HTTP client:

```elixir
# Credentials established with this authorization server. Resolve secrets at
# use time rather than embedding them in application configuration.
auth = %{
  client_registration:
    {:pre_registered, "client-id", {:env, "MCP_CLIENT_SECRET"}},
  credential_issuer: "https://auth.example.com"
}

# Portable, self-hosted Client ID Metadata Document.
auth = %{
  client_registration:
    {:cimd, "https://client.example/oauth/metadata.json"},
  private_key: signing_jwk,
  signing_algorithm: "ES256",
  key_id: "client-key-1"
}

# Automatic compatibility fallback. DCR is used only when advertised.
auth = %{
  client_registration: :auto,
  client_metadata_url: "https://client.example/oauth/metadata.json",
  application_type: :native,
  redirect_port: 8080
}
```

Registration priority is pre-registered credentials, a configured CIMD URL
when the authorization server sets
`client_id_metadata_document_supported: true`, deprecated DCR when it exposes
`registration_endpoint`, then an actionable error. `:auto` never fabricates a
metadata URL. Existing `client_id` / `client_secret` keys remain accepted as
1.x compatibility aliases.

A CIMD client ID must be an exact HTTPS URL with a non-root path. The JSON
document at that URL must repeat the same `client_id` byte-for-byte and include
non-empty `client_name` and `redirect_uris`. Use
`Arbor.MCP.Authorization.ClientIdMetadata.build_metadata/1` and `validate/2` before
publishing it. For `private_key_jwt`, publish `jwks_uri` or inline `jwks` and
configure the matching private key locally; ArborMCP will not downgrade to a
weaker token authentication method if assertion construction fails.

DCR requires an explicit `application_type: :native | :web` and stable local
`redirect_port`. Registration rejections retain the authorization server's
error response so redirect-policy failures are actionable. ArborMCP does not
silently change the application type or redirect URI.

### OAuth metadata network policy

CIMD, Protected Resource Metadata, OIDC/RFC 8414 authorization-server
metadata, and JWKS retrieval use one fail-closed outbound fetch boundary.
Metadata URLs must use HTTPS, including in local development. Each hostname is
resolved on every redirect hop; a DNS answer containing any private, loopback,
link-local, reserved, documentation, or otherwise non-public IPv4/IPv6 address
is rejected. The connection is pinned to an approved address while the original
hostname remains the TLS SNI and certificate-validation name.

Defaults can be tightened globally:

```elixir
config :arbor_mcp, :oauth_metadata_fetch,
  max_redirects: 3,
  max_response_bytes: 262_144,
  max_aggregate_bytes: 524_288,
  dns_timeout_ms: 1_000,
  connect_timeout_ms: 2_000,
  request_timeout_ms: 5_000,
  allowed_redirect_origins: []
```

Redirects remain on the current origin by default. If a provider deliberately
hosts metadata on another origin, list each destination as an exact HTTPS
origin such as `https://metadata.example.com`; wildcards and URL paths are not
accepted. Every allowed destination still receives fresh DNS/IP validation.

The metadata client sends only `Accept`, `Accept-Encoding: identity`, and a
non-secret user agent. It never inherits MCP transport headers, authorization,
cookies, client secrets, or proxy credentials. Compressed responses are
rejected and the default client enforces the byte limit while streaming.

The legacy custom metadata-client shapes `get(url)` and `get(url, headers)` are
no longer accepted because they can re-resolve DNS after validation. A custom
`:http_client` must implement:

```elixir
get(uri, approved_address, options)
```

It must connect directly to `approved_address`, preserve `uri.host` for TLS and
HTTP host validation, use only `options[:request_headers]`, enforce
`options[:connect_timeout_ms]`, `options[:request_timeout_ms]`, and
`options[:max_response_bytes]` while streaming, and return
`{:ok, %{status: integer, headers: list, body: binary}}`. Per-flow overrides go
under `metadata_fetch: [...]`; use them only for a tighter policy or an exact
provider redirect.

### Issuer-bound credential persistence

For MCP `2026-07-28`, pre-registered credentials require
`credential_issuer`. ArborMCP compares this value byte-for-byte with the issuer in
the discovered authorization-server metadata before resolving or using the
secret. A trailing slash, path change, or any other textual difference is a
mismatch; issuer identifiers are not URL-normalized. During 1.x, only the
legacy `client_id` / `client_secret` aliases retain their old unbound behavior
for legacy protocol versions; the new explicit pre-registration strategy is
always issuer-bound.

Applications that persist DCR registrations or tokens can provide an encrypted
store or OS-keychain adapter implementing
`Arbor.MCP.Authorization.CredentialStore`:

```elixir
auth: %{
  client_registration: :auto,
  application_type: :native,
  redirect_port: 8080,
  credential_store: {MyApp.MCPCredentialStore, store_state},
  credential_context: "desktop-installation-42"
}
```

`credential_context` is a stable, non-secret local index (the resource URL is
the default). The adapter still stores each registration under the exact
versioned issuer + client-ID key supplied to it. On an authorization-server
change, the new issuer partition misses and ArborMCP performs registration again;
an adapter returning a credential from another issuer is rejected.

Tokens are partitioned by issuer, client ID, resource and/or audience,
subject or client identity, and normalized granted scopes. Access and refresh
tokens never appear in a storage key, and the credential structs redact secret
fields from `Inspect`. ArborMCP intentionally provides no plaintext file adapter.

Old records without an issuer fail with
`{:credential_migration_required, :registration | :token}`. After verifying
the original authorization server out of band, migrate them explicitly with
`CredentialStore.bind_legacy_registration/2` or
`CredentialStore.bind_legacy_token/2`; never use the currently discovered
issuer as an implicit migration value.

### OAuth transaction retention

Every authorization-code flow started by ArborMCP uses a random 256-bit `state`
and PKCE verifier. The returned transaction is registered in a supervised,
node-local single-use store before the authorization URL is returned. Callback
validation consumes state atomically, and code exchange atomically binds the
validated code to the exact redirect URI before making the token request. This
path is shared by legacy and `2026-07-28` MCP sessions.

The default store retains up to 10,000 transaction records for 10 minutes. Both
limits can be adjusted:

```elixir
config :arbor_mcp, Arbor.MCP.Authorization.OAuthTransactionStore,
  ttl_ms: 600_000,
  max_entries: 10_000
```

Do not shorten the TTL below the time a user may reasonably spend in the
browser. Capacity exhaustion fails new flows closed. The built-in loopback flow
is intentionally node-local; a distributed web callback must route back to the
originating node or implement its own strongly consistent end-to-end flow.

For direct use of `Arbor.MCP.Authorization`, preserve the returned transaction and
pass it through validation and redemption:

```elixir
{:ok, authorization_url, transaction} =
  Arbor.MCP.Authorization.start_authorization_flow(config)

{:ok, code} =
  Arbor.MCP.Authorization.validate_authorization_response(callback, transaction)

Arbor.MCP.Authorization.exchange_code_for_token(%{
  code: code,
  code_verifier: transaction.code_verifier,
  client_id: config.client_id,
  redirect_uri: transaction.redirect_uri,
  token_endpoint: config.token_endpoint,
  transaction: transaction
})
```

ArborMCP does not accept caller-supplied state or reserved OAuth fields in
`additional_params`. If a token request has an ambiguous outcome, its code
remains redeemed; restart authorization instead of retrying the code.

## JSON Schema Resource Policy

Tool `inputSchema` / `outputSchema` (DSL: `input_schema` / `output_schema`)
and elicitation `requestedSchema` use the **JSON Schema 2020-12** dialect
(`https://json-schema.org/draft/2020-12/schema`). `$schema` draft identifiers
are metadata; bundled 2020-12 meta-schemas do not require a network request.

Every JSON Schema compiled or validated by ArborMCP passes through one bounded,
fail-closed policy. By default, only local fragment references (`#` and
`#/...`) are accepted. HTTP(S), file, and relative cross-document `$ref` values
are rejected before ExJsonSchema can resolve them, even if the host application
configured ExJsonSchema's global `:remote_schema_resolver`.

The defaults are suitable for protocol schemas and can be tightened or raised
for a trusted application workload:

```elixir
config :arbor_mcp, :json_schema,
  max_schema_bytes: 262_144,
  max_schema_depth: 64,
  max_subschemas: 1_000,
  max_composition_depth: 16,
  resolve_timeout_ms: 1_000,
  validation_timeout_ms: 100
```

`max_subschemas` conservatively counts schema object nodes, including nested
property maps but excluding literal instance data in `const`, `default`, `enum`,
and `examples`. Composition depth counts nesting through `allOf`, `anyOf`,
`oneOf`, `not`, `if`, `then`, and `else`. A zero timeout or limit is valid and
can be used to disable the corresponding work. Invalid values fail closed.

`$schema` draft identifiers are metadata and remain accepted; bundled draft
meta-schemas do not require a network request. Boolean JSON Schemas (`true` and
`false`) are supported.

### Opt-in network references

Keep remote references disabled unless the schema publisher is part of the
application's trust boundary. To opt in, provide a non-empty host allowlist and
increase the outer resolution deadline enough to cover the bounded network
work:

```elixir
config :arbor_mcp, :json_schema,
  resolve_timeout_ms: 10_000,
  network_refs: [
    enabled: true,
    allowed_hosts: ["schemas.example.com", "*.schemas.example.net"],
    trust_partition: "production-schema-publishers",
    allow_http: false,
    max_redirects: 3,
    max_documents: 16,
    max_reference_depth: 8,
    max_response_bytes: 262_144,
    max_decompressed_bytes: 262_144,
    max_aggregate_bytes: 1_048_576,
    dns_timeout_ms: 1_000,
    connect_timeout_ms: 2_000,
    request_timeout_ms: 3_000,
    proxy: :disabled
  ]
```

The allowlist contains hostnames, not URLs. `*.example.com` matches subdomains
but not `example.com` itself. HTTPS is required unless `allow_http: true` is set;
plain HTTP provides no publisher authentication or integrity and is not
recommended. Redirects from HTTPS to HTTP are rejected even when HTTP was
enabled for an explicitly HTTP reference.

Every request and redirect target is allowlisted, independently DNS-resolved,
checked for public-only IPv4/IPv6 addresses, and connected to an approved IP
while TLS verification and SNI use the original hostname. A mixed DNS answer
containing even one loopback, link-local, private, reserved, or documentation
address is rejected. URI userinfo, compressed responses, and proxies are
rejected. No cookies, authorization headers, or other credentials are sent.

Fetched documents exist only inside one compilation; ArborMCP does not persist or
globally share a remote-schema cache. This is stronger than partitioning a
persistent cache and prevents one tenant or principal from warming another's
schema state. `trust_partition` is hashed in audit logs and establishes the
partition identity for any future cache implementation.

`:dns_resolver` and `:http_client` adapter overrides exist for controlled tests.
Do not replace them in production: doing so replaces the DNS revalidation,
IP-pinned connection, TLS, streaming limit, and deadline enforcement that make
the boundary safe.

## OpenTelemetry Metadata Policy

ArborMCP can carry W3C trace-context values in the MCP `_meta` object without
taking a dependency on an OpenTelemetry SDK or mutating process-global tracing
state. `traceparent` and `tracestate` are validated at every client and server
metadata boundary. Baggage is validated and bounded before filtering, then only
explicitly allowlisted members are retained. The default baggage allowlist is
empty, so baggage is dropped unless the application opts in.

```elixir
config :arbor_mcp, :otel_meta,
  baggage_allowlist: ["tenant.id", "request-id"],
  max_total_bytes: 9_216,
  max_baggage_bytes: 8_192,
  max_baggage_members: 64
```

The fixed `tracestate` limits are 512 bytes and 32 unique members. Configured
byte limits cannot exceed 65,536 bytes, and baggage member/allowlist counts
cannot exceed 64. Invalid configuration or malformed metadata fails closed.
ArborMCP currently accepts the W3C version `00` `traceparent` wire format; values
must use lowercase hexadecimal and non-zero trace and parent identifiers.

Attach a connection-level context to all modern client requests:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  trace_context: %{
    traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    tracestate: "vendor=opaque",
    baggage: "tenant.id=acme,secret=discarded"
  }
)
```

Per-request values may also be supplied in the request's `_meta`; the explicit
client `:trace_context` wins when both sources contain the same field. On the
server, handlers receive the sanitized map as
`Arbor.MCP.Server.RequestContext.trace_context`. Notification and result metadata
go through the same policy.

Allowlist only low-cardinality routing or correlation fields. Do not propagate
credentials, authorization tokens, personal data, or other secrets as baggage.

## Tasks Extension

Modern Tasks is an explicit extension, not the experimental `tasks` capability
from MCP 2025-11-25. A modern client opts in on every request by adding
`io.modelcontextprotocol/tasks` to its configured capabilities:

```elixir
task_capabilities =
  Arbor.MCP.Tasks.Extension.put_capability(%{
    "elicitation" => %{"form" => %{}}
  })

Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  capabilities: task_capabilities
)
```

After a `tools/call` returns `resultType: "task"`, use
`Arbor.MCP.Client.get_task/3`, `update_task/4`, and `cancel_task/3`. The client
rejects task results unless the extension was configured, and validates the
task handle before returning it to application code.

A server must advertise the same extension from `server/discover` only when it
has configured an appropriate task store. The bundled node-local store is
enabled in a Handler with `tasks: :store`; ArborMCP then adds the extension to
discovery automatically:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler, tasks: :store

  @impl Arbor.MCP.Server.Handler
  def handle_call_tool("long_deploy", arguments, state) do
    Arbor.MCP.Tasks.Server.create(
      "long_deploy",
      arguments,
      state,
      __task_store_options__()
    )
  end
end
```

Handlers without `tasks: :store` do not gain this capability. A custom task
backend that overrides the task callbacks may advertise the extension
explicitly through `:server_capabilities` or `__server_capabilities__/0` after
it has implemented equivalent durability and ownership checks.

The injected modern `handle_task_get/2`, `handle_task_update/3`, and
`handle_task_cancel/2` callbacks use `Arbor.MCP.Tasks`. Existing callbacks remain
overridable, and legacy task methods are unchanged unless the application
implements them explicitly. `Arbor.MCP.Tasks.Server.create/4` inserts the task
synchronously and returns a handle only after `tasks/get` can read it.

`Arbor.MCP.Tasks.Store.ETS` is bounded and atomic on one node. Its entries
survive client reconnects, connection failures and callback-worker failures
while the actual store process remains alive. A Runtime owns an unnamed store
in its service cohort by default; a cohort or whole-root replacement discards
that in-memory task state. An explicitly supervised standalone store has its
own process lifetime. Neither form persists entries across a store process or
node restart.

Configure a Runtime's task adapter and limits on its service descriptor:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyServer,
   handler_args: [],
   services: [
     tasks: [
       options: [
         max_tasks: 10_000,
         max_ttl_ms: 2_592_000_000,
         max_entry_bytes: 1_000_000,
         max_retained_bytes: 8_000_000
       ]
     ]
   ]}
]
```

These are store limits, not a whole-VM memory guarantee. The v2 application no
longer starts `Tasks.Store.ETS` automatically or reads limits from
`config :arbor_mcp, Arbor.MCP.Tasks.Store.ETS`. Supply limits as child options
when supervising a standalone store. The retained application `:task_store`
selector and Handler `:task_store`/`:task_store_opts` apply to explicitly
supervised standalone calls; they do not select or override the task service
of a Runtime callback.

For stronger durability, select a custom adapter in the Runtime descriptor,
for example `tasks: [adapter: MyApp.Tasks.PostgresStore, options: [repo: MyApp.Repo]]`.
The `Arbor.MCP.Tasks.Store` behaviour alone is insufficient for a Runtime
adapter: an owned adapter must declare `bounded_startup: 1`, register before
blocking initialization, and provide bounded native startup. Runtime task
adapters also declare `bounded_operations: 1`, implement
`runtime_service_binding/2` and `operate/4`, reserve operations before payload
publication and recheck the supplied authority immediately before mutation.
A borrowed descriptor additionally needs the explicit live `:server` and
stable `:namespace` contract; the Runtime never stops that borrowed backend.
See [native store bounds](./V2_NATIVE_STORE_PRESSURE.md).

The store binds each task to the current request's principal, tenant, and
endpoint. Before starting work outside a request callback, capture both the
logical service reference and non-secret owner, then pass them to storage calls:

```elixir
{:ok, task_service} = Arbor.MCP.Server.Runtime.service(:tasks)
owner = Arbor.MCP.Tasks.owner()

# Retain these values in application-owned work outside the callback:
{:ok, task} =
  Arbor.MCP.Tasks.complete(task_id, result,
    service: task_service,
    owner: owner,
    notify: false
  )
```

The retained service reference and owner permit storage addressing and
authorization; they do not recreate the original callback's publication Origin.
Successful creates and wire-visible transitions attempt asynchronous full-state
`notifications/tasks` publication when `notify: true` (the default), but their
stored success result does not prove publication acceptance or stream delivery.
Runtime publication requires an authentic current callback Origin and the
matching subscription service, generation, scope and original cutoff. Public
options cannot supply a caller-authored Origin. Work outside that callback must
own publication separately; `notify: false` makes that choice explicit.
Standalone calls retain the `subscription_registry: registry` selector for an
explicitly supervised registry. A missing/retired origin, pressure or subsequent
source retirement can prevent notification delivery without undoing a stored
transition.

The host application still owns worker execution and recovery. Store adapters
own persistence, atomicity across serving nodes, authorization binding, and
expiry. Do not advertise the extension when the configured store cannot meet
the deployment's durability requirements.

`Arbor.MCP.Tasks.Task.to_map/1` retains the legacy 2025-11-25 keys.
`to_map/2` with `:modern` or `"2026-07-28"` emits `ttlMs`,
`pollIntervalMs`, `inputRequests`, and `error` without removing the public 1.x
struct aliases. `tasks/list`, `tasks/result`, and
`notifications/tasks/status` remain legacy-only.

## Client Configuration

You can pass options directly to `Arbor.MCP.Client.start_link/1`:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    protocol_mode: :prefer_modern,
    use_sse: true,
    request_timeout: 30_000
  )
```

Or build a reusable config with `Arbor.MCP.ClientConfig`:

```elixir
config =
  Arbor.MCP.ClientConfig.new(:production)
  |> Arbor.MCP.ClientConfig.put_transport(:http, url: "https://api.example.com/mcp")
  |> Arbor.MCP.ClientConfig.put_auth(:bearer, token: System.fetch_env!("MCP_TOKEN"))
  |> Arbor.MCP.ClientConfig.put_retry_policy(max_attempts: 3, base_interval: 500)

{:ok, client} = Arbor.MCP.Client.connect(config)
```

`Arbor.MCP.Client.connect/2` also accepts a URL string, a `{transport, opts}` tuple, or
a list of those specs. A list is still accepted in v2, but only the
first spec is used. Remaining specs are ignored. This is not a failover.

## stdio

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["node", "server.js"],
    protocol_mode: :prefer_modern,
    cd: "/path/to/project",
    env: [{"NODE_ENV", "production"}],
    timeout: 30_000
  )
```

Supported options:

- `:command`
- `:cd`
- `:env`
- `:environment_policy` (`:isolated` by default; `:inherit` is an explicit
  compatibility opt-in)
- `:process_group` (`false` by default): stop the server's whole process
  group, not only the process the port started
- `:timeout`

The isolated policy passes a small runtime baseline and the explicitly supplied
`:env` entries. It prevents unrelated API, cloud, and session credentials from
being inherited by a third-party MCP subprocess; it does not provide a
filesystem or network sandbox.

The command is resolved against the `PATH` the child sees. When the VM runs as
an OTP release, the release's own directories (under `RELEASE_ROOT`) are
dropped from the inherited `PATH`, so a server that is itself an Erlang or
Elixir program finds the host's `erl` rather than the release's.

Set `process_group: true` for a server that starts processes of its own (a
launcher or shell script that spawns the real server, a server that forks
workers): closing the connection then signals the server and everything it
started in its process group, instead of the one process the port started.

## Streamable HTTP

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
    max_retry_delay: 60_000,
    dns_timeout_ms: 1_000,
    max_request_bytes: 8_388_608,
    max_response_bytes: 8_388_608,
    max_stream_buffer_bytes: 1_048_576
  )
```

Supported options include:

- `:url`
- `:endpoint`
- `:headers`
- `:protocol_mode`
- `:use_sse`
- `:session_id`
- `:protocol_version`
- `:timeout`
- `:request_timeout`
- `:stream_handshake_timeout`
- `:stream_idle_timeout`
- `:max_retry_delay`
- `:dns_timeout_ms` (DNS lookup deadline; defaults to `1_000`)
- `:dns_resolver` (custom resolver for controlled testing)
- `:allowed_private_hosts` (exact internal hostnames allowed to resolve to
  RFC 1918/IPv6 ULA addresses; no wildcards)
- `:max_request_bytes`
- `:max_response_bytes`
- `:max_stream_buffer_bytes` (maximum delimiter-free/incomplete SSE data)
- `:security`
- `:auth`
- `:auth_provider`

Every POST, GET/SSE, retry, and DELETE resolves the destination, validates the
entire answer set, and pins the connection to an approved address. The original
hostname remains the Host/SNI/certificate name. Public destinations are allowed
by default, as are literal/named loopback destinations for local MCP servers.
Internal destinations require an exact `:allowed_private_hosts` entry;
link-local, reserved, and mixed public/private answers remain forbidden.

`use_sse` controls the legacy standalone GET stream. It may remain `true` on a
dual-era client: once `server/discover` succeeds, ArborMCP disables that stream,
clears legacy session state, and uses JSON or POST-owned SSE for each modern
request. `subscriptions/listen` opens its own POST response stream.

### TLS trust store

Outbound HTTPS (this transport and the OAuth HTTP boundary) verifies peers
against the operating system's trust store unless you pass certificates
yourself, so CAs installed on the host, such as a private or corporate CA,
are trusted automatically.

Loading that store can stall: on macOS it runs `/usr/bin/security`, which can
hang on the keychain, for example while the session is locked. ArborMCP loads it
with a deadline. If the load stalls, fails, or finds no certificates, ArborMCP
**fails closed** by default: HTTPS requests return
`{:error, {:trust_store_unavailable, reason}}` (OAuth requests return their
usual request error), an error is logged, and a
`[:arbor_mcp, :cacerts, :os_load, :failed]` telemetry event is emitted. The
failure is cached briefly so requests fail immediately instead of each waiting
out the deadline, and the load is retried after that.

```elixir
config :arbor_mcp, :cacerts,
  # Deadline for loading the OS trust store (default 5_000 ms). Once loaded,
  # the store is cached for the life of the VM.
  os_timeout_ms: 5_000,
  # How long a failed load is cached before the next attempt (default 30_000).
  failure_ttl_ms: 30_000,
  # :none (default) fails closed. :castore trusts the castore bundle instead;
  # see below before enabling it.
  fallback: :none,
  # With fallback: :castore, how often to retry the OS store in the background
  # (default 5 min). Arbor.MCP switches back as soon as it loads.
  refresh_interval_ms: 300_000
```

`fallback: :castore` keeps HTTPS working through a stall by trusting the
Mozilla-derived bundle from the [`castore`](https://hex.pm/packages/castore)
package. It is opt-in because it changes which CAs are trusted, and anyone
able to make the OS store unavailable can force that change:

- CAs installed only in the OS store (private or corporate CAs) stop being
  trusted, and CAs the OS has distrusted but the bundle version still
  contains become trusted again.
- The bundle comes from a dependency, so its integrity depends on your
  supply chain. Review `castore` updates like code changes; `mix.lock`
  checksums protect only versions you have already locked.

Enable it only if availability matters more than those risks, and alert on
the `:os_load, :failed` telemetry event, which reports `fallback: :castore`
whenever the switch happens.

To trust a fixed set of CAs instead, pass DER-encoded certificates. For
example, to always use the `castore` bundle:

```elixir
castore_certs =
  for {:Certificate, der, _} <- :public_key.pem_decode(File.read!(CAStore.file_path())),
      do: der

# The HTTP transport:
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  security: %{tls: %{cacerts: castore_certs}}
)

# The OAuth HTTP boundary (metadata, token, and registration requests):
config :arbor_mcp, :oauth_http, cacerts: castore_certs
```

A fixed bundle does not change when the OS store is updated, so a distrusted
CA stays trusted until you update it. Prefer the default unless you need the
same trust set on every host.

## BEAM-Local

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)  # works when using DSL; otherwise use HandlerServer.start_link(handler: MyServer, ...)

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :beam,
    server: server,
    timeout: 5_000
  )
```

`transport: :beam` is local to the current VM and requires a server PID. Keep any
pooling, service discovery, or process selection in your application layer.

## Server Configuration

Servers (DSL or raw handlers) can be started with:

```elixir
MyServer.start_link(transport: :beam, protocol_mode: :prefer_legacy)
MyServer.start_link(transport: :stdio, protocol_mode: :prefer_legacy)
MyServer.start_link(transport: :http, port: 4000, protocol_mode: :prefer_legacy)

# For a raw handler module (no DSL):
Arbor.MCP.Server.HandlerServer.start_link(handler: MyHandler, transport: :beam)
# or the convenience:
Arbor.MCP.start_server(handler: MyHandler, transport: :stdio)
```

`HandlerServer`-based BEAM/test servers and stdio servers retain request IDs for
the connection's protocol lifetime so a client cannot execute the same
JSON-RPC request ID twice. The retained set is bounded to 10,000 IDs by
default; set `max_request_ids: positive_integer` on server startup to choose a
deployment-specific fail-closed bound.

Phoenix/Plug applications usually mount `Arbor.MCP.HttpPlug`:

```elixir
# In Application.start/2, before the borrowed Phoenix endpoint:
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http,
   protocol_mode: :prefer_legacy,
   request_timeout_ms: 10_000}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  protocol_mode: :prefer_legacy,
  cors_enabled: true
```

The Runtime owns the handler and initializes it once with `:handler_args`.
Configure its work deadline with `:request_timeout_ms`; the retired mount
`:handler_call_timeout` raises a configuration error. Handler/DSL metadata owns
server identity. Client-side `:timeout`, `:request_timeout`,
`:stream_handshake_timeout`, and `:stream_idle_timeout` remain separate settings.

The MCP 2024-11-05 HTTP+SSE transport is deprecated and disabled by default.
Version 2 servers select it with `legacy_http_sse: true`. The old server
constructor aliases `sse_enabled` and `use_sse` are rejected; the HTTP client's
separate `use_sse` option remains supported. Optional `legacy_http_sse_path` and
`legacy_http_sse_post_path` settings default to `/sse` and `/message`.
Neither dual-era preference mode enables this transport. `:modern_only`
disables it even when the compatibility option is present; retired aliases
remain invalid configuration.

### OAuth protected-resource metadata

When `oauth_enabled: true`, `Arbor.MCP.HttpPlug` requires the canonical HTTPS
resource identifier and at least one HTTPS authorization-server issuer. Mount
the plug so the RFC 9728 path-specific metadata URL is reachable:

```elixir
# In Application.start/2, before the borrowed Phoenix endpoint:
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router:
forward "/", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  path: "/mcp",
  oauth_enabled: true,
  resource: "https://mcp.example.com/mcp",
  authorization_servers: ["https://auth.example.com"],
  auth_config: %{
    introspection_endpoint: "https://auth.example.com/introspect",
    client_id: System.fetch_env!("MCP_RESOURCE_CLIENT_ID"),
    client_secret: System.fetch_env!("MCP_RESOURCE_CLIENT_SECRET"),
    expected_issuer: "https://auth.example.com",
    expected_audience: "https://mcp.example.com/mcp"
  }
```

This serves `/.well-known/oauth-protected-resource/mcp`; bearer challenges
point clients to that metadata document. Custom MCP methods also need an
explicit `:scope_mapper` returning a non-empty list of scopes. Unmapped or
invalid policies are denied rather than sharing a catch-all scope.

The resource server authenticates to introspection with
`:client_secret_basic` by default; `:client_secret_post` is available through
`:introspection_auth_method`. An active token is still rejected unless its
issuer, audience/resource, `exp`, and optional `nbf` satisfy this configuration.
Only migration deployments should use `legacy_unbound_tokens: true`.

### Session storage

HTTP Runtimes that support legacy sessions create their own session service.
Its defaults differ from the old standalone `SessionManager` configuration:

| Runtime service option | Default | Scope |
| --- | --- | --- |
| `max_sessions` | 128 | Sessions in the service |
| `max_request_ids` | 1,024 | Retained IDs across the service |
| `max_request_ids_per_session` | 128 | Retained IDs in one session |
| `max_request_id_bytes` | 65,536 | Aggregate retained ID bytes |
| `max_events` | 1,024 | Replay events across the service |
| `max_events_per_session` | 128 | Replay events in one session |
| `max_event_bytes` | 65,536 | One encoded replay event |
| `max_replay_bytes` | 1,000,000 | Aggregate replay bytes |
| `max_replay_bytes_per_session` | 262,144 | Replay bytes in one session |
| `session_ttl_ms` | 3,600,000 | Idle session lifetime in milliseconds |

Set limits through the HTTP Runtime's `services:` descriptor. This example
chooses a smaller session population with a larger per-session ID allowance:

```elixir
{Arbor.MCP.Server.Runtime,
 handler: MyApp.MCPServer,
 transport: :mounted_http,
 services: [
   sessions: [
     options: [
       max_sessions: 64,
       max_request_ids: 5_000,
       max_request_ids_per_session: 500,
       max_request_id_bytes: 262_144,
       session_ttl_ms: 900_000
     ]
   ]
 ]}
```

The aggregate ID/count/byte bounds still apply when an individual session is
below its own limit. `session_ttl_seconds` belongs to the standalone API and
does not configure this Runtime service. Metadata and replay-page bounds also
apply; runtime session storage currently uses ETS.

At capacity, new session allocation returns HTTP `503` with `Retry-After`.
Exhausted request-ID capacity fails closed with HTTP `429`; duplicates return
JSON-RPC `Invalid Request`. Retired/expired sessions reclaim their retained IDs
and replay data. Plan session rotation for long-lived clients instead of assuming
that completing a request frees its duplicate-execution record.

Replay retention rejects oversized events. Notification append may evict old
events to satisfy per-session limits. Prepared response publication instead
reserves retained and pending capacity before state commit and can fail closed
at capacity. Aggregate bounds apply to both paths. A requested event may have
expired or been evicted before a reconnect. See the
[transport guide](TRANSPORT_GUIDE.md) for legacy replay behavior.

## Multi Round-Trip Requests (MCP 2026-07-28)

MRTR lets `tools/call`, `resources/read`, and `prompts/get` pause for client
elicitation, sampling, or roots input. Configure a runtime AES-256 key ring and
declare `mrtr: true` so server startup validates it:

```elixir
# runtime.exs — load the secret from your runtime secret manager/environment.
key = System.fetch_env!("MCP_REQUEST_STATE_KEY") |> Base.decode64!()

config :arbor_mcp, :request_state,
  active_key_id: "2026-08",
  keys: %{"2026-08" => key},
  ttl_seconds: 300,
  max_ttl_seconds: 900,
  clock_skew_seconds: 30
```

For a rolling rotation, first distribute `%{"old" => old_key, "new" =>
new_key}` to every node with `active_key_id: "old"`; then roll only
`active_key_id` to `"new"`; finally remove `"old"` after the maximum token TTL
plus clock skew. Install each complete key-ring snapshot atomically. Use
`revoked_key_ids: ["old"]` for emergency invalidation, accepting that any
in-flight token sealed by that key must restart.

```elixir
MyServer.start_link(
  transport: :stdio,
  protocol_mode: :modern_only,
  mrtr: true
)
```

Handlers can return either MRTR tuple, or use the DSL builder:

```elixir
{:input_required, input_requests, state}
{:input_required, input_requests, application_request_state, state}

ToolResult.input_required(input_requests, %{"workflowStep" => 1})
```

On the retry, unchanged callback arities read verified data from
`Arbor.MCP.Server.Context.input_responses/0` and
`Arbor.MCP.Server.Context.request_state/0`. Application request state must be JSON
encodable and is size-bounded before encryption.

Client operation options default to 8 rounds, 16 input requests per round, and
1 MiB of serialized MRTR input/output. Override them with
`:max_mrtr_rounds`, `:max_input_requests`, and `:max_mrtr_bytes`. One overall
`:timeout` covers all rounds.

Input callbacks run sequentially in deterministic request-ID order by default.
A stateless client handler can explicitly opt into bounded parallel dispatch by
implementing `mrtr_input_concurrency/0` and returning an integer from 2 through
16. Every parallel callback receives the same handler state and must return it
unchanged; ArborMCP rejects a parallel callback that attempts to update the state.

For resumptions that may cause side effects, enable atomic single-use
enforcement:

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyServer,
   handler_args: [],
   transport: :mounted_http,
   services: [replay_cache: []],
   require_replay_protection: true}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router, validate the key ring and require the Runtime's replay service:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  mrtr: true,
  require_replay_protection: true
```

The bundled cache is node-local. Clustered deployments must implement
`Arbor.MCP.Server.ReplayCache` over a shared, strongly consistent store. Without a
replay cache, verified retry context explicitly reports
`delivery_semantics: :at_least_once`.

HTTP deployments may provide `:principal_id` and `:tenant_id` as strings or
resolver functions. OAuth token `sub` and `tenant_id` claims are used by
default when available; these identities are authenticated into the sealed
state without embedding bearer tokens.

## Modern subscriptions (MCP 2026-07-28)

Open an immutable notification stream with `Arbor.MCP.Client.listen/3`. The call
returns only after `notifications/subscriptions/acknowledged`; events are sent
to the subscribing process with the acknowledged subscription reference:

```elixir
{:ok, subscription} =
  Arbor.MCP.Client.listen(client, %{
    "toolsListChanged" => true,
    "resourceSubscriptions" => ["file:///project/config.json"],
    "taskIds" => [task_id]
  })

receive do
  {:ex_mcp_subscription, ^subscription, method, params} ->
    handle_notification(method, params)
end

:ok = Arbor.MCP.Client.Subscription.cancel(subscription)
```

`taskIds` is defined by the `io.modelcontextprotocol/tasks` extension. The
client must declare that extension in its configured capabilities. Servers
using `tasks: :store` automatically authorize every requested ID against the
same principal, tenant, endpoint, and task store used by `tasks/get`; IDs that
are missing or not authorized are omitted from the acknowledged filter. A
server with a custom task backend must provide
`:authorize_subscription_filter` and must not acknowledge an ID until it has
performed the equivalent access check.

`subscribe_resource/3` and `unsubscribe_resource/3` retain their legacy RPC
behavior before 2026-07-28. On a modern connection they maintain one
ref-counted desired URI set. Changes open and acknowledge an immutable
replacement stream before cancelling the old stream; only the committed
subscription ID delivers compatibility events:

```elixir
{:ok, _subscription} = Arbor.MCP.Client.subscribe_resource(client, uri)

receive do
  {:ex_mcp_resource_updated, ^uri, params} -> handle_update(params)
end

{:ok, _result} = Arbor.MCP.Client.unsubscribe_resource(client, uri)
```

`unsubscribe_resource/3` sends `resources/unsubscribe` (legacy) or drops the
URI from the ref-counted modern set. Implement
`c:Arbor.MCP.Server.Handler.handle_unsubscribe_resource/2` on a raw handler.

### List-changed notifications

Listen for catalog changes, then refetch. The server publishes with the
matching `Arbor.MCP.Server.notify_tools_changed/1`, `Arbor.MCP.Server.notify_resources_changed/1`, or `Arbor.MCP.Server.notify_prompts_changed/1` helper:

```elixir
{:ok, subscription} =
  Arbor.MCP.Client.listen(client, %{
    "resourcesListChanged" => true,
    "promptsListChanged" => true,
    "toolsListChanged" => true
  })

receive do
  {:ex_mcp_subscription, ^subscription, "notifications/resources/list_changed", _params} ->
    {:ok, resources} = Arbor.MCP.Client.list_resources(client)

  {:ex_mcp_subscription, ^subscription, "notifications/prompts/list_changed", _params} ->
    {:ok, prompts} = Arbor.MCP.Client.list_prompts(client)

  {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed", _params} ->
    {:ok, tools} = Arbor.MCP.Client.list_tools(client)
end

:ok = Arbor.MCP.Server.notify_resources_changed(server)
:ok = Arbor.MCP.Server.notify_prompts_changed(server)
:ok = Arbor.MCP.Server.notify_tools_changed(server)
```

After reconnect, subscriptions are opened with fresh JSON-RPC IDs. ArborMCP
refetches each affected list, resource, and task, then emits
`{:ex_mcp_subscription_resync, subscription, {:complete, snapshot}}` for a
generic subscription or `{:ex_mcp_resource_resync, subscription, snapshot}`
for the resource compatibility wrapper before releasing queued events.

Server listener defaults are 1,000 global registrations, 100 per principal,
500 per tenant, 100 queued events per listener, a 1 MiB encoded-message cap,
an 8 MiB aggregate queue cap, a one-hour maximum lifetime, 256 resource URIs,
256 task IDs, and a 64 KiB filter. Configure the registry child directly with
`:max_queue`, `:max_message_bytes`, and `:max_queue_bytes`, or pass the
corresponding server options (`:subscription_max_queue`,
`:subscription_max_message_bytes`, `:subscription_max_queue_bytes`,
`:subscription_max_lifetime_ms`, `:authorize_subscription_filter`, and
`:authorize_subscription_publication`). A message that exceeds its individual
cap, or a slow consumer that exhausts either queue bound, is closed fail-safe.
Publication authorization is checked again for every event; denial gracefully
closes the stream.

For clustered HTTP, start the application's PubSub process before each Runtime
that owns a subscription service. Configure that service's storage/fanout adapter
through its descriptor; a raw `:subscription_registry` selector is retired:

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http,
   services: [
     subscriptions: [
       options: [
         adapter:
           {Arbor.MCP.Server.Subscriptions.PubSub,
            pubsub_server: MyApp.PubSub,
            topic: "my_app:mcp:subscriptions:v1"}
       ]
     ]
   ]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

`Arbor.MCP.Server.Subscriptions.PubSub` has no hard Phoenix dependency. Its
`:pubsub_module` defaults to `Phoenix.PubSub` and may be replaced by any module
implementing `subscribe/2` and `broadcast_from/4`. Registrations and listener
processes stay node-local; untargeted publications fan out and each receiving
listener rechecks authorization. Publications carrying a `:transport_ref`
stay on the owning node. `publish/3` counts describe synchronous work in the
called registry, not eventual work on peers.

The bundled ETS storage makes global/principal/tenant limits per-node. If a
deployment requires cluster-wide quotas, supply a storage adapter backed by a
shared, atomic data store via the PubSub adapter's `:storage_adapter` option.
That adapter must still return only entries whose listener processes belong to
the current registry; use the shared store for reservation/accounting rather
than attempting to call remote listener PIDs as local registrations.

Over modern Streamable HTTP, each `subscriptions/listen` call is a dedicated
POST response stream. Cancelling `Arbor.MCP.Client.Subscription` closes that HTTP
response; it does not POST `notifications/cancelled`. An unexpected response
close opens a new listen request with a fresh JSON-RPC ID and runs the resync
flow described above. The server sends an SSE comment keepalive every 15
seconds by default so quiet disconnects are detected and intermediaries do not
expire an otherwise healthy stream:

```elixir
# In Application.start/2, before the borrowed Phoenix endpoint:
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http,
   protocol_mode: :modern_only}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  protocol_mode: :modern_only,
  subscription_keepalive_interval_ms: 15_000,
  subscription_max_lifetime_ms: :timer.hours(1)
```

Set `:subscription_keepalive_interval_ms` to a positive integer or
`:infinity`. Disabling keepalives delays detection of a quiet peer disconnect
until the next notification or server-initiated closure.

## Legacy notifications (MCP 2024-11-05 through 2025-11-25)

Legacy peers deliver `notifications/tools/list_changed`,
`notifications/prompts/list_changed`, `notifications/resources/list_changed`,
and `notifications/resources/updated` on the connection itself, with nothing
that correlates them to a request. `Arbor.MCP.Client.subscribe_notifications/3`
registers a local filter for those notifications and delivers each match to
the subscriber process. It accepts the same filter keys as `listen/3`, minus
`taskIds`:

```elixir
{:ok, listener} =
  Arbor.MCP.Client.subscribe_notifications(client, %{
    "toolsListChanged" => true,
    "resourceSubscriptions" => ["file:///project/config.json"]
  })

receive do
  {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _params} ->
    {:ok, tools} = Arbor.MCP.Client.list_tools(client)

  {:ex_mcp_notification, ^listener, "notifications/resources/updated", %{"uri" => uri}} ->
    {:ok, content} = Arbor.MCP.Client.read_resource(client, uri)
end

:ok = Arbor.MCP.Client.unsubscribe_notifications(listener)
```

This is a local listener, not a server-acknowledged subscription. The client
sends `resources/subscribe` once per listened URI, shared across listeners,
and `resources/unsubscribe` when the last listener naming a URI is removed;
list-change notifications need no request. The requested filter is
authoritative: a resource update for a URI the filter does not name is never
delivered. On a modern peer the call returns `{:error, :use_listen}`; use
`listen/3` there.

The client monitors the subscriber and removes the listener when it exits.
Listeners survive an automatic reconnect: after the client re-initializes it
re-sends `resources/subscribe` for every listened URI and sends
`{:ex_mcp_notification_reconnected, listener, %{resubscribed: uris, failed: [{uri, reason}]}}`.
When the client gives up reconnecting, disconnects, or stops, each subscriber
receives `{:ex_mcp_notification_closed, listener, reason}`. The full message
and lifecycle contract is in `Arbor.MCP.Client.NotificationListener`.

## Completions

`completion/complete` suggests values for a prompt argument or a resource
template argument. The client sends a `ref` map; the server callback receives
that same map as its first argument.

```elixir
# Prompt argument
{:ok, result} =
  Arbor.MCP.Client.complete(
    client,
    %{"type" => "ref/prompt", "name" => "code_review"},
    %{"name" => "language", "value" => "el"}
  )

# Resource template argument
{:ok, result} =
  Arbor.MCP.Client.complete(
    client,
    %{"type" => "ref/resource", "uri" => "file:///"},
    %{"name" => "path", "value" => "/src"}
  )

# Server
@impl true
def handle_complete(%{"type" => "ref/prompt", "name" => "code_review"}, argument, state) do
  prefix = Map.get(argument, "value", "")
  values = Enum.filter(["elixir", "erlang"], &String.starts_with?(&1, prefix))
  {:ok, %{completion: %{values: values, total: length(values), hasMore: false}}, state}
end

def handle_complete(%{"type" => "ref/resource", "uri" => "file:///"}, argument, state) do
  prefix = Map.get(argument, "value", "")
  values = Enum.filter(["/src", "/test"], &String.starts_with?(&1, prefix))
  {:ok, %{completion: %{values: values, hasMore: false}}, state}
end
```

Advertise `completions: %{}` from `handle_initialize/2` or
`server/discover` when the handler implements `handle_complete/3`.

Protocol ping, progress tokens, and request cancellation live in the
[Protocol Guide](PROTOCOL_GUIDE.md).

## Modern Streamable HTTP headers (MCP 2026-07-28)

After a connection settles on MCP 2026-07-28, the HTTP client is stateless:
it neither sends nor retains `Mcp-Session-Id` or `Last-Event-ID`. Every POST
mirrors the body protocol version and method into `MCP-Protocol-Version` and
`Mcp-Method`; `tools/call`, `resources/read`, and `prompts/get` also send
`Mcp-Name`. Unsafe UTF-8, leading/trailing whitespace, control characters,
and values shaped like the Base64 sentinel are encoded automatically.

Tool input properties may opt into routing headers:

```elixir
%{
  "type" => "object",
  "properties" => %{
    "region" => %{
      "type" => "string",
      "x-mcp-header" => "Region"
    }
  }
}
```

After `tools/list`, a modern HTTP `tools/call` mirrors a present non-null
argument as `Mcp-Param-Region`. String, integer, and boolean properties are
supported, including nested property paths. Invalid, duplicate, unreachable,
or unsupported annotations cause the server to omit that tool from a modern
list response. On a `-32020` header mismatch the client refreshes `tools/list`
and retries the tool call exactly once inside the original timeout.

The ArborMCP DSL returns its complete tool set and therefore needs no cursor
coordination. A raw handler that paginates a dynamic tool set must filter and
sort the full source collection before it slices the requested page:

```elixir
def handle_list_tools(cursor, state) do
  tools =
    state.dynamic_tools
    |> Arbor.MCP.Server.ResultNormalizer.prepare_tools_list()

  {page, next_cursor} = MyApp.Cursor.page(tools, cursor)
  {:ok, page, next_cursor, state}
end
```

Result normalization repeats this validation as a defensive boundary, but it
cannot correct a handler-owned cursor calculated from invalid definitions.

The server validates standard and annotated headers against the body before
tool dispatch. Custom raw `Mcp-Method`, `Mcp-Name`, `Mcp-Session-Id`,
`Last-Event-ID`, and `Mcp-Param-*` values supplied through the client's
`:headers` option are removed and replaced by protocol-derived values on
modern requests.

Treat all `Mcp-Param-*` values as sensitive routing data. ArborMCP does not attach
raw request headers to its Plug/client debug logs or telemetry. Configure
reverse proxies, load balancers, APM agents, and access-log middleware to
redact `Mcp-Param-*` just as they redact `Authorization` and cookies; those
systems observe headers before ArborMCP can sanitize their logs.

At a reverse proxy or load balancer, preserve individual request-header field
instances through the upstream hop or reject duplicates at the edge. Do not
collapse duplicate `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, or
`Mcp-Param-*` fields by selecting one value: once discarded, the application
cannot distinguish an ambiguous request from a valid one. It is safe for an
intermediary to apply a smaller header-size limit and reject early.

For response streams, use an HTTP/1.1-or-newer upstream connection, disable
request and response buffering, disable transformation/caching, preserve
`Content-Type: text/event-stream` and `X-Accel-Buffering: no`, and set the
proxy idle timeout above `:subscription_keepalive_interval_ms`. The automated
proxy-boundary matrix sends literal HTTP bytes through two Cowboy connections
and a normalizing, buffering forwarding hop. Deployment CI should run the same
valid/duplicate/oversized/stream cases against the exact Nginx, HAProxy,
Envoy, ingress, or managed load-balancer configuration used in production.

### Modern result cache hints

MCP 2026-07-28 requires `ttlMs` and `cacheScope` on complete results from
`server/discover`, `tools/list`, `prompts/list`, `resources/list`,
`resources/templates/list`, and `resources/read`. ArborMCP supplies conservative
defaults when a handler omits them:

```elixir
%{
  ttlMs: 0,
  cacheScope: :private
}
```

`ttlMs: 0` means immediately stale; `private` prevents reuse across
authorization contexts. A handler may return `ttl_ms` / `cache_scope` or the
wire keys `ttlMs` / `cacheScope` to override those defaults. TTL must be a
non-negative integer and scope must be `:public`, `:private`, `"public"`, or
`"private"`. Only use `public` when the result is safe to share across users,
including on authenticated endpoints. Each paginated response page carries
its own hints, and ArborMCP removes cache hints from `input_required` results.

Modern clients reject missing or invalid required hints. With the default
`:struct` response format they are available as `response.ttlMs` and
`response.cacheScope`; `format: :map` preserves the wire keys. ArborMCP currently
parses and validates these hints but does not store or reuse responses. This
is the deliberate 1.0 scope: a client cache would add authorization
partitioning, invalidation races, memory bounds, and MRTR exclusion to the
final release candidate. Repeated calls therefore still reach the transport,
even for a positive public TTL, and a later operation never reuses an earlier
`requestState`. Cache storage remains a post-1.0 additive feature.

Pass request-local context into a handler with `:handler_opts`. The option can
be a static term, a one-arity function called with the `Plug.Conn`, a two-arity
function called with the `Plug.Conn` and decoded JSON-RPC request, or an MFA
tuple called as `apply(module, function, [conn, request | extra_args])`. Its
bounded result is available at `Arbor.MCP.Server.Context.current().application_context`;
it does not rerun handler initialization or replace the Runtime handler state.

```elixir
# In Application.start/2, before the borrowed Phoenix endpoint:
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime,
   handler: MyApp.MCPServer,
   handler_args: [],
   transport: :mounted_http}
]
Supervisor.start_link(children, strategy: :one_for_one)

# In the router:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyApp.MCPRuntime,
  handler_opts: fn conn ->
    [current_user: conn.assigns[:current_user]]
  end
```

## Resilience

Retries:

```elixir
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
  retry_policy: [max_attempts: 3, initial_delay: 100, max_delay: 2_000]
)
```

Circuit breaker and health checks:

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

## Observability

### Operational telemetry and alerts

The MCP 2026-07-28 migration emits bounded operational events for era
selection, fallback and downgrade observations; unsupported-version retries;
MRTR rounds, failures and replay rejection; subscription reconnect and queue
pressure; and ambiguous HTTP reissue. See `Arbor.MCP.Telemetry` for the event list
and exact metadata shapes. Client response-cache hit/miss events are absent in
1.0 because response storage/reuse is deliberately deferred.

Build deployment alerts from counts and rates, not raw payload dimensions:

- alert on any sustained `:downgrade_attempt`, and investigate even a single
  unexpected event for an endpoint previously pinned modern;
- alert immediately on MRTR `:request_state_key_unknown` or
  `:request_state_key_revoked`, and rate-alert on `:replay_rejected` or replay
  cache failures;
- watch the ratio of subscription queue `:closed` to `:coalesced`, plus
  reconnect attempts that repeatedly fail to reach `phase: :complete`;
- investigate spikes in unsupported-version retries, legacy fallbacks, or
  ambiguous HTTP reissues during a rollout.

Choose thresholds from normal traffic volume and rollout policy. Event
metadata never includes tool arguments, `_meta`, `inputResponses`, resource
contents or URIs, `Mcp-Param-*`, `requestState`, key IDs, credentials, raw
subscription IDs, filters, principals, or tenants. Preserve that boundary in
custom telemetry handlers and exporters.

## Logging

This section configures application/runtime logging. The MCP wire-level Logging
feature (`logging/setLevel`, per-request log levels, and
`notifications/message`) is deprecated as of MCP 2026-07-28 but remains
available throughout ArborMCP 1.x. New observability integrations should use
stderr for stdio diagnostics or OpenTelemetry for structured telemetry.

For stdio servers, stdout must contain only JSON-RPC messages. ArborMCP 2.0
preserves the host's Logger levels, handlers, filters and application settings
during application startup and stdio connection. Configure every host log sink
before application startup so diagnostics cannot reach the protocol stream.
For a compiled release, put this in the host's configuration:

```elixir
# Host config/runtime.exs or config/config.exs
config :logger, :default_handler, config: [type: :standard_error]
```

This sends the default handler to stderr and preserves normal log levels.
Additional handlers must also use non-protocol sinks. A dependency's own config
is not loaded by its consumers. The old `config :arbor_mcp, stdio_mode: true`
flag no longer suppresses logging automatically.

The exported <code>Arbor.MCP.Internal.StdioLoggerConfig.configure/0</code> remains an
explicit legacy host opt-in: it sets the library flag and VM-global Logger,
`:logger` application and OTP primary levels to `:emergency`. It does not route
logs to stderr and suppresses unrelated application logs. No library startup or
transport connection calls it in 2.0.

Standalone commands and examples route their own default handler to stderr
before starting applications. For an already running VM, OTP's `:logger_std_h`
requires replacing the host-owned handler to change its `:type`; updating that
field in place is unsupported. Preserve the handler's level, formatter, filters
and other configuration when replacing it. `Mix.install/2` can still print
compiler/dependency output before the protocol starts even with `verbose: false`;
use compiled releases for clean stdout from process boot.

Send ad hoc diagnostics to stderr:

```elixir
IO.puts(:stderr, "debug")
```

Security-boundary logs describe payload types and sizes and use short hashes
for opaque session, progress, and origin identifiers. OAuth failures and HTTP
handler results are not rendered verbatim. Preserve that rule in custom
handlers: record a correlation ID and safe error class locally, and return a
stable generic error across the wire.

For HTTP and BEAM-local development:

```elixir
Logger.configure(level: :debug)
```

## Security

HTTP clients can use headers:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://api.example.com/mcp",
  headers: [{"Authorization", "Bearer #{token}"}]
)
```

For server-side HTTP concerns, compose Plug/Phoenix pipelines before
`Arbor.MCP.HttpPlug`.
