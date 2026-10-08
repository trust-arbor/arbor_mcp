# MCP and ACP Security Audit — 2026-08-12

## Scope and baseline

This audit reviewed ArborMCP at baseline `eeb8583`, including both client and
server roles, every bundled transport, OAuth authorization, session/replay
state, the native ACP implementation, and the Codex ACP adapter. Conformance
was checked against the official [MCP specifications](https://modelcontextprotocol.io/specification)
and [ACP v1 specification](https://agentclientprotocol.com/protocol/v1/overview).

The review assumed every remote MCP/ACP peer, discovered OAuth endpoint,
session identifier, JSON-RPC field, subprocess, path, and adapter-provided
configuration value may be hostile. Findings were remediated in the working
tree rather than left as a report-only plan.

## Findings and disposition

| ID | Severity | Finding | Resolution |
|---|---|---|---|
| MCP-01 | High | Exact trusted-origin grants discarded scheme and port, permitting credential forwarding to another origin. | Trust now compares canonical scheme, host, and effective port. Broad host/wildcard trust is a separate, documented compatibility policy. |
| MCP-02 | High | OAuth clients lacked complete hostname verification, redirect controls, deadlines, and hard response bounds. | OAuth uses a pinned, hostname-verifying passive HTTP client with no automatic redirects, finite deadlines, identity encoding, header limits, and incremental response limits. |
| MCP-03 | High | Discovered authorization, token, registration, and redirect endpoints could become second-order SSRF or credential-exfiltration sinks. | Every discovered endpoint is parsed, DNS-validated, public-address checked, pinned, and same-issuer-origin by default. Redirects are bounded, cycle-free, and revalidated at every hop. |
| MCP-04 | High | Resource-server bearer validation accepted `active: true` without binding issuer/audience/resource or token times. Introspection credentials were unused. | Introspection is authenticated and tokens require configured issuer and audience/resource bindings plus valid `exp`/`nbf`. External failures are generic. |
| MCP-05 | High | Protected Resource Metadata and scope mapping could advertise invalid metadata or authorize modern/custom methods through broad fallback scopes. | Metadata now has a canonical HTTPS resource, authorization-server issuers, and header-only bearer method. Every standard method is explicitly mapped; unknown/custom methods fail closed unless configured. |
| MCP-06 | High | Legacy sessions accepted caller-selected IDs, lacked principal/tenant binding and an initialize-once lifecycle, and could be created outside initialization without a capacity limit. | IDs are server-issued only, created by initialization, identity-bound for their lifetime, and capped globally. Initialization is atomically claimed once, monitored, version-bound only on success, and rolled back on failure or request death. Streamable GET/POST require a successfully initialized session. |
| MCP-07 | High | Duplicate JSON-RPC request IDs could execute twice because validator state was not persisted. | IDs are atomically claimed per session/process, retained for the bounded session lifetime, and rejected before dispatch. |
| MCP-08 | High | HTTP/SSE/stdio response, frame, queue, handshake, and replay paths had unbounded or post-allocation limits. | Requests, responses, incomplete frames, replay storage, subscription queues, stream delivery, handshakes, retries, and stdio frames now have byte/count/deadline limits and slow-consumer handling. |
| MCP-09 | Medium | Progress tokens were global and logs/telemetry exposed request data, opaque IDs, URLs, issuers, commands, or upstream errors. | Progress is owner/session scoped. Logs and telemetry use structural summaries or non-reversible fingerprints; peer-facing errors omit internal details. |
| MCP-10 | Medium | Legacy HTTP protocol-version validation rejected initialization yet did not bind later requests to the negotiated session version. | Initialization negotiates from `params.protocolVersion` without requiring the HTTP header. Subsequent headers are checked against the stored negotiated version; malformed, duplicate, and unsupported headers are rejected. |
| MCP-11 | High | MCP HTTP connected by hostname after trust checks and accepted caller-controlled `Host`, leaving DNS-rebinding and virtual-host authority gaps. | Every POST, GET/SSE, retry, and DELETE validates the complete A/AAAA answer, pins Mint to one approved IP, retains the URI host for SNI/certificate/Host, and discards caller-supplied Host. Private targets need an exact explicit hostname exception; link-local/reserved/mixed answers remain denied. |
| ACP-01 | High | Native ACP subprocesses inherited the complete parent environment. | Subprocesses use an isolated runtime allowlist by default and accept only explicit variable grants. Full inheritance is an explicit unsafe compatibility option. |
| ACP-02 | High | Requests could run before initialization or after duplicate initialization; malformed version negotiation was accepted. | ACP now has an initialize-once lifecycle state machine and strict v1 request/result validation. |
| ACP-03 | High | Duplicate prompt IDs, orphaned requests, unbounded frames/updates/outboxes/tasks, and slow consumers could corrupt state or exhaust memory. | Outstanding IDs are unique, callers are monitored, deadlines clean pending state, and frame/queue/task/event/prompt limits plus backpressure are enforced. |
| ACP-04 | High | Peer-supplied workspaces and MCP server definitions could expand Codex filesystem/process/network authority. | Workspaces are canonicalized and confined to configured roots. MCP servers require an authorization callback or exact operator-owned map; name-only trust was removed. |
| ACP-05 | Medium | File/terminal requests lacked full schema, absolute-path, session-root, and symlink containment checks. | ACP v1 fields are validated before callbacks; filesystem and terminal paths must remain within the canonical session roots. Writes/terminal/permissions remain denied by the default handler. |
| ACP-06 | Medium | Handler exceptions and stack traces were returned to the peer. | Detailed failures stay in redacted local logs; the wire receives stable generic errors. |
| ACP-07 | Medium | Explicit JSON-RPC `id: null` was conflated with notifications, and malformed `session/update` payloads reached callbacks. | Absent IDs and explicit null IDs are distinct; one outstanding null ID is supported with duplicate/timeout cleanup. Session updates are validated against the ACP v1 discriminated union before dispatch. |
| SUP-01 | Medium | CI actions used mutable tags, broad default token permissions, and a stale ACP SDK oracle. | Actions are commit-pinned, workflow permissions are read-only, checkout credentials are not persisted, and ACP interop is pinned to SDK `1.3.0`. |

## Remediation plan and rollout order

The implementation followed this dependency order:

1. Establish hard trust boundaries: exact origins, endpoint validation, TLS,
   OAuth issuer/audience binding, isolated environments, and ACP authority
   callbacks.
2. Enforce protocol lifecycle and identity: initialize/version negotiation,
   server-issued sessions, session identity binding, request-ID uniqueness,
   and ACP initialize-once behavior.
3. Add resource controls at ingress and before allocation: request/frame/header
   limits, response streaming limits, deadlines, replay/queue byte accounting,
   pending-call cleanup, and slow-consumer backpressure.
4. Reduce privacy exposure: sanitize peer errors, replace raw identifiers and
   URLs in logs/telemetry, scope progress/state by owner, and isolate child
   environments.
5. Lock conformance and supply-chain checks in CI, then document every
   compatibility escape hatch.

Deployers should configure OAuth issuer/audience and introspection credentials,
declare exact outbound origins, set application-specific ACP workspace/MCP
authorization callbacks, and tune byte limits for their largest legitimate
messages before rollout. Test staging without the legacy escape hatches first.

## Intentional compatibility escape hatches

These options weaken a security boundary and should not be ordinary production
defaults:

- `legacy_unbound_tokens: true` accepts bearer tokens without strict resource
  and issuer binding during a controlled migration.
- `trusted_hosts` grants broad host-only trust across schemes/ports; use
  `trusted_origins` for remote services.
- `environment_policy: :inherit` exposes the parent environment to an MCP/ACP
  subprocess.
- Codex `trusted_mcp_servers: :all` accepts caller-supplied executable, URL,
  header, and environment details.
- `allowed_private_hosts` permits an exact MCP hostname to resolve to RFC 1918
  or IPv6 ULA space. Keep the list empty unless an internal MCP endpoint is an
  intentional trust boundary; link-local and reserved addresses are never
  enabled by this option.

Environment isolation and path allowlists are defense-in-depth controls, not an
operating-system sandbox. Run third-party agents and MCP servers under a
separate low-privilege account/container when they are not fully trusted, and
keep application-specific authorization in handlers.

## Known upstream dependency advisories

Cowlib `2.19.0` is the newest release as of the audit date and retains one
medium response-header and one low cookie-encoder advisory. ArborMCP's Plug path
rejects CR, LF, and NUL response-header bytes before Cowlib serialization, and
no ArborMCP module imports the affected `cow_cookie:cookie/1`. Regression tests
lock both assumptions. The two exact Hex exceptions are owned by project
maintainers, expire for review on 2026-09-12, and must be removed immediately
when a patched Cowlib is available; every other advisory still fails CI.

The Node interop oracle overrides its transitive `@hono/node-server` to patched
version `2.1.0`; `npm audit --omit=dev` reports zero vulnerabilities.

## Verification record

- Warnings-as-errors compilation and formatting checks.
- MCP and ACP unit, property, and doctest suites.
- Official MCP client/server conformance harnesses for supported revisions.
- ACP v1 interoperation against `@agentclientprotocol/sdk` `1.3.0`.
- Focused adversarial tests for wrong-host TLS, cross-origin redirects, private
  and mixed DNS answers, Host override, fragmented/oversized frames, duplicate
  and null IDs, initialization races, identity crossing, symlink escapes,
  queue limits, missing deadlines, and secret redaction.
- Hex/npm advisory review and immutable CI action verification.

Exact final command counts are recorded in the implementation handoff for this
audit so they cannot become stale when the test suite grows.
