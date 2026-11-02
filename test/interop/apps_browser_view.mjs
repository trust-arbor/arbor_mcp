import { AppBridge, PostMessageTransport } from "@modelcontextprotocol/ext-apps/app-bridge";
async function main() {
const data = await (await fetch("/bootstrap")).json();
const iframe = document.querySelector("#view");
// Only content reaches this fixture's model-facing context; _meta goes to the View.
document.querySelector("#model-tools").textContent = data.tools.filter(t => (t._meta?.ui?.visibility ?? ["model", "app"]).includes("model")).map(t => t.name).join(", ");
document.querySelector("#model-result").textContent = data.result.content.filter(c => c.type === "text").map(c => c.text).join("\n");
const bridge = new AppBridge(null, { name: "browser-fixture", version: "1" }, { serverTools: {}, serverResources: {} }, {
  hostContext: { theme: "light", displayMode: "inline", toolInfo: { tool: data.tool } },
});
const post = async (path, params) => {
  const response = await fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(params) });
  if (!response.ok) throw new Error("The app request was rejected");
  return response.json();
};
bridge.oncalltool = params => post("/call", params);
bridge.onreadresource = params => post("/resource", params);
bridge.onsandboxready = () => bridge.sendSandboxResourceReady({ html: data.html, csp: data.ui.csp, permissions: data.ui.permissions });
bridge.oninitialized = async () => {
  await bridge.sendToolInput({ arguments: data.args });
  await bridge.sendToolResult(data.result);
  document.body.dataset.initialized = "true";
};
let sizes = 0;
bridge.onsizechange = params => {
  sizes++;
  if (params.height) iframe.style.height = `${Math.min(Math.max(params.height, 300), 2000)}px`;
};
window.testHost = {
  setTheme: theme => bridge.setHostContext({ theme }),
  sendInput: args => bridge.sendToolInput({ arguments: args }),
  completePlan: async args => bridge.sendToolResult(await post("/call", { name: "plan", arguments: args })),
  sizeChanges: () => sizes,
  teardown: async () => { await bridge.teardownResource({}); iframe.remove(); await bridge.close(); return true; },
};
await bridge.connect(new PostMessageTransport(iframe.contentWindow, iframe.contentWindow));
iframe.src = data.sandboxOrigin;

}
main().catch(error => { console.error(error); throw error; });
