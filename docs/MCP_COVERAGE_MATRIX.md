# MCP Specification Test Coverage Matrix

This document maps ArborMCP's local and external conformance coverage to the MCP
protocol revisions it implements. Release evidence is associated with each tagged package graph separately; see
the [release checklist](RELEASING.md). The historical 1.0 results below retain
their original source/date.

## Protocol Status

- **Latest stable MCP revision:** [`2026-07-28`](https://modelcontextprotocol.io/specification/2026-07-28).
- **Newest legacy revision:** `2025-11-25`.
- **Other retained legacy revisions:** `2025-06-18`, `2025-03-26`, and
  `2024-11-05`.
- **Current stable release:** `1.0.0` enables `2026-07-28` through
  `:prefer_modern` and `:modern_only` and defaults to `:prefer_modern`. Every
  legacy revision remains available, and
  `:legacy_only` preserves the legacy protocol era (not an exact rc.5 package rollback).

The protocol revision is stable even though its official conformance runner is
still published as a prerelease. Do not describe `2026-07-28` itself as a
draft.

## External Conformance

| Target | Runner | Command | Last recorded result |
|---|---|---|---|
| MCP 2026-07-28, complete server suite | `@modelcontextprotocol/conformance@0.2.0-alpha.12`, Node.js 22+ | `./scripts/conformance.sh modern` | 150/150 checks passed |
| MCP 2026-07-28, complete client suite | `@modelcontextprotocol/conformance@0.2.0-alpha.12`, Node.js 22+ | `./scripts/conformance.sh modern` | 411/411 checks passed |
| Published legacy/core server suite | `@modelcontextprotocol/conformance@0.1.16` | `./scripts/conformance.sh server` | 39/39 checks passed |
| Published legacy/core client suite | `@modelcontextprotocol/conformance@0.1.16` | `./scripts/conformance.sh client` | 218/218 checks passed |

The modern results have zero warnings and no expected-failure entries. The
legacy runner remains pinned separately because the published stable package
does not exercise the 2026-07-28 wire model. CI's `MCP external conformance`
job gates all four suites: the modern ones with `./scripts/conformance.sh
modern` and the legacy core ones with `./scripts/conformance.sh all`. `./scripts/conformance.sh
draft-alpha` is non-gating exploration for future draft scenarios; it is not
the 2026-07-28 qualification command.

The weekly `MCP conformance upstream` workflow selects the highest version in
the package's published npm version list and runs the same complete modern
suites. It is an advisory early-warning lane: it uploads the selected version
and full logs for core and supported-extension runs, but it does not mutate the
reviewed pin used by release CI.
Manual runs may select an exact package version. Review any failure against the
upstream release diff, add a local regression test for newly exposed behavior,
and advance the pinned gate only after the new harness passes.

The separate weekly **MCP extensions upstream** workflow discovers official
extension repositories and compares specification/schema sources with recorded
baselines. It reports new sources, file drift and pending reviews without
changing implementation or conformance pins. See
[extension source tracking](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/EXTENSION_SYNC.md)
for local commands, comparison scope and the baseline review process.

## Official SDK Interoperability

`test/interop/package.json` and its committed lockfile pin the official MCP
TypeScript SDK v2 packages at `@modelcontextprotocol/client@2.4.0`,
`@modelcontextprotocol/server@2.4.0`, and
`@modelcontextprotocol/node@2.1.2`. The following CI lanes negotiate exactly
`2026-07-28`:

| ArborMCP role | Official SDK v2 role | Transport | CI tag |
|---|---|---|---|
| Server | Client | stdio | `interop_modern_ts_client` |
| Client | Server | stdio | `interop_modern_ex_mcp_client` |
| Server | Client | Streamable HTTP | `interop_modern_ts_http_client` |
| Client | Server | Streamable HTTP | `interop_modern_ex_mcp_http_client` |

The lanes cover discovery, tools, structured output, resources, prompts,
per-request context, result metadata, MRTR, subscriptions, modern HTTP routing
headers, POST-owned SSE, stateless session behavior, and modern GET/DELETE
rejection. Their assertions live in
`integration/modern_interop_test.exs`; the official-SDK fixtures live in
`test/interop/modern_ts_*.mjs`. Legacy interop remains separately pinned and
tested so SDK v2 coverage cannot mask a regression in an older protocol era.

The official everything reference server,
`@modelcontextprotocol/server-everything@2.0.1`, serves both eras from one
Streamable HTTP endpoint. ArborMCP's HTTP client runs the same tools,
progress, resources, templates, prompts and ping checks against it in each era:
`interop_everything_legacy` negotiates `2025-11-25` (and also covers the
session's GET stream) and `interop_everything_modern` negotiates
`2026-07-28`. The assertions live in
`integration/everything_http_interop_test.exs`.

The totals above are dated maintainer-recorded snapshots, not live badges.
The rc.8 CI workflow preserves the complete modern conformance output as a
build artifact, and the GitHub prerelease links the exact tag commit and
qualifying run. Update this table if the pinned versions or results change.

## Local Revision Coverage

| Revision | Era | Version characterization | Shared feature coverage |
|---|---|---|---|
| `2024-11-05` | Legacy | `version_2024_11_05_test.exs` | `features/`, transport, negotiation, and cross-version suites |
| `2025-03-26` | Legacy | `version_2025_03_26_test.exs` | `features/`, transport, negotiation, and cross-version suites |
| `2025-06-18` | Legacy | `version_2025_06_18_test.exs` | `features/`, structured output, elicitation, OAuth, and cross-version suites |
| `2025-11-25` | Legacy | `version_2025_11_25_test.exs` | Tasks, icons, URL elicitation, sampling tool calls, transport, and cross-version suites |
| `2026-07-28` | Modern | Modern suites listed below | Discovery, per-request context, result envelopes, MRTR, subscriptions, modern HTTP, authorization, and extensions |

Every legacy revision has an explicit handler under `handlers/`. The generated
compliance matrix derives its version list from the canonical registry and
fails when a legacy revision lacks a handler. Modern traffic uses a separate
wire path and is characterized by era-specific tests rather than being folded
into legacy `initialize` feature tables.

## MCP 2026-07-28 Core Coverage

Legend: ✅ implemented with test coverage; ⚠️ limited or awaiting qualification;
— not implemented. External results above cover their selected scenarios;
they do not certify every feature or optional extension.

Test paths in this table are relative to `test/arbor_mcp/`.

| Area | Status | Primary local tests |
|---|---|---|
| `server/discover` and version advertisement | ✅ | `client/discover_test.exs`, `server/discover_test.exs` |
| Era selection, probing, fallback, pinning, and cache policy | ✅ | `client/era_probe_test.exs`, `client/era_cache_test.exs`, `client/modern_stdio_test.exs` |
| Required per-request protocol, client capability, and client-info metadata | ✅ | `server/request_context_test.exs`, `internal/request_params_test.exs`, `protocol/meta_test.exs` |
| Modern method availability and error codes | ✅ | `protocol/methods_test.exs`, `protocol/error_code_characterization_test.exs`, `server/dispatch_test.exs` |
| Required `resultType` envelopes and cache hints | ✅ | `protocol/result_envelope_test.exs`, `protocol/cacheable_result_test.exs`, `client/modern_result_validation_test.exs` |
| Multi Round-Trip Requests and sealed request state | ✅ | `client/mrtr_test.exs`, `client/manual_mrtr_test.exs`, `message_processor_mrtr_test.exs`, `protocol/request_processor_mrtr_test.exs`, `server/mrtr_dispatch_test.exs`, `integration/mrtr_round_trip_test.exs` |
| Replay, expiry, ownership, and key/codec rotation | ✅ | `server/request_state_test.exs`, `server/replay_cache_test.exs` |
| `subscriptions/listen`, filters, replacement streams, and pressure bounds | ✅ | `client/modern_subscription_test.exs`, `client/modern_http_subscription_test.exs`, `server/subscriptions_test.exs`, `subscription_registry_test.exs` |
| Stateless Streamable HTTP routing and POST-owned SSE | ✅ | `http_plug_test.exs`, `transport/http_request_headers_test.exs`, `transport/http_modern_stream_client_test.exs`, `client/modern_http_request_stream_test.exs` |
| Bidirectional official TypeScript SDK v2 interop over stdio and HTTP | ✅ | `integration/modern_interop_test.exs`, `../interop/modern_ts_*.mjs` |
| Reverse-proxy header validation | ✅ | `http_reverse_proxy_test.exs` |
| Modern OAuth, CIMD, registration policy, issuer binding, and metadata SSRF controls | ✅ | `authorization/compatibility_matrix_test.exs`, `authorization/registration_policy_test.exs`, `authorization/client_id_metadata_test.exs`, `authorization/metadata_fetcher_test.exs`, `client/modern_http_stream_auth_test.exs` |
| Trace context and telemetry redaction/cardinality | ✅ | `protocol/trace_context_test.exs`, `operational_telemetry_test.exs` |
| 2026 type surface and synced schema mapping | ✅ | `types/v20260728_test.exs`, `spec_sync/file_mapper_test.exs` |
| Optional response-cache storage and reuse | ✅ | Client-local bounded storage, invalidation and per-call bypass are tested in `client/response_cache_test.exs`; core cache-hint validation has separate external coverage. |

## MCP Extensions

Extensions are optional protocols layered on core MCP. Auth is one source
repository containing two separate published extensions, listed individually
below. Core OAuth discovery, CIMD and registration policy remain in the core
table. Library features such as forwarding, caching and middleware are described
in the [features guide](FEATURES.md).

The pinned upstream revisions and implementation-scope assessment are in the
[baseline review](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_EXTENSION_BASELINE_REVIEW.md).
An acknowledged source baseline does not imply that its protocol is implemented.

| Extension | Published target / maturity | ArborMCP support | Coverage |
|---|---|---|---|
| Tasks (`io.modelcontextprotocol/tasks`) | `2026-07-28`, Beta | ✅ Opt-in client/server methods, bounded node-local store, input rounds, cooperative cancellation and notifications. Peer TTLs may be null; the bundled store retains a finite TTL policy. | `tasks/`, `client/modern_result_validation_test.exs`, `transport/http_request_headers_test.exs`, `client/modern_http_subscription_test.exs`; official Tasks server scenarios below. |
| OAuth Client Credentials | `2026-07-28`, Stable | ✅ Client flows for Basic, body credentials and JWT assertions, including issuer-bound discovery. | `authorization/discovery_flow_auth_methods_test.exs`, `authorization/client_assertion_test.exs`, `authorization/oauth_flow_test.exs`; official Basic/JWT client scenarios below. |
| Enterprise-Managed Authorization | `2026-07-28`, Stable | ⚠️ ID-JAG token exchange and JWT bearer grant. The high-level public-IdP flow is covered; separate confidential-IdP credential configuration is not yet available. | `authorization/enterprise_flow_test.exs`, `authorization/token_exchange_test.exs`, `authorization/id_jag_test.exs`, `authorization/id_jag_handler_test.exs`; official enterprise client scenario below. |
| Apps | `2026-01-26`, Stable | — No built-in or qualified Apps integration. | Generic tools/resources/metadata are building blocks, not an Apps qualification. |
| Skills | Beta | — Skills methods, manifests and host loading semantics are not implemented. | No extension conformance claim. |
| Server Cards | Beta | — Card publication and card-based discovery are not implemented. | No extension conformance claim. |
| File uploads | Experimental | — No protocol adopted from the incubation placeholder. | No extension conformance claim. |
| Filesystems | Experimental | — No filesystem extension implementation. | No extension conformance claim. |
| Interceptors | Experimental | — The remote interceptor protocol is not implemented. | Local middleware is a separate library feature. |
| Tool annotations | Experimental | — Draft trust annotations and action metadata are not implemented. | Standard core tool hints and `_meta` handling are separate. |
| Triggers/events | Experimental | — Proposed event polling, streams and webhooks are not implemented. | Core subscriptions are separate. |
| Variants | Experimental | — No maintained Variants integration. | No extension conformance claim. |

### Extension conformance and interoperability

Run `./scripts/conformance.sh extensions` with the same pinned
`@modelcontextprotocol/conformance@0.2.0-alpha.12` harness. CI's **MCP external
conformance** job runs this as a separate step and preserves its combined output
in the `mcp-conformance` artifact under `conformance-extensions/`. The date-filtered
core run excludes these extension-tagged scenarios.
The explicit selectors use `--spec-version 2026-07-28 --force` to include those
extension-tagged cases at the modern wire revision; the harness otherwise
defaults its Auth extension peers to legacy MCP traffic.

| ArborMCP role | Independent peer / selected scenarios | Last recorded result |
|---|---|---|
| Tasks server over Streamable HTTP | Official harness client: lifecycle, capabilities, wire fields, request-state removal, task input rounds, routing headers, dispatch/envelopes, required capabilities and MRTR-to-task composition | 44 checks passed across nine executed scenarios. |
| Client-credentials client | Official harness authorization servers: `auth/client-credentials-basic`, `auth/client-credentials-jwt` | 16 checks passed. |
| Enterprise client | Official harness IdP and authorization server: `auth/enterprise-managed-authorization` | 9 checks passed for the public-IdP profile. |

These are maintainer-recorded results from 2026-10-31 (America/Chicago), not live
badges. The tenth selected Tasks scenario, `tasks-status-notifications`, is an
upstream skipped stub awaiting a `subscriptions/listen` rewrite. It is not counted
as external notification coverage. Actual HTTP task notification delivery and
malformed-event rejection are tested locally in
`client/modern_http_subscription_test.exs`.

The TypeScript SDK v2 interop lanes above currently exercise core MCP. They do
not provide a separate SDK-extension qualification for Tasks or Auth. The explicit
extension harness run supplies independent wire peers for the roles shown here;
local suites cover additional library paths and documented limits.

## Legacy Feature Coverage

The legacy compliance suite continues to cover:

- initialization, capability negotiation, JSON-RPC validation, pagination,
  progress, cancellation, and version-specific method gating;
- tools, resources, prompts, completion, roots, sampling, and protocol logging;
- batch behavior where the negotiated revision permits it;
- legacy Streamable HTTP sessions, resumability, GET SSE, DELETE termination,
  and the deprecated two-endpoint HTTP+SSE compatibility transport;
- structured output and elicitation from `2025-06-18` onward; and
- the legacy Tasks capability, icons, URL elicitation, and sampling tool calls
  in `2025-11-25`.

Primary coverage lives in `test/arbor_mcp/compliance/`, its `features/` modules,
the four `version_*_test.exs` files, and the transport integration suites. MCP
2026-07-28 removals are tested separately so retaining a legacy feature cannot
accidentally expose it on the modern wire path.

## Stable Release Qualification

The implementation, test coverage, and final-candidate soak for stable ArborMCP
1.0 are complete. Ongoing qualification policy is:

1. Replace the prerelease modern conformance runner with a stable 2026-aware
   release when available. Until then, retain the now-passing pinned official
   SDK v2 fallback and disclose both pins in release notes.
2. Preserve rc.8's published qualification evidence as the behavioral baseline
   for the 1.x line.
3. Repeat the mixed-version rollback exercise when changing protocol lifecycle
   behavior in a future 1.x release. The stable-1.0 baseline is the 2026-08-22
   run of `test/arbor_mcp/integration/rollback_drill_test.exs`, including its
   opt-in exact-`v1.0.0-rc.5` subprocess path.

See the [MCP 2026-07-28 migration plan](https://github.com/trust-arbor/arbor_mcp/blob/6c32d32de623962cef0322b2763068c2965980b6/docs/MCP_2026_07_28_MIGRATION_PLAN.md) for
gate ownership, rollback requirements, and the complete implementation record.
