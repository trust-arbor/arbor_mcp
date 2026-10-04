defmodule Arbor.MCP.Protocol.VersionNegotiatorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  describe "negotiate/1" do
    test "returns the highest mutually supported version" do
      assert {:ok, "2025-11-25"} = VersionNegotiator.negotiate(["2025-11-25", "2025-06-18"])
      assert {:ok, "2025-11-25"} = VersionNegotiator.negotiate(["2025-06-18", "2025-11-25"])
      assert {:ok, "2025-06-18"} = VersionNegotiator.negotiate(["2025-06-18", "2025-03-26"])
    end

    test "returns 2025-03-26 when it's the only supported version" do
      assert {:ok, "2025-03-26"} = VersionNegotiator.negotiate(["2025-03-26", "2024-01-01"])
      assert {:ok, "2025-03-26"} = VersionNegotiator.negotiate(["2025-03-26"])
    end

    test "returns 2024-11-05 when it's the only supported version" do
      assert {:ok, "2024-11-05"} = VersionNegotiator.negotiate(["2024-11-05", "2024-01-01"])
      assert {:ok, "2024-11-05"} = VersionNegotiator.negotiate(["2024-11-05"])
    end

    test "prefers newer versions over older ones" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate([
                 "2024-11-05",
                 "2025-11-25",
                 "2025-06-18",
                 "2025-03-26"
               ])

      assert {:ok, "2025-06-18"} =
               VersionNegotiator.negotiate(["2024-11-05", "2025-06-18", "2025-03-26"])

      assert {:ok, "2025-03-26"} = VersionNegotiator.negotiate(["2024-11-05", "2025-03-26"])
    end

    test "returns error when no compatible version found" do
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(["2024-01-01"])
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(["invalid"])
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate([])
    end

    test "handles invalid input" do
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(nil)
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate("not a list")
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(%{})
    end

    test "filters out unsupported versions" do
      client_versions = ["2026-07-28", "2025-11-25", "2024-12-31", "2025-06-18"]
      assert {:ok, "2025-11-25"} = VersionNegotiator.negotiate(client_versions)
    end

    test "does not negotiate the staged modern version" do
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(["2026-07-28"])
    end

    test "handles duplicate versions in client list" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate(["2025-11-25", "2025-11-25", "2025-03-26"])
    end
  end

  describe "supported_versions/0" do
    test "returns the correct list of supported versions" do
      versions = VersionNegotiator.supported_versions()
      assert is_list(versions)
      assert "2025-11-25" in versions
      assert "2025-06-18" in versions
      assert "2025-03-26" in versions
      assert "2024-11-05" in versions
      assert length(versions) == 4
    end
  end

  describe "latest_version/0" do
    test "returns the newest legacy revision" do
      assert VersionNegotiator.latest_version() == "2025-11-25"
    end
  end

  describe "supported?/1" do
    test "returns true for supported versions" do
      assert VersionNegotiator.supported?("2025-11-25")
      assert VersionNegotiator.supported?("2025-06-18")
      assert VersionNegotiator.supported?("2025-03-26")
      assert VersionNegotiator.supported?("2024-11-05")
    end

    test "returns false for unsupported versions" do
      refute VersionNegotiator.supported?("2024-01-01")
      refute VersionNegotiator.supported?("invalid")
      refute VersionNegotiator.supported?("")
    end

    test "returns false for non-string input" do
      refute VersionNegotiator.supported?(nil)
      refute VersionNegotiator.supported?(123)
      refute VersionNegotiator.supported?(:atom)
      refute VersionNegotiator.supported?([])
    end
  end

  describe "canonical initialize migration" do
    test "builds complete initialization through the canonical result and capability APIs" do
      result = LegacyInitialize.result("2025-11-25")

      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "Arbor.MCP"
      assert is_binary(result["serverInfo"]["version"])

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2025-11-25")
               )

      assert result["capabilities"]["tasks"] == %{}
    end

    test "does not advertise a staged version" do
      result = LegacyInitialize.result("2026-07-28")

      assert result["protocolVersion"] == "2025-11-25"

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2025-11-25")
               )
    end
  end
end
