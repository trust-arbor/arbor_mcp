# V2 API migration inventory

Status: proposed removal/replacement inventory for review. This inventory does
not implement source removals. Supported 1.x remains in `lib/`; candidate
v2 source is in the isolated MCP checkout and canonical ACP repository. This
inventory records the accepted package/namespace split and API retirement
scope, and distinguishes implemented candidate contracts from release gates.

The frozen [API baseline](./v2/api_baseline_1_5_plus.json) describes application
`ex_mcp` version `1.5.0` at source `1808c56bd4fc7b000043c2775f61ecced6ed059f`
with 341 compiled modules, 3,137 exports, 653 types and 136 callbacks. It
includes hidden exports/modules. Its 31 deprecated callable signatures and two
deprecated modules are compiled metadata; documentation warnings alone do not
make a removal decision. Defaults contribute separate arities. The companion
[machine-readable plan](./v2/api_migration_plan.json) identifies each planned
module/member/type removal and links it to a replacement group below. Neither
file changes the frozen baseline or supported source.

Read this alongside [package ownership](./V2_PACKAGE_CONTRACT.md) and the
[runtime contract](./V2_RUNTIME_CONTRACT.md). Candidate runtime files remain
under active development; the presence of a source file does not establish
release-wide qualification or a final public API.

## Complete compiled-deprecation list

Every deprecated callable in the frozen manifest appears below. Whole-module
HTTP removal also includes its callable entries; the Tools family inventory
includes both its compiled-deprecated macros and its other exported members.

| Old module | Exact compiled-deprecated signatures | Replacement group | Source |
|---|---|---|---|
| `ExMCP.Content.Builders` | `compress/1`, `compress/2`, `resize/3` | `media` | `lib/ex_mcp/content/builders.ex` |
| `ExMCP.Content.Sanitizer` | `remove_metadata/1` | `metadata` | `lib/ex_mcp/content/sanitizer.ex` |
| `ExMCP.Content.Transformer` | `compress_image/2`, `compress_image/3`, `convert_encoding/1`, `convert_encoding/2`, `generate_thumbnail/2`, `generate_thumbnail/3`, `resize_image/3` | `media` | `lib/ex_mcp/content/transformer.ex` |
| `ExMCP.HttpPlug` | `start_link/0`, `start_link/1` | `http_owner` | `lib/ex_mcp/http_plug.ex` |
| `ExMCP.Protocol.ErrorCodes` | `legacy_consent_required/0`, `resource_not_found/0`, `url_elicitation_required/0` | `consent`, `resource_code`, `url_code` | `lib/ex_mcp/protocol/error_codes.ex` |
| `ExMCP.Protocol.VersionNegotiator` | `build_capabilities/1` | `initialize` | `lib/ex_mcp/protocol/version_negotiator.ex` |
| `ExMCP.Server.Tools` | `macro annotations/1`, `macro description/1`, `macro handle/1`, `macro input_schema/1`, `macro output_schema/1`, `macro param/2`, `macro param/3`, `macro title/1`, `macro tool/2`, `macro tool/3` | `tools_dsl` | `lib/ex_mcp/server/tools.ex` |
| `ExMCP.Transport.HTTPServer` | `call/2`, `init/1` | `http_endpoint` | `lib/ex_mcp/transport/http_server.ex` |
| `ExMCP.Transport.HTTPServerWithVersion` | `call/2`, `init/1` | `http_endpoint` | `lib/ex_mcp/transport/http_server_with_version.ex` |

For every row, the corresponding `Arbor.MCP.*` module has the namespace change
in addition to the retirement. Existing candidate copies of retired functions
are temporary implementation state, not a promise that v2 will retain them.

## Remove the complete Server.Tools family

Remove these eight modules, their 81 callable signatures and four types.
Compiler hooks, hidden helpers, generated struct constructors and GenServer
callbacks are included because they appear in the compiled baseline. Modules
generated in a consumer by `use` are not a closed set of baseline modules:
recompile/migrate those consumers too.

| Old module | Exact callable signatures | Removed types | Replacement group |
|---|---|---|---|
| `ExMCP.Server.Tools` | `__normalize_response__/2`, `__tool__/4`, `__validate_and_normalize_response__/3`, `compile_schema/1`, `validate_with_schema/2`, `macro __before_compile__/1`, `macro __using__/1`, `macro annotations/1`, `macro description/1`, `macro handle/1`, `macro input_schema/1`, `macro output_schema/1`, `macro param/2`, `macro param/3`, `macro title/1`, `macro tool/2`, `macro tool/3` | None | `tools_dsl`, `tools_results`, `tools_schema` |
| `ExMCP.Server.Tools.ASTValidator` | `validate_schema_ast/1` | None | `tools_schema` |
| `ExMCP.Server.Tools.Builder` | `annotations/2`, `build/1`, `description/2`, `handler/2`, `input_schema/2`, `new/1`, `output_schema/2`, `param/3`, `param/4`, `title/2` | None | `tools_builder` |
| `ExMCP.Server.Tools.Builder.Tool` | `__struct__/0`, `__struct__/1` | `param/0`, `t/0` | `tools_builder` |
| `ExMCP.Server.Tools.Helpers` | `array_schema/1`, `array_schema/2`, `error_response/1`, `image_response/2`, `image_response/3`, `multi_content_response/1`, `number_schema/0`, `number_schema/1`, `object_schema/1`, `object_schema/2`, `resource_response/2`, `string_schema/0`, `string_schema/1`, `structured_response/2`, `text_response/1`, `validate_arguments/2` | None | `tools_results`, `tools_schema` |
| `ExMCP.Server.Tools.Registry` | `call_tool/3`, `call_tool/4`, `child_spec/1`, `code_change/3`, `get_tool/1`, `get_tool/2`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `init/1`, `list_tools/0`, `list_tools/1`, `register_tool/2`, `register_tool/3`, `register_tools/1`, `register_tools/2`, `start_link/0`, `start_link/1`, `terminate/2` | `handler/0`, `tool_definition/0` | `tools_registry` |
| `ExMCP.Server.Tools.ResponseNormalizer` | `normalize/1`, `normalize_error/1` | None | `tools_results` |
| `ExMCP.Server.Tools.Simplified` | `apply_default_description/2`, `process_instructions/2`, `macro __before_compile__/1`, `macro __using__/1`, `macro annotations/1`, `macro deftool/2`, `macro deftool/3`, `macro description/1`, `macro input_schema/1`, `macro output_schema/1`, `macro param/2`, `macro param/3`, `macro run/1`, `macro title/1` | None | `tools_dsl` |

The replacements are semantic migrations:

| Group | Available replacement and prerequisites |
|---|---|
| `tools_dsl` | `Arbor.MCP.Server.Handler` plus `Arbor.MCP.Server.DSL`; existing `tool/2,3`, `param/2,3`, `description/1`, `title/1`, `annotations/1`, `input_schema/1`, `output_schema/1`, `run/1` and `handle/1` macros are present in `lib/ex_mcp/server/dsl.ex` and the renamed candidate. Rewrite Simplified `deftool` to `tool`; migrate compiler-generated consumer modules instead of calling old hooks. |
| `tools_builder` | Static definitions use the DSL; dynamic definitions use handler-owned maps and `handle_list_tools/2` / `handle_call_tool/3`. There is no replacement builder struct or process-global registration service. Move descriptors and dispatch functions into application-owned state; do not serialize handler closures as tool descriptors. `Builder.Tool.t/0`, `param/0` and their fields disappear. |
| `tools_registry` | Dynamic handler callbacks and explicit owned state replace registration, lookup and dispatch. `Arbor.MCP.Server.Handler.tool/0` aliases the current MCP descriptor type; application callback types replace `Registry.handler/0`. Registry child specs and OTP callbacks have no standalone replacement. Dynamic mutation, defaults, validation and list-change notifications need consumer migration tests before the old registry is removed. |
| `tools_results` | DSL `ToolResult` is an alias for `Arbor.MCP.Server.DSL.Result`. `text/1`, `error/1`, `structured/2` and normalizers are present in `lib/ex_mcp/server/dsl/result.ex`. Result helpers return complete result maps rather than always returning a content list. Images, embedded resources and mixed content use valid MCP content maps. A URI alone is not a complete embedded resource; supply resource content or a revision-supported link. Modern `structuredContent` normalization replaces the old normalizer's `structuredOutput` convention. Test wire/result equivalence per protocol era rather than blindly renaming helpers. |
| `tools_schema` | Literal JSON Schema maps plus DSL schema declarations replace schema constructors and AST evaluation. `Arbor.MCP.Content.SchemaPolicy.compile/1,2` and `validate/2,3` exist in `lib/ex_mcp/content/schema_policy.ex`; `Content.SchemaValidator.compile_schema/1,2` also exists. They return tagged results, unlike `Tools.compile_schema/1`, which returned a resolved value or raised. They do not duplicate `Helpers.validate_arguments/2` default insertion/coercion. Applications that rely on that behavior must provide and test it explicitly. `nil` schema bypass must be handled deliberately. |

The per-member replacement groups in the JSON distinguish schema helpers from
result helpers even when both belonged to `Tools.Helpers`. Its complete schema
constructor set is `string_schema/0,1`, `number_schema/0,1`, `array_schema/1,2`
and `object_schema/1,2`. The remaining helper set is `text_response/1`,
`error_response/1`, `structured_response/2`, `image_response/2,3`,
`resource_response/2`, `multi_content_response/1` and `validate_arguments/2`.

```elixir
defmodule MyApp.Echo do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL

  tool "echo", "Echo input" do
    param :message, :string, required: true
    run fn %{message: message}, state ->
      {:ok, ToolResult.text(message), state}
    end
  end
end
```

For runtime-selected tools, implement `handle_list_tools(cursor, state)` with
`{:ok, descriptors, next_cursor, state}` and `handle_call_tool(name, args, state)`
with `{:ok, result, next_state}` / `{:error, reason, next_state}`. The descriptor
uses MCP fields such as `inputSchema` and `outputSchema`. The callback path
already exists in `lib/ex_mcp/server/handler.ex`; it preserves tools/list,
tools/call, schema validation and tool execution errors as distinct behavior.

Before deletion, migrate the deprecated-family tests to test the replacement
or retire tests that only characterize the removed implementation. Keep
semantic assertions from `compliance/protocol_vs_execution_error_test.exs`,
`compliance/structured_output_compliance_test.exs`,
`content/schema_policy_test.exs` and the schema compilation performance suite.
`server/structured_output_test.exs` has already migrated to the modern DSL.

## Remove deprecated HTTP endpoint wrappers

Remove `ExMCP.Transport.HTTPServer` and
`ExMCP.Transport.HTTPServerWithVersion`, including each `init/1` and `call/2`.
They declare no frozen public types. The replacement Plug is
`Arbor.MCP.HttpPlug`; `init/1` and `call/2` are present in current main and the
candidate. It supports forwarded mount paths, bodies already parsed by
`Plug.Parsers`, canonical initialization and protocol-version validation.
Removing wrappers does not remove Streamable HTTP, request-owned SSE, sessions,
resume/replay, OAuth, origin/host checks or explicitly supported legacy HTTP+SSE.

`ExMCP.HttpPlug.start_link/0,1` separately disappear. They only start the
application-owned session registry. In supported 1.x the replacement is
ensuring `:ex_mcp` is started, not starting another session owner manually.
The final v2 replacement is an explicit runtime owning its session/replay/
subscription stores. Runtime-mounted HTTP has not converged in the candidate;
do not tell consumers that renaming this startup helper completes that migration.

The planned mounted shape is:

```elixir
# Final shape required by the runtime contract; HTTP convergence is still pending.
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

A separately reviewed listener candidate in `tmp/arbor-mcp-http-qa` retains
`Arbor.MCP.Server.Transport.start_http_server/4` and `start_server/3,4`. It adds
`:http_adapter` (`:cowboy` default or `:bandit`), `:http_listener_options`, and
`stop_http_server/1,2` with positive finite `:http_shutdown_timeout` (5,000 ms
default). Cowboy-only `:ranch_ref` is rejected for Bandit. A missing optional
backend returns `{:error, {:missing_http_listener_dependency, backend, package}}`.
Plug.Cowboy and Bandit are optional dependencies in that candidate; mounted
Phoenix does not need the library to own a listener. This candidate is listener
foundation evidence, not implemented runtime-mounted HTTP convergence.

## Remove unimplemented media/encoding helpers

The exact callable set is in the compiled-deprecation table. `Builders.resize`
and `compress`, and `Transformer.convert_encoding`, `compress_image`,
`resize_image` and `generate_thumbnail` currently return an explicit
not-implemented error. `Sanitizer.remove_metadata/1` clears a content-level
`:metadata` map when present; it never strips image EXIF. There is no library
image-processing replacement to advertise.

Perform media processing and EXIF removal in an application-owned pipeline, then
use retained `Arbor.MCP.Content.Builders.image/2,3` with base64 data and MIME.
Encoding conversion likewise belongs to the application's decoder. Retain
content construction, image/audio transfer, text transformations that are
implemented, content validation and annotations.

```elixir
# processed_bytes come from the application's chosen media processor.
content = Arbor.MCP.Content.Builders.image(Base.encode64(processed_bytes), "image/png")
# Clearing application metadata is separate from removing EXIF in media bytes.
content = Map.put(content, :metadata, %{})
```

The inventory also includes type/option changes invisible to deprecated-export
counts:

| Retained type/API | Planned narrowing or unmet prerequisite |
|---|---|
| `ExMCP.Content.Transformer.transformation_op/0` | Retire `:convert_encoding`, `{:convert_encoding, from}`, `:compress_images`, `:resize_images`, `{:resize_images, opts}` and `:generate_thumbnails`. Current pipeline clauses are no-ops, with other atoms accepted by a catch-all. Agree and test explicit rejection/error behavior for removed operations; changing a typespec alone does not remove silent acceptance. Keep implemented whitespace and custom operations. |
| `ExMCP.Content.Sanitizer.sanitization_op/0` | Retire `:remove_metadata` and `:compress_media` pipeline operations alongside `remove_metadata/1`. Keep the type and supported sanitizers. Agree/test rejection behavior for removed tokens; clearing content metadata and actual media sanitization have different effects. |
| `ExMCP.Content.Builders.file_opts/0` | `:auto_resize` and `:quality` are advertised but have no implementation in file processing. Their final removal/explicit-rejection policy needs review alongside the stub removal; retain implemented size/MIME checks. Remove misleading examples once decided. |

`Transformer.transform/2`, `transform_with_validation/2`, `convert_format/2`,
`extract_text/1`, `Sanitizer.sanitize/2` and the content modules themselves are
not planned wholesale removals. Their remaining partial/experimental behavior
needs its own review; this inventory does not infer removals from every no-op
or documentation warning.

## Replace ambiguous compatibility helpers

`Protocol.ErrorCodes.legacy_consent_required/0` becomes the existing
`Arbor.MCP.Protocol.ErrorCodes.consent_required/0` for local application consent
errors. Do not reuse historical MCP resource code `-32002` for new consent
errors. Historical decoding must remain contextual and is a migration-test
prerequisite, not a reason to change legacy resource-not-found on the wire.

`Protocol.ErrorCodes.resource_not_found/0` becomes existing
`resource_not_found/1` with an established era or negotiated revision. Legacy
peers still receive `-32002`; modern peers receive `-32602`.
`url_elicitation_required/0` becomes `url_elicitation_required(:legacy)` only
when emitting the historical `-32042` for a legacy peer. Modern peers use the
existing MRTR `Server.DSL.Result.input_required/1,2`; the version-aware helper
rejects modern emission with `{:error, :retired_error_code}`. Preserve modern
MRTR and legacy URL elicitation rather than dropping either wire feature.

```elixir
code = Arbor.MCP.Protocol.ErrorCodes.resource_not_found(negotiated_version)
# In a modern callback that needs input:
ToolResult.input_required(input_requests, request_state)
```

`Protocol.VersionNegotiator.build_capabilities/1` returned a complete legacy
initialize wrapper. Existing `Server.Capabilities.build_capabilities/1,2`
returns only a capability map. Existing internal
`Protocol.Initialize.build_initialize_result/2` builds the canonical complete
string-keyed result from request params and handler fields; framework dispatch
already uses it. Applications should return capabilities/server information
through `handle_initialize/2` and let dispatch normalize them. A standalone
replacement must deliberately assemble serverInfo/version and account for the
tag/key differences; this is not a one-argument drop-in. Do not use legacy
VersionNegotiator to discover MCP 2026-07-28, which uses `server/discover`.

## Namespace, package and shared ownership moves

The accepted names are `arbor_mcp` / `Arbor.MCP.*`, `arbor_acp` /
`Arbor.ACP.*`, `arbor_acp_adapters` / `Arbor.ACP.Adapters.*`, and `arbor_rpc` /
`Arbor.RPC.*`. Package application atoms change too. Version `2.0.0-dev` is an
unpublished implementation checkpoint; normal consumer installation remains a
release gate. No `ExMCP.*` aliases are promised inside the new protocol packages.

| Old owner/symbol | New owner and verified candidate |
|---|---|
| `ExMCP` and MCP-only `ExMCP.*` | `arbor_mcp`, `Arbor.MCP` / `Arbor.MCP.*`; the 10 retired modules above are removed rather than retained under the new prefix. |
| `ExMCP.ACP`, `.Client`, `.Agent` and generic ACP descendants | `arbor_acp`, `Arbor.ACP.*`; `start_client/1`, `start_agent/1`, `run_agent/1` are in the ACP facade. MCP no longer supplies ACP. |
| `ExMCP.ACP.Adapters.*` including nested vendor helpers | Optional `arbor_acp_adapters`, keeping `Arbor.ACP.Adapters.*`. Core ACP has no dependency on the vendor bundle. |
| `ExMCP.ACP.PromptQueue` | `Arbor.ACP.Adapters.Internal.PromptQueue` in the bundle. This hidden helper is not promoted to a protocol extension API. |
| `ExMCP.Internal.JSONRPC`, `StdioFraming`, `PortEnvironment`, `LogSummary` | `arbor_rpc`: `Arbor.RPC.JSONRPC`, `.StdioFraming`, `.PortEnvironment`, `.LogSummary`. Their candidate files exist in the RPC package; callers must declare a dependency when calling RPC APIs directly. |
| `ExMCP.Internal.LineBuffer` | `Arbor.RPC.Internal.LineBuffer`; remains an internal implementation detail. New documented `Arbor.RPC.Framing` and `FramedStream` support bounded streaming. |
| `ExMCP.ACP.Envelope` | ACP retains `Arbor.ACP.Envelope` as an internal delegate to `Arbor.RPC.JSONRPC`. Method payload builders remain ACP-owned; there is one envelope mechanics implementation. |
| `ExMCP.Internal.NameValue`, `WorkspacePath` | `Arbor.ACP.AdapterSupport.NameValue`, `.WorkspacePath`; no copied vendor helper. `Arbor.ACP.NameValue` remains an internal delegate. Generic map/options helpers are not moved wholesale into RPC. |
| `ExMCP.ACP.AdapterBridge.PortRunner.open/4`, `command/2`, `close/1`, `safe_env/2` | `Arbor.ACP.AdapterSupport.Subprocess` has these signatures. `open/4` now returns an opaque shared child handle; callers must replace raw Port pattern matching/ownership/reading with documented identity/event/ACK/monitor helpers. Close can return a known cleanup error. |
| Port mechanics in MCP/ACP stdio, persistent bridges and Pi | `Arbor.RPC.Subprocess` / `FramedStream`; protocol validation, banner handling, telemetry, vendor selection and logging stay with protocol wrappers. This is a semantic ownership change, not a raw Port type alias. |

RPC owns byte framing, child environment/PATH resolution, lifetime ownership and
cleanup; it owns no protocol method catalog, OAuth, HTTP listener, adapter policy
or handler scheduler. Neither protocol package depends on the other. Retain
legacy ACP `_meta.ex_mcp`, `_ex_mcp.pi/*`, native request IDs, client information
defaults and `~/.ex_mcp/pi/session-map.json` unless an explicit wire/storage
migration is separately accepted. Do not apply namespace replacement inside
opaque peer data or persistent keys.

## Candidate handler runtime migration

The implemented candidate slice is Test/BEAM HandlerServer and generated DSL
startup. Its detailed evidence and residuals are in the candidate
`docs/V2_HANDLER_RUNTIME_MIGRATION.md`; these contracts still require full
cross-transport/runtime qualification.

| Old usage/contract | Candidate replacement and limits |
|---|---|
| `ExMCP.Server.HandlerServer.start_link/1` and generated DSL startup return a handler GenServer PID | `Arbor.MCP.Server.HandlerServer.start_link/1` / generated Test/BEAM startup return a runtime supervisor PID. Child specs become supervisor specs; registered names belong to the root. Stdio/HTTP convergence is outstanding. |
| `self()` during protocol/custom callbacks identifies the transport/handler process | Callbacks execute in supervised tasks; their PID differs from the root, protocol edge and state owner. Scheduler owns committed state and handler init/termination. Resources created inside an invocation inherit task lifetime. An ETS table created in init belongs to the scheduler: callback tasks cannot access a private table or write a protected table. Use explicit state or a supervised state owner for those operations. |
| `GenServer.call(server, request)` / `GenServer.cast(server, message)` for custom handlers | New `Arbor.MCP.Server.call/2,3` and `cast/2` submit through bounded runtime admission. These are additive helpers, absent from the frozen `ExMCP.Server` callable set. Custom callbacks support `{:reply, reply, next_state}` and `{:noreply, next_state}`; deferred `GenServer.reply`, continuation and stop tuples are unsupported. Override the Handler default before adding custom call clauses. |
| External inspection assumes `:sys.get_state(server)` contains handler state | Root state is supervisor state. `Runtime.ref/1` gives an opaque runtime reference stable across child restarts; `Runtime.edge/1` is explicit diagnostic/control access. Edge state is protocol state. Direct GenServer calls/sends to an edge bypass supported pre-mailbox admission and are not the migration contract. |
| Singletons/process-dictionary context and wire ID alone determine cancellation | `Server.Context.cancelled?/0` consults runtime/connection/direction/invocation scope; new `Context.scope/0` exposes that opaque scope during a callback (nil outside); accepted cancellation prevents the invocation's state commit and retires old peer work. A new peer can reuse its wire IDs safely. |

```elixir
# Qualified candidate for Test/BEAM, not yet the full HTTP/stdio migration.
{:ok, root} = Arbor.MCP.Server.HandlerServer.start_link(handler: MyHandler, transport: :beam)
{:ok, runtime} = Arbor.MCP.Server.Runtime.ref(root)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: runtime)
Arbor.MCP.Server.call(runtime, :read)
Arbor.MCP.Server.cast(runtime, {:add, 1})
```

Stateful callbacks remain serialized. Opt-in stateless concurrency requires
unchanged state. A finite caller wait can expire while accepted state work
continues; the candidate uses aliases to discard late replies. The invocation's
server deadline includes ingress/queue time. Defaults, callback result size,
aggregate batch output, store recovery, stdio, HTTP and shutdown across all
transports remain qualification gates. Do not equate bounded admission with a
hard bound on arbitrary Erlang sends, all callback memory or application state.

Scheduled custom `handle_call/3` now receives
`{original_caller_pid, proxy_reply_tag}` as `from` at candidate `c8a4987`.
The opaque reply tag addresses the callback worker; early or saved late
`GenServer.reply/2` calls cannot settle the caller or bypass serialized state
commit. Callback `self()` still identifies a supervised task. Deferred replies
remain unsupported. The original PID, worker separation and early/late reply
behavior have regressions on minimum/current toolchains; representative
consumer/resource migration remains required before RC. See the candidate's
`docs/V2_CALLER_IDENTITY_SLICE.md` for the contract and limits.

Legacy batches at `9eaca9e` reserve one input envelope plus one work permit per
member, including notifications and invalid members. Atomic whole-set claims
prevent a batch from bypassing the queue count; permits remain held until its
envelope settles. Combined batch/services/caller regressions pass on minimum
and current toolchains. Aggregate response accounting and production output
preparation remain prerequisites before cross-transport release qualification.

The synchronous runtime helper at `dd75a7c` uses one caller wait budget from
API entry through admission and result observation. Expired confirmation
retains uncertain credit until the admission owner releases it, and queued late
results cannot bypass the original wait cutoff. Already accepted work may still
commit under its server deadline. Finite cleanup under byte-ledger contention
remains a separate pressure gate; this is not a complete transport qualification.

## Non-symbol migration inventory and release prerequisites

The frozen symbol manifest does not describe configuration keys, accepted
option values/defaults, registered names, ETS/DETS identities, telemetry,
messages, persistence paths, error shapes, links or process lifetime. The
following inventories must be finished separately before removals ship:

| Surface | Concrete current evidence and required decision/check |
|---|---|
| Application configuration | Migrate `config :ex_mcp` to the owning app (`:arbor_mcp`, `:arbor_acp`, or RPC only for actual shared options), including module-valued OAuth/task/subscription keys and JSON Schema policy. Enumerate all `Application.get_env/fetch_env/compile_env/put_env` sites; do not blanket-map vendor environment variables or protocol data. |
| HTTP options | Retire the `:sse_enabled` alias separately from the retained `:legacy_http_sse` wire feature. Inventory `:sse_mode`, `:handler_opts` static/function/MFA behavior, `:handler_call_timeout`, `:handler`, `:server`, authentication facts, replay and store options before runtime-mounted HTTP replacement. Per-request handler initialization must not survive behind a renamed option. |
| Media options | Decide explicit rejection of removed pipeline tokens and advertised `:auto_resize` / `:quality`; typespec narrowing alone is insufficient. |
| Process/store names | Current `ExMCP.Supervisor`, `DynamicSupervisor`, cancellation/subscription/session/progress/replay/task owners and named ETS such as `:progress_tracker_state` / `:http_plug_sessions` must be assigned to package-wide or runtime-owned state. Enumerate DETS paths/table allocation and upgrade cleanup; renaming module atoms does not provide two-runtime isolation. |
| Telemetry and messages | Main emits `[:ex_mcp, ...]`; candidate MCP stdio already emits `[:arbor_mcp, ...]`. Inventory every event name, measurement, metadata field and handler attachment; decide the migration/compatibility policy. Internal push events and raw Port callbacks change to generation-tagged acknowledged RPC events. They are not covered by export parity. |
| Lifecycle/results | Audit public close/disconnect errors, startup cleanup failures, supervisor links/child specs, worker `self()`, direct GenServer calls, deferred callbacks, callback-created ETS/children and timeout cancellation assumptions. ACP's explicit cleanup-result and receipt/shutdown changes are documented in its `docs/ADAPTER_EXTENSION_API.md`. |
| Package/consumer release | Validate four real package manifests, normal dependency resolution and clean consumer compilation; move examples, Mix tasks, SDK/ecosystem tooling and tests to the owning package. V2 must include full runtime/scheduler scope and preserved wire-era coverage. No release/tag/publication is implied by source-copy or manifest checks. |

Protocol-deprecated Roots, Sampling and protocol Logging are not compiled
deprecated-callable removals in this inventory. Keep the accepted legacy and
modern wire-era compatibility until a separate explicit feature decision says
otherwise. Library API retirement does not retire MCP/ACP content, tasks,
subscriptions, progress, cancellation, OAuth, schema policy, MRTR or legacy
negotiation. Check those features with replacement-path tests before deleting
compatibility code.

The removal implementation can begin after review of this plan, prerequisite
resolution and replacement evidence. Diff the rebuilt v2 API against the frozen
baseline using this plan as an explicit allowlist; review unexpected differences
in callables, callbacks, types and struct fields. The allowlist does not replace
the non-symbol inventories above.
