import Config

config :phoenix, :json_library, Jason
config :logger, level: :warning

for endpoint <- [McpAppsHostWeb.Endpoint, McpAppsHostWeb.SandboxEndpoint] do
  config :mcp_apps_host, endpoint,
    adapter: Bandit.PhoenixAdapter,
    pubsub_server: McpAppsHost.PubSub,
    live_view: [signing_salt: "local-apps-view"],
    check_origin: {McpAppsHostWeb.Origins, :allowed?, []},
    render_errors: [formats: [html: McpAppsHostWeb.Errors], layout: false],
    code_reloader: false,
    debug_errors: false,
    server: true
end
