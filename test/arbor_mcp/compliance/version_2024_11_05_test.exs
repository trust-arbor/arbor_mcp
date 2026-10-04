defmodule Arbor.MCP.Compliance.Version20241105Test do
  @moduledoc """
  Tests for MCP protocol version 2024-11-05 compliance.

  Validates version negotiation, capability advertisement, method availability,
  feature registry, and message format for the 2024-11-05 specification
  which is the initial stable (baseline) version of the protocol.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Internal.{Protocol, VersionRegistry}
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  describe "version support" do
    test "2024-11-05 is a supported version in VersionRegistry" do
      assert VersionRegistry.supported?("2024-11-05")
    end

    test "2024-11-05 is a supported version in VersionNegotiator" do
      assert VersionNegotiator.supported?("2024-11-05")
    end

    test "2024-11-05 is not the newest legacy revision in VersionRegistry" do
      refute VersionRegistry.latest_version() == "2024-11-05"
    end

    test "2024-11-05 is not the newest legacy revision in VersionNegotiator" do
      refute VersionNegotiator.latest_version() == "2024-11-05"
    end

    test "2024-11-05 appears in the list of supported versions" do
      assert "2024-11-05" in VersionRegistry.supported_versions()
      assert "2024-11-05" in VersionNegotiator.supported_versions()
    end
  end

  describe "version negotiation" do
    test "server negotiates 2024-11-05 when it is the only offered version" do
      assert {:ok, "2024-11-05"} = VersionNegotiator.negotiate(["2024-11-05"])
    end

    test "when client offers all versions, server picks latest (NOT 2024-11-05)" do
      {:ok, negotiated} =
        VersionNegotiator.negotiate([
          "2024-11-05",
          "2025-03-26",
          "2025-06-18",
          "2025-11-25"
        ])

      refute negotiated == "2024-11-05"
      assert negotiated == VersionNegotiator.latest_version()
    end

    test "when client offers only 2024-11-05, server accepts it" do
      assert {:ok, "2024-11-05"} = VersionNegotiator.negotiate(["2024-11-05"])
    end

    test "VersionRegistry negotiate_version works for 2024-11-05" do
      server_versions = VersionRegistry.supported_versions()

      assert {:ok, "2024-11-05"} =
               VersionRegistry.negotiate_version("2024-11-05", server_versions)
    end
  end

  describe "canonical capabilities for 2024-11-05" do
    test "canonical initialization retains version-specific capabilities" do
      result = LegacyInitialize.result("2024-11-05")

      assert result["protocolVersion"] == "2024-11-05"
      assert result["serverInfo"]["name"] == "Arbor.MCP"

      assert result["capabilities"] ==
               ResultNormalizer.stringify_keys(
                 VersionRegistry.capabilities_for_version("2024-11-05")
               )

      assert result["capabilities"]["experimental"] == %{}
    end
  end

  describe "method availability - base methods" do
    test "initialize is available" do
      assert Protocol.method_available?("initialize", "2024-11-05")
    end

    test "tools/list is available" do
      assert Protocol.method_available?("tools/list", "2024-11-05")
    end

    test "tools/call is available" do
      assert Protocol.method_available?("tools/call", "2024-11-05")
    end

    test "resources/list is available" do
      assert Protocol.method_available?("resources/list", "2024-11-05")
    end

    test "resources/read is available" do
      assert Protocol.method_available?("resources/read", "2024-11-05")
    end

    test "prompts/list is available" do
      assert Protocol.method_available?("prompts/list", "2024-11-05")
    end

    test "prompts/get is available" do
      assert Protocol.method_available?("prompts/get", "2024-11-05")
    end

    test "ping is available" do
      assert Protocol.method_available?("ping", "2024-11-05")
    end

    test "sampling/createMessage is available" do
      assert Protocol.method_available?("sampling/createMessage", "2024-11-05")
    end

    test "completion/complete is available" do
      assert Protocol.method_available?("completion/complete", "2024-11-05")
    end

    test "resources/subscribe is available" do
      assert Protocol.method_available?("resources/subscribe", "2024-11-05")
    end

    test "resources/unsubscribe is available" do
      assert Protocol.method_available?("resources/unsubscribe", "2024-11-05")
    end

    test "logging/setLevel is available" do
      assert Protocol.method_available?("logging/setLevel", "2024-11-05")
    end

    test "notifications/resources/updated is available" do
      assert Protocol.method_available?("notifications/resources/updated", "2024-11-05")
    end

    test "elicitation/create is NOT available" do
      refute Protocol.method_available?("elicitation/create", "2024-11-05")
    end

    test "tasks/get is NOT available" do
      refute Protocol.method_available?("tasks/get", "2024-11-05")
    end

    test "tasks/list is NOT available" do
      refute Protocol.method_available?("tasks/list", "2024-11-05")
    end

    test "tasks/result is NOT available" do
      refute Protocol.method_available?("tasks/result", "2024-11-05")
    end

    test "tasks/cancel is NOT available" do
      refute Protocol.method_available?("tasks/cancel", "2024-11-05")
    end

    test "notifications/tasks/status is NOT available" do
      refute Protocol.method_available?("notifications/tasks/status", "2024-11-05")
    end

    test "notifications/elicitation/complete is NOT available" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2024-11-05")
    end
  end

  describe "feature registry" do
    test "base features are available" do
      for feature <- [:prompts, :resources, :tools, :logging] do
        assert VersionRegistry.feature_available?("2024-11-05", feature),
               "#{feature} should be available in 2024-11-05"
      end
    end

    test "resource_subscription is available" do
      assert VersionRegistry.feature_available?("2024-11-05", :resource_subscription)
    end

    test "prompts_list_changed is available" do
      assert VersionRegistry.feature_available?("2024-11-05", :prompts_list_changed)
    end

    test "resources_list_changed is available" do
      assert VersionRegistry.feature_available?("2024-11-05", :resources_list_changed)
    end

    test "logging_set_level is available" do
      assert VersionRegistry.feature_available?("2024-11-05", :logging_set_level)
    end

    test "completion is available" do
      assert VersionRegistry.feature_available?("2024-11-05", :completion)
    end

    test "batch_processing is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :batch_processing)
    end

    test "elicitation is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :elicitation)
    end

    test "structured_content is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :structured_content)
    end

    test "tool_output_schema is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :tool_output_schema)
    end

    test "tasks is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :tasks)
    end

    test "icons is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :icons)
    end

    test "url_elicitation is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :url_elicitation)
    end

    test "tool_calling_in_sampling is NOT available" do
      refute VersionRegistry.feature_available?("2024-11-05", :tool_calling_in_sampling)
    end
  end

  describe "capabilities_for_version" do
    test "prompts has listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      assert caps.prompts == %{listChanged: true}
    end

    test "resources has subscribe: true, listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      assert caps.resources == %{subscribe: true, listChanged: true}
    end

    test "tools has listChanged: true" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      assert caps.tools == %{listChanged: true}
    end

    test "logging is an empty map (just an object indicating support)" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      assert caps.logging == %{}
    end

    test "experimental is an empty map" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      assert caps.experimental == %{}
    end

    test "no completion key" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      refute Map.has_key?(caps, :completion)
    end

    test "no tasks key" do
      caps = VersionRegistry.capabilities_for_version("2024-11-05")
      refute Map.has_key?(caps, :tasks)
    end
  end

  describe "message_format" do
    test "supports_batch is false" do
      format = VersionRegistry.message_format("2024-11-05")
      assert format.supports_batch == false
    end

    test "supports_progress is true" do
      format = VersionRegistry.message_format("2024-11-05")
      assert format.supports_progress == true
    end

    test "supports_cancellation is true" do
      format = VersionRegistry.message_format("2024-11-05")
      assert format.supports_cancellation == true
    end

    test "has basic notification_methods" do
      format = VersionRegistry.message_format("2024-11-05")

      assert "notifications/initialized" in format.notification_methods
      assert "notifications/tools/list_changed" in format.notification_methods
      assert "notifications/resources/list_changed" in format.notification_methods
      assert "notifications/prompts/list_changed" in format.notification_methods
      assert "notifications/progress" in format.notification_methods
      assert "notifications/message" in format.notification_methods
      assert "notifications/cancelled" in format.notification_methods
    end

    test "has notifications/resources/updated" do
      format = VersionRegistry.message_format("2024-11-05")
      assert "notifications/resources/updated" in format.notification_methods
    end

    test "has notifications/roots/list_changed" do
      format = VersionRegistry.message_format("2024-11-05")
      assert "notifications/roots/list_changed" in format.notification_methods
    end

    test "does NOT have logging/setLevel in notification_methods (it is a request, not a notification)" do
      format = VersionRegistry.message_format("2024-11-05")
      refute "logging/setLevel" in format.notification_methods
    end

    test "does NOT have notifications/tasks/status" do
      format = VersionRegistry.message_format("2024-11-05")
      refute "notifications/tasks/status" in format.notification_methods
    end

    test "does NOT have notifications/elicitation/complete" do
      format = VersionRegistry.message_format("2024-11-05")
      refute "notifications/elicitation/complete" in format.notification_methods
    end

    test "has an empty request_methods list" do
      format = VersionRegistry.message_format("2024-11-05")
      assert format.request_methods == []
    end
  end

  describe "type module" do
    test "types_module returns Arbor.MCP.Types.V20241105 for 2024-11-05" do
      assert VersionRegistry.types_module("2024-11-05") == Arbor.MCP.Types.V20241105
    end
  end

  describe "validate_message_version" do
    test "base methods pass validation for 2024-11-05" do
      base_methods = [
        "initialize",
        "tools/list",
        "tools/call",
        "resources/list",
        "resources/read",
        "prompts/list",
        "prompts/get",
        "ping",
        "sampling/createMessage",
        "completion/complete",
        # These are all defined in the 2024-11-05 schema
        "resources/subscribe",
        "resources/unsubscribe",
        "logging/setLevel",
        "notifications/resources/updated"
      ]

      for method <- base_methods do
        assert :ok == Protocol.validate_message_version(%{"method" => method}, "2024-11-05"),
               "#{method} should pass validation for 2024-11-05"
      end
    end

    test "elicitation/create fails validation for 2024-11-05" do
      assert {:error, _message} =
               Protocol.validate_message_version(
                 %{"method" => "elicitation/create"},
                 "2024-11-05"
               )
    end

    test "tasks/get fails validation for 2024-11-05" do
      assert {:error, _message} =
               Protocol.validate_message_version(%{"method" => "tasks/get"}, "2024-11-05")
    end

    test "all version-gated methods fail validation for 2024-11-05" do
      gated_methods = [
        "elicitation/create",
        "tasks/get",
        "tasks/list",
        "tasks/result",
        "tasks/cancel",
        "notifications/tasks/status",
        "notifications/elicitation/complete"
      ]

      for method <- gated_methods do
        assert {:error, _message} =
                 Protocol.validate_message_version(%{"method" => method}, "2024-11-05"),
               "#{method} should fail validation for 2024-11-05"
      end
    end
  end
end
