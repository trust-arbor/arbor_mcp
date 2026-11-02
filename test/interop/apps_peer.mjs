import assert from "node:assert/strict";
import { Client, InMemoryTransport, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { App } from "@modelcontextprotocol/ext-apps";
import { AppBridge, getToolUiResourceUri, isToolVisibilityAppOnly, McpUiToolMetaSchema, McpUiResourceMetaSchema } from "@modelcontextprotocol/ext-apps/app-bridge";
import { getUiCapability, registerAppTool, RESOURCE_MIME_TYPE } from "@modelcontextprotocol/ext-apps/server";

const capabilities = { extensions: { "io.modelcontextprotocol/ui": { mimeTypes: [RESOURCE_MIME_TYPE] } } };
const client = new Client({ name: "official-apps-peer", version: "1" }, {
  capabilities, versionNegotiation: { mode: { pin: "2026-07-28" }, probe: { timeoutMs: 10000, maxRetries: 0 } },
});
const observations = [];
const observingFetch = async (input, init) => {
  const request = new Request(input, init);
  const payload = request.method === "POST" ? await request.clone().json() : {};
  const response = await fetch(request);
  if (["tools/list", "server/discover"].includes(payload.method)) {
    observations.push({ request: payload, response: await response.clone().text() });
  }
  return response;
};
const bridge = new AppBridge(null, { name: "official-bridge-peer", version: "1" }, { serverTools: {}, serverResources: {} }, { hostContext: { theme: "light", displayMode: "inline" } });
const app = new App({ name: "official-view-peer", version: "1" }, {}, { autoResize: false });

try {
  let transport;
  if (process.argv[2] === "--stdio") {
    const names = ["PATH", "HOME", "MIX_HOME", "HEX_HOME", "ARBOR_RPC_PATH", "ARBOR_V2_DEPS", "ARBOR_V2_BUILD", "ARBOR_V2_LOCK", "LANG", "LC_ALL", "ERL_FLAGS"];
    const env = Object.fromEntries(names.filter(k => process.env[k] !== undefined).map(k => [k, process.env[k]]));
    transport = new StdioClientTransport({ command: process.argv[3], args: ["run", "--no-compile", "examples/mcp_apps/run.exs", "--", "--stdio"], cwd: process.cwd(), env: {...env, MIX_ENV: "test"}, stderr: "inherit" });
  } else transport = new StreamableHTTPClientTransport(new URL(process.argv[2]), { fetch: observingFetch });
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(t => t.name).sort(), ["plan", "plan_policy", "update_plan"], JSON.stringify(observations));
  const tool = tools.find(t => t.name === "plan");
  const uri = getToolUiResourceUri(tool);
  assert.equal(uri, "ui://arbor/plan.html");
  McpUiToolMetaSchema.parse(tool._meta.ui);
  assert.equal(isToolVisibilityAppOnly(tools.find(t => t.name === "update_plan")), true);
  assert.deepEqual(tools.filter(t => !isToolVisibilityAppOnly(t)).map(t => t.name), ["plan", "plan_policy"]);
  assert.deepEqual(getUiCapability(capabilities).mimeTypes, [RESOURCE_MIME_TYPE]);
  let normalized;
  registerAppTool({ registerTool: (_name, config) => { normalized = config; } }, "plan", { _meta: { ui: { resourceUri: uri } } }, async () => ({ content: [] }));
  assert.deepEqual(tool._meta, normalized._meta);
  const { resources } = await client.listResources();
  assert.equal(resources[0].mimeType, RESOURCE_MIME_TYPE);
  const resource = await client.readResource({ uri });
  assert.equal(resource.contents[0].mimeType, RESOURCE_MIME_TYPE);
  assert.match(resource.contents[0].text, /<!doctype html>/i);
  McpUiResourceMetaSchema.parse(resource.contents[0]._meta.ui);
  assert.deepEqual(resource.contents[0]._meta.ui.csp.connectDomains, []);

  const forwarded = [];
  bridge.oncalltool = async params => {
    const known = tools.find(t => t.name === params.name);
    if (!known || (known._meta?.ui?.visibility && !known._meta.ui.visibility.includes("app"))) throw new Error("Tool is not available to this app connection");
    forwarded.push(params.name);
    return client.callTool({ name: params.name, arguments: params.arguments });
  };
  bridge.onreadresource = params => client.readResource({ uri: params.uri });
  const initialized = new Promise(resolve => { bridge.oninitialized = resolve; });
  const inputReceived = new Promise(resolve => { app.ontoolinput = resolve; });
  const resultReceived = new Promise(resolve => { app.ontoolresult = resolve; });
  let tornDown = false;
  app.onteardown = async () => { tornDown = true; return {}; };
  const [viewTransport, hostTransport] = InMemoryTransport.createLinkedPair();
  await bridge.connect(hostTransport);
  await app.connect(viewTransport);
  await initialized;
  assert.equal(app.getHostContext().theme, "light");
  const args = { seats: 8, storageGb: 100 };
  await bridge.sendToolInput({ arguments: args });
  assert.deepEqual((await inputReceived).arguments, args);
  const result = await client.callTool({ name: "plan", arguments: args });
  assert.match(result.content[0].text, /\$164\.00/);
  await bridge.sendToolResult(result);
  const delivered = await resultReceived;
  assert.equal(delivered.structuredContent.totalCents, 16400);
  assert.equal(delivered._meta["example/viewLabel"], "Local estimate");
  const updated = await app.callServerTool({ name: "update_plan", arguments: { seats: 12, storageGb: 200 } });
  assert.equal(updated.structuredContent.totalCents, 25600);
  assert.equal((await app.readServerResource({ uri })).contents[0].mimeType, RESOURCE_MIME_TYPE);
  await assert.rejects(app.callServerTool({ name: "plan_policy", arguments: {} }));
  await assert.rejects(app.callServerTool({ name: "other_server__tool", arguments: {} }));
  assert.deepEqual(forwarded, ["update_plan"]);
  await bridge.teardownResource({});
  assert.equal(tornDown, true);
  process.stdout.write(JSON.stringify({ uri, toolCount: tools.length, totalCents: updated.structuredContent.totalCents, forwarded, metadata: delivered._meta["example/viewLabel"], tornDown }) + "\n");
} finally {
  await Promise.allSettled([app.close(), bridge.close(), client.close()]);
}
