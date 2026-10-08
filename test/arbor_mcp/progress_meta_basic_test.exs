defmodule Arbor.MCP.ProgressMetaBasicTest do
  use ExUnit.Case, async: true

  @moduletag :progress

  alias Arbor.MCP.Internal.Protocol

  describe "Protocol _meta support" do
    test "encode_list_tools includes _meta when provided" do
      encoded = Protocol.encode_list_tools(nil, %{"progressToken" => "test123"})
      assert encoded["params"]["_meta"] == %{"progressToken" => "test123"}
    end

    test "encode_call_tool includes _meta when provided as map" do
      encoded =
        Protocol.encode_call_tool("test", %{"arg" => "value"}, %{"progressToken" => "test123"})

      assert encoded["params"]["_meta"] == %{"progressToken" => "test123"}
    end

    test "encode_call_tool includes _meta when provided as progress token string" do
      encoded = Protocol.encode_call_tool("test", %{"arg" => "value"}, "test123")
      assert encoded["params"]["_meta"] == %{"progressToken" => "test123"}
    end

    test "encode_list_resources includes _meta when provided" do
      encoded = Protocol.encode_list_resources("cursor", %{"progressToken" => "test123"})
      assert encoded["params"]["_meta"] == %{"progressToken" => "test123"}
    end

    test "encode_list_prompts includes _meta when provided" do
      encoded = Protocol.encode_list_prompts(nil, %{"custom" => "field"})
      assert encoded["params"]["_meta"] == %{"custom" => "field"}
    end

    test "encode_get_prompt includes _meta when provided" do
      encoded = Protocol.encode_get_prompt("prompt_name", %{}, %{"token" => "abc"})
      assert encoded["params"]["_meta"] == %{"token" => "abc"}
    end

    test "encode_complete includes _meta when provided" do
      encoded = Protocol.encode_complete("ref", "arg", %{"requestId" => "123"})
      assert encoded["params"]["_meta"] == %{"requestId" => "123"}
    end

    test "encode_create_message includes _meta when provided" do
      params = %{"messages" => []}
      encoded = Protocol.encode_create_message(params, %{"traceId" => "xyz"})
      assert encoded["params"]["_meta"] == %{"traceId" => "xyz"}
    end
  end
end
