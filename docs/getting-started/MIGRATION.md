# Historical ExMCP Migration Notes

For the current package split and Runtime APIs, start with the
[v1-to-v2 migration guide](../guides/MIGRATING_V1_TO_V2.md). ArborMCP RC1 is
published; the corrected independent-version replacements are pending. its [RC notes](../guides/V2_RELEASE_CANDIDATE.md) describe the
current testing scope and limits.

The record below preserves the ExMCP 0.x and 1.x migrations, including the
rc.5-to-modern protocol rollout. Its `ExMCP.*` names, `:ex_mcp` dependencies,
old API examples and release-candidate planning language belong to those
historical versions. They are not ArborMCP installation or API instructions.
For current protocol-mode configuration, use the
[configuration guide](../CONFIGURATION.md#protocol-eras-and-modes).


## Table of Contents

- [Upgrading from rc.5 / legacy MCP to the 1.0 dual-era release](#upgrading-from-rc5--legacy-mcp-to-the-10-dual-era-release)
- [Deprecations toward 2.0.0](#deprecations-toward-200)
- [Planning for ExMCP 2.0](#planning-for-exmcp-20)
- [Upgrading to v0.6.0 from v0.5.x](#upgrading-to-v060-from-v05x)
- [Upgrading to v0.5.0 from v0.4.x](#upgrading-to-v050-from-v04x)
- [General Migration Tips](#general-migration-tips)

## Upgrading from rc.5 / legacy MCP to the 1.0 dual-era release

ExMCP 1.0 includes MCP 2026-07-28 support. This is the latest stable protocol
revision and is wire incompatible with the pre-2026 revisions supported by
rc.5, but ExMCP itself has not yet published a stable 1.0 API. Landing the
protocol transition in the remaining release candidates gives 1.0 one coherent
compatibility baseline; waiting for ExMCP 2.0 would make the first stable
release immediately obsolete.

This does **not** waive ExMCP API compatibility. Existing 1.x functions,
callbacks, struct fields, and legacy protocol behavior remain available. The
deprecated public APIs identified below are retained until ExMCP 2.0.

### What changes on the wire

| Concern | MCP 2025-11-25 and earlier | MCP 2026-07-28 |
|---|---|---|
| Connection establishment | `initialize`, then `notifications/initialized` | Side-effect-free `server/discover`; no initialized notification |
| Request context | Connection-scoped initialization state | Required per-request `_meta`, including protocol version and client context |
| Result shape | Method-specific result; no discriminator | Every successful result includes `resultType` |
| Additional client input | Server-to-client Roots, Sampling, and Elicitation requests | `input_required` result; client repeats the original operation with `inputResponses` and opaque `requestState` |
| Notifications | Connection channel or legacy HTTP GET stream | Explicit `subscriptions/listen` request |
| Streamable HTTP | Session IDs, optional GET SSE stream, DELETE termination | Stateless POST; request and subscription SSE stay on their owning POST response; MCP endpoint GET/DELETE return 405 |
| HTTP routing metadata | Primarily JSON body and session headers | Body-derived `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and annotated `Mcp-Param-*` headers |

ExMCP normalizes these differences behind its existing Client and Handler APIs
where possible. Code that constructs raw JSON-RPC, inspects wire maps, mounts
custom HTTP middleware, or implements transport adapters must handle both
shapes explicitly.

### Choose an explicit protocol mode

Do not let a release-default change decide a production rollout. Set the mode
globally or on each client/server while migrating:

```elixir
# config/runtime.exs
config :ex_mcp, protocol_mode: :legacy_only

# A per-connection value overrides the application setting.
ExMCP.Client.start_link(
  transport: :http,
  url: "https://mcp.example.com/mcp",
  protocol_mode: :prefer_modern
)

forward "/mcp", ExMCP.HttpPlug,
  handler: MyApp.MCPServer,
  protocol_mode: :prefer_modern
```

| Mode | Client behavior | Server behavior | Recommended use |
|---|---|---|---|
| `:legacy_only` | Sends `initialize`; never probes modern | Accepts only legacy requests | Legacy protocol era (not an exact rc.5 package rollback) |
| `:prefer_legacy` | Tries `initialize`; probes modern only after an eligible protocol failure on a live transport | Accepts both eras; advertises legacy versions first | First compatibility canary |
| `:prefer_modern` | Probes with `server/discover`; falls back only when the response proves the peer is legacy and the transport remains usable | Accepts both eras; advertises modern versions first | Target dual-era deployment after canaries pass |
| `:modern_only` | Uses `server/discover`; never falls back | Accepts only modern requests | Conformance, new closed ecosystems, and final legacy retirement |

`1.0.0-rc.6` introduced the `:prefer_modern` application default. Stable
`1.0.0` retains the same default and behavior as the final rc.8 candidate.
Published rc.5 is legacy-only and does not contain these modes. Pin
a mode explicitly if your deployment cannot tolerate a release-default
transition.

### Recommended rollout

1. Upgrade both sides with `:legacy_only` and run the existing rc.5 tests. This
   isolates ExMCP API regressions from protocol-era differences.
2. Make servers dual-era with `:prefer_legacy`. Legacy clients keep working;
   modern canaries can now establish with `server/discover`.
3. Move a small client cohort to `:prefer_modern`. Watch the
   `[:ex_mcp, :client, :era, ...]` telemetry for the selected era and fallbacks.
4. Expand `:prefer_modern` only after every peer identity has been observed.
   Modern observations are pinned and cannot silently downgrade. Legacy
   observations expire after five minutes by default so upgraded peers are
   probed again; use `era_cache_legacy_ttl` to tune that interval or
   `reset_era_cache: true` for a deliberate re-probe.
5. Use `:modern_only` only when all reachable peers implement 2026-07-28. A
   failure in this mode is intentional evidence of an incompatible peer, not a
   reason to retry with `initialize`.

Test every transport and both directions separately. At minimum cover legacy
client → dual-era server, modern client → dual-era server, and the two strict
same-era pairs. Mixed strict-era pairs must fail without dispatching an
application operation.

### HTTP migration notes

`use_sse: true` on an HTTP **client** controls the standalone GET stream used by
pre-2026 Streamable HTTP. ExMCP turns it off after a connection settles on the
modern era; modern request and subscription SSE responses need no flag.

The older MCP 2024-11-05 two-endpoint HTTP+SSE transport (`GET /sse` plus its
announced POST endpoint) is a different compatibility path. It is deprecated,
disabled by default, and available during 1.x only with
`legacy_http_sse: true`. A dual-era protocol mode does not enable it, and
`:modern_only` never exposes it.

Beginning with `1.0.0-rc.7`, legacy SSE events are persisted
before delivery. An ordinary GET-stream disconnect retains the MCP session,
subscriptions, and bounded replay history until explicit DELETE or TTL expiry.
A reconnect using the same session and `Last-Event-ID` receives events
published during the connection gap. Deployments should therefore size the
session TTL and replay bound rather than relying on disconnect to delete state.

See the [Configuration Guide](../CONFIGURATION.md#protocol-eras-and-modes) for
the complete option reference and the
[Transport Guide](../TRANSPORT_GUIDE.md#streamable-http) for HTTP
request/response shapes.

## Deprecations toward 2.0.0

### `ExMCP.Server.Tools` → `ExMCP.Server.DSL`

`ExMCP.Server.Tools`, `ExMCP.Server.Tools.Simplified`, and related helpers
(`Builder`, `Helpers`, `Registry`, `ResponseNormalizer`, `ASTValidator`) are
**deprecated**, retained throughout 1.x, and planned for removal in **2.0.0**.

```elixir
# Before (deprecated — compile warning)
defmodule MyServer do
  use ExMCP.Server.Handler
  use ExMCP.Server.Tools

  tool "echo", "Echo" do
    param :message, :string, required: true
    handle fn %{message: message}, state ->
      {:ok, text: message}
    end
  end
end

# After (supported)
defmodule MyServer do
  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "echo", "Echo" do
    param :message, :string, required: true
    run fn %{message: message}, state ->
      {:ok, message, state}
    end
  end
end
```

Notes:

- Prefer `run` over `handle` for tool bodies.
- DSL modules get `start_link/1` and can declare resources and prompts too.
- See [DSL_GUIDE.md](../DSL_GUIDE.md) for param types, results, and compile-time checks.

## Planning for ExMCP 2.0

The [ExMCP 2.0 roadmap](https://github.com/azmaveth/ex_mcp/blob/master/docs/V2_ROADMAP.md) is the canonical plan for public API
removals, per-server runtime ownership, bounded handler scheduling, replaceable
state/replay stores, and API consolidation. It also records which ideas are
eligible for behavior-preserving 1.x backports.

An unchanged function signature is not the complete compatibility test for a
backport. Wire output and ordering, callback process identity, links,
cancellation, state ordering, supervision names, defaults, and documented side
effects are part of the 1.x contract too. Lifecycle and ownership changes stay
in 2.0 even when they could be hidden behind existing arities.

## Upgrading to v0.6.0 from v0.5.x

v0.6.0 includes significant enhancements and some breaking changes. This section provides step-by-step migration instructions.

### 1. Update Dependencies

Update your `mix.exs`:

```elixir
# Before (v0.5.x)
{:ex_mcp, "~> 0.5.0"}

# After (v0.6.x)
{:ex_mcp, "~> 0.6.0"}
```

Run `mix deps.update ex_mcp` to get the latest version.

### 2. Test Tagging System (New Feature)

v0.6.0 introduces a comprehensive test tagging system. If you have existing tests, consider adopting the new tagging strategy:

```elixir
# Add module tags to your tests
defmodule MyProjectTest do
  use ExUnit.Case, async: true
  
  # Add relevant tags
  @moduletag :unit
  @moduletag :my_feature
  
  # Your existing tests...
end
```

**New test tasks available:**

- **mix test.suite unit** - Run only unit tests
- **mix test.suite integration** - Run integration tests
- **mix test.tags** - List all available tags

### 3. OAuth 2.1 Enhancements

If you're using OAuth features, no breaking changes are required, but new capabilities are available:

```elixir
# New OAuth configuration options in config/config.exs
config :ex_mcp, :oauth2_server_config,
  # Enhanced security features now available
  introspection_endpoint: "https://auth.example.com/introspect",
  authorization_server: "https://auth.example.com",
  required_scopes: ["mcp:read"],
  token_cache_ttl: :timer.minutes(5)
```

### 4. MCP 2025-06-18 Protocol Support

v0.6.0 added support for the MCP 2025-06-18 protocol version. Current ExMCP
versions retain MCP 2025-11-25 as the newest legacy revision and add modern
MCP 2026-07-28 behind the protocol modes described above.

```elixir
# In your configuration
config :ex_mcp,
  protocol_version: "2025-11-25"
```

**New features available:**
- Structured tool output with `outputSchema`
- Enhanced resource metadata
- Improved security features

### 5. BEAM-Local Transport Updates

Use `:beam` for BEAM-local MCP clients and servers:

```elixir
# BEAM-local MCP transport
ExMCP.Client.start_link(transport: :beam, server: server_pid)
MyServer.start_link(transport: :beam)
```

The old `ExMCP.Native` direct dispatcher and public `:native` transport alias were removed before 1.0. Use `transport: :beam` with a server pid for BEAM-local MCP.

### 6. Python MCP SDK Interoperability

v0.6.0 adds complete Python MCP SDK integration examples. No breaking changes, but new capabilities:

- Elixir clients ↔ Python servers (stdio and HTTP)
- Python clients ↔ Elixir servers
- Hybrid architectures with performance-based routing

See `examples/python_integration/` for complete examples.

## Upgrading to v0.5.0 from v0.4.x

### 1. Transport Renaming

The biggest breaking change in v0.5.0 was transport renaming:

```elixir
# Before (v0.4.x)
ExMCP.Client.start_link(transport: :sse, url: "http://localhost:8080/mcp")
MyServer.start_link(transport: :sse, port: 8080)

# After (v0.5.x+)
ExMCP.Client.start_link(transport: :http, url: "http://localhost:8080/mcp")
MyServer.start_link(transport: :http, port: 8080)
```

**Rationale:** The `:sse` transport identifier was renamed to `:http` before the
1.0 release candidates. In current ExMCP versions, use `transport: :http`.
Modern SSE streams are owned by their POST requests and require no server flag;
`use_sse: true` retains the client GET stream for pre-2026 Streamable HTTP.
The separate MCP 2024-11-05 HTTP+SSE transport is deprecated, disabled on new
servers, and available during 1.x only by explicitly setting
`legacy_http_sse: true` (`sse_enabled: true` remains an rc.5-compatible alias).

### 2. Authorization API Changes

OAuth 2.1 integration was significantly enhanced:

```elixir
# Before (v0.4.x)
# Limited OAuth support

# After (v0.5.x+)
# Full OAuth 2.1 Resource Server implementation
config :ex_mcp, :oauth2_server_config,
  introspection_endpoint: "https://auth.example.com/introspect",
  required_scopes: ["mcp:read"]
```

### 3. Logging Integration

Enhanced MCP logging protocol support:

```elixir
# New in v0.5.0+
{:ok, _} = ExMCP.Client.set_log_level(client, "debug")
:ok = ExMCP.Server.send_log_message(server, "info", "Operation completed", %{result: "success"})
```

MCP 2026-07-28 deprecates the protocol Logging feature. ExMCP retains the
existing logging APIs and legacy methods throughout 1.x, but new integrations
should write stdio diagnostics to stderr and use OpenTelemetry for structured
observability.

### MCP 2026-07-28 feature deprecations

Roots and Sampling are also protocol-deprecated in MCP 2026-07-28. They remain
available in ExMCP 1.x for peers that negotiate a revision containing them and
for modern MRTR compatibility. Migrate Roots to explicit tool parameters,
resource URIs, or server configuration. Migrate Sampling to direct LLM provider
API calls. These notices do not remove or change the existing 1.x public
functions and callbacks.

## General Migration Tips

### 1. Check Breaking Changes

Always review the [CHANGELOG.md](../../CHANGELOG.md) for your target version to understand all breaking changes.

### 2. Update Tests Gradually

When upgrading:

1. Run your existing test suite against the new version
2. Fix any failing tests due to API changes
3. Consider adopting new testing patterns (like the v0.6.0 tagging system)

### 3. Configuration Updates

Review your `config/config.exs` for new configuration options:

```elixir
# Common configuration to review
config :ex_mcp,
  protocol_mode: :prefer_modern,   # Explicit dual-era policy
  protocol_version: "2025-11-25", # Legacy revision preference
  oauth2_enabled: true,            # If using OAuth
  structured_output_enabled: true # New in v0.6.0
```

### 4. Example Code Updates

Check the `examples/` directory for updated patterns and new integration examples that match your use case.

### 5. Performance Considerations

Each version includes performance improvements. Consider:

- Using `transport: :beam` for local client/server calls in the same BEAM VM
- HTTP transport for network communication
- stdio transport for external tool integration

## Getting Help

If you encounter issues during migration:

1. Check the [troubleshooting guide](../TROUBLESHOOTING.md)
2. Review relevant examples in the `examples/` directory
3. Open an issue on GitHub with your specific migration scenario

## Version Support

- **v1.0.0**: Stable modern-preferred release; wire- and API-compatible with rc.8 after its final-candidate soak, plus an internal OAuth callback parser fix for a runtime-order crash.
- **Published v1.0.0-rc.8**: Final modern-preferred candidate; preserves rc.7 wire behavior while adding real adapter-CLI lifecycle evidence, Pi configuration isolation, internal helper deduplication, and slimmer Hex packaging.
- **Published v1.0.0-rc.7**: MCP **2026-07-28** modern support plus the negotiated 2024-11-05 through 2025-11-25 legacy revisions; ACP major **v1**. Security/SSE lifecycle baseline superseded as soak candidate by rc.8.
- **Published v1.0.0-rc.6**: Prior dual-era modern-preferred baseline; superseded as soak candidate by rc.7
- **Published v1.0.0-rc.5**: Legacy MCP through 2025-11-25; no modern protocol modes
- **v0.12.x**: Prior line with MCP 2025-11-25 support and ACP v1 alignment
- **v0.11.x and earlier**: Upgrade recommended

### Forward-looking protocol notes

- **MCP 2026-07-28** is the latest stable revision, is wire-breaking relative
  to 2025-11-25, and is implemented behind the explicit protocol modes above.
  The rc.6 through rc.8 release default is `:prefer_modern`.
- **ACP** adds non-breaking capabilities under major `1` (session list/close/resume,
  logout, config options, etc.). Adapter packages (Claude / Codex / Pi) should be
  re-synced periodically with upstream agent releases.
- Refresh local MCP reference docs with `mix mcp.sync_spec --version 2026-07-28`.

Keep your ExMCP version up to date to benefit from the latest MCP protocol features and security improvements.
