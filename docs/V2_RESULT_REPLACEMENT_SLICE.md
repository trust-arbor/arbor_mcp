# V2 Result replacement slice

Status: integrated into the unpublished MCP v2 draft after qualification against
canonical MCP source `47fe089c507b7fc3b776cb26250700d035a55caa`. No public
export is removed here. The supported 1.x source, frozen baseline and accepted retirement
plan are unchanged. This slice does not qualify all API retirements or the
production output integration being implemented separately.

## Implemented constructor contracts

All functions below belong to `Arbor.MCP.Server.DSL.Result`, aliased as
`ToolResult` in modules using `Arbor.MCP.Server.DSL`. They return complete,
ordinary tool-result maps, rather than the deprecated helpers' content lists.

| Signature | Result and validation |
|---|---|
| `content([map()]) :: map()` | `%{content: entries}`; requires a proper list of plain maps; preserves entries and nested metadata. |
| `image(base64_binary, mime_binary) :: map()` | One image block with `type`, `data`, and `mimeType`; validates already-base64 data and requires a nonempty explicit MIME string. |
| `audio(base64_binary, mime_binary) :: map()` | The corresponding audio block, with the same validation. |
| `resource(contents_map) :: map()` | One embedded resource block. Requires nonempty `uri` and exactly one binary `text` or base64 `blob`. Optional `mimeType` is a nonempty binary and `_meta` a plain map. Accepts atom or string keys and rejects duplicate spellings of these fields. |
| `structured(text, data_map, opts) :: map()` | Existing text/structured result plus optional boolean `:is_error`, emitted as `isError`. |
| `error(reason, opts) :: map()` | Existing error result plus optional plain-map `:structured_content`, emitted as `structuredContent`. |

Options require a proper keyword list with no duplicate or unknown keys and the
documented value types. Invalid constructor arguments/options raise
`ArgumentError` with fixed text `Invalid tool result or result options`; values
are never formatted into that error. Existing binary `error/1` text and
`structured/2` result shapes stay unchanged. `structured/2,3` remain map-based;
modern scalar/list `structuredContent` requires separate schema qualification.

`error/1,2` preserve deliberately authored binary text. Nonbinary authored atoms
and binary `message` fields use the existing safe error-message formatter.
Other reasons produce `Tool execution failed` without inspecting private terms.
This changes the previous arbitrary `inspect(reason)` wire response.

These helpers do not read files/URIs, infer MIME types, transform media, call
application JSON/Inspect protocols, or apply runtime byte budgets. Base64
validation decodes producer-provided data and therefore has a transient producer
allocation cost; the constructors do not claim to bound total producer memory.
URI-only resource contents fail explicitly. Revision-specific content support
and protocol validation remain the dispatcher's responsibility.

```elixir
# In a modern DSL tool's inline run callback:
result = ToolResult.content([
  %{type: "text", text: "preview"},
  hd(ToolResult.image(Base.encode64(processed_bytes), "image/png").content),
  hd(ToolResult.resource(%{uri: "file:///notes.txt", text: notes}).content)
])
{:ok, result, state}

# A structured tool failure remains a tool result, not a JSON-RPC protocol error.
ToolResult.structured("Try again", %{retryable: true}, is_error: true)
ToolResult.error("Unavailable", structured_content: %{retryable: false})
```

## Normalization and state-commit boundary

`normalize_tool_result/1` now wraps bare content-map lists and preserves complete
atom- or string-keyed result maps, including `isError`, `structuredContent`,
annotations and `_meta`. Complete results take precedence over shorthand `text`
fields. Both spellings of legacy `structuredOutput` normalize to
`structuredContent`; an existing canonical value wins, and the alias disappears.
Structured-only results acquire an empty `content` list in the corresponding
key style. MRTR `InputRequired` markers retain their distinct existing path.

Unsupported top-level values and invalid content-list shapes raise the fixed
argument error before `normalize_tool/2` can return callback state. This is a
programming error: Runtime classifies it as safe `:handler_crash` / protocol
internal failure with no state commit. It is deliberately not an `isError` tool
failure; applications use `Result.error/1,2` for authored execution failures.
Malformed results are no longer silently converted to inspected text. Nested application values remain
unchanged: unsupported nested PIDs/references/structs must fail the separate
protocol output codec before Scheduler state commit. This module does not
serialize them or invoke their custom encoders. A direct handler call is not an
output admission boundary; production reservation, publication and state-commit
integration is a separate slice.

The output implementation owner confirmed compatibility with its bounded native
`:protocol` walk of ordinary maps/lists and protocol atom values; arbitrary
structs remain invalid protocol JSON. Custom `Server.call` term responses are a
separate `:term` contract and are not passed through these tool-result helpers.

## Consumer evidence and remaining retirement gates

Read-only inspection of `/Users/azmaveth/code/arbor` at clean master
`effc6056559513bd16ca214b5b3503eb73c9e9f1` found no `ExMCP`, `Arbor.MCP`,
`:ex_mcp` or `:arbor_mcp` references. This provides no evidence that a compatibility
shim is needed, and it does not prove that other downstream consumers exist or
have migrated.

Internal consumers are real migration evidence: `server/dsl_test.exs` exercises
inline DSL callbacks and output-schema validation; `server/structured_output_test.exs`
uses complete result maps, structured-only results and the legacy alias; the new
`server/dsl/result_replacement_test.exs` adds mixed string/atom content maps,
image/audio/resources, structured errors, safe error responses and rejection
before callback state return. Existing Tools family tests, deprecated-registry
compliance fixtures and schema-performance fixtures still depend on APIs slated
for removal and must be migrated before deleting those exports.

All **102 accepted callable retirements remain unimplemented** in this slice,
including the 81-callable/eight-module Tools family. The 10 whole-module
retirements, four removed types (`ExMCP.Server.Tools.Builder.Tool.param/0`,
`Builder.Tool.t/0`, `ExMCP.Server.Tools.Registry.handler/0`, and
`Registry.tool_definition/0`) and 31 compiled deprecations remain recorded in
[the authoritative inventory](./V2_API_MIGRATION.md) and
[the machine-readable plan](./v2/api_migration_plan.json). The exact callable
inventory below is generated from that unchanged plan; it is not new removal
authorization.

| Old module | Planned removal signatures, still present |
|---|---|
| `ExMCP.Content.Builders` | `compress/1`, `compress/2`, `resize/3` |
| `ExMCP.Content.Sanitizer` | `remove_metadata/1` |
| `ExMCP.Content.Transformer` | `compress_image/2`, `compress_image/3`, `convert_encoding/1`, `convert_encoding/2`, `generate_thumbnail/2`, `generate_thumbnail/3`, `resize_image/3` |
| `ExMCP.HttpPlug` | `start_link/0`, `start_link/1` |
| `ExMCP.Protocol.ErrorCodes` | `legacy_consent_required/0`, `resource_not_found/0`, `url_elicitation_required/0` |
| `ExMCP.Protocol.VersionNegotiator` | `build_capabilities/1` |

Result constructors cover only part of `tools_results`. Before actual source
retirement, the remaining work includes:

- Migrate Tools and Simplified declarations/compiler-generated consumer modules
  to Handler/DSL; migrate builder descriptors and dynamic registry mutation,
  defaults/coercion, schema validation and list-change notification behavior to
  application-owned handler state.
- Qualify tagged SchemaPolicy compilation/validation replacements, deliberate
  `nil` bypass, default/coercion changes and modern schema/structured-data
  semantics; this slice does not change SchemaPolicy or DSL validation.
- Replace URI-only embedded resource callers with actual contents or a
  revision-supported resource link. Qualify content types and retained wire
  behavior by era before migrating deprecated result helpers.
- Retire media-transform/encoding stubs and unsupported no-op operation/options
  with explicit agreed rejection behavior. Application media/EXIF processing
  has no library drop-in replacement.
- Complete runtime-mounted HTTP/store ownership and replacement startup, preserve
  optional listeners, sessions/SSE/replay/security, and verify contextual error
  codes and canonical capability initialization.
- Inventory configuration keys/options, process/registry names, telemetry events,
  callback PID/supervisor/custom-call contracts and consumer shims separately.
  Compiled symbol counts do not cover these contracts.

Preserved wire features include modern and legacy text/image/audio/resource
content where revision-supported, structured tool failures via `isError`,
canonical `structuredContent`, metadata/annotations and the existing MRTR path.
No protocol error codes, wire/storage identifiers, namespace/package ownership
or transport behavior change in this slice.

The unchanged frozen baseline SHA-256 is
`a6a952ef2483f2490c13594e1a44bc4a47f96abc9efa19ab4829984b2234f0a8`.

## Qualification

The exact source passed 34 focused cases on both minimum Elixir 1.17.3/OTP
27.0.1 and current Elixir 1.19.5/OTP 28.4.1. These are the new replacement tests,
existing DSL tests and existing structured-output tests, loaded by a pure harness
without the global test helper or its port-cleanup routine. Both toolchains
passed project warnings-as-errors compilation and formatting checks for the
owned implementation/test files. Current strict Credo checked all 638 source
files using the unchanged repository configuration and found no issues.

Each toolchain used separate copied dependency sources and build directories;
no main/canonical dependency build was reused. RPC source was extracted from
ACP commit `0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb` into each private source
cache; this additive helper slice does not change the candidate's published RPC
pin. Cached dependency compilation still emits existing dependency warnings;
project warnings-as-errors compilation passed. No network consumer, broad runtime
or port suite is claimed by this evidence.

Broader output integration must still assert safe client errors and no state
commit for malformed returns or nested bad protocol JSON. Transport, consumer
archive and all accepted retirement release gates remain outside this additive
slice.
