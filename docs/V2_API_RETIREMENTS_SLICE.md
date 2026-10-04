# First v2 API retirements

The candidate removes 15 of the 102 accepted callable retirements. Default
arities count separately. The remaining 87 are the 81-callable Tools family
and six HTTP wrapper/startup signatures; their consumer and transport
prerequisites remain release gates. The ten planned whole modules and four
Tools types are still present.

The frozen 1.x API baseline is unchanged at SHA-256
`a6a952ef2483f2490c13594e1a44bc4a47f96abc9efa19ab4829984b2234f0a8`.
The [machine-readable plan](./v2/api_migration_plan.json) records the exact
removed members and partial qualification. A final compiled diff across all
four installed packages remains required.

## Removed members and migration

| Candidate module | Removed signatures | Migration |
|---|---|---|
| `Arbor.MCP.Content.Builders` | `resize/3`, `compress/1,2` | Process media in the application; retain image/audio content construction. |
| `Arbor.MCP.Content.Sanitizer` | `remove_metadata/1` | Change application metadata explicitly; perform EXIF processing before content construction. |
| `Arbor.MCP.Content.Transformer` | `convert_encoding/1,2`, `compress_image/2,3`, `resize_image/3`, `generate_thumbnail/2,3` | Decode and process media in the application. |
| `Arbor.MCP.Protocol.ErrorCodes` | `legacy_consent_required/0`, `resource_not_found/0`, `url_elicitation_required/0` | Use local `consent_required/0`, explicit negotiated-era resource codes, and legacy-only URL codes or modern MRTR. |
| `Arbor.MCP.Protocol.VersionNegotiator` | `build_capabilities/1` | Build a complete canonical initialization result and a version-aware capability map. |

Removed transformation tokens return a fixed tagged error; removed sanitization
tokens raise a fixed `ArgumentError`. Both validate the entire operation list
before invoking any custom step. Atom and tuple forms reject regardless of the
content type. Unknown experimental behavior in the retained content APIs is
outside this selected retirement slice.

All file builders reject `:auto_resize` and `:quality` by presence before using
the file path, including explicit false/null values. Automatic file loading
also enforces `:mime_types`, which was advertised but previously ignored. Size
checks, metadata and original bytes remain covered.

## Qualification

The combined minimum/current selection passes 444 tests and eight properties
on each toolchain with zero failures. It covers 17 new component cases,
retained DSL constraints/defaults/results, strict media rejection before custom
effects or file reads, retained content loading, explicit legacy/modern error
codes, and migrated version-specific initialization/property consumers.
Production compilation with warnings as errors passes on both toolchains.

`test/arbor_mcp/protocol/api_retirement_test.exs` verifies the exact 15 compiled
exports are absent and retained APIs remain available. The legacy initialization
fixture uses canonical string-keyed results and capability maps; it retains
legacy revision behavior and never advertises the modern revision through
legacy negotiation. Final full-suite, static, archive and RC qualification are
separate gates.
