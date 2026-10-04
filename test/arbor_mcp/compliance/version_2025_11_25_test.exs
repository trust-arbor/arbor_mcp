defmodule Arbor.MCP.Compliance.Version20251125Test do
  @moduledoc """
  Tests for MCP protocol version 2025-11-25 compliance.

  Validates version negotiation, capability advertisement, method availability,
  feature registry, and backward compatibility for the 2025-11-25 specification
  which introduces tasks, icons, URL elicitation, and tool calling in sampling.
  """
  use ExUnit.Case, async: false

  @moduletag :compliance

  alias Arbor.MCP.Internal.{Protocol, VersionRegistry}
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  describe "version support" do
    test "2025-11-25 is a supported version in VersionRegistry" do
      assert VersionRegistry.supported?("2025-11-25")
    end

    test "2025-11-25 is a supported version in VersionNegotiator" do
      assert VersionNegotiator.supported?("2025-11-25")
    end

    test "2025-11-25 is the newest legacy revision in VersionRegistry" do
      assert VersionRegistry.latest_version() == "2025-11-25"
    end

    test "2025-11-25 is the newest legacy revision in VersionNegotiator" do
      assert VersionNegotiator.latest_version() == "2025-11-25"
    end

    test "2025-11-25 appears in the list of supported versions" do
      assert "2025-11-25" in VersionRegistry.supported_versions()
      assert "2025-11-25" in VersionNegotiator.supported_versions()
    end
  end

  describe "version negotiation" do
    test "server negotiates 2025-11-25 when client offers it alongside older versions" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate(["2025-11-25", "2025-06-18"])
    end

    test "server negotiates 2025-11-25 when it is the only offered version" do
      assert {:ok, "2025-11-25"} = VersionNegotiator.negotiate(["2025-11-25"])
    end

    test "negotiation picks the highest compatible version" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate([
                 "2024-11-05",
                 "2025-03-26",
                 "2025-06-18",
                 "2025-11-25"
               ])
    end

    test "negotiation falls back to older version when 2025-11-25 is not offered" do
      assert {:ok, "2025-06-18"} = VersionNegotiator.negotiate(["2025-06-18", "2025-03-26"])
    end

    test "negotiation fails when no compatible versions are offered" do
      assert {:error, :no_compatible_version} = VersionNegotiator.negotiate(["9999-01-01"])
    end

    test "VersionRegistry negotiate_version accepts 2025-11-25 when server supports it" do
      server_versions = VersionRegistry.supported_versions()

      assert {:ok, "2025-11-25"} =
               VersionRegistry.negotiate_version("2025-11-25", server_versions)
    end

    test "VersionRegistry negotiate_version picks best common version" do
      server_versions = ["2025-11-25", "2025-06-18"]

      assert {:ok, "2025-11-25"} =
               VersionRegistry.negotiate_version("2025-11-25", server_versions)
    end
  end

  describe "canonical capabilities for 2025-11-25" do
    test "canonical initialization retains version-specific capabilities" do
      result = LegacyInitialize.result("2025-11-25")

      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "Arbor.MCP"

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2025-11-25")
               )

      assert result["capabilities"]["tasks"] == %{}
    end
  end

  describe "method availability for 2025-06-18 methods in 2025-11-25" do
    test "initialize is available" do
      assert Protocol.method_available?("initialize", "2025-11-25")
    end

    test "tools/list is available" do
      assert Protocol.method_available?("tools/list", "2025-11-25")
    end

    test "tools/call is available" do
      assert Protocol.method_available?("tools/call", "2025-11-25")
    end

    test "resources/list is available" do
      assert Protocol.method_available?("resources/list", "2025-11-25")
    end

    test "resources/read is available" do
      assert Protocol.method_available?("resources/read", "2025-11-25")
    end

    test "resources/subscribe is available" do
      assert Protocol.method_available?("resources/subscribe", "2025-11-25")
    end

    test "prompts/list is available" do
      assert Protocol.method_available?("prompts/list", "2025-11-25")
    end

    test "prompts/get is available" do
      assert Protocol.method_available?("prompts/get", "2025-11-25")
    end

    test "completion/complete is available" do
      assert Protocol.method_available?("completion/complete", "2025-11-25")
    end

    test "logging/setLevel is available" do
      assert Protocol.method_available?("logging/setLevel", "2025-11-25")
    end

    test "elicitation/create is available" do
      assert Protocol.method_available?("elicitation/create", "2025-11-25")
    end

    test "sampling/createMessage is available" do
      assert Protocol.method_available?("sampling/createMessage", "2025-11-25")
    end

    test "ping is available" do
      assert Protocol.method_available?("ping", "2025-11-25")
    end

    test "notifications/resources/updated is available" do
      assert Protocol.method_available?("notifications/resources/updated", "2025-11-25")
    end
  end

  describe "new 2025-11-25 methods" do
    test "tasks/get is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/get", "2025-11-25")
    end

    test "tasks/list is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/list", "2025-11-25")
    end

    test "tasks/result is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/result", "2025-11-25")
    end

    test "tasks/cancel is available in 2025-11-25" do
      assert Protocol.method_available?("tasks/cancel", "2025-11-25")
    end

    test "notifications/tasks/status is available in 2025-11-25" do
      assert Protocol.method_available?("notifications/tasks/status", "2025-11-25")
    end

    test "notifications/elicitation/complete is available in 2025-11-25" do
      assert Protocol.method_available?("notifications/elicitation/complete", "2025-11-25")
    end

    test "tasks/get is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/get", "2025-06-18")
    end

    test "tasks/list is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/list", "2025-06-18")
    end

    test "tasks/result is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/result", "2025-06-18")
    end

    test "tasks/cancel is NOT available in 2025-06-18" do
      refute Protocol.method_available?("tasks/cancel", "2025-06-18")
    end

    test "notifications/tasks/status is NOT available in 2025-06-18" do
      refute Protocol.method_available?("notifications/tasks/status", "2025-06-18")
    end

    test "notifications/elicitation/complete is NOT available in 2025-06-18" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2025-06-18")
    end

    test "tasks methods are NOT available in older versions" do
      for version <- ["2025-03-26", "2024-11-05"] do
        refute Protocol.method_available?("tasks/get", version),
               "tasks/get should not be available in #{version}"

        refute Protocol.method_available?("tasks/list", version),
               "tasks/list should not be available in #{version}"

        refute Protocol.method_available?("tasks/result", version),
               "tasks/result should not be available in #{version}"

        refute Protocol.method_available?("tasks/cancel", version),
               "tasks/cancel should not be available in #{version}"

        refute Protocol.method_available?("notifications/tasks/status", version),
               "notifications/tasks/status should not be available in #{version}"

        refute Protocol.method_available?("notifications/elicitation/complete", version),
               "notifications/elicitation/complete should not be available in #{version}"
      end
    end
  end

  describe "feature registry for 2025-11-25" do
    test "tasks feature is available" do
      assert VersionRegistry.feature_available?("2025-11-25", :tasks)
    end

    test "icons feature is available" do
      assert VersionRegistry.feature_available?("2025-11-25", :icons)
    end

    test "url_elicitation feature is available" do
      assert VersionRegistry.feature_available?("2025-11-25", :url_elicitation)
    end

    test "tool_calling_in_sampling feature is available" do
      assert VersionRegistry.feature_available?("2025-11-25", :tool_calling_in_sampling)
    end

    test "2025-11-25 exclusive features are NOT available in 2025-06-18" do
      for feature <- [:tasks, :icons, :url_elicitation, :tool_calling_in_sampling] do
        refute VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} should not be available in 2025-06-18"
      end
    end

    test "2025-11-25 exclusive features are NOT available in older versions" do
      for version <- ["2025-03-26", "2024-11-05"],
          feature <- [:tasks, :icons, :url_elicitation, :tool_calling_in_sampling] do
        refute VersionRegistry.feature_available?(version, feature),
               "#{feature} should not be available in #{version}"
      end
    end
  end

  describe "backward compatibility" do
    test "base features are available in 2025-11-25" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2025-11-25", feature),
               "#{feature} should be available in 2025-11-25"
      end
    end

    test "2025 features are available in 2025-11-25" do
      for feature <- [
            :resource_subscription,
            :prompts_list_changed,
            :resources_list_changed,
            :logging_set_level,
            :completion
          ] do
        assert VersionRegistry.feature_available?("2025-11-25", feature),
               "#{feature} should be available in 2025-11-25"
      end
    end

    test "2025-06-18 features are available in 2025-11-25" do
      for feature <- [:elicitation, :structured_content, :tool_output_schema] do
        assert VersionRegistry.feature_available?("2025-11-25", feature),
               "#{feature} should be available in 2025-11-25"
      end
    end

    test "capabilities_for_version returns proper structure for 2025-11-25" do
      caps = VersionRegistry.capabilities_for_version("2025-11-25")

      # Base capabilities
      assert is_map(caps.prompts)
      assert caps.prompts.listChanged == true
      assert is_map(caps.resources)
      assert caps.resources.subscribe == true
      assert caps.resources.listChanged == true
      assert is_map(caps.tools)
      assert caps.tools.listChanged == true

      refute Map.has_key?(caps.tools, :outputSchema),
             "outputSchema belongs on individual Tool definitions, not ServerCapabilities.tools"

      assert is_map(caps.logging)
      assert caps.logging == %{}, "logging capability should be an empty object per MCP spec"

      assert is_map(caps.completions),
             "MCP spec uses 'completions' (plural) for server capabilities"

      # Tasks capability (new in 2025-11-25)
      assert is_map(caps.tasks)

      # Experimental features
      assert caps.experimental.elicitation == true
      assert caps.experimental.structuredContent == true
      assert caps.experimental.toolOutputSchema == true
      assert caps.experimental.batchProcessing == false
      assert caps.experimental.urlElicitation == true
      assert caps.experimental.icons == true
      assert caps.experimental.toolCallingInSampling == true
    end

    test "message_format includes new notification and request methods" do
      format = VersionRegistry.message_format("2025-11-25")

      assert "notifications/tasks/status" in format.notification_methods
      assert "notifications/elicitation/complete" in format.notification_methods
      assert "tasks/get" in format.request_methods
      assert "tasks/list" in format.request_methods
      assert "tasks/result" in format.request_methods
      assert "tasks/cancel" in format.request_methods
    end

    test "message_format retains existing notification methods from older versions" do
      format = VersionRegistry.message_format("2025-11-25")

      assert "notifications/initialized" in format.notification_methods
      assert "notifications/tools/list_changed" in format.notification_methods
      assert "notifications/resources/list_changed" in format.notification_methods
      assert "notifications/prompts/list_changed" in format.notification_methods
      assert "notifications/progress" in format.notification_methods
      assert "notifications/message" in format.notification_methods
      assert "notifications/cancelled" in format.notification_methods
      assert "notifications/resources/updated" in format.notification_methods
      assert "notifications/roots/list_changed" in format.notification_methods
      # logging/setLevel is a request method, not a notification
      refute "logging/setLevel" in format.notification_methods
    end

    test "validate_message_version accepts all new 2025-11-25 methods" do
      for method <- [
            "tasks/get",
            "tasks/list",
            "tasks/result",
            "tasks/cancel",
            "notifications/tasks/status",
            "notifications/elicitation/complete"
          ] do
        assert :ok == Protocol.validate_message_version(%{"method" => method}, "2025-11-25"),
               "#{method} should be valid for 2025-11-25"
      end
    end

    test "validate_message_version rejects 2025-11-25 methods in older versions" do
      for method <- [
            "tasks/get",
            "tasks/list",
            "tasks/result",
            "tasks/cancel",
            "notifications/tasks/status",
            "notifications/elicitation/complete"
          ],
          version <- ["2025-06-18", "2025-03-26", "2024-11-05"] do
        assert {:error, _message} =
                 Protocol.validate_message_version(%{"method" => method}, version),
               "#{method} should be rejected for #{version}"
      end
    end
  end
end
