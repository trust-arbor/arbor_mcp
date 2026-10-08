defmodule Arbor.MCP.Internal.ProtocolBatchTest do
  use ExUnit.Case

  @moduletag :internal
  @moduletag :compliance

  alias Arbor.MCP.Internal.Protocol

  describe "batch request encoding" do
    test "encodes a batch of requests" do
      batch = [
        Protocol.encode_list_tools(),
        Protocol.encode_list_resources(),
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => Protocol.generate_id()}
      ]

      encoded = Protocol.encode_batch(batch)

      assert is_list(encoded)
      assert length(encoded) == 3
      assert Enum.at(encoded, 0)["method"] == "tools/list"
      assert Enum.at(encoded, 0)["id"] != nil
      assert Enum.at(encoded, 1)["method"] == "resources/list"
      assert Enum.at(encoded, 1)["id"] != nil
      assert Enum.at(encoded, 2)["method"] == "ping"
      assert Enum.at(encoded, 2)["id"] != nil
    end

    test "encodes mixed requests and notifications" do
      batch = [
        Protocol.encode_list_tools(),
        Protocol.encode_notification("initialized", %{}),
        Protocol.encode_list_resources()
      ]

      encoded = Protocol.encode_batch(batch)

      assert length(encoded) == 3
      assert Enum.at(encoded, 0)["id"] != nil
      refute Map.has_key?(Enum.at(encoded, 1), "id")
      assert Enum.at(encoded, 2)["id"] != nil
    end
  end

  describe "batch response parsing" do
    test "parses a batch of responses" do
      responses = [
        %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1},
        %{"jsonrpc" => "2.0", "result" => %{"resources" => []}, "id" => 2},
        %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32601, "message" => "Method not found"},
          "id" => 3
        }
      ]

      parsed = Protocol.parse_batch_response(responses)

      assert length(parsed) == 3
      assert {:result, %{"tools" => []}, 1} = Enum.at(parsed, 0)
      assert {:result, %{"resources" => []}, 2} = Enum.at(parsed, 1)

      assert {:error, %{"code" => -32601, "message" => "Method not found"}, 3} =
               Enum.at(parsed, 2)
    end

    test "parses mixed responses and notifications" do
      responses = [
        %{"jsonrpc" => "2.0", "result" => %{"pong" => true}, "id" => 1},
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"progressToken" => "test", "progress" => 50}
        }
      ]

      parsed = Protocol.parse_batch_response(responses)

      assert length(parsed) == 2
      assert {:result, %{"pong" => true}, 1} = Enum.at(parsed, 0)

      assert {:notification, "notifications/progress",
              %{"progressToken" => "test", "progress" => 50}} = Enum.at(parsed, 1)
    end
  end

  describe "batch message parsing" do
    test "detects batch messages" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}, "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "resources/list", "params" => %{}, "id" => 2}
      ]

      assert {:batch, ^batch} = Protocol.parse_message(batch)
    end

    test "handles empty batch" do
      assert {:error, :validation_failed,
              %{code: -32600, message: "Empty batch array is invalid"}} =
               Protocol.parse_message([])
    end
  end
end
