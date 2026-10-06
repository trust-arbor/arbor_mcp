# ArborMCP Quick Start Guide

This guide shows a minimal MCP server and client in the `2.0.0-rc.1` checkout.
Publication is pending; see the [RC notes](../guides/V2_RELEASE_CANDIDATE.md)
for qualification and known limits, and the
[v1-to-v2 guide](../guides/MIGRATING_V1_TO_V2.md) when upgrading ExMCP.

**Next Steps:** See the [User Guide](../guides/USER_GUIDE.md), [DSL Guide](../DSL_GUIDE.md), and [Configuration Guide](../CONFIGURATION.md).

## Installation

After RC publication, add `{:arbor_mcp, "== 2.0.0-rc.1"}` to your dependencies.
Until then, use a local checkout:

```sh
git clone --branch codex/v2-migration https://github.com/trust-arbor/arbor_mcp.git
git clone --branch main https://github.com/trust-arbor/arbor_rpc.git
```

The MCP default `master` branch is still ExMCP 1.x. In a separate consumer
application with these sibling checkouts, declare the MCP path:

```elixir
def deps do
  [
    {:arbor_mcp, path: "../arbor_mcp"}
  ]
end
```

The transitive `arbor_rpc` source build requires a C17 compiler on macOS/Darwin
and Linux, even when the application uses only HTTP or BEAM. `CC` selects a
compiler executable; it is not a shell command. Source packages contain no
prebuilt helper. Include the built helper in assembled releases, which need no
runtime compiler. Windows native subprocess operations are unsupported; framing
remains separate. See the [source-install policy](../V2_PACKAGE_RELEASE.md).

For a standalone Cowboy HTTP server, add `{:plug_cowboy, "~> 2.7"}` and
`{:ranch, "== 1.8.1"}` to the host dependencies. For Bandit, add
`{:bandit, "== 1.12.5"}` and `{:thousand_island, "== 1.5.0"}`. Select Bandit
with `http_adapter: :bandit`; Cowboy remains the default. HTTP clients and
mounting `Arbor.MCP.HttpPlug` in an existing host need no additional listener.
See the [HTTP listener guide](../HTTP_LISTENERS.md).

Set `ARBOR_RPC_PATH` to the shared RPC checkout, then run `mix deps.get`.
For example: `export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc`. The released
1.x package is `ex_mcp` and uses its previous namespace.

MCP `2026-07-28` is the latest stable revision. The client tries it first while
retaining evidence-based legacy fallback. Pin the mode explicitly when rollout
policy must remain fixed:

```elixir
# config/config.exs
config :arbor_mcp, protocol_mode: :prefer_modern
```

New connections default to `:prefer_modern`. Use `:legacy_only` to preserve the
legacy protocol era. Exact rc.5 wire and session behavior still requires
package rollback to `1.0.0-rc.5`. See the
[Configuration Guide](../CONFIGURATION.md#protocol-eras-and-modes) for all four
modes.

## DSL Server

Define tools, resources, and prompts next to their handlers:

```elixir
defmodule MyMCPServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "echo", "Echoes back the input message" do
    param :message, :string, required: true

    # ToolResult is aliased by the DSL and returns a complete result map.
    run fn %{message: message}, state ->
      {:ok, ToolResult.text("Echo: #{message}"), state}
    end
  end

  resource "config://app/settings", "Current application configuration" do
    title "App Settings"
    mime_type "application/json"

    read fn _params, state ->
      {:ok, %{text: Jason.encode!(%{debug: false, log_level: "info"})}, state}
    end
  end
end

{:ok, server} = MyMCPServer.start_link(transport: :stdio)
```

Run a stdio server under an application supervisor or a script that stays alive;
keep diagnostics on stderr. The library does not change the host's Logger policy.
For HTTP deployment, follow the [Phoenix guide](../guides/PHOENIX_GUIDE.md) or
[owned listener guide](../HTTP_LISTENERS.md); every mount needs an explicit Runtime.

The DSL generates the MCP list/read/call callbacks plus legacy initialization
and modern discovery metadata from your declarations. See the
[DSL Guide](../DSL_GUIDE.md) for param types (including `{:array, :string}`),
compile-time checks, and `ToolResult` helpers.

## Client Connections

Connect to a stdio server:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["node", "my-mcp-server.js"]
  )

{:ok, tools} = Arbor.MCP.Client.list_tools(client)
{:ok, result} = Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "Hello"})
:ok = Arbor.MCP.Client.stop(client)
```

Connect to a streamable HTTP server:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "http://localhost:4000/mcp",
    # Retains a legacy GET stream if this connection negotiates a legacy era.
    use_sse: true
  )

:ok = Arbor.MCP.Client.stop(client)
```

## BEAM-Local MCP

Use `transport: :beam` when both the client and server are Elixir processes in the same VM:

```elixir
{:ok, server} =
  MyMCPServer.start_link(
    transport: :beam,
    protocol_mode: :prefer_modern
  )

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :beam,
    server: server,
    protocol_mode: :prefer_modern
  )

{:ok, tools} = Arbor.MCP.Client.list_tools(client)
{:ok, result} = Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "Hello"})
:ok = Arbor.MCP.Client.stop(client)
:ok = Arbor.MCP.Server.Runtime.stop(server)
```

BEAM-local MCP uses the configured protocol mode. New connections default to
`:prefer_modern`, which uses MCP 2026-07-28 discovery and per-request context;
`:legacy_only` retains the initialize handshake. The transport simply passes
MCP-shaped maps/lists as Elixir terms between local processes.

> **Note for raw handlers:** If you are not using the DSL, start with `Arbor.MCP.Server.HandlerServer.start_link(handler: YourHandler, transport: :beam)` (or `Arbor.MCP.start_server/1`). DSL modules automatically provide `start_link/1`.

For a fast compiled DSL/client example, use `mix examples.getting_started` from
the repository root. This alias uses `:test`; the standalone demo exercises
additional transports and can take longer on a cold dependency cache.

## Choosing A Transport

| Transport | Best For |
|-----------|----------|
| `:stdio` | External MCP servers and subprocess tools |
| `:http` | Phoenix apps, remote clients, and Streamable HTTP |
| `:beam` | Trusted local Elixir client/server pairs |
| `:test` | Unit and integration tests |

## Resilience

Connection and operation retries are configured with `retry_policy`:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    retry_policy: [max_attempts: 3, initial_delay: 100, max_delay: 2_000]
  )
```

Transport-level reliability can wrap supported transports with circuit breakers or health checks:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    reliability: [
      circuit_breaker: [failure_threshold: 5, reset_timeout: 30_000],
      health_check: [check_interval: 60_000]
    ]
  )
```

For HTTP server-side pipelines, compose normal Plug/Phoenix plugs around `Arbor.MCP.HttpPlug`.

An operation retry can repeat a side effect. Use application idempotency keys
where needed; a timed-out or broken response does not prove the work was undone.

## Next Steps

1. Read the [DSL Guide](../DSL_GUIDE.md)
2. Read the [User Guide](../guides/USER_GUIDE.md)
3. Review [Transport Guide](../TRANSPORT_GUIDE.md)
4. Review the [v1-to-v2 migration guide](../guides/MIGRATING_V1_TO_V2.md)
   and the [historical protocol rollout](MIGRATION.md)
5. Explore [Examples](https://github.com/trust-arbor/arbor_mcp/tree/codex/v2-migration/examples)
