defmodule Arbor.MCP.Server.StructuredOutputTest do
  @moduledoc """
  Tests for MCP 2025-06-18 structured tool output.

  Structured results use `Arbor.MCP.Server.Handler` + `Arbor.MCP.Server.DSL`.
  These wire/result assertions remain after the retired Tools family is removed.

  Note the field name: the spec field is `structuredContent`. `structuredOutput`
  is accepted as a legacy alias and normalized to `structuredContent`.
  """
  use ExUnit.Case, async: true

  defmodule TestServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "calculate", "Perform mathematical calculations with structured output" do
      input_schema(%{
        type: "object",
        properties: %{
          expression: %{type: "string"}
        },
        required: ["expression"]
      })

      output_schema(%{
        type: "object",
        properties: %{
          result: %{type: "number"},
          expression: %{type: "string"}
        },
        required: ["result"]
      })

      run(fn %{expression: expr}, state ->
        case eval_expression(expr) do
          {:ok, result} ->
            {:ok,
             %{
               content: [%{type: "text", text: "Result: #{result}"}],
               structuredContent: %{result: result, expression: expr}
             }, state}

          {:error, reason} ->
            {:error, "Calculation failed: #{reason}", state}
        end
      end)
    end

    tool "echo", "Echo input without output schema" do
      input_schema(%{
        type: "object",
        properties: %{
          message: %{type: "string"}
        },
        required: ["message"]
      })

      run(fn %{message: msg}, state ->
        {:ok, %{content: [%{type: "text", text: msg}]}, state}
      end)
    end

    tool "structured_only", "Returns only structured content" do
      input_schema(%{
        type: "object",
        properties: %{
          data: %{type: "string"}
        }
      })

      output_schema(%{
        type: "object",
        properties: %{
          processed: %{type: "string"},
          timestamp: %{type: "integer"}
        },
        required: ["processed"]
      })

      run(fn %{data: data}, state ->
        {:ok,
         %{
           structuredContent: %{
             processed: String.upcase(data),
             timestamp: System.system_time(:second)
           }
         }, state}
      end)
    end

    tool "invalid_output", "Tool that returns invalid structured content" do
      input_schema(%{
        type: "object",
        properties: %{
          value: %{type: "string"}
        }
      })

      output_schema(%{
        type: "object",
        properties: %{
          result: %{type: "number"}
        },
        required: ["result"]
      })

      run(fn _args, state ->
        {:ok,
         %{
           content: [%{type: "text", text: "Invalid output"}],
           # Invalid per schema
           structuredContent: %{result: "not a number"}
         }, state}
      end)
    end

    tool "legacy_structured_output", "Tool using the legacy structuredOutput field" do
      input_schema(%{
        type: "object",
        properties: %{
          input: %{type: "string"}
        }
      })

      run(fn %{input: input}, state ->
        {:ok,
         %{
           content: [%{type: "text", text: "Processing..."}],
           # Legacy field, normalized to structuredContent
           structuredOutput: %{output: input}
         }, state}
      end)
    end

    defp eval_expression("2+2"), do: {:ok, 4}
    defp eval_expression("10*5"), do: {:ok, 50}
    defp eval_expression("invalid"), do: {:error, "invalid expression"}
    defp eval_expression(_), do: {:ok, 42}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         "protocolVersion" => "2025-06-18",
         "serverInfo" => %{"name" => "Test Server", "version" => "1.0.0"},
         "capabilities" => %{"tools" => %{}}
       }, state}
    end
  end

  describe "structured output with validation" do
    test "validates structured content against schema successfully" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("calculate", %{expression: "2+2"}, state)

      assert %{
               content: [%{type: "text", text: "Result: 4"}],
               structuredContent: %{result: 4, expression: "2+2"}
             } = response

      refute Map.has_key?(response, :isError)
    end

    test "returns validation error for invalid structured content" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("invalid_output", %{value: "test"}, state)

      assert %{
               content: [%{type: "text", text: text}],
               isError: true
             } = response

      assert String.contains?(text, "Output validation failed")
    end

    test "handles tool without output schema normally" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("echo", %{message: "hello"}, state)

      assert %{content: [%{type: "text", text: "hello"}]} = response

      refute Map.has_key?(response, :structuredContent)
      refute Map.has_key?(response, :isError)
    end

    test "adds empty content array when only structured content provided" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("structured_only", %{data: "test"}, state)

      assert %{
               content: [],
               structuredContent: %{processed: "TEST", timestamp: _}
             } = response
    end

    test "maps legacy structuredOutput to structuredContent" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("legacy_structured_output", %{input: "test"}, state)

      assert %{
               content: [%{type: "text", text: "Processing..."}],
               structuredContent: %{output: "test"}
             } = response

      refute Map.has_key?(response, :structuredOutput)
    end
  end

  describe "response normalization integration" do
    test "structured response includes both content and structuredContent" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("calculate", %{expression: "10*5"}, state)

      assert Map.has_key?(response, :content)
      assert Map.has_key?(response, :structuredContent)
      assert response.content == [%{type: "text", text: "Result: 50"}]
      assert response.structuredContent == %{result: 50, expression: "10*5"}
    end

    test "handler errors are normalized into an error tool result" do
      state = %{}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool("calculate", %{expression: "invalid"}, state)

      assert %{content: [%{type: "text", text: text}], isError: true} = response
      assert String.contains?(text, "Calculation failed")
    end
  end

  describe "list tools includes output schema" do
    test "output schema is included in tool definitions" do
      state = %{}

      assert {:ok, tools, nil, ^state} = TestServer.handle_list_tools(nil, state)

      calculate_tool = Enum.find(tools, &(&1.name == "calculate"))

      assert calculate_tool.outputSchema == %{
               type: "object",
               properties: %{
                 result: %{type: "number"},
                 expression: %{type: "string"}
               },
               required: ["result"]
             }

      echo_tool = Enum.find(tools, &(&1.name == "echo"))
      refute Map.has_key?(echo_tool, :outputSchema)
    end
  end
end
