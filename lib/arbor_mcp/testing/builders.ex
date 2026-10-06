defmodule Arbor.MCP.Testing.Builders do
  @moduledoc """
  Test data builders and generators for ArborMCP.

  This module provides factories and builders for creating test data that
  conforms to MCP protocol specifications. It includes builders for all
  major MCP entities and supports both fixed and randomized test data.

  ## Features

  - **Content Builders**: Generate valid content for all supported types
  - **Tool Builders**: Create tool definitions and results
  - **Resource Builders**: Generate resource definitions and data
  - **Prompt Builders**: Create prompt templates and arguments
  - **Message Builders**: Generate MCP protocol messages
  - **Schema Builders**: Create JSON schemas for validation
  - **Randomized Data**: Support for property-based testing

  ## Usage

      alias Arbor.MCP.Testing.Builders

      # Create test content
      text_content = Builders.text_content("Hello world")
      image_content = Builders.image_content()

      # Create test tools
      tool = Builders.tool("sample_tool")
      tool_with_schema = Builders.tool("complex_tool", schema: Builders.object_schema())

      # Create test messages
      request = Builders.request("list_tools", id: 1)
      response = Builders.success_response(1, %{"tools" => []})
  """

  alias Arbor.MCP.Content.Protocol

  @typedoc "Builder options for customizing generated data"
  @type builder_opts :: [
          random: boolean(),
          seed: integer(),
          size: pos_integer(),
          format: atom(),
          metadata: map()
        ]

  # Content Builders

  @doc """
  Builds text content for testing.

  ## Examples

      # Fixed content
      text_content("Hello world")

      # Random content
      text_content(random: true)

      # Markdown content
      text_content("# Header", format: :markdown)

      # With metadata
      text_content("Test", metadata: %{author: "test"})
  """
  @spec text_content(String.t() | nil, builder_opts()) :: Protocol.text()
  def text_content(content \\ nil, opts \\ [])

  def text_content(content, opts) when is_binary(content) do
    Protocol.text(content,
      format: Keyword.get(opts, :format, :plain),
      language: Keyword.get(opts, :language),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def text_content(nil, opts) do
    if Keyword.get(opts, :random, false) do
      content = random_text(Keyword.get(opts, :size, 50))
      text_content(content, opts)
    else
      text_content("Sample text content", opts)
    end
  end

  @doc """
  Builds image content for testing.

  ## Examples

      # Default test image
      image_content()

      # Custom MIME type
      image_content(mime_type: "image/jpeg")

      # With dimensions
      image_content(width: 800, height: 600)

      # Random image data
      image_content(random: true, size: 1024)
  """
  @spec image_content(builder_opts()) :: Protocol.image()
  def image_content(opts \\ []) do
    data =
      if Keyword.get(opts, :random, false) do
        size = Keyword.get(opts, :size, 100)
        random_bytes(size) |> Base.encode64()
      else
        # 1x1 PNG pixel
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
      end

    Protocol.image(
      data,
      Keyword.get(opts, :mime_type, "image/png"),
      width: Keyword.get(opts, :width),
      height: Keyword.get(opts, :height),
      alt_text: Keyword.get(opts, :alt_text),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc """
  Builds audio content for testing.

  ## Examples

      # Default test audio
      audio_content()

      # With transcript
      audio_content(transcript: "Hello world")

      # With duration
      audio_content(duration: 10.5)

      # Random audio data
      audio_content(random: true, size: 2048)
  """
  @spec audio_content(builder_opts()) :: Protocol.audio()
  def audio_content(opts \\ []) do
    data =
      if Keyword.get(opts, :random, false) do
        size = Keyword.get(opts, :size, 500)
        random_bytes(size) |> Base.encode64()
      else
        # Fake WAV header + minimal data
        <<82, 73, 70, 70, 40, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0, 1, 0, 1, 0,
          68, 172, 0, 0, 136, 88, 1, 0, 2, 0, 16, 0, 100, 97, 116, 97, 4, 0, 0, 0, 0, 0, 1, 0>>
        |> Base.encode64()
      end

    Protocol.audio(
      data,
      Keyword.get(opts, :mime_type, "audio/wav"),
      duration: Keyword.get(opts, :duration),
      transcript: Keyword.get(opts, :transcript),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc """
  Builds resource content for testing.

  ## Examples

      # File resource
      resource_content("file://data.txt")

      # HTTP resource with metadata
      resource_content("https://example.com/api",
        text: "API endpoint",
        mime_type: "application/json"
      )

      # Random resource
      resource_content(random: true)
  """
  @spec resource_content(String.t() | nil, builder_opts()) :: Protocol.resource()
  def resource_content(uri \\ nil, opts \\ [])

  def resource_content(uri, opts) when is_binary(uri) do
    Protocol.resource(uri,
      text: Keyword.get(opts, :text),
      mime_type: Keyword.get(opts, :mime_type),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def resource_content(nil, opts) do
    uri =
      if Keyword.get(opts, :random, false) do
        schemes = ["file", "http", "https", "ftp"]
        scheme = Enum.random(schemes)
        "#{scheme}://example.com/#{random_string(10)}"
      else
        "file://test_resource.txt"
      end

    resource_content(uri, opts)
  end

  @doc """
  Builds annotation content for testing.

  ## Examples

      # Simple annotation
      annotation_content("sentiment")

      # With confidence and text
      annotation_content("sentiment", confidence: 0.95, text: "positive")

      # Random annotation
      annotation_content(random: true)
  """
  @spec annotation_content(String.t() | nil, builder_opts()) :: Protocol.annotation()
  def annotation_content(type \\ nil, opts \\ [])

  def annotation_content(type, opts) when is_binary(type) do
    Protocol.annotation(type,
      confidence: Keyword.get(opts, :confidence),
      text: Keyword.get(opts, :text),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def annotation_content(nil, opts) do
    type =
      if Keyword.get(opts, :random, false) do
        types = ["sentiment", "classification", "extraction", "summary", "translation"]
        Enum.random(types)
      else
        "test_annotation"
      end

    annotation_content(type, opts)
  end

  # Tool Builders

  @doc """
  Builds a tool definition for testing.

  ## Examples

      # Simple tool
      tool("sample_tool")

      # Tool with custom description
      tool("sample_tool", description: "Custom description")

      # Tool with complex schema
      tool("complex_tool", schema: object_schema(%{
        "name" => string_schema(),
        "age" => integer_schema()
      }))

      # Random tool
      tool(random: true)
  """
  @spec tool(String.t() | nil, builder_opts()) :: map()
  def tool(name \\ nil, opts \\ [])

  def tool(name, opts) when is_binary(name) do
    description = Keyword.get(opts, :description, "A test tool")
    schema = Keyword.get(opts, :schema, object_schema())

    %{
      "name" => name,
      "description" => description,
      "inputSchema" => schema
    }
  end

  def tool(nil, opts) do
    name =
      if Keyword.get(opts, :random, false) do
        "tool_#{random_string(8)}"
      else
        "sample_tool"
      end

    tool(name, opts)
  end

  @doc """
  Builds a tool result for testing.

  ## Examples

      # Simple text result
      tool_result("Operation completed")

      # Multiple content items
      tool_result([
        text_content("Result 1"),
        text_content("Result 2")
      ])

      # Error result
      tool_result(error: "Something went wrong")
  """
  @spec tool_result(String.t() | [Protocol.content()] | nil, builder_opts()) :: map()
  def tool_result(content \\ nil, opts \\ [])

  def tool_result(content, opts) when is_binary(content) do
    tool_result([text_content(content)], opts)
  end

  def tool_result(content_list, _opts) when is_list(content_list) do
    serialized_content = Enum.map(content_list, &Protocol.serialize/1)

    %{"content" => serialized_content}
  end

  def tool_result(nil, opts) do
    if Keyword.has_key?(opts, :error) do
      %{
        "isError" => true,
        "content" => [
          Protocol.serialize(text_content("Error: #{opts[:error]}"))
        ]
      }
    else
      tool_result("Sample tool result", opts)
    end
  end

  # Resource Builders

  @doc """
  Builds a resource definition for testing.

  ## Examples

      # Simple resource
      resource("file://data.txt", "Test Data")

      # Resource with metadata
      resource("https://api.example.com", "API",
        description: "REST API endpoint",
        mime_type: "application/json"
      )

      # Random resource
      resource(random: true)
  """
  @spec resource(String.t() | nil, String.t() | nil, builder_opts()) :: map()
  def resource(uri \\ nil, name \\ nil, opts \\ [])

  def resource(uri, name, opts) when is_binary(uri) and is_binary(name) do
    base = %{
      "uri" => uri,
      "name" => name
    }

    base
    |> maybe_add("description", Keyword.get(opts, :description))
    |> maybe_add("mimeType", Keyword.get(opts, :mime_type))
  end

  def resource(nil, nil, opts) do
    if Keyword.get(opts, :random, false) do
      schemes = ["file", "http", "https"]
      scheme = Enum.random(schemes)
      uri = "#{scheme}://example.com/#{random_string(10)}"
      name = "Resource #{random_string(5)}"
      resource(uri, name, opts)
    else
      resource("file://test_resource.txt", "Test Resource", opts)
    end
  end

  @doc """
  Builds resource data for testing.

  ## Examples

      # Text resource data
      resource_data("Hello world", "text/plain")

      # Binary resource data
      resource_data(random: true, mime_type: "application/octet-stream", size: 1024)
  """
  @spec resource_data(String.t() | nil, String.t() | nil, builder_opts()) :: map()
  def resource_data(content \\ nil, mime_type \\ nil, opts \\ [])

  def resource_data(content, mime_type, opts) when is_binary(content) do
    %{
      "contents" => [
        %{
          "uri" => Keyword.get(opts, :uri, "file://test.txt"),
          "mimeType" => mime_type || "text/plain",
          "text" => content
        }
      ]
    }
  end

  def resource_data(nil, mime_type, opts) do
    if Keyword.get(opts, :random, false) do
      size = Keyword.get(opts, :size, 100)
      content = random_text(size)
      resource_data(content, mime_type || "text/plain", opts)
    else
      resource_data("Sample resource content", mime_type, opts)
    end
  end

  # Prompt Builders

  @doc """
  Builds a prompt definition for testing.

  ## Examples

      # Simple prompt
      prompt("sample_prompt", "A test prompt")

      # Prompt with arguments
      prompt("complex_prompt", "Complex prompt", arguments: [
        prompt_argument("topic", "The topic to discuss", required: true),
        prompt_argument("style", "Writing style", required: false)
      ])

      # Random prompt
      prompt(random: true)
  """
  @spec prompt(String.t() | nil, String.t() | nil, builder_opts()) :: map()
  def prompt(name \\ nil, description \\ nil, opts \\ [])

  def prompt(name, description, opts) when is_binary(name) and is_binary(description) do
    base = %{
      "name" => name,
      "description" => description
    }

    case Keyword.get(opts, :arguments) do
      nil -> base
      arguments when is_list(arguments) -> Map.put(base, "arguments", arguments)
    end
  end

  def prompt(nil, nil, opts) do
    if Keyword.get(opts, :random, false) do
      name = "prompt_#{random_string(8)}"
      description = "A test prompt for #{random_string(10)}"
      prompt(name, description, opts)
    else
      prompt("sample_prompt", "A sample test prompt", opts)
    end
  end

  @doc """
  Builds a prompt argument for testing.

  ## Examples

      # Required argument
      prompt_argument("topic", "The topic to discuss", required: true)

      # Optional argument
      prompt_argument("style", "Writing style", required: false)
  """
  @spec prompt_argument(String.t(), String.t(), builder_opts()) :: map()
  def prompt_argument(name, description, opts \\ []) do
    base = %{
      "name" => name,
      "description" => description
    }

    case Keyword.get(opts, :required) do
      nil -> base
      required -> Map.put(base, "required", required)
    end
  end

  @doc """
  Builds prompt data for testing.

  ## Examples

      # Simple prompt result
      prompt_data("Write about: space exploration")

      # Prompt with multiple messages
      prompt_data([
        %{"role" => "system", "content" => "You are a helpful assistant"},
        %{"role" => "user", "content" => "Hello"}
      ])
  """
  @spec prompt_data(String.t() | [map()], builder_opts()) :: map()
  def prompt_data(content, opts \\ [])

  def prompt_data(content, _opts) when is_binary(content) do
    %{
      "description" => "Generated prompt",
      "messages" => [
        %{
          "role" => "user",
          "content" => %{
            "type" => "text",
            "text" => content
          }
        }
      ]
    }
  end

  def prompt_data(messages, _opts) when is_list(messages) do
    %{
      "description" => "Generated prompt with messages",
      "messages" => messages
    }
  end

  # Message Builders

  @doc """
  Builds an MCP request message for testing.

  ## Examples

      # Simple request
      request("list_tools", id: 1)

      # Request with parameters
      request("call_tool", id: 2, params: %{
        "name" => "sample_tool",
        "arguments" => %{"input" => "test"}
      })
  """
  @spec request(String.t(), builder_opts()) :: map()
  def request(method, opts \\ []) do
    id = Keyword.get(opts, :id, :rand.uniform(1000))
    params = Keyword.get(opts, :params)

    base = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id
    }

    case params do
      nil -> base
      params -> Map.put(base, "params", params)
    end
  end

  @doc """
  Builds an MCP success response for testing.

  ## Examples

      # Simple success response
      success_response(1, %{"tools" => []})

      # Tool call response
      success_response(2, tool_result("Success"))
  """
  @spec success_response(integer(), any()) :: map()
  def success_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  @doc """
  Builds an MCP error response for testing.

  ## Examples

      # Method not found error
      error_response(1, -32601, "Method not found")

      # Custom error with data
      error_response(2, -1, "Tool error", %{"details" => "Something went wrong"})
  """
  @spec error_response(integer(), integer(), String.t(), any()) :: map()
  def error_response(id, code, message, data \\ nil) do
    error = %{
      "code" => code,
      "message" => message
    }

    error =
      case data do
        nil -> error
        data -> Map.put(error, "data", data)
      end

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    }
  end

  @doc """
  Builds an MCP notification for testing.

  ## Examples

      # Simple notification
      notification("notifications/message", %{"level" => "info", "text" => "Hello"})

      # Progress notification
      notification("notifications/progress", %{
        "progressToken" => "task_1",
        "progress" => 50,
        "total" => 100
      })
  """
  @spec notification(String.t(), map()) :: map()
  def notification(method, params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }
  end

  # Schema Builders

  @doc """
  Builds a JSON Schema object for testing.

  ## Examples

      # Simple object schema
      object_schema()

      # Object with properties
      object_schema(%{
        "name" => string_schema(),
        "age" => integer_schema(minimum: 0),
        "email" => string_schema(format: "email")
      })

      # Required properties
      object_schema(%{"name" => string_schema()}, required: ["name"])
  """
  @spec object_schema(map() | nil, builder_opts()) :: map()
  def object_schema(properties \\ nil, opts \\ []) do
    base = %{"type" => "object"}

    base =
      case properties do
        nil -> Map.put(base, "properties", %{})
        props -> Map.put(base, "properties", props)
      end

    case Keyword.get(opts, :required) do
      nil -> base
      required -> Map.put(base, "required", required)
    end
  end

  @doc """
  Builds a string JSON Schema for testing.

  ## Examples

      string_schema()
      string_schema(min_length: 1, max_length: 100)
      string_schema(pattern: "^[a-z]+$")
      string_schema(format: "email")
  """
  @spec string_schema(builder_opts()) :: map()
  def string_schema(opts \\ []) do
    base = %{"type" => "string"}

    base
    |> maybe_add("minLength", Keyword.get(opts, :min_length))
    |> maybe_add("maxLength", Keyword.get(opts, :max_length))
    |> maybe_add("pattern", Keyword.get(opts, :pattern))
    |> maybe_add("format", Keyword.get(opts, :format))
    |> maybe_add("description", Keyword.get(opts, :description))
    |> maybe_add("enum", Keyword.get(opts, :enum))
  end

  @doc """
  Builds an integer JSON Schema for testing.

  ## Examples

      integer_schema()
      integer_schema(minimum: 0, maximum: 100)
      integer_schema(multiple_of: 5)
  """
  @spec integer_schema(builder_opts()) :: map()
  def integer_schema(opts \\ []) do
    base = %{"type" => "integer"}

    base
    |> maybe_add("minimum", Keyword.get(opts, :minimum))
    |> maybe_add("maximum", Keyword.get(opts, :maximum))
    |> maybe_add("multipleOf", Keyword.get(opts, :multiple_of))
  end

  @doc """
  Builds an array JSON Schema for testing.

  ## Examples

      array_schema(string_schema())
      array_schema(object_schema(), min_items: 1, max_items: 10)
  """
  @spec array_schema(map() | nil, builder_opts()) :: map()
  def array_schema(items \\ nil, opts \\ []) do
    base = %{"type" => "array"}

    base =
      case items do
        nil -> base
        items -> Map.put(base, "items", items)
      end

    base
    |> maybe_add("minItems", Keyword.get(opts, :min_items))
    |> maybe_add("maxItems", Keyword.get(opts, :max_items))
    |> maybe_add("uniqueItems", Keyword.get(opts, :unique_items))
  end

  # Random Data Generators

  @doc """
  Generates random text of specified length.
  """
  @spec random_text(pos_integer()) :: String.t()
  def random_text(length) do
    words = [
      "hello",
      "world",
      "test",
      "sample",
      "data",
      "content",
      "message",
      "example",
      "demo",
      "mock"
    ]

    Stream.repeatedly(fn -> Enum.random(words) end)
    |> Enum.take(div(length, 5) + 1)
    |> Enum.join(" ")
    |> String.slice(0, length)
  end

  @doc """
  Generates random string of specified length.
  """
  @spec random_string(pos_integer()) :: String.t()
  def random_string(length) do
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"

    1..length
    |> Enum.map_join("", fn _ ->
      String.at(chars, :rand.uniform(String.length(chars)) - 1)
    end)
  end

  @doc """
  Generates random bytes.
  """
  @spec random_bytes(pos_integer()) :: binary()
  def random_bytes(size) do
    :crypto.strong_rand_bytes(size)
  end

  # Helper Functions

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
