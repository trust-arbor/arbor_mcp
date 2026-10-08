defmodule Arbor.MCP.SpecSync.FileMapper do
  @moduledoc """
  Maps GitHub paths to local paths for MCP specification files.

  Handles the conversion from the upstream repository structure
  (MDX files with JSX components) to clean local Markdown files.
  """

  # Directory name mappings from upstream to local
  @dir_mappings %{
    "basic" => "BaseProtocol",
    "server" => "ServerFeatures",
    "client" => "ClientFeatures",
    "utilities" => "Utilities",
    "architecture" => "Architecture"
  }

  # Special file name mappings
  @file_mappings %{
    "changelog.mdx" => "KeyChanges.md",
    "security_best_practices.mdx" => "SecurityBestPractices.md"
  }

  @doc """
  Maps a GitHub doc path to its local equivalent.

  ## Examples

      iex> FileMapper.github_to_local("docs/specification/2025-11-25/index.mdx")
      "2025-11-25/Specification.md"

      iex> FileMapper.github_to_local("docs/specification/2025-11-25/basic/lifecycle.mdx")
      "2025-11-25/BaseProtocol/Lifecycle.md"

      iex> FileMapper.github_to_local("schema/2025-11-25/schema.ts")
      "2025-11-25/schema.ts"
  """
  @spec github_to_local(String.t()) :: String.t()
  def github_to_local("schema/" <> rest) do
    # Schema files keep their names: schema/VERSION/schema.ts -> VERSION/schema.ts
    rest
  end

  def github_to_local("docs/specification/" <> rest) do
    parts = String.split(rest, "/")
    map_doc_path(parts)
  end

  # Non-versioned tutorial docs (moved out of specification/YYYY-MM-DD/basic/)
  def github_to_local("docs/docs/tutorials/security/security_best_practices.mdx"),
    do: "Tutorials/SecurityBestPractices.md"

  def github_to_local("docs/docs/tutorials/security/authorization.mdx"),
    do: "Tutorials/Authorization.md"

  def github_to_local(path), do: path

  @doc """
  Returns the list of schema file paths to fetch for a given version.
  """
  @spec schema_files_for_version(String.t()) :: [String.t()]
  def schema_files_for_version(version) do
    [
      "schema/#{version}/schema.ts",
      "schema/#{version}/schema.json"
    ]
  end

  @doc """
  Returns the list of known doc file paths to fetch for a given version.

  These are used as a fallback when the upstream tree cannot be enumerated.
  """
  @spec doc_files_for_version(String.t()) :: [String.t()]
  def doc_files_for_version("2026-07-28" = version) do
    base = "docs/specification/#{version}"

    [
      "#{base}/architecture/index.mdx",
      "#{base}/basic/authorization/authorization-server-discovery.mdx",
      "#{base}/basic/authorization/client-registration.mdx",
      "#{base}/basic/authorization/index.mdx",
      "#{base}/basic/authorization/security-considerations.mdx",
      "#{base}/basic/index.mdx",
      "#{base}/basic/patterns/cancellation.mdx",
      "#{base}/basic/patterns/index.mdx",
      "#{base}/basic/patterns/mrtr.mdx",
      "#{base}/basic/patterns/progress.mdx",
      "#{base}/basic/patterns/subscriptions.mdx",
      "#{base}/basic/transports/index.mdx",
      "#{base}/basic/transports/stdio.mdx",
      "#{base}/basic/transports/streamable-http.mdx",
      "#{base}/basic/versioning.mdx",
      "#{base}/changelog.mdx",
      "#{base}/client/elicitation.mdx",
      "#{base}/client/roots.mdx",
      "#{base}/client/sampling.mdx",
      "#{base}/deprecated.mdx",
      "#{base}/index.mdx",
      "#{base}/schema.mdx",
      "#{base}/server/discover.mdx",
      "#{base}/server/index.mdx",
      "#{base}/server/prompts.mdx",
      "#{base}/server/resources.mdx",
      "#{base}/server/tools.mdx",
      "#{base}/server/utilities/caching.mdx",
      "#{base}/server/utilities/completion.mdx",
      "#{base}/server/utilities/logging.mdx",
      "#{base}/server/utilities/pagination.mdx"
    ]
  end

  def doc_files_for_version(version) do
    base = "docs/specification/#{version}"

    [
      # Root docs
      "#{base}/index.mdx",
      "#{base}/changelog.mdx",
      # Architecture
      "#{base}/architecture/index.mdx",
      # Base protocol
      "#{base}/basic/index.mdx",
      "#{base}/basic/lifecycle.mdx",
      "#{base}/basic/transports.mdx",
      "#{base}/basic/authorization.mdx",
      # Note: security_best_practices left the versioned tree; see shared_doc_files/0
      # Base protocol utilities
      "#{base}/basic/utilities/cancellation.mdx",
      "#{base}/basic/utilities/ping.mdx",
      "#{base}/basic/utilities/progress.mdx",
      "#{base}/basic/utilities/tasks.mdx",
      # Server features
      "#{base}/server/index.mdx",
      "#{base}/server/prompts.mdx",
      "#{base}/server/resources.mdx",
      "#{base}/server/tools.mdx",
      # Server utilities
      "#{base}/server/utilities/completion.mdx",
      "#{base}/server/utilities/logging.mdx",
      "#{base}/server/utilities/pagination.mdx",
      # Client features
      "#{base}/client/elicitation.mdx",
      "#{base}/client/roots.mdx",
      "#{base}/client/sampling.mdx"
    ]
  end

  @doc """
  Non-versioned tutorial / guide docs that apply across protocol revisions.

  Upstream moved Security Best Practices out of
  `specification/YYYY-MM-DD/basic/` into the global tutorials tree:

  * Site: https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices
  * Repo: `docs/docs/tutorials/security/security_best_practices.mdx`
  """
  @spec shared_doc_files() :: [String.t()]
  def shared_doc_files do
    [
      "docs/docs/tutorials/security/security_best_practices.mdx",
      "docs/docs/tutorials/security/authorization.mdx"
    ]
  end

  @doc """
  Processes MDX content into clean Markdown.

  Strips JSX components, import statements, and other MDX-specific
  syntax while preserving the documentation content.
  """
  @spec process_mdx_content(String.t()) :: String.t()
  def process_mdx_content(content) do
    content
    |> remove_import_statements()
    |> remove_jsx_self_closing_tags()
    |> convert_jsx_block_tags()
    |> remove_export_statements()
    |> clean_blank_lines()
  end

  @doc """
  Checks if a file path is an MDX file that should be converted.
  """
  @spec mdx_file?(String.t()) :: boolean()
  def mdx_file?(path), do: String.ends_with?(path, ".mdx")

  # Private - path mapping

  defp map_doc_path([version, "index.mdx"]) do
    "#{version}/Specification.md"
  end

  defp map_doc_path([version, filename]) when is_binary(filename) do
    local_name = map_filename(filename)
    "#{version}/#{local_name}"
  end

  defp map_doc_path([version, "architecture", "index.mdx"]) do
    "#{version}/Architecture.md"
  end

  defp map_doc_path([version, dir, "index.mdx"]) do
    local_dir = Map.get(@dir_mappings, dir, capitalize_name(dir))
    "#{version}/#{local_dir}/Overview.md"
  end

  defp map_doc_path([version, dir, filename]) do
    local_dir = Map.get(@dir_mappings, dir, capitalize_name(dir))
    local_name = map_filename(filename)
    "#{version}/#{local_dir}/#{local_name}"
  end

  defp map_doc_path([version, dir, subdir, "index.mdx"]) do
    local_dir = Map.get(@dir_mappings, dir, capitalize_name(dir))
    local_subdir = Map.get(@dir_mappings, subdir, capitalize_name(subdir))
    "#{version}/#{local_dir}/#{local_subdir}/Overview.md"
  end

  defp map_doc_path([version, dir, subdir, filename]) do
    local_dir = Map.get(@dir_mappings, dir, capitalize_name(dir))
    local_subdir = Map.get(@dir_mappings, subdir, capitalize_name(subdir))
    local_name = map_filename(filename)
    "#{version}/#{local_dir}/#{local_subdir}/#{local_name}"
  end

  defp map_doc_path([version | rest]) when rest != [] do
    {dirs, [filename]} = Enum.split(rest, -1)

    local_dirs =
      Enum.map(dirs, fn dir ->
        Map.get(@dir_mappings, dir, capitalize_name(dir))
      end)

    local_name = if filename == "index.mdx", do: "Overview.md", else: map_filename(filename)

    Path.join([version | local_dirs] ++ [local_name])
  end

  defp map_doc_path(parts), do: Enum.join(parts, "/")

  defp map_filename(filename) do
    case Map.get(@file_mappings, filename) do
      nil ->
        filename
        |> String.replace_suffix(".mdx", ".md")
        |> capitalize_name()

      mapped ->
        mapped
    end
  end

  defp capitalize_name(name) do
    # Convert snake_case or lowercase to CamelCase
    # "lifecycle.md" -> "Lifecycle.md"
    # "security_best_practices.md" -> "SecurityBestPractices.md"
    {base, ext} =
      case String.split(name, ".", parts: 2) do
        [base, ext] -> {base, "." <> ext}
        [base] -> {base, ""}
      end

    camel =
      base
      |> String.split(~r/[-_]/, trim: true)
      |> Enum.map_join(&String.capitalize/1)

    camel <> ext
  end

  # Private - MDX processing

  defp remove_import_statements(content) do
    # Remove lines like: import { Info, Warning } from '...'
    Regex.replace(~r/^import\s+.*$\n?/m, content, "")
  end

  defp remove_jsx_self_closing_tags(content) do
    # Remove self-closing JSX tags like <Component /> or <div className="..." />
    # Also handle lowercase self-closing tags like <div ... />
    content
    |> then(&Regex.replace(~r/<[A-Z][a-zA-Z]*\s*[^>]*\/>\s*\n?/m, &1, ""))
    |> then(&Regex.replace(~r/<div\s+[^>]*\/>\s*\n?/m, &1, ""))
  end

  defp convert_jsx_block_tags(content) do
    content
    |> convert_admonition_tags("Info", "> **Info:**")
    |> convert_admonition_tags("Warning", "> **Warning:**")
    |> convert_admonition_tags("Tip", "> **Tip:**")
    |> convert_admonition_tags("Note", "> **Note:**")
    |> convert_admonition_tags("Caution", "> **Caution:**")
    |> remove_generic_jsx_block_tags()
  end

  defp convert_admonition_tags(content, tag, prefix) do
    # Convert <Tag>content</Tag> to blockquote with prefix
    pattern = ~r/<#{tag}[^>]*>\s*\n?(.*?)\s*<\/#{tag}>/s

    Regex.replace(pattern, content, fn _, inner ->
      lines =
        inner
        |> String.trim()
        |> String.split("\n")
        |> Enum.map_join("\n", fn line -> "> #{line}" end)

      "#{prefix}\n#{lines}\n"
    end)
  end

  defp remove_generic_jsx_block_tags(content) do
    # Remove remaining opening/closing JSX tags like <div className="...">, </div>
    content
    |> then(&Regex.replace(~r/<div[^>]*>\s*\n?/m, &1, ""))
    |> then(&Regex.replace(~r/<\/div>\s*\n?/m, &1, ""))
    |> then(&Regex.replace(~r/<[A-Z][a-zA-Z]*[^>]*>\s*\n?/m, &1, ""))
    |> then(&Regex.replace(~r/<\/[A-Z][a-zA-Z]*>\s*\n?/m, &1, ""))
  end

  defp remove_export_statements(content) do
    Regex.replace(~r/^export\s+.*$\n?/m, content, "")
  end

  defp clean_blank_lines(content) do
    # Collapse 3+ blank lines into 2
    Regex.replace(~r/\n{3,}/, content, "\n\n")
  end
end
