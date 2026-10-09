# API compatibility fixtures

`api_baseline_1_5_plus.json` records the frozen ExMCP 1.5 API with integrated
maintenance work. `api_migration_plan.json` records accepted removals, replacements
and facade-boundary cleanup. Keep baseline identities and retirement decisions
when updating these regression inputs.

Run `mix run scripts/check_v2_api_retirements.exs --complete` against compiled current source.
Generate a current census with `mix mcp.api_manifest --output _verification/api_current.json`.
The baseline is evidence, not the current public API. Reader documentation lives
in [the public API reference](../../../docs/API_REFERENCE.md) and
[the migration guide](../../../docs/guides/MIGRATING_V1_TO_V2.md).
