# Tagged SchemaPolicy replacement slice

This slice is integrated into the unpublished MCP v2 draft after `b240463`,
including the collision-rejecting ResultNormalizer and production output path.
It adds standalone optional schema operations and checks DSL declarations at
module compilation. It removes no public exports and leaves the frozen 1.x
baseline and supported main source unchanged. Tools retirement is still pending.

## Public contract

All signatures belong to `Arbor.MCP.Content.SchemaPolicy`.

| Operation | Contract |
| --- | --- |
| `compile(schema, opts \\ [])` | Raw plain object or boolean schema → `{:ok, ExJsonSchema.Schema.Root.t()}` or `{:error, policy_error}`. `nil` is invalid. Retain the Root unchanged for repeated validation. |
| `compile_optional(schema, opts \\ [])` | Only `nil` → `{:ok, nil}`; other schemas use ordinary tagged compilation. `false` is an always-rejecting schema. |
| `validate(data, raw_or_compiled_schema, opts \\ [])` | `:ok` or `{:error, reason}`. Policy failures are tagged; instance failures retain the validator's existing error list. `nil` is invalid. |
| `validate_optional(data, raw_or_compiled_schema, opts \\ [])` | Only `nil` bypasses. Invalid schemas and known policy-option values remain errors; `false` still rejects. |
| `preflight(schema, opts \\ [])` | Native JSON/size/depth/reference policy checks before resolution; this is not full meta-schema validation. |

The existing `SchemaValidator.compile_schema/1,2` still delegates to the same
tagged ordinary compile operation. Existing raw/compiled `validate/2,3` signatures
and Root cache representation remain compatible. Application-created or mutated
Roots are trusted compiled artifacts; the raw declaration guard does not assert
that such an artifact originated from this module.

Compilation now checks native ordinary JSON terms before Jason can see them.
Atom keys/values normalize to JSON strings; conflicting normalized keys,
non-UTF8 bytes, structs, PIDs, references, functions and improper lists reject
with fixed tagged policy messages. No application JSON/Inspect protocol runs for
raw schema normalization. The finite native walk applies byte/depth bounds to
literal default/enum/example data too, before allocating an encoded schema;
oversized binary values/keys reject by byte size before UTF-8 scanning;
JSON encoded-size, composition, subschema, reference and worker deadlines remain
in force. These bounds exclude arbitrary caller heap allocations and validator
instance-data costs. Existing timeouts remain finite worker limits, not a hard
whole-VM heap guarantee.

Every raw object, including opt-in fetched documents, is explicitly checked
against its supported draft meta-schema.
This closes ExJsonSchema's shortcut that skips meta-validation for identifiers
resembling JSON Schema's own meta-schema IDs. Invalid schema/dialect and worker
exception messages are fixed; declarations and reference values are not inspected
into policy errors. Default callback probes use `Code.ensure_compiled/1` so cold
DSL compilation cannot reject the valid default DNS/HTTP modules merely because
another compiler worker has not emitted their beams yet.

## Migration examples

The former Tools API returned a resolved value or raised; the replacement is an
explicit tagged branch:

```elixir
alias Arbor.MCP.Content.SchemaPolicy

case SchemaPolicy.compile_optional(application_schema) do
  {:ok, compiled_or_nil} ->
    case SchemaPolicy.validate_optional(arguments, compiled_or_nil) do
      :ok -> {:ok, arguments}
      {:error, reason} -> {:error, reason}
    end

  {:error, reason} ->
    {:error, {:invalid_configuration, reason}}
end
```

Literal schema maps replace schema constructors:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{"count" => %{"type" => "integer", "minimum" => 0}},
  "required" => ["count"]
}
{:ok, compiled} = SchemaPolicy.compile(schema)
:ok = SchemaPolicy.validate(%{"count" => 2}, compiled)
{:error, _} = SchemaPolicy.validate(%{"count" => "2"}, compiled)
```

`validate` does not insert schema defaults, coerce types, normalize instance keys
or return transformed arguments. Applications migrating `Tools.Helpers.validate_arguments/2`
must explicitly implement and test the default/coercion behavior they require.
Static DSL params retain their existing missing-value defaults and atom-key
convenience; this slice adds no runtime input validation or type coercion.

## DSL compiler and handler boundaries

Both generated/literal input schemas and literal output schemas are compiled
while the handler module is compiled. Invalid declarations raise a fixed
`ArgumentError` prefixed `invalid input_schema/1:` or `invalid output_schema/1:`.
The generated mapping still caches the resolved output Root; input compilation
checks descriptors without adding a runtime input validator.

The pinned primary MCP snapshot `docs/mcp-specs/2026-07-28/schema.json`,
`$defs.Tool`, requires an input **object schema with root type `object`** and an
output **object schema**. Builder preserves a supplied `false` long enough for
that declaration to fail explicitly, rather than replacing it with a generated
schema. Standalone boolean SchemaPolicy support does not imply that boolean Tool
descriptors are valid. Omitted/`nil` output schema remains an explicit bypass.

An always-rejecting object output schema is `%{not: %{}}`, rather than literal
`false` on a Tool descriptor. Actual handler tests prove it returns the existing
`isError` tool failure while retaining the callback's proposed state. Output
schema validation runs after the callback and does not undo effects. This
preserves current DSL behavior; Runtime's separate preparation and commit guards
remain responsible for malformed protocol output. No Runtime source is changed.

## Dialect and release gates

ExJsonSchema 0.10 supports drafts 4, 6 and 7 and selects draft 7 when `$schema`
is absent. Explicit 2020-12 declarations fail with a tagged unsupported-schema
error. Supported-draft meta-validation still permits unknown annotation/extension
keywords; this does not implement the semantics of 2020-12-only keywords.
The pinned modern MCP snapshot defaults tool schemas to 2020-12 and allows any
JSON `structuredContent`, so full modern-dialect validation and scalar/array/null
structured-result compatibility are distinct outstanding release gates. This
slice neither adds a validator dependency nor infers those wire features from
standalone schema validation. The prior DSL guide's full 2020-12 support claim is
corrected in this slice.

Before Tools/Schema-family removal, migrate deprecated consumers, registry/default
behavior and performance/compliance fixtures; qualify dialect semantics per era,
protocol-vs-execution error behavior, dynamic handler ownership and consumer
archives. The independent Result slice and output integration have their own
qualified paths. All 102 accepted callable retirements remain unimplemented here.
Configuration/options, public names and telemetry migration inventories are
separate from the compiled symbol manifest.

Read-only real Arbor consumer evidence remains clean master
`effc6056559513bd16ca214b5b3503eb73c9e9f1` with no relevant imports; no compatibility
shim is inferred from that absence. The frozen baseline SHA-256 remains
`a6a952ef2483f2490c13594e1a44bc4a47f96abc9efa19ab4829984b2234f0a8`.

## Qualification

The exact source passed **34 pure cases** on minimum Elixir 1.17.3/OTP 27.0.1
and current Elixir 1.19.5/OTP 28.4.1. The cases include this slice's native/tagged
policy checks, live custom-encoder positive control, local and injected remote
resolution, real invalid-declaration compilation, handler validation/state
semantics, and retained DSL/structured-output cases. The harness omits the global
test helper and process/port cleanup, starts no protocol servers, and does not
modify application resolver configuration. Remote callbacks return fixture data;
no real DNS/HTTP request occurs.

Both toolchains passed forced project warnings-as-errors compilation (329 project
files) and owned-file formatting. Current strict Credo checked all 650 source
files with unchanged configuration and found no issues. Each toolchain used
independently copied dependency sources/builds and tracked RPC source
`0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb`; no canonical/main cache was reused.
Cached dependency compilation still emits existing dependency warnings; project
warnings-as-errors passes without suppression. Exact owned-path hashes and
independent logs accompany the immutable freeze. Broad transport/application,
consumer archive, full modern-dialect and throughput gates remain separate.

Root integration passed the same 34 focused cases on both supported toolchains.
The complete minimum/current selections with production output/startup
integration pass 4,008 executed tests, 20 doctests and 34 properties, zero
failures (82 excluded; 4,090-test inventory).
Minimum forced project compilation checks 330 files with warnings as errors and
owned-file formatting passes. Normal commit hooks pass with 35 existing dev warnings filtered and no added
filters. Complete fresh remote CI on the schema source remains separate from
the fully passing earlier `b240463` checkpoint.
