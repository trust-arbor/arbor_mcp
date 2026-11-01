# MCP extension baseline assessment

Review date: 2026-10-31 (America/Chicago). ArborMCP source: [`5ea3884`](https://github.com/trust-arbor/arbor_mcp/tree/5ea3884cb8f3941a354b1c65b40176dc8bbaa429).
Upstream revisions are the immutable commits recorded in the initial inventory,
not moving default branches. This is an assessment of implementation scope and
compatibility gaps, not certification of every role in each extension.

## Current resolution status

The compatibility follow-up corrects T1–T5 and A1 below. Tasks now has
regressions for nullable peer TTLs, routing-header validation, lookup error
codes, lifetime input-key uniqueness, quota rollback and terminal input cleanup.
The client accepts unlimited peer tasks while the bundled store keeps finite
retention. `DiscoveryFlow` selects Basic before body credentials from server
metadata and rejects incompatible metadata before sending a secret.

The explicit official extension run records 44 Tasks server checks, 16
client-credentials client checks and 9 enterprise client checks passing. The
upstream task-notification scenario is a skipped stub; actual task notification
HTTP delivery is covered locally. See the separate
[extension coverage matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md#mcp-extensions)
for roles, evidence and remaining limits.

Tasks and Auth are acknowledged at their pinned revisions for the recorded
scope. On 2026-11-01 the maintainer approved optional `:idp_auth` in both
enterprise orchestrators. It provides exact issuer-bound discovery and separate
IdP Basic, POST or JWT credentials, with method/algorithm validation before
the exchange. Mock IdP/AS HTTP tests cover credential separation, invalid
config, discovery/endpoint mismatches, rejected authentication and the unchanged
public-client path. The official enterprise scenario continues to qualify the
public-client IdP flow; confidential-client evidence is local and separate.

The host still acquires the initial ID token. On the resource AS side,
Both orchestrators now offer optional separate `:as_auth` Basic/POST/JWT
credentials and `:idp_subject` OIDC/refresh/SAML-transition inputs. These later
profiles have named contract evidence, a verifying independent Node/jose peer
and scoped SDK Auth-helper interop. The [requirement register](MCP_REQUIREMENTS.md)
supersedes the earlier AS-grant limits below. Initial SSO, XML validation and
IdP/AS issuance, tenant and replay policy remain host-owned. This scope does not
qualify arbitrary vendor deployments or constitute complete inherited-spec coverage.

## Initial outcome

Twelve source baselines were assessed. Ten were acknowledged in the initial assessment:
the extension framework/index and nine optional extension repositories whose
protocols ArborMCP does not currently implement as supported integrations.
Tasks and authorization were left pending because supported paths had concrete
compatibility gaps. The original assessment changed no runtime behavior; the
current resolution status above records the subsequent corrections.

`reviewed` acknowledges the recorded disposition. For an unimplemented
extension it does not mean compatible, enabled, or permanently excluded from
the roadmap. The watcher will still report subsequent source changes.

The table records current dispositions at those source pins. The findings
below describe the initial `5ea3884` implementation; the resolution status
above records their subsequent corrections.

| Source | Reviewed revision | Disposition |
| --- | --- | --- |
| Framework and extension index | [`d0e246e`](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/extensions) | Reviewed: optional adoption, explicit opt-in, maturity and revision rules. |
| Authorization | [`15ca394`](https://github.com/modelcontextprotocol/ext-auth/tree/15ca394e00a66434520b9ade26294999295a43ae) | Reviewed for recorded scope; expanded Auth profiles and separate contract/fixture/SDK evidence are in the requirement register. Inherited requirement inventory remains partial. |
| Tasks | [`b3d28ac`](https://github.com/modelcontextprotocol/ext-tasks/tree/b3d28aceaa6d49f5f92258e3d06b61ad6f111e84) | Reviewed after T1–T5 corrections; documented finite store and node-lifetime limits. |
| Apps | [`cf599cc`](https://github.com/modelcontextprotocol/ext-apps/tree/cf599cc462406accc90ec3ca7879e3a22a9fc2a8) | Reviewed: no built-in or qualified Apps integration. |
| Skills | [`649f7ae`](https://github.com/modelcontextprotocol/ext-skills/tree/649f7aee87d631ac4d1fdd3b12eef0c6264fdb3a) | Reviewed: Skills transport methods and host loading semantics are not implemented. |
| Server Cards | [`526201b`](https://github.com/modelcontextprotocol/ext-server-card/tree/526201bbc80231daa40ffcdecfc9da4e54e5dc93) | Reviewed: card publication and discovery are not implemented. |
| Experimental file uploads | [`e4b12c9`](https://github.com/modelcontextprotocol/experimental-ext-file-uploads/tree/e4b12c99aa01ef16a53c3c99a620c7da38b292fd) | Reviewed: repository is an incubation placeholder; no protocol adopted. |
| Experimental filesystems | [`6a61117`](https://github.com/modelcontextprotocol/experimental-ext-filesystems/tree/6a61117ab2a2e21e90546c3a28cc081b9761dc64) | Reviewed: problem statements, no filesystem extension adopted. |
| Experimental interceptors | [`07c89a2`](https://github.com/modelcontextprotocol/experimental-ext-interceptors/tree/07c89a24879eb2231e2afb72942643ebc8dfe485) | Reviewed: remote interceptor protocol is not implemented. |
| Experimental tool annotations | [`fecace7`](https://github.com/modelcontextprotocol/experimental-ext-tool-annotations/tree/fecace78a9552f70ba735d750fc3c4b190e20429) | Reviewed: neither draft trust annotations nor action metadata is adopted. |
| Experimental triggers/events | [`d5316be`](https://github.com/modelcontextprotocol/experimental-ext-triggers-events/tree/d5316be214be2e76e51462069c1d67e00a5a7619) | Reviewed: proposed event delivery methods are not implemented. |
| Experimental variants | [`cfc05d6`](https://github.com/modelcontextprotocol/experimental-ext-variants/tree/cfc05d6f5eb8829f9896d44a6d47360bd15c3b5c) | Reviewed: no maintained Variants protocol integration. |

## Tasks: findings and corrections

The [published 2026-07-28 task contract][tasks-spec] and its
[extension schema][tasks-schema] are the targets. The empty extension settings
object used by ArborMCP is correct for that revision. TypeScript package
directories named `v1` or `v2` are not a requirement to invent a new wire
capability revision setting.

Existing tests cover explicit opt-in, per-request declarations, flat task
results, synchronous store insertion, owner isolation, partial input responses,
cooperative cancellation, expiry and complete notification payloads. The initial suite did
not expose the following gaps; regression tests now cover their corrections.

| ID | Published requirement and observed behavior | Required follow-up |
| --- | --- | --- |
| T1 | `ttlMs` is required and may be null. The task-response validator rejects null, so a valid unlimited-lifetime peer task can be rejected. The pure task serializer also omits a null TTL. | Accept the published nullable wire value and preserve the required key. Keep the bundled store's finite retention policy separate from accepting a peer's result. |
| T2 | HTTP `tasks/get`, `tasks/update` and `tasks/cancel` carry `Mcp-Name: taskId`. The request-header builder omits it for all three methods. Its shared name validator also lacks those mappings. | Add task-ID header generation and corresponding body/header validation. |
| T3 | An invalid or nonexistent `taskId` MUST return JSON-RPC `-32602` for `tasks/get` and SHOULD do so for `tasks/update` and `tasks/cancel`. With a present but nonexistent ID, the bundled handler's dispatch path returns `-32000`; the HTTP message-processor path returns `-32603` for all three methods. An absent `taskId` already receives `-32602`. | Return an explicit invalid-params error for unknown/unauthorized task IDs across the three methods, preserving the existing indistinguishable lookup policy. |
| T4 | Input-request keys are unique for the lifetime of a task. After one round is answered and drained, the store accepts the same key for a different question. Clients deduplicating keys can then miss the new question. | Retain issued-key history across rounds and reject reuse without admitting a changed task state. Account for retained history within store limits. |
| T5 | A task execution that ends in a JSON-RPC error is represented as failed, including while input is outstanding. `Tasks.fail/3` currently rejects an input-required task as an invalid transition. | Permit the appropriate nonterminal-to-terminal transitions while keeping terminal states immutable; clear obsolete pending input data. |

Relevant implementation: [wire validation][task-validation],
[HTTP headers][task-headers], [handler adapters][task-adapters],
[stored input handling][task-store] and [state transitions][task-state].

The bundled store's node/process lifetime and finite quotas remain documented
implementation limits, not a claim of clustered persistence. Applications must
apply their authentication policy to task endpoints and provide the correct
principal/tenant/audience context. Existing ownership tests cover that binding;
the review does not certify arbitrary host authentication configuration.

## Authorization: required compatibility work and profile boundaries

The reviewed files are the published 2026-07-28
[client-credentials profile][auth-client] and
[enterprise-managed profile][auth-enterprise]. Core authorization controls,
JWT assertions, token exchange and ID-JAG helpers exist; that is not evidence
that every orchestration path supports every client registration profile.

**A1 — Basic-only metadata is ignored by `DiscoveryFlow`.** A valid authorization
server can advertise only `client_secret_basic`. With `auth_method:
:client_secret`, [`DiscoveryFlow`][auth-discovery] ignores that metadata and
calls the body-credential path, which sends no Basic header. A controlled token
endpoint rejects it. The same endpoint accepts the library's low-level Basic
request in the probe's positive control.

The follow-up is to select a supported secret-authentication method from
metadata and fail explicitly when no compatible method exists. Exact
pre-registered issuer binding must remain intact. This finding concerns
`DiscoveryFlow`; [`FullOAuthFlow`][auth-full] has a separate method selector
that already chooses between JWT, Basic and body credentials. It is also the
flow used by the OAuth provider and HTTP client. Do not infer that every OAuth
request uses the defective helper.

**Enterprise qualification boundary.** The profile requires IdP client
authentication when the preceding OIDC registration requires it. The
[`EnterpriseFlow` helper][auth-enterprise-helper] forwards an ID token and
client ID but has no separate IdP credential/authentication configuration; its
single client ID is used on both sides. The cross-app path in `FullOAuthFlow`
also submits the IdP exchange without a client-authentication method. These
high-level paths are not qualified for arbitrary confidential-IdP registrations.
Lower-level `TokenExchange` can carry a client secret, and applications can
compose their own requests, but that does not close the high-level API gap.

Before clearing this baseline, fix A1 and explicitly choose/document the
supported enterprise profiles. Supporting distinct confidential IdP and resource
authorization-server registrations needs an API design; do not reuse one
authority's credential at another. IdP policy, access-token issuance and host
authorization remain application/authorization-server responsibilities.

## Optional extensions: acknowledged current scope

- **Apps.** The [published Apps specification][apps-spec] defines UI resource
  metadata plus a separate UI protocol and host rendering/sandbox behavior.
  ArborMCP's tools/resources and metadata can be building blocks for a host,
  but there is no built-in Apps host, UI lifecycle or tested Apps integration.
  Generic HTML resources alone are not that integration.
- **Skills.** The [canonical beta specification][skills-spec] adds `skills/list`,
  `skills/get` and optional `resources/directory/read`, plus manifests, content
  verification, per-origin identity and host approval/loading rules. These are
  not implemented. Packaged UsageRules and ordinary resource reads do not
  implement Skills over MCP. The adjacent `skills.md` is a redirect stub;
  `skills.mdx` is the reviewed specification.
- **Server Cards.** The [repository schema][cards-schema] describes static
  remote connectivity metadata and a recommended `GET <mcp-url>/server-card`
  location, separate from `server/discover`. ArborMCP supplies neither a card
  route nor card-based client discovery. SEP-3392's final transition and the
  central index classify it as Beta, while the pinned repository README still
  says experimental. That stale banner does not change the library's current
  scope or establish compatibility.
- **File uploads and filesystems.** The upload repository contains a short
  incubation README; the filesystem repository adds problem statements for
  scoped listing, search, partial reads, writes and concurrency. Neither is
  an adopted ArborMCP protocol surface. File tools and resource support are not
  a qualification of a proposed filesystem or upload extension.
- **Interceptors.** The [proposal][interceptors-spec] describes discoverable
  out-of-process interceptor servers and an invocation lifecycle. ArborMCP's
  local `Server.Middleware` and outbound authorization interceptor are different
  mechanisms; neither implements that protocol.
- **Tool annotations.** The [repository's draft extensions][annotations-readme]
  are `io.modelcontextprotocol/trust-annotations` and
  `io.modelcontextprotocol/action-metadata`. No implementation is claimed.
  Standard MCP tool hints and generic `_meta` preservation do not supply their
  classification, evidence or action semantics.
- **Triggers/events.** The [design sketch][events-spec] proposes `events/list`,
  polling, streams and webhook subscriptions. No such protocol is implemented.
  Existing MCP catalog/resource/task subscriptions are distinct.
- **Variants.** The [experimental repository][variants-readme] describes
  variant-dependent tool sets and descriptions and links a proposal. There is
  no maintained ArborMCP integration. The watched repository has no standalone
  normative specification; linked PR/discussion edits outside watched source
  files are not covered by the source-drift job.

These are factual implementation-scope acknowledgements, not decisions to
reject those features. Adopting one later requires its own supported-role,
transport, capability, API and test plan.

## Framework, evidence and closure

[SEP-3392][lifecycle] leaves extension adoption to SDKs and retains explicit
opt-in. Maturity does not force adoption. A stable published revision is a
different target from an experimental/beta iteration or a future draft.
ArborMCP's task opt-in and legacy/modern separation fit that model; they do not
waive the outstanding task requirements above.

The review used pinned source documents, implementation/test inspection and
controlled local probes. The existing focused Tasks/auth suite passed 142
checks. Seven additional contract probes exposed six findings: T1–T5, with T3
checked through two dispatch paths, and A1. Those probes intentionally fail
against the reviewed implementation and are retained with the review evidence,
outside the normal repository test suite. They are not passing conformance tests.
The auth probe uses fake credentials and a loopback token endpoint; no real
account or vendor service is used.

The original probes are historical evidence of the six findings. The follow-up
adds passing regressions and explicit extension conformance gates. Tasks is
acknowledged after its corrections. Auth is acknowledged after its A1 correction
and the separately approved `:idp_auth` addition, with the profile limits above.
No additional optional protocol is enabled.

[tasks-spec]: https://github.com/modelcontextprotocol/ext-tasks/blob/b3d28aceaa6d49f5f92258e3d06b61ad6f111e84/specification/2026-07-28/tasks.md
[tasks-schema]: https://github.com/modelcontextprotocol/ext-tasks/blob/b3d28aceaa6d49f5f92258e3d06b61ad6f111e84/schema/2026-07-28/schema.ts
[task-validation]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/tasks/extension.ex
[task-headers]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/transport/http/request_headers.ex
[task-adapters]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/tasks/server.ex
[task-store]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/tasks/store/ets.ex
[task-state]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/tasks/task.ex
[auth-client]: https://github.com/modelcontextprotocol/ext-auth/blob/15ca394e00a66434520b9ade26294999295a43ae/specification/stable/oauth-client-credentials/2026-07-28/oauth-client-credentials.mdx
[auth-enterprise]: https://github.com/modelcontextprotocol/ext-auth/blob/15ca394e00a66434520b9ade26294999295a43ae/specification/stable/enterprise-managed-authorization/2026-07-28/enterprise-managed-authorization.mdx
[auth-discovery]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/authorization/discovery_flow.ex
[auth-full]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/authorization/full_oauth_flow.ex
[auth-enterprise-helper]: https://github.com/trust-arbor/arbor_mcp/blob/5ea3884cb8f3941a354b1c65b40176dc8bbaa429/lib/arbor_mcp/authorization/enterprise_flow.ex
[apps-spec]: https://github.com/modelcontextprotocol/ext-apps/blob/cf599cc462406accc90ec3ca7879e3a22a9fc2a8/specification/2026-01-26/apps.mdx
[skills-spec]: https://github.com/modelcontextprotocol/ext-skills/blob/649f7aee87d631ac4d1fdd3b12eef0c6264fdb3a/specification/beta/skills.mdx
[cards-schema]: https://github.com/modelcontextprotocol/ext-server-card/blob/526201bbc80231daa40ffcdecfc9da4e54e5dc93/schema.ts
[interceptors-spec]: https://github.com/modelcontextprotocol/experimental-ext-interceptors/blob/07c89a24879eb2231e2afb72942643ebc8dfe485/docs/sep.md
[annotations-readme]: https://github.com/modelcontextprotocol/experimental-ext-tool-annotations/blob/fecace78a9552f70ba735d750fc3c4b190e20429/README.md
[events-spec]: https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/d5316be214be2e76e51462069c1d67e00a5a7619/docs/design-sketch-proposal.md
[variants-readme]: https://github.com/modelcontextprotocol/experimental-ext-variants/blob/cfc05d6f5eb8829f9896d44a6d47360bd15c3b5c/README.md
[lifecycle]: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/seps/3392-extension-lifecycle.md
