# Library features

ArborMCP provides more than MCP message handling. This guide describes the
Elixir APIs and operational behavior applications can build on. These are
features of the implementation, not new MCP protocol capabilities or claims
that no other SDK provides them. For wire-level coverage, see the
[MCP feature matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md).
Its [extensions section](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md#mcp-extensions)
lists Tasks and the two Auth profiles separately from core MCP, including their
supported roles, tests and remaining limits.

The library is on the v2 release-candidate line. Supported APIs are listed in
the [API reference](API_REFERENCE.md); the [RC notes](guides/V2_RELEASE_CANDIDATE.md)
describe qualification limits. ACP and vendor-agent integrations are separate
[ArborACP packages](https://github.com/trust-arbor/arbor_acp).

## Forwarding and embedded proxies

Use an ArborMCP server and upstream clients inside an existing OTP application
to forward requests for another client. No separate gateway deployment is
required. The client provides:

- Manual MRTR, returning an unfinished round distinctly and accepting the
  downstream client's input responses and upstream request state on a retry.
- Per-request client capabilities, so upstream servers choose input methods
  the downstream client can answer.
- Per-call progress targets, including the originating client PID and token.
- Caller-exit cancellation and independent modern HTTP requests, so one slow
  forwarded call need not block other calls through the same client.

The application supplies routing, authorization and identity-scoped upstream
clients. Forwarding subscriptions requires a long-lived bridge; `progress_to:`
does not relay catalog/resource/task events automatically. Manual resource
reads support MRTR continuation but cannot currently combine it with forwarded
progress through `read_resource/3`'s public options. See
[forwarding clients](CONFIGURATION.md#forwarding-clients-mcp-2026-07-28) and
[progress delivery](PROTOCOL_GUIDE.md#progress-to-another-process).

The repository's
[embedded forwarding example](https://github.com/trust-arbor/arbor_mcp/tree/master/examples/forwarding_gateway)
is a controlled Stage 0 integration fixture, not a packaged gateway product or
proof of compatibility with every coding harness.

## Server authoring and application integration

| Feature | What it provides | Contract and details |
| --- | --- | --- |
| Supervised Runtime per server | One owner for handler execution, transports, scoped services and shutdown; concurrent callbacks by default. | Stateful execution is available for serialized state changes. Runtime count/byte/deadline limits cover managed work, not arbitrary application state or VM memory. [Runtime guide](RUNTIME_GUIDE.md). |
| Compile-checked server DSL | Declare tools, resources and prompts alongside schemas; validate declarations, duplicates and constraints while compiling. | DSL components compose into one host Runtime and state shape. [DSL guide](DSL_GUIDE.md). |
| Existing Plug/Phoenix hosting | Mount MCP beside an application's existing routes and authentication; choose an optional standalone Cowboy/Bandit listener when useful. | A mount borrows its host listener. Owned constructors have a narrower qualified backend-version contract. [HTTP listeners](HTTP_LISTENERS.md), [Phoenix integration](guides/PHOENIX_GUIDE.md). |
| Request middleware | Add auditing, access checks or transformations around dispatched requests without repeating them in every handler. | `Server.Middleware` runs in the callback process and deadline, cannot change method/ID, and does not own handler state. Runtime cancellation and pre-dispatch rejections bypass it. [Middleware configuration](RUNTIME_GUIDE.md#middleware). |
| Runtime registration | Add, replace and remove tools, resources, templates and prompts without rebuilding a DSL module. | Public `Server.add_*` / `remove_*` APIs retain entries for the Runtime lifetime and issue list-change notifications. [Dynamic registration](DSL_GUIDE.md#adding-tools-at-runtime). |
| Request-local context and output | Access validated identity, capabilities, continuation data and headers; emit progress against the active request. | `Server.Context` belongs to the callback process and is not inherited by spawned tasks. [Configuration](CONFIGURATION.md), [protocol guide](PROTOCOL_GUIDE.md). |

## Client ergonomics and lifetime management

| Feature | What it provides | Contract and details |
| --- | --- | --- |
| Explicit protocol-era policies | Choose `:modern_only`, `:legacy_only`, `:prefer_modern` or `:prefer_legacy` without handling negotiation in application code. | Preference modes use evidence-based fallback; modern observations prevent silent downgrade. Stdio fallback confirms cleanup before starting a fresh child. [Protocol modes](CONFIGURATION.md#protocol-eras-and-modes). |
| Complete results with explicit extraction | Preserve structured content, metadata and tool-error flags; select text/content helpers when desired. | Canonical operations return complete responses. A protocol-success result may have `isError: true`. [API reference](API_REFERENCE.md). |
| Bounded pagination collectors | Collect catalog pages through `Client.all_tools`, `all_resources`, `all_resource_templates` and `all_prompts`. | One total deadline and finite page/item/byte bounds; collectors discard page metadata deliberately. Use `list_*` for full individual pages. [API reference](API_REFERENCE.md). |
| Owned client scopes | Use `Client.with_connection/2,3` for temporary clients with cleanup when the callback or owner exits. | Borrowed servers survive client cleanup. The API reports confirmed cleanup or a tagged cleanup failure rather than equating process death with resource release. [Runtime guide](RUNTIME_GUIDE.md). |
| Reconnection and idle health checks | Recover connections with bounded attempts/backoff and detect idle peers that stop answering pings. | Explicit disconnect/stop does not reconnect, and reconnection does not replay pending application operations. [Transport guide](TRANSPORT_GUIDE.md). |
| Response caching and invalidation | Reuse fresh client-local catalog pages and resource reads; refresh or bypass per call. | Bounded to 512 entries, 16 MiB total and 1 MiB per entry. Notifications invalidate relevant results; reconnect clears the cache. Keep one authorization context per client. Manual/per-request-capability forwarding bypasses this cache. See `Arbor.MCP.Client`'s Response cache documentation. |
| Retry policy and delivery classification | Configure retry/backoff and circuit breakers; inspect `Client.delivery_outcome/1` before deciding what a failure means. | Unknown delivery does not establish that repeating a side-effecting operation is safe. Modern HTTP stream outcomes are not recorded by the circuit breaker. [Resilience configuration](CONFIGURATION.md#resilience). |
| Subscription lifecycle helpers | Open acknowledged immutable filters, replace resource-interest streams before canceling old ones, and reconnect with resynchronization. | Legacy notification listeners are also available. Resync is not lossless event replay; aggregate pagination and gateway bridging remain application work. [Subscriptions](CONFIGURATION.md#modern-subscriptions-mcp-2026-07-28). |

## Trust, validation and continuation controls

| Feature | What it provides | Contract and details |
| --- | --- | --- |
| Outbound trust policy | Exact trusted origins, consent checks, credential stripping and DNS/IP validation for outbound requests. | Defaults fail closed for untrusted origins; declare the intended origins instead of disabling protections. [Security guide](SECURITY.md#outbound-requests-trusted-origins-and-consent). |
| OAuth integration boundaries | Discovery, PKCE, token providers, issuer-partitioned storage contracts and separate enterprise IdP/AS credentials. | Optional `:idp_auth` and `:as_auth` independently support Basic/POST/JWT. OIDC, refresh-token and SAML-transition inputs have scoped contract and interop evidence. Applications supply persistent secret storage and identity/account-linking policy. [Authorization configuration](CONFIGURATION.md#enterprise-idp-client-authentication), [security](SECURITY.md). |
| Bounded JSON Schema work | Validate tool inputs and schema resources with explicit dialect/reference policy and finite size/depth/time budgets. | Remote references are disabled by default; unsupported dialects reject. No general value coercion or default insertion is promised. [Schema guide](SCHEMAS.md). |
| Sealed MRTR state and replay protection | Encrypt/authenticate continuation state, bind it to the request and identity, rotate keys, and optionally enforce atomic single use. | Encryption alone does not prevent replay. Bundled replay storage is node-local and cannot promise exactly-once remote effects. [MRTR configuration](CONFIGURATION.md#multi-round-trip-requests-mcp-2026-07-28), [security](SECURITY.md). |
| Bounded parallel input handling | Opt into 2–16 concurrent MRTR input callbacks through `Client.Handler.mrtr_input_concurrency/0`. | Default dispatch is sequential and deterministic; parallel callbacks must return unchanged handler state. [MRTR configuration](CONFIGURATION.md). |
| Scoped storage and fan-out adapters | Configure Runtime-owned services, task/replay limits, custom adapters and optional subscription PubSub. | Runtime durable sessions remain unqualified. Standalone DETS is node-local; default quotas are per node. [Storage guide](STORAGE.md), [subscription configuration](CONFIGURATION.md). |

## Operations and downstream development

- **Tagged inspection and diagnostics.** `Client.status` and `Server.stats`
  expose supported operational views; normal OTP diagnostic reports omit
  retained payloads. Trusted in-VM inspection and application logging can still
  expose data. See [diagnostics](DIAGNOSTICS.md).
- **Telemetry and trace propagation.** Operational events support monitoring;
  validated W3C trace context and bounded, allowlisted baggage can travel in MCP
  metadata without an OpenTelemetry SDK dependency. Event fields vary: some
  documented events include tool names, request IDs or resource URIs. Inspect
  exact metadata before exporting it. See `Arbor.MCP.Telemetry` and
  [configuration](CONFIGURATION.md).
- **Published testing helpers.** `Testing.Builders`, `Testing.Assertions`,
  `Testing.MockServer` and `Testing.MockTransport` are available to consumer
  tests. Repository-only Mix tasks and internal test fixtures are excluded
  from the package; do not depend on them downstream.
- **Managed native stdio through ArborRPC.** Shared framing, controlled child
  environments and owned shutdown live in ArborRPC. Native use needs a C17
  compiler at source installation on qualified Unix platforms; an assembled
  release includes the helper and needs no runtime compiler. Windows native
  subprocesses are unsupported. See [transports](TRANSPORT_GUIDE.md).
- **Packaged agent usage rules.** The package includes supported API, result,
  lifecycle and DSL guidance for downstream coding agents. Optional UsageRules
  tooling can sync it into a host project's agent instructions without adding
  a runtime dependency. See [agent guidance](../README.md#ai-agent-guidance).

These features can be used independently. Building a forwarding handler does
not require adopting a new deployment, an application-specific client pool or
every storage/extension mechanism in this guide.
