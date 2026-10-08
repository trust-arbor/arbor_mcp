defmodule Mix.Tasks.Mcp.SyncSpec do
  @moduledoc """
  Syncs MCP specification documentation from the upstream GitHub repository.

  Downloads schema files and specification documentation from
  `modelcontextprotocol/modelcontextprotocol` and stores them locally
  in `docs/mcp-specs/`.

  ## Usage

      mix mcp.sync_spec [options]

  ## Options

    * `--version VERSION` - Sync only a specific version (e.g., `2025-11-25`)
    * `--force` - Re-download all files even if unchanged
    * `--dry-run` - Show what would be fetched without downloading
    * `--schema-only` - Only sync schema files (schema.ts, schema.json)
    * `--docs-only` - Only sync documentation files
    * `--verbose` - Show detailed progress information

  ## Examples

      # Discover and sync all versions
      mix mcp.sync_spec

      # Preview what would be synced
      mix mcp.sync_spec --dry-run

      # Sync only the latest version
      mix mcp.sync_spec --version 2025-11-25

      # Force re-download everything
      mix mcp.sync_spec --force

      # Sync only schema files
      mix mcp.sync_spec --schema-only

  ## Authentication

  Set the `GITHUB_TOKEN` environment variable for higher API rate limits
  (5000/hr vs 60/hr unauthenticated).

      GITHUB_TOKEN=ghp_... mix mcp.sync_spec
  """

  use Mix.Task

  alias Arbor.MCP.SpecSync.{FileMapper, GitHubClient, Metadata}

  @shortdoc "Sync MCP specification docs from GitHub"

  @base_dir "docs/mcp-specs"

  @switches [
    version: :string,
    force: :boolean,
    dry_run: :boolean,
    schema_only: :boolean,
    docs_only: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    ensure_started()

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    opts =
      opts
      |> Keyword.put_new(:force, false)
      |> Keyword.put_new(:dry_run, false)
      |> Keyword.put_new(:schema_only, false)
      |> Keyword.put_new(:docs_only, false)
      |> Keyword.put_new(:verbose, false)

    info("MCP Specification Sync")
    info("======================\n")

    case discover_versions(opts) do
      {:ok, versions} ->
        versions = filter_versions(versions, opts)
        info("Found #{length(versions)} version(s): #{Enum.join(versions, ", ")}\n")

        metadata = Metadata.load(@base_dir)
        metadata = sync_versions(versions, metadata, opts)
        metadata = sync_shared_docs(metadata, opts)

        unless opts[:dry_run] do
          case Metadata.save(@base_dir, metadata) do
            :ok -> :ok
            {:error, reason} -> warn("Failed to save metadata: #{inspect(reason)}")
          end
        end

        info("\nSync complete.")

      {:error, reason} ->
        error("Failed to discover versions: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Ensure required OTP applications are started
  defp ensure_started do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:crypto)

    # Start an httpc profile
    :inets.start(:httpc, profile: :spec_sync)
  end

  defp discover_versions(opts) do
    info("Discovering versions...")
    GitHubClient.discover_versions(client_opts(opts))
  end

  defp filter_versions(versions, opts) do
    case opts[:version] do
      nil ->
        versions

      v ->
        if v in versions,
          do: [v],
          else:
            (
              warn("Version #{v} not found upstream")
              []
            )
    end
  end

  defp sync_versions(versions, metadata, opts) do
    Enum.reduce(versions, metadata, fn version, acc ->
      sync_version(version, acc, opts)
    end)
  end

  defp sync_version(version, metadata, opts) do
    info("--- Version: #{version} ---")

    files = files_to_sync(version, opts)
    verbose(opts, "  Files to check: #{length(files)}")

    {metadata, stats} =
      Enum.reduce(
        files,
        {metadata, %{new: 0, updated: 0, unchanged: 0, errors: 0, skipped: 0}},
        fn
          github_path, {meta, stats} ->
            sync_file(github_path, version, meta, stats, opts)
        end
      )

    print_stats(stats)
    metadata
  end

  defp files_to_sync(version, opts) do
    schema_files =
      if opts[:docs_only],
        do: [],
        else: FileMapper.schema_files_for_version(version)

    doc_files =
      if opts[:schema_only],
        do: [],
        else: discover_doc_files(version, opts)

    schema_files ++ doc_files
  end

  defp discover_doc_files(version, opts) do
    directory = "docs/specification/#{version}"

    case GitHubClient.list_directory(directory, client_opts(opts)) do
      {:ok, paths} ->
        Enum.filter(paths, &FileMapper.mdx_file?/1)

      {:error, reason} ->
        warn(
          "Could not enumerate #{version} documentation (#{inspect(reason)}); " <>
            "using the known-file fallback"
        )

        FileMapper.doc_files_for_version(version)
    end
  end

  # Tutorial docs that live outside specification/VERSION/ (e.g. Security Best Practices).
  defp sync_shared_docs(metadata, opts) do
    if opts[:schema_only] do
      metadata
    else
      info("--- Shared tutorials ---")
      files = FileMapper.shared_doc_files()
      verbose(opts, "  Files to check: #{length(files)}")

      {metadata, stats} =
        Enum.reduce(
          files,
          {metadata, %{new: 0, updated: 0, unchanged: 0, errors: 0, skipped: 0}},
          fn github_path, {meta, stats} ->
            sync_file(github_path, "shared", meta, stats, opts)
          end
        )

      print_stats(stats)
      metadata
    end
  end

  defp sync_file(github_path, _version, metadata, stats, opts) do
    local_rel = FileMapper.github_to_local(github_path)

    if opts[:dry_run] do
      local_path = Path.join(@base_dir, local_rel)
      exists = File.exists?(local_path)
      label = if exists, do: "check", else: "new"
      info("  [#{label}] #{local_rel}")
      {metadata, Map.update!(stats, :skipped, &(&1 + 1))}
    else
      fetch_and_save(github_path, local_rel, metadata, stats, opts)
    end
  end

  defp fetch_and_save(github_path, local_rel, metadata, stats, opts) do
    etag =
      if opts[:force],
        do: nil,
        else: Metadata.get_etag(metadata, local_rel)

    fetch_opts = client_opts(opts) ++ [etag: etag]

    case GitHubClient.fetch_raw_file(github_path, fetch_opts) do
      {:ok, {content, resp_headers}} ->
        content =
          if FileMapper.mdx_file?(github_path),
            do: FileMapper.process_mdx_content(content),
            else: content

        if opts[:force] or Metadata.file_changed?(metadata, local_rel, content) do
          save_file(local_rel, content, github_path, resp_headers, metadata, stats, opts)
        else
          verbose(opts, "  [unchanged] #{local_rel}")
          {metadata, Map.update!(stats, :unchanged, &(&1 + 1))}
        end

      {:ok, :not_modified} ->
        verbose(opts, "  [unchanged] #{local_rel} (ETag match)")
        {metadata, Map.update!(stats, :unchanged, &(&1 + 1))}

      {:ok, :not_found} ->
        verbose(opts, "  [skipped] #{local_rel} (not found upstream)")
        {metadata, Map.update!(stats, :skipped, &(&1 + 1))}

      {:error, reason} ->
        warn("  [error] #{local_rel}: #{inspect(reason)}")
        {metadata, Map.update!(stats, :errors, &(&1 + 1))}
    end
  end

  defp save_file(local_rel, content, github_path, resp_headers, metadata, stats, opts) do
    local_path = Path.join(@base_dir, local_rel)
    exists = File.exists?(local_path)

    File.mkdir_p!(Path.dirname(local_path))
    File.write!(local_path, content)

    label = if exists, do: "updated", else: "new"
    stat_key = if exists, do: :updated, else: :new
    info("  #{colorize(label)} #{local_rel}")

    new_etag = GitHubClient.get_etag(resp_headers)

    raw_url =
      "https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/#{github_path}"

    metadata =
      Metadata.update_file(metadata, local_rel, content,
        etag: new_etag,
        source_url: raw_url
      )

    verbose(opts, "    SHA256: #{Metadata.sha256(content)}")
    {metadata, Map.update!(stats, stat_key, &(&1 + 1))}
  end

  defp print_stats(stats) do
    parts =
      [
        {stats.new, "new"},
        {stats.updated, "updated"},
        {stats.unchanged, "unchanged"},
        {stats.skipped, "skipped"},
        {stats.errors, "errors"}
      ]
      |> Enum.filter(fn {count, _} -> count > 0 end)
      |> Enum.map(fn {count, label} -> "#{count} #{label}" end)

    info("  Summary: #{Enum.join(parts, ", ")}\n")
  end

  defp client_opts(_opts) do
    # Pass through token if available
    case System.get_env("GITHUB_TOKEN") do
      nil -> []
      token -> [token: token]
    end
  end

  # Output helpers

  defp info(msg), do: Mix.shell().info(msg)

  defp warn(msg), do: Mix.shell().info("#{IO.ANSI.yellow()}warning: #{msg}#{IO.ANSI.reset()}")

  defp error(msg), do: Mix.shell().error("#{IO.ANSI.red()}error: #{msg}#{IO.ANSI.reset()}")

  defp verbose(opts, msg) do
    if opts[:verbose], do: info(msg)
  end

  defp colorize("new"), do: "#{IO.ANSI.green()}[new]#{IO.ANSI.reset()}"
  defp colorize("updated"), do: "#{IO.ANSI.cyan()}[updated]#{IO.ANSI.reset()}"
end
