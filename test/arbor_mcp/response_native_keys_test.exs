defmodule Arbor.MCP.ResponseNativeKeysTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Response

  test "descriptor accessors support native keys while canonical string presence wins" do
    tool = %{
      name: "echo",
      description: "Echo",
      inputSchema: %{properties: %{message: %{type: "string"}}}
    }

    assert Response.tool_name(tool) == "echo"
    assert Response.tool_description(tool) == "Echo"
    assert Response.tool_input_schema(tool) == tool.inputSchema
    assert Response.schema_property(tool.inputSchema, "message") == %{type: "string"}
    assert Response.schema_property(%{"properties" => %{"message" => false}}, :message) == false
    assert Response.schema_property(%{properties: %{message: false}}, "message") == false
    assert Response.schema_property(tool.inputSchema, "unknown-property") == nil

    assert Response.schema_property(
             %{"properties" => nil, properties: %{message: false}},
             "message"
           ) == nil

    assert Response.tool_name(Map.put(tool, "name", nil)) == nil
    assert Response.tool_input_schema(Map.put(tool, "inputSchema", false)) == false
  end

  test "native content retains text, binary data, annotations, extensions and null presence" do
    raw = %{
      "content" => [
        %{"extension" => false, type: "text", text: "hello", annotations: nil},
        %{"mimeType" => "image/png", type: "image", data: "encoded"},
        %{"type" => "text", text: "mixed", annotations: false},
        %{"text" => nil, type: "text", text: "fallback"}
      ]
    }

    response = Response.from_raw_response(raw)
    assert Response.text_content(response) == "hello"

    expected = %{
      "content" => [
        %{"extension" => false, "type" => "text", "text" => "hello", "annotations" => nil},
        %{"mimeType" => "image/png", "type" => "image", "data" => "encoded"},
        %{"type" => "text", "text" => "mixed", "annotations" => false},
        %{"type" => "text", "text" => nil}
      ]
    }

    assert Response.to_raw(response) == expected
  end
end
