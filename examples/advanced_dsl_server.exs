#!/usr/bin/env elixir

# Advanced MCP server using the modern Arbor.MCP Handler + DSL API.

Mix.install([
  {:arbor_mcp, path: Path.expand("..", __DIR__)}
])

defmodule AdvancedServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "advanced-server", version: "1.0.0"

  @impl true
  def init(_args) do
    {:ok,
     %{
       documents: %{
         "readme" => "# Project README\n\nWelcome to the project.",
         "config" => ~s({"port":8080,"enabled":true})
       }
     }}
  end

  tool "analyze_data", "Analyzes a list of numbers" do
    title("Analyze Data")
    param(:data, {:array, :number}, required: true, description: "Numbers to analyze")
    param(:method, :string, default: "all", description: "mean, median, or all")
    param(:precision, :integer, default: 2)

    output_schema(%{
      type: "object",
      properties: %{
        count: %{type: "integer"},
        result: %{type: "object"}
      },
      required: ["count", "result"]
    })

    # ToolResult is aliased by `use Arbor.MCP.Server.DSL`
    run(fn %{data: data, method: method, precision: precision}, state ->
      result =
        data
        |> Enum.map(&to_number/1)
        |> analyze(method, precision)

      {:ok,
       ToolResult.structured("Analyzed #{length(data)} values.", %{
         count: length(data),
         result: result
       }), state}
    end)
  end

  tool "transform_text", "Transforms text through a list of operations" do
    title("Transform Text")
    param(:text, :string, required: true)
    param(:operations, {:array, :string}, default: ["uppercase"])

    run(fn %{text: text, operations: operations}, state ->
      transformed =
        operations
        |> List.wrap()
        |> Enum.reduce(text, &apply_operation/2)

      {:ok,
       ToolResult.structured("Transformation complete.", %{
         original: text,
         transformed: transformed,
         operations: operations
       }), state}
    end)
  end

  resource_template "doc://project/{name}", "Project documents" do
    title("Project Document")
    mime_type("text/plain")
    param(:name, :string)

    read(fn %{name: name, uri: uri}, state ->
      case Map.fetch(state.documents, name) do
        {:ok, content} -> {:ok, %{uri: uri, text: content}, state}
        :error -> {:error, "Unknown document: #{name}", state}
      end
    end)
  end

  resource "config://app", "Application configuration" do
    title("Application Config")
    mime_type("application/json")
    annotations(%{audience: ["assistant"], priority: 0.8})

    read(fn %{uri: uri}, state ->
      {:ok, %{uri: uri, text: state.documents["config"]}, state}
    end)
  end

  prompt "code_assistant", "Creates a coding assistant prompt" do
    title("Code Assistant")
    arg(:language, required: true, description: "Programming language")
    arg(:task, required: true, description: "What to implement")
    arg(:style, description: "Coding style preferences")

    render(fn %{language: language, task: task} = args, state ->
      style = Map.get(args, :style, "clean and readable")

      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: "Write #{style} #{language} code for this task:\n\n#{task}"
             }
           }
         ]
       }, state}
    end)
  end

  defp to_number(value) when is_number(value), do: value
  defp to_number(value) when is_binary(value), do: String.to_float(value)

  defp analyze([], _method, _precision), do: %{}

  defp analyze(data, "mean", precision), do: %{mean: mean(data, precision)}
  defp analyze(data, "median", precision), do: %{median: median(data, precision)}

  defp analyze(data, _method, precision) do
    %{
      mean: mean(data, precision),
      median: median(data, precision),
      min: Enum.min(data),
      max: Enum.max(data)
    }
  end

  defp mean(data, precision) do
    data
    |> Enum.sum()
    |> Kernel./(length(data))
    |> Float.round(precision)
  end

  defp median(data, precision) do
    sorted = Enum.sort(data)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      0 -> Float.round((Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2, precision)
      1 -> Enum.at(sorted, middle)
    end
  end

  defp apply_operation("uppercase", text), do: String.upcase(text)
  defp apply_operation("lowercase", text), do: String.downcase(text)
  defp apply_operation("reverse", text), do: String.reverse(text)
  defp apply_operation("base64", text), do: Base.encode64(text)
  defp apply_operation(_unknown, text), do: text
end

defmodule AdvancedServerRunner do
  def run do
    IO.puts("Starting Advanced MCP Server on stdio.")
    IO.puts("Tools: analyze_data, transform_text")
    IO.puts("Resources: config://app, doc://project/{name}")
    IO.puts("Prompt: code_assistant")

    {:ok, _server} = AdvancedServer.start_link(transport: :stdio)
    Process.sleep(:infinity)
  end
end

if System.get_env("MCP_ENV") != "test" do
  AdvancedServerRunner.run()
end
