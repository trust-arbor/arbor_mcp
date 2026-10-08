defmodule CombinedArchiveConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :combined_archive_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps(),
      releases: [combined_archive_consumer: [include_erts: true]]
    ]
  end

  def application do
    [extra_applications: [:logger, :arbor_rpc, :arbor_mcp, :arbor_acp, :arbor_acp_adapters]]
  end

  defp deps do
    packages =
      for app <- [:arbor_rpc, :arbor_mcp, :arbor_acp, :arbor_acp_adapters],
          do: {app, path: "packages/#{app}", override: true}

    # Local qualification can use independent external source copies. CI leaves
    # this unset to resolve the archives' external dependencies through Hex.
    external =
      case System.get_env("ARCHIVE_CONSUMER_EXTERNAL_DEPS") do
        nil ->
          []

        root ->
          for app <- [
                :jason,
                :telemetry,
                :mint,
                :mint_web_socket,
                :castore,
                :hpax,
                :plug,
                :plug_crypto,
                :mime,
                :ex_json_schema,
                :jsv,
                :abnf_parsec,
                :idna,
                :texture,
                :decimal,
                :jose
              ],
              do: {app, path: Path.join(root, to_string(app)), override: true}
      end

    packages ++ external
  end
end
