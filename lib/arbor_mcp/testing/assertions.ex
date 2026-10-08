defmodule Arbor.MCP.Testing.Assertions do
  @moduledoc """
  Custom assertions for MCP protocol testing.

  This module provides MCP-specific assertions that go beyond basic ExUnit
  assertions, offering detailed validation for protocol compliance, content
  structure, and common MCP patterns.

  ## Features

  - **Protocol Assertions**: Validate MCP message structure and compliance
  - **Content Assertions**: Type-safe content validation and inspection
  - **Tool Assertions**: Validate tool definitions and results
  - **Resource Assertions**: Validate resource definitions and responses
  - **Error Assertions**: Structured error validation
  - **Performance Assertions**: Response time and throughput validation

  ## Usage

      use Arbor.MCP.TestCase

      test "tool call returns valid content" do
        result = call_tool(client, "sample_tool", %{input: "test"})

        assert_success(result)
        assert_valid_tool_result(result)
        assert_content_type(result, :text)
        assert_content_contains(result, "expected output")
      end
  """

  # Import ExUnit.Assertions - this module is only meant for test environment
  import ExUnit.Assertions, only: [assert: 2, refute: 2, flunk: 1]

  alias Arbor.MCP.Content.Protocol

  @typedoc "MCP message types for assertion validation"
  @type mcp_message_type ::
          :request
          | :response
          | :notification
          | :error
          | :initialize
          | :list_tools
          | :call_tool
          | :list_resources
          | :read_resource
          | :list_prompts
          | :get_prompt

  @typedoc "Assertion options for customizing behavior"
  @type assertion_opts :: [
          strict: boolean(),
          timeout: pos_integer(),
          retry_count: pos_integer(),
          message: String.t()
        ]

  # Core Protocol Assertions

  @doc """
  Asserts that a response indicates success.

  ## Examples

      assert_success({:ok, result})
      assert_success(%{"status" => "success"})

      # With custom message
      assert_success(result, "Tool call should succeed")
  """
  @spec assert_success(any(), String.t() | nil) :: any()
  def assert_success(result, message \\ nil)

  def assert_success({:ok, result}, _message), do: result

  def assert_success({:error, reason}, message) do
    failure_message = message || "Expected success, got error: #{inspect(reason)}"
    flunk(failure_message)
  end

  def assert_success(%{"error" => error}, message) do
    failure_message = message || "Expected success, got error: #{inspect(error)}"
    flunk(failure_message)
  end

  def assert_success(result, _message), do: result

  @doc """
  Asserts that a response indicates an error.

  ## Examples

      assert_error({:error, :timeout})
      assert_error(%{"error" => %{"code" => -1}})

      # With specific error checking
      assert_error(result, fn error ->
        assert error.code == -32601
        assert error.message =~ "Method not found"
      end)
  """
  @spec assert_error(any(), (any() -> any()) | nil, String.t() | nil) :: any()
  def assert_error(result, validator \\ nil, message \\ nil)

  def assert_error({:error, error}, validator, _message) do
    if validator, do: validator.(error), else: error
  end

  def assert_error({:ok, result}, _validator, message) do
    failure_message = message || "Expected error, got success: #{inspect(result)}"
    flunk(failure_message)
  end

  def assert_error(%{"error" => error}, validator, _message) do
    if validator, do: validator.(error), else: error
  end

  def assert_error(result, _validator, message) do
    failure_message = message || "Expected error, got: #{inspect(result)}"
    flunk(failure_message)
  end

  @doc """
  Asserts that a value matches MCP message structure.

  ## Examples

      assert_mcp_message(message, :request)
      assert_mcp_message(message, :response, id: 123)
      assert_mcp_message(message, :notification, method: "notifications/message")
  """
  @spec assert_mcp_message(map(), mcp_message_type(), keyword()) :: map()
  def assert_mcp_message(message, type, opts \\ [])

  def assert_mcp_message(message, :request, opts) do
    assert is_map(message), "MCP request must be a map"
    assert Map.has_key?(message, "jsonrpc"), "MCP request must have jsonrpc field"
    assert message["jsonrpc"] == "2.0", "MCP request must use JSON-RPC 2.0"
    assert Map.has_key?(message, "method"), "MCP request must have method field"
    assert Map.has_key?(message, "id"), "MCP request must have id field"

    if expected_id = Keyword.get(opts, :id) do
      assert message["id"] == expected_id, "Request ID mismatch"
    end

    if expected_method = Keyword.get(opts, :method) do
      assert message["method"] == expected_method, "Request method mismatch"
    end

    message
  end

  def assert_mcp_message(message, :response, opts) do
    assert is_map(message), "MCP response must be a map"
    assert Map.has_key?(message, "jsonrpc"), "MCP response must have jsonrpc field"
    assert message["jsonrpc"] == "2.0", "MCP response must use JSON-RPC 2.0"
    assert Map.has_key?(message, "id"), "MCP response must have id field"

    # Response must have either result or error, but not both
    has_result = Map.has_key?(message, "result")
    has_error = Map.has_key?(message, "error")
    assert has_result or has_error, "MCP response must have result or error field"
    refute has_result and has_error, "MCP response cannot have both result and error"

    if expected_id = Keyword.get(opts, :id) do
      assert message["id"] == expected_id, "Response ID mismatch"
    end

    message
  end

  def assert_mcp_message(message, :notification, opts) do
    assert is_map(message), "MCP notification must be a map"
    assert Map.has_key?(message, "jsonrpc"), "MCP notification must have jsonrpc field"
    assert message["jsonrpc"] == "2.0", "MCP notification must use JSON-RPC 2.0"
    assert Map.has_key?(message, "method"), "MCP notification must have method field"
    refute Map.has_key?(message, "id"), "MCP notification must not have id field"

    if expected_method = Keyword.get(opts, :method) do
      assert message["method"] == expected_method, "Notification method mismatch"
    end

    message
  end

  def assert_mcp_message(message, :error, opts) do
    assert is_map(message), "MCP error must be a map"
    assert Map.has_key?(message, "jsonrpc"), "MCP error must have jsonrpc field"
    assert message["jsonrpc"] == "2.0", "MCP error must use JSON-RPC 2.0"
    assert Map.has_key?(message, "id"), "MCP error must have id field"
    assert Map.has_key?(message, "error"), "MCP error must have error field"

    error = message["error"]
    assert Map.has_key?(error, "code"), "MCP error must have code field"
    assert Map.has_key?(error, "message"), "MCP error must have message field"
    assert is_integer(error["code"]), "MCP error code must be integer"
    assert is_binary(error["message"]), "MCP error message must be string"

    if expected_code = Keyword.get(opts, :code) do
      assert error["code"] == expected_code, "Error code mismatch"
    end

    message
  end

  # Content Assertions

  @doc """
  Asserts that content is valid according to MCP content protocol.

  ## Examples

      assert_valid_content(Protocol.text("Hello"))
      assert_valid_content(%{"type" => "text", "text" => "Hello"})
  """
  @spec assert_valid_content(Protocol.content() | map()) :: Protocol.content() | map()
  def assert_valid_content(content) when is_map(content) do
    case Protocol.validate(content) do
      :ok -> content
      {:error, reason} -> flunk("Content validation failed: #{reason}")
    end
  end

  @doc """
  Asserts that a tool result contains valid content.

  ## Examples

      result = %{"content" => [%{"type" => "text", "text" => "Hello"}]}
      assert_valid_tool_result(result)
  """
  @spec assert_valid_tool_result(map()) :: map()
  def assert_valid_tool_result(result) do
    assert is_map(result), "Tool result must be a map"
    assert Map.has_key?(result, "content"), "Tool result must have content field"

    content_list = result["content"]
    assert is_list(content_list), "Tool result content must be a list"
    assert length(content_list) > 0, "Tool result must have at least one content item"

    Enum.each(content_list, fn content_item ->
      case Protocol.deserialize(content_item) do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("Invalid content in tool result: #{reason}")
      end
    end)

    result
  end

  @doc """
  Asserts that content is of a specific type.

  ## Examples

      assert_content_type(content, :text)
      assert_content_type(result, :image)
      assert_content_type(result["content"], :text)  # For tool results
  """
  @spec assert_content_type(Protocol.content() | map() | [map()], atom()) :: any()
  def assert_content_type(%{type: type}, expected_type) do
    assert type == expected_type, "Expected content type #{expected_type}, got #{type}"
  end

  def assert_content_type(%{"type" => type}, expected_type) when is_binary(type) do
    type_atom = String.to_existing_atom(type)
    assert type_atom == expected_type, "Expected content type #{expected_type}, got #{type_atom}"
  end

  def assert_content_type(%{"content" => content_list}, expected_type)
      when is_list(content_list) do
    # For tool results - check first content item
    case content_list do
      [first | _] -> assert_content_type(first, expected_type)
      [] -> flunk("Cannot check content type of empty content list")
    end
  end

  def assert_content_type(content_list, expected_type) when is_list(content_list) do
    case content_list do
      [first | _] -> assert_content_type(first, expected_type)
      [] -> flunk("Cannot check content type of empty content list")
    end
  end

  @doc """
  Asserts that text content contains a specific string.

  ## Examples

      assert_content_contains(text_content, "hello")
      assert_content_contains(tool_result, "expected output")
  """
  @spec assert_content_contains(Protocol.content() | map(), String.t()) :: any()
  def assert_content_contains(%{type: :text, text: text}, expected) when is_binary(expected) do
    assert String.contains?(text, expected),
           "Expected text to contain '#{expected}', got: #{text}"
  end

  def assert_content_contains(%{"type" => "text", "text" => text}, expected)
      when is_binary(expected) do
    assert String.contains?(text, expected),
           "Expected text to contain '#{expected}', got: #{text}"
  end

  def assert_content_contains(%{"content" => content_list}, expected)
      when is_list(content_list) do
    # For tool results - check all text content
    text_items =
      content_list
      |> Enum.filter(fn item -> Map.get(item, "type") == "text" end)
      |> Enum.map_join(" ", fn item -> Map.get(item, "text", "") end)

    assert String.contains?(text_items, expected),
           "Expected content to contain '#{expected}', got: #{text_items}"
  end

  @doc """
  Asserts that content matches a regular expression.

  ## Examples

      assert_content_matches(content, ~r/hello \\w+/)
      assert_content_matches(tool_result, ~r/\\d{4}-\\d{2}-\\d{2}/)
  """
  @spec assert_content_matches(Protocol.content() | map(), Regex.t()) :: any()
  def assert_content_matches(%{type: :text, text: text}, pattern) do
    assert Regex.match?(pattern, text), "Expected text to match #{inspect(pattern)}, got: #{text}"
  end

  def assert_content_matches(%{"type" => "text", "text" => text}, pattern) do
    assert Regex.match?(pattern, text), "Expected text to match #{inspect(pattern)}, got: #{text}"
  end

  def assert_content_matches(%{"content" => content_list}, pattern) when is_list(content_list) do
    text_items =
      content_list
      |> Enum.filter(fn item -> Map.get(item, "type") == "text" end)
      |> Enum.map_join(" ", fn item -> Map.get(item, "text", "") end)

    assert Regex.match?(pattern, text_items),
           "Expected content to match #{inspect(pattern)}, got: #{text_items}"
  end

  # Tool and Resource Assertions

  @doc """
  Asserts that a tool definition is valid.

  ## Examples

      tool = %{
        "name" => "sample_tool",
        "description" => "A sample tool",
        "inputSchema" => %{"type" => "object"}
      }
      assert_valid_tool(tool)
  """
  @spec assert_valid_tool(map()) :: map()
  def assert_valid_tool(tool) do
    assert is_map(tool), "Tool must be a map"
    assert Map.has_key?(tool, "name"), "Tool must have name field"
    assert Map.has_key?(tool, "description"), "Tool must have description field"
    assert Map.has_key?(tool, "inputSchema"), "Tool must have inputSchema field"

    assert is_binary(tool["name"]), "Tool name must be a string"
    assert is_binary(tool["description"]), "Tool description must be a string"
    assert is_map(tool["inputSchema"]), "Tool inputSchema must be a map"

    # Validate JSON Schema structure
    schema = tool["inputSchema"]
    assert Map.has_key?(schema, "type"), "Tool inputSchema must have type field"

    assert schema["type"] in ["object", "array", "string", "number", "boolean", "null"],
           "Tool inputSchema type must be valid JSON Schema type"

    tool
  end

  @doc """
  Asserts that a resource definition is valid.

  ## Examples

      resource = %{
        "uri" => "file://data.txt",
        "name" => "Sample Data",
        "description" => "Sample data file",
        "mimeType" => "text/plain"
      }
      assert_valid_resource(resource)
  """
  @spec assert_valid_resource(map()) :: map()
  def assert_valid_resource(resource) do
    assert is_map(resource), "Resource must be a map"
    assert Map.has_key?(resource, "uri"), "Resource must have uri field"
    assert Map.has_key?(resource, "name"), "Resource must have name field"

    assert is_binary(resource["uri"]), "Resource uri must be a string"
    assert is_binary(resource["name"]), "Resource name must be a string"

    # Validate URI format
    case URI.parse(resource["uri"]) do
      %URI{scheme: scheme} when is_binary(scheme) -> :ok
      _ -> flunk("Resource uri must be a valid URI")
    end

    resource
  end

  @doc """
  Asserts that a prompt definition is valid.

  ## Examples

      prompt = %{
        "name" => "sample_prompt",
        "description" => "A sample prompt",
        "arguments" => [
          %{"name" => "topic", "description" => "The topic", "required" => true}
        ]
      }
      assert_valid_prompt(prompt)
  """
  @spec assert_valid_prompt(map()) :: map()
  def assert_valid_prompt(prompt) do
    assert is_map(prompt), "Prompt must be a map"
    assert Map.has_key?(prompt, "name"), "Prompt must have name field"
    assert Map.has_key?(prompt, "description"), "Prompt must have description field"

    assert is_binary(prompt["name"]), "Prompt name must be a string"
    assert is_binary(prompt["description"]), "Prompt description must be a string"

    if Map.has_key?(prompt, "arguments") do
      arguments = prompt["arguments"]
      assert is_list(arguments), "Prompt arguments must be a list"

      Enum.each(arguments, fn arg ->
        assert is_map(arg), "Each prompt argument must be a map"
        assert Map.has_key?(arg, "name"), "Prompt argument must have name field"
        assert Map.has_key?(arg, "description"), "Prompt argument must have description field"
        assert is_binary(arg["name"]), "Prompt argument name must be a string"
        assert is_binary(arg["description"]), "Prompt argument description must be a string"
      end)
    end

    prompt
  end

  # Performance Assertions

  @doc """
  Asserts that an operation completes within a time limit.

  ## Examples

      assert_performance fn ->
        slow_operation()
      end, max_time: 1000

      assert_performance fn ->
        call_tool(client, "tool", %{})
      end, max_time: 500, message: "Tool call should be fast"
  """
  @spec assert_performance((-> any()), assertion_opts()) :: any()
  def assert_performance(operation, opts \\ []) do
    max_time = Keyword.get(opts, :max_time, 5000)
    message = Keyword.get(opts, :message, "Operation took too long")

    {elapsed_time, result} = :timer.tc(operation)
    elapsed_ms = div(elapsed_time, 1000)

    if elapsed_ms > max_time do
      flunk("#{message} (took #{elapsed_ms}ms, max #{max_time}ms)")
    end

    result
  end

  @doc """
  Asserts that multiple operations maintain average performance.

  ## Examples

      assert_throughput fn ->
        call_tool(client, "tool", %{})
      end, iterations: 10, max_avg_time: 100
  """
  @spec assert_throughput((-> any())) :: [any()]
  @spec assert_throughput((-> any()), assertion_opts()) :: [any()]
  def assert_throughput(operation, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 10)
    max_avg_time = Keyword.get(opts, :max_avg_time, 1000)

    {results, total_time} =
      :timer.tc(fn ->
        Enum.map(1..iterations, fn _ -> operation.() end)
      end)

    avg_time_ms = div(total_time, iterations * 1000)

    if avg_time_ms > max_avg_time do
      flunk("Average operation time #{avg_time_ms}ms exceeds maximum #{max_avg_time}ms")
    end

    results
  end

  # Batch and List Assertions

  @doc """
  Asserts that a list of tools contains a specific tool.

  ## Examples

      tools = [%{"name" => "tool1"}, %{"name" => "tool2"}]
      assert_has_tool(tools, "tool1")
  """
  @spec assert_has_tool([map()], String.t()) :: map()
  def assert_has_tool(tools, tool_name) do
    assert is_list(tools), "Tools must be a list"

    found_tool =
      Enum.find(tools, fn tool ->
        Map.get(tool, "name") == tool_name
      end)

    assert found_tool, "Expected to find tool '#{tool_name}' in tools list"
    found_tool
  end

  @doc """
  Asserts that a list of resources contains a specific resource.

  ## Examples

      resources = [%{"uri" => "file://a.txt"}, %{"uri" => "file://b.txt"}]
      assert_has_resource(resources, "file://a.txt")
  """
  @spec assert_has_resource([map()], String.t()) :: map()
  def assert_has_resource(resources, resource_uri) do
    assert is_list(resources), "Resources must be a list"

    found_resource =
      Enum.find(resources, fn resource ->
        Map.get(resource, "uri") == resource_uri
      end)

    assert found_resource, "Expected to find resource '#{resource_uri}' in resources list"
    found_resource
  end

  @doc """
  Asserts that all items in a list pass a validation function.

  ## Examples

      assert_all_valid(tools, &assert_valid_tool/1)
      assert_all_valid(content_list, fn content ->
        assert_content_type(content, :text)
        assert_content_contains(content, "required")
      end)
  """
  @spec assert_all_valid([any()], (any() -> any())) :: [any()]
  def assert_all_valid(items, validator) when is_list(items) and is_function(validator, 1) do
    Enum.each(items, validator)
    items
  end

  # State and Sequence Assertions

  @doc """
  Asserts that a value becomes true within a timeout period.

  ## Examples

      assert_eventually fn ->
        Process.alive?(pid)
      end, timeout: 1000

      assert_eventually fn ->
        GenServer.call(server, :is_ready)
      end, timeout: 5000, interval: 100
  """
  @spec assert_eventually((-> boolean()), assertion_opts()) :: :ok
  def assert_eventually(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 100)
    message = Keyword.get(opts, :message, "Condition never became true")

    end_time = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(condition, end_time, interval, message)
  end

  defp do_assert_eventually(condition, end_time, interval, message) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= end_time do
        flunk(message)
      else
        Process.sleep(interval)
        do_assert_eventually(condition, end_time, interval, message)
      end
    end
  end

  @doc """
  Asserts that events occur in a specific order.

  ## Examples

      assert_sequence([
        fn -> send(self(), :event1) end,
        fn -> send(self(), :event2) end,
        fn -> send(self(), :event3) end
      ]) do
        assert_received :event1
        assert_received :event2
        assert_received :event3
      end
  """
  defmacro assert_sequence(operations, do: assertions) do
    quote do
      Enum.each(unquote(operations), fn op -> op.() end)
      unquote(assertions)
    end
  end
end
