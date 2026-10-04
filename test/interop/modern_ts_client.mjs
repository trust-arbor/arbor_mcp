// MCP 2026-07-28 TypeScript SDK client used by Arbor.MCP interop tests.
// Connects with an exact version pin so the test cannot fall back to legacy.
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const serverCommand = process.argv[2];
const serverArgs = process.argv.slice(3);

if (!serverCommand) {
  process.stderr.write(
    `${JSON.stringify({ error: "Usage: node modern_ts_client.mjs <command> [args...]" })}\n`
  );
  process.exit(1);
}

const results = {};
const requestOptions = { timeout: 10_000 };
let client;

const textFromResult = (result) =>
  (result?.content ?? [])
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join(" ");

const waitFor = (promise, timeoutMs, label) =>
  Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`Timed out waiting for ${label}`)), timeoutMs)
    ),
  ]);

// The SDK intentionally inherits only a small allow-list of environment
// variables. Pass MIX_ENV explicitly so a clean CI runner reuses the
// already-compiled test build instead of compiling a dev build on stdout, and
// forward the parent's Mix paths so a version manager (mise/asdf) child loads
// the same Hex archive as the parent instead of a stale global one. Explicit
// split-development overrides must also select the same RPC source/build/lock.
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
    cwd: process.cwd(),
    env: mixChildEnv(),
  });

  client = new Client(
    {
      name: "ts-modern-interop-client",
      version: "2.0.0",
    },
    {
      capabilities: {
        elicitation: { form: {} },
      },
      versionNegotiation: {
        mode: { pin: "2026-07-28" },
        probe: { timeoutMs: 10_000, maxRetries: 0 },
      },
    }
  );

  client.setRequestHandler("elicitation/create", async (request) => {
    results.elicitation_message = request.params.message;
    return {
      action: "accept",
      content: { name: "TypeScript Client" },
    };
  });

  await client.connect(transport, { timeout: 30_000 });
  results.connected = true;
  results.negotiated_version = client.getNegotiatedProtocolVersion();
  results.protocol_era = client.getProtocolEra();
  results.server_info = client.getServerVersion();
  results.discovery = client.getDiscoverResult();

  const toolsResult = await client.listTools(undefined, requestOptions);
  results.tools = toolsResult.tools.map((tool) => tool.name);
  results.tools_meta = toolsResult._meta;
  results.tools_cache = {
    ttl_ms: toolsResult.ttlMs,
    cache_scope: toolsResult.cacheScope,
  };

  const echoResult = await client.callTool(
    {
      name: "echo",
      arguments: { message: "hello from TypeScript v2" },
    },
    requestOptions
  );
  results.echo = textFromResult(echoResult);
  results.echo_meta = echoResult._meta;

  const addResult = await client.callTool(
    {
      name: "add",
      arguments: { a: 10, b: 20 },
    },
    requestOptions
  );
  results.add = textFromResult(addResult);

  const contextResult = await client.callTool(
    { name: "inspect_context", arguments: {} },
    requestOptions
  );
  results.request_context = JSON.parse(textFromResult(contextResult));

  const onboardResult = await client.callTool(
    { name: "onboard", arguments: {} },
    requestOptions
  );
  results.onboard = textFromResult(onboardResult);

  const resourcesResult = await client.listResources(undefined, requestOptions);
  results.resources = resourcesResult.resources.map((resource) => resource.uri);

  const resourceResult = await client.readResource(
    { uri: "test://greeting" },
    requestOptions
  );
  results.resource_text = (resourceResult.contents ?? [])
    .map((content) => content.text ?? "")
    .join(" ");

  const promptsResult = await client.listPrompts(undefined, requestOptions);
  results.prompts = promptsResult.prompts.map((prompt) => prompt.name);

  const promptResult = await client.getPrompt(
    { name: "simple_prompt", arguments: {} },
    requestOptions
  );
  results.prompt_roles = promptResult.messages.map((message) => message.role);

  let resolveToolsChanged;
  const toolsChanged = new Promise((resolve) => {
    resolveToolsChanged = resolve;
  });

  client.setNotificationHandler(
    "notifications/tools/list_changed",
    async (notification) => {
      results.tools_changed_meta = notification.params?._meta;
      resolveToolsChanged();
    }
  );

  const subscription = await client.listen(
    { toolsListChanged: true },
    requestOptions
  );
  results.subscription_filter = subscription.honoredFilter;

  await client.callTool(
    { name: "publish_tools_changed", arguments: {} },
    requestOptions
  );
  await waitFor(toolsChanged, 10_000, "tools/list_changed");
  await subscription.close();
  results.subscription_closed = true;

  const rediscovery = await client.discover(requestOptions);
  results.rediscovered_versions = rediscovery.supportedVersions;
  results.success = true;
} catch (error) {
  results.error = error instanceof Error ? error.message : String(error);
  results.success = false;
} finally {
  if (client) {
    try {
      await client.close();
    } catch (error) {
      results.close_error = error instanceof Error ? error.message : String(error);
      results.success = false;
    }
  }
}

process.stderr.write(`${JSON.stringify(results)}\n`);
process.exit(results.success ? 0 : 1);
