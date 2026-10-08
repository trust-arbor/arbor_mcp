defmodule Arbor.MCP.Internal.ProtocolNotificationsTest do
  use ExUnit.Case

  @moduletag :internal
  @moduletag :compliance

  alias Arbor.MCP.Internal.Protocol

  describe "change notification encoding" do
    test "encodes resources list changed notification" do
      notification = Protocol.encode_resources_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/resources/list_changed"
      assert notification["params"] == %{}
      refute Map.has_key?(notification, "id")
    end

    test "encodes tools list changed notification" do
      notification = Protocol.encode_tools_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/tools/list_changed"
      assert notification["params"] == %{}
      refute Map.has_key?(notification, "id")
    end

    test "encodes prompts list changed notification" do
      notification = Protocol.encode_prompts_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/prompts/list_changed"
      assert notification["params"] == %{}
      refute Map.has_key?(notification, "id")
    end

    test "encodes resource updated notification" do
      uri = "file:///path/to/resource.txt"
      notification = Protocol.encode_resource_updated(uri)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/resources/updated"
      assert notification["params"]["uri"] == uri
      refute Map.has_key?(notification, "id")
    end

    test "generic notification encoding" do
      method = "custom/notification"
      params = %{"key" => "value", "number" => 42}

      notification = Protocol.encode_notification(method, params)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == method
      assert notification["params"] == params
      refute Map.has_key?(notification, "id")
    end
  end

  describe "notification parsing" do
    test "parses resources list changed notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}})

      assert {:notification, "notifications/resources/list_changed", %{}} =
               Protocol.parse_message(json)
    end

    test "parses resource updated notification" do
      json =
        ~s({"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///test.txt"}})

      assert {:notification, "notifications/resources/updated", %{"uri" => "file:///test.txt"}} =
               Protocol.parse_message(json)
    end

    test "parses tools list changed notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}})

      assert {:notification, "notifications/tools/list_changed", %{}} =
               Protocol.parse_message(json)
    end

    test "parses prompts list changed notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{}})

      assert {:notification, "notifications/prompts/list_changed", %{}} =
               Protocol.parse_message(json)
    end
  end
end
