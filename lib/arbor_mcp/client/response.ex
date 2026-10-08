defmodule Arbor.MCP.Client.Response do
  @moduledoc """
  Response normalization and transformation utilities for MCP.

  This module provides consistent, developer-friendly response formats
  by normalizing raw MCP protocol responses into standardized structures.

  ## Features

  - Standardized field names (snake_case instead of mixed case)
  - Type coercion and validation
  - Automatic content parsing (JSON, text, etc.)
  - Error context enrichment
  - Missing field defaults

  ## Response Types

  All normalized responses follow consistent patterns:
  - Tools: `%{name, description, input_schema, metadata}`
  - Resources: `%{uri, name, description, mime_type, metadata}`
  - Prompts: `%{name, description, arguments, metadata}`
  - Content: Automatic parsing based on type detection
  """

  @type normalized_tool :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map() | nil,
          metadata: map()
        }

  @type normalized_resource :: %{
          uri: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          metadata: map()
        }

  @type normalized_prompt :: %{
          name: String.t(),
          description: String.t() | nil,
          arguments: [map()] | nil,
          metadata: map()
        }

  # Tool Response Normalization

  @doc """
  Normalizes a tool definition from MCP protocol format.

  ## Examples

      # Raw MCP response
      raw = %{
        "name" => "calculator",
        "description" => "Performs calculations",
        "inputSchema" => %{"type" => "object", "properties" => %{...}}
      }

      # Normalized response
      tool = Response.normalize_tool(raw)
      # => %{
      #   name: "calculator",
      #   description: "Performs calculations",
      #   input_schema: %{type: "object", properties: %{...}},
      #   metadata: %{}
      # }
  """
  @spec normalize_tool(map()) :: normalized_tool()
  def normalize_tool(raw_tool) when is_map(raw_tool) do
    %{
      name: Map.get(raw_tool, "name", ""),
      description: Map.get(raw_tool, "description"),
      input_schema: normalize_schema(Map.get(raw_tool, "inputSchema")),
      metadata: extract_metadata(raw_tool, ["name", "description", "inputSchema"])
    }
  end

  @doc """
  Normalizes a tool call result from MCP protocol format.

  Handles content parsing, error detection, and metadata extraction.
  """
  @spec normalize_tool_result(map()) :: any()
  def normalize_tool_result(%{"content" => content} = result) when is_list(content) do
    normalized_content = Enum.map(content, &normalize_content_item/1)

    case normalized_content do
      [single_item] when map_size(result) == 1 ->
        # Single content item, return just the value for convenience
        extract_content_value(single_item)

      _ ->
        # Multiple items or additional metadata
        %{
          content: normalized_content,
          is_error: Map.get(result, "isError", false),
          metadata: extract_metadata(result, ["content", "isError"])
        }
    end
  end

  def normalize_tool_result(%{"isError" => true} = result) do
    {:error,
     %{
       message: get_error_message(result),
       code: Map.get(result, "code"),
       metadata: extract_metadata(result, ["isError", "message", "code"])
     }}
  end

  def normalize_tool_result(result) when is_map(result) do
    # Fallback for non-standard responses
    extract_metadata(result, [])
  end

  # Resource Response Normalization

  @doc """
  Normalizes a resource definition from MCP protocol format.
  """
  @spec normalize_resource(map()) :: normalized_resource()
  def normalize_resource(raw_resource) when is_map(raw_resource) do
    %{
      uri: Map.get(raw_resource, "uri", ""),
      name: Map.get(raw_resource, "name"),
      description: Map.get(raw_resource, "description"),
      mime_type: Map.get(raw_resource, "mimeType"),
      metadata: extract_metadata(raw_resource, ["uri", "name", "description", "mimeType"])
    }
  end

  @doc """
  Normalizes resource content with automatic parsing.

  ## Options

  - `:parse_json` - Parse JSON content automatically (default: true)
  - `:encoding` - Text encoding to use (default: "utf-8")
  - `:max_size` - Maximum content size to parse (default: 10MB)
  """
  @spec normalize_resource_content(map(), keyword()) :: any()
  def normalize_resource_content(result, opts \\ [])

  def normalize_resource_content(%{"contents" => contents} = result, opts)
      when is_list(contents) do
    parse_json? = Keyword.get(opts, :parse_json, true)
    encoding = Keyword.get(opts, :encoding, "utf-8")
    # 10MB
    max_size = Keyword.get(opts, :max_size, 10 * 1024 * 1024)

    normalized_contents =
      Enum.map(contents, fn content ->
        content
        |> normalize_content_item()
        |> maybe_parse_content(parse_json?, encoding, max_size)
      end)

    case normalized_contents do
      [single_content] when map_size(result) == 1 ->
        # Single content, return value directly
        extract_content_value(single_content)

      _ ->
        # Multiple contents or additional metadata
        %{
          contents: normalized_contents,
          metadata: extract_metadata(result, ["contents"])
        }
    end
  end

  def normalize_resource_content(result, _opts) do
    extract_metadata(result, [])
  end

  # Prompt Response Normalization

  @doc """
  Normalizes a prompt definition from MCP protocol format.
  """
  @spec normalize_prompt(map()) :: normalized_prompt()
  def normalize_prompt(raw_prompt) when is_map(raw_prompt) do
    %{
      name: Map.get(raw_prompt, "name", ""),
      description: Map.get(raw_prompt, "description"),
      arguments: normalize_prompt_arguments(Map.get(raw_prompt, "arguments")),
      metadata: extract_metadata(raw_prompt, ["name", "description", "arguments"])
    }
  end

  @doc """
  Normalizes a prompt result (messages) from MCP protocol format.
  """
  @spec normalize_prompt_result(map()) :: map()
  def normalize_prompt_result(%{"messages" => messages} = result) when is_list(messages) do
    %{
      messages: Enum.map(messages, &normalize_message/1),
      metadata: extract_metadata(result, ["messages"])
    }
  end

  def normalize_prompt_result(result) do
    extract_metadata(result, [])
  end

  # Server Info Normalization

  @doc """
  Normalizes server information response.
  """
  @spec normalize_server_info(map()) :: map()
  def normalize_server_info(nil), do: %{}

  def normalize_server_info(server_info) when is_map(server_info) do
    %{
      name: Map.get(server_info, "name"),
      version: Map.get(server_info, "version"),
      metadata: extract_metadata(server_info, ["name", "version"])
    }
  end

  @doc """
  Converts a raw protocol response to a normalized format.

  This is a convenience function that handles the most common response types
  and provides a unified interface for response normalization.
  """
  @spec from_protocol(map()) :: {:ok, any()} | {:error, any()}
  def from_protocol(%{"result" => result}) do
    {:ok, result}
  end

  def from_protocol(%{"error" => error}) do
    {:error, error}
  end

  def from_protocol(response) when is_map(response) do
    {:ok, response}
  end

  def from_protocol(response) do
    {:ok, response}
  end

  # Private Implementation

  defp normalize_schema(nil), do: nil
  defp normalize_schema(schema) when is_map(schema), do: schema
  defp normalize_schema(_), do: nil

  defp normalize_content_item(%{"type" => type} = content) do
    base = %{
      type: type,
      text: Map.get(content, "text"),
      data: Map.get(content, "data"),
      uri: Map.get(content, "uri"),
      mime_type: Map.get(content, "mimeType")
    }

    base
    |> Map.merge(extract_metadata(content, ["type", "text", "data", "uri", "mimeType"]))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_content_item(content) when is_map(content) do
    # Fallback for non-standard content
    content
  end

  defp extract_content_value(%{text: text}) when not is_nil(text), do: text
  defp extract_content_value(%{data: data}) when not is_nil(data), do: data
  defp extract_content_value(%{uri: uri}) when not is_nil(uri), do: uri
  defp extract_content_value(content), do: content

  defp maybe_parse_content(
         %{text: text, mime_type: "application/json"} = content,
         true,
         _encoding,
         max_size
       )
       when is_binary(text) and byte_size(text) <= max_size do
    case Jason.decode(text) do
      {:ok, parsed} -> Map.put(content, :parsed, parsed)
      {:error, _} -> content
    end
  end

  defp maybe_parse_content(
         %{text: text, mime_type: mime_type} = content,
         true,
         _encoding,
         max_size
       )
       when is_binary(text) and byte_size(text) <= max_size do
    if String.contains?(mime_type || "", "json") do
      case Jason.decode(text) do
        {:ok, parsed} -> Map.put(content, :parsed, parsed)
        {:error, _} -> content
      end
    else
      content
    end
  end

  defp maybe_parse_content(content, _parse_json, _encoding, _max_size), do: content

  defp normalize_prompt_arguments(nil), do: nil

  defp normalize_prompt_arguments(args) when is_list(args) do
    Enum.map(args, &normalize_prompt_argument/1)
  end

  defp normalize_prompt_arguments(_), do: nil

  defp normalize_prompt_argument(%{"name" => name} = arg) do
    %{
      name: name,
      description: Map.get(arg, "description"),
      required: Map.get(arg, "required", false),
      metadata: extract_metadata(arg, ["name", "description", "required"])
    }
  end

  defp normalize_prompt_argument(arg), do: arg

  defp normalize_message(%{"role" => role, "content" => content} = message) do
    %{
      role: role,
      content: normalize_message_content(content),
      metadata: extract_metadata(message, ["role", "content"])
    }
  end

  defp normalize_message(message), do: message

  defp normalize_message_content(%{"type" => "text", "text" => text}) do
    text
  end

  defp normalize_message_content(content) when is_list(content) do
    Enum.map(content, &normalize_content_item/1)
  end

  defp normalize_message_content(content), do: content

  defp get_error_message(%{"message" => message}), do: message
  defp get_error_message(%{"error" => %{"message" => message}}), do: message
  defp get_error_message(%{"content" => [%{"text" => text} | _]}), do: text
  defp get_error_message(_), do: "Unknown error"

  defp extract_metadata(map, excluded_keys) when is_map(map) do
    map
    |> Map.drop(excluded_keys)
    |> case do
      empty when map_size(empty) == 0 -> %{}
      metadata -> metadata
    end
  end

  defp extract_metadata(_, _), do: %{}
end
