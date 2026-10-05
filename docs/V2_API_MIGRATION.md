# V2 API migration inventory

Status: all 102 accepted callable retirements, the eight Tools modules and two
legacy HTTP wrappers, and four type retirements are implemented in the reviewed
source candidate.
The final sealed four-package compiled comparison remains pending.
Seven additional implementation exports deliberately retire with the reviewed
runtime redesign; they are recorded separately below. During migration, supported
1.x remains on the default `master` branch; a later default-branch change is a
separate release action.
Candidate v2 source is in the isolated MCP checkout and canonical ACP repository.
This inventory records the package/namespace split, implemented migrations and
remaining release gates.

The frozen [API baseline](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/v2/api_baseline_1_5_plus.json) describes application
`ex_mcp` version `1.5.0` at source `1808c56bd4fc7b000043c2775f61ecced6ed059f`
with 341 compiled modules, 3,137 exports, 653 types and 136 callbacks. It
includes hidden exports/modules. Its 31 deprecated callable signatures and two
deprecated modules are compiled metadata; documentation warnings alone do not
make a removal decision. Defaults contribute separate arities. The companion
[machine-readable plan](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/v2/api_migration_plan.json) identifies each planned
module/member/type removal and links it to a replacement group below. Neither
file changes the frozen baseline or supported source.

Read this alongside [package ownership](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_PACKAGE_CONTRACT.md) and the
[runtime contract](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_RUNTIME_CONTRACT.md), and the
[non-symbol migration record](./V2_NON_SYMBOL_MIGRATION.md) for options,
configuration, callback/process identity, deadlines, ACKs, stores and telemetry.
This document is reconciled against MCP source `111a3c7` and the historical
MCP `69b0a39` / ACP-RPC `0e4cfd1` census. Ordinary Client lifetime and runtime
privacy freezes are supplementary named checkpoints, not retroactive changes
to that census. Candidate runtime files remain
under active development; the presence of a source file does not establish
release-wide qualification or a final public API. Live status also includes the
later owned-listener, finite-shutdown, HTTP alias and accepted HttpPlug startup
retirement followups. Runtime-only mounts and bounded HTTP reverse are integrated
at `1284440`; the later scoped HTTP bookkeeping, legacy JSON progress and
shutdown observation followups are committed at `e284fee`. Selected conformance
results and remaining final qualification gates are recorded below. The
historical compiled counts are unchanged.

The compiled checkpoint audit reads actual BEAM exports (including macro/default
arities) and type metadata against the frozen baseline and accepted plan:

```sh
mix run --no-start scripts/check_v2_api_retirements.exs
```

The historical minimum/current artifacts confirm 96 callable, eight module and
four type removals. Later source followups remove the four HTTP-wrapper callables
and `HttpPlug.start_link/0,1`, completing the accepted source retirement inventory.
Run `--complete` on freshly compiled final sources; it fails while any planned
removal is present. Source absence is not a sealed compiled 102-callable result,
and this audit does not replace the final four-package API/consumer comparison.

The historical four-package comparison maps 333 of 341 old modules; the eight
missing modules are accepted Tools retirements. Its 104 missing callables are
**96 accepted retirements + one moved ACP facade + seven implementation exports**.
They are separate categories: `ExMCP.start_acp_client/1` moves to
`Arbor.ACP.start_client/1`, rather than counting as a retired ACP capability.
The census reports zero missing callbacks and four accepted Tools types absent.
Its MCP reflection reused `f16660b` and explicitly excluded the subsequent DSL
source delta. Regenerate final manifests after all overlays; added callbacks,
changed types/struct meanings and generated consumer modules require their own
review even when the old export name remains.

### Current compiled API census: API4 snapshot

The fresh four-package production comparison at MCP
`9d18d9b6266260acbda45b5f7399c19c11c01327` and ACP/RPC/adapters
`47c9e8a303cb0b3fcbb9c1c748e49edfa53a377b` is a separate snapshot from the
historical counts above. On minimum and current toolchains, it maps 331 old
modules, classifies ten module retirements and 110 missing callables
(102 accepted retirements, the moved ACP facade and seven implementation
exports), and reports zero unintended missing items or ownership differences.
The four missing types remain the accepted Tools types.

Both captures contain eleven retained type-definition changes and sixteen
struct changes: fifteen structs gain fields and the accepted
`Tools.Builder.Tool` struct retires entirely. Three callback contracts expand:
ACP `Adapter.shutdown/1`, MCP `Transport.close/1`, and the hidden
`Internal.SessionStore.close/1` seam. Minimum reflection also renders unchanged
`Client.Middleware.call/2`'s `fun()` as `(... -> any())`; the released and current
source declarations match, so that fourth rendered row is not a callback
contract change. See the [current semantic census](./V2_NON_SYMBOL_MIGRATION.md#current-api4-type-callback-and-struct-census)
for the additional fields and consumer actions.

The retained `Server.DSL.Result` constructor delegates and StdioServer startup
entrypoints have explicit function documentation linking their replacement and
Runtime ownership contracts. This documentation followup changes no production
forms, signatures or retirement-plan classifications.

API4 is a source-qualified `2.0.0-dev` API snapshot, not release qualification.
The later legacy Client async-POST correction requires a new source association
and reflection. Final RC metadata, external consumers, paired performance,
platform/wire qualification and the continuous soak remain separate gates.

## Deliberate implementation-surface retirements

These seven former exports are already absent from the new architecture and
are deliberately retired as part of the reviewed v2 runtime redesign. This
checkpoint review is distinct from the earlier accepted 96 removal decisions;
hidden documentation alone is not the removal rationale. The final compiled
comparison/allowlist must record these exact entries too.

| Former symbol | Supported entry points and semantic replacement |
| --- | --- |
| `ExMCP.Server.StdioServer.init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2`, `code_change/3` | Use retained `Arbor.MCP.Server.StdioServer.start_link/1` / `child_spec/1`, Handler callbacks and public Server helpers. The facade returns a native Runtime supervisor; Reader/Writer/HandlerServer/Scheduler own implementation callbacks. Direct invocation of the old inline GenServer callbacks has no forwarding shim. |
| `ExMCP.Transport.Stdio.process_data/2` | Use retained protocol transport `connect`, `send_message`, `receive_message`, `subscribe` and `close`, or the documented RPC framing/subprocess APIs when implementing a transport. Raw Port parser state is replaced by opaque owned framing/receipt state; do not feed messages into a removed private parser. |

See [stdio facade source](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/stdio_server.ex),
[transport source](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/transport/stdio.ex) and the
[behavior migration](./V2_NON_SYMBOL_MIGRATION.md). This does not retire stdio,
Handler behaviours, existing protocol methods or supported subscriber semantics.

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

These eight modules, their 81 callable signatures and four types are removed
from the v2 candidate. The replacement consumer and compiled absence cases are
qualified on both supported toolchains; see `V2_TOOLS_RETIREMENT_SLICE.md`.
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
| `tools_dsl` | `Arbor.MCP.Server.Handler` plus `Arbor.MCP.Server.DSL`; `tool/2,3`, `param/2,3`, `description/1`, `title/1`, `annotations/1`, `input_schema/1`, `output_schema/1`, `run/1` and `handle/1` macros are present in [DSL source](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/dsl.ex). Rewrite Simplified `deftool` to `tool`; migrate compiler-generated consumer modules instead of calling old hooks. |
| `tools_builder` | Static definitions use the DSL; dynamic definitions use handler-owned maps and `handle_list_tools/2` / `handle_call_tool/3`. There is no replacement builder struct or process-global registration service. Move descriptors and dispatch functions into application-owned state; do not serialize handler closures as tool descriptors. `Builder.Tool.t/0`, `param/0` and their fields disappear. |
| `tools_registry` | Dynamic handler callbacks and explicit owned state replace registration, lookup and dispatch. `t:Arbor.MCP.Server.Handler.tool/0` aliases the current MCP descriptor type; application callback types replace `Registry.handler()`. Registry child specs and OTP callbacks have no standalone replacement. The application-owned consumer has qualified mutation, list/get/call, duplicate/replacement, explicit defaults, cached validation and list-change semantics; see [dynamic migration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_DYNAMIC_TOOLS_MIGRATION_SLICE.md). |
| `tools_results` | DSL `ToolResult` and raw Handler callbacks use `Arbor.MCP.Server.Result`, the single complete-result implementation; the existing `Server.DSL.Result` function surface forwards here. `text/1`, `error/1,2`, `structured/2,3`, media/resource/content helpers and normalizers are present in `lib/arbor_mcp/server/result.ex`. Result helpers return complete result maps rather than always returning a content list. Images, embedded resources and mixed content use valid MCP content maps. A URI alone is not a complete embedded resource; supply resource content or a revision-supported link. Modern `structuredContent` normalization replaces the old normalizer's `structuredOutput` convention. Test wire/result equivalence per protocol era rather than blindly renaming helpers. |
| `tools_schema` | Literal JSON Schema maps plus DSL schema declarations replace schema constructors and AST evaluation. [SchemaPolicy](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/content/schema_policy.ex) provides `compile/1,2` and `validate/2,3`; `Content.SchemaValidator.compile_schema/1,2` also exists. They return tagged results, unlike `Tools.compile_schema/1`, which returned a resolved value or raised. They do not duplicate `Helpers.validate_arguments/2` default insertion/coercion. Applications that rely on that behavior must provide and test it explicitly. `nil` schema bypass must be handled deliberately. |

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
already exists in [Handler source](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/handler.ex); it preserves tools/list,
tools/call, schema validation and tool execution errors as distinct behavior.

The deprecated-family tests migrated to replacement semantics, or retired only
when they characterized the removed implementation. Keep
semantic assertions from `compliance/protocol_vs_execution_error_test.exs`,
`compliance/structured_output_compliance_test.exs`,
`content/schema_policy_test.exs` and the schema compilation performance suite.
`server/structured_output_test.exs` has already migrated to the modern DSL.

## Remove deprecated HTTP endpoint wrappers

Remove `ExMCP.Transport.HTTPServer` and
`ExMCP.Transport.HTTPServerWithVersion`, including each `init/1` and `call/2`.
They declare no frozen public types. The replacement Plug is
`Arbor.MCP.HttpPlug`; `init/1` and `call/2` remain in the v2 candidate. Supported
1.x main retains `ExMCP.HttpPlug`. The v2 Plug supports forwarded mount paths and
bodies already parsed by
`Plug.Parsers`, canonical initialization and protocol-version validation.
Removing wrappers does not remove Streamable HTTP, request-owned SSE, sessions,
resume/replay, OAuth, origin/host checks or explicitly supported legacy HTTP+SSE.

`ExMCP.HttpPlug.start_link/0,1` separately disappear in the accepted source
retirement. They only started the application-owned session registry. In supported
1.x the replacement is ensuring `:ex_mcp` is started, not starting another session
owner manually. V2 mounts an explicit Runtime owning its configured services;
replay stays opt-in. V2 package startup does not start server state owners.
The standalone `SessionRegistry`, `SessionManager`, resource registry,
ProgressTracker, Cancellation, Tasks ETS, Replay ETS and Subscriptions APIs remain
exported for explicit host supervision. Start only the standalone owner an
application intentionally uses; mounted HTTP never selects those global owners.
Handler-only mounts and raw store/registry selectors raise before effects.
`:handler_opts` supplies charged per-request application context; initialize the
handler once with root `:handler_args`. Mount subscription authorizers must
compose with the root service policy and mount limits may only narrow root caps
and the original listener cutoff. See [runtime HTTP cutover](./V2_HTTP_RUNTIME_CUTOVER.md).
Mounted POST/request-SSE, addressed sessions/replay, cancellation/arrays/MRTR and
legacy aliases have implemented checkpoints. Addressed resource subscription
tracking and durable fanout are implemented; publication requires the actual
HTTP callback context and exact lease identity. See [the resource slice](https://github.com/trust-arbor/arbor_mcp/blob/f08c090c44edcda3a53478fd04a7a944c0bf2b7f/docs/V2_HTTP_RESOURCE_PUBLICATION_SLICE.md).
Legacy progress/log notifications and mounted modern subscription routing have
implemented source checkpoints. Runtime-only HTTP mounts and explicit standalone
server ownership are implemented at `27f81a1`. The combined 543-case selection
passes on all three captured toolchains, and the 27-case HTTP wire/Client selection
passes on both supported toolchains. Bounded reverse integration is committed at
`1284440`, with 636 combined cases on all three captured toolchains and 40 actual
HTTP wire/Client cases on both supported toolchains. The later scoped HTTP
followups are committed at `e284fee`. Their immediately preceding qualified
snapshot passes 671 combined cases with WAE/full formatting on all three and
50 actual HTTP wire cases on both supported toolchains. Supported quality/docs
gates and 13 actual SDK stdio/HTTP cases pass both; the full current rerun passes
5,344 tests plus doctests/properties. The later fixture-only restoration of its
original paced workload has passing actual progress coverage. Stable server
conformance reports 38/1 on both, retaining the published version-header
mismatch; stable client 218 and modern server 149/client 387 cases pass both.
Final full minimum/CI, actual OAuth wire, complete stable conformance and the
sealed compiled API audit remain gates. See
[current release status](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_RELEASE_PLAN.md) for the separate source receipts
and remaining package, consumer, performance and continuous-soak gates.

The supported mounted shape is:

```elixir
# The host owns its listener; a supervised Runtime owns handler state and services.
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

Owned Cowboy construction pins and checks Ranch 1.8.1's private constructor ABI.
It uses real Arbor native callback modules, with actual parent links and one
startup cutoff. Its bounded VM-lifetime reference authority also fences the
retained stock lower Cowboy adapter/helper, preserves uncertain startup claims,
and never deletes borrowed backend metadata. See [HTTP listeners](./HTTP_LISTENERS.md)
for capacity, lifecycle and dependency migration details.

Owned Bandit construction likewise pins Bandit 1.12.5 and Thousand Island 1.5.0;
Arbor's real native callback roles register before delegated initialization,
retain the original cutoff and native parent, and preserve admitted HTTP option
defaults. Borrowed listeners keep stock backend constructors. See
`HTTP_LISTENERS.md` for dependency constraints and lifetime distinctions.

The standalone listener migration retains
`Arbor.MCP.Server.Transport.start_http_server/4` and `start_server/3,4`.
`start_server/3,4` and DSL HTTP startup return the runtime supervisor PID and own
its listener; the lower-level `start_http_server/4` requires an explicit matching
`:runtime` and keeps its listener-PID return shape. Direct Runtime construction
uses `transport: :http, http: [adapter: ..., port: ...]`. It adds
`:http_adapter` (`:cowboy` default or `:bandit`), `:http_listener_options`, and
`stop_http_server/1,2` with positive finite `:http_shutdown_timeout` (5,000 ms
default). Cowboy-only `:ranch_ref` is rejected for Bandit. A missing optional
backend returns `{:error, {:missing_http_listener_dependency, backend, package}}`.
Plug.Cowboy and Bandit are optional dependencies; mounted Phoenix does not need
the library to own a listener. See [listener source](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/lib/arbor_mcp/server/transport.ex).
The two legacy wrappers are removed in this constructor checkpoint; preserve
`HttpPlug.init/1` and `call/2`. Owned HTTP/mounted runtime profiles default to
unnamed owned ETS sessions and resource subscriptions in legacy-capable modes,
while explicit disable/descriptors win and replay remains opt-in. Owned Cowboy
roots use unique default references; borrowed helpers retain the old Plug
reference. Removed server `sse_enabled`/`use_sse` aliases require
`legacy_http_sse`; the client's `use_sse` option is separate. See
[standalone ownership and migration](HTTP_LISTENERS.md).
This checkpoint does not establish the remaining live subscription/reverse-helper
HTTP convergence or final compiled API graph qualification.

## Remove unimplemented media/encoding helpers

The 11 media/metadata callable signatures below and the four ambiguous protocol
helpers in the next section are removed in the candidate. Compiled absence and
semantic migrations pass on minimum/current together with component composition:
444 tests and eight properties, zero failures. The frozen 1.x baseline is
unchanged. See [the implementation record](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_API_RETIREMENTS_SLICE.md).

The exact callable set is in the compiled-deprecation table. In 1.x,
`Builders.resize` and `compress`, and `Transformer.convert_encoding`,
`compress_image`, `resize_image` and `generate_thumbnail` returned an explicit
not-implemented error. `Sanitizer.remove_metadata/1` cleared a content-level
`:metadata` map when present; it never stripped image EXIF. Perform media
processing in the application before constructing MCP content.

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

| Retained type/API | Implemented narrowing |
|---|---|
| `ExMCP.Content.Transformer.transformation_op/0` | Removed media/encoding atoms and tuple forms return a fixed tagged error before any pipeline step. Whitespace and custom operations remain. The retained experimental generic atom fallback does not override this rejection. |
| `ExMCP.Content.Sanitizer.sanitization_op/0` | Removed `:remove_metadata` and `:compress_media` atoms and tuple forms raise a fixed `ArgumentError` before any content/text pipeline step. Supported sanitizers remain. Application metadata can be changed explicitly with `Map.put/3`. |
| `ExMCP.Content.Builders.file_opts/0` | `:auto_resize` and `:quality` are removed from the type/examples and rejected by presence before file reads in all file builders. `from_file/2` retains size checks and now enforces the previously ignored `:mime_types` allowlist. |

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
existing MRTR `Server.Result.input_required/1,2`; the version-aware helper
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
| `ExMCP` and MCP-only `ExMCP.*` | `arbor_mcp`, `Arbor.MCP` / `Arbor.MCP.*`; eight Tools modules and the two legacy HTTP wrappers are retired. The replacement Runtime-mounted HttpPlug retains Plug `init/1` / `call/2`, without its old registry startup helpers. |
| `ExMCP.ACP`, `.Client`, `.Agent` and generic ACP descendants | `arbor_acp`, `Arbor.ACP.*`; `start_client/1`, `start_agent/1`, `run_agent/1` are in the ACP facade. MCP no longer supplies ACP. |
| `ExMCP.start_acp_client/1` | `Arbor.ACP.start_client/1`; this facade replacement is distinct from the accepted callable retirements. |
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

## Handler runtime migration

The candidate routes Test/BEAM HandlerServer, generated DSL startup, server
stdio and installed HTTP requests through Runtime/Scheduler and bounded output.
Mounted subscription/resource/reverse paths are integrated; final combined
cross-transport, authenticated wire and installed-package qualification remain gates. Earlier slice documents describe their original
evidence boundaries; [the non-symbol migration](./V2_NON_SYMBOL_MIGRATION.md)
records current source and supplementary freezes without rewriting that history.

| Old usage/contract | Candidate replacement and limits |
|---|---|
| `ExMCP.Server.HandlerServer.start_link/1` and generated DSL startup return a handler GenServer PID | `Arbor.MCP.Server.HandlerServer.start_link/1`, generated startup, `StdioServer.start_link/1` and owned HTTP startup return a native runtime supervisor PID. Child specs become supervisor specs; registered names belong to the root. Existing Phoenix mounts borrow their host listener and address a supervised Runtime. |
| `self()` during protocol/custom callbacks identifies the transport/handler process | Callbacks execute in supervised tasks; their PID differs from the root, protocol edge and state owner. Scheduler owns committed state and handler init/termination. ETS owned by a callback worker follows that owner's lifetime unless an explicit heir or ownership transfer is configured. Arbitrary spawned processes and other callback-created resources do not gain automatic Runtime lifecycle management; give persistent resources explicit managed owners. An ETS table created in init belongs to the scheduler: callback tasks cannot access a private table or write a protected table. Use explicit state or a supervised state owner for those operations. |
| `GenServer.call(server, request)` / `GenServer.cast(server, message)` for custom handlers | New `Arbor.MCP.Server.call/2,3` and `cast/2` submit through bounded runtime admission. These are additive helpers, absent from the frozen `ExMCP.Server` callable set. Custom callbacks support `{:reply, reply, next_state}` and `{:noreply, next_state}`; deferred `GenServer.reply`, continuation and stop tuples are unsupported. Override the Handler default before adding custom call clauses. |
| External inspection assumes `:sys.get_state(server)` contains handler state | Root state is supervisor state. `Runtime.ref/1` gives an opaque runtime reference stable across child restarts; `Runtime.edge/1` is explicit diagnostic/control access. Edge state is protocol state. Direct GenServer calls/sends to an edge bypass supported pre-mailbox admission and are not the migration contract. |
| Singletons/process-dictionary context and wire ID alone determine cancellation | `Server.Context.cancelled?/0` consults runtime/connection/direction/invocation scope; new `Context.scope/0` exposes that opaque scope during a callback (nil outside); accepted cancellation prevents the invocation's state commit and retires old peer work. A new peer can reuse its wire IDs safely. |

```elixir
# Supported candidate Test/BEAM shape; full HTTP convergence has additional gates.
{:ok, root} = Arbor.MCP.Server.HandlerServer.start_link(handler: MyHandler, transport: :beam)
{:ok, runtime} = Arbor.MCP.Server.Runtime.ref(root)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: runtime)
Arbor.MCP.Server.call(runtime, :read)
Arbor.MCP.Server.cast(runtime, {:add, 1})
```

Stateful callbacks remain serialized. Opt-in stateless concurrency requires
unchanged state. A finite caller wait can expire while accepted state work
continues; aliases discard late replies. The invocation's server deadline
includes ingress/queue time. Output/aggregate admission occurs before state
commit; actual handoff and physical IO have separate receipt boundaries.
Defaults, pressure, durable recovery and the complete HTTP/cross-transport
matrix remain release gates. Managed bounds are not hard bounds on arbitrary
Erlang sends, all callback memory or application state.

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
and current toolchains. The later output integration charges member and
prospective aggregate output before each commit and delivers one charged array.
An explicit whole-envelope output failure preserves earlier sequential effects;
it does not retry callbacks. See [output integration](https://github.com/trust-arbor/arbor_mcp/blob/111a3c70421206a0d6b96184523ffa1db9d209d6/docs/V2_OUTPUT_INTEGRATION_SLICE.md).

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
[non-symbol record](./V2_NON_SYMBOL_MIGRATION.md) consolidates the historical
64-entry census, current source and named followups. The following release
checks remain distinct from symbol parity:

| Surface | Concrete current evidence and required decision/check |
|---|---|
| Application configuration | Migrate `config :ex_mcp` to the actual owner, including module-valued OAuth/task/subscription keys and schema policy. Host Logger/Phoenix settings remain host-owned. Do not blanket-map vendor environment variables or protocol/storage identifiers. Application/launcher stdio Logger migration remains separate from facade behavior and privacy formatting. |
| HTTP options | `:sse_enabled` and server `:use_sse` retire; `:legacy_http_sse` remains an explicit wire option. `:handler_call_timeout` moves to root `:request_timeout_ms`; per-request static/function/MFA `:handler_opts` becomes charged Context application data, never handler initialization. Explicit Runtime/service addresses replace raw handler/server/store overrides. Preserve authenticated request facts and qualify the final combined subscription/resource/reverse package graph. |
| Media options | Implemented in the first retirement checkpoint: full pipeline prevalidation rejects removed tokens before custom effects, and every file builder rejects `:auto_resize` / `:quality` presence before file access. Retained `:mime_types` and `:max_size` constrain loading. See `V2_API_RETIREMENTS_SLICE.md` for exact policies and tests. |
| Process/store names | Native runtime/service logical references replace cached child PIDs; descriptors distinguish owned and genuinely namespaced borrowed domains. ETS runtime sessions and bounded Tasks/Replay have implemented slices; standalone DETS has its separate finite ownership contract. HTTP mounts no longer select implicit server globals. Final combined retention/recovery/pressure evidence remains a gate; a filename or renamed atom does not prove runtime isolation. |
| Telemetry and messages | Prefixes become `[:arbor_mcp, ...]` / `[:arbor_acp, ...]`. Managed runtime `server/request/admitted` replaces old `received`: reservation-envelope count/request bytes/runtime PID have different meanings from method-level receipt metadata. Local mailbox ACK, staged batch ACK, physical IO completion and remote consumption are distinct. Selected legacy IDs/messages remain; RPC events carry generation/token with explicit bounded ACK. |
| Lifecycle/results | Source checkpoints distinguish the committed scoped helper, supplementary ordinary Client lifetime/event-context patches and supplementary privacy diagnostics. Preserve native parent identity, typed cleanup uncertainty, original deadlines and borrowed survival during final integration. ACP's shutdown result expansion and pure managed-receipt callback require consumer changes despite retained names. |
| Package/consumer release | Validate four real package manifests, normal dependency resolution and clean consumer compilation; move examples, Mix tasks, SDK/ecosystem tooling and tests to the owning package. V2 must include full runtime/scheduler scope and preserved wire-era coverage. No release/tag/publication is implied by source-copy or manifest checks. |

Protocol-deprecated Roots, Sampling and protocol Logging are not compiled
deprecated-callable removals in this inventory. Keep the accepted legacy and
modern wire-era compatibility until a separate explicit feature decision says
otherwise. Library API retirement does not retire MCP/ACP content, tasks,
subscriptions, progress, cancellation, OAuth, schema policy, MRTR or legacy
negotiation. Check those features with replacement-path tests before deleting
compatibility code.

The accepted six HTTP signatures and two wrappers are retired in the reviewed
source candidate; Plug `init/1` and `call/2` remain. Rebuild the final four-package
API against
the frozen baseline, recording accepted removals, the ACP facade move, the
seven implementation retirements and all unexpected differences in callables,
callbacks, types and struct meanings. Validate actual installed consumer graphs,
published version constraints, retained wire eras and the final RC/soak matrix.
An allowlist or an unchanged exported name does not establish those contracts.
