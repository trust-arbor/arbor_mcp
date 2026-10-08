#!/usr/bin/env elixir

# Error Handling Example
# Demonstrates Response and Error helper patterns

Mix.install([
  {:arbor_mcp, path: Path.expand("../..", __DIR__)}
])

alias Arbor.MCP.Response
alias Arbor.MCP.Error

IO.puts("""
==========================================
Arbor.MCP Error Handling Demo
==========================================
""")

# 1. Creating Error Responses
IO.puts("1. Creating Error Responses:\n")

# Simple error
simple_err = Response.error("File not found", "file_reader")
IO.inspect(simple_err, label: "Simple error")

# Error with details
detailed_err =
  Error.tool_error("Database connection failed", "db_tool",
    data: %{
      host: "localhost",
      port: 5432,
      error: "Connection refused"
    }
  )

IO.inspect(detailed_err, label: "Detailed error")

# 2. Standard JSON-RPC Errors
IO.puts("\n2. Standard JSON-RPC Errors:\n")

parse_err = Error.parse_error("Unexpected token at position 42")
IO.puts("Parse error: #{parse_err.message} (code: #{parse_err.code})")

method_err = Error.method_not_found("tools/unknown")
IO.puts("Method error: #{method_err.message} (code: #{method_err.code})")

invalid_params = Error.invalid_params("Missing required field: 'name'")
IO.puts("Invalid params: #{invalid_params.message} (code: #{invalid_params.code})")

internal_err = Error.internal_error("Server ran out of memory")
IO.puts("Internal error: #{internal_err.message} (code: #{internal_err.code})")

# 3. Error Categories
IO.puts("\n3. Error Categories:\n")

errors = [
  parse_err,
  method_err,
  invalid_params,
  internal_err,
  detailed_err
]

for error <- errors do
  category = Error.category(error)
  IO.puts("#{String.pad_trailing(error.message, 50)} → #{category}")
end

# 4. Converting Errors to Responses
IO.puts("\n4. Converting Errors to Responses:\n")

# Create an error
tool_error =
  Error.tool_error("API rate limit exceeded", "weather_tool",
    data: %{
      limit: 100,
      reset_at: "2024-01-20T15:00:00Z",
      current_usage: 100
    }
  )

# Option 1: Direct error response
error_resp1 = Response.error("API rate limit exceeded", "weather_tool")
IO.puts("Direct error response: #{Arbor.MCP.Response.text_content(error_resp1)}")

# Option 2: Error response with data (using JSON)
error_resp2 =
  Response.json(
    %{
      error: "API rate limit exceeded",
      limit: 100,
      reset_at: "2024-01-20T15:00:00Z"
    },
    "weather_tool"
  )

# Mark it as an error
error_resp2 = %{error_resp2 | is_error: true}
IO.puts("JSON error response marked as error: #{inspect(error_resp2.is_error)}")

# 5. Error Handling Patterns
IO.puts("\n5. Error Handling Patterns:\n")

defmodule ErrorPatterns do
  def safe_divide(_a, b) when b == 0 do
    Response.error("Division by zero", "calculator")
  end

  def safe_divide(a, b) do
    Response.json(%{result: a / b}, "calculator")
  end

  def handle_response(response) do
    if response.is_error do
      IO.puts("Error: #{Arbor.MCP.Response.text_content(response)}")
    else
      data = Arbor.MCP.Response.data_content(response)

      if data && Map.has_key?(data, "result") do
        IO.puts("Success: Result = #{data["result"]}")
      else
        text = Arbor.MCP.Response.text_content(response)

        if text do
          IO.puts("Success: #{text}")
        else
          IO.puts("Success: #{inspect(response)}")
        end
      end
    end
  end
end

# Test the patterns
IO.puts("Testing 10 / 2:")
ErrorPatterns.safe_divide(10, 2) |> ErrorPatterns.handle_response()

IO.puts("\nTesting 10 / 0:")
ErrorPatterns.safe_divide(10, 0) |> ErrorPatterns.handle_response()

# 6. Error Context and Request IDs
IO.puts("\n6. Error Context and Request IDs:\n")

# Create error with request ID
req_error = %{Error.tool_error("Failed to fetch data", "api_tool") | request_id: "req-123"}
IO.inspect(req_error, label: "Error with request ID")

# 7. JSON-RPC Error Format
IO.puts("\n7. JSON-RPC Error Format:\n")

json_rpc = Error.to_json_rpc(tool_error)
IO.puts("JSON-RPC format:")
IO.puts(Jason.encode!(json_rpc, pretty: true))

IO.puts("""

==========================================
Error Handling Best Practices:
==========================================

1. Use Response.error/2 for simple errors
2. Use Error types for structured errors
3. Check response.is_error to detect errors
4. Include helpful context in error data
5. Use standard error codes when applicable
6. Provide actionable error messages
7. Include request IDs for tracing
""")
