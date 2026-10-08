# ArborMCP 1.0.0-rc.6

`1.0.0-rc.6` is the first published dual-era ArborMCP release candidate and the
modern-preferred soak candidate for stable 1.0. It implements MCP 2026-07-28
while retaining every legacy revision and the complete rc.5 public API.

## What changes

- New clients default to `:prefer_modern`: they probe with `server/discover`
  and fall back to legacy `initialize` only after positive compatibility
  evidence on a live transport.
- Default servers accept both eras and advertise MCP 2026-07-28 first.
- `:legacy_only` preserves the legacy protocol era connection policy (rc.7 still enforces server-issued sessions and newer lifecycle/security rules).
- MCP 2026-07-28 adds stateless per-request context, typed result envelopes,
  multi-round tool results, `subscriptions/listen`, stateless Streamable HTTP,
  OAuth 2026 hardening, and the negotiated Tasks extension.
- Deprecated Roots, Sampling, protocol Logging, legacy subscriptions, and
  HTTP+SSE remain available for supported legacy revisions throughout 1.x.

See the [migration guide](getting-started/MIGRATION.md) for rollout steps and
the [API diff](API_DIFF_RC5_TO_1_0.md) for the public compatibility audit.

> **Post-rc.6 status (2026-08-12):** `1.0.0-rc.7` is the next modern-preferred
> soak candidate. Current `master` after rc.6 includes legacy SSE
> persist/reconnect/replay, ACP Pi multi-chunk and subprocess isolation fixes,
> the 2026-08-12 security harden, and CI/compat follow-ups. rc.6 itself is not
> promoted to stable 1.0. See
> [RELEASE_1_0_0_RC_7.md](RELEASE_1_0_0_RC_7.md) and the
> [2.0 roadmap backport lane](V2_ROADMAP.md#8-the-1x-backport-lane).

## Installation

```elixir
{:arbor_mcp, "~> 1.0.0-rc.6"}
```

Pin the rollout policy when it must not change with a package upgrade:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
# Emergency rollback / legacy protocol era (not an exact rc.5 package rollback):
# config :arbor_mcp, protocol_mode: :legacy_only
```

## Security and dependencies

The release updates Mint, Mint WebSocket, Plug, Plug Cowboy, Cowboy, Cowlib,
HPAX, Decimal, and related runtime dependencies. The locked dependency set has
no critical or high-severity advisories.

Cowlib 2.19.0, the newest compatible release, retains two upstream advisories:

- `EEF-CVE-2026-43966` (medium) is mitigated because Plug rejects CR/LF/NUL in
  response-header values and Cowboy independently terminates invalid response
  headers before serialization.
- `EEF-CVE-2026-43969` (low) affects `cow_cookie:cookie/1`, which ArborMCP and its
  Plug/Cowboy response path do not call.

These acknowledgements are exact IDs in the Hex audit configuration. CI still
fails on every unacknowledged advisory and builds the real Hex archive.

## Qualification evidence and ownership

The release tag identifies the exact source commit. Its GitHub Actions run is
the durable evidence record; the external-conformance job uploads the complete
runner output as `mcp-2026-07-28-conformance`.

| Gate | Owner | rc.6 evidence |
|---|---|---|
| Legacy byte fixtures | Protocol maintainer | `mix test.suite compliance`; version characterization and cross-version suites |
| Seven-row era matrix | Protocol maintainer | stdio/HTTP compatibility tests in the full CI and coverage jobs |
| Modern conformance and SDK v2 interop | Release maintainer | external conformance artifact plus six isolated legacy/modern Node.js lanes |
| MRTR retry, tamper, replay, expiry, and rotation | Security maintainer | MRTR, request-state, replay-cache, integration, and coverage suites |
| Subscription pressure, isolation, reconnect, and cluster fanout | Runtime maintainer | subscription, PubSub, multi-node, performance, stress, and coverage suites |
| OAuth/CIMD/SSRF/credential isolation | Security maintainer | authorization matrix, redirect leakage, metadata fetch, and security suites |
| Modern-preferred soak | Release maintainer | begins when rc.6 is published; minimum seven calendar days |
| Security, resource bounds, and public API | Release maintainer | `mix hex.audit`, Sobelow, performance/stress CI, API diff, and package build |
| Mixed-cluster rollback drill | Deployment operator | required before stable 1.0; record the operator run in the stable release evidence |

The external suite is pinned to
`@modelcontextprotocol/conformance@0.2.0-alpha.10` because no stable
2026-07-28-aware runner is published; its CI lane pins Node.js 22 because the
harness imports `fs.globSync`. Official TypeScript SDK v2 interop pins
`@modelcontextprotocol/client`, `server`, and `node` to `2.0.0`. The legacy
conformance baseline remains pinned independently to `0.1.16`.

## Load and regression budget

The qualifying workload is `mix test.suite performance` on OTP 27 / Elixir
1.17. It covers the committed microbenchmarks, concurrent serialization,
high-volume tool request preparation, large payloads, a ten-second sustained
load interval, security checks, schema compilation, subscription queue
pressure, and slow-consumer behavior.

The rc.6 gate is:

- zero errors or timeouts in the performance and stress suites;
- no committed absolute performance threshold may regress;
- shared legacy workloads may not regress more than 20% in median runtime or
  10% in retained memory versus the rc.5 baseline on the same runner;
- process and mailbox counts must return to their bounded post-cleanup state;
- slow subscribers must coalesce or disconnect according to policy without
  cross-principal delivery.

Any unexplained breach blocks the release. Runner noise must be resolved by
repeating both revisions on the same machine, not by widening a threshold in
the release commit.

## Stable 1.0 gates still open

Publishing rc.6 started, but did not complete, the stable-release clock. The
post-rc.6 SSE lifecycle fix resets that clock. Stable `1.0.0` now requires:

1. at least seven calendar days of final modern-preferred RC use without a
   release-blocking regression; and
2. a successful mixed-version cluster rollback drill with active
   subscriptions and in-flight MRTR operations.

Any wire-design, public-API, or documented lifecycle change requires another
RC and restarts the soak. Current `master` met that condition because of the
legacy SSE persistence and disconnect-lifecycle fix described above.
