// TypeScript MCP Client for interop testing
// Connects to a server via stdio, runs operations, outputs JSON results to stderr
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const serverCommand = process.argv[2];
const serverArgs = process.argv.slice(3);

if (!serverCommand) {
  process.stderr.write(
    JSON.stringify({ error: "Usage: node ts_client.mjs <command> [args...]" }) +
      "\n"
  );
  process.exit(1);
}

const results = {};
const requestOptions = { timeout: 10_000 };
// Starting a nested Mix VM can take longer on a cold, shared CI runner even
// when the project is already compiled. Keep the protocol timeout bounded,
// but allow enough time for the child BEAM to boot before initialization.
const connectOptions = { timeout: 30_000 };

// The SDK intentionally inherits only a small allow-list of environment
// variables. Pass MIX_ENV explicitly so a clean CI runner reuses the
// already-compiled test build instead of compiling a dev build on stdout, and
// forward the parent's Mix paths so a version manager (mise/asdf) child loads
// the same Hex archive as the parent instead of a stale global one.
function mixChildEnv() {
  const env = { MIX_ENV: process.env.MIX_ENV ?? "test" };
  for (const name of ["MIX_HOME", "MIX_ARCHIVES", "MIX_DEPS_PATH", "ARBOR_RPC_PATH", "ARBOR_V2_DEPS", "ARBOR_V2_BUILD", "ARBOR_V2_LOCK"]) {
    if (process.env[name]) env[name] = process.env[name];
  }
  return env;
}

try {
  const transport = new StdioClientTransport({
    command: serverCommand,
    args: serverArgs,
    env: mixChildEnv(),
  });

  const client = new Client({
    name: "ts-test-client",
    version: "1.0.0",
  });

  await client.connect(transport, connectOptions);
  results.connected = true;

  // List and call tools
  try {
    const toolsResult = await client.listTools(undefined, requestOptions);
    results.tools = toolsResult.tools.map((t) => t.name);
  } catch (e) {
    results.tools_error = e.message;
  }

  // Call echo tool
  try {
    const echoResult = await client.callTool(
      {
        name: "echo",
        arguments: { message: "hello from TS" },
      },
      undefined,
      requestOptions
    );
    results.echo = echoResult;
  } catch (e) {
    results.echo_error = e.message;
  }

  // Call add tool (if available)
  try {
    const addResult = await client.callTool(
      {
        name: "add",
        arguments: { a: 10, b: 20 },
      },
      undefined,
      requestOptions
    );
    results.add = addResult;
  } catch (e) {
    results.add_error = e.message;
  }

  // List resources
  try {
    const resourcesResult = await client.listResources(undefined, requestOptions);
    results.resources = resourcesResult.resources.map((r) => r.uri);
  } catch (e) {
    results.resources_error = e.message;
  }

  // List prompts
  try {
    const promptsResult = await client.listPrompts(undefined, requestOptions);
    results.prompts = promptsResult.prompts.map((p) => p.name);
  } catch (e) {
    results.prompts_error = e.message;
  }

  // Ping
  try {
    await client.ping(requestOptions);
    results.ping = true;
  } catch (e) {
    results.ping_error = e.message;
  }

  await client.close();
  results.success = !Object.keys(results).some((key) => key.endsWith("_error"));
} catch (e) {
  results.error = e.message;
  results.success = false;
}

// Output results to stderr (stdout is used by stdio transport)
process.stderr.write(JSON.stringify(results) + "\n");
process.exit(results.success ? 0 : 1);
