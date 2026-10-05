defmodule ListenerArchiveConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :listener_archive_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps(),
      releases: [listener_archive_consumer: [include_erts: true]]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :arbor_rpc, :arbor_mcp]]
  end

  defp deps do
    # Only the two unpublished Arbor packages use extracted archive paths.
    # In particular, do not pin Ranch here: the MCP archive must constrain it.
    listener =
      case System.fetch_env!("LISTENER_ARCHIVE_ADAPTER") do
        "cowboy" -> {:plug_cowboy, "~> 2.7"}
        "bandit" -> {:bandit, "~> 1.12 and >= 1.12.5"}
      end

    [
      {:arbor_rpc, path: "packages/arbor_rpc", override: true},
      {:arbor_mcp, path: "packages/arbor_mcp", override: true},
      listener
    ]
  end
end
