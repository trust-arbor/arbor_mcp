defmodule McpAppsHostWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug McpAppsHostWeb.Headers
    plug :put_root_layout, html: {McpAppsHostWeb.Layouts, :root}
  end

  scope "/", McpAppsHostWeb do
    pipe_through :browser
    live "/", HostLive
  end
end
