# Arbor.MCP Quick Start Guide

This guide shows the MCP server, client and BEAM-local patterns in the v2
development checkout. Runtime integration and package qualification are still
release work in progress.

**Next Steps:** See the [User Guide](../guides/USER_GUIDE.md), [DSL Guide](../DSL_GUIDE.md), and [Configuration Guide](../CONFIGURATION.md).

## Installation

Version 2 is not published yet. Use a local checkout while developing the split:

```elixir
def deps do
  [
    {:arbor_mcp, path: "../arbor_mcp"}
  ]
end
```

Standalone HTTP servers additionally need `{:plug_cowboy, "~> 2.7"}` or
`{:bandit, "~> 1.12 and >= 1.12.5"}` in the host dependencies. Select Bandit
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

    # Plain strings and maps are normalized; ToolResult is aliased by the DSL
    run fn %{message: message}, state ->
      {:ok, %{content: [%{type: "text", text: "Echo: #{message}"}]}, state}
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
```

Connect to a streamable HTTP server:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "http://localhost:4000/mcp",
    use_sse: true
  )
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
```

BEAM-local MCP uses the configured protocol mode. rc.8 defaults to
`:prefer_modern`, which uses MCP 2026-07-28 discovery and per-request context;
`:legacy_only` retains the initialize handshake. The transport simply passes
MCP-shaped maps/lists as Elixir terms between local processes.

> **Note for raw handlers:** If you are not using the DSL, start with `Arbor.MCP.Server.HandlerServer.start_link(handler: YourHandler, transport: :beam)` (or `Arbor.MCP.start_server/1`). DSL modules automatically provide `start_link/1`.

For a fast (compiled) run of the patterns in this guide, use `mix examples.getting_started` from the repo root.

## Choosing A Transport

| Transport | Best For |
|-----------|----------|
| `:stdio` | External MCP servers and subprocess tools |
| `:http` | Phoenix apps, remote clients, and Streamable HTTP |
| `:beam` | Trusted local Elixir client/server pairs |
| `:test` | Unit and integration tests |

## Resilience

Client connection retries are configured with `retry_policy`:

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

## Next Steps

1. Read the [DSL Guide](../DSL_GUIDE.md)
2. Read the [User Guide](../guides/USER_GUIDE.md)
3. Review [Transport Guide](../TRANSPORT_GUIDE.md)
4. Review the [1.0 Migration Guide](MIGRATION.md) for the dual-era rollout
5. Explore [Examples](https://github.com/trust-arbor/arbor_mcp/tree/master/examples)
