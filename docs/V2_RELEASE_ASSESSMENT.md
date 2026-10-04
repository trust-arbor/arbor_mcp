# ExMCP v2 Release Assessment

- **Reviewed:** 2026-10-04
- **Released baseline:** `v1.5.0`
- **Integrated source baseline:** `e4d2fc3`
- **Status:** Full v2 scope, adapter split and Arbor namespaces accepted; GitHub MCP transfer complete; implementation and qualification in progress
- **Release target:** Friday 2026-10-09, subject to release gates and RC soak
- **Canonical plan:** [V2_ROADMAP.md](./V2_ROADMAP.md)

## Release conclusion

The library has a stable protocol baseline and useful split preparation, but
neither the package cutover nor the architectural v2 roadmap is complete.

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
repository migration is complete. Main remains a supported 1.x package; the
latest main CI passed at `080322d` after the Mint floor was raised to `1.10.2`
and the Pi fixture was corrected.

| Slice | Reviewable evidence | Remaining work |
|---|---|---|
| MCP package/runtime foundation | [Draft PR #76](https://github.com/trust-arbor/arbor_mcp/pull/76), committed through `46b4f86`; independent MCP package and scheduler foundation. [Complete CI](https://github.com/trust-arbor/arbor_mcp/actions/runs/37183380769) passes all ten jobs, including Elixir 1.17–1.20, coverage, conformance, SDK interoperability, performance and Dialyzer. | This CI snapshot precedes the local handler-runtime and optional-listener integration. Requalify the exact combined commit. |
| Neutral shared subprocess | [ACP draft PR #1](https://github.com/trust-arbor/arbor_acp/pull/1), committed through `25fc8d1`; stable owner, generation events, explicit frame credit, bounded managed queues/writes, absolute read deadlines and finite cleanup. Its 74 tests pass on minimum, current and newest toolchains, including fast-child metadata and stale-PID cleanup. | Raw Port-driver mailbox pressure, process-group/platform behavior and full packaged-consumer qualification remain release gates. Fast group startup requires measured ownership proof and can return an explicit proof error. |
| ACP bridge, Pi and native stdio/client | Shared-handle adoption, explicit cleanup errors and adapter frame-receipt extension in [draft PR #1](https://github.com/trust-arbor/arbor_acp/pull/1). RPC 74, core 352, adapter 1,447 and six pinned SDK tests passed on minimum/current toolchains; production compilation, formatting, boundaries and all three archive inspections passed. Original golden transcripts were unchanged. [Package CI](https://github.com/trust-arbor/arbor_acp/actions/runs/37183152160) and [SDK CI](https://github.com/trust-arbor/arbor_acp/actions/runs/37183149767) pass at `25fc8d1`. | Remaining vendor utility subprocess paths, pressure/platform behavior and full release qualification need evidence. |
| MCP child stdio/client | Committed through `46b4f86` in [draft PR #76](https://github.com/trust-arbor/arbor_mcp/pull/76), with shared RPC pinned at `25fc8d1`: frame credit until protocol processing, one absolute read deadline and known cleanup failures across repeated disconnect. All 13 legacy/modern SDK cases and 28 focused lifecycle cases pass; complete CI is green. | This integrates client-owned children. Server stdio still needs the runtime cutover, output pressure and finite EOF drain. |
| Handler runtime integration | Local Test/BEAM candidate moves callbacks and committed state into the scheduler, scopes peer generations/cancellation, and uses bounded ETS ingress plus independent incoming/outgoing control lanes. The combined default run passes 20 doctests, 34 properties and 3,695 tests (207 excluded); 110 focused runtime/caller cases also pass. | Final quality gates and immutable checkpoint are in progress. HTTP, server stdio, output/batch budgets, public stores and complete cross-transport equivalence remain unfinished. |
| Optional HTTP listeners | Local integrated candidate has optional Cowboy/Cowlib/Bandit dependencies, bounded listener shutdown and missing-adapter diagnostics. Each minimum/current listener suite passes 34 tests. Six real packaged consumers cover core-only, Cowboy-only and Bandit-only graphs across both toolchains; ExDoc, strict Credo and audit checks pass. The stdio/listener composite also compiles on Elixir 1.20.3/OTP 29 and passes 118 focused tests. | Requalify the final combined commit. Runtime-mounted HTTP, per-session routing/stores, Phoenix consumption and full release conformance remain separate gates. |

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

## Full-roadmap work still outstanding

| Phase | Remaining implementation |
|---|---|
| 1: contracts | Review and finish the [removal/replacement inventory](./V2_API_MIGRATION.md), non-symbol migration, result/configuration contracts and final public defaults. The runtime candidate validates its scheduling configuration, but not every transport/configuration option. |
| 2: runtime | Extend the implemented Test/BEAM supervisor/reference and scoped cancellation to server stdio and HTTP. Replace application-singleton session/subscription/replay/task owners; qualify store lifecycle and cross-runtime crash/restart/stop isolation. |
| 3: dispatch/scheduler | The Test/BEAM candidate now schedules supervised callbacks with bounded ingress, deadlines, cancellation and serialized commits. Server stdio and HTTP still need the same path, bounded output/batch accumulation and full cross-transport qualification. |
| 4: stores | Deliberate public contracts, runtime-owned adapter lifecycle and payload-safe store telemetry. The internal ETS/DETS seam is groundwork, not the whole target. |
| 5: public API | Unified `Server.Result`, selected DSL constraints/composition, and bracketed client connection ownership. No `with_connection` helper or unified result facade exists. |
| 6–7: migration/release | Accepted removals, final API diff/guide, cross-transport equivalence, runtime pressure/isolation/upgrade evidence and v2 RC/soak. |

The accepted runtime contract specifies callback PID/links, state order,
cancellation, ownership and restart behavior. The Test/BEAM candidate implements
those scheduling semantics; server stdio and HTTP must converge before release.
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
The MCP repository transfer is complete. Package publication and canonical
ACP cutover remain gated on implementation and qualification.
