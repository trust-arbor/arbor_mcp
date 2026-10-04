# Tools-family retirement checkpoint

This isolated slice starts at `f4d85342ba53e58f3d67ab12294a4eb0b87392fc`
and applies the exact frozen seven-file application-owned dynamic-tools
prerequisite before removing the accepted Tools family. The frozen 1.x API
baseline and API migration inventory remain unchanged.

## Removed source

Seven source files define eight removed modules. `Builder.Tool` is nested in
`builder.ex`; it is not another source file.

| Module | Source |
| --- | --- |
| `Arbor.MCP.Server.Tools` | `lib/arbor_mcp/server/tools.ex` |
| `Tools.Simplified` | `lib/arbor_mcp/server/tools/simplified.ex` |
| `Tools.Builder` and `Tools.Builder.Tool` | `lib/arbor_mcp/server/tools/builder.ex` |
| `Tools.Helpers` | `lib/arbor_mcp/server/tools/helpers.ex` |
| `Tools.Registry` | `lib/arbor_mcp/server/tools/registry.ex` |
| `Tools.ResponseNormalizer` | `lib/arbor_mcp/server/tools/response_normalizer.ex` |
| `Tools.ASTValidator` | `lib/arbor_mcp/server/tools/ast_validator.ex` |

The accepted inventory counts 81 removed callables and four types:
`Builder.Tool.t/0`, `Builder.Tool.param/0`, `Registry.handler/0`, and
`Registry.tool_definition/0`. There are no forwarding aliases, renamed helper
shims, replacement builder structs, or runtime global registration service.
Fresh compiled-application tests assert that every removed module is absent
and that using the old Tools DSL fails compilation.

Static definitions use the existing `Server.DSL`, including compile-time
components. Dynamic descriptors, dispatch, validators, defaults and mutations
belong to application Handler state as demonstrated by the separate frozen
`examples/dynamic_tools.exs`. Complete authored results use `Server.Result`;
standalone schema consumers use `Content.SchemaPolicy`. Default insertion and
coercion do not silently survive removal of an old helper.

## Tests and documentation

| Change | Cases |
| --- | --- |
| Delete Tools-only DSL implementation tests | 11 retired |
| Delete Tools-only helper implementation tests | 24 retired |
| Delete Tools-only response-normalizer implementation tests | 3 retired |
| Replace 1.x module/metadata presence tests with v2 absence/nonforwarding | 2 replacements |
| Keep protocol Roots/Sampling/Logging function, callback and migration checks | 2 retained |
| Migrate deprecated server's unknown-name callback and Client/Test dispatch tests to Handler+DSL | 2 retained |

The dynamic prerequisite separately adds 13 application migration tests and
migrates three existing consumer files. That source freeze stays immutable;
its tests are included in the combined retirement qualification.

The retained structured-output tests now describe current Handler/DSL coverage.
Only Tools-specific facade/server prose changes. Independent `Arbor.MCP.Registry`
source/tests and compliance `Features.Tools` are unchanged.

Searches of tracked `lib`, `test`, `examples`, and `scripts` leave retired module
names only in explicit absence/failed-use assertions. Historical docs/inventories
remain historical evidence. `mix.exs` is root-owned: its seven stale deprecated
docs-group entries must be dropped during integration, rather than overwritten
by this source overlay.

## Qualification and remaining work

Minimum/current standalone qualification includes all relevant DSL, components,
result, schema, retirement, structured-output, and protocol/execution-error
files: 180 tests, zero failures on each toolchain. These are actual Runtime/Test
and Client/Test paths where needed, without repository `test_helper`, SDK
fixtures, native helper fixtures, or fixed listener ports.

Test and production compilation use warnings-as-errors on both supported
toolchains. Formatting passes both; normal strict Credo passes 688 repository
source files. The source manifest records the final normal minimum Dialyzer
result and exact production/test/deletion hashes. Existing ignore filters are
unchanged; no warning filter is added for this slice.

Root integration still needs the whole combined suite, package/docs checks,
installed-package acceptance, and final compiled public API diff. The six
standalone HTTP export removals depend on the separate HTTP gateway cutover.
This checkpoint does not claim the entire v2 release is complete.
