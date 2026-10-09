defmodule Arbor.MCP.DocRegressionTest do
  @moduledoc """
  Regression tests for documentation shapes.

  These ensure that the example code in guides, README, and moduledocs
  remains valid as the library evolves. They exercise the exact callback
  signatures and return shapes that we document for new users.
  """

  use ExUnit.Case, async: true

  # This test would have caught the pre-audit 1-arg list_* and incomplete
  # initialize shapes in PHOENIX_GUIDE, USER_GUIDE, lib/arbor_mcp.ex, etc.
  test "documented raw Handler callback shapes work (2-arity lists, full initialize, proper returns)" do
    defmodule DocRegressionRawHandler do
      use Arbor.MCP.Server.Handler

      @impl true
      def init(_args), do: {:ok, %{}}

      @impl true
      def handle_initialize(_params, state) do
        {:ok,
         %{
           protocolVersion: Arbor.MCP.protocol_version(),
           serverInfo: %{name: "doc-regression", version: "1.0.0"},
           capabilities: %{tools: %{}, resources: %{}}
         }, state}
      end

      @impl true
      def handle_list_tools(_cursor, state) do
        tools = [
          %{
            name: "echo",
            description: "Echo input",
            inputSchema: %{type: "object", properties: %{}}
          }
        ]

        {:ok, tools, nil, state}
      end

      @impl true
      def handle_call_tool("echo", args, state) do
        msg = Map.get(args, "message", "hello")
        {:ok, %{content: [%{type: "text", text: "echo: #{msg}"}]}, state}
      end

      # Minimal implementations for other callbacks used in docs
      @impl true
      def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_read_resource(uri, state),
        do: {:ok, %{uri: uri, text: "ok"}, state}

      @impl true
      def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_get_prompt(_name, _args, state),
        do: {:ok, %{messages: []}, state}
    end

    {:ok, server} =
      Arbor.MCP.Server.HandlerServer.start_link(
        handler: DocRegressionRawHandler,
        transport: :test
      )

    {:ok, client} = Arbor.MCP.Client.start_link(transport: :test, server: server)

    assert {:ok, %{"tools" => tools}} = Arbor.MCP.Client.list_tools(client, format: :map)
    assert Enum.any?(tools, &(&1["name"] == "echo" || &1[:name] == "echo"))

    assert {:ok, result} =
             Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "world"}, format: :map)

    assert result["content"] |> hd() |> Map.get("text") =~ "echo: world"

    # Also exercise a resource to cover documented shapes
    assert {:ok, _} = Arbor.MCP.Client.list_resources(client, format: :map)

    Arbor.MCP.Client.stop(client)
    GenServer.stop(server)
  end

  test "no 1-arity list_* callbacks or other known-bad patterns remain in live docs" do
    bad_patterns = [
      ~r/handle_list_tools\(state\)/,
      ~r/handle_list_resources\(state\)/,
      ~r/handle_list_prompts\(state\)/
    ]

    doc_files =
      Path.wildcard("docs/**/*.md") ++
        Path.wildcard("README.md") ++
        Path.wildcard("docs/getting-started/**/*.md")

    for file <- doc_files, pattern <- bad_patterns do
      content = File.read!(file)

      refute Regex.match?(pattern, content),
             "Found outdated 1-arity callback pattern in #{file} matching #{inspect(pattern)}"
    end
  end

  test "operator and contributor guides document every protocol mode" do
    for file <- ["docs/CONFIGURATION.md", "CLAUDE.md"] do
      content = File.read!(file)

      for mode <- ~w(legacy_only prefer_legacy prefer_modern modern_only) do
        assert content =~ "`:#{mode}`", "#{file} does not explain :#{mode}"
      end
    end
  end

  test "live docs identify the modern revision and current release state" do
    readme = File.read!("README.md")
    configuration = File.read!("docs/CONFIGURATION.md")
    quickstart = File.read!("docs/getting-started/QUICKSTART.md")
    coverage = File.read!("docs/MCP_COVERAGE_MATRIX.md")
    ex_mcp_source = File.read!("lib/arbor_mcp.ex")

    for {file, content} <- [
          {"README.md", readme},
          {"docs/CONFIGURATION.md", configuration},
          {"docs/getting-started/QUICKSTART.md", quickstart},
          {"docs/MCP_COVERAGE_MATRIX.md", coverage},
          {"lib/arbor_mcp.ex", ex_mcp_source}
        ] do
      assert content =~ "2026-07-28", "#{file} does not name the latest MCP revision"

      assert String.downcase(content) =~ "latest stable",
             "#{file} does not identify the latest MCP status"
    end

    refute readme =~ "**2025-11-25** (latest stable)"
    assert readme =~ "**Version 2 release candidate.**"
    refute readme =~ "replacement is not published yet"
    assert readme =~ "`arbor_mcp` 2.0 has not been released"
    assert readme =~ "`ex_mcp`"
    assert readme =~ "protocol_mode: :prefer_modern"
    refute readme =~ "Arbor.MCP.ACP"
    assert configuration =~ "defaults to `:prefer_modern`"
    assert quickstart =~ "`:prefer_modern`"
    assert coverage =~ "defaults to `:prefer_modern`"
    assert configuration =~ "newest legacy revision"
    assert coverage =~ "official conformance runner is\nstill published as a prerelease"
  end

  test "architecture and transport guides preserve the modern wire invariants" do
    architecture = File.read!("docs/ARCHITECTURE.md")
    transport = File.read!("docs/TRANSPORT_GUIDE.md")

    for term <- [
          "Protocol Era Model",
          "Arbor.MCP.Client.EraProbe",
          "Arbor.MCP.Client.EraCache",
          "Arbor.MCP.Server.RequestContext",
          "Arbor.MCP.Protocol.ResultEnvelope"
        ] do
      assert architecture =~ term, "architecture guide is missing #{inspect(term)}"
    end

    refute architecture =~ "**Not implemented** — post-1.0"

    for term <- [
          "Modern POST shape",
          "MCP-Protocol-Version",
          "Mcp-Method",
          "Mcp-Name",
          "Mcp-Param-*",
          "subscriptions/listen",
          "resultType",
          "405 Method Not Allowed"
        ] do
      assert transport =~ term, "transport guide is missing #{inspect(term)}"
    end
  end

  test "public HTTP docs do not present legacy sessions as modern behavior" do
    http_transport = File.read!("lib/arbor_mcp/transport/http.ex")
    session_manager = File.read!("lib/arbor_mcp/session_manager.ex")
    negotiator = File.read!("lib/arbor_mcp/protocol/version_negotiator.ex")

    for term <- [
          "both supported MCP wire eras",
          "Modern requests always use a fresh POST",
          "Legacy session compatibility",
          "does not depend on `:use_sse`"
        ] do
      assert http_transport =~ term, "HTTP transport moduledoc is missing #{inspect(term)}"
    end

    assert session_manager =~ "MCP 2026-07-28 HTTP is stateless"
    assert negotiator =~ "newest\n  legacy revision rather than the latest upstream"
  end

  test "troubleshooting and release docs cover modern migration failures and gates" do
    troubleshooting = File.read!("docs/TROUBLESHOOTING.md")
    development = File.read!("docs/DEVELOPMENT.md")
    mixfile = File.read!("mix.exs")

    for term <- [
          "server/discover",
          "Error `-32022`",
          "Error `-32020`",
          "io.modelcontextprotocol/clientCapabilities",
          "Result is rejected for missing `resultType`, `ttlMs`, or `cacheScope`",
          "GET or DELETE returns 405"
        ] do
      assert troubleshooting =~ term, "troubleshooting guide is missing #{inspect(term)}"
    end

    migration = File.read!("docs/getting-started/MIGRATION.md")
    assert migration =~ "[troubleshooting guide](../TROUBLESHOOTING.md)"
    refute migration =~ "](TROUBLESHOOTING.md)"

    for term <- [
          "./scripts/conformance.sh modern",
          "MCP_COVERAGE_MATRIX.md"
        ] do
      assert development =~ term, "development guide is missing #{inspect(term)}"
    end

    for packaged_guide <- [
          "docs/ARCHITECTURE.md",
          "docs/CONFIGURATION.md",
          "docs/DEVELOPMENT.md",
          "docs/DSL_GUIDE.md",
          "docs/SECURITY.md",
          "docs/TRANSPORT_GUIDE.md",
          "docs/TROUBLESHOOTING.md"
        ] do
      assert mixfile =~ packaged_guide, "Hex package/ExDoc config is missing #{packaged_guide}"
    end
  end

  test "public relative Markdown links resolve" do
    files =
      ["README.md", "CHANGELOG.md"] ++
        (Path.wildcard("docs/**/*.md")
         |> Enum.reject(&String.starts_with?(&1, "docs/mcp-specs/")))

    for file <- files,
        [target] <-
          Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, File.read!(file), capture: :all_but_first),
        target = target |> String.split(~r/\s+"/, parts: 2) |> hd() |> String.trim("<>"),
        target != "",
        not String.starts_with?(target, ["#", "http://", "https://", "mailto:"]) do
      relative_path = target |> String.split("#", parts: 2) |> hd()
      resolved = Path.expand(relative_path, Path.dirname(file))

      assert File.exists?(resolved), "#{file} links to missing relative target #{target}"
    end
  end
end
