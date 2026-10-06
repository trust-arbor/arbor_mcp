# ArborMCP Examples

This directory contains MCP examples being migrated for version 2. Runtime and HTTP listener integration must pass the release checks before these examples are qualified for 2.0.

Set `ARBOR_RPC_PATH` to your shared RPC checkout while developing the unpublished split; the examples use the local MCP project through `Mix.install/1`.

**Note on first runs:** The self-contained `.exs` files (e.g. `elixir examples/basic_dsl_server.exs`) perform a `Mix.install/1` of the local `arbor_mcp` on every invocation. This can take 30s–3+ minutes on a cold cache (subsequent runs are much faster). For the quickest "brand new user" experience, start with the utilities or the `demo_client.exs` (which orchestrates the getting-started servers).

Fast alias (recommended for repo developers after `mix compile`):

```bash
mix examples.getting_started
```

## Getting Started

`getting_started/` demonstrates the supported transports:

- `01_stdio_server.exs` - stdio server with a `hello` tool
- `02_http_server.exs` - HTTP server with resources
- `03_http_sse_server.exs` - HTTP server with SSE enabled
- `04_beam_server.exs` - BEAM-local server
- `demo_client.exs` - self-contained client demo for stdio, HTTP, HTTP+SSE, and BEAM-local

```bash
cd examples/getting_started
./run_demo.sh
```

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

Param types, compile-time checks, and `ToolResult` helpers are documented in [docs/DSL_GUIDE.md](../docs/DSL_GUIDE.md).

Run a server directly (see note above about first-run time):

```bash
elixir examples/basic_dsl_server.exs
```

Server examples use stdio by default unless their filename calls out another transport.

**For developers** (after `mix compile` in the repo root): you can drive these servers from a client without re-installing on every run by using a small harness or the patterns in `test/doc_regression_test.exs`. The `demo_client.exs` in `getting_started/` is the recommended way to exercise all transports at once.

## Client Example

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
- `:http` for Streamable HTTP, with `use_sse: true` when SSE is needed
- `:beam` for BEAM-local client/server processes in the same VM
- `:test` for in-memory tests

The old public `:native` alias and direct dispatcher API were removed before 1.0.
