# MCP Apps

`Arbor.MCP.Apps` supports the **server authoring role** of stable MCP Apps
`2026-01-26`: link tools to predeclared HTML resources, declare visibility and
resource policy, and select text fallback for hosts without Apps support. It
uses existing MCP tools/resources and transports. The
[runnable calculator example](https://github.com/trust-arbor/arbor_mcp/tree/master/examples/mcp_apps)
includes an official-SDK browser View and stdio/HTTP launchers.

Browser rendering and the separate `ui/*` protocol belong to the embedding Host
and View. Use the official JavaScript Apps SDK there. Advertising Apps on an
Elixir client alone does not create a rendering host.

## Author a tool and resource

The helpers accept ordinary MCP maps with **string keys** and return
`{:ok, map}` or `{:error, {:invalid_app_field, field}}`. They preserve unrelated
metadata and unknown UI fields for extensibility.

```elixir
alias Arbor.MCP.Apps

{:ok, tool} = Apps.tool(
  %{"name" => "forecast", "inputSchema" => %{"type" => "object"}},
  %{"resourceUri" => "ui://weather/forecast.html"}
)
{:ok, resource} = Apps.resource(%{
  "uri" => "ui://weather/forecast.html", "name" => "Forecast"
})
:ok = Apps.validate_catalog([tool], [resource])

{:ok, content} = Apps.html(resource["uri"], html_document, %{
  "csp" => %{"connectDomains" => [], "resourceDomains" => []},
  "prefersBorder" => false
})
# resources/read returns %{"contents" => [content]}.
```

Serve the **valid HTML5 document** through `resources/read`, with exactly
`text/html;profile=mcp-app`. `Apps.html/3` accepts nonempty UTF-8 text;
`Apps.blob/3` accepts nonempty base64-encoded document bytes. These helpers check
wire fields; they do not parse/sanitize HTML or fetch its assets. `Apps.resource/2`
builds the declaration with the correct MIME type. `validate_catalog/2` checks
that linked resources exist in the supplied registered catalog, including any
UI-only resources intentionally omitted from `resources/list`. It does not
prove a dynamic read callback returns the declared content.

The helpers work with raw Handler callbacks and existing runtime `Server.add_tool`
/ `Server.add_resource` registration. DSL authors can declare the equivalent
metadata using `meta %{"ui" => ...}` in a tool/resource block; consult the
[DSL guide](DSL_GUIDE.md). For capability-dependent catalogs, use the raw Handler
pattern in the example. No new dispatch callback or transport is required.

Tool metadata uses `_meta.ui.resourceUri`. The tool helper also emits the
upstream SDK's deprecated `_meta["ui/resourceUri"]` compatibility alias and
rejects conflicting aliases. HTML is predeclared; returning inline HTML inside
a tool result is not the Apps resource-linkage pattern.

## Capabilities and fallback

Hosts explicitly advertise:

```elixir
capabilities = Apps.put_capability(existing_string_keyed_capabilities)
Apps.supported?(capabilities)
# extensions["io.modelcontextprotocol/ui"].mimeTypes includes
# "text/html;profile=mcp-app"
{:ok, selected} = Apps.tools_for_client(all_tools, capabilities)
```

Invoke selection with the **active client's** capabilities. Modern handlers get
per-request capabilities from `Arbor.MCP.Server.Context.current()`. Legacy
handlers must retain initialized capabilities per connection/session; never
put one client's capabilities into a shared global profile. The example shows
a bounded, serialized cache and documents its node-lifetime limit.

Apps-capable hosts receive all declarations and enforce audience visibility.
Other hosts receive model-visible declarations with UI metadata removed;
unrelated metadata is retained. Malformed UI declarations return an error.
The callback must always return meaningful `content` for both UI and text-only
use. It may additionally return `structuredContent` for rendering and `_meta`
for UI-only data. Existing client APIs preserve the complete result; the Host
controls what enters model context. Keep `_meta` out of model context and follow
the Apps specification's UI-targeted data rules.

## Visibility and resource policy

`visibility` is an array containing `"model"`, `"app"`, both (the default), or
neither (an empty array). App-only helper tools may omit `resourceUri`.
`Apps.visible_to?(tool, :model | :app)` checks this declaration, failing closed
for malformed fields. It is a selection predicate, **not authorization**:

- The Host excludes app-only tools from the model catalog.
- The Host rejects View calls to model-only tools and binds View tool calls to
  their originating server connection. It blocks cross-server app-only calls.
- The server still applies normal authentication and application authorization;
  a raw MCP `tools/call` has no trusted model-versus-View identity signal.

Resource `_meta.ui` supports `csp` (`connectDomains`, `resourceDomains`,
`frameDomains`, `baseUriDomains` string arrays), requested `permissions`
(`camera`, `microphone`, `geolocation`, `clipboardWrite` objects), host-defined
`domain`, and boolean `prefersBorder`. Put final security/rendering policy on the
resource content returned by `resources/read`; a listing declaration alone is
not browser enforcement. Helpers check known wire types, not whether an origin
is safe or a domain matches a particular host. Permission requests can be denied;
Views must feature-detect capabilities.

Web Hosts must provide a different-origin sandbox proxy, sandboxed View,
source/origin-validated messaging and declared-domain CSP with restrictive
defaults. They also own template review, audit, resource limits and consent for
links, downloads, messages, model-context changes and other advertised actions.
ArborMCP does not ship a production browser Host or an Elixir implementation of
all `ui/*` methods.

## Evidence and scope

The [requirements tracker](MCP_REQUIREMENTS.md) separates implemented server
mechanisms from Host/View duties and deferred formats. Its Apps source manifest
hashes the stable prose and protocol types at the reviewed revision and maps
every heading/export to a responsibility. The weekly extension watcher reports
upstream specification/type changes; the tooling watcher tracks the pinned Apps
SDK separately. Pins are reviewed rather than automatically upgraded.

Named tests cover helper validation, modern/legacy HTTP, fallback and profile
isolation. The pinned official client/Apps SDK validate wire declarations and
exercise App/AppBridge input/result, View calls/reads and teardown over HTTP and
the documented stdio launcher. Chromium runs the rebuilt example with a
cross-origin upstream sandbox, tests host visibility/connection denials and CSP,
and preserves light/dark/mobile screenshots. These are scoped SDK/browser
integration tests; they are not official Apps conformance scenarios or universal
vendor certification. Existing official **core** conformance tests remain the
core protocol authority. See [assurance](MCP_ASSURANCE.md) and the
[extension matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md#mcp-extensions).
