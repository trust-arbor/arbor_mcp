defmodule Arbor.MCP.StructuredOutputTest do
  @moduledoc """
  Tests for the structured tool output feature (2025-06-18 specification).
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestHandler do
    @behaviour Arbor.MCP.Server.Handler

    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      result = %{
        protocolVersion: "2025-06-18",
        serverInfo: %{name: "test-server", version: "1.0.0"},
        capabilities: %{
          tools: %{}
        }
      }

      {:ok, result, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "get_weather",
          description: "Get weather data with structured output",
          inputSchema: %{
            type: "object",
            properties: %{
              location: %{type: "string", description: "City name"}
            },
            required: ["location"]
          },
          # 2025-06-18 feature: outputSchema
          outputSchema: %{
            type: "object",
            properties: %{
              temperature: %{type: "number", description: "Temperature in Celsius"},
              conditions: %{type: "string", description: "Weather conditions"},
              humidity: %{type: "number", description: "Humidity percentage"},
              windSpeed: %{type: "number", description: "Wind speed in km/h"}
            },
            required: ["temperature", "conditions"]
          }
        },
        %{
          name: "calculate",
          description: "Basic calculator without structured output",
          inputSchema: %{
            type: "object",
            properties: %{
              expression: %{type: "string"}
            },
            required: ["expression"]
          }
          # No outputSchema - traditional tool
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("get_weather", %{"location" => location}, state) do
      # Return both unstructured and structured content
      result = %{
        content: [
          %{
            type: "text",
            text: "Weather in #{location}: 22.5°C, Partly cloudy, 65% humidity"
          }
        ],
        # 2025-06-18 feature: structuredContent
        structuredContent: %{
          "temperature" => 22.5,
          "conditions" => "Partly cloudy",
          "humidity" => 65,
          "windSpeed" => 15.2
        }
      }

      {:ok, result, state}
    end

    @impl true
    def handle_call_tool("calculate", %{"expression" => expr}, state) do
      # Traditional tool - only unstructured content
      result =
        case evaluate_expression(expr) do
          {:ok, value} ->
            [%{type: "text", text: "Result: #{value}"}]

          {:error, reason} ->
            %{
              content: [%{type: "text", text: "Error: #{reason}"}],
              is_error: true
            }
        end

      {:ok, result, state}
    end

    @impl true
    def handle_call_tool(name, _args, state) do
      {:error, "Unknown tool: #{name}", state}
    end

    # Stub implementations for other required callbacks
    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_read_resource(_uri, state), do: {:error, "Not implemented", state}

    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_get_prompt(_name, _args, state), do: {:error, "Not implemented", state}

    defp evaluate_expression("1 + 1"), do: {:ok, 2}
    defp evaluate_expression("10 / 2"), do: {:ok, 5}
    defp evaluate_expression("invalid"), do: {:error, "Invalid expression"}
    defp evaluate_expression(expr), do: {:ok, "Evaluated: #{expr}"}
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestHandler,
        handler_args: []
      )

    # Start client with BEAM transport
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    on_exit(fn ->
      # More robust cleanup with try/catch
      try do
        if Process.alive?(client), do: GenServer.stop(client)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(server), do: GenServer.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, client: client}
  end

  describe "structured tool output" do
    test "tools can declare outputSchema", %{client: client} do
      {:ok, %{tools: tools}} = Client.list_tools(client)

      weather_tool = Enum.find(tools, &(&1.name == "get_weather"))
      assert weather_tool.outputSchema != nil
      assert weather_tool.outputSchema.type == "object"

      temperature =
        weather_tool.outputSchema.properties["temperature"] ||
          weather_tool.outputSchema.properties.temperature

      assert temperature.type == "number"
      assert weather_tool.outputSchema.required == ["temperature", "conditions"]

      calculate_tool = Enum.find(tools, &(&1.name == "calculate"))
      assert Map.get(calculate_tool, :outputSchema) == nil
    end

    test "tool can return structured content", %{client: client} do
      {:ok, result} = Client.call_tool(client, "get_weather", %{"location" => "London"})

      # Check unstructured content is present
      assert result.content != nil
      assert length(result.content) > 0
      assert result.content |> List.first() |> Map.get(:type) == "text"

      # Check structured content is present
      assert Map.has_key?(result, :structuredOutput)
      structured = Map.get(result, :structuredOutput)
      assert structured != nil

      # Keys are strings after JSON encoding/decoding
      assert Map.get(structured, "temperature") == 22.5
      assert Map.get(structured, "conditions") == "Partly cloudy"
      assert Map.get(structured, "humidity") == 65
      assert Map.get(structured, "windSpeed") == 15.2
    end

    test "traditional tools work without structured content", %{client: client} do
      {:ok, result} = Client.call_tool(client, "calculate", %{"expression" => "1 + 1"})

      # Should return map format with content
      assert is_map(result)
      assert result.content != nil
      assert length(result.content) > 0
      assert result.content |> List.first() |> Map.get(:type) == "text"
      assert result.content |> List.first() |> Map.get(:text) =~ "Result: 2"
    end

    test "tool errors work with structured output format", %{client: client} do
      {:ok, result} = Client.call_tool(client, "calculate", %{"expression" => "invalid"})

      # Error result should be in extended format
      assert is_map(result)
      assert result.is_error == true
      assert result.content != nil
      assert result.content |> List.first() |> Map.get(:text) =~ "Error:"
    end
  end

  describe "backwards compatibility" do
    test "clients can ignore outputSchema if not supported", %{client: client} do
      # List tools should work even if client doesn't understand outputSchema
      {:ok, %{tools: tools}} = Client.list_tools(client)
      assert length(tools) > 0

      # Tool calls should work normally
      {:ok, result} = Client.call_tool(client, "get_weather", %{"location" => "Paris"})
      assert result.content != nil
    end

    test "servers can return only unstructured content", %{client: client} do
      # Traditional tool without structured output
      {:ok, result} = Client.call_tool(client, "calculate", %{"expression" => "10 / 2"})
      assert is_map(result) and result.content != nil
    end
  end
end
