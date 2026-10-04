# V2 DSL input constraints

The existing `Arbor.MCP.Server.DSL` supports numeric bounds and multiples,
string lengths and patterns, enums, array bounds/uniqueness, and object
bounds/additional-properties options. The generated descriptors contain the
standard JSON Schema keys. Literal `schema:` declarations support nested
arrays/objects and nullable properties; they replace the generated property
schema and cannot be combined with constraint options. Unknown, duplicate,
malformed and inapplicable options fail at the declaration's file and line.

Generated tool callbacks retain their compiled input schema and validate before
calling application code. Invalid arguments return protocol error `-32602`,
without invoking the tool or changing handler state. Explicit param defaults
are inserted before validation, including false, empty arrays and explicit
null. Literal schema default annotations do not insert values. Validation does
not coerce values. The existing atom-key convenience remains available to the
callback; validation uses one canonical JSON view and rejects normalized key
collisions. Framework `_meta` remains available to callbacks and is excluded
from validation against the tool's argument schema.

The source also normalizes raw Handler `structuredOutput` compatibility aliases
before applying the negotiated result-era rules. Canonical `structuredContent`
wins by presence, including false/null; modern results preserve all JSON value
kinds and legacy structured results require objects. This closes the raw
Handler alias path without changing wire protocol names.

The minimum-toolchain combined DSL/schema/result selection passes 79 cases.
Current focused selections and the complete minimum/current MCP selection pass.
The existing current schema-performance suite passes its unchanged four cases,
including the sub-0.1ms cached-validation and sub-1ms DSL callback budgets.
Both production builds compile with warnings as errors. The full release still
requires component grouping, owned dynamic-registry consumer migration,
deprecated API retirement, HTTP runtime convergence and final RC qualification.
No accepted API retirement is removed by this additive slice.
