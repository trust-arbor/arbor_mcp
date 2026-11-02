import Config

host_port = String.to_integer(System.get_env("MCP_APPS_HOST_PORT", "4000"))
sandbox_port = String.to_integer(System.get_env("MCP_APPS_SANDBOX_PORT", "4001"))

for {endpoint, port} <- [
      {McpAppsHostWeb.Endpoint, host_port},
      {McpAppsHostWeb.SandboxEndpoint, sandbox_port}
    ] do
  config :mcp_apps_host, endpoint,
    url: [scheme: "http", host: "127.0.0.1", port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
end

config :mcp_apps_host,
  server_url: System.get_env("MCP_APPS_SERVER_URL", "http://127.0.0.1:8080/mcp")
