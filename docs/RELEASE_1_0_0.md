# ArborMCP 1.0.0

ArborMCP 1.0 is the first stable release of the dual-era MCP and ACP library. It
preserves the public API, wire behavior, security posture, lifecycle semantics,
and `:prefer_modern` default of `1.0.0-rc.8`.

## Installation

```elixir
{:arbor_mcp, "~> 1.0"}
```

Set rollout policy explicitly when an upgrade must not change it:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
# Emergency legacy-era rollback; exact rc.5 behavior requires package rollback:
# config :arbor_mcp, protocol_mode: :legacy_only
```

## Stable baseline

- MCP `2026-07-28` is preferred by default through `:prefer_modern`.
- Every legacy MCP revision from `2024-11-05` through `2025-11-25` remains
  available throughout 1.x.
- ACP major v1 includes native client/agent support and managed adapters for
  Claude Code, Codex, and Pi. ZCode remains deferred until after 1.0.
- `Arbor.MCP.Server.Tools` remains deprecated but available throughout 1.x;
  `Arbor.MCP.Server.Handler` with `Arbor.MCP.Server.DSL` is the recommended API.
- MCP/ACP subprocess isolation, bounded queues and frames, server-issued legacy
  sessions, OAuth destination validation, and persist-before-delivery SSE
  replay retain the rc.8 security baseline.

## Qualification record

`1.0.0-rc.8` was published on 2026-08-13 and soaked through 2026-08-22 without
a release-blocking compatibility, security, lifecycle, or resource regression.
Stable 1.0 introduces no wire, public-API, or protocol-default change. Its one
internal production fix replaces a runtime-order-dependent
`String.to_existing_atom/1` OAuth callback lookup with a closed mapping for the
same supported `code`, `state`, and `iss` fields. The fix restores documented
callback behavior, cannot create atoms from input, and has a focused regression
test, so it does not restart the protocol-behavior soak.

The release commit must pass the complete CI matrix, including:

- all supported Elixir/OTP combinations, full coverage, Dialyzer, Credo,
  dependency audit, package build, and warnings-as-errors documentation;
- legacy and MCP 2026-07-28 compliance suites;
- bidirectional official TypeScript SDK interop over stdio and Streamable HTTP;
- ACP 1.3.0 SDK interop; and
- performance and stress suites.

The modern conformance harness remains pinned to
`@modelcontextprotocol/conformance@0.2.0-alpha.10` until a stable
2026-07-28-aware runner is available. Official TypeScript SDK v2 interop is
pinned to `2.0.0`; legacy conformance remains pinned independently to `0.1.16`.

The 2026-08-22 dependency audit also identified medium-severity
`EEF-CVE-2026-43971` in Cowlib's `cow_link:link/1` encoder. Cowlib 2.19.0 is
the latest Hex release and does not yet contain the upstream fix. ArborMCP and
its Plug/Cowboy server stack do not call the affected encoder; a BEAM-import
regression test locks that assumption. The exact advisory exception shares the
existing 2026-09-12 Cowlib review deadline and must be removed as soon as a
patched compatible release is available.

The operator-run mixed-version rollback drill passed on 2026-08-22. Its modern
node held an acknowledged subscription and an MRTR call paused in the client
elicitation callback while an exact `v1.0.0-rc.5` stdio server was live. The
drain closed the subscription with `:server_shutdown`, completed MRTR, stopped
the modern node, passed the reconciled operation state to rc.5, and received
`rc5-reconciled=Lin`. The rc.5 process negotiated MCP `2025-11-25`, and its
server metadata reported package version `1.0.0-rc.5`.

The same test proved that a legacy observation cannot overwrite an infinite
modern era pin. Only an explicit `Arbor.MCP.Client.EraCache.clear/1` allowed the
legacy observation to be stored. CI runs the self-contained legacy-only path:

```console
mix test test/arbor_mcp/integration/rollback_drill_test.exs --include integration
```

The release-gate run exported `v1.0.0-rc.5`, compiled its locked production
dependencies in an isolated temporary directory, and selected the exact-tag
path with `EX_MCP_ROLLBACK_RC5_ROOT`. The committed fixture contains only the
rc.5-compatible stdio handler; no rc.5 dependency or build artifact is retained
in the release tree.

## Release procedure

1. Confirm the rollback drill and final rc.8 soak are complete.
2. Confirm every GitHub Actions job is green on the stable release commit.
3. Inspect the unpacked Hex archive and retained documentation links.
4. Tag `v1.0.0` at the release commit and create a non-prerelease GitHub release
   using this document and `CHANGELOG.md`.
5. Publish the same commit to Hex with `mix hex.publish`.
