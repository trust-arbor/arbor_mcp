defmodule Arbor.MCP.Internal.VersionRegistry do
  @moduledoc false

  # Registry for MCP protocol versions and their capabilities.
  #
  # This module manages protocol version differences and provides
  # version-specific behavior for the MCP implementation.

  @type version :: String.t()
  @type version_status :: :supported | :unknown
  @type protocol_mode :: :legacy_only | :modern_only | :prefer_legacy | :prefer_modern
  @type capability_key :: atom()
  @type feature :: atom()

  require Logger
  alias Arbor.MCP.Internal.RevisionCatalog
  alias Arbor.MCP.Protocol.Methods

  # The raw revision lists live in `Arbor.MCP.Internal.RevisionCatalog` so that
  # lower-level protocol modules can read them without depending on this
  # registry. This module remains the canonical owner of enablement, era
  # preference ordering, and version-specific behaviour.

  # Legacy protocol versions in order of preference (newest first)
  @versions RevisionCatalog.legacy_revisions()

  # Modern revisions participate according to the selected dual-era mode. The
  # zero-arity legacy APIs intentionally retain their initialize-compatible
  # meaning throughout 1.x even though new connections prefer modern by default.
  @modern_revisions RevisionCatalog.modern_revisions()

  @modern_versions Enum.map(@modern_revisions, &elem(&1, 0))

  @doc """
  Get all initialize-compatible legacy protocol versions.
  """
  @spec supported_versions() :: [version()]
  def supported_versions do
    Enum.map(@versions, fn {version, _desc} -> version end)
  end

  @doc """
  Get every protocol version implemented by ArborMCP, including opt-in modern revisions.

  Callers performing era-aware negotiation or advertising support must use
  `supported_versions/1` with the selected protocol mode.
  """
  @spec known_versions() :: [version()]
  def known_versions do
    Enum.map(@modern_revisions ++ @versions, fn {version, _desc} -> version end)
  end

  @doc "Returns whether ArborMCP recognizes a version, regardless of enablement status."
  @spec known?(version()) :: boolean()
  def known?(version), do: version in known_versions()

  @doc "Returns the configured dual-era protocol mode."
  @spec protocol_mode() :: protocol_mode()
  def protocol_mode do
    case Application.get_env(:arbor_mcp, :protocol_mode, :prefer_modern) do
      mode when mode in [:legacy_only, :modern_only, :prefer_legacy, :prefer_modern] -> mode
      _invalid -> :prefer_modern
    end
  end

  @doc "Returns versions enabled by an explicit protocol mode."
  @spec enabled_versions(protocol_mode()) :: [version()]
  def enabled_versions(mode), do: supported_versions(mode)

  @doc "Returns supported versions in the preference order for a protocol mode."
  @spec supported_versions(protocol_mode()) :: [version()]
  def supported_versions(:legacy_only), do: supported_versions()
  def supported_versions(:modern_only), do: @modern_versions
  def supported_versions(:prefer_legacy), do: supported_versions() ++ @modern_versions
  def supported_versions(:prefer_modern), do: @modern_versions ++ supported_versions()

  @doc "Returns whether a version is enabled in an explicit protocol mode."
  @spec enabled?(version(), protocol_mode()) :: boolean()
  def enabled?(version, mode), do: version in enabled_versions(mode)

  @doc "Returns whether a version is supported under an explicit protocol mode."
  @spec supported?(version(), protocol_mode()) :: boolean()
  def supported?(version, mode), do: version in supported_versions(mode)

  @doc "Returns the preferred version for an explicit protocol mode."
  @spec preferred_version(protocol_mode()) :: version()
  def preferred_version(mode) do
    mode
    |> enabled_versions()
    |> List.first()
  end

  @doc "Returns the implementation status for a protocol version."
  @spec version_status(version()) :: version_status()
  def version_status(version), do: if(known?(version), do: :supported, else: :unknown)

  @doc """
  Get the newest initialize-compatible legacy protocol revision.

  This compatibility accessor intentionally remains separate from the latest
  upstream stable revision (`2026-07-28`) during the dual-era RC rollout.
  """
  @spec latest_version() :: version()
  def latest_version, do: @versions |> hd() |> elem(0)

  @doc """
  Get the preferred protocol version from configuration or default.
  """
  @spec preferred_version() :: version()
  def preferred_version do
    configured_version = Application.get_env(:arbor_mcp, :protocol_version, latest_version())

    if supported?(configured_version) do
      configured_version
    else
      Logger.warning(
        "Configured MCP protocol version #{inspect(configured_version)} is not enabled; " <>
          "using #{latest_version()}"
      )

      latest_version()
    end
  end

  @doc """
  Check if a version is supported by initialize-compatible legacy paths.
  """
  @spec supported?(version()) :: boolean()
  def supported?(version) do
    version in supported_versions()
  end

  @doc """
  Get capabilities available in a specific protocol version.
  """
  @spec capabilities_for_version(version()) :: %{capability_key() => any()}
  def capabilities_for_version("2024-11-05") do
    %{
      # Base capabilities available in 2024-11-05
      # The 2024-11-05 schema defines subscribe and listChanged for resources,
      # listChanged for prompts and tools, and logging as an object capability.
      prompts: %{listChanged: true},
      resources: %{subscribe: true, listChanged: true},
      tools: %{listChanged: true},
      logging: %{},
      # No experimental features
      experimental: %{}
    }
  end

  def capabilities_for_version("2025-03-26") do
    %{
      # Enhanced capabilities in 2025-03-26
      prompts: %{listChanged: true},
      resources: %{subscribe: true, listChanged: true},
      tools: %{},
      # logging is a presence indicator per spec (logging?: object)
      logging: %{},
      # completions (with "s") is a presence indicator per spec (completions?: object)
      completions: %{},
      # Batch processing available in 2025-03-26
      experimental: %{batchProcessing: true}
    }
  end

  def capabilities_for_version("2025-06-18") do
    %{
      # Enhanced capabilities in 2025-06-18
      prompts: %{listChanged: true},
      resources: %{subscribe: true, listChanged: true},
      # tools capability has listChanged; outputSchema goes on individual Tool definitions
      tools: %{listChanged: true},
      # logging is an empty object per the spec (logging?: object)
      logging: %{},
      # The spec uses "completions" (with "s") as the capability key
      completions: %{},
      # 2025-06-18 features (no batch processing)
      experimental: %{
        elicitation: true,
        structuredContent: true,
        toolOutputSchema: true,
        batchProcessing: false
      }
    }
  end

  def capabilities_for_version("2025-11-25") do
    %{
      # Enhanced capabilities in 2025-11-25
      prompts: %{listChanged: true},
      resources: %{subscribe: true, listChanged: true},
      # outputSchema is per-tool definition, not a server capability
      tools: %{listChanged: true},
      # logging capability is an empty object per MCP spec
      logging: %{},
      # MCP spec uses "completions" (plural) for server capabilities
      completions: %{},
      # Tasks capability (new in 2025-11-25)
      tasks: %{},
      # 2025-11-25 features
      experimental: %{
        elicitation: true,
        structuredContent: true,
        toolOutputSchema: true,
        batchProcessing: false,
        urlElicitation: true,
        icons: true,
        toolCallingInSampling: true
      }
    }
  end

  def capabilities_for_version("2026-07-28") do
    %{
      prompts: %{listChanged: true},
      resources: %{listChanged: true},
      tools: %{listChanged: true},
      completions: %{},
      extensions: %{}
    }
  end

  def capabilities_for_version(unknown) do
    Logger.warning(
      "Unknown MCP protocol version #{inspect(unknown)}; using #{latest_version()} capabilities"
    )

    capabilities_for_version(latest_version())
  end

  @doc "Returns the protocol era for a known version."
  @spec era_for(version()) :: :legacy | :modern | :unknown
  def era_for(version), do: RevisionCatalog.era_for(version)

  @doc "Returns whether a version uses the post-2025-11-25 protocol era."
  @spec modern?(version()) :: boolean()
  def modern?(version), do: era_for(version) == :modern

  @doc """
  Check if a feature is available in a specific version.
  """
  @spec feature_available?(version(), feature()) :: boolean()
  def feature_available?(version, feature) do
    cond do
      not supported?(version) -> false
      feature in base_features() -> true
      feature in v2025_features() -> version in ["2025-03-26", "2025-06-18", "2025-11-25"]
      feature in batch_features() -> version == "2025-03-26"
      feature in v20250618_features() -> version in ["2025-06-18", "2025-11-25"]
      feature in v20251125_features() -> version == "2025-11-25"
      true -> false
    end
  end

  # Helper functions for feature categorization
  # The 2024-11-05 schema defines resource subscriptions, listChanged notifications
  # for prompts/resources, logging/setLevel, and completion/complete - so these are
  # all base features available in every version.
  defp base_features do
    [
      :prompts,
      :resources,
      :tools,
      :logging,
      :resource_subscription,
      :prompts_list_changed,
      :resources_list_changed,
      :logging_set_level,
      :completion
    ]
  end

  # No features are gated to 2025-03-26 exclusively (batch is handled separately)
  defp v2025_features do
    []
  end

  defp batch_features, do: [:batch_processing]

  defp v20250618_features, do: [:elicitation, :structured_content, :tool_output_schema]

  defp v20251125_features, do: [:tasks, :icons, :url_elicitation, :tool_calling_in_sampling]

  @doc """
  Get the message format differences for a version.
  """
  @spec message_format(version()) :: map()
  def message_format("2024-11-05") do
    %{
      # Basic message format
      supports_batch: false,
      supports_progress: true,
      supports_cancellation: true,
      notification_methods: Methods.notification_methods("2024-11-05"),
      request_methods: []
    }
  end

  def message_format("2025-03-26") do
    %{
      # Enhanced message format with batch support
      supports_batch: true,
      supports_progress: true,
      supports_cancellation: true,
      notification_methods: Methods.notification_methods("2025-03-26"),
      request_methods: []
    }
  end

  def message_format("2025-06-18") do
    %{
      # 2025-06-18 format (no batch support)
      supports_batch: false,
      supports_progress: true,
      supports_cancellation: true,
      notification_methods: Methods.notification_methods("2025-06-18"),
      request_methods: []
    }
  end

  def message_format("2025-11-25") do
    %{
      # 2025-11-25 format with tasks and URL elicitation
      supports_batch: false,
      supports_progress: true,
      supports_cancellation: true,
      notification_methods: Methods.notification_methods("2025-11-25"),
      request_methods: Methods.introduced_request_methods("2025-11-25")
    }
  end

  def message_format(unknown) do
    Logger.warning(
      "Unknown MCP protocol version #{inspect(unknown)}; using #{latest_version()} message format"
    )

    message_format(latest_version())
  end

  @doc """
  Negotiate protocol version between client and server.

  Returns the best mutually supported version or an error.
  """
  @spec negotiate_version(version(), [version()]) ::
          {:ok, version()} | {:error, :version_mismatch}
  def negotiate_version(client_version, server_versions) do
    cond do
      # Exact match
      supported?(client_version) and client_version in server_versions ->
        {:ok, client_version}

      # Client version is supported by us
      supported?(client_version) ->
        # Find best common version
        common_versions = Enum.filter(supported_versions(), &(&1 in server_versions))

        if common_versions != [] do
          {:ok, hd(common_versions)}
        else
          {:error, :version_mismatch}
        end

      # Unknown client version, propose our best that server supports
      true ->
        our_versions = supported_versions()
        common_versions = Enum.filter(our_versions, &(&1 in server_versions))

        if common_versions != [] do
          {:ok, hd(common_versions)}
        else
          {:error, :version_mismatch}
        end
    end
  end

  @doc """
  Get version-specific type module.

  This allows loading different type definitions based on protocol version.
  """
  @spec types_module(version()) :: module()
  def types_module("2024-11-05"), do: Arbor.MCP.Types.V20241105
  def types_module("2025-03-26"), do: Arbor.MCP.Types.V20250326
  def types_module("2025-06-18"), do: Arbor.MCP.Types.V20250618
  def types_module("2025-11-25"), do: Arbor.MCP.Types.V20251125
  def types_module("2026-07-28"), do: Arbor.MCP.Types.V20260728
  def types_module(_), do: Arbor.MCP.Types
end
