# Arbor package roadmap

The accepted ArborMCP v2 scope is implemented and available in
`arbor_mcp` `2.0.0-rc.2`. ArborACP, ArborACP adapters and ArborRPC are newly
extracted libraries on independent `1.0.0-rc.1` lines. Their original
`2.0.0-rc.1` candidates are retired; existing archives and tags remain available.
The maintained ExMCP line has released `ex_mcp` `1.6.0`.

## Delivered scope

- Separate MCP, ACP and RPC ownership, with an optional vendor adapter bundle.
- Per-server runtime supervision, common dispatch and bounded callback scheduling
  across BEAM, test, stdio and HTTP. Stateful handlers remain serialized by default.
- Scoped sessions, subscriptions, Tasks and replay stores, explicit cancellation,
  deadlines, output accounting and ownership-aware shutdown.
- Optional Cowboy/Bandit listeners and mounted Phoenix/Plug hosting.
- Canonical Client/Server and ACP Client/Agent APIs, complete results, explicit
  extraction, bounded pagination and scoped connections.
- API retirements, stricter DSL declarations, schema constraints and compile-time
  composition, migration guides and agent usage rules.
- Native RPC subprocess ownership, finite delivery/write admission and typed
  cleanup receipts; Claude file limits and ZCode settings/acknowledgement fixes.
- Host-owned logging and diagnostic payload redaction.

Modern MCP `2026-07-28` and the documented legacy revisions remain supported.
Legacy HTTP+SSE remains an explicit compatibility option. Package versions and
wire protocol versions are separate contracts. Hot upgrades of 1.x process state
into v2 are unsupported; use cold runtime replacement and rehearse rollback.

## Stable-release work

The RC packages, owning tags, source archives, normal Hex installation and
assembled-release probes have been verified. Stable qualification remains open:

- Exercise real downstream integrations and live vendor workflows on the final
  candidate, including authenticated HTTP and application-specific handlers.
- Complete the supported platform/pressure/lifecycle and dependency-contract
  checks for the advertised package graph.
- Confirm production capacity and peer-turnover policy. The continuous test
  harness previously reached the documented 10,000-entry persistent-peer cap;
  its short run does not qualify the accepted soak.
- Accept and document the measured performance costs. Further optimization is
  deferred; keep lifetime, deadline and capacity guarantees during later work.
- Complete the accepted continuous **48-hour final-candidate soak**, retaining
  source, lockfile, platform and cleanup evidence.
- Qualify any later source, metadata or dependency change before stable promotion.

The [release checklist](RELEASING.md) owns qualification and publication steps.
The [RC notes](guides/V2_RELEASE_CANDIDATE.md) explain current consumer limits.
The earlier October 9 target does not establish a completed release gate.

## Deferred work

Spark DSL evaluation, public middleware, a general dialect framework, additional
durable/clustered store adapters and further performance experiments are follow-up
work. Runtime durable session backends remain unqualified; standalone DETS stays
supported within its documented contract. Windows native subprocess support is
outside this release's scope. ACP protocol-v2 adoption requires its own upstream
compatibility review and does not follow from ArborACP's package version.

## ExMCP 1.x maintenance

Applicable correctness, security and compatible additions continue on
`codex/maintenance-1.x`. Each backport needs its own 1.x regression and package
qualification. Keep its public APIs, defaults and persisted/wire identifiers;
the v2 package split, scheduler and API removals stay on the new line.
See the [maintenance policy](MAINTENANCE_POLICY.md). No end-of-support date is set.
