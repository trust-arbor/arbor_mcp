# Embedded forwarding example (Stage 0)

Run from the repository root after `mix deps.get`:

```sh
mix run examples/forwarding_gateway/demo.exs
mix test test/arbor_mcp/forwarding_gateway_test.exs --include integration
```

This fixture starts three host-owned loopback HTTP listeners on OS-assigned
ports: two controlled upstream endpoints and one forwarding endpoint. Alice
and Bob each have a separate Runtime/client set on those endpoints. No external
credentials, account state or running MCP server is used. The short demo lists
the six namespaced tools, completes an interactive upstream tool, and stops its
supervision tree. Tests exercise the same example modules over actual HTTP.

## Pieces

- `gateway.exs`: a forwarding Handler, a host-authentication Plug and a
  supervised tool-change watcher, built using public APIs.
- `support.exs`: controlled upstream tools, a downstream form-elicitation
  handler, and fixture supervision/listener setup.
- `demo.exs`: a short executable run. Diagnostics and compilation output make
  this a command-line demonstration, not a stdio protocol server.

Aliases such as `alpha__echo` and `beta__ask` resolve through an immutable route
map. `handle_get_tool/2` and tool execution use the same definition. Normal tool
results retain structured content. Upstream calls run in linked tasks; the
callback relays progress with its own downstream context and cleans up the
task when cancelled. An encrypted MRTR application state carries the upstream
continuation, stable upstream progress token and original deadline; the Runtime
provides replay protection. No extra continuation store is used.

The fixture's credential strings are deliberately fake and fixed. They select
server-owned identity routes; a production host must authenticate real tokens
and supply its own credential integration. An inbound gateway token is never
forwarded to an upstream. Separate identity Runtimes let the watcher use normal
Runtime-scoped publications without broadcasting one person's upstream changes
to another person's sessions.

## Deliberate scope

- Upstreams use modern `2026-07-28` HTTP. Downstream tests cover modern HTTP
  and legacy `2025-11-25` HTTP with exactly the fixture's form-elicitation
  capability profile. Other legacy profiles are rejected during initialization;
  do not generalize this into arbitrary legacy-client compatibility.
- Routes and schemas are static. Tool-change notifications exercise upstream
  subscription acknowledgment, downstream modern/legacy notification paths and
  identity isolation; they do not implement a mutable production catalog.
- Tool-call batches are outside the fixture. The host's per-request application
  context distinguishes caller-owned argument `_meta` from Runtime-injected
  metadata so new downstream progress tokens do not change upstream arguments.
- Each identity's watcher owns a fixed pair of upstream catalog subscriptions
  for the Runtime lifetime, independently of individual tool calls/listeners.
  Stopping the identity releases them. Per-downstream dynamic interest and
  ref-counted feed pooling are not implemented.
- Upstream clients explicitly use `conformance_mode: false` with
  `http_stream_retry: :safe_only`, and ordinary retries are limited to one
  attempt. This prevents replay of a tool call after an ambiguous stream break.
  The option is an existing opt-out policy, not a change to library defaults
  or a claim that this policy matches the standard stream-retry behavior.
- The controlled tools emit two progress updates per interactive call. The
  fixture is not a proof of bounded delivery from an arbitrary event flood:
  `progress_to:` and generic subscription delivery still use plain messages.
- Resource/prompt/task forwarding, real harness/vendor certification, shared
  multi-user Runtime routing, persistent credentials, multi-node recovery and a
  standalone service remain outside this example.

The [design draft](../../docs/GATEWAY_DESIGN.md) and
[library forwarding docs](../../docs/CONFIGURATION.md#forwarding-clients-mcp-2026-07-28)
explain the wider design and current resource-read progress limitation. Examples
are repository-only; the package's existing forwarding APIs are available to
normal Hex consumers.
