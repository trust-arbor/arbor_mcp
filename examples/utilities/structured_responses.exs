#!/usr/bin/env elixir

# Structured Responses Example
# Demonstrates Response and Error helpers

Mix.install([
  {:arbor_mcp, path: Path.expand("../..", __DIR__)}
])

alias Arbor.MCP.Response
alias Arbor.MCP.Error

IO.puts("""
==========================================
Arbor.MCP Structured Responses Demo
==========================================
""")

# 1. Creating Different Response Types
IO.puts("1. Creating Responses:\n")

# Text response
text_resp = Response.text("Hello from Arbor.MCP!", "greeting_tool")
IO.inspect(text_resp, label: "Text response")

# JSON response  
data = %{
  user: "Alice",
  score: 95,
  passed: true
}

json_resp = Response.json(data, "score_calculator")
IO.inspect(json_resp, label: "JSON response")

# Error response
error_resp = Response.error("Invalid input: age must be positive", "validation_tool")
IO.inspect(error_resp, label: "Error response")

# 2. Extracting Content
IO.puts("\n2. Extracting Content:\n")

IO.puts("Text from text response: #{inspect(Response.text_content(text_resp))}")
IO.puts("Data from JSON response: #{inspect(Response.data_content(json_resp))}")
IO.puts("Is error response? #{error_resp.is_error}")

# 3. Working with Errors
IO.puts("\n3. Error Types:\n")

# Standard JSON-RPC errors
parse_err = Error.parse_error("Invalid JSON at position 42")
IO.inspect(parse_err, label: "Parse error")

method_err = Error.method_not_found("tools/unknown")
IO.inspect(method_err, label: "Method not found")

# Tool-specific errors
tool_err =
  Error.tool_error("Division by zero", "calculator",
    data: %{
      operation: "divide",
      numerator: 10,
      denominator: 0
    }
  )

IO.inspect(tool_err, label: "Tool error with data")

# 4. Error Conversion
IO.puts("\n4. Error Conversion:\n")

json_rpc = Error.to_json_rpc(tool_err)
IO.inspect(json_rpc, label: "JSON-RPC format")

# 5. Error Categories
IO.puts("\n5. Error Categories:\n")

errors = [
  Error.parse_error("Bad JSON"),
  Error.internal_error("Database connection failed"),
  Error.tool_error("Failed to fetch data", "weather_tool")
]

for error <- errors do
  category = Error.category(error)
  IO.puts("#{error.message} -> Category: #{category}")
end

# 6. Response Conversion
IO.puts("\n6. Response to Raw Format:\n")

# Convert response to raw MCP format
raw = Response.to_raw(text_resp)
IO.inspect(raw, label: "Raw format")

# 7. Creating Raw Tool Response
IO.puts("\n7. Creating Tool List Response:\n")

# Create a response that would come from list_tools
tools_content = [
  %{
    name: "search",
    description: "Search the web",
    input_schema: %{type: "object", properties: %{}}
  },
  %{
    name: "calculate",
    description: "Perform calculations",
    input_schema: %{type: "object", properties: %{}}
  }
]

# Server would return this format
server_response = %{
  tools: tools_content
}

# Create a response from server data
tools_resp = Response.from_raw_response(server_response)
IO.inspect(tools_resp, label: "Tools response")

# Convert back to raw
raw_tools = Response.to_raw(tools_resp)
IO.puts("Raw tools format: #{inspect(raw_tools)}")

IO.puts("""

==========================================
Key Takeaways:
==========================================

1. Use Response.text/2 for text content
2. Use Response.json/2 for structured data
3. Use Response.error/2 for errors
4. Use Error types for detailed error info
5. Extract content with type-specific functions
6. Check response.is_error to detect errors
7. Use Error.category/1 to classify errors
""")
