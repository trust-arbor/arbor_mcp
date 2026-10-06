# Historical one-way extraction used before ACP/RPC became canonical repositories.
# Its original three-package layout is retained as reconciliation evidence; do
# not regenerate over the current ACP workspace or standalone ArborRPC checkout.
defmodule ArborV2.ExtractACP do
  @shared ~w(JSONRPC LineBuffer StdioFraming PortEnvironment LogSummary)
  @internal_files ~w(jsonrpc line_buffer stdio_framing port_environment log_summary)
  @support %{NameValue: "name_value", WorkspacePath: "workspace_path"}

  def run(source, destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)
    if source == destination, do: raise("destination must differ from source")
    unless File.exists?(Path.join(source, "lib/ex_mcp/acp.ex")), do: raise("missing ACP source")
    File.mkdir_p!(destination)
    packages = Path.join(destination, "packages")
    core = Path.join(packages, "arbor_acp")
    adapters = Path.join(packages, "arbor_acp_adapters")
    rpc = Path.join(packages, "arbor_rpc")

    # Remove only the original extraction's generated root layout. Preserve Git
    # history and new, independently implemented package files on repeat runs.
    for path <- ~w(lib dev test config scripts mix.exs mix.lock .formatter.exs) do
      File.rm_rf!(Path.join(destination, path))
    end

    for {dir, app, title, description, deps} <- [
          {rpc, :arbor_rpc, "Arbor.RPC",
           "Shared JSON-RPC, framing and environment mechanics for Arbor protocols.", []},
          {core, :arbor_acp, "Arbor.ACP",
           "Agent Client Protocol client, native agent and generic adapter runtime.",
           [:arbor_rpc]},
          {adapters, :arbor_acp_adapters, "Arbor.ACP.Adapters",
           "Optional Claude, Codex, Pi and ZCode adapters for Arbor.ACP.",
           [:arbor_acp, :arbor_rpc]}
        ] do
      write(Path.join(dir, "mix.exs"), project(app, title, description, deps))

      write(
        Path.join(dir, ".formatter.exs"),
        "[inputs: [\"{mix,.formatter}.exs\", \"{config,dev,lib,test}/**/*.{ex,exs}\"]]\n"
      )

      File.cp!(Path.join(source, "LICENSE"), mkdir_parent(Path.join(dir, "LICENSE")))

      write(
        Path.join(dir, "README.md"),
        "# #{title}\n\n#{description}\n\nVersion 2.0.0-dev is an unpublished implementation snapshot.\n"
      )

      write(
        Path.join(dir, "CHANGELOG.md"),
        "# Changelog\n\n## 2.0.0-dev\n\nInitial package extraction from ExMCP. Full v2 runtime qualification remains pending.\n"
      )

      write(Path.join(dir, "test/test_helper.exs"), test_helper(app))

      write(
        Path.join(dir, "config/config.exs"),
        "import Config\nconfig :logger, :console, metadata: :all\n"
      )
    end

    for {name, file} <- Enum.zip(@shared, @internal_files) do
      text = File.read!(Path.join(source, "lib/ex_mcp/internal/#{file}.ex"))

      text =
        text
        |> rewrite(:core)
        |> String.replace("@moduledoc false", "@moduledoc \"Shared #{name} mechanics.\"")

      rpc_path =
        if name == "LineBuffer",
          do: "lib/arbor_rpc/internal/#{file}.ex",
          else: "lib/arbor_rpc/#{file}.ex"

      write(Path.join(rpc, rpc_path), text)
      test = Path.join(source, "test/ex_mcp/internal/#{file}_test.exs")

      if File.exists?(test),
        do: copy(test, Path.join(rpc, "test/arbor_rpc/#{file}_test.exs"), :core)
    end

    for {name, file} <- @support do
      text = File.read!(Path.join(source, "lib/ex_mcp/internal/#{file}.ex")) |> rewrite(:core)

      text =
        String.replace(
          text,
          "@moduledoc false",
          "@moduledoc \"Documented adapter support for #{name}.\""
        )

      write(Path.join(core, "lib/arbor_acp/adapter_support/#{file}.ex"), text)
    end

    for file <- ~w(maps options stdio_logger_config) do
      copy(
        Path.join(source, "lib/ex_mcp/internal/#{file}.ex"),
        Path.join(core, "lib/arbor_acp/internal/#{file}.ex"),
        :core
      )
    end

    copy(Path.join(source, "lib/ex_mcp/acp.ex"), Path.join(core, "lib/arbor_acp.ex"), :core)

    for path <- Path.wildcard(Path.join(source, "lib/ex_mcp/acp/**/*.ex")) do
      relative = Path.relative_to(path, Path.join(source, "lib/ex_mcp/acp"))

      cond do
        String.starts_with?(relative, "adapters/") ->
          copy(path, Path.join(adapters, "lib/arbor_acp/#{relative}"), :adapters)

        relative == "prompt_queue.ex" ->
          copy(
            path,
            Path.join(adapters, "lib/arbor_acp/adapters/internal/prompt_queue.ex"),
            :adapters
          )

        relative == "adapter_bridge/port_runner.ex" ->
          text =
            File.read!(path)
            |> rewrite(:core)
            |> String.replace(
              "@moduledoc false",
              "@moduledoc \"Adapter subprocess support; shared subprocess convergence is pending.\""
            )

          write(Path.join(core, "lib/arbor_acp/adapter_support/subprocess.ex"), text)

        true ->
          copy(path, Path.join(core, "lib/arbor_acp/#{relative}"), :core)
      end
    end

    extract_environment_policy(core, adapters)

    # These tiny data construction helpers are adapter-owned, not RPC policy.
    maps = File.read!(Path.join(source, "lib/ex_mcp/acp/maps.ex")) |> rewrite(:adapters)

    maps =
      maps
      |> String.replace(
        ~r/  defdelegate put_present\([^\n]+/,
        "  def put_present(map, _key, nil), do: map\n  def put_present(map, key, value), do: Map.put(map, key, value)"
      )

    maps =
      maps
      |> String.replace(
        ~r/  defdelegate put_non_empty\([^\n]+/,
        "  def put_non_empty(map, _key, value) when value in [nil, \"\", []] or value == %{}, do: map\n  def put_non_empty(map, key, value), do: Map.put(map, key, value)"
      )

    maps =
      maps
      |> String.replace(
        ~r/  defdelegate put_unless\([^\n]+/,
        "  def put_unless(map, _key, value, value), do: map\n  def put_unless(map, key, value, _skip), do: Map.put(map, key, value)"
      )

    maps =
      String.replace_suffix(
        String.trim_trailing(maps),
        "end",
        "  def put_present_non_empty_list(map, key, value), do: put_non_empty(map, key, value)\nend\n"
      )

    write(Path.join(adapters, "lib/arbor_acp/adapters/internal/maps.ex"), maps)

    # The current main transport supplies fresh lifecycle/PATH fixes. ACP owns
    # its temporary mechanical wrapper; remove MCP-only validation/policy.
    stdio = File.read!(Path.join(source, "lib/ex_mcp/transport/stdio.ex")) |> rewrite(:core)
    stdio = String.replace(stdio, ~r/\s*alias Arbor\.ACP\.Internal\.SecurityConfig\n/, "\n")

    stdio =
      String.replace(stdio, ~r/\s*alias Arbor\.ACP\.Transport\.(?:Error|SecurityGuard)\n/, "\n")

    stdio =
      String.replace(
        stdio,
        "Error.connection_error({:spawn_failed, reason})",
        "{:error, {:connection_error, {:spawn_failed, reason}}}"
      )

    stdio =
      String.replace(
        stdio,
        "Error.connection_error({:process_exited, status})",
        "{:error, {:connection_error, {:process_exited, status}}}"
      )

    stdio =
      String.replace(stdio, "Error.connection_error(:eof)", "{:error, {:connection_error, :eof}}")

    stdio =
      String.replace(
        stdio,
        ~r/  defp do_send_message\(.*?(?=  @impl true\n  def receive_message)/s,
        acp_send()
      )

    stdio =
      String.replace(
        stdio,
        ~r/  @moduledoc """.*?"""/s,
        "  @moduledoc \"ACP stdio subprocess transport; shared subprocess convergence remains pending.\""
      )

    write(Path.join(core, "lib/arbor_acp/transport/stdio.ex"), stdio)

    copy(
      Path.join(source, "lib/ex_mcp/transport.ex"),
      Path.join(core, "lib/arbor_acp/transport.ex"),
      :core
    )

    transport = File.read!(Path.join(core, "lib/arbor_acp/transport.ex"))
    transport = String.replace(transport, ~r/  def get_transport\(:http\).*\n/, "")
    transport = String.replace(transport, ~r/  def get_transport\(:sse\).*\n/, "")
    transport = String.replace(transport, ~r/  def get_transport\(:test\).*\n/, "")
    transport = String.replace(transport, ~r/  def get_transport\(:beam\).*\n/, "")
    write(Path.join(core, "lib/arbor_acp/transport.ex"), transport)

    for path <- Path.wildcard(Path.join(source, "test/ex_mcp/acp/**/*.{ex,exs}")) do
      relative = Path.relative_to(path, Path.join(source, "test/ex_mcp/acp"))

      target =
        if String.starts_with?(relative, "adapters/") or relative == "prompt_queue_test.exs",
          do: adapters,
          else: core

      owner = if target == adapters, do: :adapters, else: :core
      copy(path, Path.join(target, "test/arbor_acp/#{relative}"), owner)
    end

    mixed = File.read!(Path.join(core, "test/arbor_acp/adapter_integration_test.exs"))

    [generic, vendor] =
      String.split(mixed, "  describe \"Codex adapter translate chain\" do", parts: 2)

    write(Path.join(core, "test/arbor_acp/adapter_integration_test.exs"), generic <> "end\n")

    write(
      Path.join(adapters, "test/arbor_acp/adapters/codex_translation_integration_test.exs"),
      "defmodule Arbor.ACP.Adapters.CodexTranslationIntegrationTest do\n  use ExUnit.Case, async: true\n  describe \"Codex adapter translate chain\" do" <>
        vendor
    )

    for path <- Path.wildcard(Path.join(source, "test/support/acp/**/*.ex")),
        do:
          copy(
            path,
            Path.join(
              adapters,
              "test/support/acp/#{Path.relative_to(path, Path.join(source, "test/support/acp"))}"
            ),
            :adapters
          )

    copy(
      Path.join(source, "test/support/i18n_corpus.ex"),
      Path.join(core, "test/support/i18n_corpus.ex"),
      :core
    )

    for path <- Path.wildcard(Path.join(source, "test/fixtures/acp/**/*")),
        File.regular?(path),
        do:
          copy(
            path,
            Path.join(
              adapters,
              "test/fixtures/acp/#{Path.relative_to(path, Path.join(source, "test/fixtures/acp"))}"
            ),
            :adapters
          )

    for path <- Path.wildcard(Path.join(source, "test/ex_mcp/integration/acp_*.exs")) do
      target =
        if String.ends_with?(path, "acp_adapter_cli_interop_test.exs"), do: adapters, else: core

      copy(
        path,
        Path.join(target, "test/arbor_acp/integration/#{Path.basename(path)}"),
        if(target == adapters, do: :adapters, else: :core)
      )
    end

    for path <- Path.wildcard(Path.join(source, "test/interop/acp_*")),
        File.regular?(path),
        do: copy(path, Path.join(core, "test/interop/#{Path.basename(path)}"), :core)

    write(
      Path.join(core, "test/interop/package.json"),
      ~s({"name":"arbor-acp-interop","private":true,"type":"module","dependencies":{"@agentclientprotocol/sdk":"1.4.0","zod":"4.4.3"}}\n)
    )

    lock = source |> Path.join("test/interop/package-lock.json") |> File.read!() |> :json.decode()

    packages =
      Map.take(lock["packages"], ["node_modules/@agentclientprotocol/sdk", "node_modules/zod"])

    deps = %{"@agentclientprotocol/sdk" => "1.4.0", "zod" => "4.4.3"}
    packages = Map.put(packages, "", %{"name" => "arbor-acp-interop", "dependencies" => deps})

    lock = %{
      "name" => "arbor-acp-interop",
      "lockfileVersion" => 3,
      "requires" => true,
      "packages" => packages
    }

    write(
      Path.join(core, "test/interop/package-lock.json"),
      IO.iodata_to_binary(:json.encode(lock)) <> "\n"
    )

    copy(
      Path.join(source, "dev/ex_mcp/acp_compat.ex"),
      Path.join(core, "dev/arbor_acp/compat.ex"),
      :core
    )

    for task <- ~w(acp.compat.check acp.everything_agent acp.interop_agent),
        do:
          copy(
            Path.join(source, "dev/mix/tasks/#{task}.ex"),
            Path.join(core, "dev/mix/tasks/#{task}.ex"),
            :core
          )

    # Additional package-owned support, regression tests, and ecosystem tooling.
    rpc_corpus =
      File.read!(Path.join(source, "test/support/i18n_corpus.ex"))
      |> rewrite(:core)
      |> String.replace("Arbor.ACP.Test.I18nCorpus", "Arbor.RPC.Test.I18nCorpus")

    write(Path.join(rpc, "test/support/i18n_corpus.ex"), rpc_corpus)
    rpc_test = Path.join(rpc, "test/arbor_rpc/stdio_framing_test.exs")

    write(
      rpc_test,
      File.read!(rpc_test)
      |> String.replace("Arbor.ACP.Test.I18nCorpus", "Arbor.RPC.Test.I18nCorpus")
    )

    helper_source = File.read!(Path.join(source, "test/support/test_helpers.ex"))
    [_, wait_until] = String.split(helper_source, "  @spec wait_until", parts: 2)
    [wait_until, _] = String.split(wait_until, "\n  @doc", parts: 2)

    write(
      Path.join(adapters, "test/support/test_helpers.ex"),
      "defmodule Arbor.ACP.TestHelpers do\n  @moduledoc false\n  @spec wait_until" <>
        wait_until <> "\nend\n"
    )

    interop = Path.join(core, "test/arbor_acp/integration/acp_interop_test.exs")

    text =
      File.read!(interop)
      |> String.replace(
        "{output, 0} = System.cmd(\"npm\", [\"install\"], cd: @interop_dir, stderr_to_stdout: true)\n      output",
        "raise \"Install the pinned ACP SDK in test/interop before running interop tests\""
      )

    write(interop, text)

    for path <- Path.wildcard(Path.join(source, "examples/acp/*")) do
      text = File.read!(path) |> rewrite(:core) |> String.replace("{:ex_mcp,", "{:arbor_acp,")
      write(Path.join(core, "examples/acp/#{Path.basename(path)}"), text)
    end

    File.cp!(Path.join(source, "mise.toml"), mkdir_parent(Path.join(destination, "mise.toml")))

    write(
      Path.join(destination, ".gitignore"),
      "**/_build/\n**/deps/\n**/doc/\n**/cover/\n**/node_modules/\n**/tmp/\n_verification/\n*.tar\nerl_crash.dump\n"
    )

    write(
      Path.join(destination, "README.md"),
      "# Arbor ACP workspace\n\nThree independent Mix projects: `packages/arbor_rpc`, `packages/arbor_acp`, and optional `packages/arbor_acp_adapters`.\n\nAll are unpublished 2.0.0-dev snapshots. Pure RPC mechanics are shared. Subprocess lifecycle and global stdio logging convergence remain v2 release gates.\n\nUse `ARBOR_V2_DEPS=/path/to/ex_mcp/deps ARBOR_V2_LOCAL=1` for offline local verification. Published manifests use version ranges when local overrides are absent.\n"
    )

    source_sha =
      case System.cmd("git", ["rev-parse", "HEAD"], cd: source) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end

    write(Path.join(destination, "SOURCE_SNAPSHOT"), source_sha <> "\n")
    IO.puts("Extracted Arbor ACP workspace from #{source_sha} into #{destination}")
  end

  defp rewrite(text, owner) do
    text =
      Regex.replace(~r/alias (ExMCP(?:\.[A-Za-z0-9_]+)+)\.\{([^}]+)\}/s, text, fn _,
                                                                                  prefix,
                                                                                  parts ->
        parts
        |> String.split(",")
        |> Enum.map_join("\n", &("alias " <> prefix <> "." <> String.trim(&1)))
      end)

    text =
      Enum.reduce(@shared, text, fn name, acc ->
        target =
          if name == "LineBuffer", do: "Arbor.RPC.Internal.LineBuffer", else: "Arbor.RPC.#{name}"

        String.replace(acc, "ExMCP.Internal.#{name}", target)
      end)

    text =
      Enum.reduce(@support, text, fn {name, _}, acc ->
        String.replace(acc, "ExMCP.Internal.#{name}", "Arbor.ACP.AdapterSupport.#{name}")
      end)

    text =
      text
      |> String.replace(
        "ExMCP.ACP.AdapterBridge.PortRunner",
        "Arbor.ACP.AdapterSupport.Subprocess"
      )
      |> String.replace("ExMCP.ACPCompat", "Arbor.ACP.Compat")
      |> String.replace("ExMCP.ACP", "Arbor.ACP")
      |> String.replace("ExMCP.Internal.", "Arbor.ACP.Internal.")
      |> String.replace("ExMCP.Transport", "Arbor.ACP.Transport")
      |> String.replace("ExMCP.Test.", "Arbor.ACP.Test.")
      |> String.replace("ExMCP.Integration.", "Arbor.ACP.Integration.")
      |> String.replace("[:ex_mcp, :acp, ", "[:arbor_acp, ")
      |> String.replace("[:ex_mcp, :transport, ", "[:arbor_acp, :transport, ")
      |> String.replace("Application.spec(:ex_mcp,", "Application.spec(:arbor_acp,")
      |> String.replace(
        "Application.ensure_all_started(:ex_mcp)",
        "Application.ensure_all_started(:arbor_acp)"
      )
      |> String.replace("Application.put_env(:ex_mcp,", "Application.put_env(:arbor_acp,")
      |> String.replace("Application.get_env(:ex_mcp,", "Application.get_env(:arbor_acp,")
      |> String.replace("Application.delete_env(:ex_mcp,", "Application.delete_env(:arbor_acp,")
      |> String.replace("Application.fetch_env(:ex_mcp,", "Application.fetch_env(:arbor_acp,")
      |> String.replace("ExMCP.start_acp_client", "Arbor.ACP.start_client")
      |> String.replace(
        "alias Arbor.ACP.AdapterSupport.Subprocess\n",
        "alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner\n"
      )
      |> String.replace("alias Arbor.ACP.Compat\n", "alias Arbor.ACP.Compat, as: ACPCompat\n")
      |> String.replace("ExMCP.TestHelpers", "Arbor.ACP.TestHelpers")

    if owner == :adapters do
      text
      |> String.replace("Arbor.ACP.Envelope", "Arbor.RPC.JSONRPC")
      |> String.replace("alias Arbor.RPC.JSONRPC\n", "alias Arbor.RPC.JSONRPC, as: Envelope\n")
      |> String.replace("Arbor.ACP.PromptQueue", "Arbor.ACP.Adapters.Internal.PromptQueue")
      |> String.replace("Arbor.ACP.Internal.Maps", "Arbor.ACP.Adapters.Internal.Maps")
      |> String.replace("Arbor.ACP.Maps", "Arbor.ACP.Adapters.Internal.Maps")
      |> String.replace(~r/alias Arbor\.ACP\.PendingRequests\s*\n/, "")
      |> String.replace("PendingRequests.put(", "Map.put(")
      |> String.replace("PendingRequests.pop(", "Map.pop(")
    else
      text
    end
  end

  defp extract_environment_policy(core, adapters) do
    path = Path.join(core, "lib/arbor_acp/adapter_support/subprocess.ex")
    text = File.read!(path)

    text =
      String.replace(
        text,
        ~r/  @session_vars_to_clear ~w\(.*?\)\n/s,
        "  @runtime_vars_to_clear ~w(MIX_ENV MIX_TARGET)\n"
      )

    text = String.replace(text, "@session_vars_to_clear", "@runtime_vars_to_clear")
    text = String.replace(text, "    |> maybe_put_api_key(Keyword.get(opts, :api_key))\n", "")
    text = String.replace(text, ~r/  defp maybe_put_api_key.*?(?=^end)/ms, "")

    text =
      String.replace(
        text,
        "    |> Map.merge(adapter_env(opts, adapter_mod))",
        "    |> Map.merge(adapter_environment_defaults(opts, adapter_mod))\n    |> Map.merge(adapter_env(opts, adapter_mod))"
      )

    defaults = """
      defp adapter_environment_defaults(opts, adapter_mod) do
        if function_exported?(adapter_mod, :environment_defaults, 1),
          do: adapter_mod.environment_defaults(opts) |> PortEnvironment.normalize(),
          else: %{}
      end

    """

    write(path, String.replace(text, "  defp adapter_env(", defaults <> "  defp adapter_env("))
    behaviour = Path.join(core, "lib/arbor_acp/adapter.ex")

    text =
      File.read!(behaviour)
      |> String.replace(
        "  @optional_callbacks [",
        "  @optional_callbacks [\n    environment_defaults: 1,"
      )

    text =
      String.replace(
        text,
        "  @callback env(opts :: keyword()) :: map() | keyword()",
        "  @callback env(opts :: keyword()) :: map() | keyword()\n\n  @doc \"Adapter-owned defaults applied before env/1 and caller :env; false unsets a variable.\"\n  @callback environment_defaults(opts :: keyword()) :: map() | list()"
      )

    write(behaviour, text)

    environment = """
    defmodule Arbor.ACP.Adapters.Internal.Environment do
      @moduledoc false
      alias Arbor.RPC.PortEnvironment
      @session_vars_to_clear ~w(
        CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDECODE
        CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY PI_API_KEY
      )
      def defaults(env \\\\ []) do
        @session_vars_to_clear |> Map.new(&{&1, false}) |> Map.merge(PortEnvironment.normalize(env))
      end
      def pi(opts) do
        case Keyword.get(opts, :api_key) do
          nil -> defaults()
          api_key -> Map.put(defaults(), "PI_API_KEY", to_string(api_key))
        end
      end
    end
    """

    write(Path.join(adapters, "lib/arbor_acp/adapters/internal/environment.ex"), environment)

    for name <- ~w(claude_sdk codex pi zcode) do
      path = Path.join(adapters, "lib/arbor_acp/adapters/#{name}.ex")
      argument = if name == "pi", do: "opts", else: "_opts"
      function = if name == "pi", do: "pi(opts)", else: "defaults()"

      callback =
        "  @impl true\n  def environment_defaults(#{argument}), do: Arbor.ACP.Adapters.Internal.Environment.#{function}\n\n"

      write(
        path,
        File.read!(path)
        |> String.replace(
          "  @impl true\n  def init(opts)",
          callback <> "  @impl true\n  def init(opts)"
        )
      )
    end
  end

  defp copy(source, target, owner) do
    text = File.read!(source) |> rewrite(owner)

    text =
      if String.ends_with?(source, "session_safety_golden_test.exs") do
        original = "defp load_steps(acp_id, session_id, file, opts " <> <<92, 92>> <> " []) do"
        String.replace(text, original, "defp load_steps(acp_id, session_id, file, opts) do")
      else
        text
      end

    write(target, text)
  end

  defp mkdir_parent(path) do
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp write(path, text), do: File.write!(mkdir_parent(path), text)

  defp project(app, title, description, internal_deps) do
    deps = Enum.map_join(internal_deps, ",\n", fn dep -> "      internal_dep(:#{dep})" end)
    deps = if deps == "", do: "", else: deps <> ","

    telemetry =
      if app == :arbor_rpc, do: "", else: ",\n          external_dep(:telemetry, \"~> 1.2\")"

    internal_function =
      if internal_deps == [] do
        ""
      else
        """
        defp internal_dep(app) do
          if System.get_env("ARBOR_V2_LOCAL") == "1",
            do: {app, path: Path.expand("../\#{app}", __DIR__)},
            else: {app, "~> 2.0.0-dev"}
        end
        """
      end

    """
    defmodule #{title}.MixProject do
      use Mix.Project
      @version "2.0.0-dev"
      def project do
        [app: :#{app}, version: @version, elixir: "~> 1.17", elixirc_paths: paths(Mix.env()),
         deps: deps(), description: #{inspect(description)},
         package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/trust-arbor/arbor_acp"},
                   files: ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md)],
         source_url: "https://github.com/trust-arbor/arbor_acp",
         docs: [name: #{inspect(title)}, main: "readme", extras: ["README.md", "CHANGELOG.md"]]]
      end
      def application, do: [extra_applications: #{inspect(case app do
      :arbor_acp -> [:logger, :crypto, :inets, :ssl]
      :arbor_rpc -> [:logger, :crypto]
      _ -> [:logger]
    end)}]
      defp paths(:test), do: ["lib", "dev", "test/support"]
      defp paths(:dev), do: ["lib", "dev"]
      defp paths(_), do: ["lib"]
      defp deps do
        [
    #{deps}
          external_dep(:jason, "~> 1.4")#{telemetry}
        ]
      end
      defp external_dep(app, version) do
        case System.get_env("ARBOR_V2_DEPS") do
          nil -> {app, version}
          directory -> {app, path: Path.join(directory, to_string(app)), override: true}
        end
      end
      #{internal_function}
    end
    """
  end

  defp test_helper(app) do
    """
    Logger.configure(level: :warning)
    #{if(app == :arbor_rpc, do: "", else: "{:ok, _} = Application.ensure_all_started(:telemetry)")}
    ExUnit.start(capture_log: true)
    ExUnit.configure(exclude: [integration: true, external: true, slow: true, interop: true, interop_acp: true, interop_acp_cli: true, interop_acp_ecosystem: true, wip: true, skip: true])
    """
  end

  defp acp_send do
    """
      defp do_send_message(message, port, state) do
        cond do
          String.contains?(message, ["\\n", "\\r"]) -> {:error, {:validation_error, :embedded_newline}}
          not match?({:ok, _}, Jason.decode(message)) -> {:error, {:validation_error, :invalid_json}}
          true ->
            :telemetry.execute([:arbor_acp, :transport, :message, :sent], %{size: byte_size(message)}, %{transport: :stdio})
            try do
              Port.command(port, message <> "\\n")
              {:ok, state}
            catch
              :error, reason -> {:error, {:transport_error, {:send_failed, reason}}}
            end
        end
      end

    """
  end
end

case System.argv() do
  [source, destination] -> ArborV2.ExtractACP.run(source, destination)
  _ -> raise "usage: elixir scripts/v2/extract_acp.exs SOURCE DESTINATION"
end
