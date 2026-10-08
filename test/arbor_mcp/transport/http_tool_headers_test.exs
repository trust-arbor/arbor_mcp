defmodule Arbor.MCP.Transport.HTTP.ToolHeadersTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.Transport.HTTP.ToolHeaders

  test "compiles nested string, integer, and boolean annotations" do
    tool = %{
      "name" => "query",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => "Region"},
          "options" => %{
            "type" => "object",
            "properties" => %{
              "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"},
              "trace" => %{"type" => "boolean", "x-mcp-header" => "Trace"}
            }
          }
        }
      }
    }

    assert {:ok, annotations} = ToolHeaders.compile(tool)

    assert %{header: "Region", path: ["region"], type: "string"} in annotations
    assert %{header: "Limit", path: ["options", "limit"], type: "integer"} in annotations
    assert %{header: "Trace", path: ["options", "trace"], type: "boolean"} in annotations
  end

  test "compiles annotations from atom-keyed DSL definitions" do
    tool = %{
      name: "query",
      inputSchema: %{
        type: "object",
        properties: %{
          region: %{"x-mcp-header" => "Region", type: "string"}
        }
      }
    }

    assert {:ok, [%{header: "Region", path: ["region"], type: "string"}]} =
             ToolHeaders.compile(tool)
  end

  test "rejects invalid names, unsupported types, duplicates, and unreachable annotations" do
    assert {:error, :invalid_header_name} =
             ToolHeaders.compile(tool_with(%{"type" => "string", "x-mcp-header" => "bad name"}))

    assert {:error, :unsupported_header_value_type} =
             ToolHeaders.compile(tool_with(%{"type" => "number", "x-mcp-header" => "Value"}))

    duplicate = %{
      "name" => "duplicate",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "one" => %{"type" => "string", "x-mcp-header" => "Route"},
          "two" => %{"type" => "string", "x-mcp-header" => "route"}
        }
      }
    }

    assert {:error, :duplicate_header_name} = ToolHeaders.compile(duplicate)

    unreachable =
      tool_with(%{
        "type" => "string",
        "anyOf" => [%{"type" => "string", "x-mcp-header" => "Hidden"}]
      })

    assert {:error, :unreachable_header_annotation} = ToolHeaders.compile(unreachable)
  end

  test "modern tools/list normalization excludes invalid annotated tools" do
    valid = tool_with(%{"type" => "string", "x-mcp-header" => "Region"})
    invalid = tool_with(%{"type" => "array", "x-mcp-header" => "Items"})
    invalid = Map.put(invalid, "name", "invalid")

    result =
      ResultNormalizer.protocol_result(
        %{"tools" => [valid, invalid]},
        %{era: :modern, method: "tools/list"},
        server_info: %{name: "test", version: "1"}
      )

    assert Enum.map(result["tools"], & &1["name"]) == ["tool"]
  end

  test "prepares the filtered and sorted collection before custom pagination" do
    valid_z =
      tool_with(%{"type" => "string", "x-mcp-header" => "Region"})
      |> Map.put("name", "z-last")

    invalid =
      tool_with(%{"type" => "array", "x-mcp-header" => "Items"})
      |> Map.put("name", "a-invalid")

    valid_a =
      tool_with(%{"type" => "string", "x-mcp-header" => "Tenant"})
      |> Map.put("name", "a-first")

    source = ResultNormalizer.prepare_tools_list([valid_z, invalid, valid_a])
    {page, remaining} = Enum.split(source, 1)

    assert Enum.map(page, & &1["name"]) == ["a-first"]
    assert Enum.map(remaining, & &1["name"]) == ["z-last"]
  end

  test "validates mirrored values, including numeric integer comparison" do
    annotations = [
      %{header: "Region", path: ["region"], type: "string"},
      %{header: "Limit", path: ["limit"], type: "integer"},
      %{header: "Trace", path: ["trace"], type: "boolean"}
    ]

    headers = [
      {"mcp-param-region", "us-west1"},
      {"mcp-param-limit", "42.0"},
      {"mcp-param-trace", "false"}
    ]

    assert :ok =
             ToolHeaders.validate_request(
               headers,
               annotations,
               %{"region" => "us-west1", "limit" => 42, "trace" => false}
             )

    assert {:error, message} =
             ToolHeaders.validate_request(
               List.keyreplace(headers, "mcp-param-limit", 0, {"mcp-param-limit", "43"}),
               annotations,
               %{"region" => "us-west1", "limit" => 42, "trace" => false}
             )

    assert message =~ "does not match"
  end

  test "requires present values and rejects headers for missing or null arguments" do
    annotation = [%{header: "Region", path: ["region"], type: "string"}]

    assert {:error, message} = ToolHeaders.validate_request([], annotation, %{"region" => "one"})
    assert message =~ "missing"

    assert {:error, message} =
             ToolHeaders.validate_request(
               [{"mcp-param-region", "one"}],
               annotation,
               %{"region" => nil}
             )

    assert message =~ "omitted"

    assert :ok = ToolHeaders.validate_request([], annotation, %{})
    assert :ok = ToolHeaders.validate_request([], annotation, %{"region" => nil})
  end

  defp tool_with(property_schema) do
    %{
      "name" => "tool",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"value" => property_schema}
      }
    }
  end
end
