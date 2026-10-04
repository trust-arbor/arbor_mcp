defmodule Arbor.MCP.Compliance.Version20250618Test do
  @moduledoc """
  Tests for MCP protocol version 2025-06-18 compliance.

  Validates version negotiation, capability advertisement, method availability,
  feature registry, and backward compatibility for the 2025-06-18 specification
  which introduces elicitation, structured output, and removes batch processing.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Internal.{Protocol, VersionRegistry}
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  describe "version support" do
    test "2025-06-18 is a supported version in VersionRegistry" do
      assert VersionRegistry.supported?("2025-06-18")
    end

    test "2025-06-18 is a supported version in VersionNegotiator" do
      assert VersionNegotiator.supported?("2025-06-18")
    end

    test "2025-06-18 is not the newest legacy revision" do
      assert VersionRegistry.latest_version() == "2025-11-25"
      assert VersionNegotiator.latest_version() == "2025-11-25"
      refute VersionRegistry.latest_version() == "2025-06-18"
    end

    test "2025-06-18 appears in the list of supported versions" do
      assert "2025-06-18" in VersionRegistry.supported_versions()
      assert "2025-06-18" in VersionNegotiator.supported_versions()
    end
  end

  describe "version negotiation" do
    test "server negotiates 2025-06-18 when it is the only offered version" do
      assert {:ok, "2025-06-18"} = VersionNegotiator.negotiate(["2025-06-18"])
    end

    test "when client offers [2025-06-18, 2025-03-26], server picks 2025-06-18" do
      assert {:ok, "2025-06-18"} =
               VersionNegotiator.negotiate(["2025-06-18", "2025-03-26"])
    end

    test "when client offers all 4 legacy revisions, server picks the newest" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate([
                 "2024-11-05",
                 "2025-03-26",
                 "2025-06-18",
                 "2025-11-25"
               ])
    end

    test "VersionRegistry negotiate_version works for 2025-06-18" do
      server_versions = VersionRegistry.supported_versions()

      assert {:ok, "2025-06-18"} =
               VersionRegistry.negotiate_version("2025-06-18", server_versions)
    end
  end

  describe "canonical capabilities for 2025-06-18" do
    test "canonical initialization retains version-specific capabilities" do
      result = LegacyInitialize.result("2025-06-18")

      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "Arbor.MCP"

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2025-06-18")
               )

      assert result["capabilities"]["experimental"]["structuredContent"]
      refute Map.has_key?(result["capabilities"], "tasks")
    end
  end

  describe "method availability" do
    test "initialize is available" do
      assert Protocol.method_available?("initialize", "2025-06-18")
    end

    test "tools/list is available" do
      assert Protocol.method_available?("tools/list", "2025-06-18")
    end

    test "tools/call is available" do
      assert Protocol.method_available?("tools/call", "2025-06-18")
    end

    test "resources/list is available" do
      assert Protocol.method_available?("resources/list", "2025-06-18")
    end

    test "resources/read is available" do
      assert Protocol.method_available?("resources/read", "2025-06-18")
    end

    test "prompts/list is available" do
      assert Protocol.method_available?("prompts/list", "2025-06-18")
    end

    test "prompts/get is available" do
      assert Protocol.method_available?("prompts/get", "2025-06-18")
    end

    test "ping is available" do
      assert Protocol.method_available?("ping", "2025-06-18")
    end

    test "sampling/createMessage is available" do
      assert Protocol.method_available?("sampling/createMessage", "2025-06-18")
    end

    test "completion/complete is available" do
      assert Protocol.method_available?("completion/complete", "2025-06-18")
    end

    test "resources/subscribe is available (from 2025-03-26)" do
      assert Protocol.method_available?("resources/subscribe", "2025-06-18")
    end

    test "resources/unsubscribe is available (from 2025-03-26)" do
      assert Protocol.method_available?("resources/unsubscribe", "2025-06-18")
    end

    test "logging/setLevel is available (from 2025-03-26)" do
      assert Protocol.method_available?("logging/setLevel", "2025-06-18")
    end

    test "notifications/resources/updated is available (from 2025-03-26)" do
      assert Protocol.method_available?("notifications/resources/updated", "2025-06-18")
    end

    test "elicitation/create is NEWLY available in 2025-06-18" do
      assert Protocol.method_available?("elicitation/create", "2025-06-18")
    end

    test "tasks/get is NOT available" do
      refute Protocol.method_available?("tasks/get", "2025-06-18")
    end

    test "tasks/list is NOT available" do
      refute Protocol.method_available?("tasks/list", "2025-06-18")
    end

    test "tasks/result is NOT available" do
      refute Protocol.method_available?("tasks/result", "2025-06-18")
    end

    test "tasks/cancel is NOT available" do
      refute Protocol.method_available?("tasks/cancel", "2025-06-18")
    end

    test "notifications/tasks/status is NOT available" do
      refute Protocol.method_available?("notifications/tasks/status", "2025-06-18")
    end

    test "notifications/elicitation/complete is NOT available" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2025-06-18")
    end
  end

  describe "feature registry" do
    test "base features are available" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} should be available in 2025-06-18"
      end
    end

    test "v2025 features are available" do
      for feature <- [
            :resource_subscription,
            :prompts_list_changed,
            :resources_list_changed,
            :logging_set_level,
            :completion
          ] do
        assert VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} should be available in 2025-06-18"
      end
    end

    test "elicitation is NEWLY available" do
      assert VersionRegistry.feature_available?("2025-06-18", :elicitation)
    end

    test "structured_content is NEWLY available" do
      assert VersionRegistry.feature_available?("2025-06-18", :structured_content)
    end

    test "tool_output_schema is NEWLY available" do
      assert VersionRegistry.feature_available?("2025-06-18", :tool_output_schema)
    end

    test "batch_processing is NOT available (removed from 2025-03-26)" do
      refute VersionRegistry.feature_available?("2025-06-18", :batch_processing)
    end

    test "tasks is NOT available" do
      refute VersionRegistry.feature_available?("2025-06-18", :tasks)
    end

    test "icons is NOT available" do
      refute VersionRegistry.feature_available?("2025-06-18", :icons)
    end

    test "url_elicitation is NOT available" do
      refute VersionRegistry.feature_available?("2025-06-18", :url_elicitation)
    end

    test "tool_calling_in_sampling is NOT available" do
      refute VersionRegistry.feature_available?("2025-06-18", :tool_calling_in_sampling)
    end
  end

  describe "batch processing removed in 2025-06-18" do
    test "batch_processing is NOT available in 2025-06-18" do
      refute VersionRegistry.feature_available?("2025-06-18", :batch_processing)
    end

    test "batch_processing WAS available in 2025-03-26" do
      assert VersionRegistry.feature_available?("2025-03-26", :batch_processing)
    end

    test "capabilities_for_version 2025-06-18 has batchProcessing == false" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.batchProcessing == false
    end

    test "capabilities_for_version 2025-03-26 has batchProcessing == true" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.experimental.batchProcessing == true
    end

    test "message_format 2025-06-18 has supports_batch == false" do
      format = VersionRegistry.message_format("2025-06-18")
      assert format.supports_batch == false
    end

    test "message_format 2025-03-26 has supports_batch == true" do
      format = VersionRegistry.message_format("2025-03-26")
      assert format.supports_batch == true
    end
  end

  describe "capabilities_for_version" do
    test "prompts has listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.prompts == %{listChanged: true}
    end

    test "resources has subscribe: true and listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.resources.subscribe == true
      assert caps.resources.listChanged == true
    end

    test "tools has listChanged: true (outputSchema goes on individual Tool definitions, not capabilities)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.tools == %{listChanged: true}
      assert caps.tools.listChanged == true
      # outputSchema is NOT a server capability field; it belongs on individual Tool definitions
      refute Map.has_key?(caps.tools, :outputSchema)
    end

    test "logging is an empty object (the spec says logging?: object)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.logging == %{}
    end

    test "completions (with 's') is present as an empty object" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert Map.has_key?(caps, :completions)
      assert caps.completions == %{}
      # The key is "completions" not "completion"
      refute Map.has_key?(caps, :completion)
    end

    test "experimental.elicitation is true (NEW)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.elicitation == true
    end

    test "experimental.structuredContent is true (NEW)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.structuredContent == true
    end

    test "experimental.toolOutputSchema is true (NEW)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.toolOutputSchema == true
    end

    test "experimental.batchProcessing is false (REMOVED)" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.batchProcessing == false
    end

    test "NO tasks key in capabilities" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      refute Map.has_key?(caps, :tasks)
    end
  end

  describe "message_format" do
    test "supports_batch is false (changed from true in 2025-03-26)" do
      format = VersionRegistry.message_format("2025-06-18")
      assert format.supports_batch == false

      format_0326 = VersionRegistry.message_format("2025-03-26")
      assert format_0326.supports_batch == true
    end

    test "supports_progress is true" do
      format = VersionRegistry.message_format("2025-06-18")
      assert format.supports_progress == true
    end

    test "supports_cancellation is true" do
      format = VersionRegistry.message_format("2025-06-18")
      assert format.supports_cancellation == true
    end

    test "notification_methods includes all notifications from 2025-03-26 (excluding logging/setLevel which is a request)" do
      format = VersionRegistry.message_format("2025-06-18")
      format_0326 = VersionRegistry.message_format("2025-03-26")

      # logging/setLevel is a REQUEST method, not a notification, so exclude it from comparison
      notifications_only =
        Enum.reject(format_0326.notification_methods, &(&1 == "logging/setLevel"))

      for method <- notifications_only do
        assert method in format.notification_methods,
               "#{method} from 2025-03-26 should be in 2025-06-18 notification_methods"
      end
    end

    test "includes notifications/roots/list_changed" do
      format = VersionRegistry.message_format("2025-06-18")
      assert "notifications/roots/list_changed" in format.notification_methods
    end

    test "does NOT include logging/setLevel in notification_methods (it is a request, not a notification)" do
      format = VersionRegistry.message_format("2025-06-18")
      refute "logging/setLevel" in format.notification_methods
    end

    test "does NOT include notifications/tasks/status" do
      format = VersionRegistry.message_format("2025-06-18")
      refute "notifications/tasks/status" in format.notification_methods
    end

    test "does NOT include notifications/elicitation/complete" do
      format = VersionRegistry.message_format("2025-06-18")
      refute "notifications/elicitation/complete" in format.notification_methods
    end

    test "has an empty request_methods list (no tasks)" do
      format = VersionRegistry.message_format("2025-06-18")
      assert format.request_methods == []
    end
  end

  describe "type module" do
    test "types_module for 2025-06-18 returns Arbor.MCP.Types.V20250618" do
      assert VersionRegistry.types_module("2025-06-18") == Arbor.MCP.Types.V20250618
    end
  end

  describe "validate_message_version" do
    test "2025-06-18 methods pass: elicitation/create" do
      assert :ok ==
               Protocol.validate_message_version(
                 %{"method" => "elicitation/create"},
                 "2025-06-18"
               )
    end

    test "2025-06-18 methods pass: resources/subscribe" do
      assert :ok ==
               Protocol.validate_message_version(
                 %{"method" => "resources/subscribe"},
                 "2025-06-18"
               )
    end

    test "2025-06-18 methods pass: logging/setLevel" do
      assert :ok ==
               Protocol.validate_message_version(%{"method" => "logging/setLevel"}, "2025-06-18")
    end

    test "2025-11-25 methods fail: tasks/get" do
      assert {:error, _} =
               Protocol.validate_message_version(%{"method" => "tasks/get"}, "2025-06-18")
    end

    test "2025-11-25 methods fail: tasks/list" do
      assert {:error, _} =
               Protocol.validate_message_version(%{"method" => "tasks/list"}, "2025-06-18")
    end

    test "2025-11-25 methods fail: notifications/tasks/status" do
      assert {:error, _} =
               Protocol.validate_message_version(
                 %{"method" => "notifications/tasks/status"},
                 "2025-06-18"
               )
    end

    test "2025-11-25 methods fail: notifications/elicitation/complete" do
      assert {:error, _} =
               Protocol.validate_message_version(
                 %{"method" => "notifications/elicitation/complete"},
                 "2025-06-18"
               )
    end
  end

  describe "backward compatibility" do
    test "all base features from 2024-11-05 still available" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} from 2024-11-05 should be available in 2025-06-18"
      end
    end

    test "all 2025-03-26 features still available (except batch)" do
      for feature <- [
            :resource_subscription,
            :prompts_list_changed,
            :resources_list_changed,
            :logging_set_level,
            :completion
          ] do
        assert VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} from 2025-03-26 should be available in 2025-06-18"
      end

      # Batch is the exception - removed in 2025-06-18
      refute VersionRegistry.feature_available?("2025-06-18", :batch_processing)
    end

    test "2025-11-25 features are NOT available" do
      for feature <- [:tasks, :icons, :url_elicitation, :tool_calling_in_sampling] do
        refute VersionRegistry.feature_available?("2025-06-18", feature),
               "#{feature} from 2025-11-25 should NOT be available in 2025-06-18"
      end
    end
  end
end
