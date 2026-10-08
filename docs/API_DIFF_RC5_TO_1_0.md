# Public API diff: v1.0.0-rc.5 to v1.0.0

This report records the public Elixir API compatibility gate for the MCP
2026-07-28 migration. The comparison is between:

- baseline: `v1.0.0-rc.5` (`a2464c3423ee48ba825402cc2d17be8042f1451a`);
- stable release: `v1.0.0`, with the same public and wire surface as the rc.8
  candidate measured below.

The original BEAM snapshot was taken against the `v1.0.0-rc.6` release
commit. Independent rc.7 and rc.8 censuses (2026-08-13) updated the candidate
totals below. There are zero removals versus rc.5.

> **Stable-release note (2026-08-22):** `1.0.0` preserves the measured rc.8
> public surface. Public deltas after the rc.6 snapshot are summarized in
> [Updates for 1.0.0-rc.7](#updates-for-100-rc7) and
> [Updates for 1.0.0-rc.8](#updates-for-100-rc8).

## Method

The rc.5 tag and the candidate were compiled independently. As a conservative
package-level check, the audit included every BEAM module whose compile source
is under `lib/`, even when the module is hidden from HexDocs. It normalized and
compared:

- module names;
- exported functions and arities, excluding `module_info/*` and `__info__/1`;
- callbacks, via `Code.Typespec.fetch_callbacks/1` and
  `Code.Typespec.spec_to_quoted/2`;
- public and opaque types, via `Code.Typespec.fetch_types/1` and
  `Code.Typespec.type_to_quoted/1`;
- struct field names.

The snapshot totals were:

| Surface | rc.5 | 1.0.0 | Removed |
|---|---:|---:|---:|
| Modules | 236 | 303 | 0 |
| Exported functions | 2,288 | 2,763 | 0 |
| Callbacks | 93 | 115 | 0 |
| Struct fields | 363 | 557 | 0 |
| Types | 485 | 602 | 0 named types |

The type count treats a changed definition as one removed textual row and one
added textual row. Those changes were inspected individually as described
below. Public compatibility characterization tests remain the runtime check for
return shapes and retained deprecated modules; a BEAM snapshot cannot prove
behavioral equivalence by itself.

## Result

No public module, exported function/arity, callback, named type, or struct field
present in rc.5 was removed.

Three existing handler callbacks were widened to admit MRTR input-required
results while preserving every rc.5 return:

- `Arbor.MCP.Server.Handler.handle_call_tool/3`;
- `Arbor.MCP.Server.Handler.handle_get_prompt/3`;
- `Arbor.MCP.Server.Handler.handle_read_resource/2`.

Existing structs only gained fields. The additions on rc.5 structs are:

- `Arbor.MCP.Response`: `resultType`, `ttlMs`, and `cacheScope`;
- `Arbor.MCP.Client`: MRTR and subscription bookkeeping;
- `Arbor.MCP.Tasks.Task`: `error` and `input_requests`;
- `Arbor.MCP.Transport.HTTP`: `protocol_era`, `modern_streams`, and `tool_headers`;
- `Arbor.MCP.Server.HandlerServer`: protocol-era, request-context, MRTR,
  replay-cache, and subscription state;
- `Arbor.MCP.Authorization.Provider.OAuth`: authorization-server issuer, rejected-issuer,
  and granted-scope tracking used to bound migration and scope-step-up retries.

The changed typespec definitions are additive or corrective except for the
OAuth state hardening called out below:

- authorization configuration types add issuer, metadata-fetch, client
  registration, credential-store, protocol-version, and HTTP adapter options;
- capability types add the standard `extensions` map;
- JSON Schema types now admit all map-shaped schemas, including boolean
  schemas where the receiving API supports them;
- `tool_result/0` widens `structuredContent` from string-keyed maps to any JSON
  value, and result/task/transport structs describe their added fields;
- `ClientRegistration.registration_request/0` now declares
  `application_type`, which its rc.5 documentation and runtime validation
  already required.

`OAuthFlow.auth_params/0` no longer advertises caller-supplied `:state`.
`start_authorization_flow/1` now rejects it and generates a high-entropy,
single-use state bound to the transaction store. This is an intentional
security behavior change, not a removed function or return shape. Applications
that supplied `:state` must retain the returned transaction and use its
generated `state_param` instead.

## Additive public API

The candidate adds 67 modules and 475 exports. The main supported additions
are grouped here rather than listing internal plumbing:

- era selection and discovery: `Arbor.MCP.Client.EraProbe`,
  `Arbor.MCP.Client.EraCache`, `Arbor.MCP.Server.Discover`, and
  `Arbor.MCP.Protocol.Initialize`;
- modern request context and envelopes: `Arbor.MCP.Server.RequestContext`,
  `Arbor.MCP.Server.Context`, `Arbor.MCP.Protocol.Meta`,
  `Arbor.MCP.Protocol.ResultEnvelope`, and `Arbor.MCP.Protocol.CacheableResult`;
- MRTR: `Arbor.MCP.Client.MRTR`, `Arbor.MCP.Client.InputDispatcher`,
  `Arbor.MCP.Server.MRTR`, `Arbor.MCP.Server.RequestState`, and replay-cache modules;
- subscriptions: `Arbor.MCP.Client.Subscription`,
  `Arbor.MCP.Server.Subscriptions`, the ETS adapter, and the optional PubSub fanout
  adapter;
- Tasks extension: `Arbor.MCP.Tasks`, `Arbor.MCP.Tasks.Extension`, task operations,
  server dispatch, and store behavior/ETS implementation;
- HTTP 2026 routing: request/tool header modules and modern request-stream
  clients;
- OAuth 2026 security: credential stores, issuer checking, metadata fetchers,
  registration policy, and transaction storage.

Existing modules gain additive entry points such as `Arbor.MCP.Client.discover/2`,
`listen/3`, `get_task/3`, `update_task/4`, and `cancel_task/3`, plus schema
compilation, version-registry, version-aware error, stream-management, MRTR
result helpers, and option-aware OAuth metadata URL validation.

## Protocol-driven behavior changes

These are wire or security changes rather than public Elixir symbol removals:

- modern-preferred connections negotiate MCP 2026-07-28 and use
  `server/discover`, stateless Streamable HTTP routing headers, result
  envelopes, MRTR, and `subscriptions/listen`;
- legacy revisions and deprecated HTTP+SSE remain selectable throughout 1.x;
- Tasks are advertised only when the extension is configured and supported;
- result cache metadata is validated, but ArborMCP 1.0 does not store or reuse
  responses;
- OAuth state is generated and consumed by ArborMCP as described above.

The wire migration is intentionally landing before stable 1.0. These changes
would have required an ArborMCP 2.0 release if 1.0 had already been published;
the retained rc.5 public surface lets existing Elixir applications migrate
without a simultaneous package-API rewrite.

## Release decision

The public-API gate is satisfied on the rc.8 census: there are no unresolved
rc.5 symbol, callback, named-type, struct-field, or return-shape removals.
Stable 1.0 still depends on the conformance, security, interoperability, load,
rollback, and minimum seven-day modern-preferred RC soak gates in the
migration plan.


## Updates for 1.0.0-rc.7

> This section is the public delta for changes that landed after the rc.6
> BEAM snapshot. The table above is the rc.7 census (modules, exports,
> callbacks, struct fields, and named types).

### Additive public API

- `Arbor.MCP.SessionManager.append_event/3` — atomically appends a legacy SSE event
  with a store-owned, monotonically increasing ID. Persist-before-delivery uses
  this entry point so events remain replayable when a write races a disconnect.
  Existing `store_event/2` and `replay_events_after/2,3` remain available.

### Protocol and security behavior (no symbol removals)

These are wire, lifecycle, or configuration-behavior changes rather than removed
Elixir symbols:

- **Server-issued legacy sessions** — Streamable HTTP no longer accepts
  caller-selected session IDs. Sessions are created by initialization, exposed
  only after a successful initialize response, identity-bound for their
  lifetime, initialize-once, and capacity-capped. Streamable GET/POST require a
  successfully initialized session.
- **Duplicate request-ID rejection** — JSON-RPC request IDs are atomically
  claimed per session/process and rejected before dispatch for the bounded
  session lifetime.
- **Subprocess environment isolation** — stdio MCP and ACP adapter subprocesses
  default to `environment_policy: :isolated`. Full inheritance requires an
  explicit `:inherit` opt-in.
- **Outbound network policy options** — public client/server configuration now
  documents and enforces `allowed_private_hosts`, pinned DNS/TLS destination
  checks, and related OAuth metadata fetch bounds. Escape hatches such as
  `legacy_unbound_tokens`, `trusted_hosts`, and Codex `trusted_mcp_servers: :all`
  remain available but are documented as deliberate weakenings.
- **Resource bounds** — session, request-ID, replay-byte, frame, queue, and
  handshake limits are enforced fail-closed with slow-consumer handling.

### Compatibility statement

No rc.5 public module, exported function/arity, callback, named type, or struct
field known from the rc.6 audit was removed for rc.7. Applications that minted
or supplied their own legacy `Mcp-Session-Id` values, or that relied on
disconnect deleting session/replay state, must adopt server-issued sessions and
size TTL/replay bounds as documented in the migration and configuration guides.


## Updates for 1.0.0-rc.7 (API census addendum)

- `Arbor.MCP.ACP.Client.HandlerRunner.session_update/3` is retained as a compatibility
  wrapper over `session_update/5`. The `/3` form applies the same default update
  queue bounds used by `Arbor.MCP.ACP.Client` (`max_update_queue: 32`,
  `max_update_queue_bytes: 8_388_608`) but always returns `:ok`, matching the
  rc.6 contract even when bounded `/5` delivery drops.
- Callers that need explicit bounds and a `:dropped` result should use
  `session_update/5`.

## Updates for 1.0.0-rc.8

The conservative census counts every compiled module whose source is under
`lib/`, including modules hidden from HexDocs. Rc.8 adds the internal
`Arbor.MCP.Internal.Options`, `Arbor.RPC.PortEnvironment`, and
`Arbor.MCP.Internal.WorkspacePath` modules, with seven exports and two named types.

Three additional hidden Pi exports are additive compatibility entry points:

- `Arbor.MCP.ACP.Adapters.Pi.Settings.agent_dir/1`; `agent_dir/0` remains available
  through its default argument;
- `Arbor.MCP.ACP.Adapters.Pi.SlashCommands.load/2`; `load/1` remains available; and
- `Arbor.MCP.ACP.Adapters.Pi.SlashCommands.normalize_input/1`.

No rc.5 or rc.7 module, exported function/arity, callback, named type, or
struct field was removed. The shared internal helpers preserve existing
options, errors, ordering, and wire output. The Pi `:agent_dir` isolation fix
does not change an existing public function or return shape.
