# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ExMCP is an Elixir implementation of the Model Context Protocol (MCP), enabling AI models to communicate with external tools and resources through a standardized protocol.

## Version Management

### When to Bump Versions
- **Patch version (0.x.Y)**: Bug fixes, documentation updates, minor improvements
- **Minor version (0.X.0)**: New features, non-breaking API changes
- **Major version (X.0.0)**: Breaking API changes (after 1.0.0 release)

### Version Update Checklist
1. Update version in `mix.exs`
2. Update CHANGELOG.md with:
   - Version number and date
   - Added/Changed/Fixed/Removed sections
   - **BREAKING:** prefix for any breaking changes
3. Commit with message: `chore: bump version to X.Y.Z`

### CHANGELOG Format
```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes in existing functionality
- **BREAKING:** API changes that break compatibility

### Fixed
- Bug fixes

### Removed
- Removed features
- **BREAKING:** Removed APIs
```

## Development Commands

```bash
# Essential commands
mix deps.get          # Install dependencies
mix test              # Run all tests
mix test test/ex_mcp/internal/protocol_compliance_test.exs  # Run specific test file
mix format            # Format code (required before committing)
mix credo             # Static code analysis
mix dialyzer          # Type checking (run after significant changes)
mix docs              # Generate documentation
iex -S mix            # Start interactive shell with project loaded

# Development workflow
mix compile --warnings-as-errors  # Compile with strict warnings
MIX_ENV=test mix compile         # Compile for test environment
mix sobelow --skip               # Security analysis
mix coveralls.html               # Generate coverage report

# Repo-only tooling (lives in dev/, never published to Hex)
mix test.suite <unit|compliance|integration|performance|all|ci>
mix test.tags         # List the test tags and what they mean
mix test.cleanup      # Kill stray processes/ports left by crashed tests
mix mcp.sync_spec     # Sync upstream MCP spec docs into docs/mcp-specs/
```

## Architecture

The library follows a layered architecture:

1. **Transport Layer** (`lib/ex_mcp/transport/`)
   - Defines behaviour for different communication protocols
   - Implementations: stdio, Streamable HTTP, BEAM (Erlang processes), test
   - Each transport handles message framing and delivery

2. **Protocol Layer** (`lib/ex_mcp/internal/protocol.ex`)
   - JSON-RPC 2.0 message encoding/decoding
   - Request/response correlation
   - Error handling

3. **Client/Server Layer**
   - `ExMCP.Client`: Manages connections, auto-reconnection, request routing
   - `ExMCP.Server`: Request handling, capability negotiation
   - `ExMCP.Server.Handler`: Behaviour for implementing server handlers

4. **ACP Layer** (`lib/ex_mcp/acp/`)
   - Agent Client Protocol for controlling coding agents
   - `ExMCP.ACP.Client`: GenServer managing agent connections over stdio
   - `ExMCP.ACP.Adapter`: Behaviour for adapting non-native agents (Claude Code, Codex, Pi, ZCode)
   - `ExMCP.ACP.AdapterBridge`: Bridge between ACP and agent-native protocols

5. **Application Layer** (`lib/ex_mcp/application.ex`)
   - OTP application supervision tree
   - Server discovery and management

Everything under `lib/` ships to Hex. Repo-only tooling lives in `dev/`
(`dev/mix/tasks/` and `dev/ex_mcp/spec_sync/`), which is compiled in `:dev` and
`:test` via `elixirc_paths/1` but is deliberately excluded from
`package.files`, so those mix tasks never show up in a consumer's `mix help`.
`ExMCP.Testing.*` is the opposite case: it stays in `lib/` as a published,
documented test kit.

## MCP Protocol Eras

ExMCP 1.0 supports the legacy MCP revisions (`2024-11-05` through
`2025-11-25`) and the wire-incompatible latest stable revision (`2026-07-28`). Treat
the era as a first-class connection property; do not scatter date comparisons
or infer modern behavior from one method in feature code.

| `protocol_mode` | Client opens with | Enabled eras | Fallback |
|---|---|---|---|
| `:legacy_only` | `initialize` | Legacy | Never |
| `:prefer_legacy` | `initialize` | Both | Probe modern only after an eligible protocol failure on a live transport |
| `:prefer_modern` | `server/discover` | Both | Initialize only with positive legacy evidence on a live transport; over stdio, a child that exits on the probe or never answers it is replaced once by a fresh child for `initialize`, after its stop is confirmed |
| `:modern_only` | `server/discover` | Modern | Never |

`1.0.0` defaults to `:prefer_modern`, matching the final rc.8 candidate.
Published rc.5 itself is legacy-only and does not contain modern support.
Tests and deployments that require a specific wire shape must always pass a
mode explicitly instead of relying on the release default. Both preference
modes accept both eras on a server; their preference controls advertised
version order.

Era responsibilities:

- `ExMCP.Internal.VersionRegistry` owns the version lists, era classification,
  enablement, and preference ordering.
- `ExMCP.Client.ConnectionManager`, `EraProbe`, and `EraCache` own selection,
  evidence-based fallback, and peer observations. Never retry an application
  operation in another era.
- A modern observation is pinned and cannot silently downgrade. Legacy cache
  entries expire so upgraded peers can be discovered. A cached-modern probe
  failure is an operator-visible error.
- Over stdio under `:prefer_modern`, a probed child that exits or stays silent
  is closed and replaced by a fresh process for `initialize`, once per
  attempt and within the establish deadline; the probed pipe is never reused,
  and the replacement starts only after the reaper confirms the first child
  stopped. An HTTP probe timeout is legacy evidence under the preference
  modes, since each POST is separate. `:modern_only` never falls back or
  respawns.
- `ExMCP.Server.RequestContext` validates per-request modern metadata and mode
  compatibility. HandlerServer/stdio connections pin on the first valid
  modern request or legacy `initialize` and must reject later era mixing.
- Modern success results require `resultType`. MRTR returns
  `input_required`/`inputResponses` instead of emitting elicitation, Sampling,
  or Roots as independent server-to-client requests.
- Modern HTTP is stateless: every message is a POST, SSE belongs to the
  originating request or `subscriptions/listen`, and no session ID,
  `Last-Event-ID`, GET stream, or DELETE termination is used. Keep this
  distinct from the deprecated 2024-11-05 two-endpoint HTTP+SSE transport,
  which is available only with `legacy_http_sse: true` during 1.x.

When changing protocol code, run focused tests for all four modes and both
strict-era failure directions. A dual-era success test is insufficient: also
assert that ambiguous probe failures do not downgrade, cached modern peers do
not downgrade, the stdio respawn happens at most once and never under
`:modern_only`, and an incompatible request never reaches a Handler callback.
See `docs/ARCHITECTURE.md`, `docs/TRANSPORT_GUIDE.md`, and
`docs/getting-started/MIGRATION.md` for the complete model.

## Key Patterns

- All public APIs use `{:ok, result}` or `{:error, reason}` tuples
- Transport implementations must handle the `ExMCP.Transport` behaviour
- Server handlers implement the `ExMCP.Server.Handler` behaviour
- Use `ExMCP.Types` for type definitions and specs
- Protocol messages follow MCP specification exactly

## Testing Approach

- Unit tests use lightweight in-process test transports (`transport: :test`) and
  hand-written stub modules injected via options. **There is no mocking library**
  — Mox was removed once the last vestigial usage disappeared. Do not reintroduce
  one without a strong reason.
- Property-based testing for protocol encoding/decoding
- Integration tests for client-server communication
- Test files mirror source structure in `test/`

### No `Process.sleep` for synchronization

`Process.sleep/1` is only acceptable when the test is *genuinely about timing*
(e.g. asserting a timeout fires). For everything else use a real
synchronization point — in rough order of preference:

1. `assert_receive` / `refute_receive` on a message the code under test sends
2. `Process.monitor/1` + `assert_receive {:DOWN, ref, :process, pid, reason}`
3. A synchronous round-trip that flushes the pipeline (e.g. `ExMCP.Client.ping/1`
   after firing a notification — the notification is ordered before the ping)
4. Telemetry: `ExMCP.TestHelpers.assert_event/2`, `wait_for_event/2`,
   `refute_event/2`
5. `ExMCP.TestHelpers.wait_until(fun, timeout: ms)` as a deadline-bounded poll

Note that `ExMCP.Client.start_link/1` performs full protocol-era establishment
inside `init/1`, so once it returns `{:ok, pid}` the client is already `:ready`.
That means `initialize` + `notifications/initialized` in the legacy era or a
successful `server/discover` probe in the modern era. Never sleep "to let the
client initialize".

## Common Tasks

When implementing new features:
1. Follow existing patterns in similar modules
2. Add comprehensive tests before implementation
3. Run `mix format` and `mix credo` before committing
4. Update type specs in `lib/ex_mcp/types.ex` if adding new message types
5. Prefer `ExMCP.Server.DSL` over the deprecated `ExMCP.Server.Tools` API

## Client implementation

The public MCP client API is **`ExMCP.Client`** (GenServer). There is no
`client_adapter` / `LegacyAdapter` / `StateMachineAdapter` switch anymore, and
`ExMCP.Client.StateMachine` was deleted when auto-reconnect landed — connection
state is plain fields on the `ExMCP.Client` struct (`:connection_status` is one
of `:connecting`, `:ready`, `:reconnecting`, `:disconnected`).

`ExMCP.Client.start_link/1` connects **synchronously**: the transport
connection and selected-era establishment happen inside `init/1`, so a
successful return means the client is already `:ready`. Legacy mode performs
`initialize` and sends `notifications/initialized`; modern mode completes
`server/discover` and sends no initialized notification.

Internal connection lifecycle helpers live under `ExMCP.Client.*` (for example
`ExMCP.Client.ConnectionManager` and `ExMCP.Client.RequestHandler`). Prefer
`ExMCP.Client` and the top-level `ExMCP.start_client/1` helpers in application
code.

### Auto-reconnection (client)

When the transport closes unexpectedly, `ExMCP.Client` fails pending requests
and reconnects with exponential backoff and jitter (defaults: initial 1s,
multiplier 2, cap 60s, up to 10 attempts). Configure via the `:reconnect`,
`:max_reconnect_attempts`, and `:reconnect_backoff` options on
`ExMCP.Client.start_link/1`. Explicit `disconnect/1`/`stop/2` never triggers
reconnection.

### Health checks (client)

While connected and idle, the client sends a protocol `ping` every
`:health_check_interval` ms (default 30_000; `nil`/`0` disables). If a ping is
still unanswered a full interval later, the transport is treated as closed and
the reconnection path takes over. Health checks are skipped while requests are
in flight. Tests that assert an exact message sequence over more than 30s, or
that a client stays disconnected after transport loss, must account for this —
pass `health_check_interval: nil` and/or `reconnect: false` when the test is
not about those behaviours.

### Telemetry (client)

The client stack emits telemetry such as:

```elixir
# Request lifecycle
[:ex_mcp, :client, :request, :sent]
[:ex_mcp, :client, :request, :completed]

# Connection lifecycle
[:ex_mcp, :client, :connected]
[:ex_mcp, :client, :disconnected]
[:ex_mcp, :client, :era, :settled]
[:ex_mcp, :client, :era, :fallback]
[:ex_mcp, :client, :era, :observed]

# Receiver (transport message loop)
[:ex_mcp, :client, :receiver, :started]
[:ex_mcp, :client, :receiver, :message]

# Reconnection
[:ex_mcp, :client, :reconnect, :attempt]
[:ex_mcp, :client, :reconnect, :success]
[:ex_mcp, :client, :reconnect, :error]
[:ex_mcp, :client, :reconnect, :timeout]
```

### Server DSL

- Prefer `ExMCP.Server.Handler` + `ExMCP.Server.DSL` for tools/resources/prompts.
- `ExMCP.Server.Tools` is **deprecated**, retained throughout 1.x, and planned for removal in **2.0.0**.

## Deprecated / planned removals

| API | Status |
|-----|--------|
| `ExMCP.Server.Tools` (+ `Simplified`, helpers) | Deprecated → **planned for removal in 2.0.0** |
| Client adapter layer (`LegacyAdapter`, etc.) | Already removed; use `ExMCP.Client` |

## Development notes

- Primary public APIs: `ExMCP`, `ExMCP.Client`, `ExMCP.Server` / `Handler` / `DSL`, transports, `ExMCP.HttpPlug`, `ExMCP.ACP.*`, `ExMCP.Authorization`, `ExMCP.Content`, `ExMCP.Types`.
- `ExMCP.Internal.VersionRegistry` is the canonical protocol-version registry. `ExMCP.Protocol.VersionNegotiator` is a compatibility shim for public negotiation helpers and retains a separate, non-wire capability vocabulary.
- Other modules under `ExMCP.*` are internal unless documented otherwise.
