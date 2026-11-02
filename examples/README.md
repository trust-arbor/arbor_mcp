# ArborMCP Examples

This directory contains MCP examples for the version 2 API, which is published
as release candidates. The examples are learning fixtures rather than a
substitute for the qualification described in the
[RC notes](../docs/guides/V2_RELEASE_CANDIDATE.md).

`arbor_rpc` resolves from Hex; set `ARBOR_RPC_PATH` only to try a local RPC
checkout. Source installation requires C17 on qualified macOS/Linux platforms.
Most standalone scripts load the local MCP project through `Mix.install/1`.

**First runs:** Standalone scripts call `Mix.install/1`; its cache avoids repeated
installation of unchanged dependencies, but cold runs can take minutes.
The compiled alias below is the shortest local DSL/client example. It uses the
`:test` transport, not every physical transport.

Fast alias (recommended for repo developers after `mix compile`):

```bash
mix examples.getting_started
```

## Getting Started

`getting_started/` demonstrates the supported transports:

- `01_stdio_server.exs` - stdio server with a `hello` tool
- `02_http_server.exs` - HTTP server with resources
- `03_http_sse_server.exs` - HTTP server with explicit legacy HTTP+SSE aliases enabled
- `04_beam_server.exs` - BEAM-local server
- `demo_client.exs` - self-contained client demo for stdio, two HTTP configurations, and BEAM-local

```bash
cd examples/getting_started
./run_demo.sh
```

The demo's second HTTP configuration enables legacy aliases on the server but
its client uses normal HTTP with `use_sse: false` and modern-preferred negotiation.
It does not prove a 2024 two-endpoint `/sse` connection or replay. Use the
[protocol and transport guides](../docs/TRANSPORT_GUIDE.md) for that explicit flow.
The script prints per-transport failures and continues; a final "Demo completed"
line is not a test verdict for every transport.

## MCP Apps

[`mcp_apps/`](mcp_apps/) serves an interactive calculator through a predeclared
HTML resource. It includes an Elixir Handler, official-SDK View and bundle
builder, plus stdio/HTTP launchers. Build and run it from the repository root;
its README documents Apps-capable host setup and SDK/browser qualification.
The nested [Phoenix LiveView host](mcp_apps/phoenix_host/) provides a runnable
local browser host with native MCP forwarding and a second-origin sandbox.

## Server Examples

All server examples use:

```elixir
use Arbor.MCP.Server.Handler
use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"
```

- `basic_dsl_server.exs` - minimal tool, resource, and prompt
- `advanced_dsl_server.exs` - typed parameters, structured output, templates, and metadata
- `weather_service.exs` - practical simulated weather tools and resources
- `file_manager.exs` - sandboxed file operations and file resources
- `dynamic_tools.exs` - application-owned mutable tool catalog using public Runtime controls

Param types, compile-time checks, and `ToolResult` helpers are documented in [docs/DSL_GUIDE.md](../docs/DSL_GUIDE.md).

Run a server directly (see note above about first-run time):

```bash
elixir examples/basic_dsl_server.exs
```

Server examples use stdio by default unless their filename calls out another transport.

**For developers** (after `mix compile` in the repository root),
`mix examples.getting_started` reuses compiled code. `dynamic_tools.exs` is also
run in that Mix context: `mix run examples/dynamic_tools.exs --demo`.
For protocol stdio, keep diagnostics on stderr; cold `Mix.install` compilation
may still print to stdout, so use an assembled release for production startup.

## Client Example

- [`forwarding_gateway/`](forwarding_gateway/README.md) — an embedded MCP proxy
  using public client/server APIs, with two controlled HTTP upstreams, manual
  MRTR, progress, cancellation and identity-scoped tool-change notifications.
  Run `mix run examples/forwarding_gateway/demo.exs` from the repository root.
- `basic_client.exs` - starts a BEAM-local server in-process, connects a client, lists tools/resources, and calls a tool

```bash
elixir examples/basic_client.exs
```

## ACP Examples

ACP examples live in [ArborACP](https://github.com/trust-arbor/arbor_acp). This checkout contains only MCP examples.

## OAuth And Utility Examples

- `advanced/oauth/basic_pkce.exs` - offline OAuth 2.1 PKCE helper flow
- `utilities/client_config.exs` - pipe-friendly client configuration
- `utilities/error_handling.exs` - response and error helpers
- `utilities/structured_responses.exs` - structured response helpers

## Transport Names

Current public transports are:

- `:stdio` for subprocess JSON-RPC
- `:http` for Streamable HTTP; modern POST-owned SSE requires no server flag
- `:beam` for BEAM-local client/server processes in the same VM
- `:test` for in-memory tests

The HTTP client's `use_sse: true` retains a standalone legacy GET stream after
legacy negotiation. Server-side 2024 `/sse` compatibility is instead selected
with `legacy_http_sse: true`; removed server aliases are rejected.

The old public `:native` alias and ExMCP direct dispatcher were removed before 1.0.
