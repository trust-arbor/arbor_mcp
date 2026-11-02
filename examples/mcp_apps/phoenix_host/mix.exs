defmodule McpAppsHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_apps_host,
      version: "0.1.0",
      elixir: "~> 1.17",
      test_ignore_filters: [~r"^test/browser_driver\.exs$"],
      deps: [
        {:arbor_mcp, path: "../../.."},
        {:phoenix, "== 1.8.15"},
        {:phoenix_live_view, "== 1.2.13"},
        {:bandit, "== 1.14.1"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application do
    [mod: {McpAppsHost.Application, []}, extra_applications: [:logger]]
  end
end
