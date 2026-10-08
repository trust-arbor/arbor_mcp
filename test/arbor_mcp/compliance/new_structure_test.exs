defmodule Arbor.MCP.Compliance.NewStructureTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Compliance.{
    Spec20241105,
    Spec20250326,
    Spec20250618,
    Spec20251125,
    VersionGenerator
  }

  # Removed unused aliases

  @moduletag :compliance
  @moduletag :new_structure

  describe "new compliance test structure" do
    test "version generator module loads correctly" do
      # Test that we can load the version generator
      assert Code.ensure_loaded?(Arbor.MCP.Compliance.VersionGenerator)

      # Test that it has the expected functions
      versions = VersionGenerator.supported_versions()
      assert is_list(versions)
      assert versions == Arbor.MCP.Internal.VersionRegistry.supported_versions()
    end

    test "feature modules load correctly" do
      # Test that all feature modules can be loaded
      feature_modules = [
        Arbor.MCP.Compliance.Features.Tools,
        Arbor.MCP.Compliance.Features.Resources,
        Arbor.MCP.Compliance.Features.Authorization,
        Arbor.MCP.Compliance.Features.Prompts,
        Arbor.MCP.Compliance.Features.Transport
      ]

      for module <- feature_modules do
        assert Code.ensure_loaded?(module), "Failed to load #{module}"
      end
    end

    test "generated version modules exist" do
      # Test that the generated modules exist
      version_modules = [
        Arbor.MCP.Compliance.Spec20241105,
        Arbor.MCP.Compliance.Spec20250326,
        Arbor.MCP.Compliance.Spec20250618,
        Arbor.MCP.Compliance.Spec20251125
      ]

      for module <- version_modules do
        assert Code.ensure_loaded?(module), "Failed to load #{module}"
        assert function_exported?(module, :version, 0), "#{module} missing version/0 function"
      end
    end

    test "version modules return correct versions" do
      assert Spec20241105.version() == "2024-11-05"
      assert Spec20250326.version() == "2025-03-26"
      assert Spec20250618.version() == "2025-06-18"
      assert Spec20251125.version() == "2025-11-25"
    end
  end
end
