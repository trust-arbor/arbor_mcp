defmodule Arbor.MCP.Testing.AgentTestServer do
  @moduledoc """
  Comprehensive MCP server for agent simulation tests.

  Provides a rich set of tools, resources, and prompts that exercise
  the full range of MCP capabilities in realistic agent workflows.
  """

  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "agent-test-server", version: "1.0.0"

  # ── Tools ──────────────────────────────────────────────────────────────

  tool "weather", "Get current weather for a city" do
    input_schema(%{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    })

    run(fn %{"city" => city}, state ->
      weather_data = %{
        "city" => city,
        "temperature" => 72,
        "condition" => "sunny",
        "humidity" => 45,
        "wind_speed" => 8
      }

      {:ok, %{content: [%{"type" => "text", "text" => Jason.encode!(weather_data)}]}, state}
    end)
  end

  tool "calculate", "Perform basic math operations" do
    input_schema(%{
      type: "object",
      properties: %{
        operation: %{type: "string", enum: ["add", "subtract", "multiply", "divide"]},
        a: %{type: "number"},
        b: %{type: "number"}
      },
      required: ["operation", "a", "b"]
    })

    run(fn %{"operation" => op, "a" => a, "b" => b}, state ->
      result =
        case op do
          "add" -> a + b
          "subtract" -> a - b
          "multiply" -> a * b
          "divide" when b != 0 -> a / b
          "divide" -> {:error, "Division by zero"}
        end

      case result do
        {:error, msg} -> {:error, msg, state}
        value -> {:ok, %{content: [%{"type" => "text", "text" => "#{value}"}]}, state}
      end
    end)
  end

  tool "search_docs", "Search documentation by query" do
    input_schema(%{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Search query"},
        limit: %{type: "integer", description: "Max results"}
      },
      required: ["query"]
    })

    run(fn %{"query" => query} = args, state ->
      limit = Map.get(args, "limit", 5)

      results =
        1..min(limit, 3)
        |> Enum.map(fn i ->
          %{
            "title" => "Doc #{i}: #{query}",
            "snippet" => "Result #{i} for query '#{query}' — relevant documentation section.",
            "relevance" => 1.0 - i * 0.1
          }
        end)

      {:ok, %{content: [%{"type" => "text", "text" => Jason.encode!(results)}]}, state}
    end)
  end

  tool "create_report", "Create a report from data" do
    input_schema(%{
      type: "object",
      properties: %{
        title: %{type: "string"},
        data: %{type: "string"},
        format: %{type: "string", enum: ["summary", "detailed", "csv"]}
      },
      required: ["title", "data"]
    })

    run(fn %{"title" => title, "data" => data} = args, state ->
      format = Map.get(args, "format", "summary")

      report =
        case format do
          "summary" ->
            "# #{title}\n\nSummary: #{String.slice(data, 0, 100)}...\n\nGenerated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}"

          "detailed" ->
            "# #{title}\n\n## Full Data\n#{data}\n\n## Analysis\nDetailed analysis of the above data."

          "csv" ->
            "title,data\n\"#{title}\",\"#{String.replace(data, "\"", "\"\"")}\""
        end

      {:ok, %{content: [%{"type" => "text", "text" => report}]}, state}
    end)
  end

  # ── Resources ──────────────────────────────────────────────────────────

  resource "docs://api/users", "User API endpoint documentation" do
    title("API Users Documentation")
    mime_type("text/markdown")

    read(fn _params, state ->
      content = """
      # Users API

      ## GET /api/users
      Returns a list of users. Supports pagination via `page` and `per_page` params.

      ## POST /api/users
      Create a new user. Requires `name` and `email` fields.

      ## Authentication
      All endpoints require Bearer token authentication.
      """

      {:ok, %{text: content}, state}
    end)
  end

  resource "config://app/settings", "Current application configuration" do
    title("Application Settings")
    mime_type("application/json")

    read(fn _params, state ->
      config = %{
        "database" => %{"host" => "localhost", "port" => 5432, "pool_size" => 10},
        "cache" => %{"ttl" => 3600, "max_size" => 1000},
        "features" => %{"dark_mode" => true, "beta_features" => false}
      }

      {:ok, %{text: Jason.encode!(config)}, state}
    end)
  end

  resource "data://metrics/latest", "Most recent system metrics data" do
    title("Latest Metrics")
    mime_type("application/json")

    read(fn _params, state ->
      metrics = %{
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "cpu_usage" => 42.5,
        "memory_usage" => 68.2,
        "request_count" => 15234,
        "error_rate" => 0.02
      }

      {:ok, %{text: Jason.encode!(metrics)}, state}
    end)
  end

  # ── Prompts ────────────────────────────────────────────────────────────

  prompt "summarize", "Summarize content with a given style" do
    title("Summarizer")
    arg(:style, description: "Summary style (concise, detailed, bullet)")

    render(fn args, state ->
      style = Map.get(args, "style", "concise")

      {:ok,
       %{
         description: "Summarization prompt with #{style} style",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text:
                 "Please provide a #{style} summary of the given content. Focus on key points and actionable insights."
             }
           }
         ]
       }, state}
    end)
  end

  prompt "analyze", "Analyze data with a specific focus area" do
    title("Analyzer")
    arg(:focus, required: true, description: "Focus area for analysis")

    render(fn args, state ->
      focus = Map.get(args, "focus", "general")

      {:ok,
       %{
         description: "Analysis prompt focused on #{focus}",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text:
                 "Analyze the following data with a focus on #{focus}. Provide insights and recommendations."
             }
           }
         ]
       }, state}
    end)
  end
end
