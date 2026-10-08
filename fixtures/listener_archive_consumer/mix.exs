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
    # Owned listeners use the exact qualified constructor versions. The host
    # regression mounts HttpPlug on a normally resolved Ranch 2.x listener.
    listener =
      case {System.fetch_env!("LISTENER_ARCHIVE_ADAPTER"),
            System.get_env("LISTENER_ARCHIVE_OWNERSHIP", "owned")} do
        {"cowboy", "owned"} -> [{:plug_cowboy, "~> 2.7"}, {:ranch, "== 1.8.1"}]
        {"bandit", "owned"} -> [{:bandit, "== 1.12.5"}, {:thousand_island, "== 1.5.0"}]
        {"cowboy", "host"} -> [{:plug_cowboy, "~> 2.7"}, {:ranch, "== 2.2.0"}]
      end

    [
      {:arbor_rpc, path: "packages/arbor_rpc", override: true},
      {:arbor_mcp, path: "packages/arbor_mcp", override: true}
    ] ++ listener
  end
end
