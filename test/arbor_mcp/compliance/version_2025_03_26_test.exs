defmodule Arbor.MCP.Compliance.Version20250326Test do
  @moduledoc """
  Tests for MCP protocol version 2025-03-26 compliance.

  Validates version negotiation, capability advertisement, method availability,
  feature registry, and backward compatibility for the 2025-03-26 specification
  which introduces batch processing and completions support.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Internal.{Protocol, VersionRegistry}
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  describe "version support" do
    test "2025-03-26 is a supported version in VersionRegistry" do
      assert VersionRegistry.supported?("2025-03-26")
    end

    test "2025-03-26 is a supported version in VersionNegotiator" do
      assert VersionNegotiator.supported?("2025-03-26")
    end

    test "2025-03-26 is not the newest legacy revision in VersionRegistry" do
      refute VersionRegistry.latest_version() == "2025-03-26"
    end

    test "2025-03-26 is not the newest legacy revision in VersionNegotiator" do
      refute VersionNegotiator.latest_version() == "2025-03-26"
    end

    test "2025-03-26 appears in the list of supported versions" do
      assert "2025-03-26" in VersionRegistry.supported_versions()
      assert "2025-03-26" in VersionNegotiator.supported_versions()
    end
  end

  describe "version negotiation" do
    test "server negotiates 2025-03-26 when it is the only offered version" do
      assert {:ok, "2025-03-26"} = VersionNegotiator.negotiate(["2025-03-26"])
    end

    test "server negotiates 2025-03-26 when client offers 2025-03-26 and 2024-11-05" do
      assert {:ok, "2025-03-26"} =
               VersionNegotiator.negotiate(["2025-03-26", "2024-11-05"])
    end

    test "server picks the newest legacy revision when client offers all four" do
      assert {:ok, "2025-11-25"} =
               VersionNegotiator.negotiate([
                 "2024-11-05",
                 "2025-03-26",
                 "2025-06-18",
                 "2025-11-25"
               ])
    end

    test "VersionRegistry negotiate_version works for 2025-03-26" do
      server_versions = VersionRegistry.supported_versions()

      assert {:ok, "2025-03-26"} =
               VersionRegistry.negotiate_version("2025-03-26", server_versions)
    end
  end

  describe "canonical capabilities for 2025-03-26" do
    test "canonical initialization retains version-specific capabilities" do
      result = LegacyInitialize.result("2025-03-26")

      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"]["name"] == "Arbor.MCP"

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2025-03-26")
               )

      assert result["capabilities"]["experimental"]["batchProcessing"]
    end
  end

  describe "method availability" do
    test "initialize is available" do
      assert Protocol.method_available?("initialize", "2025-03-26")
    end

    test "tools/list is available" do
      assert Protocol.method_available?("tools/list", "2025-03-26")
    end

    test "tools/call is available" do
      assert Protocol.method_available?("tools/call", "2025-03-26")
    end

    test "resources/list is available" do
      assert Protocol.method_available?("resources/list", "2025-03-26")
    end

    test "resources/read is available" do
      assert Protocol.method_available?("resources/read", "2025-03-26")
    end

    test "prompts/list is available" do
      assert Protocol.method_available?("prompts/list", "2025-03-26")
    end

    test "prompts/get is available" do
      assert Protocol.method_available?("prompts/get", "2025-03-26")
    end

    test "ping is available" do
      assert Protocol.method_available?("ping", "2025-03-26")
    end

    test "sampling/createMessage is available" do
      assert Protocol.method_available?("sampling/createMessage", "2025-03-26")
    end

    test "completion/complete is available" do
      assert Protocol.method_available?("completion/complete", "2025-03-26")
    end

    test "resources/subscribe is available" do
      assert Protocol.method_available?("resources/subscribe", "2025-03-26")
    end

    test "resources/unsubscribe is available" do
      assert Protocol.method_available?("resources/unsubscribe", "2025-03-26")
    end

    test "logging/setLevel is available" do
      assert Protocol.method_available?("logging/setLevel", "2025-03-26")
    end

    test "notifications/resources/updated is available" do
      assert Protocol.method_available?("notifications/resources/updated", "2025-03-26")
    end

    test "elicitation/create is NOT available" do
      refute Protocol.method_available?("elicitation/create", "2025-03-26")
    end

    test "tasks/get is NOT available" do
      refute Protocol.method_available?("tasks/get", "2025-03-26")
    end

    test "tasks/list is NOT available" do
      refute Protocol.method_available?("tasks/list", "2025-03-26")
    end

    test "tasks/result is NOT available" do
      refute Protocol.method_available?("tasks/result", "2025-03-26")
    end

    test "tasks/cancel is NOT available" do
      refute Protocol.method_available?("tasks/cancel", "2025-03-26")
    end

    test "notifications/tasks/status is NOT available" do
      refute Protocol.method_available?("notifications/tasks/status", "2025-03-26")
    end

    test "notifications/elicitation/complete is NOT available" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2025-03-26")
    end
  end

  describe "feature registry" do
    test "base features are available" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2025-03-26", feature),
               "#{feature} should be available in 2025-03-26"
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
        assert VersionRegistry.feature_available?("2025-03-26", feature),
               "#{feature} should be available in 2025-03-26"
      end
    end

    test "batch_processing is available (unique to 2025-03-26)" do
      assert VersionRegistry.feature_available?("2025-03-26", :batch_processing)
    end

    test "elicitation is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :elicitation)
    end

    test "structured_content is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :structured_content)
    end

    test "tool_output_schema is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :tool_output_schema)
    end

    test "tasks is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :tasks)
    end

    test "icons is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :icons)
    end

    test "url_elicitation is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :url_elicitation)
    end

    test "tool_calling_in_sampling is NOT available" do
      refute VersionRegistry.feature_available?("2025-03-26", :tool_calling_in_sampling)
    end
  end

  describe "capabilities_for_version" do
    test "prompts includes listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.prompts == %{listChanged: true}
    end

    test "resources includes subscribe: true and listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.resources.subscribe == true
      assert caps.resources.listChanged == true
    end

    test "tools is an empty map (no outputSchema yet)" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.tools == %{}
    end

    test "logging is an empty map (presence indicator per spec)" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.logging == %{}
    end

    test "completions is an empty map (presence indicator per spec)" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert Map.has_key?(caps, :completions)
      assert caps.completions == %{}
    end

    test "experimental includes batchProcessing: true" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.experimental.batchProcessing == true
    end

    test "does NOT have a tasks key" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      refute Map.has_key?(caps, :tasks)
    end
  end

  describe "batch processing is unique to 2025-03-26" do
    test "batch_processing feature is available in 2025-03-26" do
      assert VersionRegistry.feature_available?("2025-03-26", :batch_processing)
    end

    test "batch_processing feature is NOT available in 2024-11-05" do
      refute VersionRegistry.feature_available?("2024-11-05", :batch_processing)
    end

    test "batch_processing feature is NOT available in 2025-06-18 (removed)" do
      refute VersionRegistry.feature_available?("2025-06-18", :batch_processing)
    end

    test "batch_processing feature is NOT available in 2025-11-25" do
      refute VersionRegistry.feature_available?("2025-11-25", :batch_processing)
    end

    test "capabilities_for_version 2025-03-26 has batchProcessing true" do
      caps = VersionRegistry.capabilities_for_version("2025-03-26")
      assert caps.experimental.batchProcessing == true
    end

    test "capabilities_for_version 2025-06-18 has batchProcessing false" do
      caps = VersionRegistry.capabilities_for_version("2025-06-18")
      assert caps.experimental.batchProcessing == false
    end
  end

  describe "message_format" do
    test "supports_batch is true (unique to 2025-03-26)" do
      format = VersionRegistry.message_format("2025-03-26")
      assert format.supports_batch == true
    end

    test "supports_progress is true" do
      format = VersionRegistry.message_format("2025-03-26")
      assert format.supports_progress == true
    end

    test "supports_cancellation is true" do
      format = VersionRegistry.message_format("2025-03-26")
      assert format.supports_cancellation == true
    end

    test "notification_methods includes notifications/resources/updated (new)" do
      format = VersionRegistry.message_format("2025-03-26")
      assert "notifications/resources/updated" in format.notification_methods
    end

    test "notification_methods includes notifications/roots/list_changed" do
      format = VersionRegistry.message_format("2025-03-26")
      assert "notifications/roots/list_changed" in format.notification_methods
    end

    test "logging/setLevel is a request method, NOT a notification method" do
      format = VersionRegistry.message_format("2025-03-26")
      refute "logging/setLevel" in format.notification_methods
    end

    test "notification_methods includes all base methods" do
      format = VersionRegistry.message_format("2025-03-26")

      assert "notifications/initialized" in format.notification_methods
      assert "notifications/tools/list_changed" in format.notification_methods
      assert "notifications/resources/list_changed" in format.notification_methods
      assert "notifications/prompts/list_changed" in format.notification_methods
      assert "notifications/progress" in format.notification_methods
      assert "notifications/message" in format.notification_methods
      assert "notifications/cancelled" in format.notification_methods
    end

    test "notification_methods does NOT include notifications/tasks/status" do
      format = VersionRegistry.message_format("2025-03-26")
      refute "notifications/tasks/status" in format.notification_methods
    end

    test "notification_methods does NOT include notifications/elicitation/complete" do
      format = VersionRegistry.message_format("2025-03-26")
      refute "notifications/elicitation/complete" in format.notification_methods
    end
  end

  describe "type module" do
    test "types_module for 2025-03-26 returns Arbor.MCP.Types.V20250326" do
      assert VersionRegistry.types_module("2025-03-26") == Arbor.MCP.Types.V20250326
    end
  end

  describe "validate_message_version" do
    test "2025-03-26 methods pass: resources/subscribe" do
      assert :ok ==
               Protocol.validate_message_version(
                 %{"method" => "resources/subscribe"},
                 "2025-03-26"
               )
    end

    test "2025-03-26 methods pass: resources/unsubscribe" do
      assert :ok ==
               Protocol.validate_message_version(
                 %{"method" => "resources/unsubscribe"},
                 "2025-03-26"
               )
    end

    test "2025-03-26 methods pass: logging/setLevel" do
      assert :ok ==
               Protocol.validate_message_version(%{"method" => "logging/setLevel"}, "2025-03-26")
    end

    test "2025-03-26 methods pass: notifications/resources/updated" do
      assert :ok ==
               Protocol.validate_message_version(
                 %{"method" => "notifications/resources/updated"},
                 "2025-03-26"
               )
    end

    test "2025-06-18+ methods fail: elicitation/create" do
      assert {:error, _message} =
               Protocol.validate_message_version(
                 %{"method" => "elicitation/create"},
                 "2025-03-26"
               )
    end

    test "2025-11-25 methods fail: tasks/get" do
      assert {:error, _message} =
               Protocol.validate_message_version(%{"method" => "tasks/get"}, "2025-03-26")
    end

    test "2025-11-25 methods fail: tasks/list" do
      assert {:error, _message} =
               Protocol.validate_message_version(%{"method" => "tasks/list"}, "2025-03-26")
    end

    test "2025-11-25 methods fail: tasks/result" do
      assert {:error, _message} =
               Protocol.validate_message_version(%{"method" => "tasks/result"}, "2025-03-26")
    end

    test "2025-11-25 methods fail: tasks/cancel" do
      assert {:error, _message} =
               Protocol.validate_message_version(%{"method" => "tasks/cancel"}, "2025-03-26")
    end

    test "2025-11-25 methods fail: notifications/tasks/status" do
      assert {:error, _message} =
               Protocol.validate_message_version(
                 %{"method" => "notifications/tasks/status"},
                 "2025-03-26"
               )
    end

    test "2025-11-25 methods fail: notifications/elicitation/complete" do
      assert {:error, _message} =
               Protocol.validate_message_version(
                 %{"method" => "notifications/elicitation/complete"},
                 "2025-03-26"
               )
    end
  end

  describe "backward compatibility from 2025-03-26" do
    test "all 2024-11-05 base methods are still available" do
      for method <- [
            "initialize",
            "tools/list",
            "tools/call",
            "resources/list",
            "resources/read",
            "prompts/list",
            "prompts/get",
            "ping",
            "sampling/createMessage",
            "completion/complete"
          ] do
        assert Protocol.method_available?(method, "2025-03-26"),
               "#{method} should be available in 2025-03-26"
      end
    end

    test "base features are still available" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2025-03-26", feature),
               "#{feature} should be available in 2025-03-26"
      end
    end
  end
end
