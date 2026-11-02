# MCP Apps: workspace plan calculator

An Elixir MCP server serves a self-contained HTML View, authored with the
[official Apps SDK](https://github.com/modelcontextprotocol/ext-apps). A model
calls `plan`; an Apps-capable host renders the calculator. Changing the sliders
and clicking **Update estimate** calls the same server's app-only `update_plan`
tool. `plan_policy` is model-only. Every calculation also returns meaningful
text for clients without Apps support. Prices are illustrative; nothing is
purchased or stored.

## Build and run

From the **repository root**, using the supported Elixir/OTP toolchain, Node.js
24+ and npm:

```sh
mix deps.get
mix compile
npm ci --prefix examples/mcp_apps --ignore-scripts --no-audit --no-fund
npm run --prefix examples/mcp_apps build
mix run --no-compile examples/mcp_apps/run.exs -- --stdio
```

The process waits for an MCP client on stdin and keeps logs on stderr. In your
Apps-capable host's stdio server configuration, use the absolute `mix` executable,
this checkout as the working directory, and these arguments:

```json
{
  "command": "/absolute/path/to/mix",
  "args": ["run", "--no-compile", "examples/mcp_apps/run.exs", "--", "--stdio"],
  "cwd": "/absolute/path/to/arbor_mcp"
}
```

Host configuration formats differ; adapt those three fields to your host and
ensure its environment finds Erlang/Elixir. Alternatively, serve loopback HTTP:

```sh
mix run --no-compile examples/mcp_apps/run.exs -- --http 8080
```

Connect an Apps-capable host to `http://127.0.0.1:8080/mcp`. The example listener
accepts its own loopback Origin. Browser hosts with another Origin require an
explicit application-owned allowlist; do not disable Origin validation.
This local example has no authentication and is intended for local development.

## Run an example host with Phoenix

The [Phoenix LiveView host](phoenix_host/) connects to this server using native
ArborMCP clients, renders the View in a separate-origin sandbox, and demonstrates
model/app tool filtering, text/private-data separation, theme and close/reopen.
Its README has complete two-terminal setup; no LLM account or Node server is needed.

## Files and responsibilities

- `server.exs` uses `Arbor.MCP.Apps` to build validated tool/resource metadata,
  checks linked resources, selects a capability-aware catalog, and serves HTML.
- `view.ts` uses official `App` lifecycle/tool APIs; `view.html` contains authored
  layout/styles. `build.mjs` bundles the SDK into `dist/view.html`. No CDN, remote
  fonts, or external assets are required; all declared CSP domain lists are empty.
- `run.exs` owns the server, supports stdio or HTTP, and exits on server shutdown.
  This source-checkout example does not use `Mix.install`.

Modern requests carry their active client capabilities. The example also
supports legacy initialized clients using a **bounded 16-profile cache** keyed
by session/connection in serialized handler state (`execution: :stateful`).
Profiles remain until this example server stops; reconnecting legacy sessions
can exhaust that demonstration limit. A long-running application should own
session pruning and capacity policy rather than copy this cache unchanged.

The embedding host supplies rendering, cross-origin sandboxing, CSP enforcement,
permission/consent policy, model/app visibility and binding to the originating
server connection. Tool visibility metadata is not server authorization.
ArborMCP does not turn an Elixir client into a browser rendering host. See the
[Apps guide](../../docs/MCP_APPS.md) for the public helpers and integration contract.

## Qualification

CI exercises the documented stdio launcher and HTTP server through the pinned
official MCP client and Apps SDK. A dedicated Chromium lane runs this exact
rebuilt View through official `AppBridge` and a vendored upstream cross-origin
sandbox proxy. It checks input/result/metadata (including exact 123 GB values), app-only
updates, model-only denial and a registered app-only tool on a second real
connection, CSP denial against a reachable local endpoint, theme/resize and teardown,
and preserves light/dark/mobile screenshots and the built HTML hash.

The browser host under `test/interop/` is a controlled test fixture with a narrow
profile, not a production host example. The tests do not certify every vendor
host or every UI method. Reproduce them with the commands in
[the assurance guide](../../docs/MCP_ASSURANCE.md#mcp-apps-browser-qualification).
