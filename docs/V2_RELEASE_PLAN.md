# v2 Release Plan: October 3–9, 2026

- **Target:** Friday, October 9, 2026, in `America/Chicago`
- **Status:** Runtime-only HTTP and bounded reverse integration committed; combined followups and final release qualification underway
- **Scope:** Full accepted v2, including runtime/scheduler and transport integration
- **Names:** `Arbor.MCP.*`, `Arbor.ACP.*`, `Arbor.RPC.*`; optional `arbor_acp_adapters` bundle accepted
- **Repository:** `trust-arbor/arbor_mcp`, transferred with repository ID `989917799` preserved
- **Contracts:** [package/adapter contract](./V2_PACKAGE_CONTRACT.md), [runtime contract](./V2_RUNTIME_CONTRACT.md)
- **Baseline:** [API baseline](./V2_API_BASELINE.md); [canonical roadmap](./V2_ROADMAP.md)

October 9 is a target subject to every gate below. It does not waive scope,
qualification or soak. A missed implementation gate or a material RC fix moves
the release date; it does not turn the full redesign into a later minor release.

## Workstreams and accountable owners

The roles below identify responsibility areas. Implementation owners and agent
coordination are recorded with each slice's evidence; the release integration
owner maintains that ledger and the integration order. Named human maintainers
for package publication and final release approval remain to be recorded before RC.

| Owner role | Scope and completion evidence |
|---|---|
| Package maintainer | Current-source extraction, Arbor namespaces/apps/config, optional adapter bundle, qualified shared mechanics, independent package manifests and consumer builds |
| Runtime maintainer | Validated configuration/reference, server supervision, bounded admission/scheduler, state commits/cancellation, request context and all transport wiring |
| Store maintainer | Public session/event contracts, ETS/DETS qualification, scoped registries/replay/tasks, retention/recovery and bounded DETS name allocation |
| Public API maintainer | One result/normalization contract, accepted DSL/composition/lifecycle APIs, deprecated cleanup, migration examples and final API diff |
| HTTP maintainer | Cowboy/Bandit listener adapters, optional dependencies, Phoenix mounts, runtime routing, listener lifecycle and adapter diagnostics |
| Release maintainer | CI/toolchain matrix, conformance/interop/security/performance, package/archive/docs evidence, RC publication, soak and final release decision |

These roles can overlap. Recorded implementation ownership does not establish
publication credentials or replace the pending human release-owner record.

## Dated implementation sequence

This is the target sequence. Completion is established by the source and artifact
evidence below, not by a calendar date or a prepared test harness.

| Date | Required outcome before advancing |
|---|---|
| **Sat Oct 3 — Foundation** | Freeze the `1808c56` 1.x API/source baseline; accept package and runtime contracts; assign owners; settle shared-package qualification, subprocess ownership/events, version ranges, initial versions and soak duration. Preserve the dirty cutover spike and reconcile extraction against current main. |
| **Sun Oct 4 — Package/mechanics foundation** | Create standalone package projects with one-way dependencies and no duplicate modules. Centralize bounded framing, child environment/PATH, Port ownership and cleanup; move vendor families into the bundle. Compile native ACP with the bundle absent. Add shared-mechanics/extension contracts before dependent integration. |
| **Mon Oct 5 — Runtime and transport implementation** | Implement scoped supervision/stores/indexes, admission before payload enqueue, serialized stateful and explicit stateless workers, deadlines/cancellation/state commits. Route stdio, test, BEAM, mounted HTTP and standalone HTTP through the common runtime; prove cross-transport equivalence and sibling-runtime isolation. |
| **Tue Oct 6 — Complete release scope** | Finish public store/recovery contracts, unified results, public API cleanup and migration examples. Complete Cowboy/Bandit optional listeners and Phoenix mounting. Reconcile adapter launch/lifecycle and all retained security/wire behavior. No legacy execution path may bypass the runtime. |
| **Wed Oct 7 — Qualification and RC** | Run the complete matrix on clean package artifacts, freeze API/defaults and dependency ranges, inspect archives/docs, review performance and migration evidence, then publish coordinated RC artifacts in dependency order. Implementation must be complete before the final RC starts its soak. |
| **Wed–Fri Oct 7–9 — Final-RC soak** | Exercise the exact RC combination in representative consumers under sustained requests, reconnect/disconnect, cancellation, pressure, restart and durable replay. Record timings, bounds and outcomes. Keep scheduled upstream drift separate from pinned release gates. |
| **Fri Oct 9 — Stable gate** | Confirm the accepted soak completed on the final RC, all evidence belongs to the release commits/artifacts, and no blocker remains. Publish stable packages in the same dependency order; otherwise record the blocker and a revised target. |

**Accepted soak minimum:** 48 continuous hours on the final qualified RC combination.
The final 48-hour run has not started. Record its exact source/package selection,
accepted start timestamp and evidence ledger when it does. To retain an October 9
target, the final RC must start early enough on October 7 to complete that window.
Observable runtime, persistence, lifecycle, security or wire changes restart
the clock; release metadata alone does not. The date never shortens the accepted
soak period.

## Package dependency and publication order

The shared package candidate is implemented and used by both protocol packages;
its final ABI/default freeze and release-wide qualification remain gates.
Use this exact topological publication order for both RCs and stable artifacts:

| Order | Package | Required predecessors |
|---:|---|---|
| 1 | `arbor_rpc` | None; neutral JSON-RPC/framing/subprocess contract qualified |
| 2 | `arbor_acp` | Compatible published `arbor_rpc`; generic adapter extension runtime included |
| 3 | `arbor_mcp` | Compatible published `arbor_rpc`; full MCP runtime/scheduler included |
| 4 | `arbor_acp_adapters` | Compatible published `arbor_acp`, and an explicit `arbor_rpc` dependency if its documented API is called directly |

ACP and MCP are independent siblings; their order above is operational, not a
new dependency. ACP core never depends on the vendor bundle. Initial versions,
package-qualified tags in the ACP repository and exact supported ranges must be
recorded before RC publication. Independent versioning continues after this
coordinated release.

Both protocol packages must run their shared contract suites against the
**lowest and newest supported RPC versions**. The bundle must run its extension
and golden/lifecycle suites against the **lowest and newest supported ACP
versions**, plus its direct RPC range when applicable. A deliberately
incompatible local build must fail the contract lane. Mutable upstream/latest
vendor checks remain scheduled monitoring; pinned SDK/CLI versions qualify RCs.

## Qualification commands and evidence

These commands exist in the current repository. Preserve them or document their
package-local replacements during cutover; do not mark a lane complete because
its files moved or its tests became excluded.

| Gate | Current command / required artifact |
|---|---|
| API baseline | `MIX_ENV=dev mix mcp.api_manifest --source-ref 1808c56 --output docs/v2/api_baseline_1_5_plus.json --check` on the frozen source; generate separately named v2 package manifests and a reviewed replacement/removal diff |
| Build/quality/docs | `mix format --check-formatted`; `mix compile --warnings-as-errors --no-deps-check`; `mix credo --strict`; `MIX_ENV=dev mix docs`; `mix hex.audit`; `mix deps.unlock --check-unused` for every owning project |
| Unit/integration/security | `mix test --exclude compliance`; `mix test.suite integration --include requires_bypass`; `mix sobelow --skip`; `./scripts/check_skip_tags.sh all`; retained authorization/framing/Unicode/security cases |
| MCP protocol | `mix test.suite compliance`; `./scripts/conformance.sh modern`; every supported legacy revision and bidirectional official SDK stdio/HTTP lanes |
| ACP core | In `packages/arbor_acp`: `mix test` and `mix test --only interop_acp`; SDK v1/v2-draft routing probes; native/fake-adapter contracts with the vendor bundle absent |
| Vendor bundle | Vendor unit/golden suites and credential-free real-CLI lifecycle; upstream/reference parity manifest and all current launch/permission/history cases |
| Runtime/stores | Transport-equivalence, multi-runtime crash/restart/stop, deadline/cancel race, commit ordering, bounded admission/mailbox/queue and ETS/DETS domain suites; retain each slice's exact runner and rerun the final combined source/artifact selection |
| Performance | `mix test.suite performance`; same-runner budgets against the final 1.x artifact, including cancellation and pressure bounds |
| Archives/consumers | `mix hex.build --output /tmp/<package>.tar`; inspect intended modules/files and run clean consumers below using packaged dependencies rather than workspace path dependencies |

Record command, toolchain, commit, dependency lock/range, package checksum,
exit/result and evidence artifact for each gate. The existing CI matrix covers
Elixir/OTP combinations; port it to each applicable owning project before RC.
Preserve conformance output, SDK/CLI versions, performance baselines and soak
logs with the release record. A green default unit run omits several required
lanes and is insufficient.

## Package-only consumer smoke matrix

| Consumer | Acceptance |
|---|---|
| MCP client/stdio server | Only `arbor_mcp` and its declared mechanics; no ACP/vendor modules and no installed Cowboy/Bandit requirement |
| Native ACP client/agent | Only `arbor_acp` and mechanics; no MCP, Mint/Plug/JOSE or vendor implementation; correct application bootstrap |
| Vendor adapter | Add `arbor_acp_adapters`; compatible ACP resolves automatically; fake CLI and reviewed real-CLI lifecycle pass without MCP |
| Combined application | Load all four packages together; no duplicate modules/app names, conflicting config ownership, telemetry attachment duplication or cross-runtime state leakage; preserve the documented legacy wire/storage identifiers |
| HTTP hosts | Separate explicit Cowboy and Bandit consumers plus a Phoenix mount; declare their qualified host dependency constraints; missing listener adapter gives a clear startup error; runtime stop preserves borrowed host listeners/services and owns its own listener |
| OTP release | Start from a built release and verify effective child PATH/environment, owner/subprocess shutdown, repeated close, process groups, Unicode framing and no stdout logging corruption |

Measure cold compile time, archive size and dependency/application counts in
fresh temporary consumer projects. Consumer jobs and private preparations have
interim receipts; the final sealed source/package graph still requires its own
normal dependency resolution, compiled consumer and assembled-release evidence.

## Current qualification checkpoint — October 5

Runtime-only HTTP mounts and bounded reverse controls are integrated at
`1284440`. Its combined selection passes 636 cases on all three captured
toolchains, and 40 actual HTTP wire/Client cases pass on both supported
toolchains. Checkpoint `e284fee` commits the later scoped HTTP bookkeeping,
legacy JSON progress and shutdown observation followups. Its immediately
preceding qualified snapshot passes 671 combined cases, warnings-as-errors
compilation and full formatting on all three toolchains. The 50-case HTTP wire
selection, strict Credo, normal Dialyzer and docs with warnings as errors pass
both supported toolchains. The raw warning census retains 72/current and
66/minimum warnings, none in owned paths and no new filters. The 13 actual SDK
stdio/HTTP cases pass both with no skips. The only subsequent change within that
source batch restores the conformance progress fixture's original 150 ms
workload; production and configuration are unchanged. Keep the original
snapshot receipts distinct from the later conformance reruns.
These counts describe separate selections and must not be added together.

The followups keep bearer introspection and exact identity/endpoint/session
checks while assigning empty default scopes only to a validated methodless
JSON-RPC response; custom scope mapping remains unchanged. Six direct Plug
OAuth cases pass on all three toolchains, but the actual OAuth wire fixture has
not run. Legacy JSON callbacks can report progress through their authenticated
session's addressed GET while keeping the final POST response JSON. Four pure
regressions pass; the actual official progress scenario now observes all three
ordered notifications. The
shutdown completion read-order correction preserves the original cutoff and
unexpected observer-loss error; the combined 671-case selection includes it.

The earlier full current run executed 5,340 tests, 20 doctests and 34 properties,
with one stale documentation assertion and 207 exclusions. The corrected
retained-protocol documentation and assertion pass their focused cases on all
three toolchains. The fresh full current rerun now passes 5,344 tests, 20 doctests
and 34 properties with zero failures and 207 exclusions; the earlier failure
remains recorded. Final full minimum and complete CI qualification remain gates.

Official stable conformance 0.1.16 now reports 38 server scenarios passed and one
failed on both supported toolchains. Its earlier 34/5 and 37/2 receipts remain
preserved. Restoring the fixture's original 50 ms of work after each progress
report yields an actual passing single-scenario receipt with ordered 0/50/100
notifications. The remaining published multiple-stream scenario sends
`2025-03-26` after negotiating `2025-11-25`: HTTP 400 is the retained version
fence, while fresh correctly versioned requests return 200/200/200. That
published scenario mismatch remains unresolved; the stable server gate is not
closed and no expected failure or protocol downgrade is added. Stable client
conformance passes 218 cases on both supported toolchains. Modern
0.2.0-alpha.11 conformance passes 149 server and 387 client cases on both.
These are the selected profile receipts, not final package qualification.

The four-package production API audit and actual 2024 `/sse` to `/message`
continuous-consumer preparations are source-only. Fresh final builds, physical
consumer/short-mode proof and the unbroken 48-hour final-RC run remain required.
Preparation is not execution or release qualification.

## Outstanding release blockers

- Complete final combined transport and authenticated wire qualification.
  HTTP reverse controls, legacy progress/log delivery, mounted modern
  subscriptions, Runtime-only HTTP mounts and explicit standalone server
  ownership are integrated. Legacy JSON progress has passing actual official
  coverage; actual OAuth wire and the published stable conformance scenario
  mismatch remain open.
  Addressed resource subscription tracking and durable fanout are implemented
  and described in [the resource slice](https://github.com/trust-arbor/arbor_mcp/blob/f08c090c44edcda3a53478fd04a7a944c0bf2b7f/docs/V2_HTTP_RESOURCE_PUBLICATION_SLICE.md). Runtime/scheduler, store/result
  contracts, owned listeners and accepted API retirements have implemented slices;
  their interim receipts do not establish final cross-transport qualification.
- Freeze the final four-package compiled ABI/defaults, exact subprocess and
  dependency contracts, versions/tags and named human release owners. Independent
  package CI and the accepted 48-hour duration do not replace those final gates.
- Qualify the shared-handle integration candidates and their exact immutable
  dependency pins. Canonical v2 ACP is now in its own repository; preserve the
  original extraction and dirty spike as migration evidence, without regenerating
  over the canonical implementation.
- Complete packaged consumer, extension/range and publishing qualification.
  Independent ACP manifests and CI exist; Hex ownership/credentials, final
  links and namespace/config/telemetry migration still need release evidence.
- Requalify installed HTTP sessions, reverse controls, aliases, replay and
  optional listeners at the final package commit. Complete full CI, official
  legacy/current conformance, tagged TypeScript HTTP and SDK coverage, Phoenix,
  actual Arbor/combined/OTP-release consumers, adapter compatibility and
  same-runner performance against the released 1.x artifact. Run the final RC's
  actual 48-hour soak only after the exact package graph is qualified.

Stable publication requires all blockers cleared and the final RC's full evidence
reviewed. Keep the frozen 1.x manifest and preserved migration worktrees available
through that decision.
