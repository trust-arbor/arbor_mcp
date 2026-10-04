# Arbor.MCP Troubleshooting Guide

Version 2 is under development. Local `Mix.install/2` examples require
`ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc` until the shared dependency is published.

## stdio

### Unexpected end of JSON input

The stdio transport requires stdout to contain only newline-delimited JSON-RPC.
Avoid `IO.puts/1`, normal Logger output, or noisy startup scripts on stdout.

Use stderr for diagnostics:

```elixir
IO.puts(:stderr, "debug")
```

Configure logging in the host before applications start:

```elixir
# Host config/config.exs or config/runtime.exs
config :logger, :default_handler, config: [type: :standard_error]
```

Library startup and stdio connection preserve that configuration and normal log
levels. `:stdio_mode` no longer configures the VM logger automatically. Standalone
script examples explicitly replace their host-owned default handler before
`Mix.install/2`; that function may still print dependency/compiler output to
stdout. Prefer compiled releases when stdout must be clean from process boot.

### Server hangs after starting

Start stdio servers with:

```elixir
MyServer.start_link(transport: :stdio)
```

For clients, `command` must be a list:

```elixir
Arbor.MCP.Client.start_link(transport: :stdio, command: ["node", "server.js"])
```

## HTTP

### Connection refused

Check the URL and endpoint path. If the path is included in `url`, Arbor.MCP uses
that as the default endpoint:

```elixir
Arbor.MCP.Client.start_link(transport: :http, url: "http://localhost:4000/mcp")
```

Or provide it explicitly:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "http://localhost:4000",
  endpoint: "/mcp"
)
```

### CORS errors

For Phoenix/Plug servers, configure CORS in your Plug pipeline or pass
`cors_enabled: true` to `Arbor.MCP.HttpPlug`.

### SSE stream does not start

First identify the negotiated protocol era:

- On legacy MCP, confirm the standalone GET stream is enabled and the client
  uses `use_sse: true`.
- On MCP 2026-07-28, `use_sse` does not control streaming. Ordinary requests
  and `subscriptions/listen` own their SSE response on the POST that created
  them. Check that the proxy preserves `Content-Type: text/event-stream`, does
  not buffer or transform the response, and has an idle timeout longer than
  the configured keepalive interval.

Increase `stream_handshake_timeout` for slow deployments. See the
[Streamable HTTP comparison](TRANSPORT_GUIDE.md#streamable-http) for the full
era-specific lifecycle.

## Protocol modes and MCP 2026-07-28

### `server/discover` fails or the client does not fall back

Set the intended compatibility policy explicitly:

```elixir
Arbor.MCP.Client.start_link(
  transport: :http,
  url: "https://example.com/mcp",
  protocol_mode: :prefer_modern
)
```

`:prefer_modern` falls back to legacy `initialize` only when a live peer gives
positive evidence that it is legacy-compatible. A timeout, authentication
failure, transport break, cached-modern failure, recognized modern error, or
unsupported modern revision is surfaced instead of being silently downgraded.
Use `:prefer_legacy` for a deliberate rollback, or `reset_era_cache: true` once
after an operator-controlled endpoint upgrade. Strict `:modern_only` and
`:legacy_only` modes never fall back.

### Error `-32022`: unsupported protocol version

The request's modern
`_meta["io.modelcontextprotocol/protocolVersion"]`, the
`MCP-Protocol-Version` HTTP header, and the server's enabled protocol mode must
agree. Inspect the error's `data.requested` and `data.supported` values, then
check both client and server `protocol_mode` settings. Do not use
`protocol_version: "2025-11-25"` to select an era; that option is only the
legacy revision preference.

### Invalid request metadata

Every MCP 2026-07-28 request must include a `_meta` object with:

```json
{
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities": {}
}
```

`io.modelcontextprotocol/clientInfo` is optional, but when present it must
contain non-empty `name` and `version` strings. Arbor.MCP adds these fields for its
own clients; this error usually indicates a custom peer, manually constructed
JSON-RPC message, or middleware that rewrote `params._meta`.

### Error `-32020`: HTTP header mismatch

Modern HTTP requests must carry exactly one `MCP-Protocol-Version` and
`Mcp-Method` header matching the JSON-RPC body. `tools/call`,
`resources/read`, and `prompts/get` also require a matching `Mcp-Name`.
Annotated tool arguments may require `Mcp-Param-*` headers.

Arbor.MCP derives and replaces these headers automatically. If the error occurs
with an Arbor.MCP client, inspect reverse-proxy behavior: duplicate headers must
not be collapsed by choosing one value, and routing headers must not be
cached, normalized to a different value, or injected by middleware.

### Result is rejected for missing `resultType`, `ttlMs`, or `cacheScope`

Every modern result needs `resultType: "complete"` or
`resultType: "input_required"`. A complete cacheable result must also contain
a non-negative integer `ttlMs` and `cacheScope` equal to `"public"` or
`"private"`. Non-complete results must not contain cache hints. Legacy result
maps do not gain these fields merely because the transport is HTTP.

When the server uses Arbor.MCP's normal Handler or DSL dispatch, return the usual
`{:ok, result, state}` / `ToolResult.*` shape and let
`Arbor.MCP.Server.ResultNormalizer` add `resultType` plus conservative cache
defaults (`ttlMs: 0`, `cacheScope: "private"`). Suspend an operation with
`Arbor.MCP.Server.DSL.Result.input_required/2` or the documented
`{:input_required, ...}` handler tuple. If a custom peer constructs raw wire
results or bypasses Arbor.MCP dispatch, it must add and validate the modern fields
itself. See [Modern result cache hints](CONFIGURATION.md#modern-result-cache-hints).

### GET or DELETE returns 405

This is expected on a `:modern_only` MCP endpoint. MCP 2026-07-28 has no
standalone GET stream or session DELETE. Open a `subscriptions/listen` POST for
long-lived notifications and cancel by closing its response stream. GET,
DELETE, `Mcp-Session-Id`, and `Last-Event-ID` are retained only for enabled
legacy Streamable HTTP connections.

## BEAM-Local

### Client cannot connect

`transport: :beam` requires a live server PID:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)  # DSL provides start_link; raw handlers use HandlerServer
Process.alive?(server)

{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: server)
```

Do not use `transport: :native`; it was removed in the 1.0 API cleanup.

## DSL

### Tools do not appear

Use `Arbor.MCP.Server.Handler` and `Arbor.MCP.Server.DSL` together, and make sure the
server starts through a supported transport:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL

  tool "ping", "Health check" do
    run fn _args, state ->
      {:ok, %{content: [%{type: "text", text: "pong"}]}, state}
    end
  end
end
```

## Debugging

Enable debug logging for non-stdio transports:

```elixir
Logger.configure(level: :debug)
```

Inspect local server state when using BEAM-local tests:

```elixir
:sys.get_state(server)
```

Run focused tests:

```bash
mix test test/arbor_mcp/client_beam_transport_test.exs
mix test test/arbor_mcp/server/transport_test.exs
```
