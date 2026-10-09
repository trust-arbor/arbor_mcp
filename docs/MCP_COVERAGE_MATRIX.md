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
| MCP 2026-07-28, complete server suite | `@modelcontextprotocol/conformance@0.2.0-alpha.11`, Node.js 22+ | `./scripts/conformance.sh modern` | 149/149 checks passed |
| MCP 2026-07-28, complete client suite | `@modelcontextprotocol/conformance@0.2.0-alpha.11`, Node.js 22+ | `./scripts/conformance.sh modern` | 387/387 checks passed |
| Published legacy/core server suite | `@modelcontextprotocol/conformance@0.1.16` | `./scripts/conformance.sh server` | 39/39 checks passed |
| Published legacy/core client suite | `@modelcontextprotocol/conformance@0.1.16` | `./scripts/conformance.sh client` | 218/218 checks passed |

The modern results have zero warnings and no expected-failure entries. The
legacy runner remains pinned separately because the published stable package
does not exercise the 2026-07-28 wire model. `./scripts/conformance.sh
draft-alpha` is non-gating exploration for future draft scenarios; it is not
the 2026-07-28 qualification command.

The weekly `MCP conformance upstream` workflow selects the highest version in
the package's published npm version list and runs the same complete modern
suites. It is an advisory early-warning lane: it uploads the selected version
and full logs, but it does not mutate the reviewed pin used by release CI.
Manual runs may select an exact package version. Review any failure against the
upstream release diff, add a local regression test for newly exposed behavior,
and advance the pinned gate only after the new harness passes.

## Official SDK Interoperability

`test/interop/package.json` and its committed lockfile pin the official MCP
TypeScript SDK v2 packages at `@modelcontextprotocol/client@2.0.0`,
`@modelcontextprotocol/server@2.0.0`, and
`@modelcontextprotocol/node@2.0.0`. The following CI lanes negotiate exactly
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

## MCP 2026-07-28 Coverage

Legend: ✅ covered by local tests and exercised by the complete external suite;
⚠️ intentionally limited or awaiting a release gate.

Test paths in this table are relative to `test/arbor_mcp/`.

| Area | Status | Primary local tests |
|---|---|---|
| `server/discover` and version advertisement | ✅ | `client/discover_test.exs`, `server/discover_test.exs` |
| Era selection, probing, fallback, pinning, and cache policy | ✅ | `client/era_probe_test.exs`, `client/era_cache_test.exs`, `client/modern_stdio_test.exs` |
| Required per-request protocol, client capability, and client-info metadata | ✅ | `server/request_context_test.exs`, `internal/request_params_test.exs`, `protocol/meta_test.exs` |
| Modern method availability and error codes | ✅ | `protocol/methods_test.exs`, `protocol/error_code_characterization_test.exs`, `server/dispatch_test.exs` |
| Required `resultType` envelopes and cache hints | ✅ | `protocol/result_envelope_test.exs`, `protocol/cacheable_result_test.exs`, `client/modern_result_validation_test.exs` |
| Multi Round-Trip Requests and sealed request state | ✅ | `client/mrtr_test.exs`, `message_processor_mrtr_test.exs`, `protocol/request_processor_mrtr_test.exs`, `server/mrtr_dispatch_test.exs`, `integration/mrtr_round_trip_test.exs` |
| Replay, expiry, ownership, and key/codec rotation | ✅ | `server/request_state_test.exs`, `server/replay_cache_test.exs` |
| `subscriptions/listen`, filters, replacement streams, and pressure bounds | ✅ | `client/modern_subscription_test.exs`, `client/modern_http_subscription_test.exs`, `server/subscriptions_test.exs`, `subscription_registry_test.exs` |
| Stateless Streamable HTTP routing and POST-owned SSE | ✅ | `http_plug_test.exs`, `transport/http_request_headers_test.exs`, `transport/http_modern_stream_client_test.exs`, `client/modern_http_request_stream_test.exs` |
| Bidirectional official TypeScript SDK v2 interop over stdio and HTTP | ✅ | `integration/modern_interop_test.exs`, `../interop/modern_ts_*.mjs` |
| Reverse-proxy header validation | ✅ | `http_reverse_proxy_test.exs` |
| Modern OAuth, CIMD, registration policy, issuer binding, and metadata SSRF controls | ✅ | `authorization/compatibility_matrix_test.exs`, `authorization/registration_policy_test.exs`, `authorization/client_id_metadata_test.exs`, `authorization/metadata_fetcher_test.exs`, `client/modern_http_stream_auth_test.exs` |
| `io.modelcontextprotocol/tasks` capability, server store, and wire shape | ✅ | `tasks/extension_test.exs`, `tasks/server_test.exs`, `tasks/store_test.exs`, `tasks/task_test.exs` |
| Trace context and telemetry redaction/cardinality | ✅ | `protocol/trace_context_test.exs`, `operational_telemetry_test.exs` |
| 2026 type surface and synced schema mapping | ✅ | `types/v20260728_test.exs`, `spec_sync/file_mapper_test.exs` |
| Optional response-cache storage and reuse | ⚠️ | Required `ttlMs`/`cacheScope` validation is covered; ArborMCP 1.0 deliberately does not store or reuse responses |

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
