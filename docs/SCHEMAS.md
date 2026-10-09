# JSON Schema dialect and validation

Omitted and explicit JSON Schema 2020-12 declarations use JSV. Explicit drafts
4, 6 and 7 use ExJsonSchema. Unknown dialects fail compilation. No automatic
runtime input validation, default insertion or type coercion is introduced.
Use the [DSL guide](DSL_GUIDE.md) for declarations and
[API/migration guide](guides/MIGRATING_V1_TO_V2.md) for replacement semantics.

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
validation failures retain bounded property names and JSON Pointer paths without
exposing backend objects or rejected values. The projection uses JSV's public
normalization API inside the finite worker, keeps at most 16 diagnostics, and
caps each message and path at 256 bytes. Missing-property names remain useful;
other messages identify the failed keyword without echoing instance values,
constants or enum members. Oversized text uses a fixed fallback. Explicit
legacy validation retains the existing backend error list.

The new defaults are `max_instance_bytes: 1_048_576` and
`max_instance_depth: 64`, applied inside the finite validation worker. Byte
accounting charges container/key separators, binary content plus quotes,
`:erlang.external_size/1` for numbers, and five bytes for JSON literals.
It is a finite native traversal budget rather than exact serialized JSON size.
Schema preflight still bounds native/encoded bytes, depth, composition and
subschema count. Worker timeouts bound resolution/validation work; they do not
cap existing caller allocations, transient backend copies or whole-VM heap.
No arbitrary user encoder is used to determine these bounds.
