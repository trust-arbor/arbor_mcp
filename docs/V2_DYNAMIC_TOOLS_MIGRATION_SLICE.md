# Application-owned dynamic tools migration

This slice replaces a real `Server.Tools.Registry` consumer with a runnable
application Handler. The library does not gain another registry or tool DSL.
The example and its tests are a prerequisite for retiring the old Tools modules;
they do not make the remaining v2 release gates complete.

## Run it

From the repository, after dependencies and the application have compiled:

```sh
mix run examples/dynamic_tools.exs --demo
```

The one file defines the application Handler, its MFA actions, and a small
Runtime/Test demonstration. It registers `echo`, lists its descriptor, invokes
it through the MCP transport, prints the result, and stops its owned runtime.
An application can copy the Handler/actions into its own `lib/` directory.
Examples and repository test support are not Hex package APIs.

## State and operations

`Arbor.MCP.Examples.DynamicTools` keeps descriptors, dispatch MFA pairs, compiled
validators, explicit defaults, and business state in the same Handler state.
`Server.call/3` mutations and protocol tool calls therefore use the same
Scheduler ordering and cancellation/state-commit rules.

| Former registry operation | Application operation |
| --- | --- |
| Register one/bulk tools | `Server.call(root, {:register, entries, :reject})` |
| Explicit replacement | `Server.call(root, {:register, entries, :replace})` |
| Get descriptor | `Server.call(root, {:get, name})` |
| List descriptors | `Server.call(root, :list)` or MCP `tools/list` |
| Call a tool | MCP `tools/call` through the connected transport |
| Remove a tool | `Server.call(root, {:remove, name})` |

An entry is `{string_keyed_definition, {ApplicationModule, :function}, defaults}`.
The action receives `(arguments, host_state)` and returns an ordinary Handler
result/state tuple. Actions are trusted application code. Registering MFA pairs
avoids retaining closures and gives the application explicit dispatch ownership.
A descriptor returned by `:get` contains no dispatch function or validator.

The example admits at most 32 tools and at most 16 KiB of native term size for
one JSON descriptor/default map. It rejects opaque terms, invalid JSON strings,
unsupported dispatch, missing input schemas, and reserved transport defaults.
These are example application policy limits, not universal library defaults or
proof of bounded raw VM/OS memory.

## Defaults and validation

Defaults are a separate string-keyed application map, merged before input
validation. Explicit `false`, `nil`, and `[]` values survive. Supplied arguments
win over defaults; a supplied value must still satisfy the schema. JSON Schema
`default` annotations alone do not insert values, and strings are not coerced
into numbers or booleans.

The Handler removes reserved `_meta` and legacy `_request_id` transport fields
from tool data. Request identity, progress, cancellation, and notifications use
`Server.Context` and the existing callback scope instead. Applications should
not use transport metadata as a tool-argument schema default.

`Content.SchemaPolicy.compile/2` and `compile_optional/2` run once for each
accepted descriptor registration/replacement. List/get/call reuse the stored
opaque validators. Input and optional output use the same schema policy and
finite resolve/validation budgets. Cross-document/network references remain
forbidden unless an application deliberately supplies an approved resolver.
Wire Tool descriptors require an object input schema with root `type: "object"`
and an object output schema when present. Boolean schemas remain supported by
standalone SchemaPolicy, not as literal Tool descriptor fields. An object schema
with `not: {}` always rejects without becoming an absent validator; replacing or
removing a tool replaces or removes its associated caches.

Invalid input is a fixed protocol invalid-params error before the action runs.
An authored result that fails output validation becomes an explicit tool error,
matching the existing DSL validation policy. Unsupported result terms continue
to be rejected by result normalization/output admission rather than inspected
into wire text. Modern scalar/array structured results require the existing
modern request metadata; this slice does not widen the legacy protocol era.

## Mutation and notifications

Duplicate names reject by default. `:replace` is explicit, and duplicates within
one bulk submission still reject. Bulk construction uses a candidate state; a
bad later entry does not partially commit the catalog. Compilations made for a
rejected candidate are discarded. Removal discards its descriptor, dispatch,
validator, and defaults together.

Successful register/remove return `{:ok, notification_admission_result}`.
`Server.notify_tools_changed(self())` runs in the active callback scope and
uses the bounded existing control path. Notification admission can explicitly
return an overload error while an otherwise valid catalog mutation commits;
admission is not peer delivery confirmation. The application can surface that
result without repeating a committed mutation. A tools/list query triggered by
the notification queues on the same state owner.

A queued mutation waits for an active stateful tool. Cancelling the tool rejects
its late business-state result, then the subsequent mutation can run. Equal
tool names in different runtimes use independent catalogs. There is no runtime
global registry, cross-runtime lookup, or separate component startup.

## Migrated consumers and evidence

The former registry cache test in `schema_dialect_test.exs` now registers single
and bulk tools in the actual Handler, invokes them over Runtime/Test with modern
metadata, and checks valid/invalid array output. The fail-closed schema consumer
uses the existing DSL compilation path. Structured-result schema checks use
`Content.SchemaPolicy.validate/3` directly.

The new migration suite covers mutation/list/get/call/removal, defaults versus
annotations, duplicate/replacement/bulk atomicity, capacity/descriptor limits,
strict validation and opaque term rejection, cached compilation, independent
runtime ownership, stateful cancellation ordering, and notification pressure.

Qualification uses private supported-toolchain caches and standalone ExUnit
without repository `test_helper`, SDK fixtures, or fixed listener ports. The
source manifest records exact files and final toolchain results. Original
retired-module implementation-only tests still need removal with the production
retirement; unrelated `Arbor.MCP.Registry` behavior is outside this slice.
