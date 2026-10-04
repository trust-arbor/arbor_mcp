# v2 API Migration Baseline

- **Status:** Frozen current 1.x symbol baseline; runtime and migration decisions remain separate
- **Source:** `1808c56bd4fc7b000043c2775f61ecced6ed059f` (production code through `e4d2fc3`)
- **Package metadata:** `ex_mcp` `1.5.0`, including integrated unreleased work
- **Manifest:** [api_baseline_1_5_plus.json](./v2/api_baseline_1_5_plus.json)
- **Toolchain:** Elixir `1.19.5`, OTP `28`, Mix environment `dev`
- **Related:** [V2_ROADMAP.md](./V2_ROADMAP.md), [historical API census](./API_DIFF_RC5_TO_1_0.md)

The proposed [v2 migration inventory](./V2_API_MIGRATION.md) and
[machine-readable removal plan](./v2/api_migration_plan.json) now cover the
compiled deprecations and accepted retirement families. They distinguish
namespace/package moves from removals and list replacement prerequisites;
configuration/options/process-name/telemetry inventories and the final compiled
v2 diff remain separate release gates. The frozen snapshot below is unchanged.

## Purpose and scope

This snapshot makes the starting Elixir surface for the full v2 migration
reproducible. It is not the historical `v1.5.0` artifact: the source includes
unreleased adapter, security and lifecycle changes integrated afterwards.
Preserve this file when new v2 snapshots are generated. Rebaseline only through
an explicit release decision, with the reason and API delta recorded.

The method follows the conservative rc.5-to-1.0 census: include every compiled
application module whose compile source is under `lib/`, even if HexDocs hides
it. This retains evidence of reachable internals and compatibility names
without declaring each one a supported public API. `dev/`, `test/`, dependencies
and the new census tooling are excluded by source location.

## Snapshot totals

| Surface | Count |
|---|---:|
| Compiled `lib/` modules | 341 |
| Modules with module documentation | 227 |
| Raw exports, excluding `module_info/*` and `__info__/1` | 3,137 |
| Elixir callable functions | 3,022 |
| Elixir callable macros | 96 |
| Callbacks and macrocallbacks | 136 |
| Public and opaque named types | 653 |
| Structs / struct fields excluding `__struct__` | 63 / 629 |
| Modules with compiled deprecation metadata | 2 |
| Functions/macros with compiled deprecation metadata | 31 |

Raw exports include generated struct/protocol/behaviour helpers and compiled
`MACRO-*` exports. Callable macros record the source-level name and arity.
The categories overlap; function, macro and callback totals are not expected
to sum to the raw export count.

## Reproduction

The repository-only task compiles the project and reads its application module
inventory, BEAM docs and typespecs. It does not start the application, listeners
or vendor CLIs. With the recorded toolchain and `lib/` matching the source ref:

```sh
MIX_ENV=dev mix mcp.api_manifest \
  --source-ref 1808c56bd4fc7b000043c2775f61ecced6ed059f \
  --output docs/v2/api_baseline_1_5_plus.json --check
```

`--check` compares complete bytes and writes nothing. Omit it only to reproduce
the frozen file deliberately. An explicit source ref rejects changed or
untracked `lib/` sources. Repository-only tool/docs/test edits do not alter the
snapshot. JSON keys and collections are sorted; timestamps and absolute paths
are excluded. Compiler versions and Mix environment are recorded because
typespec rendering can change between toolchains.

To capture a later implementation for comparison without replacing the baseline:

```sh
MIX_ENV=dev mix mcp.api_manifest --output /tmp/ex_mcp_api_candidate.json
```

Without `--source-ref`, tracked or untracked `lib/` changes produce a
`+working-tree` source label. Every selected source file has a SHA-256 digest;
the aggregate digest binds sorted relative paths to their contents.

## Manifest schema and interpretation

Schema version `1` contains `baseline`, `scope`, `summary`, `sources` and
`modules`. Each module records its relative source, documentation visibility,
exports, callable functions/macros, callbacks with optional status and normalized
definitions, public/opaque types with normalized definitions, and struct fields.
Private `@typep` definitions are excluded. Missing documentation or typespec
chunks fail the census instead of silently dropping evidence.

Compiled `@deprecated` / module deprecation messages are recorded verbatim.
Lower default arities retain their compiled deprecation and inherit the
documented maximum-arity entry. `documentation_notices` additionally retains
original documentation paragraphs mentioning deprecation/removal. These notices
can describe protocol features, examples or future plans: they are evidence to
review, not automatic removal decisions. In particular, they must not turn MCP
wire deprecations into unrelated Elixir symbol removals.

For the v2 diff, review module/name ownership and replacement mappings first,
then compare exports/macros, named types and definitions, callback contracts,
struct fields and accepted deprecation removals. Package/namespace movement must
be distinguished from an API disappearing without a replacement.

## Limits and validation

This symbol inventory does not prove callback process identity, links, timeout,
cancellation, state ordering, configuration precedence, telemetry, wire behavior,
or restart/storage semantics. Those need the runtime characterization tests,
package/runtime contracts and release gates in the roadmap.

Focused generator tests cover hidden source inclusion, tooling exclusion,
default-arity deprecations, macro exports, optional/macro callbacks, public/opaque
types, struct fields, stable encoding and removal of absolute source paths:

```sh
mix test test/ex_mcp/api_manifest_test.exs
```

The source baseline and manifest stay immutable while the implementation evolves;
the final 1.x release may require an additional explicitly named snapshot if more
compatible changes are accepted before the v2 migration comparison is finalized.
