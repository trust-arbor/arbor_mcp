# Phoenix MCP Apps host

A runnable Phoenix LiveView host for the adjacent [workspace calculator](../).
The model-facing tool list and text result sit beside a sandboxed interactive
View. Phoenix uses **`Arbor.MCP.Client` on the server**; the browser uses the
official JavaScript `AppBridge`. There is no Node.js runtime server, database,
LLM account or API key to configure. Node is used to build the browser assets.

## Run it

Requirements: the repository's supported Elixir/OTP toolchain, Node.js 24+ and npm.
A C17 compiler builds the optional shared RPC subprocess helper; this HTTP
example does not use that helper. The example pins Phoenix
1.8.15, LiveView 1.2.13 and Bandit 1.14.1 in its own Mix project/lockfile. These
are example dependencies; they are not added to the ArborMCP library package.

First build the View from the **repository root**:

```sh
mix deps.get
mix compile
npm ci --prefix examples/mcp_apps --ignore-scripts --no-audit --no-fund
npm run --prefix examples/mcp_apps build
```

In one terminal, start the calculator MCP server from the repository root:

```sh
mix run --no-compile examples/mcp_apps/run.exs -- --http 8080
```

In another terminal, install/build/start the host:

```sh
cd examples/mcp_apps/phoenix_host
mix deps.get
mix compile
node build.mjs
mix phx.server
```

Open **http://127.0.0.1:4000** and choose **plan**. Adjust the calculator's
sliders and click **Update estimate**. The update calls the app-only tool through
LiveView, while the model-facing text remains separate. **plan_policy** is a
text-only tool. Try the theme toggle, close/reopen the View, or open a second tab.
All prices are illustrative; nothing is purchased or stored.

The sandbox listens on **http://127.0.0.1:4001**. Use the literal `127.0.0.1`
addresses; both endpoints reject other Host names. To change ports or the
upstream, set these when starting `mix phx.server`:

```sh
MCP_APPS_HOST_PORT=4100 MCP_APPS_SANDBOX_PORT=4101 \
MCP_APPS_SERVER_URL=http://127.0.0.1:8181/mcp mix phx.server
```

Start the adjacent calculator server on that upstream port too. The host accepts
only a configured literal-loopback HTTP URL. Browser requests cannot choose a
server URL or credentials. Re-run `node build.mjs` after changing JS/CSS or
Phoenix/LiveView dependencies. Reload after starting/restarting the MCP server.

## How it fits together

1. A connected LiveView opens its own modern HTTP MCP client and bounded tool
   catalog. A disconnected HTTP render opens no client. ArborMCP's native client
   lifetime follows the LiveView process, including abrupt owner exit.
2. Phoenix filters the model list using `Apps.visible_to?/2`. A user-selected
   tool runs on that connection; only text `content` reaches the model-context
   panel. Complete results, including `structuredContent`/`_meta`, go to the View.
3. Phoenix reads the tool's predeclared `ui://` resource and checks URI, exact
   MIME, UTF-8 text or base64-encoded UTF-8 HTML, a 1 MiB limit and the local resource profile.
4. The browser creates an official `AppBridge` and a sandbox proxy iframe on
   the **other endpoint/origin**. The upstream proxy creates the inner View.
   The Host sends tool input/result only after the View initializes.
5. View `tools/call` and `resources/read` requests go over LiveView to the native
   client. The server checks the current View binding, known same-connection
   catalog, app visibility and resource allowlist. A replaced/closed binding is
   rejected. There is no cross-server routing or arbitrary JSON-RPC relay.
6. Close/replacement requests bounded SDK teardown before removing the frame.
   Closing a browser retires its LiveView/client without affecting other tabs.

`lib/mcp_apps_host/connection.ex` contains the explicit local policy;
`host_live.ex` owns the client/binding and renders the controls; `assets/host.js`
contains the LiveView hook/bridge. The vendor sandbox source is copied verbatim
from the reviewed upstream revision; see `assets/vendor/README.md` and LICENSE.

## Deliberate example scope

This is a **local, single-server calculator host**, not a production host SDK.
It supports self-contained HTML only: no declared external network/resource/
frame/base domains, requested browser permissions, dedicated domain, or unknown
resource-policy fields. Unsupported policy is rejected. Sandbox CSP uses
restrictive defaults with no external connections, no nested frames or objects;
its frame-ancestors policy permits only this host origin. The host has loopback
binding/Host checks, an exact configured LiveView Origin check and CSRF protection, and same-site cookies.
It never renders server HTML directly in the Phoenix document.

The host advertises only server-tool and server-resource forwarding. Links,
downloads, messages, model-context mutation, fullscreen/pip, tasks and MRTR input
rounds are not adopted by this example. The visible "model context" panel is a
text illustration, not an integrated LLM conversation. Application authentication,
tenant credential partitions, resource review/consent and deployment policy must
be designed before turning it into a network service or accepting untrusted
servers. The calculator's explicit user actions are read-only recalculations.

## Tests

Run the local policy contracts:

```sh
mix test --no-start
```

The repository's `apps.browser.phoenix_host` case builds this actual project and
assets, runs Chromium against two real endpoints and a real Elixir MCP server,
and checks updates/read forwarding, hidden app-only tools, denied model-only/
unknown calls, unsupported actions, private metadata separation, CSP and origin
isolation, theme, close/reopen, LiveView reconnect, two-tab independence and native client exit when
the browsers close. CI retains empty/light/dark/mobile screenshots and the built
host asset hashes. See [assurance](../../../docs/MCP_ASSURANCE.md#mcp-apps-browser-qualification)
from the repository root, or the [Apps guide](../../../docs/MCP_APPS.md).

`priv/static/.gitkeep` keeps the asset directory present during the first Mix
compile so Mix links it into the built application before the Node build runs.
The browser test verifies the served asset bytes against the freshly built hashes.
