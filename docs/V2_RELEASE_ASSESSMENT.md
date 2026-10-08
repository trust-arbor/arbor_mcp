# ArborMCP v2 Release Assessment

- **Reviewed:** 2026-10-08; historical checkpoint evidence below is preserved
- **Released baseline:** `v1.5.0`
- **Initial integrated audit baseline:** `e4d2fc3`; later qualified v2 checkpoints are recorded below
- **Status:** Accepted v2 scope implemented; audit fixes and final release qualification in progress
- **Release target:** Friday 2026-10-09, subject to release gates and RC soak
- **Canonical plan:** [V2_ROADMAP.md](./V2_ROADMAP.md)

## Current API follow-up — October 8, 2026

Client and Server are the canonical MCP entrypoints. Explicit Client extraction
helpers preserve complete-response defaults on protocol operations, while root
wrappers retain their compatibility behavior. Plain and DSL handlers share
transport-aware Server startup and supervisor child specs; ordinary stop and
statistics forward to Runtime's existing bounded ownership path. Client status
and scoped connectivity probes have distinct, documented semantics. ACP keeps
Client/Agent roles and now supports the matching Agent stop reason/options form.
The usage rules, quickstarts and migration table reflect these entrypoints.

The MCP response checkpoint passes 5,437 tests, 20 doctests and 34 properties
(208 existing exclusions); 106 focused tests including HTTP pass on minimum and
current toolchains. Final BEAM response/resource and role regressions also pass
on both toolchains. Core ACP passes 370 tests (7 existing exclusions) on both;
Adapters passes 1,479 tests (4 existing exclusions) on the current toolchain.
Final strict docs, archive/installed-consumer and exact-head CI receipts for this
follow-up are separate from the earlier source checkpoints below. These API
checks do not publish the replacement candidates or satisfy the continuous soak,
real downstream/vendor testing or final release gates.

## Previous assessment — October 7, 2026

All four original `2.0.0-rc.1` packages are published and their archive
checksums were verified. Current source prepares MCP `2.0.0-rc.2` and RPC,
ACP and Adapters `1.0.0-rc.1`, with independent 1.x dependency requirements.
The replacements are not yet published. Preserve existing versions and tags;
retirement follows verified replacement installation.

The accepted package split and runtime/scheduler scope is implemented. Optional
HTTP dependency ranges, Claude file limits and ZCode settings fixes passed their
recorded checks. Supported/latest MCP CI passed at `0812257`; ACP and RPC retain
their own recorded source selections. Prior receipts do not qualify new metadata.

Further performance investigation is deferred at the user's request. Adopted
encoder/accounting and revision-token changes remain; mixed experimental changes
are not promoted. Document measured performance costs for the stable decision.
DSL/Spark and public API review is now open before the release freeze.

Remaining gates are final metadata/source/archive association, applicable CI,
conformance/SDK/CLI and dependency-contract checks, real downstream integrations,
long-lived peer capacity policy, registry installation and the final candidate's
continuous 48-hour soak. No qualifying soak is active; stable qualification is
incomplete. See [RC notes](guides/V2_RELEASE_CANDIDATE.md) for consumer limits.

## Historical release conclusion — October 5

The library has a stable protocol baseline and integrated package/runtime,
Runtime-only HTTP and bounded reverse implementations. API5 production artifacts
and selected consumers are qualified for their exact source; final changed-source
and RC qualification, publication and continuous soak remain open. Earlier audit
conclusions below retain their original source context.

**Accepted on 2026-10-03:** v2 includes the per-server runtime, unified
dispatch and bounded handler scheduler as well as the MCP/ACP split, any
accepted Arbor rename, optional HTTP dependencies, API cleanup and release
qualification. Supporting configuration, store and result contracts follow
the full roadmap. The earlier focused-release proposal is closed: runtime
and scheduler changes must be implemented and qualified before a v2 RC.

ACP **protocol** v2 is a separate upstream effort. Its implementation is not a
library-v2 release requirement; retain the gates in
[ACP_V2_TRACKING.md](./ACP_V2_TRACKING.md).

## Work already integrated

The following table and local validation record the initial supported 1.x audit.
Later sections identify the separate v2 implementation checkpoints.

| Area | Evidence and current outcome |
|---|---|
| MCP wire baseline | Modern MCP and retained legacy revisions, MRTR, subscriptions, Tasks, conformance and official-SDK lanes exist. The completed [migration plan](./MCP_2026_07_28_MIGRATION_PLAN.md) is release history, not unfinished v2 scope. |
| Store foundations | Accepted [store ADR](./STORE_ADAPTER.md), internal `SessionStore` behaviour, default ETS, opt-in DETS and a common contract suite. |
| Runtime characterization | `test/ex_mcp/server/runtime_characterization_test.exs` pins callback PID/links, cancellation, timeout, state ordering and basic sibling-server isolation. It does not implement a runtime or scheduler. |
| ACP adapter foundations | Pi/Codex internal boundaries and Claude/Pi/Codex golden-transcript suites provide a comparison baseline for extraction. |
| ACP split preparation | PR #71 narrowed helper documentation, promoted `AdapterEvents`, and added `mix acp.gen_shims`; the task is inert until an ACP dependency is installed. |
| Post-1.5 adapter behavior | Claude mode kinds/quota, message-specific forks and chunk message IDs, plus Pi correlation/order fixes are integrated. |
| Post-1.5 security/lifecycle | Trust-store deadlines, client shutdown/link/deadline/delivery behavior, metadata checks, redaction and raised Mint/Cowlib floors are integrated. See `CHANGELOG.md` for migration effects. |
| Claude MCP launch fix | `e4d2fc3` stops claiming unsupported session-supplied MCP transports and keeps launch-time MCP configuration out of argv through a private configuration file. Extraction must include this commit. |
| Pi subprocess test cleanup | Preserved the orphan-child correction from `014beb6`/#71. Later qualification replaced the stdout-suppressing shell fixture with a direct managed `cat` child and a real model-confirmation RPC exchange; early stdout closure is covered separately. |

Local validation of the integrated tree passed compilation with warnings as
errors, formatting of changed code/tests, strict Credo, documentation generation,
and the default test suite: 20 doctests, 34 properties, 5,330 tests, no failures
(218 excluded). External conformance, vendor CLI and other excluded lanes are
still release qualification work. `mix.exs` still identifies one `:ex_mcp`
package at `1.5.0` and requires Cowboy/Cowlib.

## Branch reconciliation

`origin` was fetched with pruning. GitHub has only `master`; the old remote
feature branches were already deleted. The following local branches were
removed after verifying their changes:

| Removed branch | Tip | Preservation evidence |
|---|---|---|
| `acp-split-prep` | `109b78d` | Complete tree equals squash merge `b087aa3` (#71). |
| `fix/cacerts-deadline` | `e1d311a` | Complete tree equals squash merge `5b0e116` (#74). |
| `claude/fervent-swanson-44cd3d` | `15c33f8` | Complete tree equals squash merge `fc61f84` (#72). |
| `claude/wizardly-cerf-11dfd4` | `e4d2fc3` | Fast-forwarded into `master`. |
| `claude/heuristic-driscoll-2fc2f7` | `014beb6` | Orphan-child correction already in #71; remaining fixture behavior reconciled, then strengthened with the direct-child model-confirmation test. |
| `co` | `3294d12` | Already an ancestor of `master`. |

Two clean Claude worktrees were removed. Their ignored local settings were
preserved under `tmp/branch-cleanup-2026-10-03/` in the main checkout. The
remaining local branches are `master` and `spike/acp-cutover`; the latter and
its dirty worktree remain intact. Draft PR #21 remains open for future work.

## Existing extraction and preserved spike

A sibling repository exists at `/Users/azmaveth/code/ex_acp`: clean local
commit `58dee1d`, with no Git remote configured. It is a concrete extraction
prototype, not a published package or completed cutover. Its project declares
`:ex_acp` version `0.1.0`, with Jason and telemetry as runtime dependencies.

The dirty `spike/acp-cutover` worktree is preserved separately. Do not discard
it or overwrite its dependency/shim edits while evaluating the clean sibling.
Neither prototype should be merged wholesale without reconciling it with the
integrated MCP source and the final package identity.

The original prototype required the following work at audit time:

- Refresh ACP sources, fixtures and tests through `e4d2fc3`; the clean sibling
  predates later fixes, including the private Claude MCP configuration work.
- Replace or formally govern copied security-sensitive helpers and stdio
  overlays. `scripts/extract_from_ex_mcp.sh` currently copies JSON-RPC, line
  buffering, port-environment, framing and diagnostics helpers into ACP.
  Stale duplicate implementations can miss lifecycle/security fixes.
- Fix `test/ex_acp/integration/acp_interop_test.exs`, which still calls
  `Application.ensure_all_started(:ex_mcp)` in its subprocess bootstrap.
  An ACP-only interoperability run must start the ACP application.
- Complete independent CI, docs, package contents and interoperability
  qualification before replacing the canonical implementation.
- Keep regeneration one-way while the monolith is canonical; explicitly
  retire the extraction script when ACP becomes the source of truth.

The source footprint measured at historical audit snapshot `fc61f84` was
60 ACP files including its facade and 26,692 of 101,085 library lines (26.4%).
These figures exclude `e4d2fc3` and are not a current cutover measurement.
Remeasure archive size, clean compile time and consumer dependency/app count;
line counts alone do not establish the value of the split.

## October 3 package implementation checkpoint

The refreshed ACP implementation is now canonical for v2 development at
[`trust-arbor/arbor_acp`](https://github.com/trust-arbor/arbor_acp), on `main`
at `06d153f0bcb515f132b3ab7b439f9b21b503868c`. The untouched sibling and dirty
cutover spike remain preserved. Core, adapter bundle and shared RPC are separate
Mix projects; the dotted `Arbor.ACP.*` / `Arbor.RPC.*` namespaces are accepted.
Vendor environment policy belongs to the bundle, and core has no vendor modules.

Local namespace verification passed 34 RPC, 323 core and 1,436 adapter tests,
six pinned ACP SDK interop tests, production compilation and all three real Hex
archive builds. The [first GitHub package matrix](https://github.com/trust-arbor/arbor_acp/actions/runs/37174597068)
also passed the advertised minimum/current toolchains and SDK lane. Fresh
extraction tooling independently passed 29 primitive, 321 core and 1,434 bundle
tests. These counts differ because the canonical workspace also contains new
bounded-framing and extraction regressions added after the generated snapshot.

No Hex package was published at that checkpoint. The subsequent October 4
checkpoint below supersedes its temporary subprocess implementation status.
Main remains the supported `ExMCP` 1.x source, and the frozen API inventory
retains those identities.

## October 4 implementation checkpoint

The namespace decision is settled as `Arbor.MCP.*`, `Arbor.ACP.*` and
`Arbor.RPC.*`; package and OTP application names retain underscores. The
repository migration is complete. Main remains a supported 1.x package. The
fully passing supported-main checkpoint is `3914a92`, with the Mint floor at
`1.10.2`, the Pi fixture corrected and the API inventory recorded. The fixture
uses a finite 1,000 ms startup allowance and monitors owner exit before asserting
file cleanup. [Fresh supported-main CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37192255584)
passes. The same fixture correction passes locally in both minimum/current
split-adapter builds; [fresh ACP CI](https://github.com/trust-arbor/arbor_acp/actions/runs/37190913343)
also passes at `b4e4ab0`.

MCP v2 CI at `c8a4987` exposed three additional checks: OTP 27 reports private
opaque-ticket contract violations, an output-pressure fixture observes a count
before all candidates finish preparing, and the stress fixture injects random
errors before initialization. The ticket correction is committed at `586ebcc`, keeps the type opaque, and passes normal minimum/current Dialyzer with unchanged filters. The pressure fixture now waits for prepared payloads. The real-client stress correction is committed at `88a9f75`; both supported toolchains pass its focused case. The merged `dd75a7c` snapshot passes the full local CI selection on minimum and current toolchains: 20 doctests, 34 properties and 3,901 executed tests, zero failures (82 excluded; 3,983-test inventory). Normal minimum Dialyzer passes all 67 existing filtered warnings with no new filters. A fresh complete remote v2 CI run remains required.
The subsequent combined checkpoint includes finite input-byte cleanup (`cc7ee20`), addressed runtime-owned session/resource services (`b189976`) and immutable native RPC `0e4cfd1`. Both minimum/current full selections pass 20 doctests, 34 properties and 3,938 executed tests, zero failures (82 excluded; 4,020-test inventory). Minimum Dialyzer passes 67 existing filtered warnings and normal commit hooks pass 35 existing dev warnings, with no new filters. The frozen 1.x API baseline hash remains unchanged.

The newer combined output/startup checkpoint `e0f1c9a` passes **3,991 executed
tests**, 20 doctests and 34 properties on both minimum/current toolchains, with
zero failures and 82 exclusions (4,073-test inventory). The current full run
preceded removal of one unreachable private codec guard; the final codec then
passed all 39 current cases, and the minimum full run used the final source.
Normal minimum Dialyzer retains 67 existing filtered warnings; normal dev hooks
retain 35, with no added filters. This checkpoint includes production output
preparation before callback-state commit, charged custom replies and atomic
grouped-batch output, plus the original service-cohort startup cutoff.

The four-package archive fixture is committed at `b240463`. Its
[complete twelve-job CI run](https://github.com/trust-arbor/arbor_mcp/actions/runs/37201745057)
passes all twelve jobs, including the minimum/current actual archive consumers,
newest-Elixir tests, Dialyzer, coverage, interop and external conformance. The
archive jobs resolve external dependencies through Hex and run compiler-free
assembled-release probes.
The preceding `47fe089` run passed nine of ten jobs; its OTP 29 cleanup fixture
read an already-deleted ETS table. `21abb42` captures owned PIDs before failure
and preserves the cleanup assertions (18 minimum/current cases pass). The fully green result qualifies `b240463`; later schema integration and final
RC qualification remain separate.

The supported branch's stress correction exercises 1,000 real mock-server
requests after successful initialization with seeded failure injection; the
v2 correction exercises the real client as well. Neither correction changes
the production mock-server error policy.

The startup, stdio, claim-lifetime and DSL checkpoint is committed at
`9ddacfe`. Both minimum/current full selections pass with zero failures;
current reports 4,912 tests and minimum reports a 4,994-test inventory including
82 exclusions. Both include 20 doctests and 34 properties. All 13 pinned SDK
cases pass on each toolchain, and the existing schema performance budgets pass
unchanged. Production compilation, full formatting, strict Credo, ExDoc and
normal commit hooks pass. Dialyzer retains the 35 existing dev filters with no
new filters. [Checkpoint CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37216046234)
passes nine of twelve jobs, including both actual archive consumers, coverage,
SDK interop, external conformance, performance and Dialyzer. Three test jobs
expose fixture coordination boundaries: the blocked-service test can exhaust a
60 ms root-startup allowance before reaching its child, accepted batch output
can arrive after its 100 ms assertion, and physical TCP closure can follow the
listener's DOWN/Ranch-removal observation. The corrected finite coordination
checks retain the owned-child, atomic-admission and socket-closure assertions;
all 54 affected service/batch/listener cases pass on minimum/current. Fresh
combined CI and final-source archives remain required.

The subsequent HTTP authority/client bracket/dynamic-consumer integration passes
both full toolchain selections with zero failures: current reports 5,033 tests,
and minimum reports a 5,115-test inventory with 82 exclusions. Both include
20 doctests and 34 properties. All 27 pinned legacy/modern SDK cases and
production compilation pass on each toolchain. The full runs precede a test-only
held-stdio-barrier coordination followup, whose final three cases pass on both.
Two obsolete media-stub placeholder cases are retired; compiled absence and
retained media/loading behavior remain covered. The named `f4d8534` CI run
passes six of twelve jobs; its failures are those obsolete placeholders and one
150 ms stdio constructor fixture exhausting its budget before its held edge.
Fresh complete CI remains required after these migrations.

The complete HTTP/client/dynamic/Tools checkpoint is committed at `f16660b`.
Both full selections pass 4,995 executed tests, 20 doctests and 34 properties
with no failures. Normal hooks pass with 34 existing dev Dialyzer filters;
minimum-test Dialyzer retains 66 existing filters, with none added.
[Its fresh CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37223674121)
passes ten of twelve jobs, including both four-package archive consumers,
minimum/current testing, performance, SDK interop and external conformance.
Coverage exposes immediate request-ID reuse before canceled work releases its
reservation; newest-Elixir compilation exposes impossible generated component
clauses in local-only DSL consumers. The followup waits for actual reservation
release and emits only the dispatch variants present in the compiled declarations.
All 56 affected component/runtime cases pass on minimum/current/newest; all three
warnings-as-errors builds pass. Fresh combined CI remains required.

The DSL/cancellation followup is committed at `69b0a39`.
[Its CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37226700206)
passes nine of twelve jobs; the newest-toolchain source compilation now passes.
The remaining failures expose a terminal HTTP cleanup receipt/ETS deletion race
and a subscription fixture assuming physical ordering across independent
producers. Cleanup now rechecks the actual terminal receipt without inferring
completion from guardian death. The fixture requires exactly one cancellation
reply and one preserved earlier notification in either physical order.
All 69 affected lifecycle, subscription-origin and HTTP installation cases
pass on minimum/current/newest. Fresh combined CI remains required.

The persistent stdio endpoint authority is integrated from an exact 11-path
handoff. Its 38 focused cases and 44 retained native startup/Test-BEAM cases
pass on minimum and current. The authority retains one physical sender and its
charged write across whole-root or internal execution-cohort replacement.
An unsettled replacement fails before fresh handler initialization or output
credit. Healthy idle replacement retains the same Runtime reference. An actual
IO receipt followed by sender `DOWN` releases liability; borrowed device or
runtime death alone does not. The conservative 64-device bound and poisoned
authority's requirement for a fresh host VM are documented in
[the stdio migration guide](./V2_STDIO_OUTPUT_LIABILITY.md). Combined static,
package and final CI qualification remain required.

The combined diagnostic/clean-device retirement followup passes **248 affected
cases on minimum and current**, including ten actual diagnostic status/failure
probes. Runtime child construction remains synchronous in the original native
parent; facade child-module identity, restart policies and finite startup/shutdown
cutoffs are preserved. Native status and failure reports omit options, handler
state, requests and prepared output. Handler initialization errors and failed
termination hooks now use fixed diagnostic reasons/messages, with remaining
cleanup preserved. Explicit trusted OTP state/debug inspection remains available;
see [runtime diagnostics](./V2_RUNTIME_DIAGNOSTICS.md).

Clean stdio device retirement now rejects old controls while preserving the old
root's exclusive lease, then reclaims capacity after root/starter retirement.
Sixty-four sequential completed-write/device-death cycles recover their slots.
Held writes, unknown sender outcomes and previous IO errors still retain their
physical charge or poison. The exact retirement slice passes 41 stdio and 44
retained startup/Test-BEAM cases on each toolchain. The two independent slices
pass production/development compilation, formatting, strict Credo and ExDoc;
minimum Dialyzer retains 66 existing filtered warnings with no new filters.

[CI at `111a3c7`](https://github.com/trust-arbor/arbor_mcp/actions/runs/37228261099)
passes eleven of twelve jobs, including coverage, minimum/newest toolchains,
both archive consumers and SDK lanes. The remaining saturation fixture expected
a stats map while all control slots were occupied; it now retries the valid
`:stdio_output_busy` response. Fresh combined CI, host-owned stdio logger
migration, complete cross-transport privacy and final release qualification remain.

The ordinary Client lifetime and peer-generation overlay now passes **201
affected cases on minimum/current**, including 23 new cases. Native Client
parent/link identity remains intact. Early bounded observers and authenticated
construction reservations own known library workers; disconnect/stop uses one
cleanup cutoff and requires actual worker death. Acknowledged resource
subscriptions retain logical lifetime across reconnect. Native Test/BEAM
controls carry captured connection epochs, so queued old controls cannot act on
a new connection. Custom close callbacks now run in a registered cleanup worker;
borrowed peers and arbitrary callback-created children are outside this ownership
proof. See [ordinary Client migration](./V2_ORDINARY_CLIENT_LIFETIME.md).

[CI at `40f65d1`](https://github.com/trust-arbor/arbor_mcp/actions/runs/37231121905)
passes six jobs, including both archive consumers, SDK interoperability,
conformance and Dialyzer. All six failed jobs share an obsolete fixture requiring
printable child startup arguments; the fixture now verifies actual native
supervision and facade module identity. The current unit lane also exposed a
startup cleanup defect: consuming root DOWN could renew a suspended guard's wait
by 5,050 ms. The observer now retains its original initialization cutoff. A
deterministic native-root regression fails against the old source and passes
the fix; the original 200 ms cutoff and 500 ms cleanup assertions remain.

The combined Client/guard checkpoint passes **5,048 executed tests, 20 doctests
and 34 properties on each supported toolchain**, zero failures (82 excluded;
minimum reports the 5,130-test inventory). The 46 cancellation/native-transport
cases pass both. Production compilation treats warnings as errors on both;
minimum Dialyzer retains 66 existing filtered warnings with no new filters.
Cancellation fixtures use the real connected server transport, preserving
current-generation delivery and malformed-notification coverage.

[The API migration](./V2_API_MIGRATION.md) and
[behavior/ownership migration](./V2_NON_SYMBOL_MIGRATION.md) preserve the frozen
1.x baseline and historical census, and distinguish the accepted 96 removals,
ACP facade move and seven required internal runtime retirements. They identify
wire/storage literals that must survive the rename. Final compiled graphs,
HTTP cutover, full diagnostic privacy and RC qualification remain release gates.

[CI at `289f021`](https://github.com/trust-arbor/arbor_mcp/actions/runs/37233707056)
passes eleven of twelve jobs, including both archive consumers, coverage,
conformance, SDKs and the minimum/newest toolchains. The remaining current unit
failure waits for a setup acknowledgement using ExUnit's 100 ms default while
the endpoint's configured output budget is 1,000 ms. The fixture now waits for
that configured budget; all later cancellation and output assertions retain
their original bounds. Its eleven focused cases pass at the failing CI seed.

The host logging checkpoint removes automatic global logger reconfiguration
from MCP Application/StdioLauncher and ACP stdio connection. Standalone commands
route their own default handler to stderr without lowering levels or replacing
filters. The explicit legacy suppression helper remains available. Canonical
MCP native stdio probes pass 46 cases on each supported toolchain; full selections
pass **5,052 executed tests, 20 doctests and 34 properties each**, zero failures
(82 excluded; minimum reports 5,134 inventory). ACP passes **359 core tests** on
both (7 excluded). Production compilation and formatting pass both; MCP strict
Credo, compiled documentation and minimum Dialyzer pass with 66 existing filtered
warnings and no new filters. ACP compiled documentation and corrected owned-file
Credo qualification pass. Fresh combined CI is required.

Runtime pressure probes now demonstrate late Tasks/Replay mutations after the
original callback has expired, retained backing binaries exceeding accounted
request bytes, unbounded standalone Replay retention and permanent atom growth
across DETS open/close cycles. These are concrete remaining store/admission
release defects; the host logging checkpoint does not resolve them.

The mounted POST/request-SSE Gateway now shares the initialized Runtime handler
and reserves primary output plus fully framed HTTP IO before state commit.
Its canonical 329-case runtime/startup/stdio/privacy selection passes both
supported toolchains. Integration retains the existing Registry terminal-receipt
recheck, opaque constructors, Client event context and startup guard. The combined
tests caught an optional HTTP field update crashing stdio control jobs; the
generic authenticated job update now preserves jobs without that field, with
all original stdio/subscription bounds unchanged. GET/replay/DELETE and the
remaining full HTTP cutover are separate gates. See [Gateway slice](./V2_HTTP_GATEWAY_SLICE.md).

The separate fourteen-path Client/HTTP diagnostics checkpoint passes 228 affected
cases on both canonical toolchains. Built-in native constructors and closed
status summaries omit private payloads, while original typed startup/cleanup
results and native parent/module identity remain. Concurrent MRTR raise/throw/exit
is captured before Task reporting; the public error remains `-32603`, while the
private converted Task completes normally. Actual host Supervisor returned-error
logging is an explicit trusted boundary. See [Client diagnostics](./V2_CLIENT_DIAGNOSTICS.md).
The combined Gateway/Client checkpoint passes **5,115 executed tests, 20 doctests
and 34 properties on each supported toolchain**, zero failures (82 excluded;
minimum reports 5,197 inventory). The actual Cowboy Gateway selection passes
40 cases on each. Production compilation, formatting and strict static checks
pass; minimum Dialyzer retains 66 existing filtered findings with no new filters.
The final graph and full retained HTTP cutover remain required.

[CI at `9f47f38`](https://github.com/trust-arbor/arbor_mcp/actions/runs/37236519538)
passes eleven of twelve jobs. Its minimum integration failure is a notification
batch fixture waiting 100 ms for a callback with a configured 2,000 ms request
budget. Callback and output observations now share one original 2,000 ms cutoff;
the callback, exact final response, normal EOF and no-extra-output assertions
remain. Both supported toolchains pass the stdio regression selection at its
failing seed. Documentation publication also replaces a hidden OTP-module link
with a description of the native Task worker. Fresh combined CI remains required.

The combined Gateway/Client checkpoint is committed and pushed at `c1ae91b`.
[Fresh CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37238956403)
completed ten of twelve jobs successfully; current-test and performance failures share one Gateway
fixture. After the original invocation expires and actual borrowed IO returns,
checkout may correctly report either empty output or typed retired authority.
The fixture now accepts only those outcomes and explicitly verifies zero retained
frames/in-flight IO. All original timeout, observation, state and no-retry checks
remain; the change does not renew a deadline or alter production behavior.
Its thirteen focused cases pass on both supported toolchains at the failing
current CI seed. Fresh combined CI is required for the corrected source.
The full local and physical results above qualify this named source, not the RC.

The later twelve-path retained session-stream integration adds addressed legacy
GET/replay/DELETE, bounded store-owned replay pages and cursor rejection, charged
stream replacement, and an empty DELETE response reserved before mutation.
Modern sessionless GET/DELETE remain 405. Canonical minimum/current selections
pass all **19 retained session/wire cases** and all **40 broader Gateway wire
cases** with zero failures. See [session streams](./V2_HTTP_SESSION_STREAM_SLICE.md).
The final store mutation guard retains the original cutoff and typed epoch;
actual unresolved writes remain charged across stream replacement or root exit.
Notification-array continuation after its early 202, subscriptions, cross-session
cancellation, MRTR, initialization arrays and deprecated aliases/listener API
retirement remain HTTP release gates. A separate continuation fix is in progress;
none of those features is deferred to v3.

The package metadata checkpoint keeps four literal `2.0.0-dev` versions and
coherent explicit prerelease dependency floors. Separate preparation copies use
literal RC/stable versions, normal major-compatible stable requirements, and
package-qualified ACP monorepo tags/source links. Each ACP project now declares
its own dev-only ExDoc dependency. [Package preparation](./V2_PACKAGE_RELEASE.md)
records dependency order and installed-source verification.

The exact metadata source at MCP `9f47f38`/ACP `cc8b207` passes six independent
four-package dev/RC.1/stable archive consumers on the two supported toolchains:
24 source archives, twelve installed-application/compiler-free-release probes,
and six standalone ACP documentation builds. Stage archives match byte-for-byte
between producing toolchains; release assembly may rewrite `.app` files and strip
BEAM debug information, so raw application/BEAM bytes are recorded separately.
This validates metadata and preparation on the named source. Final combined and
tagged-source archives, normal published Hex resolution, newest/platform checks
and native pressure remain release gates. No tags or packages are published.

The later managed-store/retention checkpoint corrects the reproduced late
Tasks/Replay mutations, oversized backing-binary retention, unbounded Replay
retention and DETS table-name atom growth. Canonical minimum/current selections
pass **158 pressure/store cases** and **329 retained Runtime/Gateway/stdio/privacy
cases** with zero failures. Narrow integration preserves the original HTTP
invocation cutoff, prepared companion output and codec-owned replay terms.
[Store bounds](./V2_NATIVE_STORE_PRESSURE.md) records finite standalone defaults,
typed capacity outcomes and the explicit custom Runtime adapter capability.
The short running-deadline fixture retains its original 100/20/30 ms settings
and actual body-entry/death assertions in a separate synchronous module.

The default-limit fresh-VM store probe below qualifies count/byte plateaus and
idle cleanup, with supporting owner/VM/RSS samples. Finite durable filesystem
behavior remains a separate gate. Native RPC write admission is integrated at
ACP `27f5606`: reservation precedes copying/enqueue, and original producer
cutoffs are checked before native admission. The actual suspended-Actor probe
admits three of 32 producers, rejects 29 with backpressure, and issues zero new
native writes after their original cutoffs. RPC 113 tests pass on all three
local toolchains; [exact-commit Linux CI](https://github.com/trust-arbor/arbor_acp/actions/runs/37244251536)
passes all nine package/SDK/archive jobs. Actor death alone remains insufficient
proof of native child/group cleanup. Final combined package/platform and RC
qualification remains required.

| Slice | Reviewable evidence | Remaining work |
|---|---|---|
| Installed HTTP writer authority | The exact 13-path slice passes canonical minimum/current full selections, all 27 pinned SDK cases and production warnings-as-errors compilation. Runtime starts an owned proxy under the original initialization epoch/cutoff, retaining a separate IO domain across proxy/Admission/execution replacement. Entry bindings derive actual writer identity and original deadline; session claims verify addressed lease/epoch. Root stop reports unresolved borrowed IO explicitly. | Gateway/Controller routing, complete legacy batch authority and actual Bandit/Cowboy delivery remain; the integrated 41 focused and 84 retained cases do not clear those routing/physical transport gates. |
| Client connection bracket and ordinary lifetime | The exact 13-path helper slice passes its canonical minimum/current full selections and all 27 pinned SDK cases. The later ordinary Client overlay passes 201 affected cases on both toolchains; its combined Client/guard full suites pass 5,048 executed tests each. The explicit bracket preserves callback caller and native guardian construction; ordinary clients preserve their native parent and own known workers with finite cleanup. | Fresh complete CI, final installed-package acceptance and full diagnostic/privacy qualification remain. Legacy HTTP cleanup explicitly cannot prove remote session termination. |
| Dynamic tool consumer migration | The exact seven-file application example passes the canonical minimum/current full selections: bounded owned descriptors/compiled schemas/MFA dispatch, explicit defaults without coercion, atomic registration/replacement/removal and scoped list-change admission. Its source-qualified selection passes 60 cases on minimum/current, including 13 new migration cases. | Fresh complete CI and installed-package consumer compilation remain. |
| Complete Tools-family retirement | The exact 16-path retirement removes 81 callables, eight modules and four types. Dynamic and DSL/Result/SchemaPolicy consumers replace global registry/helper behavior. Thirty-eight old implementation-only cases retire; two unknown-name callback/wire cases and retained protocol Roots/Sampling/Logging remain. The source-qualified 180 cases pass both toolchains. Canonical full selections pass 4,995 executed tests on each (minimum reports 5,077 including 82 excluded), plus 20 doctests and 34 properties. Production compilation, formatting, strict Credo and ExDoc pass; minimum Dialyzer filters 66 existing warnings with no new filters. Compiled BEAM inspection confirms 96 total accepted callable removals, eight modules and four types. | Fresh complete CI remains. Six HTTP callables and two deprecated wrappers still await gateway cutover; the final four-package public API comparison remains. |
| Stdio restart liability | A private actual IO-protocol probe reproduces retained borrowed-device writes after the native Writer dies and its parent permanently replaces the Runtime. Fresh per-root output credits do not account for those old writes. | A bounded logical output-device authority must survive Runtime replacement and fail closed until actual IO completion; the separate followup is in progress. Borrowed device/host processes must survive. |
| Compile-time DSL components | The integrated four-file slice composes existing DSL declarations without another registry or handler initialization. Nested components flatten once; duplicates retain source diagnostics; imported callbacks preserve private helpers, compiled validation, original context and shared host state. The combined component/API selection passes 444 tests and eight properties on minimum/current; production compilation passes both. The subsequent full selections include these components and the migrated dynamic consumer. | Fresh complete CI and installed-package acceptance remain. |
| First API retirement checkpoint | Fifteen accepted callable removals are implemented: media/encoding stubs, metadata helper, three ambiguous legacy code emitters and the initialize-result shim. Consumers now use era-specific codes and canonical Initialize/Capabilities. Removed pipeline tokens reject before custom effects; removed file options reject before IO. The frozen 1.x baseline is unchanged. | The following Tools retirement adds 81 callable, eight module and four type removals. Six HTTP callables, two wrappers and the final compiled API comparison remain. |
| Subscription ingress fixture correction | Both runtime-service subscription fixtures now enter through actual registered HandlerServer/Test edges and inspect wire acknowledgements/delivery. All 18 services cases pass on minimum/current. The deadline probe also accepts initialize-only output when its preceding probe expires before transmission; all 11 deadline cases pass on each toolchain. Production origin and timeout policies are unchanged. | Fresh combined CI remains required; raw runtime-service consumers must migrate arbitrary-PID listeners to registered edge ingress. |
| Runtime startup and stdio convergence | Committed at `9ddacfe`: one original startup cutoff through actual native supervisor construction and final root readiness. A suspended nontrapping caller receives the explicit timeout; buffered stdin waits for readiness. Server stdio uses independent owned reader/writer processes, bounded input/output admission and actual IO acknowledgements. Combined minimum/current selections and all 13 pinned SDK cases on both toolchains pass. | Final combined CI/archive, pressure/EOF/platform qualification and runtime HTTP convergence remain. |
| Bounded subscription publication | The integrated overlay charges publications before registry/listener mailbox ingress, retains checkout loans until transport completion, and propagates immutable original callback/control proofs. A canceled later phase cannot erase an earlier completed publication. The combined 111-case subscription/HTTP-core selection passes on minimum/current; shared startup sections are preserved. | Combined CI/archive, HTTP delivery, custom/remote adapter bounded ingress and measured mailbox/RSS qualification remain. |
| Borrowed HTTP writer core | The six-file foundation retains credits for started writes until an actual completion receipt or writer death, coalesces wakes across repeated bindings of the same PID, and retains liabilities across owner/root exit. Its 26 cases pass in the combined minimum/current selection; the isolated core also passes newest Elixir. The subsequent installed authority qualifies root installation and addressed invocation/session binding. | Mounted HTTP/SSE routing and full transport qualification remain. |
| Initialization claim lifetime | Original request lifetime and the short store operation wait are separate. Claims retain an immutable source outcome phase across callback exit, reject canceled/reused batch phases, and cannot extend supplied deadlines. The 39-case minimum/current slice and combined full selections pass; borrowed stores survive runtime replacement. | Authenticated HTTP invocation/session binding and end-to-end replay/writer ordering remain. |
| DSL input constraints and result aliases | The existing DSL emits selected constraints, retains compiled input schemas, and rejects invalid arguments before callbacks without state changes or coercion. Explicit null/false/array defaults retain presence. Raw Handler structured aliases cannot bypass negotiated-era checks. Minimum combined DSL/schema/result selection passes 79 cases; unchanged current schema-performance budgets pass. Later checkpoints include components, dynamic consumer migration and the first 96 accepted callable removals. | HTTP retirement and the final API comparison remain. |
| MCP package/runtime foundation | [Draft PR #76](https://github.com/trust-arbor/arbor_mcp/pull/76), committed through `3e8533f`; independent MCP package, scheduler, handler integration and optional listeners. [Complete CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37187018393) passes all ten jobs, including Elixir 1.17–1.20, coverage, conformance, SDK interoperability, performance and Dialyzer. | This qualifies the named implementation checkpoint. The unfinished runtime transports, output, stores and API contracts remain release requirements. |
| Neutral shared subprocess | [ACP draft PR #1](https://github.com/trust-arbor/arbor_acp/pull/1), native helper integrated at `08d6f21`, GCC startup writes corrected at `46295e8`, archive CI added at `0e4cfd1`. Guardian retains the helper independently of Actor; native parent signals only its unreaped child and disables signalling before reap. Typed, finite receipts retain actual vendor status and explicit unconfirmed cleanup. RPC 103 tests pass on all three local toolchains; [complete Linux CI](https://github.com/trust-arbor/arbor_acp/actions/runs/37195706890) passes all nine package/SDK/archive jobs. | Broader Linux/macOS pressure/blocked-write measurement, final compiler/packaging policy and supported platform matrix remain. Windows native subprocess currently fails explicitly. Escaped descendants and uninterruptible/helper-loss cleanup remain explicitly outside confirmed containment. |
| ACP bridge, Pi and native stdio/client | Shared-handle adoption in [draft PR #1](https://github.com/trust-arbor/arbor_acp/pull/1), now on native RPC `0e4cfd1`. RPC 103, core 355 (+7 excluded) and adapters 1,454 (+4 excluded) pass locally on minimum/current/newest. Golden transcripts and six official SDK cases pass. Fresh Linux CI passes both package toolchains and actual archive consumers using Hex external dependencies and compiler-free assembled releases. | Final public-package range installation, full pressure/platform/extension/consumer migration and complete release qualification remain. |
| Adapter utility commands | Claude logout, Pi version/npm probes and Git worktree discovery use `Subprocess.capture/2` through the adapter policy wrapper at `b46cbfe`. Capture preserves original bytes/nonzero status, caller ownership and environment/cwd policy, with an absolute read deadline and total output cap. Known cleanup failure stays explicit; utility probes omit optional metadata on failure. | This completes the identified utility convergence slice, without clearing the guardian, platform, logger or full runtime release gates. |
| MCP child stdio/client | MCP CI pins native RPC `0e4cfd1` consistently in all eight checkout sites, including upstream conformance. Frame credit, original read deadlines and explicit retained cleanup remain. The later server stdio checkpoint implements runtime dispatch, bounded output and input-first EOF drain. | Persistent borrowed-device liability across Runtime replacement, measured pressure and final installed-package qualification remain. |
| Handler runtime integration | Committed at `e6bd2a4`, with caller migration and immutable RPC pin `b46cbfe` at `3e8533f`, in [draft PR #76](https://github.com/trust-arbor/arbor_mcp/pull/76). Test/BEAM callbacks and committed state move into the scheduler, with scoped peer generations/cancellation, bounded ETS ingress and independent incoming/outgoing control lanes. The full local CI selection passes 20 doctests, 34 properties and 3,821 executed tests (82 excluded); the 3,903-test inventory also passed on minimum before the RPC update, followed by 143 affected minimum-toolchain cases on the new pin. Compilation, formatting and strict Credo pass; the integration checkpoint passed ExDoc and Dialyzer without new warning filters. | The first combined CI run exposed seven fixtures using the old raw server APIs; three test files now use supported ingress/edge/stop APIs. [Fresh complete CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37187018393) passes all ten jobs at `3e8533f`. HTTP, server stdio, output/batch budgets, remaining public stores and complete cross-transport equivalence remain unfinished; the later input batch slice is qualified separately below. |
| Runtime output preparation and delivery | Committed production integration at `e0f1c9a` builds on the private ledger/39-case qualification. Callback workers prepare plain JSON or bounded custom terms before Scheduler commits state. Opaque leases hand off before worker exit, grouped batch credits replace atomically, and terminal publication proofs prevent committed work from leaving callers waiting after ticket expiry. Combined full minimum/current selections pass 3,991 executed tests plus doctests/properties. | Test/BEAM/direct-alias ACK means local delivery, not peer processing. Server stdio/HTTP actual writers, helpers/subscriptions/reverse output, input-first EOF and measured pressure/RSS remain. |
| Custom-call caller identity | Original caller PID and a private worker-owned alias are committed at `c8a4987`; early/late `GenServer.reply/2` cannot settle callers or bypass serialized commit. Production custom replies now use bounded native-term preparation and charged delivery at `e0f1c9a`. Absolute caller/admission waits are qualified at `dd75a7c`; all normal hooks pass without new warning filters. | Deferred reply/continuation/stop are unsupported. Representative application resource migration and full transport qualification remain. |
| Owned runtime services | Committed at `121ea9f`; original-cohort startup is now bounded at `f3727f5` using early acknowledged provenance, a finite observer and guard calls. Root runtime/services/session/startup selection passes 100 cases on minimum/current, including real OTP parents and borrowed survival. | Whole-root initialization still needs one original budget and ready barrier; HTTP connection owners and actual transport integration remain. Standalone legacy stores remain during migration. |
| Per-member batch input admission | Committed at `9eaca9e`: one permit per member, atomic complete-set claims, one input byte charge plus array metadata, conservative whole-envelope retention and token-matched cleanup. Production grouped output is integrated at `e0f1c9a`; member candidates are checked against prospective decoded/wire aggregate before each state commit and final array replaces credits atomically. | Earlier committed members retain state if a later member fails; envelope failure is explicit, without a partial array. Actual transport writers, EOF settlement and measured pressure remain. |
| Absolute admission and caller waits | Committed at `dd75a7c`: original caller budget covers admission and waiting; confirmation uses the earliest server/caller/control cutoff; late queued replies cannot pass the receive boundary; signed-64 deadline metadata is charged and zero/invalid waits admit no work. Combined 110 cases and compilation pass on minimum/current; independent review and all normal hooks pass. Normal minimum Dialyzer on the merged snapshot passes with 67 existing warnings filtered, zero new filters. | Finite byte cleanup is qualified separately below. Accepted work continues under its server deadline after caller expiry. Store startup/control and full transport qualification remain. |
| Finite input-byte cleanup | Committed at `cc7ee20`: complete count/token leases, original-cutoff rollback, 512-attempt/5ms cleanup, retained count+byte credit under contention, one coalesced wake, finite owner reaping and atomic generation fencing. All 120 focused cases and three varied seeds per toolchain pass minimum/current/newest; unchanged normal Dialyzer filters. Combined full minimum/current selections pass. | Same-runner throughput/RSS and full transport/EOF qualification remain. |
| Addressed session/resource services | Committed at `b189976`: opt-in unnamed owners or namespaced borrowed stores, opaque epoch leases/init claims, atomic bounded operation admission, monotonic completion phases, finite cleanup, bounded replay/IDs/resource rows and exact replay outcomes. An independent borrowed-cohort probe found retired URI lookup; the corrected 27 domain cases and full minimum/current selections pass. | One original startup/control budget, initialization-claim lifetime versus operation budget, HTTP routing/replay/writer ordering and explicit durability/backend qualification remain. |
| Combined package-archive consumers | The `b240463` CI fixture installs all four actual source archives, resolves external dependencies through Hex and probes MCP/ACP independent lifetimes and native cleanup from both an installed application and an assembled compiler-free release. Both consumer jobs at the named CI run pass; local earlier `f3727f5` plus RPC/ACP/adapter `0e4cfd1` passed all five steps on minimum/current with matching archive hashes. | Four unpublished Arbor packages are explicit extracted-source overrides. Published Hex ranges, final RC artifacts, all consumer platforms and vendor CLI/HTTP consumers remain separate gates. |
| Optional HTTP listeners | Committed with the runtime checkpoint at `e6bd2a4`: optional Cowboy/Cowlib/Bandit dependencies, bounded listener shutdown and missing-adapter diagnostics. Each minimum/current listener suite passes 34 tests. Six real packaged consumers cover core-only, Cowboy-only and Bandit-only graphs across both toolchains; ExDoc, strict Credo and audit checks pass. The stdio/listener composite also compiles on Elixir 1.20.3/OTP 29 and passes 118 focused tests. | [Fresh combined CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37187018393) passes at `3e8533f`; final packaged-artifact qualification remains. Runtime-mounted HTTP, per-session routing/stores, Phoenix consumption and full release conformance remain separate gates. |

The additive Result constructors (`2944180`) pass 34 focused minimum/current
cases; normalized key-collision rejection (`fd11532`) passes 53. Malformed
results cannot reach state commit through the production output pipeline. The
integrated SchemaPolicy slice adds explicit optional-`nil` compilation/validation,
native JSON/collision/resource checks before encoding, raw/fetched meta-schema
validation and real DSL declaration checks. Its 34 focused cases pass on both
supported toolchains; both combined minimum/current selections pass 4,008 executed tests, 20 doctests
and 34 properties with no failures (82 excluded; 4,090-test inventory). Normal
commit hooks pass with 35 existing dev warnings filtered and no new filters. No accepted API retirement is removed.
That named snapshot still used the draft-7 default. The subsequently integrated
2020-12 dialect candidate uses JSV for omitted/explicit 2020-12 declarations and
retains ExJsonSchema for explicit drafts 4, 6 and 7. Four new dependency locks
leave all 44 prior resolutions unchanged. Its immutable source passes 880 pure
checks on minimum/current/newest: 73 focused cases and 807 pinned official corpus
cases (803 semantic checks and four explicit retained-policy rejections).
Compilation, full formatting, strict Credo and normal minimum/current Dialyzer
pass without new filters. Combined application, scalar output, conformance,
security and archive qualification of this source remain release gates.

The shared `Server.Result` and scalar-value candidate adds one canonical
constructor/normalization implementation, forwarding the existing `DSL.Result`
functions. DSL validation now treats false/null by presence and rejects
normalized collisions; Response preserves canonical values over aliases.
Modern scalar/null/array runtime delivery commits valid state; legacy nonobjects
and malformed nested data reject before commit. The combined focused result,
response, output and service selection passes 108 cases on minimum/current.

The subsequent schema CI at `068e8d0` passed eleven of twelve jobs, including all
package consumers, toolchains, Dialyzer and external interop/conformance. Its
performance job exposed an existing service-restart fixture dereferencing
`:runtime_unavailable` before the replacement execution cohort was ready. The
fixture now waits for an available changed generation, preserving its store
and stale-reference assertions; the 108-case selection includes that correction.
The next remote run at `63486d3` also passed eleven of twelve jobs, including
both archive consumers and every toolchain. Its performance job reached the
future-batch cancellation test but exceeded that fixture's default 100 ms wait
for the held callback to start. The three coordination waits in that test now
use a finite 1,000 ms budget; held-worker ordering, cancellation, committed state
and released-reservation assertions are unchanged. The complete 25-case runtime
edge selection passes on minimum/current at the failing CI seed `242598`.
[Complete CI at `9cd520f`](https://github.com/trust-arbor/arbor_mcp/actions/runs/37205296625)
passes all twelve jobs, including the corrected performance selection, minimum
and newest toolchains, both normal-Hex archive consumers, coverage, Dialyzer,
official SDK interoperability and external conformance. This qualifies that
named source checkpoint and closes the two fixture failures described above.

Test counts describe their named snapshots and slices; they are not an aggregate
release certificate. No RC, stable Hex artifact or final API/default freeze has
occurred. The accepted full runtime/scheduler scope, store/result/API work,
package-only consumer matrix, complete qualification and final-RC soak still
govern the October 9 target.

## Decisions required before moving the public contract

| Decision | Required record |
|---|---|
| Identity | Accepted: `arbor_mcp` / `Arbor.MCP.*`, `arbor_acp` / `Arbor.ACP.*`, optional `arbor_acp_adapters`. App/config/telemetry migration is specified in the package contract; GitHub redirects do not migrate these identities. |
| Repository topology | MCP repository transferred to `trust-arbor/arbor_mcp`; separate ACP repository with independently published core and adapter packages. Release order/ranges are recorded in the package contract. |
| Shared mechanics | Implemented candidate: neutral RPC framing, environment and owned subprocess mechanics are shared by both protocols. Qualify the documented bounds/platforms and freeze its ABI/defaults; ACP never depends on the full MCP package. |
| MCP integration | Keep ACP `mcpServers` descriptors as ACP-owned data; place MCP runtime integration and BEAM-specific extensions in an optional bridge. |
| Vendor adapters | Accepted on 2026-10-03: generic adapter execution remains in ACP; Claude/Codex/Pi/ZCode implementations move to one optional `arbor_acp_adapters` bundle, with explicit core compatibility ranges. |
| Migration | Decide whether a final 1.x release supplies forwarding modules, their support period, and which compatibility names disappear in v2. |
| v2 size | Resolved: retain the full architectural release, including runtime and scheduler. These are v2 release gates. |

The current shim generator hardcodes `ExACP`, `:ex_acp` and corresponding
telemetry prefixes. Adapt it to the accepted names. It forwards functions,
types and callbacks, but cannot preserve `%ExMCP.ACP.*{}` struct identity.
Document affected patterns and runtime state inspection; also review wire
extension keys, generated identifiers and Pi's persisted session-map path.

## Accepted optional ACP adapter package

At source baseline `ed2409c`, `lib/ex_mcp/acp/adapters/` holds 33 files and
17,201 of the ACP tree's 26,948 lines (63.8%, including the ACP facade in the
denominator). The generic bridge and adapter transport accept an explicit
adapter module; the vendor-module references outside the vendor tree are
documentation examples. That provides a natural package boundary.

The accepted topology is one optional `arbor_acp_adapters` package initially:

| Package | Ownership |
|---|---|
| `arbor_acp` | ACP client/agent/protocol/types/transports; `Adapter` behaviour, generic `AdapterBridge` / `AdapterTransport`, event builders and safe subprocess execution. |
| `arbor_acp_adapters` | Claude Code, Codex, Pi and ZCode implementations, native mapping/configuration, vendor session stores and vendor fixtures/lifecycle/drift checks. Depends on ACP; ACP does not depend on it. |

Keep both ACP packages in the ACP repository initially, with separate package
metadata, artifacts and versions. Vendor fixes can then release independently
of core protocol changes. Current runtime dependencies are already Jason and
telemetry, so the primary gains are a smaller core surface, less vendor code
to compile for native ACP consumers, and separate maintenance/release cadence.

The split requires more than moving directories. Vendor adapters use core
helpers that are currently hidden (`Envelope`, `PendingRequests`, `PromptQueue`
and internal map/path/log helpers), and Pi calls `AdapterBridge.PortRunner`.
Define a narrow supported adapter contract for these needs, or move
vendor-only helpers into the bundle; do not make independently released
adapters rely on arbitrary private core modules. Keep shared framing,
environment policy and process lifecycle under one canonical owner.
The extracted `PortRunner` currently also contains vendor-specific environment
handling, including Pi API-key injection; move that policy to the relevant
adapter's configuration/`env` contract while retaining generic isolation and
process safety in the core runner.

Core contract tests must load without vendor code. Vendor golden transcripts
and real-CLI checks belong with the bundle, with integration CI covering the
lowest/newest supported core versions and missing-optional-package behavior.
Migration shims must enumerate modules from both package owners and preserve
the chosen function/type/telemetry compatibility policy without duplicating
modules.

Individual vendor packages can follow if dependency requirements, maintainers
or release needs diverge. Stable vendor module names allow that packaging
change without another namespace migration. The adapter split and package name
are accepted, as are `Arbor.MCP.*` / `Arbor.ACP.*`. The shared-runtime boundary
is specified in [V2_PACKAGE_CONTRACT.md](./V2_PACKAGE_CONTRACT.md).

## V2 implementation checklist

1. **Freeze the migration baseline.** Generate a reproducible API manifest
   from the final 1.x release, covering modules/exports/callbacks/types/structs,
   options, configuration, telemetry, process names and observable defaults.
2. **Complete the package cutover.** Refresh and qualify the extraction,
   establish one canonical ACP implementation, adapt shims if retained, and
   demonstrate MCP-only, ACP-only and combined consumers without cycles.
3. **Implement runtime and scheduling.** Complete per-server supervision and
   scoped state, runtime-owned store lifecycle, common dispatch, bounded
   supervised callbacks, cancellation/deadlines, queue policy and serialized
   state-commit rules. Run cross-transport, isolation and pressure gates.
   Consolidate configuration and result contracts before removing old APIs.
4. **Complete HTTP integration.** The optional-listener candidate supplies
   Cowboy/Bandit adapters, missing-package diagnostics and bounded shutdown,
   retaining Cowboy `:ranch_ref`. Integrate scoped HTTP runtime/session routing
   and qualify the final packaged consumers. Draft PR #21 is preserved as
   historical groundwork; it is not the implementation source of truth.
5. **Remove accepted deprecated APIs.** Verify replacements before removing
   `Server.Tools` and companions, `HTTPServer` / `HTTPServerWithVersion`,
   content transformation stubs and agreed aliases. Every removal needs an
   API-diff entry and a before/after migration example.
6. **Update artifacts and guides.** Package names/dependencies, docs URLs,
   examples, CI/release credentials, telemetry/config migration, and any
   transitional `ex_mcp` package must agree with the accepted topology.
7. **Qualify and soak.** Run the applicable gates below against packaged
   artifacts, publish at least one RC, and record durable release evidence.

The default native Tasks/replay limits now have a reproducible fresh-VM probe
in `scripts/measure_native_store.exs`. On minimum/current toolchains, a 2x wave
followed by an additional 8x wave reaches identical count/byte plateaus with
explicit rejection, then idle expiry drains entries, indices and operation
credit. Actual owned store processes stop. Canonical pressure/store/runtime
selections pass 158/39/332 cases on each toolchain, and the retained/broader HTTP
wire selections pass 19/43 cases each. The pressure probe records owner/VM/RSS
supporting samples without claiming transient peaks or an absolute RSS cap.
Native RPC write admission is integrated at the qualified ACP revision above;
DETS finite cleanup and remaining HTTP convergence still have separate gates.

The next mounted HTTP slice adds accepted notification-array continuation,
ordered initialization arrays, scoped cancellation controls and actual MRTR
retry/replay. Its canonical combined selection passes 23 cases on each supported toolchain,
including seven actual Cowboy socket cases, with the 19 retained-session, 43
Gateway wire and 332 Runtime/deadline/batch cases also passing. Integration
preserves pressure/materialization rules and the original request cutoff. Queued and
future batch cancellation, subscription publication/listener ownership and HTTP
API retirement remain separate gates. See [the control convergence slice](./V2_HTTP_CONTROL_CONVERGENCE_SLICE.md).

Full Linux CI at `20d04d9` passes six of twelve jobs, including both archive
consumers, SDK interop, compliance, external conformance and Dialyzer. All six
failing jobs encounter the same missing `endpoint` default in legacy direct
HttpPlug option maps. The narrow fallback correction preserves explicit mount
paths and modern method rejection; the nine existing session/replay/delete cases
and 35 Gateway routing cases pass on both toolchains. Fresh combined CI remains
required after the control slice and native RPC integration.

The standalone DETS lifecycle slice now adds a native four-table Owner, bounded
node-local path claims and one original finite I/O cutoff. Timeout seals the
store while physical uncertainty retains exclusivity; actual all-table close
confirms cleanup. Owner DOWN alone quarantines the claim. Normal managed app
stop/start preserves rows and clears confirmed authority; unresolved shutdown
or lost authority fails closed until a new VM. Successful facade shapes remain;
storage failures deliberately reply with a typed error before Manager fail-stop.
The private exact-source 52-case contract/lifecycle selection and fresh-VM
application/authority probes pass on minimum/current. Final combined canonical
qualification follows integration. Runtime durable sessions remain explicitly
unqualified. See [DETS lifecycle](./V2_DETS_LIFECYCLE.md).

## DETS and queued HTTP cancellation checkpoint

The committed `a5a8f6e` source passes all twelve jobs in
[complete CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37247550351),
including minimum/current/newest toolchains, both archive consumers, SDK,
external conformance, coverage, performance and Dialyzer. Its local full suites
pass on both supported toolchains: current reports 5,192 executed tests and
minimum a 5,274-test inventory including 82 exclusions; both include 20 doctests
and 34 properties. All 27 pinned SDK/HTTP interoperability cases pass on each.

That checkpoint integrates bounded standalone DETS operations and actual
all-table close receipts, explicit C17 source-build policy, the unreachable
newest-Elixir clause correction and two isolated HTTP test-fixture corrections.
ACP documentation checkpoint `cb8e45c` passes all nine independent CI jobs and
six local standalone documentation builds. Its executable source is unchanged
from qualified native write-admission checkpoint `27f5606`.

The additional immutable queued/future-control packet (manifest
`8008a757fc7fa8cb163e2632e8cd5147a87a5750ae14ea2d623d3f7f4f780e3a`)
merges cleanly while retaining canonical input materialization and byte/deadline
accounting. The canonical merged source passes 38 convergence cases on each
supported toolchain, including ten actual socket cases, plus 19 retained-session
and 43 Gateway cases. It preserves first deadlines and earlier committed batch
state and checks both member handoff windows. Source control input remains
charged until Admission's actual acknowledgment. See
[queued and future controls](./V2_HTTP_FUTURE_CONTROL_SLICE.md). Both full merged-source suites pass 5,207 executed tests, 20 doctests and
34 properties, with 82 exclusions. Formatting, production compilation, strict
Credo, ExDoc and normal minimum Dialyzer pass, as does actual local newest
production compilation. The exact `d3ce77b` [fresh CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37249145133) finishes eleven of twelve jobs green. The sole newest-toolchain failure is the ordinary Client owner-death fixture's default 100 ms startup observation; compilation and all other 4,490 unit tests in that job pass. The failure is retained, and the fixture correction requires a fresh run.

The [listener lifetime core](./V2_HTTP_LISTENER_LIFETIME_CORE.md), immutable manifest
`f71715b7bb11450dec0862dfef3e94843add15979d582967680e5e88ec19ccd1`,
merges as five exact source files on `d3ce77b`. It captures the potential listener
cutoff once at Plug entry and grants a separate nonce-bound target capability
only to an actually admitted scalar Gateway invocation. Ordinary request and
publication authority retain their original cutoffs. The source packet passes
48 pure cases on minimum/current/newest, warnings-as-errors and formatting on
all three, current Credo and ExDoc, and normal/raw supported Dialyzer with no
new filters or owned production warnings. Mounted routing, actual socket
receipts and SDK subscription behavior remain required; this core is an
unwired prerequisite. Its merged canonical graph also passes the same 48 pure
cases and warnings-as-errors on all three toolchains.

The one-file readiness fixture correction, immutable manifest
`f58bc3b4a005005d6e571ecec6d1769e76ae57e76bb001233105e5dd7092d9a8`,
observes startup for up to 1,000 ms and confirms the test-owned process is DOWN
on failure. A separate 150 ms pre-start delay reproduces the original 100 ms
assertion failure and passes with the corrected fixture on all three toolchains.
Production establishment/cleanup deadlines and client/guardian/borrowed-backend
assertions are unchanged. The exact corrected case also passes against the merged
canonical graph on all three toolchains. Current strict Credo checks 741 files
without issues, supported formatting and production warnings-as-errors pass,
and current ExDoc and normal minimum Dialyzer pass with the same 66 existing
filters. A fresh CI run remains required.

Final HTTP changes and release-wide qualification remain
distinct from the earlier green CI.

## October 5 current qualification checkpoint

Committed MCP `1284440` integrates the bounded HTTP reverse path and explicit
Runtime fixtures. Its 636-case combined selection passes on all three captured
toolchains and its 40 actual HTTP wire/Client cases pass on both supported
toolchains. Checkpoint `e284fee` commits the later scoped HTTP bookkeeping,
legacy JSON progress and shutdown observation followups. Its immediately
preceding qualified snapshot passes 671 combined cases, warnings-as-errors
compilation and full formatting on all three. The 50-case HTTP wire selection,
strict Credo/normal Dialyzer and docs with warnings as errors pass both supported
toolchains. The raw warning census retains 72/current and 66/minimum, none in
owned paths and no new filters. The 13 actual SDK stdio/HTTP cases pass both
with no skips. The only later change in that source batch restores the
conformance fixture's original 150 ms progress workload; production and
configuration remain unchanged. Counts identify separate selections, not an
aggregate release total, and the earlier snapshot receipts remain distinct.

The working followups include six passing direct Plug OAuth cases, with validated
methodless response default scopes `[]` while full ServerGuard, custom mapping
and exact identity/endpoint/session/source checks remain. Actual OAuth wire was
pending at that checkpoint; the later API5 result is recorded below. Four pure
legacy JSON Context progress cases preserve
the final JSON response and authenticated addressed-session delivery. The
shutdown wait-order fix reads completion after actual observer death under the
unchanged cutoff. It resolves the accepted-await minimum selection failure;
that earlier 667-case receipt remains preserved alongside the passing 671-case
selection.

The earlier full current run executed 5,340 tests, 20 doctests and 34 properties
with one stale retained-protocol documentation assertion and 207 exclusions.
The corrected four-module docs and assertion pass their focused cases on all
three toolchains. A fresh full current rerun now passes 5,344 tests, 20 doctests
and 34 properties with zero failures and 207 exclusions. The earlier failed
receipt remains preserved; final full minimum and complete CI remain required.

Official stable conformance 0.1.16 now reports 38 server scenarios passed and one
failed on both supported toolchains. The earlier 34/5 and 37/2 receipts remain
preserved. The error-tool and subscribe/unsubscribe callback corrections are
covered by the actual reruns. After restoration of the original paced fixture,
the single progress scenario observes three ordered 0/50/100 notifications and
passes. The remaining multiple-stream scenario uses `2025-03-26` after
negotiating `2025-11-25`, producing the retained HTTP 400 version fence; fresh
correctly versioned requests return 200/200/200. The published mismatch remains
unresolved; no expected-failure adjustment or protocol downgrade qualifies the
stable server gate. Stable client conformance passes 218 cases on both supported
toolchains, and modern 0.2.0-alpha.11 passes 149 server and 387 client cases on
both. These selected-profile successes do not qualify the final package graph.

MCP migration documentation and ACP documentation checkpoints are pushed.
At this dated checkpoint, four-package API and actual 2024 continuous-consumer
preparations were source-only. Later API5 and consumer execution is recorded
below; the accepted continuous 48-hour final-RC run and release qualification
remain open. The earlier interim receipts remain preserved.

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

## Historical remaining-work register — October 6 checkpoint

The table records the checkpoint's then-open evidence. The current assessment
above supersedes its implementation/status claims; retained counts belong only
to the source selections named below.

| Phase | Remaining release work at that checkpoint |
|---|---|
| 1: contracts | Reconcile the implemented [removal/replacement inventory](./V2_API_MIGRATION.md), non-symbol migration and result/configuration contracts against the final compiled graph. Freeze and qualify final public defaults and package ranges. |
| 2: runtime | Installed HTTP POST, retained sessions and queued/future cancellation are integrated. Mounted subscriptions, durable legacy resource publication, aliases, Runtime-only mounts and reverse controls are integrated. Complete final combined and authenticated wire qualification. Final cross-runtime crash/restart/stop and upgrade evidence remains required. |
| 3: dispatch/scheduler | Test/BEAM, stdio, custom calls and HTTP Gateway prepare bounded output before serialized state commit, with grouped batches and actual writer receipts. Subscription/publication and bounded reverse wiring are integrated. Qualify final cross-transport equivalence, authenticated wire and crash-log privacy on the sealed graph. |
| 4: stores | Built-in Runtime session storage is ETS; unqualified durable session backends reject explicitly. Standalone DETS has bounded operations, path ownership and confirmed/unconfirmed cleanup. Final combined persistence/recovery, lifetime and payload-safe telemetry evidence remains required. |
| 5: public API | Shared `Server.Result`, default 2020-12 validation, selected DSL composition, media/options migration, dynamic owned tools, `with_connection` and ordinary Client cleanup pass their integrated selections. All 102 accepted callable removals, ten module retirements and four type retirements pass the API5 compiled comparison. Bind any later accepted source and RC metadata to fresh compiled evidence and final configuration/default contracts. |
| 6–7: migration/release | Associate any later accepted source and RC metadata with fresh four-package API/package/consumer evidence; complete cross-transport, pressure/isolation/privacy/upgrade, published conformance, performance and v2 RC/soak gates. |

The accepted runtime contract specifies callback PID/links, state order,
cancellation, ownership and restart behavior. The common runtime implements
those scheduling semantics across Test/BEAM, server stdio and HTTP Gateway; the
integrated reverse path still requires final combined transport qualification before release.
A client wait timeout and a server execution deadline remain distinct. Later
2.x changes preserve the qualified contract or introduce compatible opt-in behavior.

## Release evidence required

- Clean independent consumer builds and package inspection, with measured
  archive/compile/dependency results and lowest/newest dependency contracts.
- MCP legacy compliance, modern external conformance and official-SDK lanes;
  ACP SDK, adapter golden transcripts and credential-free real-CLI lifecycle.
- Cowboy, Bandit and Phoenix-mounted HTTP coverage; stdio/ACP builds without
  Cowboy/Cowlib; retained security, framing, Unicode and replay contracts.
- Namespace/shim/config/telemetry/struct migration checks and combined-package
  loading without duplicate modules or application-name collisions.
- Performance budgets against the final 1.x artifact; applicable isolation,
  cancellation, pressure, persistence and upgrade gates for accepted changes.
- RC artifact, soak duration, release owner and durable evidence for each gate.

## Proposed GitHub and Hex migration

**Completed 2026-10-03:** after explicit approval, transferred the public
repository to `trust-arbor/arbor_mcp` and updated `origin`. The repository ID
remains `989917799`; master (`1808c56`), the `v1.5.0` tag/release, draft PR #21
and Actions enablement were verified at the new URL. The old API path resolves
to the same repository. A pre-transfer Git bundle is saved locally at
`tmp/v2-migration-2026-10-03/ex_mcp-before-transfer.bundle`. Branch-protection,
third-party integrations and new package credentials still require release
qualification. The public `trust-arbor/arbor_acp` repository has also been created. Its
tested v2 extraction is pushed to `main`; Hex packages remain unpublished.

**Recommended sequence:** move GitHub ownership early, finish the architecture
in the destination, and migrate consumers through the qualified v2 packages.
The transfer itself does not require a completed runtime redesign. It also
does not make the stale extraction ready for implementation cutover.

1. Settle destination repositories, package/module/app identity and shared
   mechanics ownership. Capture the 1.x API and behavior baseline.
2. Transfer/rename the existing repository, update remotes, and verify CI,
   branch rules, repository permissions and release integrations at the new
   location. Keep the supported 1.x line and tags available.
3. Reconcile the ACP extraction and establish its canonical repository with
   CI once shared boundaries are settled. Preserve the dirty spike as input;
   stop regenerating ACP from MCP when ACP becomes canonical.
4. Finish runtime/scheduler, stores, dispatch, HTTP and public API work in the
   final repositories; qualify independent and combined consumers.
5. Publish the v2 migration guide, RC artifacts and eventual stable packages
   after the release gates and soak. Consumer dependency/namespace changes
   happen through this release rather than through the GitHub transfer.

If separate Arbor repositories are accepted, transfer the existing repository
to `trust-arbor/arbor_mcp` so its history, issues, pull requests and stars remain
with the MCP lineage. Create `trust-arbor/arbor_acp` from the reconciled ACP
extraction. GitHub's transfer/rename redirect has one successor; it cannot
route the old repository to both packages. Put a split notice linking ACP in
the destination README.

The GitHub owner/admin uses repository **Settings → Danger Zone → Transfer**,
selects `trust-arbor`, and supplies the new repository name when permitted;
otherwise transfer first and rename in the receiving repository's settings.
Then update the clone's remote:

```sh
git remote set-url origin git@github.com:trust-arbor/arbor_mcp.git
```

GitHub automatically redirects ordinary repository URLs and Git operations.
Do not recreate `azmaveth/ex_mcp`: that replaces the redirect. Project-site
URLs and consumers of repository-hosted Actions require separate handling.
See GitHub's [transfer documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/transferring-a-repository)
and [rename documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository).

Treat `arbor_mcp` and `arbor_acp` as new Hex package identities with explicit
dependency migration; a GitHub redirect does not change a Mix dependency on
`ex_mcp`. Choose the OTP apps and module namespaces separately, update package
links/docs/release metadata, and qualify coexistence with any transitional
package. Hex's [publishing guide](https://hex.pm/docs/publish) distinguishes
package name from application name, and its [usage guide](https://hex.pm/docs/usage)
documents the `:hex` override. Hex ownership is also separate from GitHub;
[mix hex.owner](https://hex.hexdocs.pm/Mix.Tasks.Hex.Owner.html) manages it.

Preserve wire/storage identifiers such as `_meta.ex_mcp`, the BEAM capability
extension and Pi's persisted session-map path unless a separate migration is
accepted. Renaming a library does not justify silently changing those contracts.
The MCP repository transfer and canonical ACP source cutover are complete.
Package publication remains gated on final artifact qualification and the RC soak.
