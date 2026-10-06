# ArborMCP Security Guide

Security is handled at the protocol edge: HTTP clients and Plug/Phoenix servers
use authentication, TLS, origin checks, and CORS; stdio relies on subprocess
isolation; BEAM-local relies on local process ownership and application-level
authorization.

Outbound requests additionally pass through a trust boundary that strips
credentials from, and requires consent for, origins the application has not
declared. Its defaults are fail-closed, so read
[Outbound Requests](#outbound-requests-trusted-origins-and-consent) before
pointing a client at a remote server.

## Security Matrix

| Feature | Streamable HTTP | stdio | BEAM-local (`:beam`) |
|---------|-----------------|-------|----------------------|
| Bearer/custom headers | Yes | No | App-level metadata/handler logic |
| OAuth 2.1 flows | Yes | No | No |
| TLS | Yes | No | Only through distributed Erlang if you add it |
| Origin/CORS checks | Yes | No | Not applicable |
| DNS rebinding protection | Server Host/origin checks plus outbound complete-answer validation and IP pinning | Not applicable | Not applicable |
| Outbound origin trust (`SecurityGuard`) | Yes | Yes, for `resources/*` URIs | Not applicable |
| Process isolation | Server process | Subprocess | Local BEAM process |

## Outbound Requests: Trusted Origins and Consent

`Arbor.MCP.Transport.SecurityGuard` runs on every outbound HTTP POST — the
JSON-RPC channel — and on the URIs of `resources/read` / `resources/list`
requests sent over stdio. It classifies the target URL against
`:trusted_origins` (exact origins) and `:trusted_hosts` (an explicitly broad
compatibility policy). For anything that is **not** trusted it:

1. removes credential headers (`authorization`, `cookie`, `x-api-key`,
   `x-auth-token`, `x-csrf-token`) so a token issued for one origin is never
   passed through to another, and
2. asks the configured `:consent_handler` to approve the origin, caching the
   decision until it expires.

**The defaults are fail-closed and this bites first-time users.**
`:trusted_origins` is empty, `:trusted_hosts` contains only loopback names, and
`:consent_handler` is
`Arbor.MCP.ConsentHandler.Deny`, so a client pointed at a server that is not on
localhost has its `Authorization` header stripped and the request denied with
`consent_denied`. Declare the servers your application talks to:

```elixir
config :arbor_mcp, :security,
  trusted_origins: ["https://mcp.example.com"]
```

A trusted origin is exempt from *both* checks — it is never stripped and never
prompts for consent. Consent then applies only to origins your application did
not declare. Exact trust compares the URI scheme, normalized host, and effective
port: trusting `https://mcp.example.com` does not trust HTTP or port 8443 on the
same host. Prefer this over disabling a control. Security logs identify the
decision using a non-reversible origin fingerprint rather than disclosing the
full URL or query string.

| Setting | Default | Effect |
|---------|---------|--------|
| `:trusted_origins` | `[]` | Exact HTTP(S) origins. Scheme, host, and effective port must match. Userinfo, query strings, fragments, and wildcards are rejected. |
| `:trusted_hosts` | `["localhost", "127.0.0.1", "::1"]` | Broad host-only compatibility trust across schemes and ports. `"*.example.com"` matches subdomains but not the apex. Avoid for remote production services. |
| `:consent_handler` | `Arbor.MCP.ConsentHandler.Deny` | Consulted for untrusted origins. `CLI` prompts; `Web` defers to an out-of-band flow. |
| `:consent_ttl` | 24 hours (milliseconds) | Lifetime of a cached consent decision. |
| `:enable_token_passthrough_prevention` | `true` | Set `false` to forward credentials to untrusted origins. |
| `:enable_user_consent_validation` | `true` | Set `false` to skip the consent handler entirely. |

Every consent decision path fails closed: a denial, an error, an
unrecognised handler return value, or an expiry that cannot be interpreted all
block the request.

### Writing a consent handler

`Arbor.MCP.ConsentHandler` implementations return an expiry. Use one of the
explicit forms — `DateTime`, `{:ttl, seconds}`, `{:unix, seconds}`, or
`{:monotonic, seconds}`:

```elixir
def request_consent(_user_id, _origin, context) do
  {:ok, {:ttl, Map.get(context, :consent_ttl, 3600)}}
end
```

A bare integer is still read as `System.monotonic_time(:second)` for backwards
compatibility. Returning Unix epoch seconds as a bare integer is the easy
mistake — it would otherwise grant consent for decades — so implausible values
(already past, or more than 365 days out) are rejected and the request fails.

## HTTP Client Security

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    headers: [{"Authorization", "Bearer #{token}"}],
    security: %{
      validate_origin: true,
      allowed_origins: ["https://app.example.com"],
      tls: %{verify: :verify_peer}
    }
  )
```

For OAuth flows, use the authorization modules or `:auth` / `:auth_provider`
options on the HTTP transport.

A connection can also trust the exact origin it was configured for, without
changing the VM-wide policy that every other client shares:

```elixir
security: %{trusted_origins: ["https://api.example.com"]}
```

Those origins join `config :arbor_mcp, :security, trusted_origins: [...]` for
that connection's own requests only. Entries must be exact HTTP(S) origins
(scheme, host and optional port, no path); anything else fails at connect.

The HTTP transport applies finite connection/request deadlines, disables
automatic redirects, requests identity encoding, and enforces request,
response, and incomplete-stream limits incrementally. Configure
`:max_request_bytes`, `:max_response_bytes`, and `:max_stream_buffer_bytes` for
your application's largest legitimate message; over-limit peers are closed.

Every MCP POST, GET/SSE, authentication retry, and DELETE resolves the target,
rejects any mixed or non-public A/AAAA answer, and connects to one approved IP
while retaining the URI hostname for HTTP authority, TLS SNI, and certificate
verification. Caller-supplied `Host` is discarded. Named and literal loopback
targets remain available for local servers. An internal RFC 1918 or IPv6 ULA
target requires an exact `:allowed_private_hosts` entry; wildcards, link-local,
reserved, and metadata-service addresses remain denied.

### OAuth credential isolation

Modern pre-registered clients bind their credentials to an exact
authorization-server issuer through `credential_issuer`. ArborMCP rejects
mismatches without normalizing trailing slashes or paths, validates discovered
AS metadata against the issuer that led to it, and never resolves the client
secret before that check succeeds. CIMD client IDs are the deliberate portable
exception defined by the protocol.

Persistent hosts should implement `Arbor.MCP.Authorization.CredentialStore` using
an encrypted database or platform keychain. Registrations are keyed by issuer
and client ID; tokens additionally include resource/audience, subject or client
identity, and granted scopes. Credential values redact secrets from `Inspect`,
and adapter failures exposed through the OAuth flow omit adapter-provided error
details so a badly behaved store cannot place token material in logs. Unkeyed
legacy records require an explicit migration after their original issuer is
independently verified.

### OAuth metadata SSRF protection

Treat every URL learned during OAuth discovery as attacker-controlled. ArborMCP
routes CIMD, Protected Resource Metadata, OIDC/RFC 8414 authorization-server
metadata, and JWKS requests through `Arbor.MCP.Authorization.MetadataFetcher`.
The boundary requires HTTPS; forbids URI userinfo and fragments; bounds DNS,
connection and request time; bounds per-response and aggregate redirect bytes;
rejects compression; and follows only a bounded, cycle-free redirect chain.

DNS is resolved again for every hop. If any returned IPv4, IPv6, or IPv4-mapped
IPv6 address is private, loopback, link-local, reserved, documentation-only, or
otherwise non-public, the request fails before connection. The default client
connects to one validated address directly while retaining the URL hostname for
TLS SNI, certificate verification, and the HTTP host value. This closes the
validation/re-resolution gap used by DNS rebinding.

Redirects are same-origin unless an operator explicitly lists an exact HTTPS
destination in `allowed_redirect_origins`; an allowed destination is still
re-resolved and revalidated. Metadata requests use fixed non-secret headers and
never forward bearer tokens, cookies, client credentials, MCP session headers,
or application transport headers. URL-only custom client adapters are rejected
because they cannot prove address pinning.

The same network policy now applies to endpoints *contained in* discovered
authorization-server metadata. Token, authorization, registration,
introspection, revocation, and JWKS endpoints must be HTTPS, resolve only to
public addresses, and share the issuer's exact origin unless an operator grants
an exact exception. OAuth POST clients disable redirects and bound request and
response sizes. The loopback exception used for an application's own redirect
URI never permits a remote authorization server to advertise an internal
endpoint.

### TLS

HTTPS connections verify the peer against the OS trust store with TLS 1.2/1.3
and HTTPS hostname matching by default. The OS store is loaded with a
deadline; if it cannot be loaded, HTTPS requests fail closed rather than hang
or silently trust a different CA set. A fallback to the `castore` bundle is
available as an opt-in, with the trade-offs described under "TLS trust store"
in the configuration guide.
`tls: %{verify: :verify_none}` is
accepted for local development against self-signed certificates, but it makes
the connection unauthenticated — encrypted, yet open to an active
man-in-the-middle — and ArborMCP logs a warning whenever it is configured.

## HTTP Server Security

Use Plug/Phoenix pipelines for server-side concerns:

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
pipeline :mcp do
  plug Arbor.MCP.Plugs.DnsRebinding
  plug MyApp.VerifyRequestSignature
  plug MyApp.RequireMCPToken
end

scope "/mcp" do
  pipe_through :mcp

  forward "/", Arbor.MCP.HttpPlug,
    runtime: MyApp.MCPRuntime,
    protocol_mode: :prefer_modern,
    cors_enabled: true
end
```

Keep request authentication and authorization at the HTTP edge. Keep
tool/resource authorization in handler code when it depends on the specific
tool, resource URI, user, tenant, or project.

Legacy Streamable HTTP sessions are issued only by `initialize`. The server
atomically permits one initialization attempt, monitors its request process,
and exposes the session ID only after a successful response binds the negotiated
version. Later POST and GET requests require that issued initialized session,
matching authorization identity, and matching protocol-version header. Failed,
abandoned, repeated, and concurrent initialization attempts fail closed. The
deprecated 2024 HTTP+SSE endpoint remains a separate compatibility transport.

When `oauth_enabled: true`, configure a canonical HTTPS `:resource`, at least
one HTTPS `:authorization_servers` issuer, and an `:auth_config` that contains
the introspection endpoint, resource-server credentials, `:expected_issuer`,
and `:expected_audience` (or `:expected_resource`). Introspection uses
authenticated client credentials and rejects tokens with a missing or wrong
issuer/audience, expired `exp`, or future `nbf`, even when the endpoint reports
`active: true`. `legacy_unbound_tokens: true` is a migration-only escape hatch
that deliberately disables these bindings.

### MRTR request state

Modern multi-round requests use an ArborMCP-owned, versioned AES-256-GCM envelope.
The authenticated payload binds the immutable request digest, expected input
IDs, round, protocol version, endpoint, capability fingerprint, principal, and
tenant. It contains only bounded JSON application state—never bearer tokens or
runtime secrets.

Load the 32-byte key ring at runtime and retain decrypt-only old keys for at
least the maximum token TTL plus clock skew. `active_key_id` selects the only
encryption key; `revoked_key_ids` immediately prevents use of a compromised
key. Every node that may resume a request needs the same ring.

Rotate the ring in three separately observable deployments:

1. Add the new key to every node while the old key remains `active_key_id`.
2. After every serving node can decrypt both key IDs, roll `active_key_id` to
   the new key. Mixed snapshots remain interoperable during this deployment.
3. Remove the old decrypt-only key only after the greatest configured token
   TTL plus clock skew has elapsed since the final node stopped encrypting
   with it.

Treat each key-ring snapshot as one atomic runtime configuration value; never
roll an active key before its key material has reached every node. For an
emergency compromise, add the old ID to `revoked_key_ids` everywhere instead
of waiting for normal retirement. In-flight tokens using that ID then fail
closed and callers must restart the operation.

AEAD prevents tampering but not replay. Side-effecting resumptions should set
`require_replay_protection: true` and configure a shared replay-cache adapter.
`Arbor.MCP.Server.ReplayCache.ETS` is atomic but node-local and is therefore only
appropriate for single-node deployments. Without an adapter, handlers must
treat `RequestContext.delivery_semantics == :at_least_once` accordingly.

### Modern subscription streams

Subscription registrations store stable principal and tenant identifiers,
never bearer tokens. Filter authorization runs before acknowledgment and
publication authorization runs again for every event. Configure a bounded
maximum stream lifetime so credentials are periodically re-evaluated, and use
a cluster-aware adapter with PubSub fan-out for multi-node HTTP deployments.
The bundled ETS adapter and listener supervisor are node-local. Modern HTTP
streams treat an unsuccessful response chunk as cancellation, immediately
remove the listener registration, and send no further events. Periodic SSE
comment keepalives make this cleanup happen even when no application events
are available to expose a disconnected peer.

The PubSub adapter distributes only method names and protocol parameters; it
does not distribute credentials or registration records. Each node matches
against its own honoured filters and each listener re-runs publication
authorization using its stored stable identity. Use a deployment-specific
topic, protect access to the PubSub cluster, and do not place secrets in
notification parameters.

### DNS rebinding protection

Protection is Host-allow-list based and is **on by default for localhost
servers**, which are the prime rebinding target. `Arbor.MCP.HttpPlug` provides
three complementary controls:

- **Host allow-list** (`:allowed_hosts`): requests whose `Host` header is not
  listed are rejected with `421` before any routing or handler work. Ports are
  ignored and IPv6 hosts match with or without brackets (`[::1]:8080` matches
  `"[::1]"` and `"::1"`). Servers started through `Arbor.MCP.Server.Transport`
  with a localhost bind get `["localhost", "127.0.0.1", "[::1]", "::1"]`
  automatically; an explicit `:allowed_hosts` always wins. When you mount
  `Arbor.MCP.HttpPlug` yourself — in a Phoenix `forward`, say — set
  `:allowed_hosts` explicitly to the hostnames the server is reachable under
  rather than relying on the default.
- **Origin allow-list** (`:validate_origin`, default `true`, plus
  `:allowed_origins`): requests that carry an `Origin` header are rejected
  with `403` unless the origin is listed (or `:allowed_origins` is `:any`).
  Requests *without* an `Origin` header are allowed, because non-browser
  clients do not send one — so the Origin check alone is not rebinding
  protection, and the Host allow-list is what closes that gap. There is no
  "same origin as the Host header" fallback: under DNS rebinding the Host
  header is attacker-controlled, so such a comparison would always pass.
- **`Arbor.MCP.Plugs.DnsRebinding`**: a standalone plug for Phoenix/Plug
  pipelines that enforces a Host allow-list (default: loopback names only)
  in front of any downstream plugs.

On legacy Streamable HTTP paths, session IDs supplied via `mcp-session-id` /
legacy `x-session-id` headers are validated (max 128 bytes,
`A-Za-z0-9._~+/=-`) and malformed values are rejected with `400` without
being echoed back. A syntactically valid client-selected or expired ID is also
rejected: only server-issued active IDs are accepted. Each legacy session is
immutably bound to its authenticated principal, tenant, token issuer, and
resource audience, and POST, GET, and DELETE all re-check that binding. MCP
2026-07-28 is stateless; do not use a session header as authentication,
authorization context, tenant identity, or modern request correlation.

## JSON Schema References and Resource Limits

JSON Schema is executable input: resolving a reference can cause network I/O,
and adversarial composition can consume excessive CPU or memory. ArborMCP applies
the same policy to content helpers, tool argument validation, DSL output
schemas, the deprecated tools API, and the dynamic tool registry.

- Only same-document fragment references (`#` and `#/...`) are accepted by
  default. File, recursive cross-document, and dynamic cross-document
  references are always rejected.
- HTTP(S) `$ref` fetching requires an explicit non-empty host allowlist.
- Configuring ExJsonSchema's process-wide `:remote_schema_resolver` does not
  bypass this boundary.
- Encoded bytes, structural depth, schema-object count, composition depth,
  resolution time, and validation time are bounded.
- Policy errors do not include the rejected reference, avoiding accidental
  disclosure of credentials or sensitive internal URLs.

When network fetching is enabled, each redirect is independently allowlisted
and DNS-resolved. Any non-public IPv4/IPv6 answer rejects the target, and the
HTTP client connects to the approved IP while retaining the hostname for TLS
certificate verification and SNI. Userinfo and credentials are forbidden;
responses, document graphs, redirects, and deadlines are bounded; compressed
responses and proxies are rejected. Cross-document fetch cycles fail closed.

Remote documents live only inside the current compilation and are never put in
a global cache. Fetch audit logs include the allowed host plus hashes of the URI
and trust partition, not paths, queries, credentials, or raw partition IDs.

The complete limits, defaults, and opt-in example are in the
[Configuration Guide](CONFIGURATION.md#json-schema-resource-policy). Prefer
embedding definitions in the local schema whenever practical.

## Trace Context and Baggage

Treat `traceparent`, `tracestate`, and `baggage` in MCP `_meta` as untrusted
wire input. ArborMCP validates these fields before exposing them to handlers or
putting them on outbound modern requests. Malformed values reject request
metadata instead of being silently forwarded, and the sanitized `_meta` no
longer contains baggage members removed by policy.

Baggage is default-deny. Incoming baggage is subject to total-byte,
baggage-byte, member-count, syntax, and duplicate-key checks before the
allowlist is applied, so a disallowed member cannot bypass resource limits.
Keep the allowlist short and limited to non-secret, low-cardinality identifiers;
baggage can cross process and service trust boundaries and may be recorded by
observability infrastructure.

ArborMCP only transports the validated strings. It does not install an
OpenTelemetry SDK, create spans, or attach remote context to global/process
state. Applications that choose to continue a trace must do so explicitly from
`Arbor.MCP.Server.RequestContext.trace_context` using their own trusted telemetry
integration. See the
[configuration guide](CONFIGURATION.md#opentelemetry-metadata-policy) for the
defaults and client example.

## Durable Tasks

Modern task IDs may act as bearer handles to stored execution state. Generate
them with cryptographic entropy; `Arbor.MCP.Tasks.Task.new/3` does this by default,
but an application that supplies `:id` assumes that responsibility. Bind every
stored task to the authenticated principal, tenant, resource/audience, and
other authorization context needed by the deployment, and repeat that check on
every `tasks/get`, `tasks/update`, and `tasks/cancel` request. Possession of a
valid-looking task ID is not authorization.

Persist the task and its authorization binding before returning a
`resultType: "task"` handle. A successful creation response promises that an
immediate `tasks/get` can find the task, including after a worker, connection,
or client restart. Enforce TTL cleanup without reassigning identifiers, and use
atomic or concurrency-controlled transitions so late updates cannot overwrite
a terminal state.

`Arbor.MCP.Tasks.Store.ETS` provides this guarantee only while its owning ArborMCP
application remains running. It deliberately returns the same error for a
missing task and an ownership mismatch. Use a shared, restart-persistent
`Arbor.MCP.Tasks.Store` implementation when multiple nodes can serve task requests
or server-restart recovery is required.

Treat task `inputRequests` with the same consent and trust policy as the
corresponding elicitation, sampling, or roots request. Validate each
`inputResponses` key against the currently outstanding request set, make
retries idempotent, and never accept a response for a different task. Task
notifications carry full state and may contain result or error data; publish
them only through an authorized `subscriptions/listen` stream.

The modern protocol intentionally has no `tasks/list`, avoiding cross-caller
enumeration. Avoid recreating a list endpoint unless the application has a
well-defined authorization scope. See the
[configuration guide](CONFIGURATION.md#tasks-extension) for the explicit
capability opt-in and callback boundary.

## stdio Security

stdio is appropriate when the MCP server process is trusted by the application
that launches it.

Best practices:

- Use absolute commands or controlled PATHs for production.
- Keep the default `environment_policy: :isolated`, which passes only a small
  runtime allowlist, and grant required variables explicitly with `:env`.
- Use `environment_policy: :inherit` only for a fully trusted subprocess that
  genuinely needs the complete parent environment.
- Set `cd` explicitly.
- Do not log to stdout; stdout is protocol traffic.
- Run subprocesses with the least privileges needed.
- Validate tool arguments before touching filesystem or network resources.

Environment isolation prevents accidental credential inheritance; it is not a
filesystem, process, or network sandbox.

## BEAM-Local Security

`transport: :beam` is for trusted local Elixir processes:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)   # requires use of DSL, or use HandlerServer
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: server)
```

There is no wire-level authentication inside a single VM. Enforce access with
normal application structure: supervision boundaries, process ownership, handler
authorization, and explicit context in tool arguments or handler state.

If you cross Erlang nodes in your own application, secure distributed Erlang
separately with strong cookies, private networks, and TLS distribution where
appropriate.

## Validation

Use public validation helpers where available:

```elixir
Arbor.MCP.Security.Validation.validate_config(security_config)
```

Use `Arbor.MCP.Content.Validation` and handler-side schema checks for tool/resource
input validation.

### Verifying JWTs

`Arbor.MCP.Authorization.JWT.verify/2` checks the **signature only** — an expired
token verifies fine. Use `verify_and_validate/3` (or `validate_claims/2`) for
anything that makes an authorization decision:

```elixir
{:ok, claims} =
  Arbor.MCP.Authorization.JWT.verify_and_validate(token, jwks,
    iss: "https://auth.example.com",
    aud: "https://mcp.example.com"
  )
```

`exp` is required and must be numeric; `nbf` and `iat` must be numeric when
present. Time comparisons allow 30 seconds of clock skew, tunable with
`:leeway`. Pass `require_exp: false` only for a token profile that genuinely
has no expiry. Only asymmetric algorithms are accepted (RS/PS/ES) — `none` and
the HMAC family are rejected, so an attacker cannot swap the header's `alg`.

`iss` and `aud` are checked only when you supply the expected values; always
supply them when validating tokens from an identity provider.

### Authorization callback issuer validation

ArborMCP registers every library-started authorization-code transaction before
returning its authorization URL. It generates random 256-bit `state` and PKCE
values, stores only SHA-256 digests of state and authorization codes, and
atomically moves the transaction through pending, code-ready, and redeemed
states. Exactly one concurrent callback and one code redemption can succeed.

`Arbor.MCP.Authorization.validate_authorization_response/2` verifies state and,
when the callback includes the RFC 9207 `iss` parameter, requires exact
equality with the issuer recorded when the flow started. Issuer identifiers are
not normalized: a trailing slash or path difference is a mismatch. A present
`iss` is rejected when the transaction did not record an issuer. Redemption is
also bound to the exact redirect URI recorded at flow start.

The built-in full OAuth flow performs this validation automatically. It also
bounds callback request/query sizes, rejects duplicate callback parameters,
and does not log the authorization URL, callback URL, code, state, PKCE
verifier, cookies, client secrets, or tokens. OAuth error logging and telemetry
redact credential-shaped fields, authorization header values, and URL queries
and fragments.

Transactions remain redeemed before the token request is sent. This fail-closed
ordering prevents code replay: after a timeout or lost response, start a new
authorization flow instead of retrying the same code. The default transaction
store is bounded, expires records, and is node-local. Route a loopback callback
to the originating node; distributed browser callbacks require a strongly
consistent application-owned flow.

Caller-constructed transaction maps without the opaque `transaction_id` retain
their 1.x validation behavior for source compatibility, but do not gain atomic
replay protection. Always carry the transaction returned by
`start_authorization_flow/1` through callback validation and token exchange.

### MCP routing-header confidentiality

Treat every `Mcp-Param-*` value as sensitive. These values mirror selected
tool arguments and may contain tenant, region, account, or routing data.
ArborMCP does not include them in its HTTP debug logs or telemetry, but reverse
proxies, load balancers, APM agents, and access-log middleware may record
request headers independently. Configure those systems to redact
`Mcp-Param-*` with the same policy used for `Authorization` and cookies.

Modern HTTP servers compare protocol, method, name, and annotated parameter
headers with the JSON-RPC body before dispatch. Missing, duplicate, malformed,
oversized, or mismatched recognized headers return HTTP 400 with JSON-RPC
error `-32020`; the rejected header value is not copied into the response or
logs. Unsupported protocol-version errors may identify the requested version,
but `Mcp-Param-*` values are never echoed.

## Best Practices

- Use HTTPS in production.
- Prefer short-lived bearer tokens or OAuth flows.
- Do not send secrets through tool arguments unless the tool explicitly needs
  them.
- Validate resource URIs and file paths before access.
- Return safe error messages to clients; log sensitive details internally.
- Put coarse-grained HTTP checks in Plug pipelines and fine-grained MCP checks
  in handlers.
- Monitor telemetry for unusual request, auth, or transport failure patterns.

## Common Issues

**`{:security_violation, %Arbor.MCP.Transport.SecurityError{type: :consent_denied}}`**

The server's origin is not in `:trusted_origins` or `:trusted_hosts`, and the
default consent handler denied it. Add the exact origin — see
[Outbound Requests](#outbound-requests-trusted-origins-and-consent).

**401/403 from HTTP server**

Check `headers`, `auth`, or `auth_provider` on the client and the server's Plug
auth pipeline. If the request never carried the credential at all, look for a
`SecurityGuard: removed credential headers` warning in the log: the target
origin is not trusted, so the `Authorization` header was stripped before the
request went out.

**CORS failure**

Configure the Phoenix/Plug pipeline or `Arbor.MCP.HttpPlug` CORS options for the
browser origin.

**BEAM-local access control**

Pass explicit application context into the handler state or arguments and reject
unauthorized tool/resource calls inside the handler.
