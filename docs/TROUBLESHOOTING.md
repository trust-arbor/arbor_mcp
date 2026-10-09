# ArborMCP Troubleshooting Guide

ArborMCP `2.0.0-rc.2` and ArborRPC `1.0.0-rc.1` are published.
Normal installation resolves both from Hex; local source overrides are optional
development settings.

## Installation and v1 migration

### Hex cannot find `arbor_mcp` or `arbor_rpc`

Use the explicit `2.0.0-rc.2` MCP requirement and normal Hex resolution.
RPC's transitive requirement includes `1.0.0-rc.1`; stable-only constraints do
not select prereleases. Check registry connectivity, dependency conflicts and
the application's lockfile. Local path overrides are optional for development.

### Native helper does not compile or cannot be found in a release

On macOS/Linux, source installation builds the ArborRPC helper with a C17
compiler, including HTTP-only and BEAM-only applications. `CC` names one
compiler executable. Build the release on a compatible target platform and
include the dependency's built `priv` contents. An assembled release does not
compile the helper at startup. See
[ArborRPC troubleshooting](https://github.com/trust-arbor/arbor_rpc/blob/main/docs/TROUBLESHOOTING.md).

### A renamed module or option no longer exists

The v2 change includes API retirements as well as namespace changes. The old
Tools DSL, `HttpPlug.start_link` and mount `handler_call_timeout` are removed.
Use the [migration guide](guides/MIGRATING_V1_TO_V2.md), a supervised Runtime
and `request_timeout_ms`; a global `ExMCP` text replacement is insufficient.

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

Check the URL and endpoint path. If the path is included in `url`, ArborMCP uses
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
contain non-empty `name` and `version` strings. ArborMCP adds these fields for its
own clients; this error usually indicates a custom peer, manually constructed
JSON-RPC message, or middleware that rewrote `params._meta`.

### Error `-32020`: HTTP header mismatch

Modern HTTP requests must carry exactly one `MCP-Protocol-Version` and
`Mcp-Method` header matching the JSON-RPC body. `tools/call`,
`resources/read`, and `prompts/get` also require a matching `Mcp-Name`.
Annotated tool arguments may require `Mcp-Param-*` headers.

ArborMCP derives and replaces these headers automatically. If the error occurs
with an ArborMCP client, inspect reverse-proxy behavior: duplicate headers must
not be collapsed by choosing one value, and routing headers must not be
cached, normalized to a different value, or injected by middleware.

### Result is rejected for missing `resultType`, `ttlMs`, or `cacheScope`

Every modern result needs `resultType: "complete"` or
`resultType: "input_required"`. A complete cacheable result must also contain
a non-negative integer `ttlMs` and `cacheScope` equal to `"public"` or
`"private"`. Non-complete results must not contain cache hints. Legacy result
maps do not gain these fields merely because the transport is HTTP.

When the server uses ArborMCP's normal Handler or DSL dispatch, return the usual
`{:ok, result, state}` / `ToolResult.*` shape and let
`Arbor.MCP.Server.ResultNormalizer` add `resultType` plus conservative cache
defaults (`ttlMs: 0`, `cacheScope: "private"`). Suspend an operation with
`Arbor.MCP.Server.DSL.Result.input_required/2` or the documented
`{:input_required, ...}` handler tuple. If a custom peer constructs raw wire
results or bypasses ArborMCP dispatch, it must add and validate the modern fields
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

## Runtime capacity and lifecycle

### Request ID tracking capacity exceeded

BEAM/test and stdio peers retain at most `max_request_ids` distinct request IDs
(10,000 by default) for duplicate-execution protection. A long-lived connection
can reach that limit even when each individual request succeeds and finishes.
Choose an appropriate finite bound and plan connection rotation. For BEAM/test,
stop the old Client and start a new Client against the retained server. Calling
`Client.connect/2` does not reconnect an existing Client PID. HTTP sessions have
separate request-ID retention and expiration.

### Increasing concurrency fails validation

Stateful callbacks are serialized. More than one callback worker requires
`execution: :stateless`, and those callbacks must return unchanged initialized
state. Queue capacity and input/output byte limits are independent of concurrency.
See the [runtime guide](RUNTIME_GUIDE.md).

### Stopping a client does not stop its server

An existing BEAM server, Phoenix listener or borrowed service belongs to its
original owner. Stop the Runtime when its whole endpoint should end. Under a
parent supervisor, terminate that child through the parent if it should remain
stopped. Check cleanup results: process death does not by itself establish
native child reaping or remote request cancellation.

## Debugging

Enable debug logging for non-stdio transports:

```elixir
Logger.configure(level: :debug)
```

Inspect formatted OTP status when diagnosing a Runtime:

```elixir
:sys.get_status(server)
```

The returned server PID is a supervisor, not the handler-state GenServer.
Normal library diagnostics omit request/handler payloads. Raw state inspection
and explicitly enabled debug buffers may expose sensitive data; see
[runtime diagnostics](DIAGNOSTICS.md).

Run focused tests:

```bash
mix test test/arbor_mcp/client_beam_transport_test.exs
mix test test/arbor_mcp/server/transport_test.exs
```
