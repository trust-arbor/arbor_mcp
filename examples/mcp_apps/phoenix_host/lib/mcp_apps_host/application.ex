defmodule McpAppsHost.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ok = McpAppsHost.Connection.validate_url(Application.fetch_env!(:mcp_apps_host, :server_url))

    Supervisor.start_link(
      [
        {Phoenix.PubSub, name: McpAppsHost.PubSub},
        McpAppsHostWeb.Endpoint,
        McpAppsHostWeb.SandboxEndpoint
      ],
      strategy: :one_for_one,
      name: McpAppsHost.Supervisor
    )
  end
end
