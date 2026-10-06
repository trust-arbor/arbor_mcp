# v2 Release Plan: October 3–9, 2026

- **Target:** Friday, October 9, 2026, in `America/Chicago`
- **Status:** Accepted v2 scope implemented; audit fixes and final release qualification underway
- **Scope:** Full accepted v2, including runtime/scheduler and transport integration
- **Names:** `Arbor.MCP.*`, `Arbor.ACP.*`, `Arbor.RPC.*`; optional `arbor_acp_adapters` bundle accepted
- **Repository:** `trust-arbor/arbor_mcp`, transferred with repository ID `989917799` preserved
- **Contracts:** [package/adapter contract](./V2_PACKAGE_CONTRACT.md), [runtime contract](./V2_RUNTIME_CONTRACT.md)
- **Baseline:** [API baseline](./V2_API_BASELINE.md); [canonical roadmap](./V2_ROADMAP.md)

October 9 is a target subject to every gate below. It does not waive scope,
qualification or soak. A missed implementation gate or a material RC fix moves
the release date; it does not turn the full redesign into a later minor release.

## Current release status — October 6, 2026

Implementation of the accepted v2 roadmap is complete. Earlier dated sequences
and checkpoints below retain the source and evidence they describe. The prior
standalone-repository selection passed 63 selected CI jobs; current follow-up
changes must establish their own result and source/archive association.

The remaining work is to:

1. Qualify the HTTP optional-range/owned-listener correction and Claude
   `max_bytes` fix, preserving the accepted lifetime, capacity and wire contracts.
2. Complete the requested performance investigation for MCP and ACP, including
   MCP BEAM paths, and record the workload budgets or accepted costs.
3. Close applicable final-source conformance, pinned SDK/credential-free CLI,
   dependency-contract and packaged-consumer evidence. For first RC1, the lowest
   and newest supported package versions may coincide; a compiler/OTP matrix is
   a separate claim from a dependency-version matrix.
4. Publish the coordinated RC in dependency order and verify clean registry-based
   installation. The refreshed Hex account check succeeds; RC1 is currently
   unpublished, and that check is not publication proof.
5. Complete the accepted stable-release qualification, including the continuous
   run, final metadata/source/archive binding, tags and publication. No soak is
   currently active, and prior unsuccessful attempts remain failed evidence.

RC publication for downstream testing and stable promotion are separate steps.
Neither the October 9 target nor a green earlier CI selection waives an open
gate. [RC notes](guides/V2_RELEASE_CANDIDATE.md) describe the candidate's limits.

The preserved `codex/maintenance-1.x` branch starts at `3914a927`; compatible
1.x fixes use that implementation's own checks under the
[maintenance policy](MAINTENANCE_POLICY.md). The v2 release does not end 1.x
maintenance or authorize wholesale architectural backports.

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
No run is currently active, and the earlier attempts did not complete this gate.
Record the next run's exact source/package selection, accepted start timestamp
and evidence ledger when it starts. To retain an October 9
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
OAuth cases pass on all three toolchains; actual OAuth wire was pending at
that checkpoint. The later API5 result is recorded below. Legacy JSON callbacks
can report progress through their authenticated
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

At this dated checkpoint, the four-package production API audit and actual 2024
`/sse` to `/message` continuous-consumer preparations were source-only. Later
API5 and package consumer execution is recorded below. A qualified ALL11 short
run and the unbroken 48-hour final-RC run remain required.

## Current qualification checkpoint — API5 and selected consumers

This section supersedes earlier active status statements. The Client/DETS
selection at `e16c0da` and other historical sources, counts and failed receipts
remain unchanged; separate selections are not an aggregate release total.

The Client followup keeps the native legacy SSE GET loop available while owned,
bounded asynchronous senders wait for established request POSTs. Single and
batch requests retain their original cutoff through sender exit and final SSE
settlement. Cancellation and actual worker cleanup retain separate obligations.
The DETS fixture creates persisted setup through a separately owned finite
setup manager, confirms its cleanup, then tests the original 60 ms storage
budget and genuine fail-stop behavior.

The selected Client source passes 163 combined cases on both current and
minimum toolchains. Forced development compilation with warnings as errors,
strict Credo, normal Dialyzer and documentation with warnings as errors pass
both. The corrected DETS module passes 16 cases on minimum, current and newest;
this is a separate selection, not an aggregate release test count. Forced test
compilation passes both, and the unfiltered warning comparison adds no warnings
or filters. The full minimum performance/stress command passes 5,573 tests,
20 doctests and 34 properties with zero failures. The later MCP `f240699` CI
passes all 16 jobs; changed candidates still need fresh complete CI. The
preceding `be1ae4a` CI passed 15 of 16 jobs, including stress
and both previously failed minimum unit/archive jobs. Its sole newest failure
was state inspection after a short-budget setup storage error and deliberate
manager fail-stop; that failed receipt remains preserved.

The historical API4 captures at MCP `9d18d9b` and ACP `47c9e8a` remain
actual passes for their original sources. Copied compiler metadata later
invalidated the current live cache; that failure and the original captures
remain preserved. API5 uses fresh independent production graphs at MCP
`18727b66d62d707fbf0c702f42b7f97516db58a2` and ACP/RPC/adapters
`47c9e8a303cb0b3fcbb9c1c748e49edfa53a377b`. Both supported toolchains complete
all 23 driver commands, including forced compilation with warnings as errors in
each owning package root and fresh reflection. The API4 semantic census is
unchanged; three added hidden deadline-aware spawn/watch exports belong to MCP.
See [the API census](./V2_API_MIGRATION.md#current-compiled-api-census-api4-snapshot).

Fresh API5 source archives pass exact source association on both toolchains.
Each combined installed/compiler-free release consumer completes eight stages;
Cowboy and Bandit each pass installed and release consumers on both toolchains.
Three authenticated legacy HTTP reverse wire cases and fifteen Phoenix wire
groups pass per toolchain. OAuth provider HTTP/DNS remains a fixture seam, not
external-provider interoperability proof. Unpublished Arbor packages use
extracted archive paths with normal Hex dependencies; published-package
resolution and the actual Arbor host's pre-existing compile-warning gate remain
open.

The codec-only experiment compares API5 with fresh changed-source graphs and
matching runtime dependency versions: all 22 checks in eight timing VMs pass.
Median 256 KiB BEAM echo falls from 1,524 to 995.5 microseconds (34.7%), and Test
echo from 2,584 to 2,034.5 microseconds (21.3%). Small operations show no fixed
improvement. This does not qualify final RC performance or replace the retained
released-1.x comparison.

The cached-scope/Node Ledger shortcut was rejected because unobserved
distribution transitions can leave stale charges. The nil-only leaf candidate
retains every full metadata admission check; its 40-case suite and own compilation
with warnings as errors pass all three toolchains. Header compatibility's
93-case and 142-case selections, warnings-as-errors compilation and formatting
also pass all three. Fresh codec-plus-nil compilation completes all four phases;
both 22-case smoke selections and eight timing VMs pass. The paired medians
show 256 KiB BEAM echo falling from 1,502.5 to 1,033 microseconds (31.2%) and
Test echo from 2,584 to 2,076 microseconds (19.7%), with identical retained output
sizes. Small-call reductions fall about 15%, but wall latency is mixed: BEAM
ping improves from 350.5 to 321 microseconds and Test ping increases from 324 to
338. The small source changes are selected; this experiment does not qualify a
final release graph or restore the released 1.x latency profile.

At MCP `367e151`, the unmodified published 0.1.16 stable server suite passes
all 39 scenarios on both supported toolchains, with unchanged CLI assertions,
post-artifact checks and confirmed owned cleanup. The earlier 38/1 receipts and
modified-header diagnostic remain historical evidence. The header fix allows
compatible 2025 Streamable HTTP headers while preserving the negotiated session
version; no filter, exclusion or protocol downgrade produces the current pass.

The `367e151` CI run `37412047958` completes ten successful and six failed jobs.
An outdated compatible-header assertion and three short-deadline/queue fixture
assumptions have separate corrections. Those four corrected fixtures pass the
selected 35 cases and formatting on minimum, current and newest, with production
source hashes unchanged. These corrections are included in this checkout;
the local selection does not replace a fresh complete CI run.

ALL11 current8 completes all seven source/build/installed/release-selector phases.
Its first installed SHORT attempt fails on configuration atom parsing before
Bootstrap or lane effects, with confirmed owned cleanup. Earlier capture failures
remain preserved; fixed configuration parsing and capture-output binding require
new evidence. No ALL11 short run or continuous 48-hour final-RC run is qualified.
Final RC metadata, changed-source static/full CI and API/package/consumer
association, final performance qualification, publication ownership and Hex remain
open. No RC or stable release is qualified by these selected-source receipts.

## October 6 CI and short-rehearsal checkpoint

This checkpoint supersedes earlier active status without combining their test
counts. The `0cd7044` CI run `37415384744` completes 13 successful and three
failed jobs. The failures are the legacy header fixture's pinned modern probe,
the minimum Ledger lifetime monitor's termination observation, and the newest
HTTP listener completion observation. The raw failures remain preserved.
Working corrections isolate each fixture endpoint, install the Ledger monitor
before its existing actor acknowledgement, serialize the listener-expiry module,
and recheck the exact live listener binding at the final completion CAS. The
first selection passes 60 cases on current/minimum and 59 of 60 on newest;
its Ledger result-observation failure remains preserved. The revised 52-case
Ledger/Gateway selection, forced warnings-as-errors compilation and formatting
pass all three toolchains. The final exact-stop Gateway followup separately
passes 12 cases and formatting on all three, with production hashes unchanged.
These are separate selections, not an aggregate release count. Normal-hook
commit, push and renewed complete CI remain pending; the local controls do not
prove the historical scheduling cause.

ALL11 current10 rehearses historical API5 archives at MCP `18727b66` and
ACP/RPC/adapters `47c9e8a`; it does not associate the newer MCP source or final
RC artifacts. All seven normal build/capture phases complete, and its corrected
failure controls pass 18 cases with source and generated-artifact guards unchanged. The installed SHORT rehearsal then fails after 5.96 seconds
during adapter-bundle startup. The report records confirmed typed native RPC
and stdio child reaping and targeted-group absence, while adapter-bundle cleanup
remains unconfirmed. The outer VM is reaped and its recorded process group is
absent; that is not wider descendant cleanup proof. Two journal records are
retained. The Phoenix HTTP 500 is an expected post-`Runtime.stop` authority check,
not the startup failure. No ALL11 SHORT or sustained-soak pass follows.

The selected codec-plus-nil Ledger source remains unchanged. Both bounded
Test/BEAM ping attribution runs complete three operations plus settlement with
unchanged source/graph guards, actual client/server DOWN and stopped profilers.
They do not establish a new latency improvement; no further performance change
is selected. The unmodified published stable server suite's 39/0 passes on both
supported toolchains remain associated with `367e151`, not these working changes.

RC metadata remains private preparation and is not applied. Fresh changed-source
API/package/consumer association, full CI, final performance and conformance
qualification, a successful installed/release SHORT rehearsal, publication
ownership and Hex authentication remain gates. The final qualified RC must still
complete 48 continuous hours; no RC or stable release is qualified by this
checkpoint.

## Outstanding release blockers

- Complete final combined transport and authenticated wire qualification.
  HTTP reverse controls, legacy progress/log delivery, mounted modern
  subscriptions, Runtime-only HTTP mounts and explicit standalone server
  ownership are integrated. Legacy JSON progress has passing actual official
  coverage; selected API5 authenticated reverse wire passes with fixture provider
  HTTP/DNS. The unmodified published stable suite passes 39/0 at `367e151`;
  final changed-source transport qualification remains open.
  Addressed resource subscription tracking and durable fanout are implemented
  and described in [the resource slice](https://github.com/trust-arbor/arbor_mcp/blob/f08c090c44edcda3a53478fd04a7a944c0bf2b7f/docs/V2_HTTP_RESOURCE_PUBLICATION_SLICE.md). Runtime/scheduler, store/result
  contracts, owned listeners and accepted API retirements have implemented slices;
  their interim receipts do not establish final cross-transport qualification.
- Bind the selected codec-plus-nil Ledger changes and final RC metadata to
  fresh compiled evidence. The nil-only 40-case and Header selections pass all
  three toolchains; the cached-scope/Node shortcut is rejected. Requalify the
  final graph's performance, and associate it with the compiled
  API/defaults, exact package/dependency contracts, static/full CI and consumers.
  Record versions/tags and named human release owners.
- Qualify the shared-handle integration candidates and their exact immutable
  dependency pins. Canonical v2 ACP is now in its own repository; preserve the
  original extraction and dirty spike as migration evidence, without regenerating
  over the canonical implementation.
- Retain API5 archive, combined installed/release, Cowboy/Bandit, OAuth and
  Phoenix passes for their selected source. Finish extension/range, actual Arbor
  host and publishing qualification. Hex ownership/credentials, normal published
  package resolution and final links still need release evidence.
- Requalify installed HTTP sessions, reverse controls, aliases, replay and
  optional listeners at the final package commit. Complete full CI, official
  legacy/current conformance, tagged TypeScript HTTP and SDK coverage, Phoenix,
  actual Arbor/combined/OTP-release consumers, adapter compatibility and
  same-runner performance against the released 1.x artifact. Complete a qualified
  ALL11 installed/release selection and short run before starting the unchanged
  final RC's continuous 48-hour soak.

Stable publication requires all blockers cleared and the final RC's full evidence
reviewed. Keep the frozen 1.x manifest and preserved migration worktrees available
through that decision.
