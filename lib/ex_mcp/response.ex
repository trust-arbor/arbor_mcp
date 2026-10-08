defmodule ExMCP.Response do
  @moduledoc """
  Structured response types for MCP operations.

  This module provides structured response handling for MCP tool calls,
  resource reads, and other operations, giving callers type-safe responses
  instead of raw maps.

  ## Response Types

  - `:text` - Simple text responses
  - `:json` - Structured JSON data
  - `:error` - Error responses with detailed information
  - `:tools` - Tool listing responses
  - `:resources` - Resource listing responses
  - `:prompts` - Prompt listing responses
  - `:server_info` - Server information responses
  - `:mixed` - Responses with multiple content types

  ## Usage

      # Create a text response
      response = ExMCP.Response.text("Hello, world!", "greeting_tool")

      # Create a JSON response
      response = ExMCP.Response.json(%{result: 42}, "calculator")

      # Create an error response
      response = ExMCP.Response.error("Invalid input", "validation_tool")

      # Extract content
      text = ExMCP.Response.text_content(response)
      json = ExMCP.Response.json_content(response)

  ## Protocol Data Handling

  Protocol data from MCP servers is kept as string-keyed maps to maintain
  compatibility with the MCP JSON-RPC protocol and avoid atom exhaustion issues.

      # Tools, resources, and prompts use string keys
      response.tools
      #=> [%{"name" => "hello", "description" => "Says hello", "inputSchema" => %{...}}]

      # Use accessor functions for convenience
      tool = hd(response.tools)
      ExMCP.Response.tool_name(tool)        #=> "hello"
      ExMCP.Response.tool_description(tool)  #=> "Says hello"
      ExMCP.Response.tool_input_schema(tool) #=> %{"type" => "object", ...}

  ## Design Rationale

  The structured response type provides:
  - Type safety and consistency across all MCP operations
  - Clear extraction functions for different content types
  - Metadata support for tracing and debugging
  - Unified error handling
  - Protocol fidelity by keeping MCP data as strings
  - Protection against atom exhaustion attacks
  """

  defstruct [
    :content,
    :meta,
    :tool_name,
    :request_id,
    :server_info,
    :is_error,
    # 2026-07-28 result envelope and cache metadata
    :resultType,
    :ttlMs,
    :cacheScope,
    # 2025-06-18 features
    :structuredOutput,
    :resourceLinks,
    # List response fields
    :tools,
    :resources,
    :prompts,
    :messages,
    :roots,
    :resourceTemplates,
    # Pagination fields
    :nextCursor,
    # Resource read response
    :contents,
    # Prompt get response
    :description,
    # Completion field (extracted from structuredOutput for direct access)
    :completion,
    # Wire presence and extensions preserve nulls/omissions without retaining a second payload.
    :wire_keys,
    :content_keys,
    :extra_fields
  ]

  @wire_fields [
    "content",
    "_meta",
    "meta",
    "isError",
    "is_error",
    "resultType",
    "ttlMs",
    "cacheScope",
    "structuredContent",
    "structuredOutput",
    "resourceLinks",
    "tools",
    "resources",
    "prompts",
    "messages",
    "roots",
    "resourceTemplates",
    "nextCursor",
    "contents",
    "description",
    "completion"
  ]

  @type t :: %__MODULE__{
          content: [content_item()],
          meta: map() | nil,
          tool_name: String.t() | nil,
          request_id: String.t() | nil,
          server_info: map() | nil,
          is_error: boolean(),
          # 2026-07-28 result envelope and cache metadata
          resultType: String.t() | nil,
          ttlMs: non_neg_integer() | nil,
          cacheScope: String.t() | nil,
          # 2025-06-18 features
          structuredOutput: any() | nil,
          resourceLinks: [map()] | nil,
          # List response fields
          tools: [map()] | nil,
          resources: [map()] | nil,
          prompts: [map()] | nil,
          messages: [map()] | nil,
          roots: [map()] | nil,
          resourceTemplates: [map()] | nil,
          # Pagination fields
          nextCursor: String.t() | nil,
          # Resource read response
          contents: [map()] | nil,
          # Prompt get response
          description: String.t() | nil,
          # Completion field (extracted from structuredOutput for direct access)
          completion: map() | nil,
          wire_keys: [String.t()] | nil,
          content_keys: [[String.t()]] | nil,
          extra_fields: map() | nil
        }

  @type content_item :: %{
          type: String.t(),
          text: String.t() | nil,
          data: any() | nil,
          annotations: map() | nil
        }

  @doc """
  Creates a response from a raw MCP response.

  ## Examples

      iex> raw = %{"content" => [%{"type" => "text", "text" => "Hello"}]}
      iex> ExMCP.Response.from_raw_response(raw)
      %ExMCP.Response{
        content: [%{type: "text", text: "Hello", data: nil, annotations: nil}],
        meta: nil,
        tool_name: nil,
        request_id: nil,
        server_info: nil,
        is_error: false
      }
  """
  @spec from_raw_response(map(), keyword()) :: t()
  def from_raw_response(raw_response, opts \\ []) when is_map(raw_response) do
    # Handle tool content
    content = normalize_content(Map.get(raw_response, "content", []))

    # Normalize messages field for struct-like access
    messages =
      case Map.get(raw_response, "messages") do
        messages when is_list(messages) ->
          # Normalize each message to have atom keys and preserve content structure
          Enum.map(messages, &normalize_message_for_struct_access/1)

        other ->
          other
      end

    %__MODULE__{
      content: content,
      meta: Map.get(raw_response, "_meta", Map.get(raw_response, "meta")),
      tool_name: Keyword.get(opts, :tool_name),
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info),
      is_error: Map.get(raw_response, "isError", Map.get(raw_response, "is_error", false)),
      resultType: Map.get(raw_response, "resultType"),
      ttlMs: Map.get(raw_response, "ttlMs"),
      cacheScope: Map.get(raw_response, "cacheScope"),
      # 2025-06-18 features
      structuredOutput: structured_output(raw_response),
      resourceLinks: Map.get(raw_response, "resourceLinks"),
      # List response fields - normalize for struct access while keeping strings
      tools: normalize_list_items(Map.get(raw_response, "tools")),
      resources: normalize_list_items(Map.get(raw_response, "resources")),
      prompts: normalize_list_items(Map.get(raw_response, "prompts")),
      messages: messages,
      roots: normalize_list_items(Map.get(raw_response, "roots")),
      resourceTemplates: normalize_list_items(Map.get(raw_response, "resourceTemplates")),
      # Pagination fields - only include nextCursor if present and non-nil
      nextCursor: Map.get(raw_response, "nextCursor"),
      # Resource read response
      contents: normalize_list_items(Map.get(raw_response, "contents")),
      # Prompt get response
      description: Map.get(raw_response, "description"),
      # Completion field (extracted from structuredOutput or direct)
      completion: extract_completion(raw_response),
      wire_keys: Map.keys(raw_response),
      content_keys: content_keys(Map.get(raw_response, "content", [])),
      extra_fields: wire_extensions(raw_response)
    }
  end

  @doc """
  Creates an error response.

  ## Examples

      iex> ExMCP.Response.error("Tool execution failed", "calculate_sum")
      %ExMCP.Response{
        content: [%{type: "text", text: "Error: Tool execution failed", data: nil, annotations: nil}],
        meta: nil,
        tool_name: "calculate_sum",
        request_id: nil,
        server_info: nil,
        is_error: true
      }
  """
  @spec error(String.t(), String.t() | nil, keyword()) :: t()
  def error(message, tool_name \\ nil, opts \\ []) do
    content = [
      %{
        type: "text",
        text: "Error: #{message}",
        data: nil,
        annotations: nil
      }
    ]

    %__MODULE__{
      content: content,
      meta: Keyword.get(opts, :meta),
      tool_name: tool_name,
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info),
      is_error: true
    }
  end

  @doc """
  Creates a success response with text content.

  ## Examples

      iex> ExMCP.Response.text("Hello, World!", "say_hello")
      %ExMCP.Response{
        content: [%{type: "text", text: "Hello, World!", data: nil, annotations: nil}],
        meta: nil,
        tool_name: "say_hello",
        request_id: nil,
        server_info: nil,
        is_error: false
      }
  """
  @spec text(String.t(), String.t() | nil, keyword()) :: t()
  def text(text_content, tool_name \\ nil, opts \\ []) do
    content = [
      %{
        type: "text",
        text: text_content,
        data: nil,
        annotations: Keyword.get(opts, :annotations)
      }
    ]

    %__MODULE__{
      content: content,
      meta: Keyword.get(opts, :meta),
      tool_name: tool_name,
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info),
      is_error: false
    }
  end

  @doc """
  Creates a response with JSON data content.

  ## Examples

      iex> data = %{"result" => 42}
      iex> ExMCP.Response.json(data, "calculate")
      %ExMCP.Response{
        content: [%{type: "text", text: nil, data: %{"result" => 42}, annotations: nil}],
        meta: nil,
        tool_name: "calculate",
        request_id: nil,
        server_info: nil,
        is_error: false
      }
  """
  @spec json(any(), String.t() | nil, keyword()) :: t()
  def json(data, tool_name \\ nil, opts \\ []) do
    content = [
      %{
        type: "text",
        text: nil,
        data: data,
        annotations: Keyword.get(opts, :annotations)
      }
    ]

    %__MODULE__{
      content: content,
      meta: Keyword.get(opts, :meta),
      tool_name: tool_name,
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info),
      is_error: false
    }
  end

  @doc """
  Checks if the response represents an error.
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{is_error: is_error}), do: is_error

  @doc """
  Gets the text content from the response.

  Returns the first text content item, or nil if none exists.
  """
  @spec text_content(t()) :: String.t() | nil
  def text_content(%__MODULE__{content: content}) do
    content
    |> Enum.find(&(&1.type == "text" && &1.text))
    |> case do
      %{text: text} -> text
      _ -> nil
    end
  end

  @doc """
  Gets all text content from the response as a concatenated string.
  """
  @spec all_text_content(t()) :: String.t()
  def all_text_content(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1.type == "text" && &1.text))
    |> Enum.map_join("\n", & &1.text)
  end

  @doc """
  Gets the data content from the response.

  Returns the first data content item, or nil if none exists.
  """
  @spec data_content(t()) :: any()
  def data_content(%__MODULE__{content: content}) do
    content
    |> Enum.find(& &1.data)
    |> case do
      %{data: data} -> data
      _ -> nil
    end
  end

  @doc """
  Gets the resource content from the response.

  Returns the text from the first resource content item, or nil if none exists.
  This is used for resource read responses that have a `contents` field.
  """
  @spec resource_content(t()) :: String.t() | nil
  def resource_content(%__MODULE__{contents: nil}), do: nil

  def resource_content(%__MODULE__{contents: contents}) do
    contents
    |> Enum.find(&(Map.get(&1, :text) || Map.get(&1, "text")))
    |> case do
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end
  end

  @doc """
  Creates a Response struct from a plain map (backward compatibility).

  This is useful for tests that expect to work with plain maps.
  If the input is already a Response struct, returns it unchanged.

  ## Examples

      iex> map = %{"tools" => [%{"name" => "test"}], "nextCursor" => "abc"}
      iex> response = ExMCP.Response.from_map(map)
      iex> response.tools
      [%{"name" => "test"}]
      iex> response.nextCursor
      "abc"
  """
  @spec from_map(map() | t()) :: t()
  def from_map(%__MODULE__{} = response), do: response
  def from_map(map) when is_map(map), do: from_raw_response(map)

  @doc """
  Converts retained response fields back to string-keyed MCP format.

  Responses decoded from wire maps preserve field presence, explicit false/null,
  content extensions and top-level extensions. Locally constructed responses
  emit populated fields using `structuredContent` and the 1.x `meta` spelling;
  locally constructed false `isError` values remain omitted for compatibility.
  Application-only fields such as `tool_name` are not sent to the peer.
  """
  @spec to_raw(t()) :: map()
  def to_raw(%__MODULE__{} = response) do
    fields = [
      {"content", raw_content(response.content, response.content_keys)},
      {"_meta", response.meta},
      {"meta", response.meta},
      {"isError", response.is_error},
      {"is_error", response.is_error},
      {"resultType", response.resultType},
      {"ttlMs", response.ttlMs},
      {"cacheScope", response.cacheScope},
      {"structuredContent", response.structuredOutput},
      {"structuredOutput", response.structuredOutput},
      {"resourceLinks", raw_items(response.resourceLinks)},
      {"tools", raw_items(response.tools)},
      {"resources", raw_items(response.resources)},
      {"prompts", raw_items(response.prompts)},
      {"messages", raw_messages(response.messages)},
      {"roots", raw_items(response.roots)},
      {"resourceTemplates", raw_items(response.resourceTemplates)},
      {"nextCursor", response.nextCursor},
      {"contents", raw_items(response.contents)},
      {"description", response.description},
      {"completion", raw_item(response.completion)}
    ]

    Enum.reduce(fields, response.extra_fields || %{}, fn {key, value}, acc ->
      if wire_field?(response.wire_keys, key, value) and not Map.has_key?(acc, key),
        do: Map.put(acc, key, value),
        else: acc
    end)
  end

  defp wire_extensions(raw) do
    aliases = [
      {"_meta", "meta"},
      {"isError", "is_error"},
      {"structuredContent", "structuredOutput"}
    ]

    Enum.reduce(aliases, Map.drop(raw, @wire_fields), fn {canonical, legacy}, extensions ->
      if Map.has_key?(raw, canonical) and Map.has_key?(raw, legacy),
        do: Map.put(extensions, legacy, raw[legacy]),
        else: extensions
    end)
  end

  # Preserve the 1.x spelling and false omission for locally constructed responses.
  # Decoded responses below retain their original wire presence instead.
  defp wire_field?(nil, "isError", value), do: value not in [nil, false]

  defp wire_field?(nil, key, value),
    do: not is_nil(value) and key not in ["_meta", "is_error", "structuredOutput"]

  defp wire_field?(keys, key, _value), do: key in keys

  defp content_keys(content) when is_list(content),
    do: Enum.map(content, &content_item_keys/1)

  defp content_keys(_content), do: []

  defp content_item_keys(item)
       when is_map_key(item, :type) or is_map_key(item, :text) or is_map_key(item, :data) or
              is_map_key(item, :annotations) do
    Enum.map(Map.keys(item), fn
      key when key in [:type, :text, :data, :annotations] -> Atom.to_string(key)
      key -> key
    end)
  end

  defp content_item_keys(item) when is_map(item), do: Map.keys(item)
  defp content_item_keys(_item), do: []

  defp raw_content(nil, _keys), do: nil
  defp raw_content(content, nil), do: Enum.map(content, &content_item_to_raw/1)

  defp raw_content([], _keys), do: []

  defp raw_content([item | content], [keys | rest]) do
    [content_item_to_raw(item, keys) | raw_content(content, rest)]
  end

  defp raw_content(content, []), do: Enum.map(content, &content_item_to_raw/1)

  defp raw_items(items) when is_list(items), do: Enum.map(items, &raw_item/1)
  defp raw_items(items), do: items

  defp raw_item(item) when is_map(item) do
    Map.reject(item, fn {key, _value} ->
      is_atom(key) and
        (Map.has_key?(item, Atom.to_string(key)) or
           (key == :mime_type and Map.has_key?(item, "mimeType")) or
           (key == :uri_template and Map.has_key?(item, "uriTemplate")))
    end)
  end

  defp raw_item(item), do: item

  defp raw_messages(nil), do: nil
  defp raw_messages(messages) when is_list(messages), do: Enum.map(messages, &raw_message/1)
  defp raw_messages(other), do: other

  defp raw_message(%{role: role, content: content} = message) do
    message
    |> Map.drop([:role, :content])
    |> Map.put("role", role)
    |> Map.put("content", raw_message_content(content))
  end

  defp raw_message(message), do: message

  defp raw_message_content(content) when is_list(content),
    do: Enum.map(content, &raw_message_content/1)

  defp raw_message_content(%{type: type, text: text} = content),
    do: content |> Map.drop([:type, :text]) |> Map.put("type", type) |> Map.put("text", text)

  defp raw_message_content(content), do: content

  @doc """
  Converts the response to a map that excludes nil pagination fields.

  This is useful for tests that expect `Map.has_key?/2` to return false
  for pagination fields when they are not present in the original response.
  """
  @spec to_test_map(t()) :: map()
  def to_test_map(%__MODULE__{} = response) do
    base = %{
      content: response.content,
      meta: response.meta,
      tool_name: response.tool_name,
      request_id: response.request_id,
      server_info: response.server_info,
      is_error: response.is_error,
      structuredOutput: response.structuredOutput,
      resourceLinks: response.resourceLinks,
      tools: response.tools,
      resources: response.resources,
      prompts: response.prompts,
      messages: response.messages,
      roots: response.roots,
      resourceTemplates: response.resourceTemplates,
      contents: response.contents,
      description: response.description,
      completion: response.completion
    }

    # Only include nextCursor if it's not nil
    if response.nextCursor do
      Map.put(base, :nextCursor, response.nextCursor)
    else
      base
    end
  end

  defp structured_output(raw) do
    case Map.fetch(raw, "structuredContent") do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(raw, "structuredOutput") do
          {:ok, value} -> value
          :error -> if(Map.has_key?(raw, "completion"), do: raw, else: nil)
        end
    end
  end

  # Private helper functions

  defp extract_completion(raw_response) do
    completion =
      cond do
        # Direct completion field
        Map.has_key?(raw_response, "completion") ->
          Map.get(raw_response, "completion")

        # Completion in structuredOutput
        is_map(raw_response["structuredOutput"]) and
            Map.has_key?(raw_response["structuredOutput"], "completion") ->
          raw_response["structuredOutput"]["completion"]

        true ->
          nil
      end

    # Normalize completion object to support both string and atom keys
    if is_map(completion) do
      normalize_item_keys(completion)
    else
      completion
    end
  end

  # Normalize message for struct-like access while preserving content structure
  defp normalize_message_for_struct_access(%{role: role, content: content} = message) do
    # Already has atom keys
    message_with_content(role, content, message)
  end

  defp normalize_message_for_struct_access(%{"role" => role, "content" => content} = message) do
    # Convert string keys to atom keys and normalize content
    message_with_content(role, content, message)
  end

  defp normalize_message_for_struct_access(message), do: message

  defp message_with_content(role, content, message) do
    message
    |> Map.drop(["role", "content"])
    |> Map.put(:role, role)
    |> Map.put(:content, normalize_content_for_struct_access(content))
  end

  # Normalize content structure for struct-like access (preserve type and text fields)
  defp normalize_content_for_struct_access(%{type: type, text: text} = content) do
    # Already has atom keys
    content |> Map.drop(["type", "text"]) |> Map.put(:type, type) |> Map.put(:text, text)
  end

  defp normalize_content_for_struct_access(%{"type" => type, "text" => text} = content) do
    # Convert to atom keys for struct-like access
    content |> Map.drop(["type", "text"]) |> Map.put(:type, type) |> Map.put(:text, text)
  end

  defp normalize_content_for_struct_access(content), do: content

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, &normalize_content_item/1)
  end

  defp normalize_content(_), do: []

  defp normalize_content_item(%{"type" => type} = item) do
    Map.merge(Map.drop(item, ["type", "text", "data", "annotations"]), %{
      type: type,
      text: Map.get(item, "text", Map.get(item, :text)),
      data: Map.get(item, "data", Map.get(item, :data)),
      annotations: Map.get(item, "annotations", Map.get(item, :annotations))
    })
  end

  defp normalize_content_item(%{type: type} = item) do
    Map.merge(Map.drop(item, [:type, :text, :data, :annotations]), %{
      type: type,
      text: Map.get(item, "text", Map.get(item, :text)),
      data: Map.get(item, "data", Map.get(item, :data)),
      annotations: Map.get(item, "annotations", Map.get(item, :annotations))
    })
  end

  defp normalize_content_item(item) when is_map(item) do
    # Handle legacy content format
    %{
      type: "text",
      text: Map.get(item, "text"),
      data: Map.get(item, "data"),
      annotations: Map.get(item, "annotations")
    }
  end

  defp normalize_content_item(_), do: nil

  defp content_item_to_raw(item), do: content_item_to_raw(item, nil)

  defp content_item_to_raw(%{type: type} = item, keys) do
    fields = [
      {"type", type},
      {"text", item.text},
      {"data", item.data},
      {"annotations", item.annotations}
    ]

    Enum.reduce(fields, Map.drop(item, [:type, :text, :data, :annotations]), fn {key, value},
                                                                                acc ->
      if (keys && key in keys) || (is_nil(keys) && not is_nil(value)),
        do: Map.put(acc, key, value),
        else: acc
    end)
  end

  defp content_item_to_raw(item, _keys), do: item

  # Note: Protocol data is kept as strings to maintain compatibility with MCP
  # and avoid atom exhaustion issues. Use accessor functions for convenience.

  @doc """
  Gets the tool name from a tool definition.

  Accepts decoded string keys and native BEAM atom keys. String-key presence
  takes precedence, including explicit null, without creating atoms.

  ## Examples

      iex> tool = %{"name" => "hello", "description" => "Says hello"}
      iex> ExMCP.Response.tool_name(tool)
      "hello"
  """
  def tool_name(%{"name" => name}), do: name
  def tool_name(%{name: name}), do: name
  def tool_name(_), do: nil

  @doc """
  Gets the tool description from a tool definition.

  ## Examples

      iex> tool = %{"name" => "hello", "description" => "Says hello"}
      iex> ExMCP.Response.tool_description(tool)
      "Says hello"
  """
  def tool_description(%{"description" => desc}), do: desc
  def tool_description(%{description: desc}), do: desc
  def tool_description(_), do: nil

  @doc """
  Gets the input schema from a tool definition.

  ## Examples

      iex> tool = %{"name" => "hello", "inputSchema" => %{"type" => "object"}}
      iex> ExMCP.Response.tool_input_schema(tool)
      %{"type" => "object"}
  """
  def tool_input_schema(%{"inputSchema" => schema}), do: schema
  def tool_input_schema(%{inputSchema: schema}), do: schema
  def tool_input_schema(_), do: nil

  @doc """
  Gets a property from a schema properties map.

  ## Examples

      iex> schema = %{"properties" => %{"name" => %{"type" => "string"}}}
      iex> ExMCP.Response.schema_property(schema, "name")
      %{"type" => "string"}
  """
  def schema_property(%{"properties" => props}, key) when is_map(props) do
    property_value(props, key)
  end

  def schema_property(%{"properties" => _props}, _key), do: nil

  def schema_property(%{properties: props}, key) when is_map(props),
    do: property_value(props, key)

  def schema_property(_, _), do: nil

  defp property_value(props, key) do
    case Map.fetch(props, key) do
      {:ok, value} -> value
      :error when is_atom(key) -> Map.get(props, Atom.to_string(key))
      :error when is_binary(key) -> Map.get(props, existing_atom_or_string(key))
      :error -> nil
    end
  end

  # Implement Access behavior for dot-notation access to string-keyed maps
  @behaviour Access

  @impl Access
  def fetch(%__MODULE__{} = response, key) when is_atom(key) do
    case key do
      :completion ->
        case response.structuredOutput do
          %{"completion" => completion} -> {:ok, completion}
          _ -> :error
        end

      _ ->
        case Map.get(response, key) do
          nil -> :error
          value -> {:ok, value}
        end
    end
  end

  @impl Access
  def fetch(_, _), do: :error

  @impl Access
  def get_and_update(_, _, _), do: raise("ExMCP.Response is read-only")

  @impl Access
  def pop(_, _), do: raise("ExMCP.Response is read-only")

  @doc """
  Gets completion data from response.

  Handles both direct completion field and structuredOutput.completion.
  """
  @spec completion(t()) :: map() | nil
  def completion(%__MODULE__{structuredOutput: %{"completion" => completion}}), do: completion

  def completion(%__MODULE__{} = response) do
    # Check if response has completion in structuredOutput
    case response.structuredOutput do
      %{"completion" => completion} -> completion
      _ -> nil
    end
  end

  # Normalizes list items to have both string and atom keys for backward compatibility.
  # This ensures tests can use either `item["name"]` or `item.name` syntax.
  defp normalize_list_items(items) when is_list(items) do
    Enum.map(items, &normalize_item_keys/1)
  end

  defp normalize_list_items(items), do: items

  # Known safe keys that we can convert to atoms
  @safe_atom_keys ~w(name description required uri text type mime_type mimeType blob arguments inputSchema outputSchema role content values total hasMore uriTemplate uri_template properties enum a b operation)

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp normalize_item_keys(item) when is_map(item) do
    # Create a map that works with both string and atom access for known safe keys
    atom_keys =
      for {k, v} <- item, into: %{} do
        normalized_value =
          cond do
            k == "arguments" and is_list(v) ->
              # Recursively normalize arguments list
              normalize_list_items(v)

            k in ["inputSchema", "outputSchema"] and is_map(v) ->
              # Recursively normalize schema objects
              normalize_item_keys(v)

            k == "properties" and is_map(v) ->
              # JSON schema property names are user-controlled. Keep keys as strings
              # instead of creating atoms for arbitrary names.
              for {prop_key, prop_value} <- v, into: %{} do
                normalized_value =
                  if is_map(prop_value), do: normalize_item_keys(prop_value), else: prop_value

                {prop_key, normalized_value}
              end

            true ->
              v
          end

        if is_binary(k) and k in @safe_atom_keys do
          {existing_atom_or_string(k), normalized_value}
        else
          {k, normalized_value}
        end
      end

    # Add special handling for camelCase to underscore conversions
    atom_keys =
      if Map.has_key?(item, "mimeType") or Map.has_key?(atom_keys, :mimeType) do
        mime_type_value = Map.get(item, "mimeType") || Map.get(atom_keys, :mimeType)
        Map.put(atom_keys, :mime_type, mime_type_value)
      else
        atom_keys
      end

    atom_keys =
      if Map.has_key?(item, "uriTemplate") or Map.has_key?(atom_keys, :uriTemplate) do
        uri_template_value = Map.get(item, "uriTemplate") || Map.get(atom_keys, :uriTemplate)
        Map.put(atom_keys, :uri_template, uri_template_value)
      else
        atom_keys
      end

    # Merge original map with atom keys, prioritizing string keys
    Map.merge(atom_keys, item)
  end

  defp normalize_item_keys(item), do: item

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
