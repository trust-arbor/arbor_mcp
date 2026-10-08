# ArborMCP → MCP 2026-07-28 Migration Plan

**Status:** Code migration and all 1.0 release gates complete — Phases 0–10 implemented; the rc.8 final-candidate soak and mixed-version rollback drill completed without a release-blocking regression
**Target release:** ArborMCP `1.0.0`, through additional release candidates after `rc.5`
**Spec revision:** [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28), latest stable ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog))
**Current ArborMCP:** `1.0.0` release-preparation tree, wire- and API-compatible with rc.8 plus an internal OAuth callback parser fix; defaults to modern-preferred MCP `2026-07-28` with fallback to `2024-11-05` / `2025-03-26` / `2025-06-18` / `2025-11-25`
**Prerequisite:** [`PRE_2_0_TECH_DEBT_PLAN.md`](./PRE_2_0_TECH_DEBT_PLAN.md) — behavior-preserving cleanup completed in `1.0.0-rc.5` (historical filename retained)
**Author:** living implementation plan
**Last updated:** 2026-08-22

---

## 1. Executive summary

MCP `2026-07-28` is the largest breaking change in the protocol's history. It is not a
feature addition on top of `2025-11-25`; it is a re-founding of the protocol on a
**stateless, per-request** model:

- The `initialize` / `notifications/initialized` handshake is **gone**. Protocol version,
  client identity and client capabilities now ride in `_meta` on *every* request.
- Protocol-level sessions (`Mcp-Session-Id`) are **gone**.
- Server-initiated JSON-RPC requests are **gone**. Sampling, elicitation and roots are now
  returned *inside results* via the new **Multi Round-Trip Requests (MRTR)** pattern and
  fulfilled by the client **retrying the original request**.
- The HTTP `GET` SSE endpoint, SSE resumability (`Last-Event-ID`), `resources/subscribe`,
  `resources/unsubscribe`, `ping`, `logging/setLevel` and `notifications/roots/list_changed`
  are **gone**, replaced by a single long-lived `subscriptions/listen` request.
- Every result now carries a required `resultType` discriminator.
- Tasks moved out of core into the `io.modelcontextprotocol/tasks` **extension**, redesigned.

### Decisions taken

| Decision | Choice | Rationale |
|---|---|---|
| Compatibility | **Dual-era.** Keep `2024-11-05` … `2025-11-25` working; add `2026-07-28`. | ArborMCP already supports every prior revision and users depend on it. The spec explicitly defines a dual-era model and a compatibility matrix. |
| Default version | **Prefer `2026-07-28`, fall back by probe.** | There is no handshake to negotiate in. Clients probe with `server/discover`; servers branch on the shape of the first request. |
| Scope | **Required modern core, applicable authorization requirements, and the Tasks extension.** Client response storage/reuse is deferred to `1.1`; required cache metadata still ships in 1.0. | The complete Tasks implementation passed qualification without extending the RC train. Response storage remains an optional optimization and no-cache is the safe conforming fallback. |
| Release | **`1.0.0` after additional RCs.** Do not publish stable `1.0.0` on the legacy-only architecture. | ArborMCP has not made a stable 1.x API promise yet. Shipping a legacy-only 1.0 would make the first stable release obsolete on arrival and create an immediate 2.0 migration cliff. |
| Public API removals | **None in this migration.** Keep `Arbor.MCP.Server.Tools` and other deprecated public surface throughout 1.x; remove it in 2.0. | The protocol revision does not require unrelated library API removals. The current “removed in 1.1” promise is incompatible with SemVer and must be corrected before 1.0. |
| Deprecated-but-live features | **Keep legacy support** for Roots / Sampling / Logging / HTTP+SSE. | The spec deprecates them with a ≥12-month window. They remain available on applicable legacy paths; modern uses MRTR/per-request logging and does not restore removed methods. |

### Why this belongs in 1.0 rather than 2.0

MCP's protocol version and ArborMCP's package version are different compatibility boundaries.
Supporting a new, breaking MCP wire revision does **not** itself require an ArborMCP major release
when the library remains dual-era and preserves its public Elixir API. Conversely, removing a
public ArborMCP module would require a major release even if the MCP wire protocol did not change.

Release candidates exist to find exactly this kind of pre-stable design change. `rc.5` is tagged,
but no stable `1.0.0` contract exists yet. The least disruptive long-term sequence is therefore:

1. Keep `rc.5` as the published legacy characterization baseline and test oracle (it remains a
   prerelease, not a stable package release).
2. Ship modern support through an additional RC. The implementation and qualification work
   completed before `rc.6`, so that candidate can start directly as modern-preferred while
   retaining explicit opt-in/rollback modes.
3. Release `1.0.0` only after modern-preferred + automatic legacy fallback has soaked in an RC.
4. Preserve all four legacy revisions and deprecated ArborMCP public APIs for the entire 1.x line.
5. Reserve ArborMCP `2.0.0` for deliberate public-API removals and any eventual legacy-protocol
   removal, with separate notice and migration guidance.

Use an explicit mode instead of a boolean flag, with per-client/per-server options overriding
the application default:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
# :prefer_modern | :prefer_legacy | :modern_only | :legacy_only
```

The original plan allowed a `:prefer_legacy` staging RC. All implementation, security,
conformance, and interop gates completed before publication, so `rc.6` is instead the first
migration RC and the modern-preferred soak candidate. Servers are dual-era by default.

The resulting RC train is:

| Candidate | Contents | Default / exit condition |
|---|---|---|
| `rc.6` | All release-scope phases: dual-era dispatch, MRTR, subscriptions, Tasks, modern Streamable HTTP, required cache metadata, auth hardening, docs/API audit, conformance and official-SDK interop | Client `:prefer_modern`; begin the minimum seven-day soak after CI and publication; complete the mixed-cluster rollback drill |
| `rc.7` | Legacy SSE persistence/disconnect lifecycle plus MCP/ACP security hardening | Restart the soak for observable lifecycle/security changes |
| `rc.8` | Credential-free adapter CLI lifecycle evidence, Pi config isolation, behavior-preserving helper deduplication, and slimmer Hex packaging | Repeat every release gate and soak the final candidate artifact |
| `1.0.0` | Same wire, public API, and protocol defaults as the final RC; release metadata plus release-gate correctness fixes only | Every gate in Phase 10 passes |

`1.0.0-rc.7` persists legacy SSE events before delivery, retains sessions
across connection gaps, and replays from `Last-Event-ID`, plus ACP and
2026-08-12 security harden work. `1.0.0-rc.8` preserves that behavior while
adding real adapter lifecycle evidence, isolating Pi config, consolidating
internal safety helpers, and trimming repository-only documents from Hex.
See [`RELEASE_1_0_0_RC_8.md`](./RELEASE_1_0_0_RC_8.md).

If a gate misses, add another RC; do not move unfinished core work into stable `1.0.0` merely
to preserve the illustrative numbering.

### Scope boundary for 1.0

The 1.0 release gate includes the modern core wire model, dual-era negotiation, MRTR,
subscriptions, Tasks, Streamable HTTP changes, required result/cache fields, schema behavior,
and the authorization requirements that apply to enabled auth flows. All of that implementation
is complete in rc.6. Only actual client response storage/reuse is deferred: emitting and parsing
the required cache metadata ships in 1.0, while no-cache remains the safe conforming fallback.

Within Phase 7, OTel propagation and actual response storage are optional. Required for 1.0 are
the cache fields on the wire, per-request logging rules, deterministic tool ordering, and the
new JSON Schema acceptance/resource-safety behavior. Within Phase 9, every normative item is a
release gate when authorization support is enabled; deployments that disable authorization do
not bypass the auth test matrix for the library itself.

### Effort shape

Rough order of magnitude, based on the current codebase (~66k LOC `lib/`, ~73k LOC `test/`,
of which ~17.6k LOC is ACP and out of scope):

| Phase | Area | Relative size |
|---|---|---|
| 0 | Foundations — **mostly split out to [`PRE_2_0_TECH_DEBT_PLAN.md`](./PRE_2_0_TECH_DEBT_PLAN.md) (rc.5)**; what remains is the `initialize` consolidation and the wire-visible fixes rc.5 couldn't take | S (was M) |
| 1 | Types & schema for 2026-07-28 | M |
| 2 | Per-request `_meta`, result envelope, `server/discover` | L |
| 3 | Era detection & dual-era dispatch | L |
| 4 | MRTR (client loop + server return path) | XL |
| 5 | `subscriptions/listen` | L |
| 6 | Streamable HTTP rework | XL |
| 7 | Caching, logging, ordering, JSON Schema, `x-mcp-header` | M |
| 8 | Tasks extension (optional for the 1.0 core gate) | L |
| 9 | Authorization updates | M |
| 10 | Compatibility audit, docs, conformance, release | M |

---

## 2. What actually changed

### 2.1 Method surface

The `ClientRequest` union in the 2026-07-28 `schema.ts` is now exactly:

```text
server/discover · completion/complete · prompts/get · prompts/list
resources/list · resources/templates/list · resources/read
subscriptions/listen · tools/call · tools/list
```

`ClientNotification` is exactly `notifications/cancelled` (stdio only).

| Method | 2025-11-25 | 2026-07-28 |
|---|---|---|
| `initialize` | required | **removed** |
| `notifications/initialized` | required | **removed** |
| `server/discover` | — | **new, servers MUST implement** |
| `ping` | both directions | **removed** |
| `logging/setLevel` | server | **removed** → `_meta["io.modelcontextprotocol/logLevel"]` per request |
| `resources/subscribe` / `unsubscribe` | server | **removed** → `subscriptions/listen` |
| `subscriptions/listen` | — | **new** |
| `notifications/subscriptions/acknowledged` | — | **new** |
| `roots/list` (server→client) | request | **only inside `inputRequests`** |
| `sampling/createMessage` (server→client) | request | **only inside `inputRequests`** |
| `elicitation/create` (server→client) | request | **only inside `inputRequests`** |
| `notifications/roots/list_changed` | client→server | **removed** |
| `notifications/elicitation/complete` | server | **removed** (added in 2025-11-25, gone again) |
| `tasks/list`, `tasks/result` | core (experimental) | **removed** |
| `tasks/get`, `tasks/cancel` | core (experimental) | **moved to extension**, redesigned |
| `tasks/update` | — | **new** (extension) |
| `notifications/tasks` | — | **new** (extension, via `subscriptions/listen`) |

### 2.2 Per-request `_meta`

```jsonc
"params": {
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",   // REQUIRED
    "io.modelcontextprotocol/clientCapabilities": { },          // REQUIRED (may be {})
    "io.modelcontextprotocol/clientInfo": { "name": "...", "version": "..." }, // SHOULD
    "io.modelcontextprotocol/logLevel": "info",                 // optional, opt-in to logs
    "progressToken": "...",                                     // optional (unchanged)
    "traceparent": "...", "tracestate": "...", "baggage": "..." // OTel, optional
  }
}
```

- Missing a required field ⇒ `-32602` (`Invalid params`); on HTTP, `400`.
- Server needs a capability the client didn't declare ⇒ `MissingRequiredClientCapabilityError`
  `-32021` with `data.requiredCapabilities`.
- Results **SHOULD** carry `_meta["io.modelcontextprotocol/serverInfo"]`.
- Notifications on a listen stream **MUST** carry `_meta["io.modelcontextprotocol/subscriptionId"]`.

### 2.3 Result envelope

Every result gains a required `resultType`:

- `"complete"` — ordinary result.
- `"input_required"` — MRTR interim result (`InputRequiredResult`).
- `"task"` — tasks extension `CreateTaskResult`.
- Extensions MAY add more; unrecognised values MUST be treated as invalid.
- **Absent on a legacy connection ⇒ treat as `"complete"`** for backward compatibility.
  Absent on a modern connection is an invalid response because `resultType` is required.
  Extension-defined values are accepted only when the corresponding extension was negotiated.

`CacheableResult` adds `ttlMs` (integer ms, ≥ 0) and `cacheScope` (`"public"` | `"private"`),
**required** on `resultType: "complete"` results of `tools/list`, `prompts/list`,
`resources/list`, `resources/templates/list`, and `resources/read`.

### 2.4 Error codes

| Code | Name | Notes |
|---|---|---|
| `-32020` | `HeaderMismatch` | was `-32001` in draft |
| `-32021` | `MissingRequiredClientCapability` | was `-32003` in draft |
| `-32022` | `UnsupportedProtocolVersion` | was `-32004` in draft; `data: {supported, requested}` |
| `-32602` | resource not found | **was `-32002`**; clients SHOULD still accept `-32002` from legacy servers |
| `-32042` | (URL elicitation required) | **retired**, MUST NOT be emitted |

Allocation policy: `-32000..-32019` legacy/implementation-defined (do not allocate new);
`-32020..-32099` reserved for the spec.

### 2.5 Transport

**Streamable HTTP**: POST-only endpoint. No session header, no GET stream, no DELETE, no
`Last-Event-ID`. New required headers on every POST: `MCP-Protocol-Version`, `Mcp-Method`,
and `Mcp-Name` (for `tools/call` / `resources/read` / `prompts/get`). Optional
`Mcp-Param-{Name}` headers mirrored from tool params annotated with `x-mcp-header`. Servers
MUST validate header↔body agreement and reject mismatches with `400` + `-32020`. Unknown
method ⇒ `404` + `-32601`. Closing the SSE response stream *is* cancellation. `X-Accel-Buffering: no`
SHOULD be set; SSE comment keep-alives encouraged on listen streams.

**stdio**: unchanged framing. Server MUST NOT write JSON-RPC *requests* to stdout.
Cancellation via `notifications/cancelled`. Backward-compat probe = `server/discover`.

---

## 3. Target architecture for ArborMCP

### 3.1 The "era" concept

Introduce a first-class notion of protocol **era**, threaded everywhere a version is
currently threaded:

```elixir
@type era :: :modern | :legacy
# :modern  => "2026-07-28" and later — per-request _meta, stateless
# :legacy  => "2025-11-25" and earlier — initialize handshake, sessions
```

`Arbor.MCP.Internal.VersionRegistry` becomes the **single** source of truth for
`supported_versions/0`, `latest_version/0`, `era_for/1`, `modern?/1`, `capabilities_for_version/1`,
and `negotiate/2`. Today there are two independent supported-version *lists*
(`VersionRegistry` `@versions`, `VersionNegotiator` `@supported_versions`) plus two more
single-version scalars (`Types`, `config.exs`) — four places that must agree and don't (§4.1).
Collapsing them is Phase 0 and everything else depends on it.

### 3.2 Client shape

```text
Arbor.MCP.Client (GenServer)
├── Arbor.MCP.Client.EraProbe          NEW  — server/discover probe + fallback + cache
├── Arbor.MCP.Client.ConnectionManager  MOD — branches: modern (no handshake) | legacy (initialize)
├── Arbor.MCP.Client.RequestHandler     MOD — injects _meta on every outbound request;
│                                          parses resultType; routes input_required
├── Arbor.MCP.Client.MRTR              NEW  — fulfils inputRequests via Arbor.MCP.Client.Handler
│                                          callbacks, then retries with a fresh id
├── Arbor.MCP.Client.Subscription      NEW  — long-lived subscriptions/listen request
├── Arbor.MCP.Client.Cache             NEW  — optional ttlMs/cacheScope cache, list_changed invalidation
└── Arbor.MCP.Client.Handler            —   behaviour UNCHANGED (big win, see §3.4)
```

`Arbor.MCP.Client.start_link/1` stays synchronous. In the modern era `init/1` performs the era
probe (`server/discover`) instead of the handshake, and populates the existing
`:server_info`, `:server_capabilities`, `:protocol_version` fields from the `DiscoverResult`.
**Public accessors `server_info/1`, `server_capabilities/1`, `protocol_version/1` keep working
unchanged** — this is the main source-compatibility lever for downstream users.

### 3.3 Server shape

```text
Arbor.MCP.Server.Dispatch              MOD — era-aware method table; builds RequestContext
├── Arbor.MCP.Server.RequestContext   NEW  — %{protocol_version, era, client_info,
│                                          client_capabilities, log_level, extensions,
│                                          progress_token, subscription_id,
│                                          principal_id, tenant_id, deadline,
│                                          input_responses, request_state, replay_protection}
├── Arbor.MCP.Server.Discover         NEW  — server/discover result assembly
├── Arbor.MCP.Server.RequestState     NEW  — AEAD sign/verify of MRTR requestState
├── Arbor.MCP.Server.Subscriptions    NEW  — per-listen-request filter registry + fan-out
└── Arbor.MCP.Server.ResultNormalizer  MOD — stamps resultType, serverInfo, ttlMs/cacheScope
```

`RequestContext` is the direct replacement for connection state. It is derived from `_meta`
on each request. In the legacy era it is synthesised from the stored session so internal code
is era-agnostic. Expose it to user code additively through context-aware callback variants or a
scoped accessor; keep existing callback arities and the documented `_meta` argument merge for
the entire 1.x line.

`Arbor.MCP.Server.ResultNormalizer` is already the single shared result shaper across all four
dispatch paths (this consolidation landed in `1.0.0-rc.5`). That makes stamping
`resultType`/`_meta.serverInfo`/`ttlMs`/`cacheScope` a **one-file change** rather than four.
Preserve that property.

### 3.4 MRTR maps onto the existing `Arbor.MCP.Client.Handler` behaviour

This is the most valuable observation in this plan. The 2026-07-28 `inputRequests` values are
*exactly* `ElicitRequest` / `CreateMessageRequest` / `ListRootsRequest` — the same payloads
ArborMCP already handles as server-initiated requests. So:

- `Arbor.MCP.Client.Handler` keeps its `handle_list_roots/1`, `handle_create_message/2`,
  `handle_elicitation_create/3` callbacks **unchanged**.
- `Arbor.MCP.Client.MRTR` iterates the `inputRequests` map, dispatches each entry through the
  same callbacks `Arbor.MCP.Client.RequestHandler` uses today (`request_handler.ex` L431-441),
  collects `inputResponses`, and re-issues the original request with a **new JSON-RPC id**
  plus `inputResponses` and the echoed `requestState`.
- Existing user handler modules (`DefaultHandler`, `CallbackHandler`, `InteractiveHandler`,
  `ElicitationHandler`) continue to work in both eras with no changes.

Two guards are required:

1. **Round-trip cap** (`max_input_rounds`, default e.g. 8) to bound the retry loop, since the
   spec explicitly permits servers to return `input_required` repeatedly.
2. **Capability gate** — never dispatch an `inputRequest` type the client did not declare;
   a server doing so is non-conforming and should surface a protocol error.

Note: `Handler.handle_url_elicitation/3` was declared but never routed — `RequestHandler`
funnelled URL-mode elicitation into `handle_elicitation_create/3` and dropped the `url`. That is
fixed in rc.5 (Track G), so MRTR should **call the fixed dispatcher**, not re-implement routing.

### 3.5 Server-side MRTR return path

Handlers need a way to say "I need input". Proposed additional return tuples, additive to the
existing `{:ok, result, state}` / `{:error, reason, state}`:

```elixir
{:input_required, input_requests :: %{String.t() => map()}, state}
{:input_required, input_requests, request_state :: term(), state}
```

with `request_state` being a bounded, portable value that `Arbor.MCP.Server.RequestState`
serialises through a safe codec + AEAD-seals into the opaque wire string, and unseals + verifies on the retry
(binding principal/tenant, TTL, expected input IDs/round, and a digest of the canonical immutable
original request, per the spec's replay guidance). Handlers receive the verified value back via `RequestContext`. Default key source:
runtime application config. Both return forms require a key ring: when the handler omits
application `request_state`, ArborMCP still emits a minimal sealed envelope containing the expected
input IDs, round and request binding. Validate a configured ring at boot when MRTR is declared;
otherwise fail the first `:input_required` return before emitting a response with an actionable
configuration error.

The default codec should accept JSON-compatible values only. If an Erlang external-term codec
is offered, decoding must use safe mode plus an explicit type/size allowlist; never call an
unrestricted `binary_to_term/1` on state derived from the wire. PIDs, ports, functions and
node-local references are invalid because a retry may land on another node or application version.

On a retry, dispatch must verify/decode `requestState`, validate `inputResponses` against the
previously requested IDs, then place both values in `RequestContext` before invoking the same
method again. Context-aware handlers read them from that context and either return the final
ordinary result or another `{:input_required, ...}` tuple. Legacy callback arities continue
through an adapter; the DSL exposes `input_responses(context)` and `request_state(context)` so
resumption does not depend on raw `_meta` or process-local state.

The DSL gets a matching affordance inside `run/1` / `handle/1` bodies, e.g. a
`Arbor.MCP.Server.DSL.Result.input_required/2` builder alongside `text/1`, `error/1`, `structured/2`.

### 3.6 Subscriptions

`subscriptions/listen` is a *request whose response is an open stream*. Model it as:

- **Client**: `Arbor.MCP.Client.Subscription` — a supervised process owning a long-lived request id,
  delivering notifications to subscriber pids and maintaining a ref-counted desired filter.
  Because a listen request is immutable, a filter change opens a replacement stream, waits for
  its acknowledgment, then cancels the old stream. During overlap, correlate by subscription ID
  and suppress duplicate/out-of-filter delivery. `subscribe_resource/2` and
  `unsubscribe_resource/2` are sugar over this replacement flow in modern and fall back to
  `resources/subscribe` / `unsubscribe` in legacy.
- **Server**: `Arbor.MCP.Server.Subscriptions` — adapter-backed registry of
  `{subscription_id, transport_ref, honoured_filter, principal_id, tenant_id, expires_at}`
  (ETS locally, PubSub fan-out in a cluster). Replaces `Arbor.MCP.Server.SSESession`'s
  server→client request correlation (which MRTR makes unnecessary) with pure notification
  fan-out. Existing `Protocol.encode_tools_changed/0` et al. get a `subscriptionId` stamped in
  `_meta` on the way out.
- On HTTP the listen response is a chunked `text/event-stream` that stays open; on stdio all
  listen streams are multiplexed on stdout and demultiplexed by `subscriptionId`.
- Graceful closure: server sends the empty `SubscriptionsListenResult` (with
  `_meta.subscriptionId`) before closing.

### 3.7 What disappears from the codebase in the modern path

These stay for the legacy path but must be **bypassed entirely** when `era == :modern`:

- `Arbor.MCP.SessionManager` event buffering / `replay_events_after/2,3`
- `Arbor.MCP.HttpPlug.SessionRegistry`, `get_or_create_session_id/1`, `validate_session_id_value/1`
- `Arbor.MCP.HttpPlug.SSEHandler` `Last-Event-ID` extraction + replay (L127/L152/L310)
- `Arbor.MCP.Transport.HTTP` `:session_id`, `:last_event_id`, `terminate_session/1`,
  `maybe_update_session_id/2`
- `Arbor.MCP.Server.SSESession` server→client request correlation
- `Protocol.encode_ping/0`, `encode_pong/1`, `encode_set_log_level/1`,
  `encode_subscribe_resource/1`, `encode_unsubscribe_resource/1`, `encode_roots_changed/0`,
  `encode_elicitation_complete_notification/1`

---

## 4. Gap analysis by subsystem

### 4.1 Version handling — **rc.5 foundations landed; modern status remains**

| Location | Problem |
|---|---|
| `lib/arbor_mcp/internal/version_registry.ex` | Canonical supported-version list and era helpers landed in rc.5; it still needs known/supported/preferred status for staged modern rollout |
| `lib/arbor_mcp/protocol/version_negotiator.ex` | Version lists delegate to the registry; legacy `build_capabilities/1` is now a deprecated compatibility shim over the same canonical capability vocabulary |
| `lib/arbor_mcp/types.ex` | `latest_protocol_version/0` remains a legacy compatibility accessor; the moduledoc now distinguishes shared legacy types from the MCP 2026-07-28 wire surface |
| `config/config.exs` L8 | Legacy preferred scalar remains `protocol_version: "2025-11-25"`; introduce `protocol_mode` without changing this default prematurely |
| `lib/arbor_mcp/protocol/methods.ex` | Single method table landed in rc.5; modern-only methods are now bounded to the staged `"2026-07-28"` version rather than a phantom `"draft"` |
| `lib/arbor_mcp/transport/http_server.ex` | Canned initialize now uses the shared version-aware result builder |
| `lib/arbor_mcp/protocol/request_processor.ex` | Missing versions now use the validated registry preference |
| `lib/arbor_mcp/plugs/protocol_version.ex` | Gated behind `FeatureFlags.enabled?(:protocol_version_header)`, **off by default** — must be always-on for modern |

**Action:** build on the rc.5 registry/method table rather than repeating that cleanup. Add
staged version status and protocol-mode selection, decide whether to deprecate the unused legacy
capability builder, and replace remaining literal defaults with era-aware policy.

### 4.2 Initialize handshake — four implementations

| Path | Location |
|---|---|
| Handler servers / stdio | `Arbor.MCP.Server.Dispatch.do_dispatch("initialize", …)` L115-117 |
| DSL servers | `Arbor.MCP.Protocol.RequestProcessor.process_initialize/2` L96-144 |
| HTTP | `Arbor.MCP.MessageProcessor.MethodHandlers.handle_initialize/5` L21-26 |
| HTTP transport helper | `Arbor.MCP.Transport.HTTPServer` L292-298 (canned, hardcoded version at L295) |

Plus `HandlerServer.process_mcp_request` L640, `StdioServer.handle_request` L174,
`Testing.MockServer` L344/L448. `notifications/initialized` is handled in `RequestProcessor`
L363-366 and `MockServer` L448 only; `Dispatch` silently ignores it.

**Action:** all four keep their legacy `initialize` branch, and all four gain a modern branch
that never sees `initialize`. `server/discover` should be implemented **once** in
`Arbor.MCP.Server.Discover` and wired into all four tables.

### 4.3 Error codes — canonical module landed; one collision remains

`lib/arbor_mcp/protocol/error_codes.ex` now distinguishes emission from compatibility decoding.
Resource-not-found emits `-32002` for legacy and `-32602` for modern, while unknown-era client
classification accepts either. ArborMCP-local consent and prompt errors use `-31002` and `-31003`,
outside `-32768..-32000`. The historical `-32042` constructor is legacy-only and deprecated;
selecting it for a modern version returns `{:error, :retired_error_code}`.

### 4.4 Client

| Concern | Current | Needed |
|---|---|---|
| Handshake | `ConnectionManager.do_handshake/3` → `send_initialize_request` → `send_initialized` | Era probe via `server/discover`; no handshake in modern |
| Outbound `_meta` | `Arbor.MCP.Internal.RequestParams` — `with_meta/2` L38, `with_non_empty_meta/2` L43, `with_opts_meta/2` L50, `with_progress_or_meta/2` L73-79. Only progress + user meta | Must inject protocolVersion + clientCapabilities on **every** request; add clientInfo, logLevel |
| Result parsing | No `resultType` awareness | Discriminate `complete` / `input_required` / negotiated extension values; absence means complete only on legacy |
| Server→client requests | `RequestHandler` L431-441 dispatch table (`ping`, `roots/list`, `sampling/createMessage`, `elicitation/create`) | Keep for legacy; add MRTR path for modern |
| Health check | idle `ping`; interval `health_check_interval: 30_000` default at `client.ex` L743, scheduled L1410/L1459, sent by `RequestHandler.send_ping/1` L180-187 | `ping` is gone — use an uncached `server/discover` liveness request in modern and keep `Client.ping/2` as a wrapper |
| Subscriptions | `Client.subscribe_resource/2` → `Operations.Resources` L79 | Re-implement over `subscriptions/listen` |
| Caching | none | Parse/validate `ttlMs`/`cacheScope`; optional cache + `list_changed` invalidation |
| Auto-reconnect | exists, backoff + jitter | Must re-establish `subscriptions/listen` streams after reconnect (spec: server holds no state) |
| `x-mcp-header` | none | Client mirrors valid listed annotations into `Mcp-Param-*`; server validates annotations and excludes invalid tools from `tools/list` |

### 4.5 Server

| Concern | Current | Needed |
|---|---|---|
| Request context | Session-derived; `_meta` merged into tool args by `Dispatch.tool_arguments/1` L106-113 | Explicit internal `RequestContext` from `_meta`; additive context-aware user API with old callback arities retained |
| `server/discover` | Method name is staged at `"2026-07-28"`; no dispatcher or handler exists yet | MUST implement |
| Result envelope | `ResultNormalizer` — no `resultType` | Stamp `resultType`, `_meta.serverInfo`, `ttlMs`, `cacheScope` |
| MRTR | Server→client requests via `HandlerServer` (L358 roots, L384-395 sampling) and `SSESession.send_request/3` | New `{:input_required, …}` handler return + `RequestState` sealing |
| Subscriptions | `Dispatch` L163-171 → `handle_subscribe_resource/2`; no subscriber registry (handler's job) | `subscriptions/listen` + `Subscriptions` registry + acknowledgment notification |
| Logging | `logging/setLevel` via `Dispatch.set_log_level/2` L244-264 (succeeds even without the callback) | Per-request `logLevel`; MUST NOT emit `notifications/message` when absent |
| Deterministic tool order | not guaranteed | SHOULD return `tools/list` in stable order |
| Capabilities | The legacy 2025-11-25 wire path advertises `tasks` unconditionally; the independent negotiator vocabulary is retired | Keep the legacy behavior; add an `extensions` map to both client and server modern capabilities |

### 4.6 Streamable HTTP

`lib/arbor_mcp/transport/http.ex` (1382 LOC) and `lib/arbor_mcp/http_plug.ex` (1081 LOC) are the two
largest single changes.

Client transport removals for modern: `@session_header` L149, `:session_id`, `:last_event_id`,
`:sse_deferred_attempted`, `maybe_update_session_id/2` L1086-1092,
`maybe_start_deferred_sse/1` L1093-1125, `Last-Event-ID` on the GET SSE start
(`start_sse/1` L1158-1163) **and on every POST** (`build_request_headers/1` L1254, header at
L1278-1283), `terminate_session/1` L1011-1045. Note `trigger_sse_reconnect/1` L1130-1146 does
not itself set `Last-Event-ID`. Additions: required headers, header/body validation on the
response side, `-32020` handling, `400`-body inspection for era detection, `404` + `-32601`
for unknown methods.

Server plug: `do_dispatch/4` L153-262 has 14 clauses, including `GET /sse`, `GET /mcp/v1/sse`,
`DELETE /sse/:id`, `DELETE /mcp/v1/sse/:id` (L224), `DELETE *`, and a `GET *` SSE catch-all.
In a modern-only configuration these must return `405`; in dual-era they stay for
legacy clients but a modern request must never mint or echo `mcp-session-id` (currently echoed
at L319, 334, 356, 379, 396, 423, 433, 450). `handle_session_delete/3` L514-567 and
`handle_sse_connection/2` L570-645 become legacy-only. New: `Mcp-Method` / `Mcp-Name` /
`Mcp-Param-*` validation including the `=?base64?…?=` sentinel decoding, and
`X-Accel-Buffering: no` on SSE responses.

`Arbor.MCP.Plugs.ProtocolVersion` must become unconditional for modern requests (currently behind
a default-off feature flag).

### 4.7 Tasks

Existing: `tasks/get`, `tasks/list`, `tasks/result`, `tasks/cancel`,
`notifications/tasks/status`, `Arbor.MCP.Tasks.Task` struct (`lib/arbor_mcp/tasks/task.ex`), DSL
`execution` instruction, `taskSupport` in `Types.V20251125`. Notably the `tools/call`
task-augmentation path was **never implemented** — nothing reads a `task` field or returns a
`CreateTaskResult`.

New extension shape:

| Old | New |
|---|---|
| `tasks/list` | **removed** |
| `tasks/result` (blocking) | **removed** — poll `tasks/get` |
| `tasks/get` | kept; returns full task incl. `result` / `error` / `inputRequests` |
| `tasks/cancel` | kept; cooperative |
| — | `tasks/update` — client submits `inputResponses` for a task in `input_required` |
| `notifications/tasks/status` | `notifications/tasks`, opted into via `subscriptions/listen` |
| per-request opt-in (`taskSupport`, tool `execution`) | **removed** — server-directed; client opts in once via the extension capability |
| `ttl` / `poll_interval` (struct, L37-38 & L49-50) emitted as `"ttl"` / `"pollInterval"` (wire, `to_map/1` L172-173) | Modern wire emits `"ttlMs"` / `"pollIntervalMs"`; retain the old public fields as 1.x aliases or use a separate extension struct |
| — | `CreateTaskResult` with `resultType: "task"` |

The existing `Arbor.MCP.Tasks.Task` state machine (`working` / `input_required` / `completed` /
`failed` / `cancelled`) matches the new spec exactly. Reuse the state logic, add
`inputRequests` and `error`, and make serialization era-specific. Do not rename/remove public
rc.5 struct fields in place; retain aliases throughout 1.x or add a separate extension struct.

**Action:** remove the DSL `execution` instruction and `taskSupport` from the modern path
(keep for legacy `2025-11-25`), and finally implement the creation side.

### 4.8 Authorization

`lib/arbor_mcp/authorization/` (6100 LOC, 28 files) needs:

1. **RFC 9207** — authorization servers SHOULD return `iss`; clients **MUST** validate a
   present `iss` against the recorded issuer before redeeming the code.
2. **Client ID Metadata Documents** — new preferred registration mechanism. Client hosts an
   HTTPS JSON doc whose `client_id` equals its own URL. Detect support via
   `client_id_metadata_document_supported` in AS metadata. Priority order:
   pre-registered → CIMD → DCR → prompt user.
3. **`application_type`** — MUST be sent during DCR; `"native"` for desktop/CLI/localhost,
   `"web"` otherwise. Handle registration failures from OIDC redirect-URI constraints.
4. **Issuer-keyed credential storage** — persisted credentials MUST be keyed by issuer, MUST
   NOT be reused across authorization servers, MUST trigger re-registration on AS change.
5. DCR itself is now **deprecated** — keep, mark, document.

### 4.9 Types & schema

`lib/arbor_mcp/types.ex` is 702 LOC of hand-written types, plus four per-version modules totalling
706 LOC (`v20241105` 103, `v20250326` 114, `v20250618` 218, `v20251125` 271) that are
documentation-grade and not used for runtime validation.

**Action:** add `lib/arbor_mcp/types/v20260728.ex`. Given the size of the delta, consider
generating it from the vendored `schema.json` rather than hand-writing — but that is a
nice-to-have, not a blocker. `mix mcp.sync_spec --version 2026-07-28` should land the spec
docs and `schema.ts` / `schema.json` under `docs/mcp-specs/2026-07-28/` on day one.

### 4.10 Testing

248 files / 73k LOC. The compliance suite has a structural problem for this migration:
`test/arbor_mcp/compliance/version_generator.ex` has `@versions ["2024-11-05", "2025-03-26", "2025-06-18"]`
— `2025-11-25` was added as a standalone hand-written file instead. Adding `2026-07-28` needs a
decision: extend the generator (and backfill `2025-11-25` into it), or write another standalone.

**Recommendation:** extend the generator. The 14 `Features.*` modules are the right unit of
reuse, but several of them (roots, sampling, elicitation, logging) describe *server-initiated
request* flows that no longer exist in modern — they need era-conditional variants.

The legacy conformance gate remains pinned to the stable
`@modelcontextprotocol/conformance@0.1.16` harness. The modern gate is now
`scripts/conformance.sh modern`, pinned by default to the first exact-version-aware harness,
`@modelcontextprotocol/conformance@0.2.0-alpha.11`. It runs the complete `all` server and client
suites for `2026-07-28` under Node.js 22+, propagates either suite's exit status, and uses one precompiled Mix
build for the parallel client scenarios. Prefer a stable 2026-07-28-aware harness for release
qualification; if one is still unavailable, use the explicit official-SDK interop fallback in
the Phase 10 gates and disclose the prerelease harness in the release notes.

---

## 5. Phased plan

Dependencies are strict unless noted. Phases 7/8/9 can run in parallel once 6 lands. Phase 10
is gated by the required parts of 7 and 9; Phase 8 gates release only if modern Tasks support is
advertised.

```text
0 ──> 1 ──> 2 ──> 3 ──> 4 ──> 6 ──> 7 ──> 10
                   └──> 5 ──┘   ├──> 9 ─────┘
                                └──> 8 (optional gate)
```

---

### Phase 0 — Foundations

> **Most of this phase has been split out into
> [`PRE_2_0_TECH_DEBT_PLAN.md`](./PRE_2_0_TECH_DEBT_PLAN.md), targeting `1.0.0-rc.5`.**
> It is pre-existing debt, not 2026-07-28 work, and it can ship without any wire change.
> **This phase assumes rc.5 has landed.** If it has not, the debt tracks become Phase 0
> here and the estimates below are wrong.

**Inherited from rc.5** (do not redo): single version registry, single method table
(`Arbor.MCP.Protocol.Methods`), single error-code module with `-32020`/`-32021`/`-32022` defined
additively, `era_for/1` / `modern?/1` helpers, a version-derived compliance test generator,
and characterization tests pinning per-version wire output.

**Remaining Phase 0 work — the parts that genuinely require the protocol migration:**

- [x] `mix mcp.sync_spec --version 2026-07-28` → `docs/mcp-specs/2026-07-28/` (+ `schema.ts`, `schema.json`).
      Verify `dev/arbor_mcp/spec_sync/file_mapper.ex` maps the new pages (`basic/patterns/*`,
      `basic/versioning`, `basic/transports/*`, `server/discover`, `server/utilities/caching`) —
      the 2026-07-28 doc tree was reorganised relative to 2025-11-25 and the mapper will need
      new entries.
- [x] **Consolidate the five `initialize` implementations** behind one
      `build_initialize_result/2` — `request_processor.ex` L118-144, `message_processor.ex` L283,
      `server/handler.ex` L300-305 and L745, `server/dsl.ex` L661,
      `transport/http_server.ex` L292-298. They disagree on default version, capability source
      and key casing. **This is the natural first commit after rc.5** — all five have to
      be touched anyway to add the modern era. (Deferred from rc.5 as §5.8 there.)
- [x] Register `"2026-07-28"` in `VersionRegistry` and have `era_for/1` return `:modern` for it,
      but mark it disabled/experimental until the Phase 2 exit gate. Merely adding the newest
      date must not make `latest_version/0`, `preferred_version/0`, default capabilities, or
      `server/discover` advertise a half-implemented protocol. Promote support and preference in
      separate, reviewable commits aligned with the RC train.
- [x] Fix `RequestProcessor` L119's `"2025-06-18"` default (wire-visible for clients that omit
      `protocolVersion`; rc.5 §5.4 added the pinning test, the modern migration changes the behavior).
- [x] Fix or delete `Transport.HTTPServer` L292-298's canned `initialize` response with its
      hardcoded `"2025-03-26"` (rc.5 §5.3 documented it as an example; the migration changes it).
- [x] Resolve the `-32002` collision: move resource-not-found to `-32602` for modern while
      still *accepting* `-32002` from legacy servers, and move `consent_required` out of the
      reserved sub-range. `prompt_error` now uses a separate application code, and `-32042`
      is rejected for modern emission while its legacy constructor remains decodable. (rc.5 §5.2.)
- [x] Reconcile `FeatureFlags` vs `VersionRegistry` on `tasks` — resolves itself via extension
      negotiation in Phase 8, but the 2025-11-25 path must keep advertising `tasks`
      unconditionally or it is a regression for existing users. (rc.5 §5.5.)
- [x] Decide the fate of `VersionNegotiator.build_capabilities/1` — retain it through 1.x as a
      deprecated compatibility shim over `VersionRegistry.capabilities_for_version/1`. The
      independent experimental vocabulary and its feature-flag-dependent tasks behavior are gone.
      (rc.5 §5.1.)
- [x] ~~Route `Handler.handle_url_elicitation/3`~~ — **shipping in rc.5 as Track G.** Phase 4
      inherits a correct dispatcher; MRTR must reuse it rather than adding a second routing path.

**Exit:** one `initialize` builder; `"2026-07-28"` known as `:modern` but not yet preferred or
advertised; full suite green, legacy versions remain wire-compatible, and intentional default
changes are covered by tests.

---

### Phase 1 — Types

- [x] `lib/arbor_mcp/types/v20260728.ex`: `RequestMetaObject`, `NotificationMetaObject`,
      `ResultMetaObject`, `ResultType`, `CacheableResult`, `DiscoverResult`,
      `InputRequests` / `InputResponses` / `InputRequiredResult`, `SubscriptionFilter`,
      `SubscriptionsListenRequest`/`Result`, `HeaderMismatchError`,
      `UnsupportedProtocolVersionError`, `MissingRequiredClientCapabilityError`.
- [x] Add `extensions` to `client_capabilities` / `server_capabilities` in `Arbor.MCP.Types`.
- [x] Loosen `inputSchema`/`outputSchema` types to any JSON Schema 2020-12, and
      `structuredContent` to any JSON value (currently narrower).
- [x] Numeric schema `minimum`/`maximum`/`default` fields use `number`, not `integer`
      (upstream generator fix).

**Exit:** compiles; `mix dialyzer` clean. Conformance is covered by type-metadata tests in
`test/arbor_mcp/types/v20260728_test.exs`; runtime promotion remains a separate Phase 2 gate.

---

### Phase 2 — Wire plumbing

- [x] `Arbor.MCP.Protocol.Meta` (new): build/parse the `io.modelcontextprotocol/*` `_meta` block;
      enforce the `_meta` key-naming rules (reserved `*.modelcontextprotocol` / `*.mcp` second
      labels); OTel passthrough for `traceparent`/`tracestate`/`baggage`.
- [x] `Arbor.MCP.Internal.RequestParams`: inject required `_meta` on every modern outbound request.
      Single choke point — do **not** scatter this across the ~30 `encode_*` functions.
- [x] `Arbor.MCP.Server.RequestContext` (new) + extraction in `Dispatch`, `RequestProcessor`,
      `MethodHandlers`. Validate required fields → `-32602` / HTTP `400`.
- [x] `Arbor.MCP.Server.ResultNormalizer`: stamp `resultType: "complete"` and
      `_meta["io.modelcontextprotocol/serverInfo"]` on modern results.
- [x] Client: parse `resultType`; absent ⇒ `"complete"` only for a known legacy connection;
      missing on modern or unknown/unnegotiated values ⇒ protocol error.
- [x] `Arbor.MCP.Server.Discover` (new) + wire `server/discover` into all four method tables.
- [x] Client: `server/discover` request + `DiscoverResult` → populate `:server_info`,
      `:server_capabilities`, `:protocol_version`.
- [x] `MissingRequiredClientCapabilityError` emission when a handler needs an undeclared
      capability.
- [x] After the stdio exit tests pass, promote `2026-07-28` from known to supported behind
      explicit `:modern_only` / `:prefer_modern` modes. The application default changes only in
      rc.6, after the complete implementation gates pass, to start the first modern-preferred
      RC soak. A later transport-lifecycle fix may require that soak to restart.

**Exit:** a modern client can call `server/discover` + `tools/list` + `tools/call` against a
modern ArborMCP server over stdio, with no `initialize`.

---

### Phase 3 — Era detection & dual-era dispatch

- [x] `Arbor.MCP.Client.EraProbe` (new):
      - stdio/local/test: send `server/discover` with the preferred modern version.
        `DiscoverResult` ⇒ modern. Recognised modern JSON-RPC error (e.g. `-32022`) ⇒ modern,
        retry with an advertised version. A non-modern JSON-RPC error, or a timeout while the
        child process remains alive, triggers a tentative legacy `initialize` per the spec.
        Process exit/transport failure is a connection failure, not era evidence. Cache legacy
        only after `initialize` succeeds; otherwise surface both probe and initialize diagnostics.
        The fallback MUST NOT be keyed to a single legacy error code.
      - HTTP: attempt a modern request; on `400`, inspect the body — recognised modern error ⇒
        modern; otherwise follow the transport compatibility algorithm and tentatively try
        `initialize`, then optionally HTTP+SSE. Authentication/authorization failures, rate
        limits, redirects and `5xx` responses are not downgrade evidence.
      - Cache the era per stdio child-process identity and canonical full HTTP endpoint plus a
        transport/auth-configuration fingerprint. Never let two paths on one origin share a pin.
        A legacy observation may expire so upgrades are discovered. Persist a successful modern
        observation and never auto-downgrade it; a failed re-probe is diagnostic until an operator
        clears the pin or changes the endpoint/configuration identity.
      - Bound probing with a dedicated short timeout. Era fallback happens only during the
        initial, side-effect-free probe; never reinterpret a failed application request as an
        era change.
      - Settle the era before sending any application request. A client never changes era during
        one connection/process after successful discovery or initialization, even though a
        dual-era server can accept clients of both eras concurrently. Emit telemetry and require
        explicit operator/config action for any previously-modern endpoint to use legacy.
      - Define all modes: `:modern_only` sends modern with no fallback; `:legacy_only` initializes
        directly; `:prefer_modern` probes then falls back as above; `:prefer_legacy` initializes
        first and, on a live-transport protocol failure, runs the modern probe before failing.
        A recognized modern error is a schema-valid modern-specific error/result, not merely any
        `-32602`/`-32601` response.
      - Do not automatically follow redirects for MCP POSTs. An explicit policy may allow a
        bounded same-origin `307`/`308`; never replay bodies, cookies, authorization or
        `Mcp-Param-*` across origin or scheme downgrade. Key pins/caches to the configured/final
        endpoint identity.
- [x] `Arbor.MCP.Client.ConnectionManager`: branch on era. Modern path skips
      `send_initialize_request`/`send_initialized` entirely.
- [x] Server: dual-era selection — a request carrying modern `_meta` is served statelessly;
      an `initialize` request selects legacy semantics scoped to the process (stdio) or session
      (HTTP). Both MAY be served concurrently on one endpoint.
- [x] Modern-only servers SHOULD name their supported versions in the error returned to a
      legacy `initialize` (legacy clients have no fall-forward).
- [x] `UnsupportedProtocolVersionError` emission + client-side retry with a mutually supported
      version.
- [x] Health checks: `ping` no longer exists in modern. Make `:health_check_interval`
      era-aware and use an uncached `server/discover` liveness request in modern. Do not let
      the application response cache satisfy a health check.
- [x] Cover all seven rows of the specification's client/server era compatibility matrix,
      including deterministic modern-only failure against legacy and supported-version
      diagnostics for legacy-only clients against modern servers.

**Exit:** the full 7-row compatibility matrix from the spec is covered by tests.

---

### Phase 4 — MRTR

- [x] `Arbor.MCP.Client.MRTR` (new): on `resultType: "input_required"`, fulfil each `inputRequests`
      entry via the existing `Arbor.MCP.Client.Handler` callbacks, then re-issue the original
      request with a **new id**, `inputResponses`, and the echoed-verbatim `requestState`.
      Never inspect `requestState`. Omit it entirely if the server didn't send one.
- [x] Round-trip cap + telemetry (`[:arbor_mcp, :client, :mrtr, :round]`).
- [x] Carry one overall deadline and cancellation scope across every round. Add limits for the
      number of rounds, `inputRequests` per round, and serialized request/response bytes so a
      peer cannot amplify work indefinitely. A timed-out MRTR scope cancels any in-flight input
      callback task and removes it from client bookkeeping.
- [x] Validate that `inputResponses` keys match requested IDs exactly. Dispatch interactive
      inputs sequentially in deterministic key order by default; allow bounded concurrency only
      when a handler explicitly opts in. Parallel callbacks are capped at 16, receive the same
      handler state, and are rejected if they try to update it.
- [x] Capability gate: refuse to fulfil an `inputRequest` type not declared in this client's
      capabilities; surface a protocol error.
- [x] Reuse the URL-mode elicitation dispatcher fixed in rc.5 Track G — do **not** add a second
      routing path inside `MRTR`.
- [x] Server: `{:input_required, input_requests, state}` / `{:input_required, input_requests,
      request_state, state}` handler returns, honoured on `tools/call`, `resources/read`,
      `prompts/get` **only** (spec forbids elsewhere).
- [x] Always generate a sealed library envelope, even when the handler supplies no application
      state, so a fresh-ID/cross-node retry can validate expected input IDs and round. ArborMCP does
      not use the spec's optional no-`requestState` form for server-produced MRTR results.
- [x] Retry dispatch: parse `inputResponses`, verify/decode `requestState`, validate response IDs,
      and populate `RequestContext.input_responses` / `.request_state` before re-invoking the
      original handler. Add context-aware callback/DSL access while adapting old arities.
- [x] `Arbor.MCP.Server.RequestState` (new): AEAD seal/unseal with a digest of the canonical immutable
      original method/params (excluding retry fields), expected input IDs, round number, protocol
      version, endpoint, capability fingerprint, and principal/tenant. Reject any mismatch.
- [x] Define a versioned, algorithm-tagged sealed-state envelope with key ID, random nonce,
      issued-at/expiry and JTI. Default to AES-256-GCM with a 96-bit random nonce and 128-bit tag;
      set a short configurable maximum TTL and clock-skew allowance. Clustered deployments share
      the runtime key ring; never put secrets or bearer tokens in payloads or config files.
- [x] Key rotation retains decrypt-only old keys for at least maximum token TTL + clock skew,
      supports emergency key-ID revocation, and is atomic across the cluster. Gate release on a
      rolling mixed-version/key rotation test; version the payload codec for rolling upgrades.
      **Complete:** decrypt-only old keys, key-ID revocation, boot validation and the versioned
      JSON codec are covered by a two-node mixed-snapshot rotation test. The documented rollout
      distributes decrypt material cluster-wide before changing `active_key_id`, then waits TTL +
      skew before removal; each node installs a complete snapshot atomically.
- [x] Default to a bounded JSON codec for handler state. Reject node-local values and unsafe
      external terms; cap the sealed token size before allocating/decoding it.
- [x] AEAD integrity does not make a token single-use. Provide a replay-cache adapter keyed by
      JTI and expiring with the token; require it when a resumed handler may cause side effects.
      Otherwise expose explicit at-least-once semantics in `RequestContext`. Atomically consume a
      JTI before dispatch and test concurrent same-request replay separately from cross-request/
      principal replay.
- [x] `Arbor.MCP.Server.DSL.Result.input_required/2` builder.
- [x] Legacy path (server-initiated requests via `HandlerServer` / `SSESession`) stays intact
      and is used only when `era == :legacy`.

**Exit:** an elicitation-driven tool call round-trips end-to-end on stdio; tampered
`requestState` is rejected. The same acceptance test over HTTP moves to Phase 6.

Current acceptance coverage exercises the complete client ↔ server flow over both the in-memory
transport and a literal subprocess stdio connection, plus every server dispatch boundary,
including the HTTP handler-process bridge. The clustered rolling-key work is complete through the
two-node mixed-snapshot rotation test described above.

---

### Phase 5 — Subscriptions

- [x] `Arbor.MCP.Server.Subscriptions` (new): registry of `{subscription_id, honoured_filter,
      transport_ref, principal_id, tenant_id, expires_at}` with no raw credential material.
- [x] Put the registry behind an adapter. The default local adapter may use ETS, but clustered
      HTTP deployments need PubSub-backed fan-out because the process producing a change may not
      own the listen stream. **Complete:** the PubSub adapter composes node-local storage with a
      Phoenix.PubSub-compatible fan-out module. Independent-registry acceptance verifies remote
      delivery, duplicate exclusion, and authorization re-checking at the listener-owning node.
- [x] `subscriptions/listen` handler; emit `notifications/subscriptions/acknowledged` **first**,
      reflecting only the honoured subset of the filter.
- [x] Authorize every requested filter at acknowledgment time and every publication against the
      stored principal/tenant so a fan-out bug cannot cross tenants. Apply per-principal,
      per-tenant and global listener/queue limits in addition to the per-listener bound.
- [x] Stamp `_meta["io.modelcontextprotocol/subscriptionId"]` on every notification on the
      stream. Server MUST NOT send unrequested types.
- [x] Request-scoped notifications (`notifications/progress`, `notifications/message`) continue
      to flow on the **originating request's** stream, never on the listen stream.
- [x] Graceful closure: empty `SubscriptionsListenResult` with `_meta.subscriptionId`.
- [x] Cancellation: HTTP ⇒ closing the SSE stream; stdio ⇒ `notifications/cancelled` on the
      listen request id. Modern HTTP cancellation closes only the owning POST response process;
      chunk failure or process exit removes the registry entry and stops delivery.
- [x] `Arbor.MCP.Client.Subscription` (new) + re-implement `subscribe_resource/2` /
      `unsubscribe_resource/2` on top of it for modern; keep `resources/subscribe` for legacy.
- [x] Implement immutable-filter replacement: ref-count the desired resource set, open and
      acknowledge a replacement listen request, then cancel the old one. Define overlap/gap and
      duplicate-suppression behavior using subscription IDs.
- [x] Auto-reconnect must re-send `subscriptions/listen` — the server holds no state across
      reconnects.
- [x] Because events are not resumable, a reconnected client refetches affected list/resource
      state before declaring the subscription current. Expose a resync-complete event so callers
      do not mistake a newly acknowledged stream for a gap-free continuation.
- [x] SSE comment keep-alives (`:\r\n`) on long-lived listen streams; clients ignore comment
      frames and reset the stream idle timer on every received chunk.
- [x] Bound each listener queue and define slow-consumer behavior: coalesce list-changed events,
      retain only the newest update per resource URI where safe, then close an irrecoverably slow
      stream with telemetry instead of allowing unbounded memory growth.
- [x] Monitor transport owners and remove registrations on disconnect/cancellation. Generate
      unguessable subscription IDs and re-check authorization when establishing a replacement
      stream after reconnect. **The wire ID remains the spec-required client request ID; ArborMCP
      separately generates an unguessable internal registry token.**
- [x] Define long-lived authorization behavior: bind the listener to the authenticated principal,
      close it on credential revocation/expiry when observable, and set a configurable maximum
      stream lifetime so authorization is periodically re-evaluated.

**Exit:** list-changed and resource-updated notifications are delivered over stdio with correct
subscription correlation; reconnect and filter replacement re-establish streams. HTTP acceptance
moves to Phase 6.

Current coverage includes generic and resource-compatibility clients, acknowledgment-first
replacement, correlation/authorization/limit checks, slow-consumer coalescing and closure,
simulated reconnect resynchronization, in-memory transport integration, a literal subprocess
stdio resource-update stream, and a literal Cowboy/httpc POST stream covering acknowledgment,
publication, cancellation, quiet keepalives, abrupt-close reconnect, and resynchronization.
Clustered PubSub fan-out is covered with two independent registries sharing a test bus; Phoenix
deployment configuration and the per-node quota boundary are documented.

---

### Phase 6 — Streamable HTTP rework

- [x] Client transport: remove session/resumability state for modern (see §4.6 for the exact
      line references). Keep the code path for legacy.
- [x] Client: emit `MCP-Protocol-Version` and `Mcp-Method` on every POST; emit `Mcp-Name` only
      for `tools/call`, `resources/read`, and `prompts/get`.
      Base64 sentinel (`=?base64?…?=`) encoding when a value isn't header-safe, **including**
      plain-ASCII values that happen to match the sentinel pattern.
- [x] Client: mirror server-listed `x-mcp-header` params into `Mcp-Param-{Name}`.
      On `-32020` due to missing/mismatched `Mcp-Param-*`, re-fetch `tools/list` and retry once
      only because header mismatch is guaranteed to reject before method dispatch.
- [x] Server: statically validate `x-mcp-header` reachability/names while normalizing
      `tools/list`; **exclude** tools with invalid annotations from the paginated result before
      cursor/cache calculation and log a warning. **Complete:** modern normalization retains a
      defensive filter, while `ResultNormalizer.prepare_tools_list/1` gives raw paginating
      handlers the required filter/stringify/sort operation before they slice or calculate an
      opaque application cursor. DSL lists are unpaginated. Atom- and string-keyed schemas are
      both validated, and regression coverage calculates a page only after invalid removal.
- [x] Server plug: validate header↔body agreement (numeric compare for integers, Base64 decode
      before compare) → `400` + `-32020`. Missing required header ⇒ same.
- [x] Server plug: `404` + `-32601` for unknown methods (distinguishes a modern server from a
      legacy HTTP+SSE `404`).
- [x] Server plug: modern requests never mint/echo `Mcp-Session-Id`; ignore `Last-Event-ID`.
      `GET`/`DELETE` on the MCP endpoint ⇒ `405` in a modern-only configuration.
- [x] `X-Accel-Buffering: no` on SSE responses.
- [x] Ordinary requests carrying `progressToken` or per-request `logLevel` use a request-owned
      SSE response. Only related `notifications/progress` / `notifications/message` events may
      precede exactly one final JSON-RPC response; independent JSON-RPC requests are rejected.
      Client callbacks receive the owning JSON-RPC request id so concurrent log streams remain
      distinguishable.
- [x] Closing the SSE response stream = cancellation; server stops work and sends nothing more.
      This covers `subscriptions/listen` and ordinary request streams: client timeout/manual
      cancellation closes only the owning POST, chunk failure kills its worker, and an owner
      watchdog terminates the temporary handler if the connection disappears.
- [x] `Arbor.MCP.Plugs.ProtocolVersion` unconditional for modern (drop the default-off flag for the
      modern era while retaining the legacy compatibility switch).
- [x] Define ambiguous-delivery semantics before enabling automatic reconnect retries. The
      spec-default policy follows the modern transport requirement and reissues a broken
      in-flight request with a new JSON-RPC id, which is **at-least-once**, not exactly-once.
      Offer a caller-selected `:safe_only` policy that retries discovery/list/read and read-only
      tools but returns `:outcome_unknown` for side-effecting calls. Clearly label this override
      as non-conforming client behavior and reject it in conformance mode. Document that JSON-RPC
      ids do not provide deduplication and recommend application-level idempotency keys for tools.
      **Implemented as `:http_stream_retry`; tools require the caller-owned `:retry_safe`
      attestation because `readOnlyHint` is advisory.**
- [x] Retry only the transport-defined broken in-flight stream condition, at most once by default,
      inside the original overall deadline/cancellation scope and reconnect backoff. Do not retry
      generic HTTP/JSON-RPC failures. A tool's `readOnlyHint` is not a security boundary; safe-only
      retry requires explicit caller policy. Provide a stable application idempotency-key hook.
      **The retry delay is bounded by the original deadline, the second attempt always gets a new
      JSON-RPC id, cancellation/protocol/HTTP errors are excluded, and `call_tool` can inject a
      stable key at a caller-selected argument path before either attempt. The application tool
      remains responsible for schema acceptance and server-side deduplication.**
- [x] Reject duplicate required headers, CR/LF values, oversized names/values and conflicting
      case variants before dispatch. Add reverse-proxy integration tests so header normalization
      or buffering by common proxies cannot silently change protocol behavior. **Complete:** in
      addition to direct validation, literal HTTP requests now cross a front Cowboy connection,
      a normalizing/buffering forwarding hop, and the ArborMCP Cowboy endpoint. The matrix verifies
      valid streaming headers, duplicate/case-conflicting required fields, oversized names and
      values, obsolete folding/injection, and no handler dispatch on rejection. Production-proxy
      preservation/rejection and buffering requirements are documented explicitly.
- [x] Treat every `Mcp-Param-*` value as potentially sensitive. Redact it from Plug/client debug
      logs, telemetry and proxy examples just like `Authorization`; document that operators must
      configure upstream access-log redaction too. **ArborMCP does not attach raw request headers to
      its HTTP logs or telemetry; server regression coverage pins that invariant, and the security
      and configuration guides call out proxy/load-balancer/APM redaction explicitly.**

Current Phase 6 coverage includes pure header encoding/validation, Base64 sentinel edge cases,
`x-mcp-header` reachability/type/name checks, client schema refresh plus exactly-one retry on
`-32020`, server-side custom-header validation before tool dispatch, stateless modern response
behavior, unknown-method `404`, modern-only `GET`/`DELETE` `405`, and the existing legacy HTTP
compatibility suites, plus literal modern HTTP subscription streaming, cancellation, keepalives,
abrupt-close reconnect and resynchronization. Literal ordinary-request coverage verifies ordered
progress/log events, one final response, per-request log opt-in/thresholds, client-side
correlation, and disconnect-driven handler cancellation. Clustered subscription fan-out and the
reverse-proxy boundary matrix are complete. Non-SSE POST recovery and OAuth-aware request-stream
reauthentication are also covered: a live HTTP test drives a POST-owned stream through a 401,
provider refresh, persisted token/provider state and final SSE response, plus a bounded 403
insufficient-scope step-up and stale-stream isolation. The request-stream retry matrix covers
retry-once, safe-only `outcome_unknown`, a fresh
JSON-RPC id, original-deadline enforcement, non-retryable failures and stable idempotency keys.

**Exit:** the modern Streamable HTTP transport subset passes locally and against every available
2026-07-28 harness case for headers, status codes, SSE and cancellation; the Phase 4 MRTR and
Phase 5 subscription acceptances also pass over HTTP. Full protocol
conformance remains a Phase 10 gate after Phases 7 and 9.

---

### Phase 7 — Caching, logging, ordering, schemas

- [x] `ttlMs` + `cacheScope` on `tools/list`, `prompts/list`,
      `resources/list`, `resources/templates/list`, `resources/read`. Never on
      `input_required` results. **Complete results receive safe defaults (`0`, `private`) unless
      the handler supplies valid overrides; non-complete results have cache hints removed.**
- [x] Modern response validation rejects missing/negative `ttlMs` or missing/unknown
      `cacheScope` on cacheable complete results. A valid `ttlMs: 0` means immediately stale.
      **The originating method is retained for asynchronous stdio/SSE responses, so validation
      is transport-independent; structured client responses expose both fields.**
- [x] **1.0 scope decision — client storage/reuse deferred.** A future `Arbor.MCP.Client.Cache` must
      define freshness as `now < t_received + ttlMs`; no background polling;
      `list_changed` notification invalidates immediately;
      MRTR retries (carrying `inputResponses`/`requestState`) **MUST NOT** be cached; per-page
      caching for paginated lists; `private` scope keyed by authorization context. Cache keys
      include endpoint, selected protocol version, method, canonical params/cursor, server
      identity and a non-secret authorization partition — never a raw token. **For 1.0, parsing
      and validation ship but storage/reuse does not. Regression coverage proves a positive public
      TTL still performs a second transport request and separate MRTR operations do not reuse
      `requestState`.**
- [x] **Not applicable to 1.0 because storage is deferred.** If storage ships later, default
      authorized responses to a partition derived from issuer, subject
      or client identity, resource/audience, client ID and granted scopes; share only when the
      server explicitly returns `cacheScope: "public"`. Use monotonic overflow-checked expiry,
      entry/total-byte limits and generation-based invalidation so an older in-flight response
      cannot repopulate the cache after `list_changed`. These remain acceptance requirements for
      the future additive cache feature, not waived requirements.
- [x] Derive the exact cacheable-result method set and required fields from the vendored
      `2026-07-28` schema instead of maintaining another hand-written list. **A schema-sync test
      discovers every result definition requiring `ttlMs` + `cacheScope`, maps it to its request
      method, and pins the runtime validator to that exact set.**
- [x] Server: per-request `logLevel` from `_meta`; **MUST NOT** emit `notifications/message` for
      requests without it. `Arbor.MCP.Server.Context.send_log_message/3` filters below-threshold
      events and uses only the owning request stream. `logging/setLevel` remains legacy-only.
- [x] Deterministic `tools/list` ordering. **Modern results are sorted lexicographically by tool
      name after invalid `x-mcp-header` definitions are removed; legacy handler ordering is
      preserved.**
- [x] JSON Schema: `$ref` MUST NOT auto-dereference network URIs (opt-in only, off by default,
      host allowlist, reject loopback/link-local/private, timeouts, size limits, logging);
      bound composition-keyword depth / subschema count / validation time. Touches
      `Arbor.MCP.Content.SchemaValidator` and `Arbor.MCP.Content.Validation`. **Every content, helper,
      DSL, deprecated-tools, and registry path uses `Arbor.MCP.Content.SchemaPolicy`. The default
      rejects external refs before ExJsonSchema's global resolver; the opt-in resolver requires
      an allowlist and applies bounded, IP-pinned fetching. Schema bytes/depth/object count/
      composition depth and resolve/validation time are bounded in both modes.**
- [x] If network `$ref` is enabled, apply redirect and DNS/IP revalidation on every hop, IPv4/
      IPv6 address-class checks, recursive-fetch/cycle and aggregate-byte/decompression limits,
      and an explicit proxy policy. Cache fetched schemas only inside the same trust partition.
      **Every hop is re-resolved and connected to an approved public IP; mixed DNS answers,
      compressed responses, userinfo, proxies, redirect/reference cycles, and all over-limit
      graphs fail closed. Documents are compilation-local and never enter a persistent/global
      cache, while audit logs hash URI and trust-partition identifiers.**
- [x] OTel `_meta` propagation conventions (`traceparent`, `tracestate`, `baggage`).
      Bound/allowlist baggage keys and total bytes. **Optional for 1.0**; it must not delay the
      modern core release gate. **All client, server, notification, and result metadata paths
      now use one validator. Trace context is syntax- and size-checked; baggage is validated
      before an exact, default-deny allowlist is applied; sanitized values are exposed without
      mutating process-global OpenTelemetry state.**

---

### Phase 8 — Tasks extension

- [x] Extension identifier `io.modelcontextprotocol/tasks` in client + server
      `capabilities.extensions`. **`Arbor.MCP.Tasks.Extension` owns the canonical identifier,
      capability fragment, declaration checks, and result-type negotiation; configured client
      capabilities flow through every request and configured server capabilities flow through
      `server/discover`. The legacy `tasks` capability never enables the extension.**
- [x] `CreateTaskResult` with `resultType: "task"`, returned **unsolicited** from `tools/call`
      (and other supported requests) when the client declared the extension. Server MUST check
      the client declared it first. **`Arbor.MCP.Tasks.Server.create/4` checks the scoped client
      declaration, synchronously creates the task through the configured store, and returns the
      handle only after insertion succeeds. The result envelope and all server transport
      boundaries reject undeclared or malformed task handles, and the client accepts them only
      from its declared capability set.**
- [x] `tasks/get` (poll), `tasks/update` (submit `inputResponses`), `tasks/cancel` (cooperative).
      Remove `tasks/list` and `tasks/result` from the modern table. **The shared method table,
      handler/GenServer bridges, HTTP message processor, DSL request processor, client operations,
      and encoders implement the redesigned surface. `CreateTaskResult` alone uses the extension
      discriminator `resultType: "task"`; `tasks/get`, `tasks/update`, and `tasks/cancel` return
      `resultType: "complete"`, and the client validates the full `tasks/get` state independently
      of that standard discriminator. `tasks/update.inputResponses` explicitly bypasses MRTR retry
      handling. Legacy list/result routing remains version-isolated.**
- [x] `notifications/tasks` carrying full task state, opted into via `subscriptions/listen`.
      **The extension's `notifications.taskIds` filter is bounded, deduplicated, and included
      only when the client declares `io.modelcontextprotocol/tasks`. Store-backed handlers
      authorize each ID against the task's principal/tenant/audience binding before
      acknowledgement; custom task backends must provide a filter authorizer. Durable creates
      and wire-visible transitions publish the complete modern task, queued updates coalesce by
      task ID, HTTP and stdio streams accept the extension notification, malformed client-side
      events are dropped, and reconnect resynchronization polls every acknowledged task before
      queued events are released.**
- [x] `Arbor.MCP.Tasks.Task`: emit modern wire keys `ttlMs` / `pollIntervalMs`; add
      `inputRequests`, `error`. Keep existing public struct fields/accessors as deprecated aliases
      throughout 1.x, or introduce a separate extension struct, so Phase 8 does not silently
      break rc.5 callers. **`to_map/1` retains the legacy representation; era-aware `to_map/2`
      emits only the modern task fields. Existing `ttl`, `poll_interval`, and `result` fields stay
      intact, while the struct adds `input_requests` and `error`; generated IDs now use
      cryptographic randomness.**
- [x] Durable creation before responding; task IDs survive client restarts. **The configurable
      `Arbor.MCP.Tasks.Store` contract covers create/get/input/cancellation/worker transitions and
      requires ownership checks on every operation. The supervised ETS implementation is bounded,
      TTL-aware, atomic on one node, and survives client/connection/worker restarts; deployments
      needing application/node restart recovery configure a persistent implementation.**
- [x] Remove DSL `execution` instruction and `taskSupport` from the modern path (keep for
      `2025-11-25`). **The DSL retains the public instruction for legacy compatibility, while the
      modern `tools/list` normalizer removes `execution` from every emitted tool definition.**
- [x] Retire the always-off `FeatureFlags` `:tasks` gate in favour of extension negotiation.
      **The 1.x API clause remains as an inert `false` result for source compatibility; its
      application configuration was removed, modern support uses the extension declaration, and
      2025-11-25 capability behavior remains version-defined.**

---

### Phase 9 — Authorization

- [x] RFC 9207: validate a present `iss` against the recorded issuer before code redemption.
      **The full authorization-code flow records the exactly discovered issuer in its in-memory
      transaction, parses the callback query as a bounded set of OAuth parameters, and validates
      `state` plus any returned `iss` before constructing the token request. Issuer comparison is
      exact, with no URL normalization; a present `iss` without a recorded issuer is rejected.
      Callback URLs, authorization codes, and state values are not written to logs.**
- [x] Client ID Metadata Documents: HTTPS `client_id` URL with a path component; document
      `client_id` MUST equal the URL; MUST include `client_id`, `client_name`, `redirect_uris`;
      detect `client_id_metadata_document_supported`; optional `private_key_jwt`. **The existing
      `ClientIdMetadata` surface now validates an exact HTTPS, non-root-path identifier, bounded
      document size, required field values, secure redirect URIs, and exact document/client-ID
      equality. It detects only an explicit `true` advertisement and can build/validate inline or
      hosted JWKS metadata. Configured CIMD keys produce RFC 7523 client assertions for both auth
      code and client-credentials token requests, with no downgrade when signing fails.**
- [x] Add explicit client configuration: `{:pre_registered, client_id, secret_ref}`,
      `{:cimd, https_url}`, or `:auto`, plus `application_type: :native | :web`. ArborMCP may provide
      a Plug/helper to serve a CIMD but must not imply that a CLI can magically host HTTPS.
      **`Arbor.MCP.Authorization.RegistrationPolicy` implements these strategies. Secret references
      may be resolved from an environment variable or zero-arity callback at use time; resolver
      failures never expose the secret. Existing `client_id`, `client_secret`, and
      `client_metadata_url` keys remain supported as 1.x compatibility aliases. Documentation
      makes clear that CIMD is a self-hosted HTTPS document.**
- [x] Registration priority: pre-registered → configured CIMD → DCR → prompt/actionable error.
      If the AS supports CIMD but no URL is configured, use DCR only when advertised/allowed;
      never invent a metadata URL or silently weaken registration policy. **Selection is
      deterministic at one tested boundary. The former hard-coded conformance CIMD URL is
      removed; `:auto` uses DCR only with an advertised registration endpoint, otherwise returns
      an actionable configuration error.**
- [x] `application_type` on DCR (`"native"` for desktop/CLI/localhost, `"web"` otherwise) is
      explicit configuration; an inference helper may validate an unambiguous redirect URI but
      must not guess silently. Redirect-URI rejection returns an actionable error; any retry uses
      an explicitly configured URI and never relaxes exact redirect validation. **DCR validation
      and its JSON body require the explicit application type. The built-in local flow also
      requires a stable configured callback port before DCR, preserves structured AS redirect
      rejection details, and performs no weakening retry.**
- [x] Key persisted credentials by issuer; refuse cross-AS reuse; re-register on AS change;
      surface an error on mismatched pre-registered credentials. **A pluggable
      `Arbor.MCP.Authorization.CredentialStore` boundary now validates every returned key and record.
      The full OAuth flow reuses DCR credentials only from the exact discovered-issuer partition,
      persists new registrations and tokens when an adapter is configured, and re-registers when
      that issuer partition misses. Modern pre-registered configuration requires an exact
      `credential_issuer`; legacy-era `client_id` / `client_secret` aliases retain their 1.x
      compatibility behavior, while CIMD remains portable by design.**
- [x] Use standards-defined issuer comparison with no ad hoc trailing-slash/path normalization.
      Partition registrations by issuer + client ID and tokens by issuer + client ID + resource/
      audience + subject/client identity + granted scopes. Migrate old unkeyed entries explicitly;
      never silently attach them to the currently discovered issuer. **`Authorization.Issuer`
      provides one byte-for-byte comparison boundary used by discovery, callbacks, configured
      credentials and storage. Versioned registration keys contain issuer + client ID; token keys
      additionally contain resource, audience, subject/client identity and a sorted granted-scope
      set, never raw tokens. Stored values redact secrets from `Inspect`; unkeyed values return
      `credential_migration_required` and can be rebound only through explicit migration helpers.**
- [x] Preserve OAuth transaction protections across both eras: random single-use `state`, PKCE,
      exact redirect URI, one-time authorization-code redemption, issuer-bound callbacks, and no
      cookies/tokens in logs. Test replay and concurrent callback attempts. **All library-started
      authorization-code flows now register a generated 256-bit state and PKCE transaction in a
      bounded supervised store shared by both protocol eras. State and code are retained only as
      SHA-256 digests; callback validation and exact-redirect redemption use atomic transitions,
      so concurrent attempts have exactly one winner and ambiguous token requests cannot retry a
      redeemed code. Reserved parameter overrides are rejected, issuer comparison remains exact,
      and OAuth log/telemetry boundaries redact tokens, cookies, codes, state, PKCE verifiers,
      authorization values and URL queries/fragments. Replay, mismatch, public-flow concurrency,
      one-time token-request, entropy and log-capture tests cover the boundary.**
- [x] Mark DCR deprecated in docs and `@doc`. **The DCR module and registration entry point now
      identify the 2026-07-28 deprecation and direct new deployments to pre-registration or
      CIMD; configuration docs describe it only as an advertised compatibility fallback.**
- [x] Treat CIMD and authorization-server metadata fetching as SSRF-sensitive: HTTPS only,
      bounded redirects that do not cross origin without policy, DNS/IP revalidation, private/
      loopback/link-local blocking, response size/time limits, and no credential forwarding.
      **`Authorization.MetadataFetcher` is now the single CIMD, PRM, OIDC/RFC 8414 and JWKS
      boundary. It rejects userinfo/fragments and every non-public IPv4/IPv6 answer, fails mixed
      public/private DNS closed, connects to a validated address with the original TLS hostname,
      and repeats resolution and pinning on every hop. Redirects are bounded, cycle-free and
      same-origin unless an exact HTTPS origin is explicitly allowed; allowed destinations are
      still revalidated. Streaming defaults bound time/body bytes, aggregate redirect bytes and
      reject compression. Requests contain only fixed non-secret headers. URL-only custom clients
      are rejected in favor of `get(uri, approved_address, opts)`. Adversarial tests cover private,
      loopback, link-local and mixed answers, rebinding across redirects, downgrade/cross-origin
      redirects, cycles, limits, compression, adapter timeouts, malformed documents and header
      confidentiality.**
- [x] Run an auth matrix covering pre-registered/CIMD/DCR registration, native vs web
      `application_type`, RFC 9207 `iss` present/absent/mismatch, issuer changes, redirect
      rejection, credential partitioning, and every supported legacy/modern HTTP mode.
      **`Authorization.CompatibilityMatrixTest` exercises all three registration strategies,
      native and web DCR, exact RFC 9207 callback issuer outcomes, and every version enabled by
      `:legacy_only`, `:prefer_legacy`, `:prefer_modern`, and `:modern_only`. Each negotiated
      version is propagated through both synchronous HTTP and HTTP+SSE OAuth-provider setup.
      Registration and token keys are varied across every issuer/client/resource/audience/
      subject-or-client-identity/scope partition. Full-flow tests prove authorization-server
      issuer changes force DCR re-registration and that native/web `invalid_redirect_uri`
      responses retain structured details after exactly one attempt, with no application-type or
      redirect weakening. The same suite covers exact pre-registered issuer binding and CIMD
      portability across authorization servers.**

---

### Phase 10 — Compatibility audit, docs, release

- [x] **Do not remove public APIs in this migration.** Keep `Arbor.MCP.Server.Tools` + related
      modules throughout 1.x. Update the current “removed in 1.1.0” notices in `README.md`,
      `CLAUDE.md`, `docs/DSL_GUIDE.md`, `docs/getting-started/MIGRATION.md`, and module docs to
      “removed in 2.0.0”; removal in 1.1 would violate SemVer. **All public documentation,
      HexDocs groups, compile-time warnings, `@deprecated` metadata, rc.5 release notes and the
      changelog now retain `Server.Tools`, `Tools.Simplified` and their companion modules for the
      full 1.x line and target removal in 2.0.0. The audit also found and corrected the same
      premature promise on deprecated public content transformation/sanitization stubs.
      `DeprecationCompatibilityTest` verifies the retained modules remain loadable and checks
      their compiled module docs and deprecation metadata for the 2.0 boundary. The final rc.5
      API-diff gate below remains the authoritative check that no other public surface vanished.**
- [x] HTTP+SSE (2024-11-05) is **decided:** keep it available and clearly deprecated throughout
      1.x, but exclude it from new-server defaults. “Dual-era server by default” means both
      protocol eras on enabled modern transports; it does not auto-enable a deprecated transport.
      **`Arbor.MCP.HttpPlug` and `Arbor.MCP.Server.Transport` now default the standalone transport off.
      `legacy_http_sse: true` is the explicit option; rc.5's `sse_enabled: true` remains a 1.x
      alias. The retained GET endpoint emits the required raw `endpoint` event, its announced
      POST endpoint accepts the session query and returns `202`, and JSON-RPC responses are sent
      as SSE `message` events. Paths are configurable, modern-only mode does not expose them,
      startup warns when the deprecated transport is enabled, and the main server/transport/
      configuration docs distinguish it from modern POST-owned SSE streams. Plug, handshake,
      routing, alias, default-selection and SSE formatting tests cover the compatibility path.**
- [x] Keep Roots/Sampling/Logging; add deprecation notes pointing at the suggested migrations
      (tool params / resource URIs for roots; direct LLM APIs for sampling; stderr or OTel for
      logging). **All representative `Arbor.MCP.Server`, `Arbor.MCP.Client`, request-context and Handler
      behaviour functions/callbacks remain exported throughout 1.x. Their compiled docs now
      identify the MCP 2026-07-28 protocol deprecation and the feature-specific migration path;
      they deliberately do not carry Elixir `@deprecated` metadata because ArborMCP has not
      scheduled these public APIs for removal during 1.x. The README, user guide, configuration
      guide and migration guide distinguish retained wire compatibility from recommended new
      designs. `DeprecationCompatibilityTest` locks the exports, callback surface, migration
      text and absence of premature removal metadata, while the focused Roots/Sampling/Logging
      compatibility suite remains green.**
- [x] Docs: `docs/getting-started/MIGRATION.md` gets an rc.5/legacy → 1.0 dual-era section;
      `docs/ARCHITECTURE.md` gets the era model; `docs/TRANSPORT_GUIDE.md` gets the new HTTP
      shape; `CLAUDE.md` and configuration docs cover all four protocol modes. **The migration
      guide now records the decision to land the wire break before stable 1.0 while preserving
      the public 1.x API, compares both eras, gives a reversible four-mode rollout, and separates
      legacy Streamable HTTP from the deprecated two-endpoint HTTP+SSE transport. The architecture
      guide defines connection pinning, probe/cache/request-context/result-envelope ownership and
      fallback invariants. The transport guide documents stateless POSTs, body-derived routing
      headers, POST-owned request/subscription SSE, MRTR continuation and modern GET/DELETE
      behavior. Configuration and `CLAUDE.md` cover all four modes, defaults, overrides, cache
      controls and contributor rules. The migration guide is now an ExDoc extra; documentation
      regression tests lock the reader-critical claims. `mix docs`, the 5-test documentation
      suite, and 107 focused era, request-context, HTTP Plug, request-stream, subscription and
      header tests pass.**
- [x] `CHANGELOG.md` separates the rc.6 MCP wire changes from ArborMCP public-API compatibility
      and preserves the intended stable 1.0 boundary. The rc.6 package and application default
      started the first modern-preferred soak. The post-rc.6 SSE fix now requires another RC
      and a fresh soak while retaining the same protocol-mode default.
- [x] Green: `mix test.suite ci`, `mix credo`, `mix dialyzer`, `mix sobelow --skip`,
      `scripts/conformance.sh` against a 2026-07-28-aware harness. **Final local evidence on
      2026-08-05: the default selection passed 20 doctests + 34 properties + 2,914 tests;
      compliance passed 591 tests; integration passed 20 doctests + 34 properties + 3,623
      tests; and performance/stress passed 20 doctests + 34 properties + 3,574 tests. Strict
      Credo and Dialyzer passed; Sobelow reported no high/critical findings; pinned conformance
      `0.2.0-alpha.10` passed 112/112 server and 377/377 client checks with zero warnings.**
- [x] Produce an API-diff report against `v1.0.0-rc.5`. Restore every removed public function,
      callback, struct field and return shape or delay stable 1.0; document additive APIs and
      protocol-driven behavior changes, but do not use release notes to waive a public removal.
      **`docs/API_DIFF_RC5_TO_1_0.md` records the rc.8 census versus `v1.0.0-rc.5`: 236 → 303
      modules, 2,288 → 2,763 exports, 93 → 115 callbacks, 363 → 557 struct fields, 485 → 602
      named types, with zero removals in those categories. Every changed typespec was inspected; callback changes are
      supersets, struct/type changes are additive or corrective, and the intentional OAuth
      caller-supplied-state hardening is disclosed as an input-behavior change.**
- [x] Phase 8 shipped rather than being deferred: store-backed handlers automatically advertise
      `io.modelcontextprotocol/tasks` through both handler and HTTP discovery paths, handlers
      without task support do not, and clients advertise it only when explicitly configured. The
      client cache is deferred: required wire metadata is validated but responses are not stored
      or reused; missing or invalid required fields remain protocol errors. Focused regression
      tests pin both sides of this conditional gate.
- [x] Add bounded-cardinality telemetry for selected era/version, probe fallback/downgrade,
      unsupported-version retry, MRTR rounds/failures, subscription reconnect/queue pressure,
      ambiguous reissue, and cache hit/miss (if enabled). Never attach tool arguments,
      `_meta`, `inputResponses`, resource contents, `Mcp-Param-*`, `requestState`, authorization
      data or raw subscription IDs to events/logs. Add operational alerts for downgrade attempts,
      unknown/revoked MRTR key IDs, replay rejection, queue pressure and reconnect churn.
      **Complete:** operational events use bounded phase/reason/method/version classes; response
      cache hit/miss is not applicable because storage is deferred. A focused telemetry matrix
      covers fallback/downgrade, MRTR round/failure/key/replay paths, reconnect/pressure and
      ambiguous reissue while asserting sensitive values are absent. The configuration guide
      documents alert signals and the metadata privacy contract.

**1.0 release gates:**

1. Legacy characterization fixtures for all four existing revisions are byte-for-byte green.
2. The seven-row era compatibility matrix passes on stdio and HTTP, including timeouts and
   downgrade diagnostics.
3. Modern client and server conformance have zero unexplained failures. A stable harness is
   preferred; while the pinned harness remains prerelease, self-conformance plus bidirectional
   stdio and HTTP interop with the official TypeScript SDK v2 implementing `2026-07-28` is
   required, and both pins are disclosed in release notes. **Satisfied locally: the four SDK v2
   lanes pass with `@modelcontextprotocol/client`, `server`, and `node` pinned to `2.0.0`.**
4. Disconnect/ambiguous-retry and MRTR tamper, concurrent replay, expiry, failover and rolling
   key/codec-rotation tests pass.
5. Slow-subscriber, cross-tenant isolation, live authorization revocation, reconnect resync and
   clustered fan-out tests pass with per-principal/global bounds.
6. The Phase 9 auth matrix, OAuth replay protections, MCP redirect-leakage tests, CIMD/schema
   SSRF suites, and credential-store migration tests pass.
7. Modern-preferred has been the default for at least one published RC with no release-blocking
   compatibility regression. `:prefer_legacy` remains a documented rollback switch.
8. No critical/high security findings, no unbounded process/mailbox growth in the subscription
   soak test, and no unresolved public API removals relative to rc.5.
9. A rollback drill succeeds from a mixed-version cluster with active subscriptions and in-flight
   MRTR: operators can select `:legacy_only`, drain/restart safely, reconcile state, and explicitly
   manage persisted modern pins. Rollback must not silently downgrade already-pinned clients.

**Current release status (2026-08-22):** the code and validation work for gates 1–8 is complete.
Gate 3 is satisfied by the pinned prerelease conformance harness plus passing, bidirectional
official TypeScript SDK v2 interop over both stdio and Streamable HTTP. Published `1.0.0-rc.8`
completed the final modern-preferred soak without a release-blocking regression. Stable 1.0 is
wire- and API-compatible with rc.8. Its only production-code delta replaces a test-order-dependent
OAuth callback atom lookup with a closed mapping of the same three supported fields; no protocol
default, wire shape, or public API changes.
Gate 9 passed on 2026-08-22: the automated drill held a modern subscription and paused MRTR
request while a legacy node was live, then closed the subscription, completed MRTR, restarted
legacy-only, reconciled external state, rejected silent modern-pin downgrade, and accepted legacy
only after explicit cache reset. The operator reran the same test with a server compiled from the
exact `v1.0.0-rc.5` tag; it negotiated `2025-11-25` and reported package version `1.0.0-rc.5`.
See `test/arbor_mcp/integration/rollback_drill_test.exs` and `docs/RELEASE_1_0_0.md`.

The rc.6 release note assigns an owner and evidence source for every gate, defines the load-test
workload and regression budget against rc.5, and records the qualifying conformance-harness and
official-SDK pins. The final modern-preferred RC soaks for at least seven calendar days; any
wire-design or public-API change restarts that window. “Release-blocking regression” means a new
unexplained conformance failure, legacy fixture diff, crash/data leak, unbounded resource growth,
or critical/high security issue.

---

## 6. Public API impact

Things downstream users will notice.

| Change | Severity | Mitigation |
|---|---|---|
| `Arbor.MCP.Client.server_info/1`, `server_capabilities/1`, `protocol_version/1` | none | Populated from `DiscoverResult` in modern; same shape |
| `Arbor.MCP.Client.Handler` behaviour | none | MRTR reuses the same callbacks |
| `Arbor.MCP.Client.ping/2` | source-compatible | Legacy sends `ping`; modern performs an uncached `server/discover` liveness request and preserves the public success/error shape |
| `Arbor.MCP.Client.set_log_level/2` | source-compatible | Keep it as a client-wide default that populates per-request `_meta`; add a per-request override |
| `Arbor.MCP.Client.subscribe_resource/2` | source-compatible | Re-implemented over `subscriptions/listen` |
| Server handler return tuples | additive | New `{:input_required, …}` |
| Server handlers receiving `_meta` in tool args | compatible transition | Introduce context-aware callback variants or an accessor additively; keep existing callback arities and `_meta` merging throughout 1.x |
| `Arbor.MCP.Server.Tools` | deprecated, still available | Correct removal target to ArborMCP 2.0; migration to `Arbor.MCP.Server.DSL` remains recommended |
| DSL `execution` instruction | legacy-only in modern mode | Keep the public DSL instruction for 1.x; it affects only the `2025-11-25` wire path |
| Tasks API (`tasks/list`, `tasks/result`) | legacy-only in modern mode | Keep public helpers for legacy; add `tasks/get`/`update`/`cancel` extension helpers without removing old functions in 1.x |
| `Arbor.MCP.SessionManager` | modern: unused | Still exported for legacy; document as legacy-only |

---

## 7. Test strategy

1. **Extend the compliance generator.** Add `2025-11-25` and `2026-07-28` to
   `test/arbor_mcp/compliance/version_generator.ex` `@versions` and write
   `handlers/handler20251125.ex` + `handler20260728.ex`. Make the `Features.*` modules
   era-conditional where the flow changed (roots, sampling, elicitation, logging, transport).
2. **New feature modules** for `Features.Discover`, `Features.MRTR`, `Features.Subscriptions`,
   `Features.Caching`, `Features.RequestHeaders`.
3. **Compatibility-matrix suite** — one test per row of the spec's 7-row matrix
   (modern/legacy/dual-era × modern/legacy), asserting the exact fallback behaviour including
   the *timeout* branch on stdio.
4. **Property tests** for: `_meta` key-name validation, Base64 sentinel round-tripping,
   `ttlMs` freshness arithmetic, MRTR round-trip convergence under a round cap.
5. **Security tests** for `requestState`: tamper detection, wrong principal, expired TTL,
   cross-request replay.
5b. **Fuzz and limit tests** for request `_meta`, sentinel headers, duplicate headers,
   subscription filters, `requestState`, MRTR maps, SSE frames, and pathological JSON Schemas.
6. **No `Process.sleep` for synchronization** — per `CLAUDE.md`, use `assert_receive`,
   monitors, a `ping`-equivalent flush (note: in modern the flush must be a real request such
   as `tools/list`, since `ping` is gone), telemetry assertions, or `wait_until/2`.
7. **External conformance** — `scripts/conformance.sh modern` pins
   `@modelcontextprotocol/conformance@0.2.0-alpha.11`, selects exactly `2026-07-28`, and runs
   both complete suites. The current result is 149/149 server and 387/387 client checks with no
   warnings or expected-failure entries.
7b. **Track the harness to stable.** Keep `CONFORMANCE_ALPHA_VERSION` overridable and replace
   the prerelease pin with a stable 2026-aware release as soon as one is available. Until then,
   retain the official-SDK fallback and disclose the pin in release notes.
8. **Interop** — `test/interop/` keeps the legacy SDK fixtures and separately pins the official
   `@modelcontextprotocol/client`, `server`, and `node` packages at `2.0.0`. Four modern lanes run
   both directions over stdio and Streamable HTTP, pin negotiation to `2026-07-28`, and exercise
   discovery, request context, result envelopes, MRTR, subscriptions, routing headers,
   POST-owned SSE, and stateless session semantics. CI runs each lane in an isolated BEAM VM.
9. **Public API compatibility** — compile and run representative rc.5 client/server modules,
   including `Arbor.MCP.Server.Tools`, old handler callback arities and legacy task helpers.
10. **Chaos/load** — disconnect HTTP responses before/after dispatch, restart stdio servers,
    reconnect subscriptions, exercise slow consumers, and publish changes from a different
    cluster node. Assert bounded mailboxes, cleanup and explicit ambiguous outcomes.

---

## 8. Risks & open questions

| # | Item | Notes |
|---|---|---|
| R1 | **Ecosystem timing.** Most servers and clients in the wild are legacy. | Dual-era is the hedge. Ship modern behind the explicit protocol mode first; flip the default only after pinned official-SDK interop passes. |
| R2 | **Health checks lose `ping`.** ArborMCP's 30s idle ping is load-bearing for auto-reconnect. | Use an uncached `server/discover` as the modern liveness operation and preserve `Client.ping/2` as a compatibility wrapper. |
| R3 | **`requestState` key management.** MRTR security depends on an AEAD key shared by every node that can resume a request. | Version the envelope, support key IDs/rotation, bind principal + request digest + expiry, and fail clearly when a configured MRTR flow cannot decrypt state. |
| R4 | **HTTP plug complexity.** `do_dispatch/4` already has 14 clauses (L153-262); dual-era adds more. | Consider splitting modern vs legacy into separate plug modules behind a router rather than growing `do_dispatch/4`. |
| R5 | **Stateless servers break existing user handlers** that relied on per-connection state. | The spec's answer is explicit server-minted handles as tool arguments (§"Stateful Tools"). Needs a documented migration recipe with an example. |
| R6 | **Conformance harness availability.** The repo pins stable `0.1.16` for legacy and `0.2.0-alpha.11` for the gating 2026-07-28 suites; the modern harness is still prerelease. | Move to a stable modern harness when available. Until then, the four bidirectional stdio/HTTP lanes pinned to official TypeScript SDK v2 `2.0.0` provide the required fallback; disclose both pins in release notes. |
| R7 | **Spec churn.** `2026-07-28` is dated in the near past relative to this plan; errata are likely. | <code>mix mcp.sync_spec</code> has sha256/ETag change detection — run it in CI and alert on drift. |
| R8 | **Scope.** ACP (17.6k LOC) is untouched but shares `_meta` helpers. | Verify no shared-helper regressions when `RequestParams` changes. |
| R9 | **Ambiguous HTTP delivery can duplicate side effects.** A broken response does not reveal whether `tools/call` ran. | The conforming default reissues and is at-least-once. Offer `:safe_only` for callers that prefer `:outcome_unknown`; document application idempotency keys. |
| R10 | **A local ETS subscription registry is insufficient in a cluster.** Producers and stream owners may be on different nodes. | Adapter boundary, PubSub fan-out, owner monitoring, bounded queues and multi-node tests are release-gating for clustered HTTP support. |
| R11 | **Perpetual-RC risk.** Adding the full optional extension/cache work could indefinitely delay 1.0. | Gate 1.0 on modern core and normative auth only; allow Tasks and the cache optimization to move to 1.1 without advertising unsupported capability. |
| Q1 | When does modern become the default? | **Decided:** rc.6 is the first migration RC and defaults to modern-preferred because every implementation and qualification gate completed before publication; the final 1.0 RC and stable 1.0 retain that default. Automatic legacy fallback remains enabled. |
| Q2 | Generate `types/v20260728.ex` from `schema.json`, or hand-write? | **Decided: generate** from the vendored schema, keep the generator in `dev/`, and review the generated diff plus small handwritten ergonomic aliases. |
| Q3 | Keep `Arbor.MCP.SessionManager`'s event buffering at all? | Only legacy uses it. Keep, mark legacy-only, and skip supervising it when configured modern-only. |
| Q4 | Ship `1.0.0` stable on `2025-11-25` before modern support? | **Decided: no.** Keep rc.5 as the legacy baseline, add dual-era `2026-07-28` support in further RCs, then cut stable 1.0. |

---

## 9. Appendix A — modern method table

| Method | Direction | Cacheable | MRTR-capable |
|---|---|---|---|
| `server/discover` | C→S | no | no |
| `tools/list` | C→S | yes | no |
| `tools/call` | C→S | no | **yes** |
| `prompts/list` | C→S | yes | no |
| `prompts/get` | C→S | no | **yes** |
| `resources/list` | C→S | yes | no |
| `resources/templates/list` | C→S | yes | no |
| `resources/read` | C→S | yes | **yes** |
| `completion/complete` | C→S | no | no |
| `subscriptions/listen` | C→S | no | no |
| `notifications/cancelled` | C→S | — | — (stdio only) |
| `notifications/progress` | S→C | — | — (request stream) |
| `notifications/message` | S→C | — | — (request stream, opt-in via `logLevel`) |
| `notifications/subscriptions/acknowledged` | S→C | — | — (listen stream) |
| `notifications/tools/list_changed` | S→C | — | — (listen stream) |
| `notifications/prompts/list_changed` | S→C | — | — (listen stream) |
| `notifications/resources/list_changed` | S→C | — | — (listen stream) |
| `notifications/resources/updated` | S→C | — | — (listen stream) |
| `tasks/get` · `tasks/update` · `tasks/cancel` | C→S | no | — (extension) |
| `notifications/tasks` | S→C | — | — (extension, listen stream) |

## 10. Appendix B — reference links

- Changelog: <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Base protocol / `_meta` / error codes: <https://modelcontextprotocol.io/specification/2026-07-28/basic>
- Versioning & compatibility matrix: <https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning>
- MRTR: <https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr>
- Subscriptions: <https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions>
- Streamable HTTP: <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http>
- stdio: <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio>
- `server/discover`: <https://modelcontextprotocol.io/specification/2026-07-28/server/discover>
- Caching: <https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching>
- Tools (incl. `x-mcp-header`): <https://modelcontextprotocol.io/specification/2026-07-28/server/tools>
- Client registration (CIMD): <https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration>
- Tasks extension: <https://modelcontextprotocol.io/extensions/tasks/overview> · <https://github.com/modelcontextprotocol/ext-tasks>
- Deprecated features registry: <https://modelcontextprotocol.io/specification/2026-07-28/deprecated>
- Feature lifecycle policy: <https://modelcontextprotocol.io/community/feature-lifecycle>
- Schema: `schema/2026-07-28/schema.ts` in `modelcontextprotocol/specification`
