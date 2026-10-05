# V2 package and adapter contract

- **Status:** Package split, optional adapter bundle, and `Arbor.MCP.*` /
  `Arbor.ACP.*` namespaces accepted; shared event/ownership implementation is
  reviewable, with package-wide qualification and the final ABI/default freeze open.
- **Release target:** Friday, 2026-10-09, subject to the full v2 release gates.
- **Reviewed:** 2026-10-03, current ExMCP main at `1808c56`; sibling ExACP
  extraction at `58dee1d`.
- **Release scope:** The full accepted v2 roadmap, including per-server runtime
  ownership and the handler scheduler. This contract does not move those changes
  to a later major release.
- **Related:** [V2 roadmap](V2_ROADMAP.md),
  [release assessment](V2_RELEASE_ASSESSMENT.md),
  [ACP wire v2 tracking](ACP_V2_TRACKING.md).

`Arbor.MCP` and `Arbor.ACP` are the confirmed public namespaces. `Arbor.RPC` remains
the implementation name for the shared mechanics package. ACP wire protocol
versions remain independent of the library's major release.

The dotted public module spelling was accepted on 2026-10-03 for the wider
Arbor library family, matching `Arbor.Trust` and `Arbor.Historian`. Sharing the
`Arbor` prefix does not add a dependency on the Arbor application: each package
owns its distinct complete module names. Package/app names and repository
paths remain independent of the Elixir namespace.

## Package and repository layout

| Repository | Directory | Hex/OTP application | Responsibility |
|---|---|---|---|
| `trust-arbor/arbor_mcp` | repository root | `arbor_mcp` | MCP clients, servers, HTTP, authorization, runtime and scheduler |
| `trust-arbor/arbor_acp` | `packages/arbor_acp` | `arbor_acp` | ACP client/native agent, protocol and generic adapter extension runtime |
| `trust-arbor/arbor_acp` | `packages/arbor_acp_adapters` | `arbor_acp_adapters` | Optional Claude, Codex, Pi and ZCode implementations |
| `trust-arbor/arbor_acp` | `packages/arbor_rpc` | `arbor_rpc` | Neutral JSON-RPC, framing and child-process mechanics shared by both protocols |

Each package is a standalone Mix project with its own package metadata, source
files, tests, documentation and release tag. Vendor modules remain under
`Arbor.ACP.Adapters.*` even though their files ship in the optional bundle; no
second adapter namespace is needed. The ACP repository can have workspace
scripts for coordinated checks; its root must not become an extra published
application merely to hold those scripts. Use package-qualified release tags such
as `arbor_acp-v2.0.0` and `arbor_rpc-v1.0.0` when more than one package shares a
repository. The exact initial package versions remain a release decision.

Dependencies are one-way:

```text
arbor_mcp ---------> arbor_rpc <--------- arbor_acp
                                           ^
                                           |
                                  arbor_acp_adapters
```

The adapter bundle depends on ACP. ACP does not depend on the bundle, including
through an optional dependency that would make native usage install or compile
the vendor implementation. Neither protocol package depends on the other.
The bundle may declare a direct `arbor_rpc` dependency only for documented RPC
APIs it actually calls; it must not rely on accidental transitive dependencies.

A user of a native ACP agent needs only `arbor_acp`. A user of a supported vendor
adapter adds `arbor_acp_adapters`, which brings a compatible ACP version. Keep
all four vendor implementations in one bundle initially. There are no
vendor-specific third-party Elixir runtime dependencies to justify four separate
release trains today.

At the reviewed main snapshot, the ACP subtree has 60 source files and 26,893
lines, excluding its root facade and shared non-ACP helpers. Its vendor subtree
has 33 files and 17,201 lines: Claude 5,144, Codex 5,563, Pi 3,918, and ZCode
2,576. At the older sibling extraction, vendor code is 16,959 of 28,004 library
lines (60.6%). These are source-footprint measurements; compile-time and archive
size savings still need measurement. The sibling currently declares only Jason
and telemetry as third-party runtime dependencies.

## Source of truth and ownership map

Supported 1.x remains canonical on MCP `master`. V2 ACP is now canonical in
`trust-arbor/arbor_acp`, and MCP v2 is developed in draft PR #76. Extraction
scripts are retained for reconciliation evidence; do not regenerate over the
canonical ACP projects. The dirty `spike/acp-cutover` worktree and original
sibling are preserved migration evidence.

At the initial review, the older sibling required refresh because it lacked
`Adapters.ClaudeSDK.MCPConfig`, current Claude launch-option validation and
unsupported session-MCP handling, release PATH cleanup, and current stdio
process-group lifecycle mechanics.

The following map uses existing main paths. Rewrite `ExMCP.*` MCP modules to
`Arbor.MCP.*`, and `ExMCP.ACP.*` core/vendor modules to `Arbor.ACP.*`; route shared
mechanics explicitly according to the map rather than applying a blanket prefix
replacement to every existing internal module.

| Existing source | Destination/owner | Migration rule |
|---|---|---|
| `lib/ex_mcp.ex` and MCP-only `lib/ex_mcp/**` | `arbor_mcp` | Remove ACP facade calls in v2; retain MCP behaviour and wire-era support through the full redesign |
| `lib/ex_mcp/acp.ex` | `arbor_acp` facade | Native ACP entry points only |
| `lib/ex_mcp/acp/{client,agent,protocol,types,capabilities,registry,lifecycle_params,request_validation}.ex` and `client/**`, `agent/**` | `arbor_acp` | Preserve v1 negotiation and validation; `Registry` is public ACP catalog data, not an adapter registration service |
| `lib/ex_mcp/acp/{adapter,adapter_events,adapter_bridge,adapter_transport}.ex` | `arbor_acp` | Generic documented extension contract; no references to bundled vendor modules outside examples |
| `lib/ex_mcp/acp/adapter_bridge/port_runner.ex` | ACP adapter support wrapper over shared subprocess mechanics | Remove vendor names/API-key mapping from generic launch policy; do not publish the current private module unchanged |
| `lib/ex_mcp/acp/adapters/**` | `arbor_acp_adapters` | Move whole vendor families, including Claude `MCPConfig`, session stores and helper modules |
| `lib/ex_mcp/acp/prompt_queue.ex` | Bundle-owned internal queue helper | Currently used by vendor adapters only; preserve FIFO and stable split order, without a shared-package dependency |
| `lib/ex_mcp/acp/pending_requests.ex` | ACP internal request bookkeeping | Adapter uses of `put/3` and `pop/2` can become `Map.put/3` and `Map.pop/2`; no new published dictionary facade |
| `lib/ex_mcp/acp/envelope.ex`, `lib/ex_mcp/internal/jsonrpc.ex` | `arbor_rpc` JSON-RPC API | One implementation; ACP-specific request payload builders stay in ACP |
| `lib/ex_mcp/internal/{line_buffer,stdio_framing,port_environment,log_summary}.ex` | `arbor_rpc` mechanics | Move/reconcile current main implementation and contracts, not the older sibling copies |
| Mechanical portions of `lib/ex_mcp/transport/stdio.ex` and sibling `lib/ex_acp/transport/stdio.ex` | Shared subprocess/NDJSON core in `arbor_rpc` | Protocol wrappers retain message validation, error mapping and telemetry; shared code owns Port/environment/framing/cleanup |
| `lib/ex_mcp/internal/workspace_path.ex` | ACP-owned documented workspace-path support | Used by ACP client and Codex authorization; no separate copy in bundle |
| `lib/ex_mcp/internal/name_value.ex`, `lib/ex_mcp/acp/{name_value,maps,meta}.ex` | ACP data normalization/metadata support | Keep ACP descriptors and extension metadata in ACP; small generic map construction can be bundle-owned rather than RPC-owned |
| `lib/ex_mcp/internal/maps.ex`, `options.ex` | Owning package's small helpers | Do not expand `arbor_rpc` into a general utility collection to avoid trivial duplication |
| `lib/ex_mcp/internal/stdio_logger_config.ex` | Protocol launcher policy, replaced during v2 IO design | Its current VM-global Logger/Application mutation is not a neutral runtime API |
| `dev/ex_mcp/acp_compat.ex`, ACP `dev/mix/tasks/**` | ACP repository tooling | Split native SDK/catalog monitoring from vendor upstream/CLI monitoring |
| Vendor tests, `test/fixtures/acp/{claude*,codex,pi}/**`, corresponding golden support | Adapter bundle tests/support | Preserve golden transcripts and all vendor-specific lifecycle/security assertions |
| Native ACP tests and official SDK interop fixtures/probes | ACP core tests/support | Run with the adapter bundle absent |
| Generic adapter bridge/transport tests with fake adapters | ACP core tests | Keep the fake-adapter contract suite; move real Codex scenarios from the mixed integration test into the bundle |
| `dev/ex_mcp/acp_shim_generator.ex` and generated legacy forwarding modules | Legacy migration tooling/package only | V2 protocol packages do not contain `ExMCP.ACP.*` compatibility modules |

The sibling extraction's script copies ten helpers and then overwrites transport
files with an overlay. It must not remain the post-cutover update mechanism.
Once canonical implementations are moved, delete that extraction/overlay
workflow from the ACP repository and stop making fixes in legacy copies.

## Narrow shared mechanics contract

`arbor_rpc` is justified by actual reuse and demonstrated drift, not the number
of helpers. Its scope is a JSON-RPC stream over a bounded IO/child-process
boundary. It has no MCP method catalog, ACP session schema, HTTP client/server,
OAuth, adapter discovery, application registry or handler scheduler. It must not
start protocol processes at application boot or change host logging globally.
Its third-party runtime dependency is Jason; OTP applications such as `:crypto`
for fingerprints are declared explicitly where used.

The initial public API carries forward these existing primitives under the
proposed shared namespace:

| Module | Functions/types | Contract |
|---|---|---|
| `JSONRPC` | `id/0`, `method/0`, `params/0`; `request/1,2,3`, `notification/1,2`, `response/2`, `error/2,3,4`, `with_params/2`, `with_id/2`, `parse_unvalidated/1`, `generate_id/0` | Envelope builders and unvalidated classification only. Preserve explicit `id: nil`, error `data` omission semantics and encoded payloads. Protocol codecs perform their own validation. Reducers receive generated IDs as inputs. |
| `StdioFraming` | `mode/0`; `mode/1`, `write_frame/2,3`, `read_line/1,2`, `read_unit/2`, `strip_bom/1` | Byte-exact UTF-8 across unicode/latin1 IO devices; mode is re-read where currently required. Encoding/framing owns no protocol validation. |
| `PortEnvironment` | `value/0`, `os_type/0`, `normalized/0`; `validate_policy/1`, `base/1,2,3`, `child_path/1,2,3`, `normalize/1`, `to_port/1` | Isolation by default; explicit inherited mode; `false` removes variables; retain main's release-root PATH cleanup and resolve the executable against the child's effective PATH. Defaults expose current ambient inputs, full arities permit deterministic tests. |
| `LogSummary` | `describe/1`, `fingerprint/1` | Diagnostics contain shape/fingerprint, never raw frames, credentials, paths or URLs by default. This is not a general logging framework. |

`LineBuffer.drain_json/1` can remain an internal implementation helper. Its
existing return of parsed messages, invalid lines and remainder must not be
treated as a validator or allow invalid lines to leak into diagnostics. The
public bounded decoder is a small pure frame reducer:

```elixir
Framing.new(max_frame_bytes: positive_integer()) :: Framing.t()
Framing.push(Framing.t(), iodata()) ::
  {:ok, [binary()], Framing.t()} | {:error, :frame_too_large}
```

`Framing.t/0` is opaque. Returned frames exclude the delimiter; the remainder is
retained in state. Limits apply to each complete frame and the unfinished frame,
including across chunks. Multiple individually valid frames in one chunk must
not fail merely because their total exceeds one frame's cap. A separate bounded
delivery queue controls aggregate retained bytes/messages. Oversize input fails
the connection explicitly; it must not silently discard an unfinished frame.
Newline parsing is shared; blank/banner/invalid-JSON policy belongs to the
protocol or native adapter wrapper. BOM and CRLF behaviour is pinned by fixtures.

Subprocess mechanics are the remaining shared implementation boundary, with an
opaque `Subprocess.t/0` rather than public Port-state structs. Required operations
are `open(command, opts)`, `write(handle, iodata)`, `close(handle)`,
`connected?(handle)` and `linked_processes(handle)`. A shared framed stream
wrapper adds receive/subscribe delivery over that handle and the frame reducer.
Finalize event/ownership signatures in the runtime design record before exposing
them; these functions are proposed, unlike the copied primitive APIs above.

**October 4 implementation:**
[ACP draft PR #1](https://github.com/trust-arbor/arbor_acp/pull/1) now implements
these handles and shared mechanics. `FramedStream.next_until/3` retains an
absolute deadline across protocol filtering. Subscriptions deliver neutral
`{:arbor_rpc, generation, {:frame, token, bytes}}` events; the receiving process
ACKs its token after bounded processing. Closure carries its reason and original
unfinished bytes. Opening ownership is independent of readers, and known cleanup
failures propagate. The generic ACP bridge and Pi use this interface; native ACP
and MCP child-stdio integration candidates are being qualified. The canonical
[RPC source documentation](https://github.com/trust-arbor/arbor_acp/tree/codex/shared-subprocess/packages/arbor_rpc)
records exact signatures and remaining Port-pressure/platform limits. This is
an implemented candidate, not the final release ABI/default freeze.

The mechanical implementation must centralize executable resolution, environment
construction, Port creation, ownership transfer, OS PID capture, normal/error
exit handling, idempotent close, bounded TERM/KILL cleanup and process-group
cleanup. Native adapter-managed subprocesses use that same launch/write/cleanup
implementation through ACP's support wrapper. Do not leave an independent raw
Port lifecycle in Pi or a second cleanup algorithm in either protocol package.
`process_group: true` must preserve or explicitly revise the existing documented
requirement that the program leads the group; it must never signal the host's
own process group. Platform differences are part of the contract tests.

MCP's JSON-RPC/resource security checks remain in its wrapper. ACP's protocol
validation and vendor-native decoding remain in their owners. Shared code does
not emit protocol telemetry names; wrappers preserve and then deliberately
migrate their established event names/metadata. The generic transport behaviour
must not select concrete MCP transports by atom.

An initial extraction commit may centralize the pure primitives before the
subprocess refactor lands. That is an implementation stage, not completion of
the shared-runtime release gate. If the shared package cannot meet the bounded
stream/child-lifecycle contract without importing protocol policy, stop and
revise its design rather than restoring security-sensitive copies.

## Stable adapter extension contract

Keep the existing required `Adapter` callbacks and their result shapes through
the extraction: `init/1`, `command/1`, `translate_outbound/2` and
`translate_inbound/2`, with `state/0 :: term()`. Current main's `command/1`
accepts `{executable, args}`, `:one_shot`, `:adapter_managed`, or
`{:error, reason}`; the last shape is missing from the older sibling and must
not be lost. Preserve the existing tagged outbound combinations, including
`messages_and_reply_and_write`, until an explicit scheduler design change
replaces them and updates both custom-adapter documentation and contract tests.

Optional callbacks remain `name/0`, `capabilities/0`, `post_connect/1`, `env/1`,
`modes/0`, `config_options/0`, `auth_methods/1,2`, `list_sessions/2`,
`fork_session/2`, `handle_adapter_message/2` and `shutdown/1`. Optional support is
discovered from the adapter module's callbacks, not a core list of vendor names.
Adapters choose vendor environment defaults through `env/1`; explicit caller
environment wins. Move Pi's `:api_key` to `PI_API_KEY` mapping and vendor session
variable policy out of the generic Port driver, with golden/environment tests
preserving intentional behaviour.

The extraction adds optional `environment_defaults/1` to express inherited
environment removals without changing the existing vendor `env/1` outputs.
The generic launcher applies isolated/inherited baseline, adapter defaults,
adapter `env/1`, then explicit caller environment, in that order. Maps/lists
are normalized through the shared environment contract; `false` removes a
variable. Vendor session-variable lists and Pi's API-key mapping belong to
the adapter bundle. This new extension callback requires custom-adapter
documentation and compatibility qualification before release.

These existing public ACP APIs are the adapter bundle's stable dependencies:

| API | Exact functions already consumed or documented |
|---|---|
| `AdapterEvents` | `session_update/2`, `agent_message_chunk/2,3`, `agent_thought_chunk/2,3`, `user_message_chunk/2,3`, `content_chunk/3,4`, `resource_link_chunk/2,3`, `current_mode_update/2`, `available_commands_update/2`, `plan/2`, `config_option_update/2`, `session_info_update/1,2`, `tool_call/2`, `tool_call_update/2`, `session_update_type/2,3,4`, `status_update/3,4`, `prompt_response/2,3` |
| `Protocol` | `encode_permission_request/3`, `encode_file_read_request/2,3`, `generate_id/0` |
| `Capabilities` | `supported?/2` |
| `Types` | `auth_required_code/0`, `session_info/2,3`; documented ACP wire/data types remain core-owned |
| Shared JSON-RPC | Vendors currently consume `Envelope.request/3`, `notification/2`, `response/2`, `error/2,3,4`; replace the private ACP `Envelope` dependency with the documented shared API |

`AdapterEvents.maybe_put/3` is a leaked helper and is not carried into the new
public surface. Chunk options retain keyword/map handling where currently
supported; explicit message IDs and metadata shape stay pinned.

The bundle must not depend on `Arbor.ACP.Internal.*`. Resolve the remaining
current internal calls as follows:

| Existing internal use | Resolution |
|---|---|
| `PromptQueue.new/0`, `from_list/1`, `empty?/1`, `len/1`, `enqueue/2`, `pop/1`, `split/2`, `drain/1`, `to_list/1`; opaque `t(item)` | Move into bundle-owned internals; no cross-package API |
| `PendingRequests.put/3`, `pop/2` | Use standard `Map` operations; ACP retains its own internal lifecycle bookkeeping |
| `Maps.put_present/3`, `put_non_empty/3`, `put_present_non_empty_list/3`, `stringify_keys/1` | Bundle-owned small data construction helpers, or documented ACP configuration normalization when consuming ACP descriptors; no RPC utility facade |
| `NameValue.map/1` | Document ACP-owned `Arbor.ACP.AdapterSupport.NameValue.map/1` descriptor normalization consumed by Codex |
| `WorkspacePath.within?/2`, `canonical/1` | Document ACP-owned `AdapterSupport.WorkspacePath` functions used by ACP client and vendor authorization; qualify symlink/canonical-root handling, without claiming race-free filesystem authorization |
| `LogSummary.describe/1` | Use documented shared diagnostics |
| `AdapterBridge.PortRunner.open/4`, `command/2`, `close/1` | Document ACP `AdapterSupport.Subprocess` launch/write/close interface backed by the shared mechanical implementation; adapter module/environment shaping stays in ACP support, not RPC |

The concrete support ABI is `Arbor.ACP.AdapterSupport.NameValue.map/1`;
`Arbor.ACP.AdapterSupport.WorkspacePath.within?/2` and `canonical/1`; and
`Arbor.ACP.AdapterSupport.Subprocess.open/4`, `command/2`, and `close/1`.
Descriptor normalization retains existing name/value map/list conversion.
Workspace path functions retain canonical-root/symlink semantics. The subprocess
functions retain the arguments already used by the bridge and Pi:

```elixir
open(command :: String.t(), args :: [String.t()], opts :: keyword(), adapter :: module()) ::
  {:ok, handle()} | {:error, term()}
command(handle(), iodata()) :: :ok | {:error, term()}
close(handle() | nil) :: :ok | {:error, term()}
```

`close(nil)` returns `:ok`. Closing a handle exposes known cleanup failures and
unconfirmed or unavailable cleanup rather than treating Actor DOWN as success.
An available typed RPC cleanup receipt records the actual owned-child reaping
and, when requested, targeted-group observation; it does not establish containment
of arbitrary descendants. This is the existing support return contract, not an
additional ownership guarantee.

The subprocess support wrapper replaces its implementation behind those
signatures. Its handle must be
opaque and its event/ownership contract must work for Pi's managed process
messages; any change from raw Port messages is an explicit adapter-runtime
change with golden lifecycle tests. Do not publish private `safe_env/2` solely
because it existed in the old module.

## Migration risks and required evidence

1. **Stale extraction loses fixes.** Build from current main and reconcile the
   sibling-only ACP transport/telemetry APIs. Pin a source snapshot and run the
   current vendor golden scenarios, including Claude MCP launch configuration.
2. **Copied subprocess policy drifts.** Main `PortEnvironment` is 145 lines;
   sibling's copy is 71 and lacks PATH cleanup/child-path resolution. Share one
   implementation and run child-launch tests from an actual OTP release.
3. **Namespace/module identity changes.** Old forwarding modules cannot preserve
   struct identity; adapter authorization callbacks expose the new module name.
   Publish an API migration table and compile representative consumer handlers,
   supervision child specs and module-based options under the chosen namespace.
4. **Wire/storage rename breaks peers or existing sessions.** Preserve
   `_meta.ex_mcp`, `ex_mcp.mcpCapabilities`, `_ex_mcp.pi/*`, existing generated ID
   meanings and `~/.ex_mcp/pi/session-map.json` for this extraction. Handle any
   later extension/storage rename through its own migration, not search/replace.
5. **Telemetry/config migration loses consumers.** Document old/new event names
   and application configuration keys, including Codex legacy-auth precedence.
   A 1.x bridge must still supply both core and bundled adapters and collect shim
   targets from both application module lists. V2 removes legacy forwarders.
6. **Separate packages accidentally remain coupled.** ACP core must compile and
   pass native/fake-adapter tests with the bundle absent. Replace the sibling
   interop setup's stale `Application.ensure_all_started(:ex_mcp)` call.
7. **Native protocol and vendor churn share a release gate.** Keep official SDK
   v1/v2 draft probes in core, and vendor upstream/real-CLI lanes in the bundle.
   Full-system checks still exercise the supported combination before release.
8. **New runtime changes lifecycle behaviour.** Preserve or explicitly document
   callback process identity, links, cancellation, ordering, queue bounds, state
   commits, session cleanup and supervision ownership. Package movement alone
   must not silently choose the scheduler contract.

## Packaging, CI and release gates

- Each package declares the confirmed app/name/namespace, source/homepage URL,
  docs canonical URL, license, source tag and exact package file list. Published
  metadata uses supported Hex version ranges; local path dependencies and
  extraction scripts do not escape into consumer archives.
- Restore CI/release workflows for the ACP repository; the sibling currently has
  no remote or `.github` directory. Use repository/org credentials and protection
  rules after the GitHub move. Repository redirects do not migrate package names,
  Hex ownership or consumer application configuration.
- Build all packages from clean consumer projects. Record compressed archive
  size, cold compile time and dependency/application count for MCP-only,
  ACP-only and ACP-plus-adapters usage. Check each produced archive for only its
  intended modules, tools and documentation.
- Run shared JSON-RPC/framing/UTF-8/environment/Port-lifecycle contracts on both
  MCP and ACP wrappers. Include partial/oversize frames, many valid frames in one
  chunk, CRLF/BOM, unicode and latin1 devices, explicit/removed child PATH,
  release-root PATH, credentials absent from isolated environments, spawn
  failure, owner/reader exit, caller timeout, repeated close and group cleanup.
- Run core native-agent/client and SDK interop without the bundle installed;
  generic bridge contracts use fake adapters. The bundle runs vendor unit/golden,
  authorization/environment, managed-process and real-CLI lifecycle suites.
- Run lowest and newest supported shared-core versions in each protocol package;
  run lowest and newest supported ACP versions in the bundle. Prove a deliberately
  incompatible shared version is caught by the contract lanes.
- Release `arbor_rpc` first, then compatible protocol packages, then the bundle.
  Each package has an independent changelog/version; coordinated initial v2
  qualification does not require permanently synchronized version numbers.
- The full v2 release gate also requires the accepted runtime/scheduler work,
  deprecated API removal, HTTP-server dependency changes, documentation,
  conformance, security checks, interop and soak. A successfully split archive
  does not complete that gate.

GitHub transfer/rename can precede implementation. Preserve the existing dirty
worktree and local sibling paths until their path dependency is replaced. Finish
the complete accepted v2 implementation and qualification before publishing the
new packages.
