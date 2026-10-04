# Arbor.MCP User Guide

A practical guide to building MCP clients and servers with Arbor.MCP. Version 2
is under development; these examples are being qualified with the new runtime.

## Table Of Contents

1. [Installation](#installation)
2. [Server DSL](#server-dsl)
3. [Low-Level Handlers](#low-level-handlers)
4. [BEAM-Local MCP](#beam-local-mcp)
5. [Clients](#clients)
6. [Protocol Versions](#protocol-versions)
7. [Protocol-Deprecated Features](#protocol-deprecated-features)
8. [Transports](#transports)
9. [Resilience And Pipelines](#resilience-and-pipelines)
10. [Troubleshooting](#troubleshooting)

## Installation

Version 2 is unpublished. Use a local MCP checkout for development and set
`ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc` before fetching dependencies.
The released 1.x package remains `ex_mcp`.

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

## Server DSL

Use `Arbor.MCP.Server.Handler` with `Arbor.MCP.Server.DSL` for most servers:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "echo", "Echoes the input message" do
    param :message, :string, required: true

    run fn %{message: message}, state ->
      {:ok, %{content: [%{type: "text", text: message}]}, state}
    end
  end

  resource "config://app", "Application configuration" do
    mime_type "application/json"

    read fn _params, state ->
      {:ok, %{text: Jason.encode!(%{debug: false})}, state}
    end
  end

  prompt "summarize", "Summarize text" do
    arg :text, required: true

    render fn %{text: text}, state ->
      {:ok,
       %{
         messages: [
           %{role: "user", content: %{type: "text", text: "Summarize: #{text}"}}
         ]
       }, state}
    end
  end
end
```

Start it with the transport you need:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)
```

## Low-Level Handlers

Use handwritten callbacks when capabilities are fully dynamic or you need
custom behavior. For nearly all cases, the DSL is simpler and recommended:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "ping", "Health check" do
    run fn _args, state ->
      {:ok, %{content: [%{type: "text", text: "pong"}]}, state}
    end
  end
end

{:ok, server} = MyServer.start_link(transport: :beam)
```

### Raw Callback Example

```elixir
defmodule DynamicServer do
  use Arbor.MCP.Server.Handler

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: Arbor.MCP.protocol_version(),
       serverInfo: %{name: "dynamic", version: "1.0.0"},
       capabilities: %{tools: %{}}
     }, state}
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        name: "ping",
        description: "Health check",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("ping", _args, state) do
    {:ok, %{content: [%{type: "text", text: "pong"}]}, state}
  end
end

# Start a raw handler (no DSL):
{:ok, server} =
  Arbor.MCP.Server.HandlerServer.start_link(
    handler: DynamicServer,
    transport: :beam
  )
# Or the convenience:
# {:ok, server} = Arbor.MCP.start_server(handler: DynamicServer, transport: :beam)
```

## BEAM-Local MCP

Use `transport: :beam` when both sides are Elixir processes in the same VM.
When using the DSL the server module gets a `start_link/1`:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :beam,
    server: server
  )

{:ok, tools} = Arbor.MCP.Client.list_tools(client)
{:ok, result} = Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello"})
```

For a raw handler (no DSL) use `Arbor.MCP.Server.HandlerServer.start_link(handler: MyHandler, ...)` (or `Arbor.MCP.start_server/1`).

**Tip:** `mix examples.getting_started` (after `mix compile`) gives a fast local run of these DSL + Client patterns for quick verification.

BEAM-local MCP follows the selected protocol mode. rc.8 defaults to
`:prefer_modern`, which uses discovery and per-request context;
`:legacy_only` uses the legacy initialize handshake. In either era, the
transport passes MCP-shaped maps/lists as Elixir terms instead of JSON strings.

## Clients

Connect to stdio:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["node", "server.js"],
    cd: "/path/to/project",
    env: [{"NODE_ENV", "production"}]
  )
```

Connect to Streamable HTTP:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    protocol_mode: :prefer_modern,
    use_sse: true,
    headers: [{"Authorization", "Bearer #{token}"}]
  )
```

Call server features:

```elixir
{:ok, tools} = Arbor.MCP.Client.list_tools(client)
{:ok, result} = Arbor.MCP.Client.call_tool(client, "search", %{"query" => "Elixir"})
{:ok, resources} = Arbor.MCP.Client.list_resources(client)
{:ok, content} = Arbor.MCP.Client.read_resource(client, "file:///docs/readme.md")
{:ok, prompts} = Arbor.MCP.Client.list_prompts(client)
{:ok, prompt} = Arbor.MCP.Client.get_prompt(client, "summarize")
```

Image, audio, blob, and `get_prompt` patterns are in the
[DSL Guide](../DSL_GUIDE.md). Elicitation, sampling, roots, ping, progress,
and cancellation are in the [Protocol Guide](../PROTOCOL_GUIDE.md).

## Protocol Versions

MCP `2026-07-28` is the latest stable revision. It is wire-incompatible with
the legacy `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`
revisions, so Arbor.MCP selects an era with `protocol_mode`:

```elixir
config :arbor_mcp, protocol_mode: :prefer_modern
```

Use `:prefer_modern` for a dual-era client or server that tries 2026-07-28
first, `:modern_only` for a closed modern ecosystem, `:prefer_legacy` for an
early compatibility canary, and `:legacy_only` to preserve the legacy protocol
era. Exact rc.5 wire and session behavior still requires package rollback to
`1.0.0-rc.5`. New connections default to `:prefer_modern`; the published rc.5
package remains the legacy-only characterization baseline and does not contain
these modes.

`Arbor.MCP.protocol_version/0` returns `2025-11-25` because it is a legacy
initialize compatibility helper; it does not report the latest upstream
revision. See the [Configuration Guide](../CONFIGURATION.md#protocol-eras-and-modes)
for negotiation, fallback, and per-connection overrides.

## Protocol-Deprecated Features

MCP 2026-07-28 deprecates Roots, Sampling, and protocol Logging, but keeps them
in the specification for at least twelve months. Arbor.MCP retains their callbacks,
functions, capability declarations, legacy methods, and modern MRTR handling
throughout the 1.x line. Existing integrations can continue to use them while
migrating; new integrations should use these replacements:

| Deprecated MCP feature | Recommended replacement |
|------------------------|-------------------------|
| Roots (`roots/list`, root callbacks and notifications) | Pass directories or files through tool parameters, resource URIs, or server configuration |
| Sampling (`sampling/createMessage`) | Call the chosen LLM provider API directly from application code |
| Logging (`logging/setLevel`, `notifications/message`, per-request log level) | Write stdio diagnostics to stderr and export structured observability through OpenTelemetry |

Roots are informational hints, not an authorization boundary. Continue to
enforce filesystem and resource permissions independently during migration.
Sampling compatibility handlers must retain human approval for any legacy
server-initiated model request.

## Transports

| Transport | Use When |
|-----------|----------|
| `:stdio` | Spawning an MCP subprocess |
| `:http` | Talking to a remote or Phoenix-hosted MCP server |
| `:beam` | Connecting local Elixir client/server processes |
| `:test` | Unit/integration tests |

## Resilience And Pipelines

Use client retries for transient connection/request failures:

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :http,
    url: "https://api.example.com/mcp",
    retry_policy: [max_attempts: 3, initial_delay: 100, max_delay: 2_000]
  )
```

Use transport reliability when a circuit breaker or health check belongs at the
connection boundary:

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

For HTTP servers, put side-effecting concerns such as authentication, request
signing, CORS, and DNS rebinding protection in the Plug/Phoenix pipeline before
`Arbor.MCP.HttpPlug`.

## Troubleshooting

**BEAM-local client cannot connect**

```elixir
Process.alive?(server)
Arbor.MCP.Client.start_link(transport: :beam, server: server)
```

**stdio server exits immediately**

Make sure `command` includes the executable and arguments as a list, and use
`cd`/`env` if the subprocess needs a specific working directory or environment.

**HTTP connection refused**

Verify the URL path matches the server endpoint. `Arbor.MCP.Transport.HTTP` extracts
the path from `url` unless `endpoint:` is provided explicitly.

**Need HTTP auth or validation**

Use `headers`, `auth`, `auth_provider`, `security`, or Plug composition around
`Arbor.MCP.HttpPlug` depending on whether the concern is client-side or server-side.
