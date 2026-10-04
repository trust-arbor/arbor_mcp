# Shared server results and structured JSON values

`Arbor.MCP.Server.Result` owns the complete-result constructors and shared
tool/resource/prompt callback normalization. DSL `ToolResult` and generated
handlers call this implementation. The existing `Server.DSL.Result` functions
forward here; there is no second normalization implementation or new result
struct. Existing map result shapes and MRTR markers remain available.

`structured/2,3` now accept plain objects, proper arrays, strings, numbers,
booleans and `nil`. `error/2` accepts the same top values through the
`:structured_content` option. Explicit `nil` emits `structuredContent: nil`;
omitting that option emits no structured field. `:is_error` remains a boolean
option, and duplicate/unknown options reject with the existing fixed error.
Top structs, PIDs, references, functions and tuples reject. Nested application
values remain unchanged until the runtime's plain-JSON output preparation
checks their shape, normalized collisions and byte limits before state commit.
No URI fetch, media inference or application encoder/Inspect protocol is added.

```elixir
alias Arbor.MCP.Server.Result

Result.structured("disabled", false)
Result.structured("no value", nil)
Result.structured("results", [1, 2])
Result.error("try again", structured_content: nil)
```

The pinned modern primary snapshot
`docs/mcp-specs/2026-07-28/schema.json`, `$defs.CallToolResult`, allows any JSON
structured value. Its `$defs.Tool.outputSchema` is an object schema that may
describe those values. The [2025-11-25 primary schema](https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolresult-structuredcontent)
requires an object for legacy structured tool content. Shared protocol
normalization therefore rejects legacy nonobject structured results before
Scheduler can commit the callback's proposed state. The helper's broader value
type does not broaden legacy wire behavior.

DSL output validation uses key presence, so `false` and null no longer bypass
a declared schema. An absent field retains the existing bypass behavior.
Normalization detects atom/string wire-key collisions before validation can
discard one spelling. Validation failures remain authored `isError` tool
results with the callback's proposed state, preserving the established DSL
contract; malformed output still fails runtime preparation without committing
state. Validation error formatting no longer calls `inspect/1` on arbitrary
validator error terms.

`Response.from_raw_response/2` gives canonical `structuredContent` precedence
by presence, including false/null, over the retained `structuredOutput` alias
and completion fallback. The existing `structuredOutput` struct field remains
the storage field, and additive `Response.structured_content/1` reads it. A
Response struct still uses `nil` for both absent and explicit JSON null; use the
client's raw map format when field presence itself matters.

The nine new cases cover actual modern and legacy runtime delivery/state
commits, rejected nested protocol data, schema false/null/array behavior,
canonical response precedence and the complete compatibility function surface.
The focused suite also includes the retained DSL, response, collision and
production output cases. Broader qualification is recorded below when complete.

This slice does not remove any of the 102 accepted callable retirements or
modify the frozen 1.x baseline. Modern default 2020-12 schema semantics,
dynamic owned registry migration, helper media/options migration, bracketed
client lifetime, stdio/HTTP delivery and complete release qualification remain
separate gates.

Root focused qualification passes **108 cases** on both minimum Elixir
1.17.3/OTP27.0.1 and current Elixir1.19.5/OTP28.4.1. This includes the retained
service restart suite; its poll now waits for an available replacement
generation instead of dereferencing temporary `:runtime_unavailable`. Broader
latest-source CI and full combined transport qualification remain separate.
