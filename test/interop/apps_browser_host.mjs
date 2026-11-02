// Test-only, loopback host for the shipped example. Not a general Apps host.
import assert from "node:assert/strict";
import http from "node:http";
import { createRequire } from "node:module";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { getToolUiResourceUri, McpUiResourceMetaSchema } from "@modelcontextprotocol/ext-apps/app-bridge";
const exampleRequire = createRequire(new URL("../../examples/mcp_apps/package.json", import.meta.url));
const { build } = exampleRequire("esbuild");
const makeClient = name => new Client({ name, version: "1" }, {
  capabilities: { extensions: { "io.modelcontextprotocol/ui": { mimeTypes: ["text/html;profile=mcp-app"] } } },
  versionNegotiation: { mode: { pin: "2026-07-28" }, probe: { timeoutMs: 10000, maxRetries: 0 } },
});
const client = makeClient("browser-apps-fixture");
const foreignClient = makeClient("second-server-fixture");
await client.connect(new StreamableHTTPClientTransport(new URL(process.argv[2])));
await foreignClient.connect(new StreamableHTTPClientTransport(new URL(process.argv[3])));
const { tools } = await client.listTools();
const foreignTool = (await foreignClient.listTools()).tools.find(t => t.name === "update_plan");
assert.deepEqual(foreignTool._meta.ui.visibility, ["app"]);
// A real registered and callable app-only tool on a different connection.
const foreignReady = (await foreignClient.callTool({ name: foreignTool.name, arguments: {} })).structuredContent.totalCents === 16400;
assert.ok(foreignReady);
const foreignName = "other_server__update_plan";
const catalog = [...tools, { ...foreignTool, name: foreignName }];
const routes = new Map(tools.map(tool => [tool.name, { tool, connection: client }]));
routes.set(foreignName, { tool: foreignTool, connection: foreignClient });
const tool = tools.find(t => t.name === "plan");
assert.ok(tool);
const uri = getToolUiResourceUri(tool);
const resource = (await client.readResource({ uri })).contents[0];
assert.equal(resource.mimeType, "text/html;profile=mcp-app");
const ui = McpUiResourceMetaSchema.parse(resource._meta.ui);
for (const key of ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"]) assert.deepEqual(ui.csp[key], []);
const args = { seats: 8, storageGb: 100 };
const result = await client.callTool({ name: "plan", arguments: args });
const bundle = async file => (await build({ entryPoints: [new URL(file, import.meta.url).pathname], bundle: true, write: false, platform: "browser", format: "iife", target: "es2022", minify: true, legalComments: "none" })).outputFiles[0].text;
const [hostJs, sandboxJs] = await Promise.all([bundle("./apps_browser_view.mjs"), bundle("./apps_upstream/sandbox.ts")]);
const forwarded = [];
const foreignForwarded = [];
let probeRequests = 0;
const listen = server => new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`)));
const send = (res, status, type, body, headers = {}) => { res.writeHead(status, { "content-type": type, ...headers }); res.end(body); };
const json = (res, status, value) => send(res, status, "application/json", JSON.stringify(value));
const csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'";
const sandbox = http.createServer((req, res) => {
  if (req.url === "/proxy.js") send(res, 200, "text/javascript", sandboxJs);
  else if (req.url === "/") send(res, 200, "text/html", '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:100%;height:100%}</style></head><body><script src="/proxy.js"></script></body></html>', { "content-security-policy": csp });
  else send(res, 404, "text/plain", "Not found");
});
const sandboxOrigin = await listen(sandbox);
const host = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/") return send(res, 200, "text/html", '<!doctype html><html><head><meta charset="utf-8"><title>Apps test host</title><style>body{margin:25px;background:#e3e7e4;font:14px monospace}#view{width:100%;height:650px;border:0;display:block}pre{white-space:pre-wrap}main{max-width:950px;margin:auto}</style></head><body><main><h1>MCP Apps test host</h1><pre id="model-tools"></pre><pre id="model-result"></pre><iframe id="view" title="Workspace plan" sandbox="allow-scripts allow-same-origin"></iframe></main><script src="/host.js"></script></body></html>');
    if (req.method === "GET" && req.url === "/host.js") return send(res, 200, "text/javascript", hostJs);
    if (req.method === "GET" && req.url === "/bootstrap") return json(res, 200, { tool, tools: catalog, uri, html: resource.text, ui, args, result, sandboxOrigin });
    if (req.method === "GET" && req.url === "/counts") return json(res, 200, { forwarded, foreignForwarded, foreignReady, registeredForeign: foreignName, probeRequests });
    if (req.method === "GET" && req.url === "/csp-probe") {
      probeRequests++;
      return send(res, 200, "text/plain", "reachable", { "access-control-allow-origin": "*" });
    }
    if (req.method === "POST" && ["/call", "/resource"].includes(req.url)) {
      const chunks = []; let size = 0;
      for await (const chunk of req) { size += chunk.length; if (size > 65536) return json(res, 413, { error: "Too large" }); chunks.push(chunk); }
      const params = JSON.parse(Buffer.concat(chunks).toString());
      if (req.url === "/resource") {
        if (params.uri !== uri) return json(res, 403, { error: "Resource outside this app connection" });
        return json(res, 200, await client.readResource({ uri }));
      }
      const route = routes.get(params.name);
      if (!route || route.connection !== client || !(route.tool._meta?.ui?.visibility ?? ["model", "app"]).includes("app")) return json(res, 403, { error: "Tool outside this app's visibility/connection" });
      (route.connection === client ? forwarded : foreignForwarded).push(route.tool.name);
      return json(res, 200, await route.connection.callTool({ name: route.tool.name, arguments: params.arguments }));
    }
    send(res, 404, "text/plain", "Not found");
  } catch (error) { process.stderr.write(String(error.stack ?? error)+"\n"); json(res, 500, { error: "Fixture request failed" }); }
});
const origin = await listen(host);
assert.notEqual(origin, sandboxOrigin);
process.stdout.write(JSON.stringify({ origin, sandboxOrigin }) + "\n");
let closing = false;
async function close() {
  if (closing) return; closing = true;
  await Promise.all([client.close(), foreignClient.close()]);
  await Promise.all([host, sandbox].map(s => new Promise(resolve => { s.closeAllConnections(); s.close(resolve); })));
  process.exit(0);
}
process.stdin.setEncoding("utf8");
process.stdin.on("data", data => { if (data.trim() === "close") void close(); });
process.stdin.on("end", close);
process.on("SIGTERM", close);
