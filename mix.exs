defmodule Arbor.MCP.MixProject do
  use Mix.Project

  @version "2.0.0-dev"
  @github_url "https://github.com/trust-arbor/arbor_mcp"

  def project do
    [
      app: :arbor_mcp,
      version: @version,
      elixir: "~> 1.17",
      build_path: System.get_env("ARBOR_V2_BUILD") || "_build",
      lockfile: System.get_env("ARBOR_V2_LOCK") || "mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r"^test/conformance/(client|server)\.exs$"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @github_url,
      homepage_url: @github_url,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :credo],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: false,
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],
      # Cowlib advisory state as of 2026-09-16. EEF-CVE-2026-43971 (cow_link)
      # is fixed in Cowlib 2.20.0 and the advisory now records that, so its
      # exception is gone. The two below have NO upstream fix: the Cowlib
      # maintainer closed every PR that validated cow_cookie:cookie/1 and
      # cow_http_struct_hd:escape_string/2 as "won't fix" (ninenines/cowlib
      # #152, #166, #169), on the position that those encoders expect
      # RFC-valid input and Cowboy/Gun reject CR/LF at their own layer. The
      # advisory metadata is therefore correct and no Cowlib release will
      # clear it. These exceptions cover the optional Cowboy stack in this
      # repository's development/test dependency set,
      # backed by: Plug/Cowboy response-header validation; Arbor.MCP does not
      # call cow_cookie:cookie/1; and the Arbor.MCP/Plug/Cowboy server stack does
      # not call cow_link:link/1. Those assumptions are locked by
      # dependency_advisory_mitigation_test.exs. Core consumers omit Cowboy and
      # Cowlib; standalone hosts explicitly select Cowboy or Bandit. Keep the
      # exceptions exact so `mix hex.audit` still fails on every new advisory.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969"
        ]
      ],
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      # Quick entry points for examples (see examples/README.md).
      # Individual .exs files do Mix.install and can be slow on first run.
      examples: [
        "run -e 'IO.puts(\"Arbor.MCP Examples — see examples/README.md\") ; IO.puts(\"Quick starts: elixir examples/utilities/*.exs or examples/getting_started/demo_client.exs\") ; IO.puts(\"Full demo: cd examples/getting_started && ./run_demo.sh\") ; IO.puts(\"Fast alias: mix examples.getting_started\")'"
      ],
      # Fast (no re-Mix.install) version of the getting-started patterns.
      # See examples/getting_started/README.md and the main examples/README.md.
      "examples.getting_started": ["run -r examples/support/getting_started.exs"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Arbor.MCP.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      rpc_dep(),
      external_dep(:jason, "~> 1.4"),
      # Security floor: 1.10.2 fixes EEF-CVE-2026-94194 (HTTP/1 transfer
      # coding), EEF-CVE-2026-91043 (HTTP/2 header bounds), and
      # EEF-CVE-2026-92103 (HTTP/2 frame bounds), and includes the earlier
      # EEF-CVE-2026-82672 chunk-size fix from 1.10.1.
      external_dep(:mint, "~> 1.10 and >= 1.10.2"),
      external_dep(:mint_web_socket, "~> 1.0"),
      external_dep(:castore, "~> 1.0"),
      external_dep(:telemetry, "~> 1.2"),
      external_dep(:ex_doc, "~> 0.40", only: :dev, runtime: false),
      external_dep(:credo, "~> 1.7", only: [:dev, :test], runtime: false),
      external_dep(:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false),
      external_dep(:sobelow, "~> 0.13", only: [:dev, :test], runtime: false),
      external_dep(:excoveralls, "~> 0.18", only: :test),
      external_dep(:git_hooks, "~> 0.7", only: [:dev], runtime: false),
      external_dep(:plug_cowboy, "~> 2.7", optional: true),
      # Keep the listener opt-in, and exclude Bandit releases before the
      # HTTP/2 header validation and flow-control fixes in 1.12.5.
      external_dep(:bandit, "~> 1.12 and >= 1.12.5", optional: true),
      # Not used directly; declared so consumers resolve a cowlib that fixes
      # EEF-CVE-2026-43971 (Link header directive smuggling in cow_link),
      # which plug_cowboy's own requirements still allow.
      external_dep(:cowlib, "~> 2.20", optional: true),
      external_dep(:plug, "~> 1.16"),
      external_dep(:fuse, "~> 2.4", optional: true),
      # MCP protocol support
      external_dep(:ex_json_schema, "~> 0.10"),
      external_dep(:jsv, "~> 0.25.0"),
      external_dep(:html_entities, "~> 0.5", only: [:dev, :test]),
      external_dep(:propcheck, "~> 1.4", only: :test),
      external_dep(:benchee, "~> 1.0", only: [:dev, :test]),
      external_dep(:bypass, "~> 2.0", only: :test),
      external_dep(:jose, "~> 1.11")
    ]
  end

  # Published packages resolve Arbor.RPC from Hex. Local cutover testing opts in
  # to a checkout explicitly; no repository-relative staging path ships.
  defp rpc_dep do
    case System.get_env("ARBOR_RPC_PATH") do
      nil -> {:arbor_rpc, "~> 2.0"}
      path -> {:arbor_rpc, path: Path.expand(path), override: true}
    end
  end

  # Reuse an existing dependency source cache during isolated split QA.
  # Keep the declared versions and options when the override is absent.
  defp external_dep(app, version, opts \\ []) do
    case System.get_env("ARBOR_V2_DEPS") do
      nil ->
        {app, version, opts}

      path ->
        {app, version,
         Keyword.merge(opts,
           path: Path.join(Path.expand(path), Atom.to_string(app)),
           override: true
         )}
    end
  end

  defp description do
    """
    Elixir MCP clients and servers with tools, resources and prompts over stdio, HTTP and BEAM, with supervised per-server runtimes.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @github_url,
        "Changelog" => "#{@github_url}/blob/master/CHANGELOG.md",
        "MCP Spec" => "https://modelcontextprotocol.io",
        "MCP Migration" =>
          "https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_RELEASE_PLAN.md"
      },
      # NOTE: `dev/` (repo-only mix tasks + Arbor.MCP.SpecSync) is intentionally
      # not listed, so it never ships to Hex.
      files: ~w(
          lib
          .formatter.exs
          mix.exs
          README.md
          LICENSE
          CHANGELOG.md
          docs/ACP_GUIDE.md
          docs/ARCHITECTURE.md
          docs/CONFIGURATION.md
          docs/HTTP_LISTENERS.md
          docs/DEVELOPMENT.md
          docs/DSL_GUIDE.md
          docs/PROTOCOL_GUIDE.md
          docs/SECURITY.md
          docs/TRANSPORT_GUIDE.md
          docs/TROUBLESHOOTING.md
          docs/getting-started
          docs/guides
        )
    ]
  end

  # Specifies which paths to compile per environment.
  #
  # `dev/` holds repo-only tooling (the `mix test.suite` / `mix mcp.sync_spec`
  # family and `Arbor.MCP.SpecSync.*`). It is compiled for local development and
  # tests but is deliberately absent from `package.files`, so it never reaches
  # consumers' `mix help` (audit L1). `Arbor.MCP.Testing.*` stays under `lib/` as a
  # documented, published test kit.
  defp elixirc_paths(:test),
    do: [
      "lib",
      "dev",
      "test/support",
      "test/arbor_mcp/compliance",
      "test/arbor_mcp/compliance/features",
      "test/arbor_mcp/compliance/handlers"
    ]

  defp elixirc_paths(:dev), do: ["lib", "dev"]

  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      name: "Arbor.MCP",
      canonical: "https://hexdocs.pm/arbor_mcp",
      warnings_as_errors: true,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      extras: [
        "README.md",
        "docs/guides/USER_GUIDE.md",
        "docs/guides/PHOENIX_GUIDE.md",
        "docs/DSL_GUIDE.md",
        "docs/V2_SCHEMA_DIALECT.md",
        "docs/V2_CLIENT_CONNECTION_SCOPE.md",
        "docs/V2_STDIO_OUTPUT_LIABILITY.md",
        "docs/TRANSPORT_GUIDE.md",
        "docs/CONFIGURATION.md",
        "docs/HTTP_LISTENERS.md",
        "docs/PROTOCOL_GUIDE.md",
        "docs/getting-started/MIGRATION.md",
        "docs/SECURITY.md",
        "docs/ARCHITECTURE.md",
        "docs/DEVELOPMENT.md",
        "docs/TROUBLESHOOTING.md",
        "CHANGELOG.md"
      ],
      extra_section: "GUIDES",
      source_ref: "v#{@version}",
      groups_for_extras: [
        Introduction: ~r/README/,
        Guides:
          ~r/USER_GUIDE|PHOENIX_GUIDE|DSL_GUIDE|V2_SCHEMA_DIALECT|V2_CLIENT_CONNECTION_SCOPE|TRANSPORT_GUIDE|HTTP_LISTENERS|PROTOCOL_GUIDE|CONFIGURATION|getting-started\/MIGRATION|SECURITY|ARCHITECTURE|DEVELOPMENT|TROUBLESHOOTING/,
        Changelog: ~r/CHANGELOG/
      ],
      groups_for_modules: [
        "MCP Core": [
          Arbor.MCP,
          Arbor.MCP.Client,
          Arbor.MCP.Server,
          Arbor.MCP.Server.Handler,
          Arbor.MCP.Server.DSL,
          Arbor.MCP.Server.DSL.Result,
          Arbor.MCP.Server.Result,
          Arbor.MCP.Server.MRTR.InputRequired,
          Arbor.MCP.HttpPlug,
          Arbor.MCP.Types,
          Arbor.MCP.Content,
          Arbor.MCP.Error,
          Arbor.MCP.Response
        ],
        "MCP Transports": [
          Arbor.MCP.Transport,
          Arbor.MCP.Transport.Stdio,
          Arbor.MCP.Transport.HTTP,
          Arbor.MCP.Transport.SSEClient,
          Arbor.MCP.Transport.Local
        ],
        Authorization: [
          Arbor.MCP.Authorization
        ]
      ],
      filter_modules: fn mod, _ ->
        # Hide pure internals and repo-only tooling from the sidebar.
        # Deprecated Tools stay visible.
        name = inspect(mod)

        not String.starts_with?(name, "Arbor.MCP.Internal.") and
          not String.starts_with?(name, "Arbor.MCP.SpecSync.") and
          not String.starts_with?(name, "Mix.Tasks.") and
          not String.contains?(name, ".Test.")
      end,
      before_closing_body_tag: fn
        :html ->
          """
          <script>
            // Add copy button to code blocks
            document.addEventListener('DOMContentLoaded', function() {
              var blocks = document.querySelectorAll('pre code');
              blocks.forEach(function(block) {
                var button = document.createElement('button');
                button.className = 'copy-button';
                button.textContent = 'Copy';
                button.addEventListener('click', function() {
                  navigator.clipboard.writeText(block.textContent);
                  button.textContent = 'Copied!';
                  setTimeout(function() { button.textContent = 'Copy'; }, 2000);
                });
                block.parentNode.insertBefore(button, block);
              });
            });
          </script>
          <style>
            .copy-button {
              position: absolute;
              top: 5px;
              right: 5px;
              padding: 2px 8px;
              font-size: 12px;
              background: #f0f0f0;
              border: 1px solid #ccc;
              border-radius: 3px;
              cursor: pointer;
            }
            pre { position: relative; }
          </style>
          """

        _ ->
          ""
      end
    ]
  end
end
