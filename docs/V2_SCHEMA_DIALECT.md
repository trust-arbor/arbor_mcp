# JSON Schema dialect replacement

This unpublished v2 slice makes omitted and explicit JSON Schema 2020-12
declarations use a 2020-12 validator. Explicit drafts 4, 6 and 7 keep their
ExJsonSchema backend and unchanged compiled Root caches. Unknown dialects fail
compilation. No public exports are removed, and neither the frozen 1.x API
baseline nor the supported 1.x source changes.

This document supersedes the legacy-only backend/cache descriptions in
`V2_SCHEMA_REPLACEMENT_SLICE.md`; that document still describes the tagged API,
DSL descriptor checks and unresolved Tools migration. This slice does not add
automatic runtime input validation, default insertion or type coercion.

## Backend and provenance

The pinned MCP snapshot `docs/mcp-specs/2026-07-28/schema.json` specifies
2020-12 as the default Tool-schema dialect. Upgrading ExJsonSchema alone cannot
satisfy that contract: its upstream implementation supports drafts 4, 6 and 7.
[ExJsonSchema source](https://github.com/jonasschmidt/ex_json_schema)

JSV 0.25.0 is a pure Elixir implementation supporting 2020-12 and draft 7,
with embedded standard meta-schemas and Elixir 1.15 as its minimum. Its versioned
source is pinned to commit `44053ef7f3e4cacbfb8df2ce50cdee5d9aed9689`.
It supplies the missing dialect without a native validator, external process,
application-defined resolver or casting hook.
[JSV 0.25.0 source](https://github.com/lud/jsv/tree/v0.25.0),
[JSV API](https://jsv.hexdocs.pm/JSV.html),
[published package](https://hex.pm/packages/jsv/0.25.0)

The dependency declaration is `{:jsv, "~> 0.25.0"}` through the existing
`external_dep/2` helper. The resolved graph adds only these four applications;
existing Jason, Decimal and NimbleParsec resolutions remain unchanged.

| Package | Version | Hex tarball checksum |
| --- | --- | --- |
| jsv | 0.25.0 | `d8b207d0c7d341c77e6a0732712dd754c10476acb49825cdc1b5b44ff7f4ee86` |
| abnf_parsec | 2.1.0 | `e0ed6290c7cc7e5020c006d1003520390c9bdd20f7c3f776bd49bfe3c5cd362a` |
| idna | 7.1.0 | `6ae959a025bf36df61a8cab8508d9654891b5426a84c44d82deaffd6ddf8c71f` |
| texture | 2.0.0 | `c85cbac5f456f4c9867deb0f70c45daa8a536142a8c8c5403401bd51962660bc` |

`mix.lock` also records the package contents checksums and requirement graph.
Fresh normal Hex resolution preserves every unrelated lock entry. Qualification
uses independent source-only dependency copies and tracked RPC source
`0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb` for each toolchain.

## Public compilation and validation

`Arbor.MCP.Content.SchemaPolicy` retains its tagged public operations:

| Operation | Behavior |
| --- | --- |
| `compile(schema, opts \\ [])` | Plain object/boolean declaration → `{:ok, compiled}` or a fixed tagged error. `nil` is invalid. |
| `compile_optional(schema, opts \\ [])` | Only `nil` → `{:ok, nil}`. `false` is compiled and rejects every instance. |
| `validate(data, raw_or_compiled, opts \\ [])` | `:ok` or `{:error, reason}`; returns no transformed data. |
| `validate_optional(data, schema, opts \\ [])` | Only absent `nil` bypasses; other declarations and instances use ordinary validation. |
| `preflight(schema, opts \\ [])` | Native declaration/resource/reference policy checks; does not promise full meta-schema validation. |

An omitted `$schema`, a boolean schema, or
`https://json-schema.org/draft/2020-12/schema` (with an optional terminal `#`)
uses JSV. Explicit canonical draft-04, draft-06 and draft-07 metadata URIs
use ExJsonSchema. The historical `http://json-schema.org/schema` alias remains
draft 7. Other dialect URIs, including 2019-09 and custom meta-schemas, reject
explicitly. Adding a supported vocabulary/dialect requires an assessed backend
and policy change.

Modern compilation returns `SchemaPolicy.compiled()`, an opaque artifact owned
by the private `SchemaPolicy.Compiled` module. Cache and pass it unchanged;
do not pattern-match its representation. Explicit legacy compilation returns
the existing `ExJsonSchema.Schema.Root.t()`. Unchanged legacy Roots, including
application-created Roots, remain trusted compiled artifacts; the declaration
guard does not authenticate or reconstruct arbitrary caller-created caches.
The retained Tools.Registry now tests only absent `nil` when storing a cache,
so minimum OTP can preserve this opacity without changing registry behavior.

```elixir
alias Arbor.MCP.Content.SchemaPolicy

schema = %{
  "type" => "array",
  "prefixItems" => [%{"type" => "integer"}],
  "items" => false
}

{:ok, compiled} = SchemaPolicy.compile(schema)
:ok = SchemaPolicy.validate([7], compiled)
{:error, _} = SchemaPolicy.validate([7, 8], compiled)
```

Applications requiring old default-draft semantics must declare their intended
legacy `$schema` explicitly. Default 2020-12 makes keywords such as `prefixItems`,
`unevaluatedProperties`, `dependentSchemas`, `minContains` and `$dynamicRef`
meaningful. Existing input descriptor maps and static DSL params keep their
wire shapes; literal Tool input schemas still require root `type: "object"`
and Tool output schemas still require an object declaration. Standalone boolean
schemas do not make boolean Tool descriptors valid.

Modern `format` uses the standard annotation behavior; the default 2020-12
meta-schema does not assert email/URI/etc. Explicit legacy schemas retain their
backend's existing format behavior. No casting/default insertion is enabled,
and backend-produced transformed values are discarded. `SchemaValidator` keeps
its existing atom-to-string content convenience after the bounded native
instance check; ordinary `SchemaPolicy.validate` does not normalize instance
keys or values.

## Reference and extension security

Resolution remains network-disabled by default, including relative
cross-document references. Fragment references, anchors and dynamic anchors
inside a document work. The existing policy conservatively rejects URI-named
embedded-resource references too, even when a validator could resolve them
without a request. Opt-in network resolution keeps host allowlisting, public-IP
checks, DNS pinning, redirect revalidation and finite document/depth/response/
aggregate/time budgets. Fetched documents are local to one compilation and are
not globally cached. Both `$ref` and `$dynamicRef` use that same fetch policy.

JSV appends an internal module resolver and its cast vocabulary even when
instance casting is disabled. Those paths can call application code while
building a schema. The policy scans each complete root and fetched document
before building, including explicit-legacy documents used by a modern root and
objects under literal `const`, `default` or annotations that a reference might
target. It rejects `jsv-cast`/`x-jsv-cast` keys, file/local/jsv reference schemes,
JSV/file/local `$id` bases, and unknown required vocabularies. This deliberately
also rejects otherwise inert occurrences of those reserved extensions.
Ordinary annotations such as `x-mcp-header` remain valid.
[JSV internal resolver](https://github.com/lud/jsv/blob/v0.25.0/lib/jsv/resolver/internal.ex),
[JSV cast vocabulary](https://github.com/lud/jsv/blob/v0.25.0/lib/jsv/vocabulary/cast.ex)

Only prefetched policy-approved documents and bundled standard meta-schemas
are exposed to JSV's resolver. No application resolver, default HTTP resolver,
module-based schema or custom format/vocabulary module is configured. Every
raw/fetched declaration still undergoes its supported meta-schema check; an
identifier resembling a standard meta-schema cannot bypass that check.

Instance validation checks native plain JSON terms before invoking a backend.
Structs, PIDs, references, functions, improper lists, invalid UTF-8, unsupported
keys and conflicting atom/string aliases reject with a fixed safe message.
No application Jason, Inspect or Enumerable implementation is invoked. Modern
validation failures use a fixed error list without exposing backend objects;
explicit legacy validation retains the existing backend error list.

The new defaults are `max_instance_bytes: 1_048_576` and
`max_instance_depth: 64`, applied inside the finite validation worker. Byte
accounting charges container/key separators, binary content plus quotes,
`:erlang.external_size/1` for numbers, and five bytes for JSON literals.
It is a finite native traversal budget rather than exact serialized JSON size.
Schema preflight still bounds native/encoded bytes, depth, composition and
subschema count. Worker timeouts bound resolution/validation work; they do not
cap existing caller allocations, transient backend copies or whole-VM heap.
No arbitrary user encoder is used to determine these bounds.

## Qualification and remaining release gates

The tracked corpus contains 23 official 2020-12 files, 245 groups and 807 cases
from JSON Schema Test Suite commit
`5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8`, with its MIT license and provenance.
803 cases check the official semantic result. Four URI-named embedded-resource
cases explicitly check the retained `:network_ref_forbidden` policy. None are
silently skipped. This is a selected core-keyword corpus, not the entire
official suite or a claim of unrestricted JSON Schema conformance.
[Pinned official suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite/tree/5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8/tests/draft2020-12)

The exact source passes **880 pure cases** on minimum Elixir 1.17.3/OTP 27.0.1,
current Elixir 1.19.5/OTP 28.4.1 and newest Elixir 1.20.3/OTP 29.0.5: 73
focused cases plus the 807 corpus checks above. Focused tests cover actual DSL compilation/cached output validation,
legacy caches, single/bulk registry caches, reserved build callbacks,
allowlisted dynamic references/remote booleans, arbitrary instance protocols,
meta-validation and finite instance limits. Pure harnesses omit the global
test helper and application startup. All three toolchains pass forced project
warnings-as-errors compilation (335 files) and full formatting. Current strict
Credo checks 660 source files with unchanged configuration and reports no issues.
Normal test-environment Dialyzer passes on current/minimum with the existing
filters only (73/67 filtered warnings respectively, zero unfiltered warnings);
no new filter is added. This does not claim those toolchain totals are identical
to a different environment's prior warning inventory. Exact paths, base hashes,
lock delta and logs accompany the immutable source manifest. Full application,
security/conformance and consumer-archive gates remain for combined integration;
they are not inferred from the pure corpus.

The root-owned scalar structured-result/unified Result slice remains separate.
Before release, qualify their combined era/descriptor/output boundaries,
normal external package/archive graphs with the four new dependencies, security
and modern conformance suites, and same-runner throughput/pressure. No Tools
exports are retired by this change; all accepted retirement and dynamic
registry/default/coercion migration work remains governed by
`V2_API_MIGRATION.md`. The frozen 1.x baseline SHA-256 remains
`a6a952ef2483f2490c13594e1a44bc4a47f96abc9efa19ab4829984b2234f0a8`.
