# ExMCP

<div align="center">

[![Hex.pm](https://img.shields.io/hexpm/v/ex_mcp.svg)](https://hex.pm/packages/ex_mcp)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/ex_mcp)
[![CI](https://github.com/trust-arbor/arbor_mcp/workflows/CI/badge.svg)](https://github.com/trust-arbor/arbor_mcp/actions)
[![Coverage](https://coveralls.io/repos/github/azmaveth/ex_mcp/badge.svg?branch=master)](https://coveralls.io/github/azmaveth/ex_mcp?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_mcp.svg)](https://github.com/trust-arbor/arbor_mcp/blob/master/LICENSE)

**A complete Elixir implementation of the Model Context Protocol (MCP) and Agent Client Protocol (ACP)**

[Getting Started](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x/docs/getting-started) | [User Guide](docs/guides/USER_GUIDE.md) | [API Docs](https://hexdocs.pm/ex_mcp) | [Examples](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x/examples) | [2.0 Roadmap](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_ROADMAP.md) | [Changelog](CHANGELOG.md)

</div>

The repository has moved to [trust-arbor/arbor_mcp](https://github.com/trust-arbor/arbor_mcp).
The supported 1.x package remains `ex_mcp`. This is the `codex/maintenance-1.x`
branch: fixes and compatible minor releases continue here, so migration is
optional. See the [maintenance policy](https://github.com/trust-arbor/arbor_mcp/blob/codex/maintenance-1.x/docs/MAINTENANCE_POLICY.md).
Version 2 is being prepared as
`arbor_mcp` (`Arbor.MCP.*`) and `arbor_acp` (`Arbor.ACP.*`), with vendor adapters
in the optional `arbor_acp_adapters` package. The target is October 9, 2026,
subject to the [release gates](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_RELEASE_PLAN.md). GitHub redirects
preserve existing repository links; consumers change dependencies through
the v2 migration guide.

---

## Overview

ExMCP is a comprehensive Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) and the [Agent Client Protocol](https://agentclientprotocol.com/), enabling AI models to securely interact with local and remote resources through standardized protocols. It provides both client and server implementations with multiple transport options, including native Phoenix integration via Plug compatibility, plus the ability to control coding agents like Gemini CLI, Claude Code, and Codex via ACP.

## Key Features

- **Full MCP support** -- **[2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28)** (latest stable) plus the legacy 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25 revisions
- **Modern MCP conformance** -- 387/387 client checks and 149/149 server checks (`@modelcontextprotocol/conformance@0.2.0-alpha.11`, complete 2026-07-28 suites, 2026-08-22)
- **Legacy MCP conformance** -- 218/218 client checks and 39/39 server checks (`@modelcontextprotocol/conformance@0.1.16`, latest executed core suite)
- **ACP v1** -- Agent Client Protocol major version `1` (`protocolVersion: 1`)
- **Multiple transports** -- Streamable HTTP, stdio, and BEAM-local MCP (~15μs local calls)
- **Phoenix Plug** -- native Phoenix integration with `ExMCP.HttpPlug`
- **DSL and Handler APIs** -- declarative tool/resource/prompt definitions via `ExMCP.Server.DSL`, or raw callback-based handlers (`ExMCP.Server.Tools` is deprecated; retained throughout 1.x and planned for removal in 2.0)
- **OAuth 2.1** -- automatic 401→discover→PKCE→token flow, scope step-up, CIMD, JWT client auth (`private_key_jwt`), enterprise SSO (ID-JAG), token revocation (RFC 7009), pluggable auth providers
- **OTP-native** -- supervision trees, auto-reconnection with exponential backoff, 88 telemetry events
- **Agent Client Protocol (ACP)** -- control coding agents and build native Elixir ACP agents
- **3500+ tests** -- comprehensive suite including official MCP conformance, integration, and performance

MCP 2026-07-28 is wire-incompatible with earlier revisions. The current source
tree supports it through `:prefer_modern` and `:modern_only`, while preserving
every legacy revision through the 1.x line. Starting in `1.0.0-rc.6`, the
application default is `:prefer_modern`: clients try modern discovery first
and fall back only when the peer positively identifies itself as legacy.
Set `protocol_mode: :legacy_only` to preserve the **legacy protocol era**.
Exact rc.5 wire and session behavior still requires package rollback to
`1.0.0-rc.5`; 1.0 continues to enforce server-issued sessions and newer
lifecycle/security rules.
`ExMCP.protocol_version/0` intentionally returns the newest legacy revision,
`2025-11-25`, for initialize-based compatibility—it is not the latest upstream
MCP revision. See
[Configuration](docs/CONFIGURATION.md#protocol-eras-and-modes) and the
[1.0 migration guide](docs/getting-started/MIGRATION.md#upgrading-from-rc5--legacy-mcp-to-the-10-dual-era-release).

> **Release-state note:** `1.0.0` is the stable modern-preferred release. It is
> wire- and API-compatible with rc.8 after the final candidate completed its
> soak, with one internal OAuth callback parser fix for a runtime-order crash.
> Published `1.0.0-rc.5` remains the legacy-only characterization baseline.

## Installation

For the stable dual-era release:

```elixir
def deps do
  [
    {:ex_mcp, "~> 1.0"}
  ]
end
```

To retain the legacy protocol era during rollout, configure the
mode explicitly:

```elixir
config :ex_mcp, protocol_mode: :legacy_only
```

### API stability (1.0)

| Stable | Experimental / limited | Deprecated (retained through 1.x) |
|--------|------------------------|---------------------------|
| `ExMCP.Client`, `Server.Handler`, `Server.DSL` | Content sanitize/transform helpers | `ExMCP.Server.Tools` (+ helpers) |
| Transports (`:stdio`, `:http`, `:beam`, `:test`) | Some draft MCP handler features | Image compress/resize/thumbnail stubs |
| `ExMCP.HttpPlug`, `Authorization`, ACP adapters | ACP `session/fork` (unstable upstream) | MCP HTTP+SSE, Roots, Sampling, and protocol Logging |
| `ExMCP.Content` builders (`text`/`image`/`audio`) | — | — |

Runnable examples live in the GitHub repo under [`examples/`](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x/examples) (not shipped in the Hex package).

The [ExMCP 2.0 roadmap](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_ROADMAP.md) records planned runtime and API
changes, deprecated-surface removals, and the policy for safely backporting
selected improvements to 1.x.

## Quick Start

### Phoenix Integration

Add MCP server capabilities to your Phoenix app:

```elixir
# In your Phoenix router
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  scope "/api/mcp" do
    forward "/", ExMCP.HttpPlug,
      handler: MyApp.MCPHandler,
      protocol_mode: :prefer_modern,
      server_info: %{name: "my-phoenix-app", version: "1.0.0"},
      handler_call_timeout: 10_000,
      cors_enabled: true
  end
end

# Create your MCP handler
defmodule MyApp.MCPHandler do
  use ExMCP.Server.Handler

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_initialize(_params, state) do
    {:ok, %{
      protocolVersion: ExMCP.protocol_version(),
      serverInfo: %{name: "my-phoenix-app", version: "1.0.0"},
      capabilities: %{tools: %{}, resources: %{}}
    }, state}
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        name: "get_user_count",
        description: "Get total number of users",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("get_user_count", _args, state) do
    count = MyApp.Accounts.count_users()
    {:ok, %{content: [%{type: "text", text: "Total users: #{count}"}]}, state}
  end
end
```

`handler_call_timeout` is the server-side Handler deadline in milliseconds;
client request and SSE timeouts are configured separately on `ExMCP.Client`.

> **Body parsing:** a Phoenix endpoint runs `Plug.Parsers` before the router, so a plug mounted in the router only ever sees an already-drained body. `ExMCP.HttpPlug` handles that by falling back to the payload Phoenix already parsed (`conn.body_params`), so the mount above works as-is. Strict enforcement of `HttpPlug`'s `:body_limit` still needs raw bytes stashed in `conn.assigns[:raw_body]` through a `Plug.Parsers` `:body_reader`; alternatively, set the parser's `:length` to the same limit. Mounting the plug in the endpoint ahead of `Plug.Parsers` works too, but the plug answers every request it receives (and halts the conn), so it has to sit behind a path match of its own.

> **Mount-relative routing:** `ExMCP.HttpPlug` routes relative to its mount point, and the MCP endpoint is the mount root. The RFC 9728 `/.well-known/oauth-protected-resource` metadata is likewise served under the mount, so the router forward above cannot answer the host-root form that clients fetch (`/.well-known/oauth-protected-resource/api/mcp`). When `oauth_enabled: true`, mount `ExMCP.Plugs.ProtectedResourceMetadata` at the host root for that path.

> **Note:** The example above uses raw `ExMCP.Server.Handler` callbacks (useful for dynamic capabilities). Most Phoenix apps will be simpler with the DSL — see the "DSL Server" section below and the [Phoenix Guide](docs/guides/PHOENIX_GUIDE.md).

### DSL Server

Define tools, resources, and prompts next to their handlers:

```elixir
defmodule MyServer do
  use ExMCP.Server.Handler
  use ExMCP.Server.DSL

  tool "greet", "Greets a person by name" do
    title "Greeting"
    param :name, :string, required: true, description: "Person to greet"

    run fn %{name: name}, state ->
      {:ok, %{text: "Hello, #{name}!"}, state}
    end
  end

  resource "info://about", "Server information" do
    title "About"
    mime_type "text/plain"

    read fn %{uri: uri}, state ->
      {:ok, %{uri: uri, text: "MyServer v1.0", mimeType: "text/plain"}, state}
    end
  end

  prompt "motivate", "Create a short motivational message" do
    arg :topic, required: true, description: "Topic to encourage"

    render fn %{topic: topic}, state ->
      {:ok,
       %{
         messages: [
           %{role: "user", content: %{type: "text", text: "Encourage me about #{topic}"}}
         ]
       }, state}
    end
  end
end
```

See the [DSL Guide](docs/DSL_GUIDE.md) and [examples](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x/examples) for more patterns.
Elicitation, sampling, roots, ping, progress, and cancellation are in the
[Protocol Guide](docs/PROTOCOL_GUIDE.md).

### Standalone Client

```elixir
# Connect to a stdio-based server
{:ok, client} = ExMCP.Client.start_link(
  transport: :stdio,
  command: ["node", "my-mcp-server.js"],
  protocol_mode: :prefer_modern
)

# List available tools
{:ok, tools} = ExMCP.Client.list_tools(client)

# Call a tool
{:ok, result} = ExMCP.Client.call_tool(client, "search", %{
  query: "Elixir programming",
  limit: 10
})
```

### BEAM-Local MCP

For trusted Elixir processes in the same VM, use the BEAM-local transport. It
carries MCP-shaped messages as Elixir terms, so local calls avoid JSON
encode/decode while still using the normal MCP client/server lifecycle.

```elixir
defmodule MyToolService do
  use ExMCP.Server.Handler
  use ExMCP.Server.DSL

  tool "ping", "Test tool" do
    run fn _args, state ->
      {:ok, %{content: [%{type: "text", text: "Pong!"}]}, state}
    end
  end
end

{:ok, server} =
  MyToolService.start_link(
    transport: :beam,
    protocol_mode: :prefer_modern
  )

{:ok, client} =
  ExMCP.Client.start_link(
    transport: :beam,
    server: server,
    protocol_mode: :prefer_modern
  )

{:ok, tools} = ExMCP.Client.list_tools(client)
{:ok, result} = ExMCP.Client.call_tool(client, "ping", %{})
```

**Fast verification:** From the repo root (after `mix compile`), run `mix examples.getting_started` for a quick in-process demo of these patterns.

### ACP: Control and Build Coding Agents

Use the [Agent Client Protocol](https://agentclientprotocol.com/) to control coding agents programmatically or expose an Elixir process as an ACP agent:

```elixir
# Native ACP agents over stdio (Gemini CLI, Hermes, OpenCode, Qwen Code, etc.)
{:ok, client} = ExMCP.ACP.start_client(command: ["gemini", "--acp"])

# Create a session and send a prompt
{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/my/project")
{:ok, %{"stopReason" => _}} = ExMCP.ACP.Client.prompt(client, sid, "Fix the failing tests")

# Claude Code via the SDK-compatible adapter
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.ClaudeSDK,
  adapter_opts: [model: "sonnet", cwd: "/my/project"]
)

# Codex via the app-server adapter
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.Codex,
  adapter_opts: [cwd: "/my/project"]
)

# Pi coding agent via its RPC adapter
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.Pi,
  adapter_opts: [cwd: "/my/project", thinking_level: "medium"]
)

# ZCode via the app-server adapter
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.ZCode,
  adapter_opts: [cli_path: "zcode", cwd: "/my/project", mode_id: "build"]
)

# Native Elixir ACP agent over stdio
{:ok, agent} = ExMCP.ACP.start_agent(
  handler: MyApp.AgentHandler,
  agent_info: %{"name" => "my-agent", "version" => "1.0.0"}
)
```

See the [ACP Guide](docs/ACP_GUIDE.md) for full details.

## Transport Performance

| Transport | Latency | Best For |
|-----------|---------|----------|
| **BEAM-local** | ~15μs | Local Elixir processes in one VM |
| **stdio** | ~1-5ms | Subprocess communication |
| **Streamable HTTP** | ~5-20ms | Web applications, remote APIs |

## Documentation

### Getting Started
- **[Quick Start Guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/getting-started/QUICKSTART.md)** -- Get running in 5 minutes
- **[Migration Guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/getting-started/MIGRATION.md)** -- Version upgrade instructions

### Guides
- **[User Guide](docs/guides/USER_GUIDE.md)** -- Complete feature walkthrough
- **[Phoenix Integration](docs/guides/PHOENIX_GUIDE.md)** -- Detailed Phoenix/Plug integration
- **[DSL Guide](docs/DSL_GUIDE.md)** -- Declarative server definitions
- **[ACP Guide](docs/ACP_GUIDE.md)** -- Agent Client Protocol for controlling coding agents
- **[Transport Guide](docs/TRANSPORT_GUIDE.md)** -- Transport selection and optimization
- **[Configuration](docs/CONFIGURATION.md)** -- All configuration options
- **[Security](docs/SECURITY.md)** -- Authentication, TLS, and best practices
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** -- Common issues and solutions

### Development & API
- **[Development Guide](docs/DEVELOPMENT.md)** -- Setup, testing, and contributing
- **[API Documentation](https://hexdocs.pm/ex_mcp)** -- Complete API reference
- **[Architecture](docs/ARCHITECTURE.md)** -- Internal design decisions
- **[MCP 2026-07-28 Migration Plan](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_2026_07_28_MIGRATION_PLAN.md)** -- Implementation record and remaining release gates
- **[MCP Coverage Matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md)** -- Local and official conformance evidence
- **[rc.5 to 1.0 API Diff](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/API_DIFF_RC5_TO_1_0.md)** -- Public compatibility audit
- **[Examples](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x/examples)** -- Real-world patterns

## Contributing

Contributions welcome! See the [Development Guide](docs/DEVELOPMENT.md) for setup and testing instructions.

1. Fork the repository
2. Create a feature branch
3. Run `make quality` to ensure code quality
4. Submit a pull request

## License

MIT -- see [LICENSE](https://github.com/trust-arbor/arbor_mcp/blob/master/LICENSE).

## Acknowledgments

- The [Model Context Protocol](https://modelcontextprotocol.io/) and [Agent Client Protocol](https://agentclientprotocol.com/) specification creators
- The Elixir community for excellent tooling and libraries
- Contributors and early adopters providing feedback
