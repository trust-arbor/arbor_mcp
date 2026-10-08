defmodule Arbor.MCP.Internal.ProtocolProgressTest do
  use ExUnit.Case

  @moduletag :internal
  @moduletag :compliance

  alias Arbor.MCP.Internal.Protocol

  describe "progress notification encoding" do
    test "encodes progress notification with token and progress only" do
      token = "operation-123"
      progress = 42

      notification = Protocol.encode_progress(token, progress)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/progress"
      assert notification["params"]["progressToken"] == token
      assert notification["params"]["progress"] == progress
      refute Map.has_key?(notification["params"], "total")
      refute Map.has_key?(notification, "id")
    end

    test "encodes progress notification with total" do
      token = "download-456"
      progress = 75
      total = 100

      notification = Protocol.encode_progress(token, progress, total)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/progress"
      assert notification["params"]["progressToken"] == token
      assert notification["params"]["progress"] == progress
      assert notification["params"]["total"] == total
      refute Map.has_key?(notification, "id")
    end

    test "supports integer progress tokens" do
      token = 12345
      progress = 50.5

      notification = Protocol.encode_progress(token, progress)

      assert notification["params"]["progressToken"] == token
      assert notification["params"]["progress"] == 50.5
    end

    test "supports float progress values" do
      token = "task-789"
      progress = 33.33
      total = 100.0

      notification = Protocol.encode_progress(token, progress, total)

      assert notification["params"]["progress"] == 33.33
      assert notification["params"]["total"] == 100.0
    end

    test "encodes progress notification with message" do
      token = "operation-001"
      progress = 25
      total = 100
      message = "Processing batch 1 of 4"

      notification = Protocol.encode_progress(token, progress, total, message)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/progress"
      assert notification["params"]["progressToken"] == token
      assert notification["params"]["progress"] == progress
      assert notification["params"]["total"] == total
      assert notification["params"]["message"] == message
    end

    test "encodes progress notification with message but no total" do
      token = "stream-processing"
      progress = 1024
      message = "Processed 1024 records"

      notification = Protocol.encode_progress(token, progress, nil, message)

      assert notification["params"]["progressToken"] == token
      assert notification["params"]["progress"] == progress
      assert notification["params"]["message"] == message
      refute Map.has_key?(notification["params"], "total")
    end
  end

  describe "request with progress token" do
    test "encodes tool call without progress token" do
      encoded = Protocol.encode_call_tool("my_tool", %{"arg" => "value"})

      assert encoded["method"] == "tools/call"
      assert encoded["params"]["name"] == "my_tool"
      assert encoded["params"]["arguments"] == %{"arg" => "value"}
      refute Map.has_key?(encoded["params"], "_meta")
    end

    test "encodes tool call with progress token" do
      token = "tool-exec-001"
      encoded = Protocol.encode_call_tool("my_tool", %{"arg" => "value"}, token)

      assert encoded["method"] == "tools/call"
      assert encoded["params"]["name"] == "my_tool"
      assert encoded["params"]["arguments"] == %{"arg" => "value"}
      assert get_in(encoded["params"], ["_meta", "progressToken"]) == token
    end
  end

  describe "progress notification parsing" do
    test "parses progress notification" do
      json =
        ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"abc","progress":50}})

      assert {:notification, "notifications/progress", params} = Protocol.parse_message(json)
      assert params["progressToken"] == "abc"
      assert params["progress"] == 50
    end

    test "parses progress notification with total" do
      json =
        ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"xyz","progress":75,"total":100}})

      assert {:notification, "notifications/progress", params} = Protocol.parse_message(json)
      assert params["progressToken"] == "xyz"
      assert params["progress"] == 75
      assert params["total"] == 100
    end
  end
end
