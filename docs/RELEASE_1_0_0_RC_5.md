# ArborMCP 1.0.0-rc.5

> **Historical release note:** This document describes rc.5 as it shipped.
> MCP 2026-07-28 was released afterward, so rc.5 became the final
> pre-modern consolidation RC rather than the final RC before stable 1.0.
> Additional RCs now qualify the dual-era implementation described in the
> [migration plan](MCP_2026_07_28_MIGRATION_PLAN.md).

rc.5 removed duplicated protocol paths, hardened the client and HTTP server
lifecycle, and fixed several live ACP adapter correctness bugs while retaining
support for MCP `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`.

## Highlights

- One canonical MCP method registry and shared server dispatcher/result
  normalizer now drive HTTP, stdio, HandlerServer, and request-processor paths.
- Client auto-reconnection and health checks now work on persistent
  transports, with bounded handshake timeouts and correct async POST state.
- Streamable-HTTP resource subscriptions are retained per client session,
  cleaned up by the SessionManager lifecycle, and broadcast through ETS-backed
  indexes without a singleton notification bottleneck.
- `Arbor.MCP.HttpPlug` now exposes `:handler_call_timeout` as a server-side Handler
  deadline distinct from client request and SSE timeouts.
- HTTP security and lifecycle fixes cover DNS rebinding, TLS option
  application, session-ID validation, SSE registry ownership, handler crash
  isolation, and process teardown.

## ACP correctness

- Claude SDK streamed assistant text is no longer delivered twice when a final
  assistant block repeats text already emitted through deltas. Multiple
  non-streamed blocks and distinct identical messages remain intact.
- Codex structured command, file-change, and permission decisions are
  validated and round-trip without map-to-string crashes or lossy downgrades.
- Codex file-change notifications map complete ordered snapshots while retaining
  compatibility with legacy nested and flat patch payloads.
- ACP initialization has a bounded lifecycle and cleans up spawned transports
  on handshake failure.

## Compatibility notes

- URL-mode `elicitation/create` requests now reach
  `handle_url_elicitation/3`. Form-only handlers retain a warned compatibility
  fallback and receive the URL payload.
- Raw Handler maps using protocol fields such as `:input_schema`,
  `:output_schema`, `:mime_type`, and `:uri_template` now emit the correct MCP
  lower-camel-case wire names.
- Several public APIs now consistently return tagged tuples, invalid JWTs
  without a numeric `exp` fail closed by default, and malformed security
  configuration is rejected rather than silently accepted. See
  `CHANGELOG.md` for the complete compatibility list.

## Deprecations

`Arbor.MCP.Server.Tools` and the non-protocol image transformation stubs remain
available in rc.5 and throughout 1.x but are deprecated for removal in 2.0.0. New server code
should use `Arbor.MCP.Server.Handler` with `Arbor.MCP.Server.DSL`.

## Verification

- Full GitHub Actions matrix across Elixir 1.17 through 1.20 and OTP 27 through
  29
- MCP compliance suite
- Full coverage suite
- Performance and stress suite
- Both Node.js interoperability directions
- Dialyzer, Credo, Sobelow, strict compilation, and Hex package build

## Install

```elixir
{:arbor_mcp, "~> 1.0.0-rc.5"}
```
