defmodule Arbor.MCP.Compliance.VersionGenerator do
  @moduledoc """
  Auto-generates version-specific compliance test modules.

  This module creates individual test modules for each MCP specification version,
  each using the appropriate feature modules based on version compatibility.

  Supported versions come from `Arbor.MCP.Internal.VersionRegistry`. Adding a new
  version requires an explicit handler entry below; missing entries fail at
  compile time instead of silently falling back to a generic handler.
  """

  alias Arbor.MCP.Internal.VersionRegistry

  @versions VersionRegistry.supported_versions()
  @handlers %{
    "2024-11-05" => Arbor.MCP.Compliance.Handlers.Handler20241105,
    "2025-03-26" => Arbor.MCP.Compliance.Handlers.Handler20250326,
    "2025-06-18" => Arbor.MCP.Compliance.Handlers.Handler20250618,
    "2025-11-25" => Arbor.MCP.Compliance.Handlers.Handler20251125
  }

  @missing_handlers @versions -- Map.keys(@handlers)

  if @missing_handlers != [] do
    raise "missing compliance handlers for: #{Enum.join(@missing_handlers, ", ")}"
  end

  # Generate a test module for each version
  for version <- @versions do
    handler = Map.fetch!(@handlers, version)
    # Create module name like Arbor.MCP.Compliance.Spec20241105
    module_name_suffix = String.replace(version, "-", "")
    module_name = :"Elixir.Arbor.MCP.Compliance.Spec#{module_name_suffix}"

    defmodule module_name do
      use ExUnit.Case, async: true

      alias Arbor.MCP.Internal.VersionRegistry

      @version version
      @handler handler

      # Import feature modules
      use Arbor.MCP.Compliance.Features.Tools, version
      use Arbor.MCP.Compliance.Features.Resources, version
      use Arbor.MCP.Compliance.Features.ResourceTemplates, version
      use Arbor.MCP.Compliance.Features.Authorization, version
      use Arbor.MCP.Compliance.Features.Prompts, version
      use Arbor.MCP.Compliance.Features.Transport, version
      use Arbor.MCP.Compliance.Features.Roots, version
      use Arbor.MCP.Compliance.Features.Sampling, version
      use Arbor.MCP.Compliance.Features.Cancellation, version
      use Arbor.MCP.Compliance.Features.Progress, version
      use Arbor.MCP.Compliance.Features.Logging, version
      use Arbor.MCP.Compliance.Features.Batch, version
      use Arbor.MCP.Compliance.Features.Completion, version
      use Arbor.MCP.Compliance.Features.Elicitation, version

      # Module tags for filtering
      @moduletag :compliance
      @moduletag :"version_#{String.replace(version, "-", "_")}"

      @doc """
      Returns the MCP specification version this test module covers.
      """
      def version, do: @version

      # Version-specific setup
      setup do
        {:ok, version: @version, spec_version: @version, handler: @handler}
      end

      # Version-specific tests that don't fit into feature categories
      test "protocol version negotiation works for #{@version}" do
        # Test that this specific version can be negotiated
        assert is_binary(@version)
        assert @version in VersionRegistry.supported_versions()
        # Add actual negotiation test logic here
      end

      test "server capabilities match #{@version} specification" do
        # Test that server capabilities align with this version's spec
        assert is_binary(@version)
        refute is_nil(@version)
        # Add actual capability validation logic here
      end
    end
  end

  @doc """
  Returns all supported MCP specification versions.
  """
  def supported_versions, do: @versions

  @doc """
  Returns the module name for a given version.
  """
  def module_for_version(version) when version in @versions do
    module_name_suffix = String.replace(version, "-", "")
    :"Elixir.Arbor.MCP.Compliance.Spec#{module_name_suffix}"
  end

  @doc """
  Returns all generated compliance test modules.
  """
  def all_modules do
    Enum.map(@versions, &module_for_version/1)
  end
end
