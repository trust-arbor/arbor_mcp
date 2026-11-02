defmodule McpAppsHostWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mcp_apps_host

  @session_options [
    store: :cookie,
    key: "_local_mcp_apps_host",
    signing_salt: "local-host-session",
    same_site: "Strict",
    http_only: true
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 131_072],
    longpoll: false

  plug McpAppsHostWeb.Loopback
  plug Plug.Static, at: "/", from: :mcp_apps_host, only: ~w(assets)
  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded], pass: [], length: 65_536
  plug Plug.Session, @session_options
  plug McpAppsHostWeb.Router
end

defmodule McpAppsHostWeb.SandboxEndpoint do
  use Phoenix.Endpoint, otp_app: :mcp_apps_host
  plug McpAppsHostWeb.Loopback
  plug McpAppsHostWeb.Sandbox
end
