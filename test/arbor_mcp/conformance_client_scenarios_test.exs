defmodule Arbor.MCP.Conformance.ClientScenariosTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Conformance.ClientScenarios

  @rich_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$defs" => %{
      "address" => %{
        "$anchor" => "address",
        "type" => "object"
      }
    },
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "additionalProperties" => false,
    "allOf" => [%{"anyOf" => [%{"required" => ["name"]}]}],
    "if" => %{"required" => ["name"]},
    "then" => %{"properties" => %{"name" => %{"minLength" => 1}}},
    "else" => %{"maxProperties" => 0}
  }

  test "the schema-preservation scenario echoes the complete advertised schema" do
    schema_tool = %{
      "name" => "json_schema_2020_12_tool",
      "inputSchema" => @rich_schema
    }

    echo_tool = %{
      "name" => "json_schema_echo",
      "inputSchema" => %{"type" => "object"}
    }

    assert [{^echo_tool, %{"schema" => echoed_schema}}] =
             ClientScenarios.tool_calls(
               [schema_tool, echo_tool],
               "json-schema-2020-12-preservation",
               %{}
             )

    assert echoed_schema == @rich_schema
  end

  test "explicit conformance tool calls retain their supplied arguments" do
    tool = %{"name" => "requested", "inputSchema" => %{"type" => "object"}}

    context = %{
      "toolCalls" => [
        %{"name" => "requested", "arguments" => %{"value" => 42}},
        %{"name" => "missing", "arguments" => %{}}
      ]
    }

    assert [{^tool, %{"value" => 42}}] =
             ClientScenarios.tool_calls([tool], "tool-call-scenario", context)
  end

  test "ordinary scenarios generate arguments from each advertised schema" do
    tool = %{
      "name" => "generated",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"count" => %{"type" => "integer"}}
      }
    }

    assert [{^tool, %{"count" => 1}}] =
             ClientScenarios.tool_calls([tool], "ordinary-scenario", %{})
  end
end
