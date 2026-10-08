// MCP 2026-07-28 TypeScript SDK v2 client for Arbor.MCP HTTP interop tests.
import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";

const endpoint = process.argv[2];

if (!endpoint) {
  process.stderr.write(
    `${JSON.stringify({ error: "Usage: node modern_ts_http_client.mjs <url>" })}\n`
  );
  process.exit(1);
}

const results = { requests: [] };
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

const observingFetch = async (input, init) => {
  const request = new Request(input, init);
  let rpcMethod;
  let rpcName;
  let observationRequest = false;

  if (request.method === "POST") {
    try {
      const payload = JSON.parse(await request.clone().text());
      rpcMethod = payload.method;
      rpcName = payload.params?.name;
      observationRequest = Object.hasOwn(payload, "id");
    } catch (_) {
      // A malformed body belongs to the server; observations are best effort.
    }
  }

  const observation = {
    http_method: request.method,
    rpc_method: rpcMethod,
    rpc_name: rpcName,
    rpc_request: observationRequest,
    protocol_version: request.headers.get("mcp-protocol-version"),
    mcp_method: request.headers.get("mcp-method"),
    mcp_name: request.headers.get("mcp-name"),
    request_session_id: request.headers.get("mcp-session-id"),
  };

  const response = await fetch(request);
  observation.status = response.status;
  observation.content_type = response.headers.get("content-type");
  observation.response_session_id = response.headers.get("mcp-session-id");
  results.requests.push(observation);
  return response;
};

try {
  const transport = new StreamableHTTPClientTransport(new URL(endpoint), {
    fetch: observingFetch,
  });

  client = new Client(
    { name: "ts-modern-http-interop-client", version: "2.0.0" },
    {
      capabilities: { elicitation: { form: {} } },
      versionNegotiation: {
        mode: { pin: "2026-07-28" },
        probe: { timeoutMs: 10_000, maxRetries: 0 },
      },
    }
  );

  client.setRequestHandler("elicitation/create", async () => ({
    action: "accept",
    content: { name: "TypeScript HTTP Client" },
  }));

  await client.connect(transport, { timeout: 30_000 });
  results.connected = true;
  results.negotiated_version = client.getNegotiatedProtocolVersion();
  results.protocol_era = client.getProtocolEra();
  results.server_info = client.getServerVersion();
  results.transport_session_id = transport.sessionId;

  const toolsResult = await client.listTools(undefined, requestOptions);
  results.tools = toolsResult.tools.map((tool) => tool.name);

  const echoResult = await client.callTool(
    {
      name: "echo",
      arguments: { message: "hello over modern HTTP" },
    },
    requestOptions
  );
  results.echo = textFromResult(echoResult);

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
  await waitFor(toolsChanged, 10_000, "HTTP tools/list_changed");
  await subscription.close();
  results.subscription_closed = true;

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
