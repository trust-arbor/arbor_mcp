# ArborMCP 1.0.0-rc.7

> **Historical release record:** rc.7 was published on 2026-08-13. The
> behavior-preserving rc.8 follow-up supersedes it as the active soak candidate.

`1.0.0-rc.7` is the modern-preferred soak candidate that follows published
`1.0.0-rc.6`. It keeps the dual-era MCP 2026-07-28 default while packaging the
post-rc.6 transport lifecycle, ACP, and security hardening that cannot promote
directly from rc.6 to stable 1.0.

## What changed since rc.6

- Legacy Streamable HTTP GET SSE streams persist events before delivery, retain
  the MCP session across ordinary connection gaps, and replay from
  `Last-Event-ID` without duplication under bounded retention.
- ACP Pi managed event handling correctly processes multi-chunk agent streams,
  and adapter/MCP subprocesses isolate their environments by default.
- The 2026-08-12 security harden enforces protocol lifecycle, identity,
  authorization, network, resource, and privacy boundaries across MCP and ACP.
  See [SECURITY_AUDIT_2026-08-12.md](SECURITY_AUDIT_2026-08-12.md).
- CI and compatibility follow-ups keep Elixir 1.17 docs/tooling green, fail
  closed on invalid MRTR identities, and align fixtures with server-issued
  sessions and strict schema/privacy behavior.

`:prefer_modern` remains the application default. `:legacy_only` preserves the
legacy protocol era connection policy (rc.7 still enforces server-issued sessions and newer lifecycle/security rules). See the
[migration guide](getting-started/MIGRATION.md) for rollout steps and the
[API diff](API_DIFF_RC5_TO_1_0.md) for the public compatibility audit, including
the rc.7 delta note.

> **Why another soak:** The SSE disconnect lifecycle intentionally retains a
> session after an ordinary GET-stream disconnect, and the security harden
> changes session issuance, outbound network policy, and subprocess defaults.
> Those observable compatibility changes restart the stable-1.0 clock. See the
> [2.0 roadmap backport lane](V2_ROADMAP.md#8-the-1x-backport-lane).

## Installation

```elixir
{:arbor_mcp, "~> 1.0.0-rc.7"}
```

Pin the rollout policy when it must not change with a package upgrade:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
# Emergency rollback / legacy protocol era (not an exact rc.5 package rollback):
# config :arbor_mcp, protocol_mode: :legacy_only
```

## Security and dependencies

The release retains the patched Mint, Mint WebSocket, Plug, Plug Cowboy,
Cowboy, Cowlib, HPAX, Decimal, and related runtime dependency set from rc.6.
The locked dependency set has no critical or high-severity advisories.

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

| Gate | Owner | rc.7 evidence |
|---|---|---|
| Legacy byte fixtures | Protocol maintainer | `mix test.suite compliance`; version characterization and cross-version suites |
| Seven-row era matrix | Protocol maintainer | stdio/HTTP compatibility tests in the full CI and coverage jobs |
| Modern conformance and SDK v2 interop | Release maintainer | external conformance artifact plus six isolated legacy/modern Node.js lanes |
| MRTR retry, tamper, replay, expiry, and rotation | Security maintainer | MRTR, request-state, replay-cache, integration, and coverage suites |
| Subscription pressure, isolation, reconnect, and cluster fanout | Runtime maintainer | subscription, PubSub, multi-node, performance, stress, and coverage suites |
| OAuth/CIMD/SSRF/credential isolation | Security maintainer | authorization matrix, redirect leakage, metadata fetch, and security suites |
| Modern-preferred soak | Release maintainer | begins when rc.7 is published; minimum seven calendar days |
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

The rc.7 publish gate is current-head only:

- zero errors or timeouts in the performance and stress suites;
- no committed absolute performance threshold may regress;
- process and mailbox counts must return to their bounded post-cleanup state;
- slow subscribers must coalesce or disconnect according to policy without
  cross-principal delivery.

A same-runner rc.5 vs rc.7 comparison (median runtime and retained memory for
shared legacy workloads, plus runner identity, commit SHAs, and raw outputs)
is **not** an rc.7 publish gate. Record that evidence before stable `1.0.0`.
Any unexplained current-head breach still blocks this candidate. Runner noise
must be resolved by repeating the current revision on the same machine, not by
widening a threshold in the release commit.

## Stable 1.0 gates still open

Publishing rc.7 restarts, but does not complete, the stable-release clock.
Stable `1.0.0` requires:

1. at least seven calendar days of final modern-preferred RC use without a
   release-blocking regression;
2. a successful mixed-version cluster rollback drill with active
   subscriptions and in-flight MRTR operations; and
3. a same-runner rc.5 vs rc.7 performance comparison (median runtime and
   retained memory for shared legacy workloads, plus runner identity, commit
   SHAs, and raw outputs).

Any wire-design, public-API, or documented lifecycle change requires another
RC and restarts the soak. Current `master` packaged as rc.7 meets that
condition because of the legacy SSE persistence/disconnect-lifecycle fix and
the 2026-08-12 security harden described above.

## Post-merge publish checklist

1. Confirm CI green on the release commit, including the MCP conformance artifact and ACP 1.3.0 interop job.
2. Tag `v1.0.0-rc.7` at that commit.
3. Create a GitHub **prerelease** for `v1.0.0-rc.7` (prerelease checkbox on) with notes pointing at this document and `CHANGELOG.md`.
4. `mix hex.publish`
5. Start the ≥7-day modern-preferred soak.
6. Complete the mixed-version cluster rollback drill before stable `1.0.0`.

## rc.5 performance comparison

Deferred to stable `1.0.0`. See the load-budget policy above: rc.7 publishes
on current-head thresholds only.
