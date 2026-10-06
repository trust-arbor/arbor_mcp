# Post-1.0 Maintenance Plan

- **Status:** Stable 1.0 packaging and the focused contract cleanup are
  complete; the Codex characterization gate is met; adapter modularization
  and functional-core extraction remain proposed and tracked
- **Baseline:** ArborMCP `1.0.0`
- **Scope:** behavior-preserving modularization, functional-core extraction,
  dependency cleanup, and Hex source-package cleanup
- **Last updated:** 2026-09-22

This is a repository-maintenance document, not user-facing package
documentation. It records cleanup that is valuable but too invasive to mix
into the final 1.0 release-candidate cycle.

## Goals and constraints

- Keep every documented public module, callback, option, and return shape
  available throughout 1.x.
- Preserve ACP JSON-RPC and native CLI wire output byte-for-byte unless a
  separately documented bug fix requires a change.
- Keep the root adapter modules as the public behaviour implementations; move
  cohesive private responsibilities behind them.
- Prefer a few substantial boundaries over many tiny helper modules.
- Separate deterministic decisions from side effects where doing so creates a
  testable semantic boundary. Pass clocks, identifiers, resolved configuration,
  and working directories into pure code rather than reading process-global
  state there.
- Keep GenServers, Ports, ETS, HTTP clients, `Plug.Conn`, telemetry, and logging
  at orchestration edges. Pure cores may return tagged actions for those shells
  to execute; they must not pretend to be pure while calling `System`, `File`,
  `Application`, or process APIs internally.
- Do not create a shared Codex/ZCode abstraction merely because private
  functions have similar names. Share behavior only after golden tests prove
  that its inputs, outputs, errors, ordering, and lifecycle are identical.

The rc.8 work is limited to credential-free real-CLI lifecycle tests for the
Claude SDK, Codex, and Pi adapters; Pi configuration normalization/isolation;
reusable subprocess-environment, positive-option, and workspace-containment
helpers; and the Hex documentation cleanup below. The CLI tests do not send
prompts or call an LLM. The larger adapter changes below remain
deferred until after stable 1.0.

## Codex adapter restructuring

At the rc.7 baseline, `Arbor.MCP.ACP.Adapters.Codex` is approximately 3,470 lines,
in addition to the existing `Codex.Config` and `Codex.Events` modules. The root
module currently owns process protocol, ACP lifecycle, request tracking,
permissions, prompt conversion, session state, and MCP configuration.

### Characterization gate

Before moving production code, add golden tests for:

- every app-server request emitted by initialize and session lifecycle calls;
- prompt content conversion for text, images, resources, and resource links;
- permission request options and every accepted/rejected response shape;
- session update ordering for text, reasoning, tool calls, plans, and usage;
- MCP stdio/HTTP/SSE conversion and authorization failures;
- cancellation, timeout, late-response, and subprocess-exit behavior; and
- model and mode catalog normalization across supported Codex CLI versions.

### Status as of 2026-09-05 (characterization gate)

The Codex characterization gate above is met on `master` by a golden-transcript
suite under `test/arbor_mcp/acp/adapters/codex/characterization/` driven by
`Arbor.MCP.Test.CodexGolden` (`test/support/acp/codex_golden.ex`), with one fixture
per scenario under `test/fixtures/acp/codex/<area>/`:

| Gate bullet | File | Scenarios |
|---|---|---|
| initialize and session lifecycle requests | `lifecycle_golden_test.exs` | 114 |
| prompt content conversion | `prompt_content_golden_test.exs` | 96 |
| permission options and response shapes | `permissions_golden_test.exs` | 83 |
| session update ordering | `session_updates_golden_test.exs` | 92 |
| MCP conversion and authorization failures | `mcp_config_golden_test.exs` | 110 |
| cancellation, late responses, fenced sessions | `faults_golden_test.exs` | 46 |
| model and mode catalog normalization | `catalog_golden_test.exs` | 83 |

Each scenario reaches its preconditions through the adapter's public
callbacks only (`init/1`, `post_connect/1`, `translate_outbound/2`,
`translate_inbound/2`), so the fixtures pin wire behavior rather than state
layout and must stay byte-identical across the boundary extractions below.
Every area was mutation-tested by an independent reviewer (a single-edit
behavior change to `codex.ex`, `config.ex`, `events.ex`, or `sessions.ex` must
fail at least one scenario); the misses that remained are wire-equivalent
resets (`accumulated_text`, `accumulated_thinking`) and are recorded in the
area moduledocs. Client-side timeouts and subprocess exit are owned by
`Arbor.MCP.ACP.Client` and `AdapterBridge`, not by the adapter, and are covered by
their own tests rather than by this gate. See `docs/DEVELOPMENT.md` for the
regeneration workflow.

### Proposed boundaries

1. **`Codex.Protocol`** — native app-server envelope builders, method names,
   response classification, and request-id correlation shapes. It must remain a
   pure module with no process ownership.
2. **`Codex.Sessions`** — session lookup/update helpers and lifecycle state
   transitions. The root adapter retains orchestration and subprocess ownership.
3. **`Codex.Permissions`** — approval option construction, structured-decision
   encoding/decoding, and fail-closed fallback responses.
4. **`Codex.Content`** — ACP prompt/resource conversion plus native item and
   tool-result mapping.
5. **`Codex.MCP`** — MCP server normalization and native configuration output;
   authorization policy remains explicit at the adapter boundary.

Extract one boundary per commit. A boundary should generally remove at least
100 lines or eliminate a repeated semantic decision; otherwise leaving the
code local is clearer.

### Status as of 2026-09-20 (boundary extractions)

Three of the proposed boundaries are extracted on
`refactor/codex-modularization`, one commit each, with every golden fixture
byte-identical:

- `Codex.Permissions` (857 lines): approval tool-call and option
  construction, command decision options, permission request metadata, the
  user-input form schema and answer decoding, structured-decision decoding for
  every approval method, and the fail-closed cancel/late/closed-session
  responses. The root keeps pending-request state and the elicitation
  capability checks.
- `Codex.Content` (418 lines): ACP prompt block conversion, native
  `item/started` and `item/completed` mapping for every stateless item type,
  history replay, and streamed-text reconciliation. Functions return plain
  message lists; the root wraps them and keeps the stateful `agent_message`
  completion, which folds deltas into the session accumulators.
- `Codex.MCP` (226 lines): MCP server transport defaulting and validation,
  the native `mcp_servers` entries, and native config assembly (gateway
  providers, trusted projects, sandbox writable roots). Authorization stays in
  the root: `session_config/3` still authorizes the workspace, the additional
  directories, and each normalized server in list order, and passes the
  `trust_authorized_workspaces` policy flag in explicitly.

The root module is 3,284 lines (4,645 at the start of the branch). It still
owns the model catalog mapping, auth helpers, turn-failure and rate-limit
classification, session config authorization, and notification dispatch;
those become boundaries only if they clear the 100-line or repeated-decision
bar above.

### Codex completion criteria

- The public `Arbor.MCP.ACP.Adapters.Codex` API and state behavior are unchanged.
- The root module primarily coordinates lifecycle, state, and subprocess I/O.
- Unit, official ACP SDK interop, and real Codex CLI lifecycle tests pass.
- Golden native-wire fixtures are unchanged.
- Any helper proposed for ZCode reuse has explicit cross-adapter contract tests.

## Pi adapter restructuring

At the rc.7 baseline, `Arbor.MCP.ACP.Adapters.Pi` is approximately 2,357 lines.
`Pi.SessionStore`, `Pi.Settings`, `Pi.SlashCommands`, `Pi.Startup`, `Pi.Tools`,
and `Pi.Version` already provide useful boundaries, but the root module still
combines RPC control flow, ACP lifecycle, streaming events, prompt scheduling,
and configuration translation.

### Characterization gate

Before moving production code, add golden tests for:

- RPC messages for new, load, resume, fork, close, delete, and prompt flows;
- control-group completion and failure ordering;
- assistant/thinking/tool/usage stream-event conversion;
- prompt queue, steering, follow-up, cancellation, and subprocess-exit behavior;
- model, thinking-level, and boolean configuration updates;
- slash-command expansion and available-command notifications; and
- session-map and backing JSONL safety rules.

### Status as of 2026-09-20 (characterization gate)

The Pi characterization gate above is met by a golden-transcript suite under
`test/arbor_mcp/acp/adapters/pi/characterization/` driven by
`Arbor.MCP.Test.PiGolden` (`test/support/acp/pi_golden.ex`, with the shared step
builders in `Arbor.MCP.Test.PiGolden.Flows`), with one fixture per scenario under
`test/fixtures/acp/pi/<area>/`:

| Gate bullet | File | Scenarios |
|---|---|---|
| RPC messages for new, load, resume, fork, close, delete, prompt | `rpc_golden_test.exs` | 24 |
| control-group completion and failure ordering | `control_groups_golden_test.exs` | 16 |
| assistant/thinking/tool/usage stream-event conversion | `stream_events_golden_test.exs` | 19 |
| prompt queue, steering, follow-up, cancellation, subprocess exit | `prompt_flow_golden_test.exs` | 18 |
| model, thinking-level, and boolean configuration updates | `config_golden_test.exs` | 16 |
| slash-command expansion and available-command notifications | `slash_commands_golden_test.exs` | 15 |
| session-map and backing JSONL safety rules | `session_safety_golden_test.exs` | 15 |

Each scenario reaches its preconditions through the adapter's public
callbacks only (`init/1`, `translate_outbound/2`, `translate_inbound/2`,
`handle_adapter_message/2`, `list_sessions/2`, `shutdown/1`) inside a
per-run sandbox that holds the agent directory, session directory, session
map, working directory and a fake echoing `pi` executable, so the fixtures
pin wire behavior rather than state layout and no test reads the developer's
real Pi settings, prompts, models, or sessions. The fake executable also
makes managed-mode port writes and real subprocess exits observable.
Sandbox paths, minted `pi-N` / `tool-N` ids and near-now timestamps are
normalized (see the harness moduledoc), and the fixtures are byte-stable
across runs.

Every area was mutation-tested (a single-edit behavior change to `pi.ex` or
`pi/slash_commands.ex` must fail at least one scenario); the edit and the
scenario that catches it are recorded in each area's moduledoc so the check
can be repeated. Pi's startup banner (`Startup.build/3`, which inventories
`~/.pi` and `~/.agents`) and the final `File.cwd!/0` fallback for a missing
`cwd` are not characterized because they depend on the developer's machine.
See `docs/DEVELOPMENT.md` for the regeneration workflow.

Building the gate surfaced three agent-controlled payloads that made the
adapter raise instead of producing a transcript: a streamed tool-call event
carrying the call under `partial.content[contentIndex]` (`get_in/2` with an
integer index on a list, in the clause written to support exactly that
shape), a `get_available_models` payload whose `models` is not a list, and
catalog entries that are not maps. All three are fixed in 1.5.0 and pinned
by golden scenarios in the stream_events and config areas; each scenario
reproduces the original crash when the fix is reverted.

### Correlation ids and what the golden harness can see

`Arbor.MCP.Test.PiGolden` normalizes minted `pi-N` correlation ids by order of
first appearance in the transcript, so two runs that emit the same requests in
the same order produce identical fixtures even when the ids were minted in a
different order. That is a real blind spot: the `Pi.Sessions` extraction merged
the `session/load` and `session/resume` clauses, bound the replay request
before the switch request, and swapped `switch_session` and `get_messages` on
the wire with all 123 fixtures unchanged.

The underlying cause was that ids came from `System.unique_integer/1`, a
VM-global sequence. Emitted ids therefore depended on unrelated activity in the
same VM, which is why the harness had to normalize them at all, and why a test
could not assert anything stronger than ordering.

Correlation ids are now minted from `rpc_counter` on the adapter state, the way
prompt ids already used `msg_counter`. Ids are deterministic per connection and
ascend in the order the requests are built, and the session-switch path mints
through `Enum.map_reduce` over the request list, so emission order and mint
order cannot diverge by construction. Two tests in `pi_test.exs` assert that
the ids of a `session/load` and a `session/resume` ascend and are distinct.

The ids are opaque correlation tokens: nothing parses them, they are only map
and set keys, and Pi echoes back whatever it was sent, so the numbering is
ArborMCP's to choose. A scenario that starts the adapter twice now sees both
connections number from one, which is why two fixtures changed with the switch.

### Proposed boundaries

1. **`Pi.RPC`** — RPC envelope construction, correlation ids, and response
   classification. It should not own adapter state or a Port.
2. **`Pi.Sessions`** — ACP lifecycle translation and Pi session-switch/new-session
   state transitions, building on `Pi.SessionStore`.
3. **`Pi.Events`** — inbound stream-event folding into ACP notifications and
   prompt results.
4. **`Pi.PromptFlow`** — active/queued prompt transitions, steering/follow-up,
   cancellation, and terminal completion.
5. **`Pi.Config`** — model catalogs, thinking levels, mode/config option
   construction, and config-update translation.

Keep `Pi.Settings`, `Pi.Startup`, `Pi.SlashCommands`, `Pi.Tools`, and
`Pi.Version` separate unless an extraction exposes a concrete duplicate. Do
not merge modules solely to reduce the file count.

### Status as of 2026-09-21 (boundary extractions)

All five proposed boundaries are extracted. `Arbor.MCP.ACP.Adapters.Pi` is now
**1,795 lines**, down from 2,586 at the 1.5.0 release commit:

| Module | Lines | What it owns |
|---|---|---|
| `Pi.RPC` | 136 | NDJSON envelopes, command names, inbound classification, id correlation (extracted before 1.5.0) |
| `Pi.Config` | 402 | thinking-level vocabulary and modes, model catalog projection and modelId resolution, session/runtime config options, set_model / set_thinking / set_config_option update plans |
| `Pi.Events` | 307 | streamed tool-call folding, tool_execution start/update/end notifications, auto-compaction and auto-retry status, agent_end usage, session/load history replay |
| `Pi.PromptFlow` | 177 | queueing, the native prompt request and its pending state, queue announcements, cancellation drain, agent_settled terminal completion |
| `Pi.Sessions` | 144 | the settled-session state transition and response, the untracked get_state fold, the empty-catalog auth check, the absolute-cwd rule, session/list paging |

Each boundary is pure: no module above opens or writes a Port, and none reads
the filesystem. The planners return an NDJSON payload plus the updated state
and the root decides how to deliver it, so the root keeps `prepare_session_process`,
the `Pi.SessionStore` reads and writes, the `Pi.Settings` / `Pi.SlashCommands` /
`Pi.Startup` loads, the edit snapshots that `tool_execution_end` needs, and
every `PortRunner` call.

Two duplications the extractions exposed were also collapsed, which is where
most of the `Pi.Sessions` saving comes from: `session/load` and `session/resume`
became one `start_session_switch/4` that differs only in whether `get_messages`
joins the control group, and the `session_new` and `session_load` finishers
became one `finish_established_session/5`. The native request order, the minted
`pi-N` ids and the emitted message order are unchanged.

What deliberately stayed in the root:

- `maybe_snapshot_edit/4` and `tool_result_content/4` read the edited file
  before and after the tool runs, so they are effects, not conversions.
  `Pi.Events` receives the resolved line number and diff content instead.
- The steering and follow-up slash handlers the plan listed under
  `PromptFlow`. They are `start_control_command/7` calls that write to the
  Port, and their result text belongs with the other slash results rather
  than split across two modules; the whole slash surface remains a separate
  future question for `Pi.SlashCommands`.
- `command_state/3` and the control-group bookkeeping (`put_group/2`,
  `put_control/4`, `delete_group/2`), which are pure but belong to the
  slash-command catalog and the control-group machinery rather than to any
  of the five boundaries.

### Pi completion criteria

- The public `Arbor.MCP.ACP.Adapters.Pi` API and startup options are unchanged.
- The root module primarily coordinates state and native process I/O.
- Pi unit tests and the credential-free real CLI lifecycle test pass.
- Golden RPC fixtures and ACP event ordering are unchanged.
- No test reads the developer's real Pi settings, prompts, models, or sessions.

## Claude adapter characterization gate

At the 1.5.0 baseline, `Arbor.MCP.ACP.Adapters.ClaudeSDK` is approximately 4,390
lines across `claude_sdk.ex` and `claude_sdk/{mapper,protocol,session_store,
tool_info}.ex`, the largest of the three ACP adapters and the last one without
a characterization gate. The four queued Claude parity items (see "2026-09-21
Claude parity sequencing") change prompt-flow ordering and session identity,
so the gate is their prerequisite rather than a follow-up.

Before porting those items, add golden tests for:

- `post_connect`, `session/new`, `load`, `resume`, `list`, `close`, `delete`,
  and `fork_session/2`;
- prompt content conversion for text, images, resources, and resource links;
- `can_use_tool`, permission modes, the `set_permission_mode` control, the
  `allowDangerouslySkipPermissions` session opt-out, and AskUserQuestion
  answer folding;
- event ordering for `agent_message_chunk`, `agent_thought_chunk`,
  `tool_call` / `tool_call_update`, `plan`, `session_info_update`,
  `current_mode_update`, `config_option_update`, `available_commands_update`,
  and usage;
- MCP server normalization, native config output, and authorization failures;
- cancellation, `interrupt`, error replies, late and unknown responses, and
  subprocess exit; and
- model, mode, and config-option catalog normalization.

### Status as of 2026-09-21 (characterization gate)

The Claude gate above is met by a golden-transcript suite under
`test/arbor_mcp/acp/adapters/claude_sdk/characterization/` driven by
`Arbor.MCP.Test.ClaudeGolden` (`test/support/acp/claude_golden.ex`, with the
shared step builders in `Arbor.MCP.Test.ClaudeGolden.Flows`), with one fixture per
scenario under `test/fixtures/acp/claude/<area>/`:

| Gate bullet | File | Scenarios |
|---|---|---|
| post_connect and session lifecycle | `lifecycle_golden_test.exs` | 55 |
| prompt content conversion | `prompt_content_golden_test.exs` | 38 |
| permissions, modes, opt-out, AskUserQuestion | `permissions_golden_test.exs` | 59 |
| session update ordering | `session_updates_golden_test.exs` | 67 |
| MCP configuration and authorization | `mcp_config_golden_test.exs` | 39 |
| cancellation, late responses, fail-closed answers | `faults_golden_test.exs` | 31 |
| model, mode, and config-option catalogs | `catalog_golden_test.exs` | 35 |

Each scenario reaches its preconditions through the adapter's public callbacks
only (`init/1`, `command/1`, `env/1`, `post_connect/1`, `auth_methods/1,2`,
`capabilities/0`, `modes/0`, `config_options/0`, `list_sessions/2`,
`fork_session/2`, `translate_outbound/2`, `translate_inbound/2`) inside a
per-run sandbox that holds the Claude config directory, the working directory
and a fake `claude` executable, so the fixtures pin wire behavior rather than
state layout and no test reads the developer's real Claude configuration,
credentials, sessions, or projects. The harness refuses any `cwd`,
`claude_config_dir`, `cli_path`, `:env` `CLAUDE_CONFIG_DIR` or request
`params.cwd` outside the sandbox, and a fixture containing the home directory
fails the run. Sandbox paths (in both their literal and symlink-resolved form,
plus the SDK project-key form), minted control-request / session / tool ids,
adapter-minted ACP request ids, forked session UUIDs, session byte counts and
near-now timestamps are normalized (see the harness moduledoc); the fixtures
are byte-stable across regeneration runs.

Every area was mutation-tested (a single-edit behavior change to
`claude_sdk.ex`, `claude_sdk/mapper.ex` or `claude_sdk/protocol.ex` must fail
at least one scenario); the edit and the scenario that catches it are recorded
in each area's moduledoc so the check can be repeated.

Two things are deliberately not characterized. Subprocess exit is not
reachable: the Claude adapter is not adapter-managed, so port exit, port close
and partial-line buffering belong to `Arbor.MCP.ACP.AdapterBridge` and its own
tests, and there is no adapter callback this gate could drive. The
remote-login branch of `auth_methods/2` reads `NO_BROWSER`, `SSH_CONNECTION`,
`SSH_CLIENT`, `SSH_TTY` and `CLAUDE_CODE_REMOTE` straight from the OS
environment, which an async test may not mutate; the harness fails an
`:auth_methods` step when one of them is set rather than guessing.

Building the gate surfaced one latent defect, pinned as it behaves today
rather than fixed: a Claude `read_file` control request's `max_bytes` never
reaches the ACP client, because the adapter passes it to
`Arbor.MCP.ACP.Protocol.encode_file_read_request/3` as `:max_bytes` while that
function reads only `:line` and `:limit`. The client therefore sees no cap
(`faults_golden_test.exs`, `read_file_drops_the_max_bytes_limit`). Fixing it
is a separate reviewed commit that must update that fixture.

See `docs/DEVELOPMENT.md` for the regeneration workflow.

Portability note: the session store reads mtime through
`File.stat(path, time: :posix)`, which is whole-second granularity, so two
session files written in the same second carry the same `lastModified`.
`Enum.sort_by/3` is stable, which leaves the tie broken by directory listing
order, and that differs between filesystems. Fixtures generated on macOS
therefore failed on the Linux CI runners. The `:write_file` step accepts
`mtime:` and the two ordering-dependent `session/list` scenarios pin distinct
values, so the sort is asserted rather than inherited from the platform. Any
new scenario whose expected output depends on session order must do the same.

## Functional-core and effect-boundary follow-up

These extractions are candidates for the supported 1.x line after stable 1.0,
not a requirement to perform all of them. Each must land behind characterization
tests and remain independently revertible. If an extraction changes process
ownership, callback identity, restart behavior, cancellation, ordering, or a
public return shape, it belongs in the 2.0 roadmap instead.

The canonical 1.x compatibility gate is
[`V2_ROADMAP.md` section 8.1](./V2_ROADMAP.md#81-required-backport-tests); this
document's candidate lists do not weaken or replace it.

The preferred shape is a reducer such as
`transition(state, event, now) -> {new_state, actions}`. Actions can describe
effects such as `{:send, message}`, `{:reply, caller, result}`,
`{:schedule, deadline}`, or `{:emit, event}`. The owning process executes those
actions and feeds outcomes back as later events. This makes state transitions
exhaustively testable without weakening OTP ownership.

Before extracting a reducer, characterize action ordering, effect-failure
feedback, request correlation/idempotency, duplicate and late events, and timer
or cancellation races. Reducer events/actions are private implementation
contracts unless a separate public design explicitly says otherwise.

### Priority candidates

1. **Client request lifecycle** — extract request planning, correlation,
   timeout/cancellation decisions, and response reduction from
   `Arbor.MCP.Client` and `Arbor.MCP.Client.RequestHandler`. Keep transport calls,
   `GenServer.reply/2`, timers, and telemetry in the client process.
2. **Session lifecycle** — extract identity binding, initialization claims,
   replay ordering, retention, and expiry decisions from
   `Arbor.MCP.SessionManager`. Keep ETS, monitors, clocks, logging, and subscription
   cleanup in the owner.
3. **HTTP client state** — extract option normalization plus Mint response/SSE
   event reduction from `Arbor.MCP.Transport.HTTP`. Keep sockets, OAuth callbacks,
   process messages, and telemetry at the edge.
4. **HTTP server routing** — expand the existing `Arbor.MCP.HttpPlug.Core` pattern
   to cover protocol-era, route, session, and response planning from plain data.
   Keep `Plug.Conn`, request-body reads, stores, and SSE streaming in the Plug.
5. **OAuth decisions** — extract redirect policy, callback parsing, discovery
   choices, and token-request construction from
   `Arbor.MCP.Authorization.FullOAuthFlow`. Keep browser, listener socket, HTTP,
   credential-store, and transaction-store operations in the flow shell.
6. **ACP adapters** — use the Codex and Pi boundaries above as pure protocol,
   content, permission, configuration, event, and prompt-flow cores. The root
   adapters continue to own subprocesses and ACP lifecycle orchestration.
7. **ACP pending requests** — either promote `Arbor.MCP.ACP.PendingRequests` into a
   real request-lifecycle core with explicit entry, resolve, cancel, expire, and
   late-response transitions, or remove the shallow map wrapper. Do not retain
   an abstraction that owns neither policy nor invariants.

### Shared HTTP framing

`Arbor.MCP.Internal.PinnedHTTPClient`,
`Arbor.MCP.Authorization.PinnedHTTPClient`, and
`Arbor.MCP.Transport.HTTP.BoundedClient` contain overlapping Mint response
accumulation and bounded-body decisions. Extract one small pure HTTP event
reducer and contract suite while keeping DNS, target, TLS, redirect, OAuth, and
authorization policies in their current owners. Do not merge the policy layers
merely because all three use Mint.

#### Status as of 2026-09-20

Extracted. `Arbor.MCP.Internal.HTTPResponseReducer` (`@moduledoc false`) owns the
pure mechanics only: `reduce(events, request_ref, acc, limits)` returning
`{:cont, acc} | {:done, acc} | {:error, reason}`, the empty accumulator,
`body/1`, `remaining_ms/2`, header normalization, the lenient
(`content_length_too_large?/2`) and strict
(`invalid_or_oversized_content_length?/2`) content-length checks,
`compressed?/1`, `conflicting_framing?/1`, `request_target/1`,
`default_port/1`, `address_family_options/1`, and `method_name/1`. The
reducer applies a caller-supplied `:validate_headers` function to every
`:headers` event, passing both the normalized batch and the accumulated list,
and returns the caller's error term untouched. Events for a foreign request
ref and unknown event shapes are skipped; the first `:done` ends the batch.

Each owner kept its policy, its socket and clock handling, and its shapes:

- `Arbor.MCP.Internal.PinnedHTTPClient`: GET only, lenient content-length check
  on each header batch, no compression check, `{:ok, %{status, headers,
  body}}`, and `:fetch_failed` for every transport or Mint failure.
- `Arbor.MCP.Authorization.PinnedHTTPClient`: httpc-style tuple with the status
  reason, `:compressed_response`, strict content-length on each batch,
  `:invalid_response` for a `:done` without a status, `:request_failed` for
  receive failures, Mint connect errors passed through, request-tuple parsing
  with `content-type` defaulting, and the TLS and `send_timeout` socket
  options.
- `Arbor.MCP.Transport.HTTP.BoundedClient`: httpc-style tuple, `TargetPolicy`
  resolution, the request-size limit, `host` stripping plus forced
  `content-type` and `accept-encoding: identity`, `:compressed_response`,
  `:invalid_response_framing`, strict content-length over the accumulated
  header list (trailers included), and the `{:http_request_failed, _}`,
  `{:http_receive_failed, _}`, and `{:http_client_error, _}` error shapes.

Characterization suites live in
`test/arbor_mcp/internal/pinned_http_client_test.exs`,
`test/arbor_mcp/authorization/pinned_http_client_test.exs`, and
`test/arbor_mcp/transport/http_bounded_client_test.exs`, driven through
`Arbor.MCP.Test.RawHTTPServer`; the reducer has its own table-driven suite in
`test/arbor_mcp/internal/http_response_reducer_test.exs`. Request-header
editing (`put_header/3`, `delete_header/2`, `put_header_if_missing/3`) stayed
in the owners because the two clients that have it disagree on
replace-versus-keep semantics.

## Focused correctness and contract cleanup

Resolve these as separate fixes, with the documented behavior and release lane
chosen explicitly before changing code:

| Area | Current mismatch or risk | Follow-up | Release lane |
|---|---|---|---|
| Circuit breaker clocks | `Arbor.MCP.Reliability.CircuitBreaker.Core` calls `System.system_time/1`, despite presenting itself as a pure core. Wall time can also move backwards during duration calculations. | Pass `now_ms` from the process shell and use monotonic time for elapsed durations. Audit session expiry for the same distinction between wall-clock timestamps and elapsed time. | Eligible for 1.x as a characterized correctness fix; preserve timeout and telemetry behavior. |
| Session storage option | `Arbor.MCP.SessionManager` documents `storage_backend: :persistent_term`, but its runtime always creates ETS state. | Specify the store contract and either implement the backend or deprecate the no-op option while continuing to accept it throughout 1.x. Do not leave a durability setting that silently does nothing. | Contract/backend may be additive in a later 1.x minor; option removal is 2.0-only. |
| Client fallback | `Arbor.MCP.connect/2` documents a transport list as fallback, while the implementation selects only `List.first/1`. | Specify ordered errors, ownership, and cleanup before implementing fallback. If those semantics are not accepted, correct the docs and deprecate the list form while preserving 1.x acceptance. | A fully characterized spec-correctness fix may qualify for a 1.x minor; otherwise defer behavior change/removal to 2.0. |
| Stdio logging | `Arbor.MCP.Internal.StdioLoggerConfig.configure/0` mutates VM-global Logger/Application/OTP logger behavior. | Route protocol output through a dedicated IO device and logs to stderr without changing unrelated host-application logging. | Document the hazard in 1.x; replace the global behavior in 2.0 unless compatibility evidence proves a safe 1.x path. |
| Client capability detection | Resource operations inspect the process dictionary's `$initial_call` to infer a modern client. | Replace the heuristic with an explicit internal connection-info or capability query. | Eligible for 1.x only with identical results for all supported client entry points. |
| Ambient inputs | Several paths read application/system environment, current directory, time, or generate IDs inside decision code. | Normalize configuration once at startup and pass resolved values into cores. | Internal injection is eligible for 1.x if precedence and generated wire values remain identical; precedence changes are 2.0-only. |

### Status as of 2026-09-02

Each row above was resolved on `master` after 1.1.1 and ships in 1.2.0 unless
noted:

- **Circuit breaker clocks:** resolved. `CircuitBreaker.Core` receives an
  injected monotonic `now_ms` from the process shell and no longer reads wall
  time for elapsed durations.
- **Session storage option:** resolved as a contract plus adapter. A standalone
  1.x store-adapter ADR and ETS-only contract suite were accepted,
  `SessionManager` dispatches through an internal `SessionStore` seam, an
  opt-in DETS backend (`storage_backend: :dets` with `:storage_path`) is
  available, and `:persistent_term` remains accepted with a warning that it
  uses ETS. ETS is still the default and its restart-empty behavior is
  unchanged.
- **Client fallback:** resolved as a documentation correction. `Arbor.MCP.connect/2`
  now documents that only the first spec of a list is used; the list form stays
  accepted throughout 1.x.
- **Stdio logging:** the VM-global hazard is documented for 1.x. Replacing the
  behavior remains a 2.0 item.
- **Client capability detection:** resolved. Resource subscribe/unsubscribe
  decide modern versus legacy from `Client.get_status` protocol version behind
  an explicit Client process marker; `$initial_call` is no longer inspected.
- **Ambient inputs:** open. The clock injection above is the first instance;
  remaining reads are handled case by case under the same 1.x rule.

### Status as of 2026-09-05

The 1.3.0 line adds ACP client and adapter work that was driven by a
downstream consumer (Jido Harness) and is classified in
[`V2_ROADMAP.md` section 8.2](./V2_ROADMAP.md#82-current-classifications):

- **Handler message context:** `Arbor.MCP.ACP.Client.Handler` gained optional
  `handle_session_update/4` and `handle_permission_request/5` variants that
  receive the decoded JSON-RPC message the client received. Both arities of
  each pair are optional; `HandlerRunner` refuses to start a handler that
  exports neither. Retained message data counts toward the handler update
  queue byte limit.
- **Adapter metadata namespace:** all adapter extension data lives under nested
  `_meta.ex_mcp.<adapter>`, matching the documented shape. `AdapterBridge`
  can tag adapter-derived messages with `_meta.ex_mcp.native` (adapter name,
  per-connection sequence, optional decoded native event) behind the
  `:native_events` option, which defaults to `:off` under the 1.x backport
  rule. Adapters implement the optional `name/0` callback.
- **Codex adapter correctness:** failed turns now fail the active prompt with
  a classified error, and streamed agent text is tracked per item so neither
  duplicate nor dropped messages reach chunk consumers. The second fix was
  found by review on the first; the per-turn accumulator had silently become
  ambiguous in a module that has grown to about 4,519 lines.
- **Dependency security:** mint 1.10.0. Cowlib 2.20.0 and Cowboy 2.19.0 were
  published on 2026-09-08 and locked here on 2026-09-16. State of the three
  Cowlib advisories, verified against the `2.20.0` tag and `master`:
  - `EEF-CVE-2026-43971` (`cow_link:link/1`): fixed. Commit `89da27ee` is an
    ancestor of the `2.20.0` tag, and EEF updated the advisory with
    `fixed: 2.20.0` on 2026-09-16, so `mix hex.audit` no longer reports it.
    The exception is removed.
  - `EEF-CVE-2026-43966` (`cow_http_struct_hd:escape_string/2`) and
    `EEF-CVE-2026-43969` (`cow_cookie:cookie/1`): not fixed, and not going to
    be. Both functions are byte-for-byte unchanged on Cowlib `master`. The
    maintainer closed every validating PR (ninenines/cowlib #154, #163, #164,
    #166, #169) and stated in #152 that the CVE "will likely remain as won't
    fix": Cowlib encoders expect RFC-valid input, and Cowboy 2.16+ and Gun
    2.4+ reject CR/LF at their own layer. The advisory metadata is accurate,
    so there is nothing to report to EEF. The exceptions have no review date;
    they stay for as long as ArborMCP requires Cowboy, and
    `dependency_advisory_mitigation_test.exs` keeps locking the assumptions
    behind them.
  - Consequence: the only way to stop carrying audit exceptions for code
    ArborMCP never calls is to stop requiring Cowboy. Bandit depends on
    `thousand_island`, `hpax`, `plug`, `websock`, and `telemetry` only, with
    no Cowlib in its tree. Making the HTTP server dependency optional (Cowboy
    optional, Bandit supported) was reserved for 2.0 because it is a breaking
    change for `transport: :http` consumers; it is now an accepted 2.0 item
    in `V2_ROADMAP.md` and a reason to bring 2.0 forward rather than wait for
    the rest of the 2.0 scope. PR #21 is the existing draft. GitHub #18 stays
    open until a downstream `mix hex.audit` passes without exceptions.

Related maintenance figures at this baseline: `Arbor.MCP.ACP.Adapters.Codex` is
about 4,519 lines and `Arbor.MCP.ACP.Adapters.Pi` about 2,553, up from the rc.7
figures quoted above, so the modularization sections below are more pressing,
not less. The existing `Codex.Sessions` helper covers session lookup and
update only; the lifecycle-transition boundary in the Codex plan remains.
Dialyzer reported 27 unnecessary entries in `.dialyzer_ignore.exs` on the CI
dialyzer version; 15 were pruned in 1.5.0 and the file now carries 26 entries.
The count is environment-dependent and that is the trap: the files under
`test/` are compiled only in the test environment, so a `MIX_ENV=dev` run
reports every test entry as unused even though the test run needs them.
Only the intersection was removed, and it was verified on both the current
toolchain (Elixir 1.19.5 / OTP 28.3.1) and the pinned CI dialyzer toolchain
(Elixir 1.17.3 / OTP 27.0), in both environments. `MIX_ENV=test` now reports
zero unnecessary skips; a `MIX_ENV=dev` run still reports the twelve
test-environment entries, which is expected and not a signal to remove them.
Record the toolchain and both environments with any future prune.

## Stdio byte-mode framing and internationalization

Tracked in GitHub #52. Diagnosed by deepfates in #41, which was withdrawn
before review; the diagnosis was correct and the unified fix sketched in that
thread is the shape adopted here.

### The defect

Both stdio transports let the VM's device encoding translate protocol frames.
That encoding is chosen by the process locale at VM start, and it has exactly
two values: `unicode` under a UTF-8 locale, `latin1` under anything else,
including no locale at all. Eleven locales were checked on 2026-09-20 (unset,
C, POSIX, ISO-8859-1, EUC-JP, Shift_JIS, GB18030, KOI8-R, and three UTF-8
variants); there is no third mode, so "other locales" is not a dimension the
fix has to generalize over.

| Transport | Device mode | Read | Write |
|---|---|---|---|
| `Arbor.MCP.Server.StdioServer` (`IO.read`, `IO.puts`) | latin1 (launchd, systemd, minimal MCP hosts) | UTF-8 input is re-encoded byte by byte; `café` reaches the handler as `cafÃ©` (35 bytes for 11) | codepoints above U+00FF become `\x{65E5}` escapes inside the JSON string; the frame is not valid JSON |
| `Arbor.MCP.ACP.Agent.Transport.Stdio` (`IO.binread(_, 1)`, `IO.puts`) | unicode (any UTF-8 developer shell) | each one-byte read returns the decoded codepoint as a latin1 byte, so `é` arrives as `0xE9` and anything above U+00FF fails with `no_translation` | unaffected |
| same | latin1 | unaffected | same corruption as the MCP server |

An echo tool hides the MCP case completely, because writing the double-encoded
text back through the same device reverses the damage exactly. The interop
lanes only ever send ASCII. Both facts explain why this shipped.

Two related findings from the same investigation:

- `IO.binwrite` on a unicode-mode device double-encodes. Switching the write
  calls without owning the device mode would move the corruption from one
  locale to the other.
- A byte-order mark before the first frame makes it undecodable, and the
  server silently drops undecodable lines by design (Mix.install noise), so a
  BOM-emitting host hangs at `initialize`.

Not affected: the client-side stdio transports move bytes through
binary-mode Ports, and the isolated child environment already passes `LANG`
and every `LC_*` variable through. The JSON layer round-trips astral
characters, surrogate-pair escapes, U+2028/U+2029, and decomposed sequences
unchanged, and rejects invalid UTF-8 on both encode and decode.

### The fix

1. **One owner for the rule.** An internal `Arbor.RPC.StdioFraming`
   that asks a device whether it is a character (unicode) or byte (latin1)
   device and reads and writes it the matching way, which is byte-exact for
   valid UTF-8 in both cases, plus BOM stripping. The mode is consulted on
   every read and write, never cached and never changed: OTP 27 cannot
   switch a unicode-mode stdin after VM start (reads fail with
   `no_translation`), and OTP 27 and 28 both flip a unicode-mode stdio to
   latin1 for good when it meets input it cannot decode, so one bad line from
   a peer must not corrupt every frame after it. A read with the wrong view
   is not recoverable, so the view is never probed. `StdioServer` and the
   ACP transport both go through it; the ACP transport consults the mode
   once per frame and counts its limit in bytes, since a unicode read returns
   a whole character.
2. **Strip a leading BOM once** at stream start, in the same module.
3. **Docs.** `TRANSPORT_GUIDE.md`: the stdio transports own their device's
   mode; stdout is protocol-only, so nothing else may write to it, which was
   already the contract. Deployment note: Linux releases whose resource
   handlers touch non-ASCII filenames need `+fnu` in `vm.args`, because the
   VM's filename encoding is locale-driven on Linux (always UTF-8 on macOS);
   that is an application concern, not a transport one.
4. **Changelog** under Fixed, crediting deepfates and #41.

Nothing is pinned VM-wide. Known limitation: on OTP 27 under a UTF-8
locale, input already buffered when the io server meets an undecodable byte
is left half decoded and half raw while the device reports latin1 for all of
it, and the session ends; OTP 28 and newer drop the line and continue. A raw
fd port would bypass the io server but steals the descriptor from the tty
driver and cannot write, so it is not a library-default option.

### The test tier

One payload corpus, reused across transports, with the locale matrix applied
only where locale enters:

- **Corpus** (`test/support/i18n_corpus.ex`): Latin-1 (`café`), CJK, astral
  emoji, a joiner sequence, combining marks in decomposed form, right-to-left
  text with bidi controls, U+2028, an astral character delivered as a
  surrogate-pair `\u` escape (as other SDKs emit), and a multibyte payload at
  the frame-size limit so byte accounting is exercised rather than grapheme
  accounting.
- **Positive round trips, byte-exact:** MCP stdio server as a subprocess; ACP
  stdio transport through devices opened in unicode mode and in latin1 mode;
  HTTP client to `HttpPlug`; the in-process test transport.
- **Locale matrix, subprocess test only:** unset, `C`, `en_US.UTF-8`,
  `ja_JP.eucJP`, each with a tool that generates its own non-ASCII text, not
  an echo.
- **Negative cases:** BOM-prefixed first frame (accepted), CRLF-terminated
  frames (accepted), invalid UTF-8 (dropped without crashing on OTP 28 and
  newer; the stdio subprocess test sends it only there, and the choice not to
  answer `-32700` is documented in the test).

### Out of scope, tracked separately

- Boot-time logger output reaching stdout before `StdioLoggerConfig` runs.
  Resolved for ArborMCP's own logs: `SessionManager` was the only boot-path
  module logging at `info` and now logs at `debug`, and a subprocess test
  boots the application's supervision tree under the default logger and
  asserts stdout stays empty. Other applications in the same VM remain the
  deployment's responsibility; the configuration guide now documents
  `stdio_mode: true` plus a stderr default handler as the stdio deployment
  setting. Replacing the VM-global suppression itself stays a 2.0 item under
  the "Stdio logging" row above.
- A Windows console CI lane. Byte mode is the right answer there too, but it
  has not been proven.

### Release lane and acceptance

A characterized correctness fix eligible for a 1.x patch or the next minor: no
wire change, no API change, identical behavior for ASCII payloads and for
properly configured devices. Done when the acceptance list in #52 passes:
the subprocess test under all four locales, the corpus byte-exact through
every transport, the three negative cases asserted, and the ASCII-only
interop lanes still green.

## Dependency-direction cleanup

At commit `4591af6`, `mix xref graph --format stats` reported eight dependency
cycles. Under Elixir 1.17.3 / OTP 27 the same command reports 22 cycles at both
the `v1.2.0` tag and the 1.3.0 baseline, none of them touching `lib/arbor_mcp/acp`;
they sit in the transport, client, internal, and content modules. Treat 22 as
the current baseline and record the toolchain with any future count, since the
difference from the earlier figure is a measurement change rather than a
regression. Break the cycles through narrow dependency inversion rather than
moving code between large modules:

- move concrete `get_transport/1` selection out of the `Arbor.MCP.Transport`
  behaviour and into a registry or factory;
- introduce a small revision catalog so version data does not cycle through
  `VersionRegistry`, `Protocol.Methods`, error codes, and generated types;
- have client operation modules call an internal request-executor contract
  instead of depending back on the public `Arbor.MCP.Client` facade;
- replace the `MessageProcessor`/`MethodHandlers` mutual call with a one-way
  invocation boundary;
- separate content-validation rules and schema-policy resolution into acyclic
  decision modules; and
- move TLS option construction out of `Arbor.MCP.Transport.HTTP` into a neutral
  security module so `Arbor.MCP.Internal.Security` does not depend back on the HTTP
  transport that consumes it.

Record the cycle count in each cleanup PR and add an xref regression threshold
once the existing cycles are eliminated. Cycle removal is eligible for 1.x only
when runtime and compile-time characterization remains unchanged.

Reproduce the baseline with `mix xref graph --format stats` and inspect the
specific strongly connected components with
`mix xref graph --format cycles`. Update the commit anchor when this plan is
rebased onto a different maintenance baseline.

**Status as of 2026-09-20.** On Elixir 1.19.5 / OTP 28.3.1, `master` at
`94ba1bf` reported 9 cycles; after the `refactor(xref)` series the same
toolchain reports 2 (`mix xref graph --format stats`: 313 tracked files, 10
compile, 37 export, and 657 runtime edges, `Cycles: 2`). Seven small cycles
were broken, one commit each, with no public API, runtime, or compile-time
semantic change and the full unit suite (4679 tests, 0 failures) plus
`mix test.suite compliance` (591 tests, 0 failures) green after each step:

- `MessageProcessor` <-> `MessageProcessor.MethodHandlers`: the `assign/3`
  struct primitive moved down to `MessageProcessor.Conn` (`@doc false`);
  the public `MessageProcessor.assign/3` delegates to it and the handlers
  call `Conn.assign/3`, so dispatch is a one-way invocation boundary.
- `Content.Validation` <-> `Content.Validation.Rules`: `Validation` injects
  its custom-validator lookup into `Rules.apply_rule/4`; the persistent_term
  key and registered-validator semantics are unchanged.
- `Content.SchemaPolicy` <-> `Content.SchemaRemoteResolver`: the resolver
  takes the policy preflight function as an explicit argument
  (`resolve/3`), passed by `SchemaPolicy`, its only caller.
- `Arbor.MCP` <-> `ClientConfig`: `ClientConfig` reads the library version from
  the existing `Arbor.MCP.Internal.VersionInfo` instead of the `Arbor.MCP` facade.
- `Server.Subscriptions` <-> `Tasks`: the store-invocation primitive behind
  `Tasks.get/2` lives in the new `@moduledoc false` `Arbor.MCP.Tasks.StoreCall`;
  `Tasks` delegates to it and `Subscriptions` authorizes `taskIds` through it
  with the same owner map, so only `Tasks -> Subscriptions` remains.
- `Internal.SessionStore` <-> `SessionStore.DETS` <-> `SessionStore.ETS`:
  the behaviour's default-selecting `open/1` moved, unchanged, into the new
  `@moduledoc false` `Arbor.MCP.Internal.SessionStore.Factory`, which
  `SessionManager` now calls.
- `Internal.VersionRegistry` <-> `Protocol.ErrorCodes` <-> `Protocol.Methods`
  (compile) <-> `Types`: the revision catalog suggested above now exists as
  the pure `@moduledoc false` `Arbor.MCP.Internal.RevisionCatalog`. The registry
  sources its revision attributes from it and delegates `era_for/1`;
  `Methods`, `ErrorCodes`, and `Types` read the catalog instead of the
  registry. `VersionRegistry` remains the canonical registry for enablement,
  preference ordering, and version-specific behaviour.

Remaining (deliberately untouched; they are a separate decision because they
require the request-executor contract and the transport-registry/TLS moves
described above rather than a narrow inversion): the 13-module client cycle
through `lib/arbor_mcp/client.ex` (its operations modules, connection manager,
era cache, notification listener, request handler, subscription, health
check, and reliability wrapper) and the 10-module transport cycle through
`lib/arbor_mcp/transport.ex` (the HTTP transport and its header/SSE helpers,
local, stdio, test, security guard, and `Internal.Security`). No cycle in
the small set was skipped. Add the xref regression threshold once those two
are eliminated.

## Hex source-package documentation cleanup

The rc.7 `package.files` list ships 204,602 bytes (approximately 200 KB) of raw internal
planning, audit, coverage, and release-candidate history:

- `docs/API_DIFF_RC5_TO_1_0.md`
- `docs/MCP_2026_07_28_MIGRATION_PLAN.md`
- `docs/MCP_COVERAGE_MATRIX.md`
- `docs/RELEASE_1_0_0_RC_6.md`
- `docs/RELEASE_1_0_0_RC_7.md`
- `docs/SECURITY_AUDIT_2026-08-12.md`
- `docs/PRE_2_0_TECH_DEBT_PLAN.md`
- `docs/V2_ROADMAP.md`

These files should remain in Git history and the repository. They need not be
installed in every consumer's dependency tree or presented as normal library
guides on HexDocs.

### Packaging change checklist

- [x] Confirm the stable user migration guide contains any still-relevant
      upgrade instructions from the RC-specific documents.
- [x] Keep `README.md`, `CHANGELOG.md`, `docs/SECURITY.md`, architecture,
      configuration, transport, troubleshooting, ACP, DSL, and getting-started
      guides in the package.
- [x] Remove the internal files above from `package.files`.
- [x] Remove the same files from ExDoc `extras` and their documentation group in
      the same commit so `mix docs` works from an unpacked Hex package.
- [x] Preserve repository links from release notes or contributor documentation
      where historical context remains useful.
- [x] Run `mix hex.build`, inspect the tarball file list, and record compressed
      size before and after. The compressed package contents decreased from
      798,062 to 728,416 bytes; the outer Hex archive decreased from 819,200 to
      749,568 bytes.
- [x] Run `mix docs` with warnings as errors and verify that no retained guide
      links to an omitted local file. An unpacked-package link scan found no
      missing relative Markdown targets.

This packaging-only cleanup is complete for rc.8. The files remain available
in the repository, and packaged references to them use repository URLs.

## MCP conformance harness tracking

Keep release CI deterministic by pinning the reviewed modern conformance
harness in `scripts/conformance.sh`. Separately, the weekly `MCP conformance
upstream` workflow resolves the highest published
`@modelcontextprotocol/conformance` version and runs both complete 2026-07-28
suites. A manual dispatch can select an exact version for prerelease review.

The scheduled lane is intentionally advisory and never rewrites the pin. It
records the selected package version and uploads the complete client, server,
and runner logs even when the harness exposes a failure. For each upstream
failure, review the conformance release diff, determine whether the change is a
new protocol assertion or a harness regression, add focused local coverage for
newly required behavior, and advance the release pin only after the full suite
passes.

## ACP ecosystem and reference-adapter tracking

Post-1.0 ACP compatibility must cover both protocol conformance and differences
between real agent implementations. The repository therefore maintains a
reviewed manifest at `test/interop/acp_compatibility.json` with three distinct
inputs:

- membership of the public ACP agents page;
- IDs and versions from the machine-readable ACP Registry; and
- exact upstream revisions for `claude-agent-acp`, `codex-acp`, `pi-acp`, and
  `ZCode`, whose behavior informed ArborMCP's Claude, Codex, Pi, and ZCode
  adapters.

`mix acp.compat.check` reports additions, removals, registry releases, and
reference-repository commits without installing or running remote catalog
content. A separate reviewed matrix runs credential-free initialization against
version-pinned native ACP commands in isolated scratch environments. It starts
with Claude Agent ACP, Codex ACP, Gemini CLI, and Pi ACP; expand it toward every
documented agent as installation, platform, licensing, and authentication
requirements are characterized.

When reference-adapter drift appears, review the compare link for protocol
mapping, capability, event-ordering, security, and lifecycle changes before
advancing the pinned commit. Port relevant behavior behind characterization
tests; a pin update alone is not evidence that ArborMCP remains behaviorally
aligned.

### 2026-08-22 reference sync

The first scheduled-review baseline now pins Claude Agent ACP
`996d488589b8db7a0f9af3dfc7b886d9d47ebae9`, Codex ACP
`ba5bcc3d7759250dde9d4d2286a1bec11b363208`, and Pi ACP
`d1cffc047ab37a096ee70ca39cfc1de463db8d12`. The review produced characterized
adapter fixes rather than a pin-only update:

- shared ACP form/URL elicitation, explicit per-mode capability negotiation,
  URL completion, and validation;
- Claude `AskUserQuestion`, truthful durable permissions, Exit Plan effects,
  dynamic modes, the SDK marker update, and background-subagent settlement;
- Codex close/delete fencing, structured non-secret user input, MCP URL
  completion, and request-scoped device authentication;
- Pi's `agent_settled` completion boundary and select/confirm extension UI
  response bridge.

Follow-up reviews should promote these cases into live CLI or deterministic
fixture tiers when the upstream CLIs expose a credential-free trigger. The
current real-CLI lifecycle suite deliberately avoids prompts and therefore
cannot exercise LLM-originated permission, elicitation, or background-task
events; the adapter unit tests are the executable evidence for those paths.

### 2026-08-25 pending reference drift

Codex ACP development moved from `zed-industries/codex-acp` to
`agentclientprotocol/codex-acp`; the manifest now follows the canonical
repository while retaining the last behaviorally reviewed commit. Do not
advance the Claude or Codex reference pins until the following post-baseline
changes have focused ArborMCP parity decisions and tests:

- Codex `8ff9e67f79335345ce53b3157b3d690c191ea027` adds permission presentation,
  provider decision preservation, and permission lifecycle isolation;
- Codex `50f69e57ca761ccafd2ca29de7fb591068277516` changes mode presentation and
  adds `_meta.kind` semantics; and
- Claude `caf609b56c91f677ffe82b6e9d11d9e9dfd99d45` advertises a stable mode
  catalog, adds `_meta.kind`, and falls unsupported Auto mode back to Accept
  edits with a client-visible warning.

These are genuine unreleased behavior changes rather than repository-move
noise. Keeping the reviewed commits pinned makes the scheduled drift check
continue to report the work until parity is deliberately accepted or ported.

### 2026-09-01 pin refresh and remaining parity decisions

The manifest was subsequently advanced to Claude Agent ACP
`7c6610835f26f18cd162b78dff74a7b7cd74497a` and Codex ACP
`4823131475b3b0d996ccc305e49dcf9fdaa6ee52`; Pi ACP is unchanged. The Codex
1.7.0 permission and mode parity work (`approvalsReviewer`, mode `_meta.kind`,
and TypeScript-style permission presentation) is ported with tests and covers
the two Codex commits listed above. The pins now lead the reviewed behavior,
so the drift check no longer reports the following upstream changes; each
still needs an explicit parity decision and, where accepted, characterized
adapter work before it is claimed as supported:

- Claude `caf609b` stable mode catalog with `_meta.kind` and the Auto-mode
  fallback to Accept edits with a client-visible warning;
- Claude per-model token usage on prompt responses, deferred steering while
  user input is pending, native subagents and async tasks, and
  message-specific ACP session forks;
- Codex native ACP subagent sessions, ACP session forks, and AI session title
  generation with a `/rename` command.

Record the decision for each item here before the next pin refresh; a pin
that leads the reviewed behavior must not be advanced again until this list is
resolved.

### 2026-09-20 drift review and parity decisions

`mix acp.compat.check` reported Claude Agent ACP at
`d421f56a6c43cde16d9a7531d08a750a5ef2f04a` (0.79.0, 39 commits past the pin)
and Codex ACP at `d7b07c1b44a28890cdf3d5450f8974a812db5ae2` (1.12.0, 29
commits), plus two new registry agents and 23 registry version moves. Both
references still build on ACP SDK 1.4.0, the version ArborMCP pins and the
newest on npm, so none of the new capabilities are schema changes; they are
extensions negotiated through `_meta`.

Ported, each behind fixture tests (see the 1.5.0 changelog):

- Claude per-session opt-out of `bypassPermissions` (claude-agent-acp#1129);
- Claude AskUserQuestion custom text kept beside the pick (#1031, #1131);
- Codex `request_user_input` form shapes (codex-acp#299); and
- Codex paginated history on `session/load` (codex-acp#481).

Deferred, pre-standard extensions not in SDK 1.4.0, to be revisited when the
weekly ecosystem workflow reports an SDK release that carries them: the
`authStatus` push notification (#1080, #467), `recommendedValue` model and
effort hints (#1111, #491), `asyncTasks` for background terminals (#460),
the tool-call `name` field from an RFD (#1128, #513), and the compaction
mechanisms (#991, #1134, #515), which fold into the existing compaction
decision above.

Not applicable: codex-acp#471 (standalone MCP elicitation finalization),
because ArborMCP forwards MCP elicitations without a synthetic tool call, so
nothing dangles. Upstream-internal: CI, dependency and Codex CLI version
bumps, fork-loading performance, TaskList parsing, model display-name
cosmetics. Kept as ArborMCP's own surface: the Claude main-thread agent config
option, removed upstream in #1112; ArborMCP retains it through 1.x.

Still open from the 2026-09-01 list, deferred to a later minor: the Claude
stable mode catalog with `_meta.kind` and the Auto-mode fallback, per-model
token usage, deferred steering while input is pending, message-specific
forks, and Codex session titles with `/rename`. Native subagents and async
tasks on both sides are covered by the `asyncTasks` deferral above.

The manifest pins now advance to the reviewed heads. The pins lead the
open items above, so they must not advance again until those are decided.

### 2026-09-21 Claude parity sequencing

The four open Claude items from the 2026-09-01 list (the stable mode catalog
with `_meta.kind` and the Auto-mode fallback, per-model token usage, deferred
steering while user input is pending, and message-specific session forks) were
considered for 1.5.0 and deliberately held.

The reason is coverage, not scope. `Arbor.MCP.ACP.Adapters.Claude*` is about 4,390
lines across five modules, the largest of the three adapters, and it is the one
without a characterization gate: 58 unit tests against 629 golden scenarios for
Codex and 123 for Pi. Every parity port in this release leaned on that
substrate, and the Pi gate surfaced three real crashes the moment it existed.
Porting steering and fork behavior, which touch prompt-flow ordering and
session identity, against unit tests alone would land changes that no test can
prove safe. That is the risk §8.1 condition 4 exists to prevent.

The sequence is therefore: build a Claude golden-transcript gate matching
`Arbor.MCP.Test.CodexGolden` and `Arbor.MCP.Test.PiGolden`, then port the four items
behind it, both in 1.6.0. Two notes for whoever picks this up. Per-model usage
is already forwarded as `modelUsage` inside `_meta.ex_mcp.claude_sdk`, so that
item is a decision about presentation shape rather than new plumbing, and
`modes/1` already advertises Auto when the model supports it, so the mode-catalog
gap is `_meta.kind` plus the fallback warning.

Update (2026-09-21): the gate is built and green - see "Claude adapter
characterization gate" above for its areas, isolation rules and the one latent
defect it recorded. The four parity ports are unblocked.

### 2026-09-21 Claude mode kinds and per-model usage

The first two of the four sequenced Claude items are ported behind the gate.
Both were read from the upstream source at the reviewed pin
`d421f56a6c43cde16d9a7531d08a750a5ef2f04a` rather than from the commit
summaries, because the shapes matter.

**Permission mode kinds and the Auto-mode fallback** (claude-agent-acp
`caf609b`, #1025; upstream `src/session-mode.ts`). The reference's
`buildAvailableModes` returns a catalog that no longer consults the model:
`default`/Manual, `acceptEdits`/Accept edits, `plan`/Plan and `auto`/Auto
are always present, `bypassPermissions` is appended only when bypass is
allowed, and every entry carries `_meta: { kind }` with the values
`standard`, `standard`, `plan`, `auto_review` and `full_access`.
`SessionModeManager.configOption` copies each mode's `_meta` onto the
corresponding `mode` config option entry. Because the catalog is stable, Auto
can now be selected on a model that cannot run it, and
`AUTO_MODE_FALLBACK = "acceptEdits"` is what the session runs instead. The
warning mechanism is not a log: `publishFallbackWarning` sends a
`session/update` `agent_message_chunk` with the fixed text
`**Auto mode unavailable:** the selected model does not support Auto mode;
using Accept edits instead.`, guarded by `autoModeFallbackWarningShown` so it
is delivered at most once per session, and a failure to deliver it must not
fail the mode change. A fallback decided while the session is being created
is held in `autoModeFallbackWarningPending` and published on the first
prompt, because there is no session id for the client to receive an update
for yet. `isAutoUnavailable` treats a model the agent never described as
capable, so only a known model without `supportsAutoMode` triggers the
fallback.

ArborMCP matches all of that: the catalog, the kinds on both the mode list and
the config option, the fallback mode, the notice text, the once-per-session
guard, the held notice, and the unknown-model rule. The fallback is applied
at every entry point the reference applies it: `session/new`
(`apply_auto_mode_policy/1` clamps and syncs the SDK with a
`set_permission_mode` control, mirroring `trySyncMode`),
`session/set_mode` and its `mode` / `permission_mode` config aliases
(mirroring `setSessionMode`, which publishes the warning before the
`current_mode_update`), a model switch that invalidates Auto (mirroring
`reconcileForModel` + `publishFallbackState`, which publishes the
`current_mode_update` before the warning - the two orders differ upstream and
are matched), and a permission decision carrying `{type: "setMode", mode:
"auto"}` (mirroring `applyPermissionFallback`, which rewrites the update and
publishes only the warning, leaving the mode state to the SDK's own status
event). ArborMCP's `session/set_mode` returns
`{:messages_and_reply_and_write, ...}` in the fallback case; the Mapper's
`client_response/2` gained a `{:ok, messages, iodata, state}` return for the
permission path.

One consequence is worth recording because it looks like drift and is not:
the elevated Exit Plan option follows the available-mode set, so with a
stable catalog it is always "Yes, and use auto mode". The reference is in the
same state for the same reason (`buildExitPlanModePermissionOptions` reads
`availableModeIds(session.modes)`), and the permission rewrite above is what
keeps that safe on a model without Auto support.

This is a wire change, so §8.1 condition 3 needs its justification. It is
accepted as deliberate reference parity, not as a bug fix. Everything added
is additive - `_meta.kind`, one extra catalog entry - and no existing mode
id, name, description or config-option key is removed or renamed. The only
behavior an existing client can observe changing is that selecting Auto on a
model without Auto support now succeeds as Accept edits instead of returning
`Unsupported Claude permission mode: auto`, and that an inherited Auto lands
on Accept edits instead of silently on Manual. Both are strictly more useful
and both are now reported to the client rather than being invisible. The four
fallback entry points, the once-per-session guard, the held notice and the
unknown-model rule are each pinned by a golden scenario.

**Per-model token usage on prompt responses** (claude-agent-acp `fad4d10`,
#1037). The reference does not leave this in a vendor namespace: `turnOutcome`
puts it on the prompt response as `_meta.quota`, with `token_count` for the
turn and `model_usage` as a list of `{model, token_count}` rows.
`quotaTokenCount` spells one row as `totalTokens`, `inputTokens`,
`cachedInputTokens`, `cachedWriteTokens`, `outputTokens`,
`reasoningOutputTokens`, and the upstream comment is explicit that the
container keys are snake_case and the counters camelCase so the shape matches
codex-acp's. It is equally explicit that the two halves need not add up:
`token_count` mirrors the response's `usage`, which the SDK reports for the
main agent loop only, while the `model_usage` rows come from
`result.modelUsage`, which also counts Task subagents, sidechains and
compaction. `reasoningOutputTokens` is always 0 because Claude bills thinking
inside its output tokens. Critically, `result.modelUsage` is a running total
for the whole `query()` call, so `modelUsageIncrement` derives a result's own
spend by subtracting the previous reading, treats a reading that fell below
the previous one as a restart (the reading itself becomes the increment), and
drops models with nothing to report.

Decision: ArborMCP adopts `_meta.quota` as the reference specifies it, and keeps
`_meta.ex_mcp.claude_sdk.modelUsage` exactly as it is. The adapter now tracks
`last_model_usage` (the previous reading) and `turn_model_usage` (the
increments accumulated for the turn), reset when the turn settles or a new
turn starts, and sorts the rows by model id so the fixtures are stable.

Rejected: keeping per-model usage only under
`_meta.ex_mcp.claude_sdk.modelUsage` and adding characterization scenarios
that pin the current shape. That was a legitimate outcome and it is what the
2026-09-21 sequencing note anticipated, but it does not hold up. The raw map
is Claude's own on three counts: it is keyed by Claude's resolved model
spelling, it uses Claude's field names (`cacheReadInputTokens`,
`cacheCreationInputTokens`, `contextWindow`), and - the decisive one - it is a
running total for the whole Claude process, not the turn's spend, so a client
reading it per prompt gets a number that means something else entirely. A
host would need Claude-specific knowledge to use it and still could not
compare it with the same figure from Codex. Namespacing is the right default
for genuinely vendor-specific data; this is not that, and there is an agreed
cross-agent shape for it. The raw map stays for readers that want the
unprocessed numbers, including the fields `_meta.quota` does not carry.

Not ported here: a cancelled turn that never received a Claude `result` still
answers with a bare `{"stopReason": "cancelled"}`. Upstream's cancellation
lanes carry `usage` and therefore `quota`; ArborMCP's have never carried `usage`
either, so adding `quota` alone would be arbitrary. Giving those responses a
usage figure is its own change with its own fixtures.

Still open from the 2026-09-01 list after this: deferred steering while user
input is pending, message-specific ACP session forks, and Codex session
titles with `/rename`.

### 2026-09-21 ZCode source baseline

ZCode's newly published source repository is tracked from its first public
`main` revision, `872ad960de7ec172591f7e1952f7849229f94521`. The weekly
ecosystem check now reports later `zai-org/ZCode` commits with a direct compare
link, alongside the Claude, Codex, and Pi reference adapters. ZCode Protocol v1
remains the adapter's production boundary in that revision; upstream also
contains an in-progress V4 wire used by its own clients. Treat V4 drift as a
separate migration signal rather than silently changing the adapter's wire
version.

### 2026-09-22 Claude message forks and deferred steering

The last two Claude items from the 2026-09-01 list are resolved: one is a
port, one is not applicable. Both were read from the upstream source at the
reviewed pin `d421f56a6c43cde16d9a7531d08a750a5ef2f04a`.

**Message-specific ACP session forks** (claude-agent-acp `c3ff343`, #1046;
upstream `src/fork-session.ts`). `session/fork` already forked a Claude
session by copying its whole transcript under a new UUID; the gap was forking
at a specific message. What the reference actually specifies:

- the fork point is optional and explicitly versioned. `forkPoint` reads
  `_meta.jetbrains.air.fork` and returns nothing unless `version === 1`, so a
  missing object, a different version, a missing `messageId` and a `messageId`
  that trims to empty all mean "no fork point" and take the unchanged
  whole-session path;
- the id is a *message* id, not a transcript uuid.
  `messageIdForGrouping` keys an assistant turn by its Anthropic API message
  id (`message.id`) because that id is identical at `message_start`, on the
  consolidated assistant message and in the persisted transcript, and keys a
  user message by its own SDK uuid because a user message has no API id.
  An assistant entry that carries an API id is therefore *not* addressable by
  its uuid;
- `forkPointMessageIdCandidates` strips a trailing `:segment:<n>` (older AIR
  builds send their visible segment id) and tries the exact id first, then the
  unsuffixed one, each across the whole history before moving on;
- the match is the *last* entry carrying the id, not the first
  (`history.slice().reverse().find(...)`, and the same last-write-wins rule in
  `assistantGroups`). One Anthropic message id can span several transcript
  entries, one per content block, and the fork has to keep all of them; the
  original commit took the first match and the pin corrects it;
- the fork point is **inclusive**. It is handed to the Agent SDK as
  `forkSession(id, { upToMessageId })`, documented there as "slice transcript
  up to the message whose `uuid` field equals this value (inclusive)"; and
- an id that resolves to nothing is `RequestError.invalidParams` naming the
  `messageId`, never a silent full copy.

ArborMCP matches all of that. `Arbor.MCP.ACP.Adapters.ClaudeSDK.fork_session/2`
extracts the versioned fork point and passes it to
`SessionStore.fork_session/2` as `:fork_message_id`;
`SessionStore.message_grouping_id/1` is `messageIdForGrouping`,
`fork_message_id_candidates/1` is `forkPointMessageIdCandidates`, and
`take_through_fork_point/3` takes the last matching index and keeps the
transcript through it. Eight golden scenarios pin the semantics
(`lifecycle_golden_test.exs`, "fork_session/2 fork points").

Three deliberate deviations, none of them guesses:

- *No live message-id table.* Upstream consults an in-memory
  `messageIdToUuid` first to avoid a disk read, then `getSessionMessages`
  (the active parentUuid chain), then a full import that also carries
  inactive branches. ArborMCP's fork has always read the persisted JSONL file
  directly, which is a superset of the last two: it contains the active chain
  *and* the inactive branches in one pass. The adapter's existing
  `:message_ids` map is keyed uuid-first and would resolve assistant ids by a
  different rule, so it is deliberately not used here. The one thing upstream's
  live map buys that this does not is a fork point from a turn still in flight
  and not yet flushed to disk; forking a session mid-turn was already reading
  from disk, so this is not a regression.
- *No fingerprint/occurrence recovery.* Upstream's full-history path can fall
  back to `messageFingerprint` (a sha256 of the grouped assistant text) plus a
  1-based `messageOccurrence` counted along the branch. That path is reachable
  only when the id lookup fails in both the active chain and the inactive
  branches, it only indexes assistant entries, and it depends on AIR computing
  and sending those two extra fields. ArborMCP's single full-file lookup already
  covers what that path exists to reach; the fields are ignored rather than
  half-implemented.
- *Error code.* The not-found error is wire-visible and now answers -32602
  (invalid params) as upstream does, through a new
  `{:error, {:invalid_params, message}, state}` return that
  `AdapterBridge.handle_adapter_fork_callback/3` maps. Every *other*
  `session/fork` failure (missing session, non-UUID id, no session at all)
  still answers -32603 byte-identically. The golden gate drives `fork_session/2`
  directly and never sees the bridge, so the new tuple is pinned in
  `adapter_bridge_test.exs` alongside a regression test for the -32603 path.

The `_meta.jetbrains.air.fork` spelling is kept exactly as the reference reads
it, deliberately: a client that can fork against claude-agent-acp forks
against ArborMCP unchanged, and inventing a second vendor-neutral alias would be
inventing protocol. §8.1 condition 4 guards session identity, and the guard
holds: a fork with no fork point produces the same bytes it always did, which
is what the unchanged fixtures for the five pre-existing fork scenarios show.

**Deferred steering while user input is pending** (claude-agent-acp
`8710ce1c`, #1045): **not applicable**, for the same class of reason as
codex-acp#471 above - the failure mode needs a mechanism ArborMCP does not have.
Upstream's ACP steering extension injects a follow-up user message into a
*running* SDK turn at `SDKUserMessage.priority` `"now"`, which is interrupting
delivery: the SDK aborts the cycle currently blocked in a user-input callback
and emits `$/cancel_request` for the open permission or elicitation, so the
client's card disappears before it can be answered. Their fix counts pending
user-input requests per session and downgrades the injected message to
`"later"` while the count is non-zero.

ArborMCP never steers, so there is no message to downgrade. The functions that
establish it:

- `Arbor.MCP.ACP.Adapters.ClaudeSDK.Protocol.user_message/2` is the only producer
  of a `"type" => "user"` line, and it has exactly two callers;
- `handle_request("session/prompt", ...)` in `claude_sdk.ex` branches on
  `pending_prompt_id`. With a turn active it returns `{:ok, :skip, ...}` after
  `enqueue_prompt/4` - the message is queued and *nothing* is written to the
  port. Only the idle branch calls `start_prompt/4`, the other caller;
- `Mapper.start_next_queued_prompt/1` is the sole place a queued message is
  written, and its sole call site is the turn-settle path that runs on
  Claude's `result` event, after the prompt response is built; and
- no ArborMCP code writes a `priority` field on any Claude SDK line.

A second prompt therefore cannot pre-empt an outstanding
`session/request_permission` or `elicitation/create`. Two golden scenarios pin
the property rather than leaving it as an assertion in prose
(`permissions_golden_test.exs`, "a concurrent prompt while user input is
pending"): with a permission request and with an elicitation outstanding, a
second `session/prompt` is skipped with no writes, exactly one message in the
whole transcript names the outstanding request (its own creation - nothing
withdraws or re-answers it), the client's answer still lands, and the queued
user message reaches Claude only on the first `result`. The recorded mutation
check makes the queued branch write immediately - upstream's `now` delivery -
and both scenarios fail.

If ArborMCP ever gains real mid-turn steering, this decision is void: that change
must port the pending-user-input counter with it.

Still open from the 2026-09-01 list after this: Codex session titles with a
`/rename` command. The Claude list is clear, so the Claude pin may advance at
the next scheduled review.

### 2026-09-22 Claude chunk message ids

The fork port above closed the *receiving* half of message-specific forks:
ArborMCP resolves a `messageId` a host sends. It left the *sending* half open.
The Claude adapter never stamped `messageId` on any session update, so a host
had no way to learn a fork point from us and had to read Claude's JSONL
transcript itself to find one. This subsection records closing that gap, read
from the same reviewed pin `d421f56a6c43cde16d9a7531d08a750a5ef2f04a`.

Only wiring was missing. `Arbor.MCP.ACP.AdapterEvents.agent_message_chunk/3`,
`agent_thought_chunk/3`, `user_message_chunk/3` and `content_chunk/4` already
accepted a `:message_id` option and stamped it with `Maps.put_present/3`;
`Arbor.MCP.ACP.RequestValidation` already accepted
`optional_nullable_string?(update, "messageId")`; and
`SessionStore.message_grouping_id/1` already implemented the id rule. No
adapter passed the option.

**The rule matches the reference.** `messageIdForGrouping` in
`src/acp-agent.ts` keys an assistant entry by `message.id` when it has one and
falls back to the entry `uuid`. `message_grouping_id/1` is the same function
with the uuid fallback restricted to `user` and `assistant` entries. That is
not a divergence in reachable behavior: upstream's two id lookups run over
`getSessionMessages` and `assistantGroups`, which are already restricted to
SDK user/assistant messages and to non-sidechain assistant entries
respectively, so neither can resolve a `summary` or `system` entry's uuid
either. Our restriction makes structurally-unreachable cases explicit rather
than changing what resolves. No change was needed.

**What is stamped.** `applyMessageId` upstream is a no-op unless the update is
one of `agent_message_chunk`, `user_message_chunk` or `agent_thought_chunk`,
and a no-op when the id is absent. ArborMCP matches that: `tool_call`,
`tool_call_update`, `plan`, `session_info_update`, `current_mode_update`,
`config_option_update`, `available_commands_update` and the usage updates never
carry one. The three coverage paths upstream threads the id through are all
covered:

- *live streamed chunks.* `message_start` is the only streamed event carrying
  the Anthropic API message id, so the adapter captures it into the new
  `stream_message_id` state field — upstream's `currentStreamMessageId` — and
  stamps every `text_delta` / `thinking_delta` chunk that follows with it. The
  field is cleared wherever a turn ends or a session is dropped (the same five
  sites that already clear `current_assistant_text_streamed?`), so a chunk can
  never inherit an id from a previous turn;
- *unstreamed / consolidated assistant text.* `reduce_message/2` computes
  `SessionStore.message_grouping_id/1` from the message wrapper and threads it
  to `handle_assistant_block/3`, which is the path that emits a text block the
  stream did not already deliver; and
- *replay.* `session/load` replays persisted entries through the same
  `reduce_message/2` for assistant entries, and `replay_user_content/2` stamps
  the replayed `user_message_chunk` with the entry's grouping id.

**What is deliberately not stamped**, both cases being chunks ArborMCP
synthesizes rather than chunks Claude sent:

- the Auto-mode fallback notice (`@auto_mode_fallback_notice` in `Mapper`) is
  ArborMCP's own prose about a mode decision. No transcript entry backs it, so any
  id we invented for it would be unresolvable and `fork_session/2` would answer
  -32602. A host forking "at the notice" wants the message before or after it,
  neither of which the notice identifies; and
- the `result` fallback chunk (`result_text_chunk/3`), which re-emits
  `result.result` when a turn streamed nothing. It is built from Claude's
  `result` event, which carries no message id, and the reference emits no chunk
  for `result` at all.

Subagent and sidechain chunks *are* stamped. Upstream's `applyMessageId` runs
on the `parentToolUseId` path too, and our own `fork_point_index/2` matches a
sidechain assistant entry like any other, so an id we stamp there still
resolves. Upstream excludes sidechains only from `assistantGroups`, the
fingerprint-recovery path ArborMCP does not implement.

**The round trip is asserted, not assumed.** A stamped id our own fork rejects
would be worse than no id, so three golden scenarios in `lifecycle_golden_test.exs`
("messageId round trip") read the `messageId` back out of the recorded
transcript and fork at exactly that string: a replayed `agent_message_chunk`
id, a replayed `user_message_chunk` id, and a live streamed chunk id whose
`message_start` matches the persisted assistant entry. Each asserts the fork
succeeds and that the forked file is cut inclusively at the addressed entry.
The `:fork_session` harness step gained function support for this, so nothing
is hand-written into the fork request.

Nine existing fixtures moved, all by pure `messageId` addition (13 added lines,
no deletion, no other key changed): six replayed `user_message_chunk`s keyed by
the transcript uuid, five consolidated assistant chunks keyed by the Anthropic
message id, one scenario's explicit id, and one replayed assistant entry with
no `message.id` keyed by its uuid. Streamed chunks were unaffected because no
pre-existing flow sends a `message_start`; seven new `session_updates`
scenarios cover that path, including the two no-stamp cases above.

Mutation checks (2026-09-22), all in `claude_sdk/mapper.ex`: stamping any id on
the `result` fallback chunk (`result_text_chunk/3`) fails
`the_result_fallback_chunk_carries_no_message_id` and
`a_result_without_streamed_text_emits_a_fallback_chunk`; dropping the
`message_start` clause of `handle_stream_event/2` fails four `message ids`
scenarios and `a_streamed_chunk_message_id_forks_at_the_persisted_message`;
and stamping the Auto-mode fallback notice (`auto_fallback_notice/1`) fails the
four pre-existing catalog and permissions fixtures that carry it, so that
judgement call is pinned without a scenario of its own.

The golden gate drives adapters directly, so it never sees
`Arbor.MCP.ACP.AdapterBridge`. No adapter return shape changed here — only the
content of a message the bridge already forwards — but because the field is
wire-visible, `adapter_bridge_test.exs` gained one test ("chunk messageId")
proving a stamped chunk survives the bridge's JSON round trip, an unstamped one
omits the key entirely, and a `tool_call` never gains it.

## ACP v1 completion and v2 monitoring

The July 2026 stable ACP v1 additions are represented in the runtime and
adapter tests. Boolean session config options require an explicit v1 client
capability, so ArborMCP provides `Capabilities.put/3` with
`:boolean_config_options` and exercises the opt-in in both directions against
the official TypeScript SDK. Do not auto-advertise this capability merely
because a generic event handler can decode the update; the integrating client
must be able to present and change the value correctly.

ACP protocol v2 is Draft and is not part of ArborMCP's advertised production
surface. The pinned interop lane validates the reviewed v1 and v2 schemas,
while the scheduled ACP ecosystem workflow installs the newest SDK to detect
release or schema drift. Version downgrade and SDK dual-router tests protect
continued v1 operation. The versioned architecture, schema-review procedure,
and Preview and Stable adoption gates live in
[`ACP_V2_TRACKING.md`](./ACP_V2_TRACKING.md).

The SDK 1.4.0 unstable compaction experiment is tracked but deliberately not
advertised or implemented. Revisit it only after the capability and update
contract enter the specification; until then, vendor-native compaction events
remain adapter details rather than claims of protocol-level support. The
removed experimental `env_var` auth variant remains available only through the
existing, disabled-by-default Codex legacy compatibility option.

## Execution order

1. Land rc.8's credential-free ACP CLI lifecycle coverage, Pi isolation fix,
   behavior-preserving internal helper deduplication, and Hex documentation
   cleanup.
2. Qualify and publish rc.8, then run the fresh final-candidate soak. **Complete.**
3. Release stable 1.0 with no adapter decomposition mixed into the release diff. **Complete.**
4. Resolve the focused contract mismatches as small correctness or documentation
   changes. **Complete for the 1.x lane** (see the status list above); ambient
   input injection continues case by case.
5. Extract the shared HTTP reducer and the smallest high-value functional cores
   behind characterization tests.
6. Modularize Codex one characterized boundary at a time. `Codex.Protocol`,
   `Codex.Permissions`, `Codex.Content`, and `Codex.MCP` are extracted and
   `Codex.Sessions` holds lookup/update helpers; the lifecycle `Sessions`
   boundary remains, and the root still owns the model catalog, auth helpers,
   turn-failure classification, and session config authorization. The 1.3.0
   failed-turn and per-item streamed-text logic is a natural seed for the
   event-folding and prompt-flow cores. This is behavior-preserving internal
   work: it lands on `master` behind golden tests and ships with the next
   user-visible release rather than forcing a release of its own.
7. Modularize Pi one characterized boundary at a time. **Complete.** All five
   proposed boundaries — `Pi.RPC`, `Pi.Config`, `Pi.Events`, `Pi.PromptFlow`
   and `Pi.Sessions` — are extracted and the root is 1,795 lines (see the
   status subsection above). What remains is optional and outside the
   proposed boundaries: the slash-command surface (the steering and follow-up
   handlers, `command_state/3` and the `slash_result_*` text) could move to
   `Pi.SlashCommands`, and the control-group bookkeeping could become its own
   boundary. Neither is required by the completion criteria.
8. Reduce dependency cycles without changing public or lifecycle semantics.
9. Re-evaluate shared app-server pieces while preparing the post-1.0 ZCode
   adapter; keep vendor-specific protocol semantics separate by default.
10. Make any MCP/ACP package-topology change only through the 2.0 decision and
    migration process in `V2_ROADMAP.md`.
11. Expand the reviewed native ACP matrix and promote agents from initialization
    to session and mock-prompt tiers where their supported configuration permits
    credential-free testing.
12. Keep ACP v2 monitoring non-shipping until its Preview adoption gates are
    met; then implement separate v1/v2 protocol surfaces around shared session
    and effect cores.
13. Fix stdio byte-mode framing for both stdio transports and land the i18n
    payload tier (GitHub #52) as a 1.x correctness fix, ahead of the
    modularization items: it is small, it is user-visible data corruption in
    common deployments, and its subprocess test is the first locale-aware gate
    in CI.
