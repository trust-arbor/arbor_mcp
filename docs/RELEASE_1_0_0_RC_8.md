# ArborMCP 1.0.0-rc.8

`1.0.0-rc.8` is a narrow, behavior-preserving follow-up to the published
`1.0.0-rc.7` candidate. It keeps rc.7's MCP and ACP wire behavior,
`:prefer_modern` default, security posture, and lifecycle semantics while
adding real adapter-CLI evidence, correcting Pi configuration isolation, and
consolidating repeated internal safety helpers.

Publishing rc.8 starts the final-candidate soak from the rc.8 artifact. Stable
1.0 remains gated on at least seven calendar days without a release-blocking
regression, the mixed-version rollback drill, and the same-runner performance
comparison.

## What changed since rc.7

- The Pi adapter consistently applies `:agent_dir` to settings, user prompts,
  session discovery, lookup, and safe deletion. Slash-command input hints are
  normalized to the ACP object shape.
- An opt-in `:interop_acp_cli` suite launches the real Claude Code, Codex, and
  Pi CLIs through `Arbor.MCP.ACP.AdapterTransport`. It exercises initialization,
  session creation/listing/close, and clean shutdown without sending a prompt
  or calling an LLM.
- Subprocess environment isolation, positive-integer option lookup, and
  symlink-aware workspace containment use shared internal helpers. The
  refactor preserves the rc.7 option precedence, environment policy, path
  decisions, errors, and wire output.
- ACP examples now show the adapter transport required by the three managed
  CLI adapters.
- Repository-only maintenance and 2.0 planning now record the post-1.0
  functional-core, dependency-direction, adapter decomposition, and package
  topology work.
- Approximately 200 KB of raw internal planning, audit, migration, coverage,
  and release-history Markdown remains in Git but is omitted from the Hex
  source archive and HexDocs guide navigation.

There are no intended public API removals, MCP/ACP wire changes, new protocol
defaults, process-ownership changes, or new runtime dependencies in rc.8.

## Installation

```elixir
{:arbor_mcp, "~> 1.0.0-rc.8"}
```

Pin rollout policy when it must not change with a package upgrade:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
# Emergency legacy-era rollback; exact rc.5 behavior still requires package rollback:
# config :arbor_mcp, protocol_mode: :legacy_only
```

## ACP CLI interoperability

The ordinary CI jobs do not require vendor CLIs. Run the real-CLI suite
explicitly on a host with all three executables installed:

```bash
mix test --only interop_acp_cli
```

The suite fails rather than silently skipping when a requested executable is
missing. Override executable discovery with `CLAUDE_CODE_EXECUTABLE`,
`CODEX_PATH`, or `PI_ACP_PI_COMMAND`. Every test uses isolated temporary home,
configuration, and session directories; Pi receives a deliberately unreachable
dummy model endpoint because it requires a configured model before session
creation, but the lifecycle test never contacts that endpoint.

## Qualification evidence and ownership

The release tag identifies the exact source commit. Its GitHub Actions run is
the durable evidence record; the external-conformance job uploads the complete
MCP runner output.

| Gate | Owner | rc.8 evidence |
|---|---|---|
| Full unit/integration/coverage matrix | Release maintainer | GitHub Actions on the release commit |
| MCP conformance and official SDK interop | Protocol maintainer | External conformance artifact and pinned Node.js lanes |
| ACP official SDK interop | ACP maintainer | Existing bidirectional TypeScript SDK suite |
| Real adapter lifecycle | ACP maintainer | Explicit `mix test --only interop_acp_cli` run on a CLI-equipped host |
| Pi isolation | ACP maintainer | Pi unit tests plus real-CLI lifecycle using isolated state |
| Public docs and source archive | Release maintainer | `mix docs`, `mix hex.build --unpack`, and packaged-link inspection |
| Security and dependencies | Security maintainer | dependency audit, Sobelow, and unchanged advisory mitigations |
| Modern-preferred soak | Release maintainer | begins when rc.8 is published; minimum seven calendar days |
| Mixed-cluster rollback drill | Deployment operator | required before stable 1.0 |

### Local candidate-preparation snapshot

On 2026-08-13, the rc.8 candidate passed these local gates on macOS 26.5.2
arm64 with Elixir 1.19.5 / Erlang/OTP 28:

- unit lane: 20 doctests, 34 properties, and 3,094 tests;
- integration lane: 20 doctests, 34 properties, and 3,808 tests;
- performance/stress lane: 20 doctests, 34 properties, and 3,754 tests;
- MCP compliance: 591 tests;
- official ACP SDK interop: 4 tests;
- real CLI lifecycle: 3 tests using Claude Code 2.1.231, Codex CLI 0.147.0,
  and Pi 0.84.1;
- formatting, warnings-as-errors compilation, strict Credo, Dialyzer,
  dependency advisory audit, skip-tag audit, and Sobelow; and
- warnings-as-errors ExDoc plus unpacked Hex archive inspection. The compressed
  package contents decreased from 798,062 to 728,416 bytes, and the unpacked
  retained documentation had no missing relative Markdown targets.

One loaded-suite run exposed a 100 ms test-only mailbox timeout in the
request-ID-capacity test. Its explicit bound is now one second, consistent with
the surrounding asynchronous transport tests; the isolated 20-run
reproduction and the complete rerun both passed. No production timeout changed.

This snapshot is preparation evidence, not a substitute for the GitHub Actions
run on the eventual release commit or its external MCP conformance artifact.

The modern conformance harness remains pinned to
`@modelcontextprotocol/conformance@0.2.0-alpha.10` until a stable
2026-07-28-aware runner is available. Official TypeScript SDK v2 interop remains
pinned to `2.0.0`; legacy conformance remains pinned independently to `0.1.16`.

## Post-merge publish checklist

1. Confirm every GitHub Actions job is green on the release commit.
2. Run the opt-in real-CLI ACP lifecycle suite and record the host/tool versions.
3. Inspect the unpacked Hex archive and confirm repository-only planning and
   release documents are absent while all retained guide links resolve.
4. Tag `v1.0.0-rc.8` at the release commit.
5. Create a GitHub **prerelease** for `v1.0.0-rc.8` pointing to this record and
   `CHANGELOG.md`.
6. Publish with `mix hex.publish`.
7. Start the rc.8 soak and complete the mixed-version rollback drill before
   stable `1.0.0`.
