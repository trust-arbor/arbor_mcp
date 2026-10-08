defmodule Arbor.MCP.FeatureFlagsTest do
  use ExUnit.Case, async: false

  # Clean up application environment after each test to ensure isolation.
  setup do
    on_exit(fn ->
      Application.delete_env(:arbor_mcp, :protocol_version_required)
      Application.delete_env(:arbor_mcp, :structured_output_enabled)
      Application.delete_env(:arbor_mcp, :oauth2_enabled)
    end)
  end

  describe "enabled?/1" do
    test "returns false for all features by default" do
      refute Arbor.MCP.FeatureFlags.enabled?(:protocol_version_header)
      refute Arbor.MCP.FeatureFlags.enabled?(:structured_output)
      refute Arbor.MCP.FeatureFlags.enabled?(:oauth2_auth)
    end

    test "returns true for :protocol_version_header when enabled" do
      Application.put_env(:arbor_mcp, :protocol_version_required, true)
      assert Arbor.MCP.FeatureFlags.enabled?(:protocol_version_header)
    end

    test "returns true for :structured_output when enabled" do
      Application.put_env(:arbor_mcp, :structured_output_enabled, true)
      assert Arbor.MCP.FeatureFlags.enabled?(:structured_output)
    end

    test "returns true for :oauth2_auth when enabled" do
      Application.put_env(:arbor_mcp, :oauth2_enabled, true)
      assert Arbor.MCP.FeatureFlags.enabled?(:oauth2_auth)
    end

    test "returns false for an unknown feature flag" do
      refute Arbor.MCP.FeatureFlags.enabled?(:some_unknown_feature)
    end

    test "keeps the retired tasks flag disabled regardless of application config" do
      Application.put_env(:arbor_mcp, :tasks_enabled, true)
      refute Arbor.MCP.FeatureFlags.enabled?(:tasks)
    after
      Application.delete_env(:arbor_mcp, :tasks_enabled)
    end
  end

  describe "all/0" do
    test "returns a map of all features with default values (false)" do
      expected_map = %{
        protocol_version_header: false,
        structured_output: false,
        oauth2_auth: false,
        tasks: false
      }

      assert Arbor.MCP.FeatureFlags.all() == expected_map
    end

    test "returns a map reflecting enabled features" do
      Application.put_env(:arbor_mcp, :protocol_version_required, true)
      Application.put_env(:arbor_mcp, :oauth2_enabled, true)

      expected_map = %{
        protocol_version_header: true,
        structured_output: false,
        oauth2_auth: true,
        tasks: false
      }

      assert Arbor.MCP.FeatureFlags.all() == expected_map
    end
  end
end
