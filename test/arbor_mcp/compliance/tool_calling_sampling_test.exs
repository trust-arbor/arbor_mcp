defmodule Arbor.MCP.ToolCallingSamplingTest do
  @moduledoc """
  Tests for tool calling in sampling, new in MCP 2025-11-25.

  Verifies that Arbor.MCP.Content.tool_use/3 and Arbor.MCP.Content.tool_result/3
  produce correct content blocks and that Arbor.MCP.Content.validate/1 accepts
  them.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Content

  # ---------------------------------------------------------------------------
  # Arbor.MCP.Content.tool_use/3
  # ---------------------------------------------------------------------------
  describe "Content.tool_use/3" do
    test "creates a tool_use content block with the correct structure" do
      result = Content.tool_use("call_123", "get_weather", %{"city" => "Berlin"})

      assert result == %{
               type: "tool_use",
               id: "call_123",
               name: "get_weather",
               input: %{"city" => "Berlin"}
             }
    end

    test "type field is the string \"tool_use\"" do
      result = Content.tool_use("id1", "my_tool", %{})
      assert result.type == "tool_use"
    end

    test "preserves the provided id" do
      result = Content.tool_use("unique-id-abc", "tool", %{})
      assert result.id == "unique-id-abc"
    end

    test "preserves the provided name" do
      result = Content.tool_use("id", "search_database", %{})
      assert result.name == "search_database"
    end

    test "preserves the provided input map" do
      input = %{"query" => "SELECT 1", "timeout" => 30}
      result = Content.tool_use("id", "run_sql", input)
      assert result.input == input
    end

    test "accepts an empty input map" do
      result = Content.tool_use("id", "ping", %{})
      assert result.input == %{}
    end

    test "accepts nested input maps" do
      input = %{
        "config" => %{
          "retry" => true,
          "limits" => %{"max" => 10}
        }
      }

      result = Content.tool_use("id", "configure", input)
      assert result.input == input
    end
  end

  # ---------------------------------------------------------------------------
  # Arbor.MCP.Content.tool_result/3
  # ---------------------------------------------------------------------------
  describe "Content.tool_result/2 (no opts)" do
    test "creates a tool_result content block with the correct structure" do
      content_items = [%{type: :text, text: "72F and sunny"}]
      result = Content.tool_result("call_123", content_items)

      assert result == %{
               type: "tool_result",
               tool_use_id: "call_123",
               content: content_items
             }
    end

    test "type field is the string \"tool_result\"" do
      result = Content.tool_result("id", [])
      assert result.type == "tool_result"
    end

    test "preserves the tool_use_id" do
      result = Content.tool_result("ref-xyz", [])
      assert result.tool_use_id == "ref-xyz"
    end

    test "preserves the content list" do
      items = [
        %{type: :text, text: "line 1"},
        %{type: :text, text: "line 2"}
      ]

      result = Content.tool_result("id", items)
      assert result.content == items
    end

    test "does not include isError key when not specified" do
      result = Content.tool_result("id", [])
      refute Map.has_key?(result, :isError)
    end
  end

  describe "Content.tool_result/3 with is_error option" do
    test "sets isError to true when is_error: true" do
      content_items = [%{type: :text, text: "Something went wrong"}]
      result = Content.tool_result("call_456", content_items, is_error: true)

      assert result == %{
               type: "tool_result",
               tool_use_id: "call_456",
               content: content_items,
               isError: true
             }
    end

    test "omits isError when is_error: false" do
      result = Content.tool_result("id", [], is_error: false)
      refute Map.has_key?(result, :isError)
    end

    test "omits isError when is_error is not provided" do
      result = Content.tool_result("id", [])
      refute Map.has_key?(result, :isError)
    end
  end

  # ---------------------------------------------------------------------------
  # Arbor.MCP.Content.validate/1 for tool_use and tool_result
  # ---------------------------------------------------------------------------
  describe "Content.validate/1 with tool_use content" do
    test "accepts a valid tool_use content block" do
      content = Content.tool_use("call_1", "get_weather", %{"city" => "Berlin"})
      assert {:ok, ^content} = Content.validate(content)
    end

    test "accepts a tool_use with empty input" do
      content = Content.tool_use("call_2", "ping", %{})
      assert {:ok, ^content} = Content.validate(content)
    end

    test "rejects tool_use missing required fields" do
      # Missing name
      assert {:error, _} = Content.validate(%{type: "tool_use", id: "x", input: %{}})
      # Missing id
      assert {:error, _} = Content.validate(%{type: "tool_use", name: "t", input: %{}})
      # Missing input
      assert {:error, _} = Content.validate(%{type: "tool_use", id: "x", name: "t"})
    end

    test "rejects tool_use with non-string id" do
      assert {:error, _} = Content.validate(%{type: "tool_use", id: 123, name: "t", input: %{}})
    end

    test "rejects tool_use with non-string name" do
      assert {:error, _} =
               Content.validate(%{type: "tool_use", id: "x", name: :bad, input: %{}})
    end

    test "rejects tool_use with non-map input" do
      assert {:error, _} =
               Content.validate(%{type: "tool_use", id: "x", name: "t", input: "bad"})
    end
  end

  describe "Content.validate/1 with tool_result content" do
    test "accepts a valid tool_result content block" do
      content = Content.tool_result("call_1", [%{type: :text, text: "ok"}])
      assert {:ok, ^content} = Content.validate(content)
    end

    test "accepts a tool_result with empty content list" do
      content = Content.tool_result("call_2", [])
      assert {:ok, ^content} = Content.validate(content)
    end

    test "accepts a tool_result with isError set" do
      content = Content.tool_result("call_3", [%{type: :text, text: "fail"}], is_error: true)
      assert {:ok, ^content} = Content.validate(content)
    end

    test "rejects tool_result missing required fields" do
      # Missing toolUseId
      assert {:error, _} = Content.validate(%{type: "tool_result", content: []})
      # Missing content
      assert {:error, _} = Content.validate(%{type: "tool_result", toolUseId: "x"})
    end

    test "rejects tool_result with non-string toolUseId" do
      assert {:error, _} = Content.validate(%{type: "tool_result", toolUseId: 123, content: []})
    end

    test "rejects tool_result with non-list content" do
      assert {:error, _} =
               Content.validate(%{type: "tool_result", toolUseId: "x", content: "bad"})
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip: create then validate
  # ---------------------------------------------------------------------------
  describe "round-trip create and validate" do
    test "tool_use created by Content.tool_use/3 always validates" do
      content = Content.tool_use("id-1", "calculator", %{"expr" => "2+2"})
      assert {:ok, _} = Content.validate(content)
    end

    test "tool_result created by Content.tool_result/2 always validates" do
      content = Content.tool_result("id-1", [%{type: :text, text: "4"}])
      assert {:ok, _} = Content.validate(content)
    end

    test "tool_result with is_error created by Content.tool_result/3 always validates" do
      content = Content.tool_result("id-1", [%{type: :text, text: "error"}], is_error: true)
      assert {:ok, _} = Content.validate(content)
    end
  end
end
