# Pre-modern-protocol Technical Debt Plan — target `1.0.0-rc.5`

**Status:** Implemented; release gates passed
**Target release:** ArborMCP `1.0.0-rc.5` (completed prerequisite for additional 1.0 RCs)
**Protocol:** unchanged — MCP `2024-11-05` / `2025-03-26` / `2025-06-18` / `2025-11-25`
**Companion doc:** [`MCP_2026_07_28_MIGRATION_PLAN.md`](./MCP_2026_07_28_MIGRATION_PLAN.md) — the 1.0 modern-protocol work this unblocks
**Last updated:** 2026-08-04

> **Historical plan:** This document records completed rc.5 work. The current
> major-version plan is [`V2_ROADMAP.md`](./V2_ROADMAP.md).

---

## 1. Purpose and the hard constraint

The 2026-07-28 migration plan opened with a "Phase 0 — Foundations" that turned out to be
almost entirely **pre-existing debt**, unrelated to the new protocol revision. This document
splits that work out so it can ship as a release candidate **before** the modern migration.

> **Acceptance gate for every item in this plan:**
> **no observable change to the JSON-RPC wire, and no change to any documented public return
> value, for any of the four currently supported protocol versions.**

An item that fails that gate does not belong in rc.5. Section 5 lists the ones that failed and
where they go instead.

**One deliberate exception:** Track G fixes URL-mode elicitation routing, which today silently
drops the `url` field. It changes which client callback fires, so it does not pass the gate as
written — it is included as an explicit, documented bug fix. It is the *only* item in this plan
allowed to change behavior, and it is called out separately in the CHANGELOG and the release
checklist so the exception stays visible rather than setting a precedent.

### Why do this first

1. **It is a prerequisite, not a nice-to-have.** Adding a fifth protocol version currently
   requires editing **five** parallel method tables and **four** places in the compliance test
   generator. Doing 2026-07-28 on top of that multiplies every change by five.
2. **It de-risks the modern-protocol diff.** Every line changed for cleanup reasons is a
   line that obscures the protocol change during review.
3. **It is independently valuable.** These are real bugs and real duplication that affect users
   on 1.x today.
4. **It gives the migration a tested baseline** before the modern wire paths are added.

### Non-goals

- No protocol behavior changes.
- No new protocol versions (2026-07-28 stays unregistered until a follow-on RC).
- No API removals — `Arbor.MCP.Server.Tools` stays available throughout 1.x and is removed in 2.0.
- No performance work.

---

## 2. How we prove "no behavior change"

This is the part that makes the plan credible. **Track 0 lands before any other track.**

### Track 0 — Characterization tests (do this first)

Write tests that pin *current* behavior, before touching the code they describe. They must
pass unchanged at the end of every subsequent track.

- [x] **Capability snapshot test.** For each of the four supported versions, snapshot the exact
      map returned by `Arbor.MCP.Server.Capabilities.build_capabilities/2` — this is the one that
      actually reaches the wire, via `server/handler.ex:300`. Assert deep equality against a
      committed fixture.
- [x] **Initialize-result golden test.** For each version, snapshot the full `initialize`
      result from all five implementations that produce one (see §4.6): `RequestProcessor`,
      `MessageProcessor`, `Server.Handler`, `Server.DSL`, `Transport.HTTPServer`. Include the
      **omitted-`protocolVersion`** case, which is currently untested and is exactly where a
      refactor would silently drift (`request_processor.ex:119` defaults to `"2025-06-18"`).
- [x] **Method-table equality test.** Assert that the five parallel method tables (§4.2) agree
      with each other today, method-for-method. This test is what lets Track B swap in a single
      table safely — it must pass both before and after.
- [x] **Error-code snapshot.** Assert the numeric code returned by every public error
      constructor across `ErrorCodes`, `Error`, `SecurityError`, and `ACP.Types`, including the
      three distinct meanings currently attached to `-32002` (§5.2).
- [x] **Elicitation routing test.** Pin which client callback fires for form-mode and URL-mode
      elicitations, **through the real client** rather than by invoking the callback directly.
      Track G changes this deliberately — the test is what makes the change visible in review
      instead of silent. It is the one Track 0 test expected to be updated, and its diff should
      be the readable summary of what Track G did.

**Exit:** these tests pass on `main` before a single production line changes.

---

## 3. Track summary

| Track | Theme | Risk | Unblocks modern support? |
|---|---|---|---|
| 0 | Characterization tests | none | — (safety net) |
| A | One source of truth for versions | low | yes |
| B | **One method table** (five → one) | low–medium | **yes, highest leverage** |
| C | Error-code consolidation (numeric only, additive) | low | yes |
| D | Dead-code removal | none | minor |
| E | **Compliance test generator** | none (test-only) | **yes, blocks modern support** |
| F | Docs & config accuracy | none | minor |
| G | **Fix URL-mode elicitation routing** | medium — the one intentional behavior change | yes (MRTR reuses this path) |

Suggested order: **0 → E → B → A → C → D → F → G**. E comes early because it is test-only, zero
risk, and every later track wants to add version-parameterised tests. G goes **last** so the
wire-diff check in §7 runs against a tree where it is the sole known difference.

---

## 4. Tracks

### Track A — One source of truth for protocol versions

**Finding:** the four "duplicate version lists" are really *two lists plus two scalars*, and
they currently **agree exactly**. That is what makes this safe — it is deduplication, not
reconciliation.

| Location | Contents | Action |
|---|---|---|
| `lib/arbor_mcp/internal/version_registry.ex` L14-19, L33 | `@versions` + `latest_version/0` — canonical, 12 lib callers | **Keep as canonical** |
| `lib/arbor_mcp/protocol/version_negotiator.ex` L13-14 | `@supported_versions` / `@latest_version` — byte-identical list, same order | **Delegate to VersionRegistry** |
| `lib/arbor_mcp/types.ex` L27 | `@latest_protocol_version` scalar, exposed as `Arbor.MCP.Types.latest_protocol_version/0`, **zero callers** in `lib/` or `test/` | **Delegate to VersionRegistry** |
| `config/config.exs` L8 | `protocol_version: "2025-11-25"`, read by `VersionRegistry.preferred_version/0` and `transport/http.ex:169` | **Leave the value alone**; document only |

- [x] `VersionNegotiator.@supported_versions` / `@latest_version` → delegate to
      `VersionRegistry`. The only lib call site is `transport/http.ex:170`
      (`VersionNegotiator.latest_version/0` as the third fallback for the
      `MCP-Protocol-Version` header) and it returns the same string either way.
- [x] `Arbor.MCP.Types.latest_protocol_version/0` → delegate to `VersionRegistry.latest_version/0`.
      Same value; zero callers. Add the missing `@doc`.
- [x] Add `era_for/1` and `modern?/1` helpers to `VersionRegistry`, returning `:legacy` for all
      four current versions. **Purely additive**, unused in rc.5, consumed heavily by the modern migration.
- [x] Add `request_methods: []` to the three `message_format/1` clauses that omit it
      (`version_registry.ex` L187-240) — only the `"2025-11-25"` clause (L241-267) has the key
      today, so any consumer doing `Map.get(format, :request_methods)` gets `nil` for older
      versions. Internal shape fix, no wire effect.
- [x] Log a warning (do **not** change the return) when `capabilities_for_version/1`
      (L131) or `message_format/1` (L269) falls through to the latest-version default for an
      unrecognised version string. A typo'd version currently gets full 2025-11-25 capabilities
      silently.

> **Explicitly NOT in this track:** merging `VersionNegotiator.build_capabilities/1` into
> `VersionRegistry.capabilities_for_version/1`. See §5.1 — they are two different capability
> vocabularies with zero overlapping experimental keys, not a mechanical dedup.

**Exit:** `grep -rn '"2025-11-25"' lib/` returns only `version_registry.ex` and
`config/config.exs`. Capability snapshot test unchanged.

---

### Track B — One method table (highest leverage)

**Finding:** there are **five** parallel method tables, not three. Adding one method today
means five coordinated edits.

| # | Location | Shape |
|---|---|---|
| 1 | `lib/arbor_mcp/server/dispatch.ex` L41 | `@methods` + `known_method?/1` |
| 2 | `lib/arbor_mcp/message_processor.ex` L292 | `@method_handlers` + `dispatched_methods/0` |
| 3 | `lib/arbor_mcp/protocol/request_processor.ex` L72-93 | `dispatch_method/3` function heads |
| 4 | `lib/arbor_mcp/internal/protocol.ex` L555-568 | version-gating MapSets |
| 5 | `lib/arbor_mcp/internal/version_registry.ex` L187-265 | `message_format/1` `notification_methods` / `request_methods` |

- [x] Introduce `Arbor.MCP.Protocol.Methods` — a single table of
      `{method, min_version, max_version, kind, handler}` rows.
- [x] **Prove equality before switching.** The Track 0 method-table test asserts the five
      current tables agree; extend it to assert the new table reproduces each of the five
      exactly. Only then rewire consumers.
- [x] Rewire all five consumers to derive from `Methods`. Delete the local tables.
- [x] Delete the dead `@methods_v20250326_plus` branch — the MapSet is empty
      (`internal/protocol.ex` L555), making the `cond` branch at L584-585 and
      `@versions_v20250326_plus` (L569) unreachable.
- [x] Decide on the phantom `"draft"` version (`internal/protocol.ex` L565-568, gating
      `"server/discover"` and `"subscriptions/listen"`). No `lib/` caller ever passes `"draft"`,
      but `test/arbor_mcp/version_registry_test.exs` L161-162 asserts it. Either keep it as the
      2026-07-28 staging ground (recommended — it is already the right shape) or delete it and
      those two test lines.

**Exit:** adding a protocol method is a one-row edit. Method-table equality test green.

---

### Track C — Error-code consolidation (numeric only, additive)

**Finding:** all four definitions **agree numerically** — the duplication is real but harmless.
The `-32002` collision is a genuine bug but resolving it is wire-visible, so it is deferred
(§5.2).

- [x] Collapse the three duplicate JSON-RPC code blocks into `Arbor.MCP.Protocol.ErrorCodes`:
      `internal/protocol.ex` L652-656 (5 codes), `types.ex` L31-35 (same 5),
      `internal/message_validator.ex` L26-29 (4 of them). All identical — pure dedup.
- [x] Collapse `ErrorCodes`' own two identical atom→code maps: `@atom_to_code` (L114-126) and
      `@atom_to_code_map` (L216-228), same module, identical contents.
- [x] **Additively** define `-32020` `HeaderMismatch`, `-32021` `MissingRequiredClientCapability`,
      `-32022` `UnsupportedProtocolVersion`. Unused in rc.5; consumed by the modern migration.
- [x] Add a `@doc` warning documenting that `-32002` currently carries **three** meanings —
      `consent_required` (`ErrorCodes` L45, emitted by `transport/security_error.ex:138`),
      `resource_not_found` (`ErrorCodes` L48, emitted by `acp/types.ex:139,148`), and
      `prompt_error` (`error.ex:384`, categorised `"Prompt Error"` at L461) — and that
      `error_message(:resource_not_found)` consequently returns `"Consent required"`. Document
      the bug; do not fix it here.

**Exit:** one error-code module. Error-code snapshot test unchanged.

---

### Track D — Dead code removal

All items verified to have **zero callers** in `lib/` and `test/`.

- [x] `MessageValidator.validate_method_version/2` (L349-360) — zero callers anywhere. Delete.
      (Wiring it in would be a behavior change — see §5.4.)
- [x] `MessageValidator` L80-88 batch-rejection clause — provably unreachable:
      `new_session/1` (L34) defaults `protocol_version` to `nil`, the sole lib call site
      `internal/protocol.ex:521` never passes a version, and no test sets it. Delete the clause
      **or** leave it and note the dead-code status; do **not** "fix" it to use version ordering,
      since wiring session versions through is the actual behavior change.
- [x] `@methods_v20250326_plus` / `@versions_v20250326_plus` — folded into Track B.
- [x] Audit `ErrorCodes.consent_required/0` and `ErrorCodes.resource_not_found/0` — zero
      callers; the real emitters bypass `ErrorCodes` entirely. Mark deprecated rather than
      removing (they are in a moduledoc'd module).

---

### Track E — Compliance test generator (blocks modern support)

**Finding:** `test/arbor_mcp/compliance/version_generator.ex` is already stale — it covers **three**
of the four supported versions. `2025-11-25` was never added and lives as a hand-written
standalone file instead.

Adding a version currently requires **four** coordinated edits:

| Location | What |
|---|---|
| L11 | `@versions ["2024-11-05", "2025-03-26", "2025-06-18"]` |
| L64-69 | the same list hardcoded **again** inside a generated assertion |
| L52-58 | version→handler `case`, falling through to `Arbor.MCP.Server.Handler` for anything new |
| — | a new `Handlers.HandlerYYYYMMDD` module |

- [x] Derive `@versions` from `VersionRegistry.supported_versions()`.
- [x] Remove the duplicated inline list at L64-69.
- [x] Replace the version→handler `case` (L52-58) with a map, and make an unmapped version a
      **loud failure** rather than a silent fallback to `Arbor.MCP.Server.Handler`.
- [x] Add `Handlers.Handler20251125` and fold the standalone
      `compliance/version_2025_11_25_test.exs` into the generated path where it duplicates
      generated coverage — keeping genuinely 2025-11-25-specific assertions standalone.
- [x] Audit the 14 `Features.*` modules for version-conditional gaps now that a fourth version
      flows through the generator.

**Exit:** adding a version is one row in a map plus one handler module. All four supported
versions flow through the generator.

---

### Track F — Docs and config accuracy

- [x] `docs/CONFIGURATION.md` L37 documents `VersionNegotiator.valid_version?/1` — **this
      function has never existed**. The real name is `supported?/1`. Fix before anyone writes
      code against it.
- [x] `config/config.exs` L14-20 declares three of the four feature flags —
      `tasks_enabled` is missing while `FeatureFlags.enabled?(:tasks)` reads it (L40-42). Add
      it with its current effective default (`false`).
- [x] `Arbor.MCP.FeatureFlags` `@doc` (L14-16) and the `all/0` doctest (L52-56) both omit `:tasks`,
      though `all/0`'s body includes it (L64). Fix the docs to match the code.
- [x] Document `Arbor.MCP.Transport.HTTPServer.call_server_method/3` as a **simplified example**,
      not a production path — it is a public-by-documentation Plug with a canned `initialize`
      response, zero repo callers and zero tests (§5.3).
- [x] `CLAUDE.md`: note that `Arbor.MCP.Protocol.VersionNegotiator` is a thin shim over
      `VersionRegistry` and that `VersionRegistry` is the module to reach for.

---

### Track G — Fix URL-mode elicitation routing

**This is the one intentional behavior change in rc.5.** It fixes silent data loss, so it is a
bug fix rather than a break — but it is a bug fix that changes which callback fires, and this
plan treats that honestly rather than filing it under "cleanup".

#### The bug

`Arbor.MCP.Client.Handler` declares `handle_url_elicitation/3` at `client/handler.ex` L213 and lists
it in `@optional_callbacks` at L256. **Nothing ever calls it.**
`client/request_handler.ex` L429-447 routes `"elicitation/create"` unconditionally to
`handle_elicitation_create_request/3` (L506-538), which only checks
`function_exported?(handler, :handle_elicitation_create, 3)` and reads `params["message"]` and
`params["requestedSchema"]`.

Meanwhile `internal/protocol.ex` L406-414 (`encode_elicitation_create_url/3`) sends URL-mode
elicitations under the *same* `"elicitation/create"` method, with `mode: "url"`, a `url` field
and an `elicitationId`. So today a URL-mode elicitation reaching a client is handed to
`handle_elicitation_create/3` with `requested_schema` defaulted to `%{}` (the `Map.get` at
L511), and **the `url` — the entire point of the request — is silently discarded.**

#### Who is affected

| Handler implements | Today | After |
|---|---|---|
| `handle_elicitation_create/3` only | receives URL-mode requests with the `url` stripped | unchanged **unless** it is the only callback — then it still receives them (see fallback below) |
| **both** callbacks | URL-mode goes to `handle_elicitation_create/3` | URL-mode goes to `handle_url_elicitation/3` — **this is the change** |
| `handle_url_elicitation/3` only | never called; falls to the `-32601` / default-handler branch at L520-536 | called |

#### Work

- [x] **Characterization test first** (part of Track 0): pin the *current* routing for both
      form-mode and URL-mode, through the real client rather than by calling the callback
      directly. Existing coverage does not do this —
      `compliance/url_elicitation_test.exs` L253-264 invokes
      `TestClientHandler.handle_url_elicitation/3` **directly**, bypassing the client entirely,
      and L266-269 only asserts the callback appears in `behaviour_info(:optional_callbacks)`.
      This is why the bug survived.
- [x] Route on `params["mode"] == "url"` in `request_handler.ex` L429-447 → dispatch to
      `handle_url_elicitation/3` when the handler exports it.
- [x] **Fallback, so nothing regresses:** if the handler does *not* export
      `handle_url_elicitation/3`, keep routing to `handle_elicitation_create/3` as today. This
      keeps single-callback handlers working. Log a warning once per handler module noting the
      `url` is being dropped and pointing at the callback to implement.
- [x] Stop discarding the payload on the legacy path: pass `url` and `elicitationId` through
      rather than defaulting `requested_schema` to `%{}` and dropping the rest.
- [x] Add real routing tests for both modes, both handler shapes, and the fallback path.
- [x] Update `Arbor.MCP.Client.Handler` `@doc` — the current docs give no indication that
      `handle_url_elicitation/3` is inert.

#### Release notes

- [x] CHANGELOG under **Fixed**, worded so users with both callbacks understand the dispatch
      moved. Do **not** use a `BREAKING:` prefix — it is a fix — but do call it out as the one
      behavior change in the release.
- [x] Note it in the rc.5 release announcement alongside the "no wire change" claim, so the
      claim reads as accurate rather than overstated.

#### Why it belongs here rather than in the modern migration

The MRTR work (Phase 4) fulfils `inputRequests` through these *same* `Arbor.MCP.Client.Handler`
callbacks. Landing the routing fix first means MRTR inherits a correct dispatcher instead of
reproducing the bug in a second code path — and it means the modern-protocol diff does not have to explain
a behavior change buried inside a protocol migration.

---

## 5. Deferred — failed the no-behavior-change gate

Each of these was considered for rc.5 and rejected. They carry forward to the modern plan.

### 5.1 Merging the two capability vocabularies — **defer to the modern migration**

`VersionNegotiator.build_capabilities/1` and `VersionRegistry.capabilities_for_version/1` are
not duplicates; they are **different vocabularies**:

| Version | `VersionNegotiator` experimental keys | `VersionRegistry` experimental keys |
|---|---|---|
| 2024-11-05 | `batchRequests` | *(none)* — but advertises `prompts`/`resources`/`tools`/`logging`, which VN does not |
| 2025-03-26 | `batchRequests` | `batchProcessing` — **different key name for the same idea** |
| 2025-06-18 | `protocolVersionHeader`, `structuredOutput`, `oauth2` | `elicitation`, `structuredContent`, `toolOutputSchema`, `batchProcessing` — **zero overlap** |
| 2025-11-25 | above + `icons`, `urlElicitation`, `toolCallingInSampling`; `tasks` flag-gated | above + `urlElicitation`, `icons`, `toolCallingInSampling`; `tasks` unconditional |

Only `VersionRegistry` reaches the wire. `VersionNegotiator.build_capabilities/1` has **zero
lib callers** — but ~45 test assertions across six files pin its vocabulary. Merging is a
design decision about which vocabulary is correct, not a refactor.

**rc.5-safe subset:** document the split; mark `VersionNegotiator.build_capabilities/1` as
not-wire-reaching in its `@doc`.

**Resolved in the 2026-07-28 migration Phase 0:** the helper is retained through 1.x as a
deprecated shim over the canonical registry vocabulary.

### 5.2 Resolving the `-32002` collision — **defer to the modern migration**

**Resolved in the 2026-07-28 migration Phase 0:** emission is era-aware, legacy decoding is
preserved, and ArborMCP-local consent/prompt errors moved outside the JSON-RPC reserved range.

Wire-visible three ways, and 386 numeric-code assertions across 77 test files sit downstream.
2026-07-28 renumbers resource-not-found to `-32602` anyway, so the fix belongs with the version
that mandates it. rc.5 adds the new constants additively (Track C) and documents the bug.

### 5.3 `transport/http_server.ex` L295 hardcoded `"2025-03-26"` — **defer / needs care**

Changing it to `VersionRegistry.latest_version()` breaks **no tests** (nothing in `test/`
references `Arbor.MCP.Transport.HTTPServer`) — but that is precisely the risk. It is a
public-by-documentation Plug that users `forward` to, so the change is wire-visible for them
(2025-03-26 → 2025-11-25) with zero test coverage to catch fallout. **Recommendation:** in rc.5,
document it as an example (Track F) and point users at `Arbor.MCP.HttpPlug`; change or delete the
canned response during the modern migration.

### 5.4 `request_processor.ex` L119 default `"2025-06-18"` — **defer / needs care**

A client that omits `protocolVersion` today gets `"2025-06-18"` echoed back and its session
gated to that version's method set. Changing the default to latest changes both. No test covers
the omitted-field path. **Recommendation:** Track 0 adds the missing test pinning current
behavior; the change itself ships with modern support, where era detection replaces this path.

### 5.5 `FeatureFlags` ↔ `VersionRegistry` `tasks` reconciliation — **defer to the modern migration**

**Resolved in the 2026-07-28 migration Phase 0:** 2025-11-25 continues to advertise `tasks`
unconditionally, including through the canonical initialize builder. Modern task negotiation
will move to `capabilities.extensions` in Phase 8.

`VersionRegistry` L117 advertises `tasks: %{}` **unconditionally** for 2025-11-25 and never
consults `FeatureFlags`. Making it honour `FeatureFlags.enabled?(:tasks)` would — because
`tasks_enabled` is unset by default — **drop the `tasks` capability from every 2025-11-25
initialize response**. That is a wire-visible regression for anyone relying on it, and
`compliance/tasks_test.exs` L183-192 asserts the unconditional behavior today.

2026-07-28 replaces the whole mechanism with extension negotiation
(`capabilities.extensions["io.modelcontextprotocol/tasks"]`), so this resolves in the modern path.
**rc.5-safe subset:** the docs/config fixes in Track F only.

### 5.6 Routing `handle_url_elicitation/3` — **decided: fix in rc.5**

Promoted out of Deferred. See **Track G** (§4.7).

### 5.7 `Arbor.MCP.Server.Tools` removal — **move the removal target to 2.0.0**

Nothing in `lib/` uses it, but removal is by definition breaking. The existing `CLAUDE.md` and
`README.md` promise of removal in 1.1.0 would violate SemVer after stable 1.0. Keep it for all
1.x releases, change the notices to 2.0.0 before 1.0 ships, and remove it only in ArborMCP 2.0.

### 5.8 Consolidating the five `initialize` implementations — **defer, sequence before modern support**

`request_processor.ex` L118-144, `message_processor.ex` L283, `server/handler.ex` L300-305 and
L745, `server/dsl.ex` L661, `transport/http_server.ex` L292-298. They disagree on default
version, capability source (`Capabilities` vs `get_capabilities/0` vs `%{}`), and key casing
(string vs atom). Consolidating behind one `build_initialize_result/2` is purely internal but
large, and it interacts directly with §5.3 and §5.4.

**Recommendation:** this is the natural **first commit after rc.5**, not an rc.5 item — the
modern era has to touch all five anyway.

---

## 6. Suggested PR breakdown

| PR | Track | Files touched (approx) | Reviewable? |
|---|---|---|---|
| 1 | 0 | `test/` only, + fixtures | yes — pure additions |
| 2 | E | `test/arbor_mcp/compliance/version_generator.ex`, new handler module | yes — test-only |
| 3 | B (table) | new `protocol/methods.ex` + equality test | yes |
| 4 | B (rewire) | 5 consumers | **largest** — split per consumer if needed |
| 5 | A | `version_negotiator.ex`, `types.ex`, `version_registry.ex` | yes |
| 6 | C | `error_codes.ex`, 3 dedup sites | yes |
| 7 | D | deletions only | yes |
| 8 | F | docs + `config.exs` | yes |
| 9 | G | `client/request_handler.ex`, `client/handler.ex`, elicitation tests | yes — **land last, review as a behavior change** |

---

## 7. Release checklist for `1.0.0-rc.5`

- [x] Track 0 characterization tests pass **unchanged** from the first commit to the last —
      with the single expected exception of the elicitation routing test, updated by Track G.
      Any *other* Track 0 diff means something escaped the gate.
- [x] `mix test.suite ci` green.
- [x] `mix format`, `mix credo`, `mix dialyzer`, `mix sobelow --skip` clean.
- [x] `scripts/conformance.sh` — 39/39 server, 226/226 client, `expected-failures.yml` still
      empty. The `draft-alpha` mode (`@modelcontextprotocol/conformance@0.2.0-alpha.9`) may
      still fail; it is non-gating.
- [x] **Wire-diff check:** capture `initialize` + `tools/list` + `tools/call` traffic for all
      four versions before and after the branch; assert byte-identical. Server→client
      `elicitation/create` traffic is unchanged by Track G — the fix is entirely client-side
      dispatch — so this check should be clean even with G landed.
- [x] **Track G callout:** confirm the CHANGELOG names the elicitation routing change
      explicitly, and that the release notes do not claim "no behavior changes" without
      qualifying it.
- [x] `mix.exs` → `1.0.0-rc.5`; `CHANGELOG.md` entry under **Changed** / **Fixed** /
      **Removed** — with **no** `BREAKING:` prefixes. If any appear, an item escaped the gate.
      Track G belongs under **Fixed**.
- [x] Commit: `chore: bump version to 1.0.0-rc.5`.

Then: add modern support through further release candidates and cut `1.0.0` only after the
modern-preferred release gates pass.
