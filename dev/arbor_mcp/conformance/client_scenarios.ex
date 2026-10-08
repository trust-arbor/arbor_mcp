defmodule Arbor.MCP.Conformance.ClientScenarios do
  @moduledoc false

  alias Arbor.MCP.Testing.SchemaGenerator

  @schema_preservation_scenario "json-schema-2020-12-preservation"
  @schema_tool "json_schema_2020_12_tool"
  @schema_echo_tool "json_schema_echo"

  @spec tool_calls([map()], String.t(), map()) :: [{map(), map()}]
  def tool_calls(tools, @schema_preservation_scenario, _context) do
    schema_tool = fetch_tool!(tools, @schema_tool)
    echo_tool = fetch_tool!(tools, @schema_echo_tool)
    schema = Map.fetch!(schema_tool, "inputSchema")

    unless is_map(schema) do
      raise ArgumentError, "#{@schema_tool} returned a non-object inputSchema"
    end

    [{echo_tool, %{"schema" => schema}}]
  end

  def tool_calls(tools, _scenario, %{"toolCalls" => calls}) when is_list(calls) do
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    Enum.flat_map(calls, fn call ->
      case Map.fetch(tools_by_name, call["name"]) do
        {:ok, tool} -> [{tool, call["arguments"] || %{}}]
        :error -> []
      end
    end)
  end

  def tool_calls(tools, _scenario, _context) do
    Enum.map(tools, fn tool ->
      {tool, SchemaGenerator.generate_args(tool["inputSchema"])}
    end)
  end

  defp fetch_tool!(tools, name) do
    Enum.find(tools, &(&1["name"] == name)) ||
      raise ArgumentError, "conformance server did not advertise #{name}"
  end
end
