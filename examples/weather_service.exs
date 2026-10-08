#!/usr/bin/env elixir

# Practical weather-style MCP server using the modern Arbor.MCP Handler + DSL API.
# The data is simulated so the example is self-contained.

Mix.install([
  {:arbor_mcp, path: Path.expand("..", __DIR__)}
])

defmodule WeatherService do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "weather-service", version: "1.0.0"

  @impl true
  def init(_args) do
    {:ok, %{favorites: ["New York", "London", "Tokyo"], units: "celsius", cache: %{}}}
  end

  tool "get_weather", "Gets current weather for a location" do
    title("Get Weather")
    param(:location, :string, required: true)
    param(:units, :string, default: "celsius", description: "celsius, fahrenheit, or kelvin")
    param(:detailed, :boolean, default: false)

    run(fn %{location: location, units: units, detailed: detailed}, state ->
      weather = generate_weather(location, units)
      new_state = put_in(state.cache[location], weather)

      text =
        if detailed do
          detailed_weather_text(weather)
        else
          "#{location}: #{weather.temperature} #{weather.unit}, #{weather.condition}"
        end

      # ToolResult is aliased by `use Arbor.MCP.Server.DSL`
      {:ok, ToolResult.structured(text, weather), new_state}
    end)
  end

  tool "get_forecast", "Gets a simulated multi-day forecast" do
    title("Get Forecast")
    param(:location, :string, required: true)
    param(:days, :integer, default: 5)

    run(fn %{location: location, days: days}, state ->
      forecast = build_forecast(location, days)

      {:ok,
       ToolResult.structured("#{days}-day forecast for #{location}.", %{
         location: location,
         forecast: forecast
       }), state}
    end)
  end

  tool "compare_weather", "Compares current weather across locations" do
    title("Compare Weather")
    param(:locations, {:array, :string}, required: true)

    run(fn %{locations: locations}, state ->
      comparisons =
        locations
        |> Enum.take(5)
        |> Enum.map(&generate_weather(&1, state.units))

      summary =
        comparisons
        |> Enum.map_join("\n", &"#{&1.location}: #{&1.temperature} #{&1.unit}, #{&1.condition}")

      {:ok, ToolResult.structured(summary, %{comparisons: comparisons}), state}
    end)
  end

  resource "weather://favorites", "Saved favorite locations" do
    title("Favorite Locations")
    mime_type("application/json")

    read(fn %{uri: uri}, state ->
      {:ok,
       %{
         uri: uri,
         text: Jason.encode!(%{favorites: state.favorites, default_units: state.units})
       }, state}
    end)
  end

  resource_template "weather://current/{location}", "Cached or generated current weather" do
    title("Current Weather")
    mime_type("application/json")
    param(:location, :string)

    read(fn %{location: location, uri: uri}, state ->
      weather = Map.get(state.cache, location) || generate_weather(location, state.units)
      {:ok, %{uri: uri, text: Jason.encode!(weather)}, state}
    end)
  end

  prompt "weather_assistant", "Creates an activity-planning weather prompt" do
    title("Weather Planning Assistant")
    arg(:activity, required: true)
    arg(:location, required: true)
    arg(:date)

    render(fn %{activity: activity, location: location} = args, state ->
      date = Map.get(args, :date, "today")

      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: "Help me plan #{activity} in #{location} on #{date} based on weather."
             }
           }
         ]
       }, state}
    end)
  end

  defp generate_weather(location, units) do
    base_celsius = 12 + stable_number(location, 22)
    {temperature, unit} = convert_temperature(base_celsius, units)

    %{
      location: location,
      temperature: temperature,
      unit: unit,
      condition:
        Enum.at(["sunny", "cloudy", "rainy", "partly cloudy"], stable_number(location, 4)),
      humidity: 35 + stable_number(location <> "humidity", 45),
      wind_kph: 5 + stable_number(location <> "wind", 25),
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp convert_temperature(celsius, "fahrenheit"), do: {round(celsius * 9 / 5 + 32), "F"}
  defp convert_temperature(celsius, "kelvin"), do: {round(celsius + 273.15), "K"}
  defp convert_temperature(celsius, _units), do: {celsius, "C"}

  defp build_forecast(location, days) do
    1..max(1, min(days, 10))
    |> Enum.map(fn day ->
      weather = generate_weather("#{location}-#{day}", "celsius")

      %{
        date: Date.utc_today() |> Date.add(day) |> Date.to_iso8601(),
        high_c: weather.temperature + 3,
        low_c: weather.temperature - 6,
        condition: weather.condition
      }
    end)
  end

  defp detailed_weather_text(weather) do
    """
    #{weather.location}: #{weather.temperature} #{weather.unit}
    Condition: #{weather.condition}
    Humidity: #{weather.humidity}%
    Wind: #{weather.wind_kph} kph
    """
  end

  defp stable_number(seed, limit) do
    seed
    |> :erlang.phash2(limit)
  end
end

defmodule WeatherServiceRunner do
  def run do
    IO.puts("Starting Weather Service MCP Server on stdio.")
    IO.puts("Tools: get_weather, get_forecast, compare_weather")
    IO.puts("Resources: weather://favorites, weather://current/{location}")
    IO.puts("Prompt: weather_assistant")

    {:ok, _server} = WeatherService.start_link(transport: :stdio)
    Process.sleep(:infinity)
  end
end

if System.get_env("MCP_ENV") != "test" do
  WeatherServiceRunner.run()
end
