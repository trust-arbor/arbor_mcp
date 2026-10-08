defmodule Arbor.MCP.Compliance.StructuredOutputComplianceTest do
  @moduledoc """
  Comprehensive test suite for MCP 2025-06-18 structured output compliance.

  Tests the following features:
  - Output schema validation with ExJsonSchema
  - structuredContent field support
  - Resource links in tool results
  - Title fields for tools
  - Legacy structuredOutput mapping
  - Error handling for invalid output
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy

  defmodule TestServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "weather_tool" do
      title("Weather Information Tool")
      description("Get weather information with structured output")

      input_schema(%{
        type: "object",
        properties: %{
          location: %{type: "string", description: "City name"}
        },
        required: ["location"]
      })

      output_schema(%{
        type: "object",
        properties: %{
          temperature: %{type: "number", description: "Temperature in Celsius"},
          conditions: %{type: "string", description: "Weather conditions"},
          humidity: %{type: "number", minimum: 0, maximum: 100}
        },
        required: ["temperature", "conditions"]
      })

      run(fn %{location: location}, state ->
        {:ok,
         %{
           content: [%{type: "text", text: "Weather in #{location}: 22°C, Sunny"}],
           structuredContent: %{
             temperature: 22.5,
             conditions: "Sunny",
             humidity: 65
           },
           resourceLinks: [
             %{
               uri: "weather://#{location}/current",
               title: "Current Weather Data",
               mimeType: "application/json"
             }
           ]
         }, state}
      end)
    end

    tool "calculator" do
      title("Mathematical Calculator")
      description("Perform calculations with structured results")

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
          expression: %{type: "string"},
          explanation: %{type: "string"}
        },
        required: ["result", "expression"]
      })

      run(fn %{expression: expr}, state ->
        case evaluate_expression(expr) do
          {:ok, result} ->
            {:ok,
             %{
               content: [%{type: "text", text: "Result: #{result}"}],
               structuredContent: %{
                 result: result,
                 expression: expr,
                 explanation: "Evaluated mathematical expression"
               }
             }, state}

          {:error, reason} ->
            {:ok,
             %{
               content: [%{type: "text", text: "Error: #{reason}"}],
               isError: true
             }, state}
        end
      end)
    end

    tool "invalid_output_tool" do
      description("Tool that returns invalid structured output for testing validation")

      input_schema(%{
        type: "object",
        properties: %{
          value: %{type: "string"}
        }
      })

      output_schema(%{
        type: "object",
        properties: %{
          number_result: %{type: "number"}
        },
        required: ["number_result"]
      })

      run(fn _args, state ->
        {:ok,
         %{
           content: [%{type: "text", text: "Invalid output test"}],
           # This should fail validation - string instead of number
           structuredContent: %{number_result: "not a number"}
         }, state}
      end)
    end

    tool "legacy_tool" do
      description("Tool using legacy structuredContent field")

      input_schema(%{
        type: "object",
        properties: %{
          input: %{type: "string"}
        }
      })

      run(fn %{input: input}, state ->
        {:ok,
         %{
           content: [%{type: "text", text: "Processed: #{input}"}],
           # Legacy field that should be mapped to structuredContent
           structuredOutput: %{processed: String.upcase(input)}
         }, state}
      end)
    end

    tool "structured_only" do
      description("Tool that returns only structured output")

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

    defp evaluate_expression("2+2"), do: {:ok, 4}
    defp evaluate_expression("10*5"), do: {:ok, 50}
    defp evaluate_expression("invalid"), do: {:error, "Invalid expression"}
    defp evaluate_expression(_), do: {:ok, 42}

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

  describe "tool definition compliance" do
    test "tools include title field in 2025-06-18 format" do
      state = %{}
      assert {:ok, tools, nil, ^state} = TestServer.handle_list_tools(nil, state)

      weather_tool = Enum.find(tools, &(&1.name == "weather_tool"))
      assert weather_tool.title == "Weather Information Tool"
      assert weather_tool.description == "Get weather information with structured output"

      calculator_tool = Enum.find(tools, &(&1.name == "calculator"))
      assert calculator_tool.title == "Mathematical Calculator"
    end

    test "tools include outputSchema field" do
      state = %{}
      assert {:ok, tools, nil, ^state} = TestServer.handle_list_tools(nil, state)

      weather_tool = Enum.find(tools, &(&1.name == "weather_tool"))
      assert weather_tool.outputSchema != nil
      assert weather_tool.outputSchema.type == "object"

      temperature =
        weather_tool.outputSchema.properties["temperature"] ||
          weather_tool.outputSchema.properties.temperature

      assert temperature.type == "number"
      assert weather_tool.outputSchema.required == ["temperature", "conditions"]

      legacy_tool = Enum.find(tools, &(&1.name == "legacy_tool"))
      refute Map.has_key?(legacy_tool, :outputSchema)
    end
  end

  describe "structured output response format" do
    test "tool results include structuredContent field" do
      state = %{}
      params = %{name: "weather_tool", arguments: %{location: "London"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Verify response structure for 2025-06-18 compliance
      assert Map.has_key?(response, :content)
      assert Map.has_key?(response, :structuredContent)
      assert Map.has_key?(response, :resourceLinks)

      # Verify content
      assert length(response.content) == 1
      assert hd(response.content).type == "text"

      # Verify structured output
      assert response.structuredContent.temperature == 22.5
      assert response.structuredContent.conditions == "Sunny"
      assert response.structuredContent.humidity == 65

      # Verify resource links
      assert length(response.resourceLinks) == 1
      link = hd(response.resourceLinks)
      assert link.uri == "weather://London/current"
      assert link.title == "Current Weather Data"
      assert link.mimeType == "application/json"
    end

    test "structured output validation against output schema" do
      state = %{}
      params = %{name: "calculator", arguments: %{expression: "2+2"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Valid output should pass validation
      assert response.structuredContent.result == 4
      assert response.structuredContent.expression == "2+2"
      assert response.structuredContent.explanation == "Evaluated mathematical expression"
      refute Map.has_key?(response, :isError)
    end

    test "invalid structured output triggers validation error" do
      state = %{}
      params = %{name: "invalid_output_tool", arguments: %{value: "test"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Should get validation error
      assert Map.has_key?(response, :isError)
      assert response.isError == true
      assert length(response.content) == 1

      error_text = hd(response.content).text
      assert String.contains?(error_text, "Output validation failed")
    end

    test "legacy structuredOutput is mapped to structuredContent" do
      state = %{}
      params = %{name: "legacy_tool", arguments: %{input: "test"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      assert Map.has_key?(response, :structuredContent)
      refute Map.has_key?(response, :structuredOutput)
      assert response.structuredContent.processed == "TEST"
    end

    test "empty content array added when only structured output provided" do
      state = %{}
      params = %{name: "structured_only", arguments: %{data: "test"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Should have empty content array and structured output
      assert response.content == []
      assert Map.has_key?(response, :structuredContent)
      assert response.structuredContent.processed == "TEST"
      assert is_integer(response.structuredContent.timestamp)
    end
  end

  describe "backwards compatibility" do
    test "tools without output schema work normally" do
      state = %{}
      params = %{name: "legacy_tool", arguments: %{input: "hello"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Should work without validation
      assert length(response.content) == 1
      assert response.structuredContent.processed == "HELLO"
      refute Map.has_key?(response, :isError)
    end

    test "error responses maintain proper structure" do
      state = %{}
      params = %{name: "calculator", arguments: %{expression: "invalid"}}

      assert {:ok, response, ^state} =
               TestServer.handle_call_tool(params.name, params.arguments, state)

      # Error should have proper structure
      assert Map.has_key?(response, :isError)
      assert response.isError == true
      assert length(response.content) == 1
      assert String.contains?(hd(response.content).text, "Error:")
    end
  end

  describe "JSON schema validation" do
    test "ExJsonSchema integration works correctly" do
      # Test the schema validation function directly
      valid_data = %{"temperature" => 25.0, "conditions" => "Clear"}

      schema = %{
        "type" => "object",
        "properties" => %{
          "temperature" => %{"type" => "number"},
          "conditions" => %{"type" => "string"}
        },
        "required" => ["temperature", "conditions"]
      }

      # This tests the internal validation logic
      result = SchemaPolicy.validate(valid_data, schema)
      assert result == :ok
    end

    test "schema validation catches type mismatches" do
      invalid_data = %{"temperature" => "not a number", "conditions" => "Clear"}

      schema = %{
        "type" => "object",
        "properties" => %{
          "temperature" => %{"type" => "number"},
          "conditions" => %{"type" => "string"}
        },
        "required" => ["temperature", "conditions"]
      }

      result = SchemaPolicy.validate(invalid_data, schema)
      assert {:error, _errors} = result
    end
  end
end
