defmodule Arbor.MCP.ResponsePropertyTest do
  @moduledoc """
  Property-based tests for Arbor.MCP.Response to ensure correct transformations
  and data handling across all response types.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias Arbor.MCP.Response

  property "from_raw_response preserves all fields" do
    forall raw <- raw_response_generator() do
      response = Response.from_raw_response(raw)

      # Check that all expected fields are preserved
      (raw["content"] == nil or (response.content != nil and is_list(response.content))) and
        (raw["tools"] == nil or check_list_normalization(response.tools, raw["tools"])) and
        (raw["resources"] == nil or check_list_normalization(response.resources, raw["resources"])) and
        (raw["prompts"] == nil or check_list_normalization(response.prompts, raw["prompts"])) and
        (raw["nextCursor"] == nil or response.nextCursor == raw["nextCursor"]) and
        (raw["contents"] == nil or check_list_normalization(response.contents, raw["contents"])) and
        (raw["description"] == nil or response.description == raw["description"])
    end
  end

  property "from_map is idempotent" do
    forall raw <- raw_response_generator() do
      response1 = Response.from_map(raw)
      response2 = Response.from_map(response1)

      response1 == response2
    end
  end

  property "text_content extracts first text content" do
    forall content_list <- list(content_item_generator()) do
      raw = %{"content" => content_list}
      response = Response.from_raw_response(raw)

      text_content = Response.text_content(response)

      # Find first text content in the list
      expected =
        Enum.find_value(content_list, fn item ->
          if item["type"] == "text" && item["text"] != nil do
            item["text"]
          end
        end)

      text_content == expected
    end
  end

  property "all_text_content concatenates all text" do
    forall content_list <- list(content_item_generator()) do
      raw = %{"content" => content_list}
      response = Response.from_raw_response(raw)

      all_text = Response.all_text_content(response)

      # Get all text content
      expected_texts =
        content_list
        |> Enum.filter(&(&1["type"] == "text" && &1["text"] != nil))
        |> Enum.map(& &1["text"])

      expected = Enum.join(expected_texts, "\n")

      all_text == expected
    end
  end

  property "error responses have is_error set correctly" do
    forall {is_error, error_field} <- {boolean(), oneof(["is_error", "isError"])} do
      raw = %{error_field => is_error}
      response = Response.from_raw_response(raw)

      response.is_error == is_error and Response.error?(response) == is_error
    end
  end

  property "structuredOutput field is populated correctly" do
    forall raw <- structured_output_generator() do
      response = Response.from_raw_response(raw)

      cond do
        Map.has_key?(raw, "structuredOutput") ->
          response.structuredOutput == raw["structuredOutput"]

        Map.has_key?(raw, "structuredContent") ->
          response.structuredOutput == raw["structuredContent"]

        Map.has_key?(raw, "completion") ->
          response.structuredOutput == raw

        true ->
          response.structuredOutput == nil
      end
    end
  end

  # Generators

  defp raw_response_generator do
    frequency([
      {3, tool_response_generator()},
      {3, list_response_generator()},
      {2, resource_response_generator()},
      {2, prompt_response_generator()},
      {1, error_response_generator()}
    ])
  end

  defp content_item_generator do
    let type <- oneof(["text", "image", "resource"]) do
      let text <- oneof([nil, utf8()]) do
        let data <- oneof([nil, map(utf8(), term())]) do
          %{
            "type" => type,
            "text" => text,
            "data" => data
          }
          |> Enum.reject(fn {_k, v} -> v == nil end)
          |> Enum.into(%{})
        end
      end
    end
  end

  defp tool_response_generator do
    let(content <- list(content_item_generator()), do: %{"content" => content})
  end

  defp list_response_generator do
    let field <- oneof(["tools", "resources", "prompts"]) do
      let items <- list(map(utf8(), utf8())) do
        let cursor <- oneof([nil, utf8()]) do
          %{field => items}
          |> maybe_add_cursor(cursor)
        end
      end
    end
  end

  defp resource_response_generator do
    let(contents <- list(map(utf8(), utf8())), do: %{"contents" => contents})
  end

  defp prompt_response_generator do
    let desc <- utf8() do
      let messages <- list(message_generator()) do
        %{
          "description" => desc,
          "messages" => messages
        }
      end
    end
  end

  defp message_generator do
    let role <- oneof(["user", "assistant"]) do
      let content <- content_item_generator() do
        %{
          "role" => role,
          "content" => content
        }
      end
    end
  end

  defp error_response_generator do
    let content <- list(content_item_generator()) do
      let error_key <- oneof(["is_error", "isError"]) do
        %{
          "content" => content,
          error_key => true
        }
      end
    end
  end

  defp structured_output_generator do
    frequency([
      {1, let(data <- map(utf8(), term()), do: %{"structuredOutput" => data})},
      {1, let(data <- map(utf8(), term()), do: %{"structuredContent" => data})},
      {1, let(comp <- utf8(), do: %{"completion" => comp})}
    ])
  end

  defp maybe_add_cursor(map, nil), do: map
  defp maybe_add_cursor(map, cursor), do: Map.put(map, "nextCursor", cursor)

  # Helper to check if normalized list matches original
  defp check_list_normalization(normalized, original)
       when is_list(normalized) and is_list(original) do
    length(normalized) == length(original) and
      Enum.all?(Enum.zip(normalized, original), fn {norm_item, orig_item} ->
        # The normalized item should contain all the original keys
        # It may have additional atom keys, which is expected
        Enum.all?(orig_item, fn {k, v} ->
          Map.get(norm_item, k) == v
        end)
      end)
  end

  defp check_list_normalization(normalized, original), do: normalized == original
end
