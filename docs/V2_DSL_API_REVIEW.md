# DSL and public API review before the release freeze

Reviewed October 7, 2026 against MCP `0812257`, ACP `7e299f8` and RPC
`d2a6fcf`, plus the independent-version/documentation preparation. This is a
source review and a proposed release disposition, not a Spark migration or a
new compiled API freeze. Existing compatibility evidence retains its sources.

## Canonical entrypoint follow-up (October 8)

Client and Server now own ordinary operations and lifecycle. New explicit
Client extraction helpers preserve the old root facade result behavior without
changing Client's full-response aliases. Root operations remain compatibility
wrappers. Server starts plain/DSL handlers across all four transports through
one dispatcher, with supervisor child specs and bounded Runtime shutdown/stats.
Client status uses tagged errors and an explicit bang; a scoped probe differs
from an existing connection's wire ping. ACP retains Client/Agent roles and
adds the matching Agent stop reason/options form. The migration guide records
the canonical entrypoints and legacy semantic differences. Spark stays deferred.
Validation of this follow-up is recorded separately from earlier checkpoints.

## Implemented release changes

The focused cleanup below is implemented for ArborMCP `2.0.0-rc.2` and
ArborRPC `1.0.0-rc.1`. The findings later in this document describe the reviewed
source before these corrections. Spark remains deferred; no dependency or
prototype is included.

- Invalid declarations now raise compile errors with source locations:
  duplicate parameters/arguments, repeated scalar instructions, stray nested
  instructions, unknown/duplicate `use` options and metadata ignored by its
  declaration owner. Valid declaration syntax and callback contracts remain.
- Twenty-one MCP facade signatures and two RPC generic-call signatures moved
  to internal owners. Client request/connection helpers, DSL validators, result
  normalization and Runtime ingress/startup no longer appear on public facades.
  Cross-module implementation functions remain callable in internal modules;
  those modules are not supported extension APIs.
- Advanced Runtime admission, request, await, cancellation and statistics
  operations remain supported and now have explicit function documentation.
- Facade disconnect uses Client's bounded cleanup, reports cleanup errors and
  remains idempotent after shutdown. Ping reports cleanup failure even after a
  successful connectivity check. The facade no longer advertises fallback for
  its first-transport-only connection behavior.
- The dynamic tools example now owns its action-result handling and uses public
  Result constructors rather than a framework normalization helper.

The migration guide and machine-readable API plan record the exact removals.
Compiled negative-export tests guard these boundaries. The full MCP suite
passed with 5,420 tests, 20 doctests and 34 properties (207 existing exclusions);
the RPC suite passed with 115 tests. These source checks do not replace the
installed four-package checks, CI matrix, downstream testing or final soak.

The October 8 API consistency pass also corrects resource `contents` extraction,
complete response conversion, facade request-control forwarding and normalized
tool-error handling. Operational status/statistics now use tagged successes;
explicit bang variants provide value-or-raise inspection. ACP setters accept
caller timeout options, and Client gains bounded stop with cleanup receipts.
The migration guide records these behavioral changes. The unused Response
`to_test_map/1` is the additional removal, bringing the facade cleanup to 24
signatures across MCP and RPC. Spark and further performance work remain deferred.

The package split and runtime/scheduler are implemented. I recommend a small
DSL correctness and facade-boundary pass before the next candidate. Keep the
current declaration syntax while evaluating Spark separately. No further
performance experiment is required for this review.

## Spark fit

Spark is independent of Ash; its current repository manifest requires Elixir
`~> 1.16` and does not depend on the Ash framework. Its production dependencies
are optional tooling packages, so adopting Spark does not imply adding Ash's
resource/database stack. These are facts about the reviewed manifest, not a
measurement of our resulting dependency or compile footprint.
[Manifest](https://github.com/ash-project/spark/blob/main/mix.exs).

Spark supplies declarative sections/entities, option schemas, identifiers,
compile-time transformers, persisted derived data, post-compilation verifiers,
generated information accessors, documentation and editor/formatter integration.
It can replace substantial parsing and validation infrastructure; it does not
replace MCP schemas, handler dispatch, deadlines, ownership or the scheduler.
[Tutorial](https://github.com/ash-project/spark/blob/main/documentation/tutorials/get-started-with-spark.md),
[extension processing](https://github.com/ash-project/spark/blob/main/documentation/how_to/writing-extensions.md),
[entities](https://github.com/ash-project/spark/blob/main/lib/spark/dsl/entity.ex).

| Concern | Current ArborMCP DSL | Spark opportunity / required proof |
| --- | --- | --- |
| Declaration syntax | Four primitives with nested metadata and handlers | Entities can describe this structure; preserve existing syntax and callbacks |
| Validation | Custom literal parser, instruction checks and ParamSchema | Replace generic option checks while keeping JSON Schema and wire semantics |
| Composition | Reusable components retain their lexical handlers and receive host state | Prove ordering, aliases, nested components and single host initialization |
| Introspection | Hidden component descriptors and generated callbacks | A stable Info API could decouple integrations from generated implementation names |
| Developer tooling | Hand-maintained guides and macro imports | Generated DSL documentation, autocomplete and formatting are the strongest immediate benefits |
| Runtime | Compiled Handler callbacks feed the existing Runtime | Generate the same callbacks; do not add a request-time interpreter |

Our implementation is 1,724 lines across DSL and its helpers (1,172 in the main
module). Some of that is MCP-specific callback generation and would remain.
Replacing the framework is therefore more than swapping a parser dependency.
In particular, Spark documents fragments as organization within one DSL rather
than general cross-instance sharing; our reusable component contract needs an
explicit extension/delegation design, not a mechanical fragment conversion.
[Fragment guidance](https://github.com/ash-project/spark/blob/main/documentation/how_to/split-up-large-dsls.md).

Recommendation: retain today's DSL for this release, fix its concrete boundary
issues, and evaluate a Spark frontend against the same Handler/Result contracts.
If that experiment preserves syntax, ordering, source diagnostics, lexical
closures, host state, minimum/latest toolchains and installed releases, adopting
it later can be an implementation change rather than a new public language.
An optional server-DSL addon is also possible, especially if the wider Arbor
family adopts Spark. No Spark dependency or performance benefit is claimed now.

## DSL issues worth addressing before the freeze

Compile-only probes confirmed all six examples below currently compile:
duplicate tool parameters, duplicate prompt arguments, repeated title,
a stray title, an unknown `use` option and ignored tool `name` metadata.
The probes did not start the application or change runtime code. Focused
regression checks are required when these behaviors are corrected.

| Issue | Source evidence | Recommended behavior |
| --- | --- | --- |
| Duplicate parameter/prompt-argument names | `parse_instructions/3` accumulates declarations; `Builder.schema_from_params/1` uses `Map.new/1` | Reject duplicates at declaration locations rather than silently collapsing properties |
| Repeated scalar instructions | `parse_instruction/4` stores metadata with `Map.put/3` | Reject repeated title/schema/etc. unless an explicit merge/override contract is provided |
| Stray nested instructions | `param`, `run`, `title` and other imported macros return `:ok` outside a declaration | Raise a useful compile error outside their valid block |
| Unknown `use DSL` options | `__using__/1` reads selected options without a whitelist | Reject misspelled or unsupported options with file/line information |
| Contextually meaningless metadata | `assert_instruction_allowed!/4` permits `name` for every primitive; tool/prompt builders do not consume it | Restrict instructions to owners that actually use them |

Preserve existing no-coercion validation, explicit false/null/default semantics,
compiled schemas, deterministic component order and host-owned state. Keep
dynamic registration separate from static compile-time composition. Broad new
DSL features are not needed merely to justify a major version.

## Public API and facade findings

The top-level `Arbor.MCP` parsing/content helpers are already `defp`.
`Arbor.ACP` exposes only its three intended entry points: `start_client/1`,
`start_agent/1` and `run_agent/1`. Required GenServer/Supervisor/behaviour
callbacks and generated cross-module component callbacks legitimately need
exports; they should not be treated as public convenience APIs.

However, `@doc false` alone does not make an ordinary function private. The
following implementation bridges remain exported on documented API modules:

| Module | Helpers to move behind an internal module boundary |
| --- | --- |
| `Arbor.MCP.Client` | `connection_options/2`, `start_scoped/3`, `parse_connection_spec/1`, `prepare_transport_config/1`, `make_request/5` |
| `Arbor.MCP.Server.DSL` | `prepare_tool_arguments/3`, `validate_tool_response/2` |
| `Arbor.MCP.Server.Result` | `normalize_tool/2`, `normalize_tool_result/1`, `normalize_resource/4`, `normalize_prompt/2` |
| `Arbor.MCP.Server.DSL.Result` | Hidden forwarding signatures for those normalizers |
| `Arbor.RPC.Subprocess` | Generic actor `call/2,3`, used by FramedStream |

The current compiled MCP census and direct export probes confirm these MCP
helpers and the RPC generic calls remain callable. The Client parser/config
exports include helpers explicitly exposed for testing; request dispatch also
has callers in extracted operations and notification workers. Tests should
exercise those internal owners or the supported facade after relocation.

Runtime needs a separate boundary decision. `start_configured/3` and the
reserve/publish/dispatch/discard ingress helpers are transport implementation
bridges. Low-level `request`, `submit`, `await` and cancellation operations are
hidden in function docs but described in Runtime's module documentation.
Do not indiscriminately remove them as leaks: explicitly document the supported
advanced operations, and move implementation-only startup/ingress hooks behind
an internal boundary. Required supervisor callbacks remain exported.

Cross-module calls prevent simply changing these definitions to `defp`.
Relocate them into explicitly internal modules and update framework callers;
keep constructors and documented user operations on the facades. Record the
removed facade exports in the API migration plan and add a negative export
check so future helper extraction does not reintroduce them. A public result
or protocol helper with an actual documented consumer contract must not be
hidden merely because framework code also calls it.

Two additional facade corrections merit release work:

- `Arbor.MCP.disconnect/1` directly calls `GenServer.stop/2` and catches every
  exit as `:ok`. `Arbor.MCP.Client.stop/2` instead uses bounded cleanup and
  reports cleanup failure. Route facade shutdown through the owned Client
  operation; define idempotent already-stopped behavior without hiding a real
  cleanup failure. Review facade `ping/2`'s cleanup path at the same time.
- `Arbor.MCP.info/0` advertises `:transport_fallback`, although `connect/2`
  deliberately selects only the first item in a transport list. Remove the
  inaccurate capability claim. Do not introduce implicit retry/failover of
  operations with uncertain delivery as a release convenience.

Use Client as the full protocol API, Server/Runtime for host operations,
Handler for callbacks and Result for constructors. Keep top-level convenience
functions' normalization explicit; they should not silently discard structured
data when applications opt into complete protocol results. Review documented
options, error/return types and examples alongside the export inventory.

| Package | Public contracts to preserve and make explicit |
| --- | --- |
| ArborMCP | Client protocol operations; scoped connections; Server/Runtime host operations; Handler callbacks; Result constructors; explicit raw/structured result formats |
| ArborRPC | Opaque subprocess handles; finite writes/cleanup receipts; framed pull/acknowledged push; framing and JSON-RPC envelope helpers |
| ArborACP | Client session lifecycle and prompts; Agent callbacks and client requests; Adapter extension behavior; cancellation and session cleanup semantics |
| ACP Adapters | Named adapter modules and their declared Adapter callbacks; provider-specific configuration; internal provider translation helpers remain unsupported implementation modules |

No additional broad convenience API family is justified by this review. Before
freezing, verify documented options and defaults against implementation, make
error/return contracts consistent with finite cleanup, and regenerate the
four-package compiled migration diff. The new MCP-only census is evidence for
this review, not a substitute for that installed four-package release gate.

## Proposed release disposition

Do the facade cleanup and focused DSL validation before publishing the final
candidate. Keep Spark adoption open as a separate design choice, backed by a
compatibility prototype rather than assumed parity. Then regenerate the API
inventory, migration diff and exact source/archive qualification. Material
runtime/API changes belong before the final 48-hour soak.
