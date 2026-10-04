# Compile-time DSL components

This isolated slice adds compile-time grouping to the existing `Arbor.MCP.Server.DSL`.
It does not create another declaration language or a runtime component registry.

```elixir
defmodule MyApp.SharedTools do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL

  tool "echo" do
    param :message, :string, required: true
    run fn %{message: message}, state -> {:ok, message, state} end
  end
end

defmodule MyApp.Server do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL,
    name: "my-app",
    version: "2.0.0",
    components: [MyApp.SharedTools]
end
```

The host starts one Runtime and initializes only its own handler. A component is
never started or initialized as a side effect of inclusion. Each inherited callback
receives the current host state and the same callback context as a local declaration.
Authors must make component handlers compatible with that shared state shape.
Component server information and startup configuration do not override the host.

## Compilation and dispatch

Every DSL module exports an internal, versioned `@doc false`
`__mcp_dsl_component__/0` descriptor. It contains primitive definitions, declaring
module and identity, and declaration file/line. It excludes handler AST, initialization,
startup options and server information. The host compiles its descriptor and routing
once, then delegates inherited primitives directly to their declaring module's
existing generated callback. Private helpers, lexical aliases, compiled input/output
validators, explicit defaults and result normalization remain in that module.
Inherited validators and handler bodies are not copied or compiled again by the host.

Nested components flatten once. Ordering is component-list order, each component's
already-flattened declaration order, then local host declarations. Repeated inclusion
is a compile error, rather than silent deduplication. Duplicate tool/prompt names,
static resource URIs and resource-template URIs fail with both declaration locations.
Components are trusted application modules; the internal descriptor is not a boundary
for untrusted same-VM code.

Tools, resources, resource templates and prompts all participate. Host capabilities
include inherited primitive kinds. Existing static-resource precedence and ordered
template matching remain intact. Existing input rejection, authored tool errors,
output validation failures and handler state semantics are preserved.

## Qualification

The slice runs standalone ExUnit through `mix run --no-start`, without the shared
`test_helper`, native subprocess helper or fixed HTTP ports. New cases cover:

- Nested, same-file and lexical-alias composition; malformed/versioned descriptors.
- Duplicate identities for every primitive and precise declaration/use locations.
- Private helpers, local aliases, schema metadata, false/null/list defaults,
  precallback input rejection and output/authored errors.
- Actual Test/BEAM Runtime initialization, shared state, sequential batch effects,
  scoped helper controls and cancellation, with one inherited callback invocation.
- Resource and prompt calls through the actual root preserving shared state.

Retained DSL declarations, compile errors, parameter constraints and result
replacement tests are included in the same qualification. This slice depends on the
parent's current DSL/Builder/ParamSchema/Result validation baseline; its handoff is an
additive patch against that baseline, not a replacement of those owned changes.

Dynamic registry consumers, runtime additions/removals, list-change publication,
whole-suite integration and installed-package acceptance remain separate gates.
Final standalone selections pass on Elixir 1.17.3/OTP 27.0.1 and Elixir
1.19.5/OTP 28.4.1: 57 cases each (17 grouping cases and 40 retained DSL cases),
zero failures. Test and production warnings-as-errors compilation and owned-file
format checks pass on both toolchains. Current strict Credo finds no issues in
667 files. Actual minimum Dialyzer analysis passes with 67 pre-existing filtered
warnings and one unnecessary skip; no warning filters were added. Its runner
preloads OTP's `prettypr` beam because Mix prunes that path before diagnostics.

The Runtime substrate is immutable commit `12b523f2ff91ac6279fa4c2a2f45f6d878d66e8f`;
the source prerequisites are listed in the base manifest. Tests use the supported
explicit callback Runtime helper target in this substrate; the parent's newer
`self()` helper resolver is independent and must be preserved during integration.
Exact hashes and commands accompany the frozen source manifest.
