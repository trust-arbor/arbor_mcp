# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ArborMCP is an Elixir implementation of the Model Context Protocol (MCP), enabling AI models to communicate with external tools and resources through a standardized protocol.

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
mix test test/arbor_mcp/internal/protocol_compliance_test.exs  # Run specific test file
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

1. **Transport Layer** (`lib/arbor_mcp/transport/`)
   - Defines behaviour for different communication protocols
   - Implementations: stdio, Streamable HTTP, BEAM (Erlang processes), test
   - Each transport handles message framing and delivery

2. **Protocol Layer** (`lib/arbor_mcp/internal/protocol.ex`)
   - JSON-RPC 2.0 message encoding/decoding
   - Request/response correlation
   - Error handling

3. **Client/Server Layer**
   - `Arbor.MCP.Client`: Manages connections, auto-reconnection, request routing
   - `Arbor.MCP.Server`: Request handling, capability negotiation
   - `Arbor.MCP.Server.Handler`: Behaviour for implementing server handlers

4. **ACP Layer** (`lib/arbor_mcp/acp/`)
   - Agent Client Protocol for controlling coding agents
   - `Arbor.MCP.ACP.Client`: GenServer managing agent connections over stdio
   - `Arbor.MCP.ACP.Adapter`: Behaviour for adapting non-native agents (Claude Code, Codex, Pi, ZCode)
   - `Arbor.MCP.ACP.AdapterBridge`: Bridge between ACP and agent-native protocols

5. **Application Layer** (`lib/arbor_mcp/application.ex`)
   - OTP application supervision tree
   - Server discovery and management

Everything under `lib/` ships to Hex. Repo-only tooling lives in `dev/`
(`dev/mix/tasks/` and `dev/arbor_mcp/spec_sync/`), which is compiled in `:dev` and
`:test` via `elixirc_paths/1` but is deliberately excluded from
`package.files`, so those mix tasks never show up in a consumer's `mix help`.
`Arbor.MCP.Testing.*` is the opposite case: it stays in `lib/` as a published,
documented test kit.

## MCP Protocol Eras

ArborMCP 1.0 supports the legacy MCP revisions (`2024-11-05` through
`2025-11-25`) and the wire-incompatible latest stable revision (`2026-07-28`). Treat
the era as a first-class connection property; do not scatter date comparisons
or infer modern behavior from one method in feature code.

| `protocol_mode` | Client opens with | Enabled eras | Fallback |
|---|---|---|---|
| `:legacy_only` | `initialize` | Legacy | Never |
| `:prefer_legacy` | `initialize` | Both | Probe modern only after an eligible protocol failure on a live transport |
| `:prefer_modern` | `server/discover` | Both | Initialize only with positive legacy evidence on a live transport |
| `:modern_only` | `server/discover` | Modern | Never |

`1.0.0` defaults to `:prefer_modern`, matching the final rc.8 candidate.
Published rc.5 itself is legacy-only and does not contain modern support.
Tests and deployments that require a specific wire shape must always pass a
mode explicitly instead of relying on the release default. Both preference
modes accept both eras on a server; their preference controls advertised
version order.

Era responsibilities:

- `Arbor.MCP.Internal.VersionRegistry` owns the version lists, era classification,
  enablement, and preference ordering.
- `Arbor.MCP.Client.ConnectionManager`, `EraProbe`, and `EraCache` own selection,
  evidence-based fallback, and peer observations. Never retry an application
  operation in another era.
- A modern observation is pinned and cannot silently downgrade. Legacy cache
  entries expire so upgraded peers can be discovered. A cached-modern probe
  failure is an operator-visible error.
- `Arbor.MCP.Server.RequestContext` validates per-request modern metadata and mode
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
not downgrade, and an incompatible request never reaches a Handler callback.
See `docs/ARCHITECTURE.md`, `docs/TRANSPORT_GUIDE.md`, and
`docs/getting-started/MIGRATION.md` for the complete model.

## Key Patterns

- All public APIs use `{:ok, result}` or `{:error, reason}` tuples
- Transport implementations must handle the `Arbor.MCP.Transport` behaviour
- Server handlers implement the `Arbor.MCP.Server.Handler` behaviour
- Use `Arbor.MCP.Types` for type definitions and specs
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
3. A synchronous round-trip that flushes the pipeline (e.g. `Arbor.MCP.Client.ping/1`
   after firing a notification — the notification is ordered before the ping)
4. Telemetry: `Arbor.MCP.TestHelpers.assert_event/2`, `wait_for_event/2`,
   `refute_event/2`
5. `Arbor.MCP.TestHelpers.wait_until(fun, timeout: ms)` as a deadline-bounded poll

Note that `Arbor.MCP.Client.start_link/1` performs full protocol-era establishment
inside `init/1`, so once it returns `{:ok, pid}` the client is already `:ready`.
That means `initialize` + `notifications/initialized` in the legacy era or a
successful `server/discover` probe in the modern era. Never sleep "to let the
client initialize".

## Common Tasks

When implementing new features:
1. Follow existing patterns in similar modules
2. Add comprehensive tests before implementation
3. Run `mix format` and `mix credo` before committing
4. Update type specs in `lib/arbor_mcp/types.ex` if adding new message types
5. Use `Arbor.MCP.Server.Handler` and `Arbor.MCP.Server.DSL`; the Tools family is removed in v2

## Client implementation

The public MCP client API is **`Arbor.MCP.Client`** (GenServer). There is no
`client_adapter` / `LegacyAdapter` / `StateMachineAdapter` switch anymore, and
`Arbor.MCP.Client.StateMachine` was deleted when auto-reconnect landed — connection
state is plain fields on the `Arbor.MCP.Client` struct (`:connection_status` is one
of `:connecting`, `:ready`, `:reconnecting`, `:disconnected`).

`Arbor.MCP.Client.start_link/1` connects **synchronously**: the transport
connection and selected-era establishment happen inside `init/1`, so a
successful return means the client is already `:ready`. Legacy mode performs
`initialize` and sends `notifications/initialized`; modern mode completes
`server/discover` and sends no initialized notification.

Internal connection lifecycle helpers live under `Arbor.MCP.Client.*` (for example
`Arbor.MCP.Client.ConnectionManager` and `Arbor.MCP.Client.RequestHandler`). Prefer
`Arbor.MCP.Client` and the top-level `Arbor.MCP.start_client/1` helpers in application
code.

### Auto-reconnection (client)

When the transport closes unexpectedly, `Arbor.MCP.Client` fails pending requests
and reconnects with exponential backoff and jitter (defaults: initial 1s,
multiplier 2, cap 60s, up to 10 attempts). Configure via the `:reconnect`,
`:max_reconnect_attempts`, and `:reconnect_backoff` options on
`Arbor.MCP.Client.start_link/1`. Explicit `disconnect/1`/`stop/2` never triggers
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
[:arbor_mcp, :client, :request, :sent]
[:arbor_mcp, :client, :request, :completed]

# Connection lifecycle
[:arbor_mcp, :client, :connected]
[:arbor_mcp, :client, :disconnected]
[:arbor_mcp, :client, :era, :settled]
[:arbor_mcp, :client, :era, :fallback]
[:arbor_mcp, :client, :era, :observed]

# Receiver (transport message loop)
[:arbor_mcp, :client, :receiver, :started]
[:arbor_mcp, :client, :receiver, :message]

# Reconnection
[:arbor_mcp, :client, :reconnect, :attempt]
[:arbor_mcp, :client, :reconnect, :success]
[:arbor_mcp, :client, :reconnect, :error]
[:arbor_mcp, :client, :reconnect, :timeout]
```

### Server DSL

- Prefer `Arbor.MCP.Server.Handler` + `Arbor.MCP.Server.DSL` for tools/resources/prompts.
- The `Server.Tools` family is removed in v2. Use Handler + DSL and `Arbor.MCP.Server.Result`. ExMCP 1.x retains its deprecated APIs on the maintenance branch.

## Deprecated / planned removals

| API | Status |
|-----|--------|
| `Arbor.MCP.Server.Tools` (+ `Simplified`, helpers) | Removed in v2; use Handler + DSL + Result |
| Client adapter layer (`LegacyAdapter`, etc.) | Already removed; use `Arbor.MCP.Client` |

## Development notes

- Primary public APIs: `Arbor.MCP`, `Arbor.MCP.Client`, `Arbor.MCP.Server` / `Handler` / `DSL`, transports, `Arbor.MCP.HttpPlug`, `Arbor.MCP.Authorization`, `Arbor.MCP.Content`, `Arbor.MCP.Types`.
- `Arbor.MCP.Internal.VersionRegistry` is the canonical legacy protocol-version registry. The accepted retirement of `VersionNegotiator.build_capabilities/1` removes its separate capability vocabulary; see `docs/API_REFERENCE.md` for retained negotiation helpers.
- ACP lives in `trust-arbor/arbor_acp` under `Arbor.ACP.*`; shared mechanics live in `trust-arbor/arbor_rpc` under `Arbor.RPC.*`.
- ExMCP 1.x maintenance and backport rules are in `docs/MAINTENANCE_POLICY.md`.
- Other modules under `Arbor.MCP.*` are internal unless documented otherwise.
