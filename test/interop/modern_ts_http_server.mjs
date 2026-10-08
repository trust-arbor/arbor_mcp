// MCP 2026-07-28 TypeScript SDK v2 HTTP server for Arbor.MCP interop tests.
import { createServer as createHttpServer } from "node:http";
import { createMcpHandler } from "@modelcontextprotocol/server";
import {
  localhostHostValidation,
  localhostOriginValidation,
  toNodeHandler,
} from "@modelcontextprotocol/node";
import { createModernServer } from "./modern_ts_fixture.mjs";

let handler;
handler = createMcpHandler(
  () =>
    createModernServer({
      publishToolsChanged: () => handler.notify.toolsChanged(),
    }),
  {
    legacy: "reject",
    responseMode: "auto",
    keepAliveMs: 0,
    onerror: (error) =>
      process.stderr.write(`[modern-ts-http-server] ${error.message}\n`),
  }
);

const serveMcp = toNodeHandler(handler, {
  onerror: (error) =>
    process.stderr.write(`[modern-ts-http-adapter] ${error.message}\n`),
});
const validateHost = localhostHostValidation();
const validateOrigin = localhostOriginValidation();

const httpServer = createHttpServer((req, res) => {
  if (req.url !== "/mcp") {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("Not found");
    return;
  }

  if (!validateHost(req, res) || !validateOrigin(req, res)) return;
  void serveMcp(req, res);
});

httpServer.listen(0, "127.0.0.1", () => {
  const address = httpServer.address();
  process.stdout.write(`PORT:${address.port}\n`);
});

let shuttingDown = false;
const shutdown = async () => {
  if (shuttingDown) return;
  shuttingDown = true;

  try {
    await handler.close();
  } finally {
    httpServer.close(() => process.exit(0));
  }
};

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
