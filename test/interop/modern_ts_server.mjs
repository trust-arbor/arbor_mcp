// MCP 2026-07-28 TypeScript SDK server used by Arbor.MCP stdio interop tests.
// The v2 serving entry rejects legacy initialization, so this fixture cannot
// silently fall back to a 2025 protocol revision.
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createModernServer } from "./modern_ts_fixture.mjs";

const handle = serveStdio(() => createModernServer(), {
  legacy: "reject",
  onerror: (error) => process.stderr.write(`[modern-ts-server] ${error.message}\n`),
});

let shuttingDown = false;
const shutdown = async () => {
  if (shuttingDown) return;
  shuttingDown = true;

  try {
    await handle.close();
  } finally {
    process.exit(0);
  }
};

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
