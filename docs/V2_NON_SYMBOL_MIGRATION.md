# V2 behavior and ownership migration

This is the consumer migration record for behavior that an export comparison
cannot establish. It accompanies [the API inventory](./V2_API_MIGRATION.md),
[package ownership](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_PACKAGE_CONTRACT.md) and
[the runtime contract](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_RUNTIME_CONTRACT.md). V2 is still an unpublished
candidate; the final compiled graph, HTTP cutover and RC gates remain open.

## Source checkpoints and evidence boundaries

| Checkpoint | What it establishes |
| --- | --- |
| Frozen supported source `1808c56bd4fc7b000043c2775f61ecced6ed059f` | The unchanged [1.x compiled baseline](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/v2/api_baseline_1_5_plus.json), including hidden symbols. |
| MCP `69b0a39ab889f8b8af19707873c9066614b68cf8`, ACP/RPC `0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb` | Historical 64-entry semantic census. MCP reflection reused `f16660b58d69982ed50b014f22319e16c291b345` and explicitly excluded the later DSL source delta, privacy and ordinary Client overlays. It is not a fresh final build. |
| MCP `111a3c70421206a0d6b96184523ffa1db9d209d6` | Source basis for this document. Stdio authority and subscription-origin followups are present. Source links below describe this checkpoint unless explicitly marked supplementary. |
| Ordinary Client lifetime freeze, combined manifest `4b2707ffc4fe597293b764ccbea3e10420dd6fa49a9fbb72e201ca0820b2d6bf`; integration `289f02138783698205186c2b8294989753e3d2cf` | Separate nineteen-path lifetime and seven-path peer-event patches on `f4d8534` plus the exact scoped-helper prerequisite; 201 affected cases on each supported toolchain, zero failures. The combined Client/guard checkpoint passes 5,048 executed cases plus doctests/properties on both. Final graph comparison remains required. |
| Runtime privacy freeze, manifest `24eeccc6bb017d98a20ef313bf44c9dda86c23e9838b986e9312bda9337e0970`; integration `40f65d14b437c8da1cb1b0ac55f761980ca1fa70` | Thirty-path diagnostics patch plus separate clean stdio-domain retirement correction. Frozen privacy cases: 245/toolchain; combined integration: 248/toolchain, zero failures. It remains supplementary to the original census and does not establish whole-library Client/HTTP diagnostic privacy. |
| Host logging freezes: MCP manifest `4496515f751d22dc946b166e75014ddacc6ce5e1ab5f6dbe5e9ee9299c170050`, ACP manifest `47b9ced480a79726ba64e16a28de66e6db8a26d9d7096f09a94c570db2905d45` | Ten MCP and eight ACP paths remove automatic global logger changes. Canonical MCP passes 46 native stdio cases and 5,052 executed full cases on both supported toolchains; ACP passes 359 core cases on both. ACP integration is `cc8b2078855148f390e899c7122fa56c8275da17`. These do not establish arbitrary host-handler privacy. |
| Mounted Gateway freeze, manifest `2b6fcb4fe34a705993316a555d182d9a93573f6d651a0baf9f56a33b3ca0c9e3` | Twenty-six HTTP POST/request-SSE paths, merged with current privacy, stdio and Client context. A separate topology fixture and native Gateway report correction accompany it. Canonical combined runtime/stdIO/privacy selection passes 329 cases on both. Full HTTP lifecycle cutover remains open. |
| Client diagnostics freeze, manifest `135a1a25ba69ea80315b8a5fc2a1ce146025e49d375d5c4fa1e969b97d0aa8da` | Fourteen Client/HTTP diagnostic paths; canonical affected selection passes 228 cases on both. Exact typed startup errors remain available to callers and trusted host logging; private MRTR callback failure now completes its Task normally. This does not establish arbitrary custom callback report privacy. |
| Retained HTTP session freeze, manifest `f52627b2f5e0976473881f7feb592b454c4121b4bb8fed9c128f3ad96f57e4a4` | Twelve-path addressed legacy GET/replay/DELETE overlay merged with the committed Gateway/Client source. Canonical retained session/wire selection passes 19 cases and broader actual Gateway wire selection passes 40 on each toolchain. Notification-array continuation, subscriptions, cancellation, MRTR, initialization arrays and aliases remain separate gates. |
| Native store/retention freeze, manifest `33a9e5ff434dc8abbaad592930df61dc592cf7f4532332a6e68c52cc72eb3227` | Twenty-two store/retention paths plus a separate two-path running-deadline fixture; canonical pressure selection passes 158 and retained Runtime/Gateway selection passes 329 on each toolchain. Native payload admission and final mutation guards preserve original cutoffs. Default-limit RSS, native write admission and durable filesystem qualification remain open. |

| Mounted HTTP control convergence manifest `59bca49d96ee0dccd7341ae193a2fc9b5ae8cbc9f2dc0f6ae0a0a92795ae12a4` | Accepted legacy notification/init arrays, charged same-lease/trusted-modern cancellation controls and actual MRTR retry/replay; canonical combined23 wire/pure,19 retained-session,43 Gateway wire and332 runtime cases pass both. Merge retains pressure/phase/deadline rules and adds endpoint default fallback; queued/future controls, subscriptions/listeners and finalAPI retirement remain required. |
| Native RPC write admission, ACP `27f5606` | Aggregate count/byte reservation precedes payload copying and Actor enqueue; final native admission checks original producer cutoff and identity. Canonical RPC113 cases pass all three local toolchains and exact-commit Linux CI passes9/9 including archives. Actual32-producer probe admits3/rejects29 and has zero new native writes after cutoff. Native acknowledgement does not prove vendor consumption or child/group cleanup. |

Live migration status also includes the later owned HTTP constructors, finite
shutdown at `cfd4686`, aliases/SDK followups at `ecc4ee9`, and the accepted
HttpPlug startup retirement. Addressed resource tracking and publication are
implemented at `f08c090`: 78 combined cases pass all three toolchains and 14
actual resource/alias wire cases pass both supported toolchains. These do not
change the historical slice counts or establish the final compiled package graph.

The historical census is retained under
`tmp/v2-semantic-census-69b0a39/{SEMANTIC_CENSUS.md,semantic-inventory.json,REVIEW_NOTES.md}`.
The Client and runtime privacy freezes are retained under
`tmp/arbor-mcp-client-lifetime-qa/tmp/ordinary-client-freeze` and
`tmp/arbor-mcp-privacy-qa/tmp/runtime-privacy-freeze-1`. These are development
evidence locations, not files installed by the packages. Do not overwrite the
old census or baseline with results from these overlays.

## Packages, configuration and identifiers

Replace the dependency/application `:ex_mcp` and `ExMCP.*` code references with
the owner below. Update aliases, imports, behaviours, dynamic module references,
child specifications and module-valued configuration too. A GitHub repository
redirect does not rename a Hex package, application or Elixir module.

| Owner | Application and modules |
| --- | --- |
| MCP | `:arbor_mcp`, `Arbor.MCP.*` |
| ACP core and generic adapter contract | `:arbor_acp`, `Arbor.ACP.*` |
| Optional vendor implementations | `:arbor_acp_adapters`, `Arbor.ACP.Adapters.*`; core ACP does not depend on the bundle. |
| Shared framing, environment and child lifecycle | `:arbor_rpc`, `Arbor.RPC.*`; neither protocol package depends on the other. |

Move application keys to their actual owner. OAuth/task/subscription settings
keyed by a module must use the new module as well. Codex's
`:codex_legacy_auth_methods` remains under `:arbor_acp` even though the vendor
implementation lives in the optional bundle. Host `:logger` and `:phoenix`
settings remain host settings. A dependency's `config/config.exs` is not loaded
automatically into its consumer. Package splitting does not broaden security,
trusted-host or protocol defaults. See [application boot](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/application.ex),
[security configuration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/internal/security_config.ex) and
[package declarations](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/mix.exs).

**Preserve wire and storage identities.** Legacy ACP `_meta.ex_mcp`,
`_ex_mcp.pi/*` methods, existing generated IDs and client-information defaults,
`~/.ex_mcp/pi/session-map.json`, OAuth's `:ex_mcp_oauth_credential` key namespace,
`__ex_mcp_sequence__` event fields and legacy storage filenames are unchanged.
Selected ETS/profile/internal-message names and `"ex-mcp-default-logger"`
attachment ID also remain. Do not mechanically replace `ex_mcp` inside peer
data, credential keys or persisted terms. References: [credential keys](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/authorization/credential_store.ex),
[event storage](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/session_manager.ex), [telemetry attachment](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/telemetry.ex),
and [Pi source at the ACP checkpoint](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_acp_adapters/lib/arbor_acp/adapters/pi.ex).

## Runtime identity, callbacks and state

`HandlerServer.start_link/1`, generated DSL startup and `StdioServer.start_link/1`
return the real native Runtime supervisor PID. Its registered name addresses
the root; `:sys.get_state(root)` is supervisor state. Use `Server.call/cast`
and supported control/transport helpers. `Runtime.ref/1` returns an opaque
logical reference; `Runtime.edge/1` is explicit diagnostic access. Raw calls or
payload sends to the root/edge do not become bounded ingress merely because
they once worked against the handler GenServer. See [HandlerServer](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/handler_server.ex),
[Runtime](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime.ex) and [stdio facade](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/stdio_server.ex).

Scheduler owns handler `init/1`, committed state and `terminate/2`. Callbacks run
in supervised tasks, so callback `self()`, process-dictionary context and
worker-owned ETS have invocation lifetime. Links, spawned processes and other
callback-created resources require explicit ownership: do not assume they
persist or are automatically reaped when the callback task exits. Private ETS
created in `init/1` belongs to Scheduler and
cannot be read by callback tasks; protected ETS cannot be written by them.
Keep persistent state explicit or use a properly owned host process. Callback
process-dictionary context is not inherited by arbitrary tasks. Stateful work
is serialized; `execution: :stateless` is explicit and cannot return changed
state. Backend effects are not transactionally rolled back. See
[Scheduler](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/scheduler.ex) and
[callback context](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/callback_context.ex).

Custom `handle_call/3` receives `{original_caller_pid, proxy_reply_tag}`.
Caller-based authorization can retain `elem(from, 0)`; the reply tag is opaque
and must not be retained. Calls return `{:reply, reply, next_state}` and casts
return `{:noreply, next_state}`. Deferred `GenServer.reply/2`, continuations and
stop tuples are unsupported. Early/late proxy replies cannot bypass output
preparation or state commit. See [caller migration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_CALLER_IDENTITY_SLICE.md).

A logical Runtime/ServiceRef follows supported child replacement, never a new
whole root. Test/BEAM edge recovery preserves state and scheduler generation;
execution/service-cohort replacement reinitializes state and retires old work.
Do not cache edge or store PIDs. Test/BEAM has one peer per runtime, so it is not
a multi-session HTTP gateway. Reconnection retires the former peer scope even
when the new peer reuses wire IDs. See [Initialization](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/initialization.ex).

One original initialization cutoff covers configuration, native construction,
owned service registration, handler initialization, edge and readiness. A
custom `:via` module must declare `runtime_name_capabilities/0` with
`%{finite_lookup: 1}` and provide pure, finite `whereis_name/1`: that lookup runs
in the initiating caller before OTP's native constructor timeout and cannot be
preempted by it. Arbitrary blocking lookup implementations are unsupported;
registration and subsequent initialization retain the original cutoff. See
[the native-name contract](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime.ex).
Shutdown has one finite overall budget captured at public stop entry; repeated
stops can tighten but never renew it. Bounded pre-mailbox control and an independent
observer enforce it even if ShutdownGuard stalls. Successful cleanup requires the
authenticated terminal result and observer DOWN; a cutoff without confirmed
cleanup returns `{:error, :shutdown_cleanup_unconfirmed}`, while lost authority
returns `{:error, :shutdown_control_unavailable}`. Registration has a fixed 16,384
proven-owned-PID capacity and reasons have a detached 4 KiB limit. Root/Writer
DOWN alone does not certify entered borrowed IO completion. A genuine replacement
gets one new epoch; a poll/child operation cannot refresh the current budget.
Forced owned cleanup can interrupt termination or persistence hooks. Use the parent
supervisor's child-termination API when restart policy must not restart an
endpoint. Borrowed devices/services/listeners survive. See
[owned startup contracts](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/service_adapter.ex).

## Admission, deadlines, cancellation and output

These current defaults describe managed counters, not measured whole-VM memory
or production capacity. Configure and qualify them for the actual workload.

| Runtime setting | Default and meaning |
| --- | --- |
| `max_concurrency`, `max_queue` | 1 and 128; stateful concurrency must stay 1. Every legacy batch member consumes a work permit, including notifications/invalid members. |
| `max_request_bytes`, `max_pending_bytes` | 1,000,000 and 8,000,000 input bytes; candidates and admitted work share accounting. |
| `max_control_queue`, `max_control_bytes` | 32 and 65,536 **per lane**; incoming reverse responses and outgoing controls are separate, giving twice each configured aggregate limit. |
| `max_output_frame_bytes`, `max_output_term_bytes` | 1,048,576 each; wire frame limit includes the framing newline. |
| `max_output_frames`, `max_output_bytes` | 128 and 4,194,304 shared across candidate/prepared/queued/in-flight output. |
| `request_timeout_ms`, `init_timeout_ms` | 10,000 ms each, absolute per operation/epoch. |
| `output_timeout_ms`, `shutdown_timeout_ms`, `cancel_grace_ms` | 5,000 ms, 5,000 ms and 100 ms; finite timer validation applies, with zero allowed for cancellation grace. |

See [authoritative configuration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/config.ex). Supported
ingress and helpers reserve count/bytes before publishing payloads; coalesced
wakes carry tokens, not request bodies. Overload is explicit `:server_busy`.
Arbitrary raw BEAM sends, consumer mailboxes, handler state, custom effects and
kernel buffers remain outside these counters. See [Admission](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/admission.ex).

`Runtime.request` has one API-entry caller-wait cutoff. An `:await_timeout`
abandons waiting and drops late replies; it does not cancel already accepted
work or prove a mutation failed. A server request deadline includes queue time.
Use `Context.cancelled?/0` and opaque `Context.scope/0` instead of a global bare-ID
tracker. Active cancellation prevents that invocation's state commit and stops
unresponsive work after grace. A completed successful origin stays valid only
through its original cutoff; retired peer/generation invalidates queued controls
independently. Reused IDs cannot revoke an unrelated completed origin.
See [absolute waits](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_ABSOLUTE_WAIT_SLICE.md) and
[subscription source proof](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_SUBSCRIPTION_ORIGIN_SLICE.md).

Protocol output must be valid bounded JSON before state commit. Synchronous
custom replies use a separate bounded term policy, preserving supported PID/ref
terms rather than silently JSON-encoding them. Prepared ownership transfers to
Scheduler before the callback worker exits. Stateful work remains held through
the documented staged/output settlement. Publication failure after commit is
terminal and cannot retry the callback. Legacy batches charge member and
prospective grouped output before each member commit, retain envelope input
through final settlement, and return an explicit whole-envelope error when a
later member/output fails. Earlier sequential effects remain committed.
See [output integration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_OUTPUT_INTEGRATION_SLICE.md).

Mounted legacy HTTP cancellation now covers queued callbacks and future members
of an admitted array, including the gap between members. Wire IDs retain their
types. The accepted receipt keeps the first source/target cutoff; duplicate
controls do not renew it. A live marker fails the whole envelope before the
targeted callback while preserving earlier committed state. Source input stays
charged until Admission actually acknowledges the control; caller timeout alone
does not release it. Initialization IDs remain protected. See
[queued and future controls](./V2_HTTP_FUTURE_CONTROL_SLICE.md).

An ACK has a specific proof boundary:

| Transport/domain | What completion establishes |
| --- | --- |
| Test/BEAM | Native `send/2` returned after local mailbox handoff; consumer processing/mailbox capacity is not proved. |
| Batch member | Staged handoff into a charged output group, not delivery of the final array to the peer. |
| Stdio | Authenticated local IO result **and** physical sender DOWN; runtime/Writer DOWN alone cannot release a borrowed device's retained write. Remote consumption is not proved. |
| HTTP | Borrowed socket-writer liability persists until actual adapter return/socket DOWN. The installed Gateway/output integration has separate qualified checkpoints; neither preparation nor queue admission establishes physical completion. |

Stdio seals input only after the final admitted frame publication, drains
accepted work under original deadlines and one EOF cutoff, then stops owned
children. Reader bounds framing before newline allocation and retains at most
one capped pre-admission frame. In-flight IO timeout is terminal, uncertain and
nonretryable. The retained authority allows 64 output device domains/aliases,
128 control slots and one physical sender/unsettled frame per device. Another
live endpoint on that device returns `:stdio_output_in_use`; unresolved output
blocks replacement. Sticky uncertainty/default-authority loss has no reset API.
Only live local PID/atom or captured standard-IO devices are supported. Clean
idle retirement and final cross-cohort qualification must be distinguished from
uncertain poison retention. See [stdio liability](./V2_STDIO_OUTPUT_LIABILITY.md),
[Reader](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/stdio/reader.ex) and
[OutputAuthority](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/stdio/output_authority.ex).

## Results, schemas, callbacks, types and structs

`Server.Result` is the complete-result implementation; `Server.DSL.Result`
forwards its existing surface. Constructors return complete plain maps, not
content entries. Embedded resources need a URI plus text or blob; media needs
explicit base64/MIME. Modern `structuredContent` supports any JSON value;
legacy results require an object. Omitted values differ from explicit null/false.
Conflicting normalized keys reject before information loss. Unsupported
top-level DSL returns fail safely; nested invalid JSON/oversized output rejects
before state commit. Authored `Result.error` remains an explicit tool failure.
See [Result](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/result.ex) and
[normalization](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/result_normalizer.ex).

SchemaPolicy defaults to draft 2020-12 with opaque JSV compiled artifacts;
explicit supported drafts 4/6/7 retain ExJsonSchema behavior. Unknown dialects
reject. `compile_optional` bypasses only `nil`; boolean `false` compiles and
rejects every instance. Validation does not coerce values or insert defaults;
default 2020-12 `format` is an annotation. Tool descriptor input schemas still
require an object with root `type: "object"`, and output schemas require an
object. Standalone boolean validators do not relax descriptor requirements.
Network references remain disabled unless the bounded allowlisted resolver is
explicitly enabled. See [SchemaPolicy](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/content/schema_policy.ex)
and [dialect migration](./V2_SCHEMA_DIALECT.md).

DSL/default maps add explicit presence information (`has_default`); omitted,
nil and false must be distinguished. Constraints validate before the callback.
Components reuse the same DSL, compiled descriptors and declaring-module
handlers under host state/context; they do not initialize another component
server. Dynamic tools keep descriptors/compiled validation/dispatch in owned
Handler state with an explicit duplicate/replacement policy. No global Tools
Registry or Builder.Tool struct replacement exists. See
[DSL Builder](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/dsl/builder.ex),
[components](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_DSL_COMPONENTS_SLICE.md) and
[dynamic tools migration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_DYNAMIC_TOOLS_MIGRATION_SLICE.md).

Removed media/encoding operations reject before custom pipeline effects.
File-builder `:auto_resize` and `:quality` reject by presence even for false/nil;
supported `:max_size` and `:mime_types` enforce loading policy. Perform media/EXIF
processing in the application, then construct content. Removing a metadata map
never stripped EXIF. See [retirement policies](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_API_RETIREMENTS_SLICE.md).

The historical reflected graph had no missing callbacks, four accepted Tools
types absent, seven retained type definitions changed, and eight existing
structs with additional fields. Those counts do not cover the final overlays.
MCP `Transport.close` now reports errors; ACP optional `shutdown/1` accepts plain
state, `{:ok, state}` or `{:error, reason, state}`, and managed adapters may use
the pure `subprocess_receipt/2` callback. Broad `any()` specs can hide a semantic
result expansion in reflection. Recompile consumers and use owner APIs; a Pi
field named `port` now holds an opaque child handle, and retained field names
do not promise persisted-term/hot-upgrade compatibility. Runtime/ServiceRef,
leases, claims, output tickets and modern schema artifacts are opaque.

| Retained type at the historical checkpoint | Semantic change after namespace normalization |
| --- | --- |
| `Content.Builders.file_opts/0` | Removes `auto_resize` and `quality`; supported size/MIME options remain. |
| `Content.Sanitizer.sanitization_op/0` | Removes named media/metadata operations; an existing broad atom type does not make retired tokens executable. |
| `Content.Transformer.transformation_op/0` | Removes named media/encoding operations; retained text/custom operations remain. |
| `Content.SchemaPolicy.compile_result/0` | Successful value becomes explicit `compiled/0`, including opaque modern artifacts and retained legacy Roots. |
| `Server.DSL.Builder.param/0` | Adds `has_default`; schema permits a plain object or boolean rather than treating nil as a declaration. |
| `Server.HandlerServer.state/0` | Replaces inline `handler_state` with an opaque Runtime reference; Scheduler owns committed handler state. |
| `Transport.Local.t/0` | Adds runtime/connection identities; a server PID alone no longer describes the active transport generation. |

These abbreviated names use `Arbor.MCP.*`. Whitespace-only reflected changes
are excluded from the seven semantic type changes. Fresh final reflection must
still include the later Client, privacy and HTTP source checkpoints.

The eight historical struct additions are recorded here for consumer review,
not as a final field-diff claim after subsequent patches:

| Struct | Added fields at the census checkpoint |
| --- | --- |
| `Arbor.ACP.Adapters.Pi` | `framing`, `port_monitor`, `subprocess_error`; retained `port` now represents an opaque child handle. |
| `Arbor.MCP.Client` | `cleanup_result` |
| `Server.SubscriptionListener` | `runtime_delivery` |
| `Server.Subscriptions` | `publication_mailbox`, `publication_timeout_ms`, `runtime_table` |
| `Testing.MockTransport` | `deadline` |
| `Transport.Local`, `Transport.Test` | `runtime`, `connection` |
| `Transport.Stdio` | `monitor`, `subprocess` |

MCP table names after the first two rows abbreviate `Arbor.MCP.*`. The ordinary
event overlay later adds captured peer context to Test/Local; privacy later
adds diagnostic callbacks. Include those in the fresh final manifest.

Use `transport: :mock` for `Testing.MockServer` and `transport: :test` for a
supported Runtime-backed server. Test cannot silently fall back to an arbitrary
mock GenServer. Mock replies use caller-owned bounded handoff and original
deadline. See [ConnectionManager](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/client/connection_manager.ex)
and [mock implementation](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/testing/mock_server.ex).

## Client, adapter and subprocess ownership

The committed scoped helper accepts a **connection specification**, creates its
own Client and runs the callback in the original calling process. It does not
adopt an existing Client PID or borrowed BEAM server/listener. Its native Client
parent is the construction guardian; ordinary `Client.start_link` keeps its
native caller parent. Establishment and cleanup have separate single cutoffs.
Success is `{:ok, value}`; known cleanup failure preserves reason/value; callback
exceptions/throws/exits re-raise after finite cleanup. See
[connection scope](./V2_CLIENT_CONNECTION_SCOPE.md).

Helper defaults are `establish_timeout: 12_000`, `cleanup_timeout: 1_000` and
`max_scope_workers: 256`; helper names must be local. The ordinary lifetime
freeze separately adds `max_client_workers: 256` (1–4096) and
`client_cleanup_timeout: 1_000` (positive finite OTP-timer range). These are
different ownership domains and options, not interchangeable timeout aliases.

The **separate ordinary lifetime freeze** registers library workers before
effects, bounds reverse/MRTR/resource/HTTP/DNS/receiver work and uses an
independent owner/worker observer. Stop/disconnect/transport loss retire maps
and generation before reconnection; stale PID/ref/epoch completions cannot
change fresh handler state. An acknowledged internal resource Subscription can
transfer into logical Client lifetime for resubscription. Ordinary custom close
runs in a registered cleanup worker, so its `self()` changes; scoped close stays
inline. `stop`/disconnect retain explicit known timeout/cleanup errors. Test/BEAM
adds a constant captured peer event context so already-queued old controls drop
after reconnect; raw non-Client peers keep their legacy tuple. These semantics
are a named supplementary checkpoint, not guarantees inferred from the old census.

ACP AdapterSupport returns an opaque RPC child handle instead of a Port. Capture
the intended persistent local owner before opening from a temporary task.
Use public event/identity/monitor/write/ACK/receipt helpers. Managed adapter ACK
follows bounded Bridge outbox admission, including skipped/partial translation;
translation cannot prematurely grant another frame credit. Close and shutdown
retain known cleanup failures. Environment policy remains generic isolation,
then vendor defaults and explicit caller overrides; effective child PATH/CD
decides executable lookup. See [adapter support source](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_acp/lib/arbor_acp/adapter_support/subprocess.ex)
and [Adapter behaviour](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_acp/lib/arbor_acp/adapter.ex).

Guardian owns the actual helper Port from launch; the native helper remains the
vendor's OS parent. Vendor status, helper status, final bytes/EOF and cleanup
completion are distinct. Typed receipts separately report direct-child reaping
and targeted-group absence, with five-second retained observation. Receipt
loss/expiry is unconfirmed, and Actor/Client DOWN never substitutes for a receipt.
No TERM/KILL occurs after owned-leader reaping and no numeric-PID fallback exists.
Escaped groups/arbitrary descendant trees are not contained. Pull reads retain
the original absolute cutoff; push events carry generation/token and explicit
ACK. Native data credit bounds one 16 KiB chunk plus reserved control traffic;
OS/driver buffers and write pressure still need qualification. See
[Subprocess](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_rpc/lib/arbor_rpc/subprocess.ex)
and [Receipt](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_rpc/lib/arbor_rpc/subprocess/receipt.ex).

The RPC source package requires a build-time C17 compiler on Linux and
macOS/Darwin, including transitive MCP/ACP installation for HTTP-only or BEAM-only
use. `CC` selects a compiler executable, not a shell command. Reviewed C source
ships; generated host binaries do not, and no prebuilt helper is promised.
Installed releases must include the helper built for their target in `priv`,
resolved through `:code.priv_dir`; there is no runtime compiler or NIF. Windows
native subprocess operations are explicitly unsupported. Missing helpers and
unsupported platforms fail clearly for subprocess opening; framing needs no
running helper. Advertise only the actually qualified platform/architecture
matrix; this does not require a Windows backend for the initial v2 release. See
[RPC compiler/package](https://github.com/trust-arbor/arbor_acp/blob/0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb/packages/arbor_rpc/mix.exs).

## Stores, HTTP and persistence

Generic Runtime construction defaults to owned Tasks/Subscriptions; replay,
session and resource services are opt-in descriptors. Explicit HTTP constructors
have the transport-specific defaults described below. `ServiceRef` follows child
replacement and rejects
retired/wrong-kind capabilities without global fallback. Raw subscription/replay
overrides reject. Borrowed adapters must implement actual namespaced operations
with a stable host logical key (1–256 bytes) and proven live address; adding a
namespace string to an unnamed legacy ETS service is insufficient. Owned adapters
register before blocking effects and cannot override injected addresses/namespaces.
See [service descriptors](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/service_config.ex) and
[ServiceRef](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/service_ref.ex).

Session leases/initialization claims bind service cohort and session epoch;
reused wire session IDs do not reuse authority. Addressed operations have finite
count/byte/phase admission and paged results. Timeouts may occur after accepted
mutation, so terminal/reapable credit does not authorize re-execution. Do not
serialize process-local leases or use PID/ref/generation as a durable namespace.
The built-in initial v2 runtime session service is ETS-backed. Its non-ETS
backends reject explicitly as `:runtime_durable_sessions_unqualified`; they do
not fall back to a global store. Standalone DETS APIs remain supported separately
and do not certify runtime durability or namespace isolation. Separately
supplied durable runtime adapters require their own contract qualification;
this release does not promise one. Preserve standalone paths/keys and its
exclusive-file, finite open/sync/close and restart-recovery contract.
See [session store](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/session_manager/runtime_store.ex) and
[session leases](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/session_manager/session_lease.ex).

Optional Cowboy/Bandit listeners are implemented, with explicit backend selection,
missing-dependency diagnostics and finite shutdown. Mounted host listeners remain
borrowed. Mounted POST/request-owned SSE, progress/log output, addressed legacy
GET/replay/DELETE, correlated cancellation, MRTR, notification/initialization
arrays and legacy aliases have separate implemented and qualified source slices.
They share the existing initialized Runtime; each POST does not reconnect a
singleton HandlerServer. Addressed resource subscribe/unsubscribe and update
publication now use the actual callback Task, original cutoff and exact lease,
private endpoint and identity. Durable acceptance can retain earlier entered
effects when later output preparation fails; it does not prove client byte
receipt. See [the resource slice](https://github.com/trust-arbor/arbor_mcp/blob/f08c090c44edcda3a53478fd04a7a944c0bf2b7f/docs/V2_HTTP_RESOURCE_PUBLICATION_SLICE.md).
Legacy progress/log and reverse helpers, final subscription convergence,
remaining global-fallback cutover and final combined qualification remain gates. The accepted HTTP wrappers/startup helpers are
retired in the reviewed source; the final compiled absence audit is pending.
The retained stream keeps its original HTTP entry cutoff and a reconnect preserves its typed session. Modern GET/DELETE
remain sessionless 405. See [session streams](./V2_HTTP_SESSION_STREAM_SLICE.md).
A separate [listener capability](./V2_HTTP_LISTENER_LIFETIME_CORE.md) captures
its potential lifetime at entry, default one hour from the subscription service.
Only an actually admitted scalar Gateway invocation can establish it. The exact
nonce/cohort/owner capability governs target IO after ordinary request expiry;
it cannot renew callback, store or publication-source authority. Entered IO
remains charged until its actual completion receipt or writer death. Mounted
subscription routing and SDK behavior are not qualified by this core alone.

Preserve
forwarded mounts, parsed bodies, host/origin/OAuth, modern discovery, legacy
initialization, request-owned SSE and opt-in `legacy_http_sse`. Deprecated
`:sse_enabled` option retirement is separate from that retained wire feature.
See [listener adapters](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/transport.ex) and
[current HttpPlug](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/http_plug.ex).

Tasks retained payload bytes, Replay aggregate retention and notification
fanout/physical output still need final convergence/pressure evidence. Native
Tasks/Replay now have bounded pre-mailbox operation admission and finite entry,
aggregate retention, identifier and expiry limits. Managed input/output/store
terms detach subbinary backing; retained function environments are charged while
their identity is preserved. Runtime-selected custom Tasks/Replay adapters must
declare `bounded_operations: 1`, expose `runtime_service_binding/2` and implement
`operate/4`, with a final source/deadline check before mutation. Standalone custom
Task store callbacks remain supported. See [store bounds](./V2_NATIVE_STORE_PRESSURE.md)
for exact defaults and tagged capacity outcomes. DETS table names now use
references. Standalone DETS now has one native four-table Owner, finite original
I/O cutoffs and bounded node-local exclusive path claims. A timeout does not
promise rollback or confirmed cleanup; late physical settlement remains tracked.
Confirmed all-table close allows reuse; Owner/authority loss remains fail-closed.
SessionManager deliberately replies with typed storage errors before fail-stop.
See [DETS lifecycle](./V2_DETS_LIFECYCLE.md). Runtime durable sessions remain
unqualified, and final combined/platform qualification remains required.
Owned
service addressing alone does not bound those payloads. A modern subscription
must capture authoritative registered-edge/runtime origin, not arbitrary caller
proof; callbacks should use Context's notification path. Its bounded registry/
listener proof preserves successful origins and drops cancelled/expired/retired
ones without killing a healthy subscription. See
[Origin](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/subscriptions/origin.ex).

### HTTP listener constructors and backend ABI

Explicit `Runtime.start_link(handler: ..., transport: :http, http: [...])`,
`Server.Transport.start_server/3,4` and DSL HTTP startup return the runtime
supervisor and own a real listener child. Initialization, registered listener
startup and final readiness use the original root cutoff. The retained
`start_http_server/4` instead requires a matching explicit Runtime and returns a
borrowed backend listener PID; runtime stop does not stop that listener or an
existing mounted Phoenix host.

Owned Cowboy delegates only the qualified Ranch **1.8.1** constructor ABI,
with an exact optional dependency requirement and a pre-effect version/export/
child-shape check. Real Arbor listener/connection/acceptor callback identities
replace the stock initial-call names while preserving actual OTP parents and
acknowledgments. Managed owned and lower borrowed Cowboy constructors share a
bounded atomic reference authority; raw third-party Ranch mutations do not.
The authority retains unknown startup exclusivity through actual settlement,
removes only unchanged exact setup objects authenticated by its lease marker and
native role PIDs, and fails closed after authority loss. Partial/changed or
untagged setup metadata quarantines the claim until VM restart, preserving any
host replacement's objects.
Its 128 reference domains, 128 pre-mailbox controls, 4,096-byte reference and
8,192-byte control limits are part of the v2 lifecycle contract. No public reset
clears uncertain obligations; VM restart is the host recovery boundary.

Owned Bandit delegates only **Bandit 1.12.5 / Thousand Island 1.5.0** startup,
with exact optional requirements and pre-effect version/export checks. Actual
Arbor native supervisors, workers and acceptors register before delegated
initialization under the same cutoff; stock child IDs and admitted HTTP option
defaults remain, subject to the owned-only 1..128 acceptor and 1024 runtime
connection-construction limits. Connection registrations use one finite original
constructor timeout (10s default); infinity is rejected. Unknown construction
and actual live-child credits survive API timeouts and Admission/cohort resets
until physical settlement. Old epochs cannot bind new children; stale exact-token
cleanup cannot retire a replacement's credit.
Native socket buffers are separate. Owned startup log text is fixed, retaining its configured level
or disabled setting. Borrowed Bandit startup remains stock. Nested Thousand
Island binding options retain upstream precedence; avoid conflicts with outer
Host/Origin defaults.

Explicit `:http`/`:mounted_http` roots default to unnamed owned ETS `:sessions`
and `:resource_subscriptions` in legacy-capable modes. Explicit descriptors or
`false`/`nil` win; `:modern_only` and generic Runtime construction keep these
services opt-in. Replay remains opt-in. Removed `:sse_enabled`/server `:use_sse`
are replaced by `:legacy_http_sse`; `:handler_call_timeout` moves to root
`:request_timeout_ms`. Raw store/registry options and owned borrowed sockets
are rejected. See [HTTP listeners](./HTTP_LISTENERS.md) for the exact constructor
migration and remaining mounted subscription/reverse-helper gates.

## Telemetry, diagnostics and final qualification

Attach consumers to `[:arbor_mcp, ...]` and `[:arbor_acp, ...]`. The old server
`request/received` event is replaced in managed runtime ingress by
`request/admitted`: `count: 1` counts reservation envelopes and `request_bytes`
measures admitted input, with runtime PID metadata rather than old method data.
`request/completed` reports count, `duration_ms` and outcome classification at
terminal settlement, not remote consumption. Update dashboards instead of only
renaming a prefix; legacy MessageProcessor spans describe their own path.
See [actual emit sites](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/runtime/admission.ex). Retain the existing
default logger attachment ID when replacing handlers to avoid duplicate attachment.

At the historical `111a3c7` source basis, Application `:stdio_mode`, StdioLauncher
and ACP agent setup still changed global Logger. The separate host logging
checkpoint removes those automatic changes. Library startup, launcher startup
and ACP stdio connection now preserve host levels, primary filters, handlers
and Application logger flags. Explicit `StdioLoggerConfig.configure/0` retains
the legacy global emergency threshold for hosts that choose it; it does not
route logs or guarantee clean stdout.

Hosts must configure every diagnostic handler to stderr or another non-protocol
sink before boot. Standalone Mix commands and examples own their default handler
and persist stderr routing across application startup while preserving levels,
formatter and filters. Additional handlers remain host-owned. `Mix.install`
and compilation can print before protocol startup; use a compiled release when
stdout must contain JSON-RPC from process boot. StdioLauncher now supplies its
200 ms default through endpoint `server_opts[:stdio_startup_delay]`, preserving
an explicit endpoint override rather than changing global Application settings.
See [configuration](./CONFIGURATION.md) and [transport guide](./TRANSPORT_GUIDE.md).

The **separate privacy freeze** formats diagnostic status as fixed component
names/counts, retains opaque native constructor arguments, uses fixed
`:handler_init_failed`/`:callback_error` and `:stdin_error` reasons, and omits
handler state/error payloads from supported native reports. Failed termination
logs a fixed message then continues remaining cleanup under its original bound.
Native parent/module identity, links, restart policies and cutoffs are preserved.
Explicit trusted `:sys.get_state` and raw `:sys.log` debugging remain raw; host
names/IDs, source locations and custom logging are not erased. This source
checkpoint is distinct from host-global logging migration and from old census
counts. Its [diagnostics record](https://github.com/trust-arbor/arbor_mcp/blob/40f65d14b437c8da1cb1b0ac55f761980ca1fa70/docs/V2_RUNTIME_DIAGNOSTICS.md)
is integrated at `40f65d1`.
Whole-library Client/HTTP error-log and native client-child-spec diagnostics
were outside the earlier Runtime freeze. The separate Client diagnostics
checkpoint now qualifies closed status summaries, opaque built-in native
startup arguments, fixed connection/error logs and actual callback reports.
It preserves original typed startup/cleanup results and native parents. A host
Supervisor can still report a returned private error; that is an explicit
trusted caller boundary, exercised by the native failed-child probe.

Concurrent MRTR callbacks now capture raise/throw/exit inside their private
Task, preserving public `-32603`, `"MRTR input handler failed"` and handler state.
The converted private Task DOWN is deliberately `:normal`. Generic managed
stream value/exit results retain their existing semantics; external hard exits
remain outside that conversion. See [Client diagnostics](./V2_CLIENT_DIAGNOSTICS.md).
Custom implementations, trusted inspection and whole-library report privacy
remain separate boundaries; formatter coverage alone cannot prove them.

Before RC, rebuild immutable MCP/ACP/adapters/RPC manifests and reconcile every
unexpected callable, callback, type and struct change, including the seven
deliberate hidden retirements and privacy callbacks. The accepted source HTTP
retirements do not certify their sealed compiled absence or full HTTP convergence.
Qualify installed archives/releases, native build and priv lookup, package-only consumers, final published dependency constraints,
both wire eras, cancellation/EOF/output/borrowed survival, physical pressure,
durable stores, coverage/conformance/SDKs and the supported toolchain/platform
matrix. The accepted final-RC soak is 48 continuous hours and has not started.
Run it and coordinated versions/tags/publication only after those gates pass. See [release plan](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/V2_RELEASE_PLAN.md); this document
does not make the release complete.
