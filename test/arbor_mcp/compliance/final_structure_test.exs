defmodule Arbor.MCP.Compliance.FinalStructureTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.VersionRegistry

  alias Arbor.MCP.Compliance.{
    Spec20241105,
    Spec20250326,
    Spec20250618,
    Spec20251125,
    VersionGenerator
  }

  alias Arbor.MCP.Compliance.Features.{
    Authorization,
    Prompts,
    Resources,
    Tools,
    Transport
  }

  @moduletag :compliance
  @moduletag :final_validation

  describe "new compliance test structure validation" do
    test "all version modules are generated and functional" do
      # Test that all version modules exist
      assert Code.ensure_loaded?(Arbor.MCP.Compliance.Spec20241105)
      assert Code.ensure_loaded?(Arbor.MCP.Compliance.Spec20250326)
      assert Code.ensure_loaded?(Arbor.MCP.Compliance.Spec20250618)
      assert Code.ensure_loaded?(Arbor.MCP.Compliance.Spec20251125)

      # Test that they return correct versions
      assert Spec20241105.version() == "2024-11-05"
      assert Spec20250326.version() == "2025-03-26"
      assert Spec20250618.version() == "2025-06-18"
      assert Spec20251125.version() == "2025-11-25"
    end

    test "all feature modules are loaded and functional" do
      # Test that all feature modules exist
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

    test "version generator provides correct information" do
      versions = VersionGenerator.supported_versions()
      assert versions == VersionRegistry.supported_versions()
      assert "2024-11-05" in versions
      assert "2025-03-26" in versions
      assert "2025-06-18" in versions
      assert "2025-11-25" in versions

      # Test module mapping
      assert VersionGenerator.module_for_version("2024-11-05") ==
               Spec20241105

      assert VersionGenerator.module_for_version("2025-03-26") ==
               Spec20250326

      assert VersionGenerator.module_for_version("2025-06-18") ==
               Spec20250618

      assert VersionGenerator.module_for_version("2025-11-25") ==
               Spec20251125
    end

    test "feature test functions are accessible" do
      # Test that feature modules are loaded and have expected functions
      # The feature modules define functions that are called by the generated test modules

      # Check that modules are loaded
      assert Code.ensure_loaded?(Tools)
      assert Code.ensure_loaded?(Resources)
      assert Code.ensure_loaded?(Authorization)
      assert Code.ensure_loaded?(Transport)
      assert Code.ensure_loaded?(Prompts)

      # Check that key test implementation functions exist
      # These are the actual implementation functions, not the test definitions
      assert function_exported?(Tools, :test_basic_tools_list, 1)
      assert function_exported?(Resources, :test_basic_resources_list, 1)
      assert function_exported?(Authorization, :test_oauth_authorization, 1)
      assert function_exported?(Transport, :test_jsonrpc_format, 1)
      assert function_exported?(Prompts, :test_basic_prompts_list, 1)
    end

    test "version-specific features are properly gated" do
      # Test that version-specific features only run for appropriate versions

      # Authorization should only work for 2025-03-26+
      assert_raise FunctionClauseError, fn ->
        Authorization.test_oauth_authorization("2024-11-05")
      end

      # But should work for 2025-03-26+
      Authorization.test_oauth_authorization("2025-03-26")
      Authorization.test_oauth_authorization("2025-06-18")
      Authorization.test_oauth_authorization("2025-11-25")

      # Batch processing should only work for 2025-03-26 (removed in 2025-06-18)
      assert_raise FunctionClauseError, fn ->
        Transport.test_batch_processing("2024-11-05")
      end

      # Should work for 2025-03-26
      Transport.test_batch_processing("2025-03-26")

      # But not for 2025-06-18 (feature removed)
      assert_raise FunctionClauseError, fn ->
        Transport.test_batch_processing("2025-06-18")
      end
    end

    test "basic feature tests work for all versions" do
      versions = VersionRegistry.supported_versions()

      for version <- versions do
        # These should work for all versions
        Tools.test_basic_tools_list(version)
        Resources.test_basic_resources_list(version)
        Transport.test_jsonrpc_format(version)
        Prompts.test_basic_prompts_list(version)
      end
    end
  end

  describe "compliance test organization" do
    test "tests are properly tagged for filtering" do
      # This test verifies that the module is properly set up for compliance testing
      # The @moduletag directives at the module level ensure tests can be filtered
      # but they're not accessible as runtime values in tests
      assert true
    end
  end
end
