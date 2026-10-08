defmodule Arbor.MCP.Internal.RevisionCatalog do
  @moduledoc false

  # Pure, dependency-free catalog of the MCP protocol revisions Arbor.MCP
  # implements. `Arbor.MCP.Internal.VersionRegistry` remains the canonical registry
  # (enablement, preference ordering, capabilities, feature tables) and reads
  # its revision lists from here. Lower-level modules that only need the raw
  # revision data or era classification at compile time or runtime
  # (`Arbor.MCP.Protocol.Methods`, `Arbor.MCP.Protocol.ErrorCodes`, `Arbor.MCP.Types`)
  # depend on this catalog instead of the registry, so version data does not
  # cycle back through the registry that consumes those modules.
  #
  # Add or reorder revisions here only; the registry derives everything else.

  @type version :: String.t()
  @type revision :: {version(), String.t()}

  # Legacy protocol versions in order of preference (newest first)
  @legacy_revisions [
    {"2025-11-25", "Newest legacy revision with tasks, icons, and URL elicitation"},
    {"2025-06-18", "Previous stable specification"},
    {"2025-03-26", "Stable specification with batch support"},
    {"2024-11-05", "Initial stable specification"}
  ]

  # Modern revisions participate according to the selected dual-era mode.
  @modern_revisions [
    {"2026-07-28", "Latest stable stateless revision available through modern modes"}
  ]

  @legacy_versions Enum.map(@legacy_revisions, &elem(&1, 0))
  @modern_versions Enum.map(@modern_revisions, &elem(&1, 0))

  @doc "Legacy (initialize-compatible) revisions with descriptions, newest first."
  @spec legacy_revisions() :: [revision()]
  def legacy_revisions, do: @legacy_revisions

  @doc "Modern (stateless) revisions with descriptions, newest first."
  @spec modern_revisions() :: [revision()]
  def modern_revisions, do: @modern_revisions

  @doc "Legacy version strings, newest first."
  @spec legacy_versions() :: [version()]
  def legacy_versions, do: @legacy_versions

  @doc "Modern version strings, newest first."
  @spec modern_versions() :: [version()]
  def modern_versions, do: @modern_versions

  @doc "Every implemented version string: modern revisions first, then legacy."
  @spec known_versions() :: [version()]
  def known_versions, do: @modern_versions ++ @legacy_versions

  @doc "The newest legacy revision."
  @spec latest_legacy_version() :: version()
  def latest_legacy_version, do: hd(@legacy_versions)

  @doc "Classifies a version string into its protocol era."
  @spec era_for(version()) :: :legacy | :modern | :unknown
  def era_for(version) do
    cond do
      version in @modern_versions -> :modern
      version in @legacy_versions -> :legacy
      true -> :unknown
    end
  end
end
