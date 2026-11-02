import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { AppBridge, PostMessageTransport } from "@modelcontextprotocol/ext-apps/app-bridge";

const AppsHost = {
  mounted() {
    this.current = null;
    this.generation = 0;
    document.documentElement.dataset.theme = this.el.dataset.theme;
    this.canvas = this.el.querySelector("#app-canvas");
    this.empty = this.canvas.innerHTML;
    this.closeButton = this.el.querySelector("#close-view");
    this.onClose = () => this.closeCurrent();
    this.closeButton.addEventListener("click", this.onClose);
    this.handleEvent("app:mount", data => this.mountView(data));
    this.handleEvent("app:theme", ({theme}) => {
      document.documentElement.dataset.theme = theme;
      this.current?.bridge.setHostContext({ theme });
    });
  },
  request(binding, operation, params) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("The local MCP request timed out.")), 7000);
      this.pushEvent("app_rpc", {binding, operation, params}, response => {
        clearTimeout(timer);
        if (response?.error) reject(new Error(response.error));
        else resolve(response.ok);
      });
    });
  },
  async dispose(view) {
    if (!view || view.closed) return;
    view.closed = true;
    try { await view.bridge.teardownResource({}, { timeout: 2000 }); } catch { /* bounded best effort */ }
    view.frame.remove();
    await view.bridge.close();
  },
  async closeCurrent() {
    const view = this.current;
    if (!view) return;
    ++this.generation;
    this.current = null;
    this.pushEvent("close_app", {binding: view.binding});
    await this.dispose(view);
    if (!this.current) this.canvas.innerHTML = this.empty;
  },
  async mountView(data) {
    const generation = ++this.generation;
    const previous = this.current;
    this.current = null;
    await this.dispose(previous);
    if (generation !== this.generation) return;
    this.canvas.replaceChildren();
    const frame = document.createElement("iframe");
    frame.id = "mcp-app-view";
    frame.title = "Workspace plan app";
    frame.setAttribute("sandbox", "allow-scripts allow-same-origin");
    this.canvas.append(frame);
    const bridge = new AppBridge(null, { name: "Arbor Phoenix host", version: "0.1.0" },
      { serverTools: {}, serverResources: {} },
      { hostContext: { theme: data.theme, displayMode: "inline", toolInfo: { tool: data.tool } } });
    const view = { binding: data.binding, frame, bridge, closed: false };
    this.current = view;
    const forward = (operation, params) => {
      if (view.closed || this.current !== view) throw new Error("The View is closed.");
      return this.request(view.binding, operation, params);
    };
    bridge.oncalltool = params => forward("tools/call", params);
    bridge.onreadresource = params => forward("resources/read", params);
    bridge.onsandboxready = () => bridge.sendSandboxResourceReady({html: data.html, csp: data.ui.csp, permissions: {}});
    bridge.oninitialized = async () => {
      await bridge.sendToolInput({arguments: data.args});
      await bridge.sendToolResult(data.result);
    };
    bridge.onsizechange = ({height}) => { if (height) frame.style.height = `${Math.min(Math.max(height, 340), 1600)}px`; };
    try {
      await bridge.connect(new PostMessageTransport(frame.contentWindow, frame.contentWindow));
      if (generation !== this.generation) { await this.dispose(view); return; }
      frame.src = data.sandboxOrigin;
    } catch {
      await this.dispose(view);
      if (this.current === view) { this.current = null; this.canvas.textContent = "The View could not start. Choose the tool to try again."; }
    }
  },
  disconnected() {
    ++this.generation;
    const view = this.current;
    this.current = null;
    // A lost LiveView connection retires its MCP client and all View bindings.
    void this.dispose(view).then(() => { if (!this.current) this.canvas.innerHTML = this.empty; });
  },
  updated() {
    document.documentElement.dataset.theme = this.el.dataset.theme;
  },
  reconnected() {
    document.documentElement.dataset.theme = this.el.dataset.theme;
  },
  destroyed() {
    this.closeButton.removeEventListener("click", this.onClose);
    this.disconnected();
  },
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, { hooks: { AppsHost }, params: { _csrf_token: csrfToken } });
liveSocket.connect();
