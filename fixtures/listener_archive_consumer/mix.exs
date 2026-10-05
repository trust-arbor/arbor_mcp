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
    # Activate the qualified backend constraints in the host graph: optional
    # transitive requirements alone do not constrain the root Hex resolution.
    listener =
      case System.fetch_env!("LISTENER_ARCHIVE_ADAPTER") do
        "cowboy" -> [{:plug_cowboy, "~> 2.7"}, {:ranch, "== 1.8.1"}]
        "bandit" -> [{:bandit, "== 1.12.5"}, {:thousand_island, "== 1.5.0"}]
      end

    [
      {:arbor_rpc, path: "packages/arbor_rpc", override: true},
      {:arbor_mcp, path: "packages/arbor_mcp", override: true}
    ] ++ listener
  end
end
