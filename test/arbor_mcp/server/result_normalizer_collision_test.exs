defmodule Arbor.MCP.Server.ResultNormalizerCollisionTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{Dispatch, ResultNormalizer}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def handle_call_tool("top", _, state) do
      {:ok,
       %{
         :content => [],
         :structuredContent => %{source: "atom"},
         "structuredContent" => %{"source" => "string"}
       }, Map.put(state, :mutated, true)}
    end

    def handle_call_tool("content", _, state) do
      {:ok, %{:content => [], "content" => [%{"type" => "text", "text" => "private"}]},
       Map.put(state, :mutated, true)}
    end

    def handle_call_tool("nested", _, state) do
      {:ok, %{content: [], structuredContent: %{:is_error => true, "isError" => false}},
       Map.put(state, :mutated, true)}
    end
  end

  test "ordinary and protocol alias collisions reject before Map.new can discard a value" do
    for map <- [
          %{:structuredContent => %{a: 1}, "structuredContent" => %{a: 2}},
          %{:isError => true, "isError" => false},
          %{:is_error => true, "isError" => false},
          %{:is_error? => true, :is_error => false},
          %{:input_schema => %{}, "inputSchema" => %{}},
          %{:mime_type => "text/plain", "mimeType" => "text/html"}
        ] do
      assert_collision(fn -> ResultNormalizer.stringify_keys(map) end)
    end
  end

  test "collisions inside nested lists and metadata fail with a fixed message" do
    collision = %{:is_error => true, "isError" => false}

    for term <- [
          collision,
          [collision],
          %{structuredContent: collision},
          %{_meta: %{nested: [collision]}}
        ] do
      assert_collision(fn -> ResultNormalizer.stringify_keys(term) end)
    end
  end

  test "tool_result validates content spellings before deleting or overwriting them" do
    for content <- [[], [%{type: "text", text: "private"}], nil],
        other <- [[], [%{"type" => "text", "text" => "other"}]] do
      assert_collision(fn ->
        ResultNormalizer.tool_result(%{:content => content, "content" => other})
      end)
    end
  end

  test "valid atom/string result normalization retains existing complete-map semantics" do
    atom = %{
      content: [%{type: :text, text: "authored", mime_type: "text/plain"}],
      structuredContent: %{count: 1},
      is_error: true,
      _meta: %{source: "app"}
    }

    expected = %{
      "content" => [%{"type" => :text, "text" => "authored", "mimeType" => "text/plain"}],
      "structuredContent" => %{"count" => 1},
      "isError" => true,
      "_meta" => %{"source" => "app"}
    }

    assert ResultNormalizer.tool_result(atom) == expected
    assert ResultNormalizer.tool_result(expected) == expected

    assert ResultNormalizer.tool_result(%{content: %{type: :text, text: "authored"}}) ==
             %{"content" => [%{"type" => :text, "text" => "authored"}]}

    assert ResultNormalizer.tool_result(%{"content" => nil}) == %{"content" => []}

    assert ResultNormalizer.tool_result("authored") ==
             %{"content" => [%{"type" => "text", "text" => "authored"}]}
  end

  test "normalization leaves nested unsupported terms intact for protocol codec rejection" do
    value = {self(), make_ref(), fn -> :private end}

    assert ResultNormalizer.stringify_keys(%{structuredContent: %{opaque: value}}) ==
             %{"structuredContent" => %{"opaque" => value}}
  end

  test "modern protocol envelope and descriptor preparation cannot erase alias collisions" do
    assert_collision(fn ->
      ResultNormalizer.protocol_result(
        %{:is_error => true, "isError" => false},
        %{era: :modern, method: "tools/call"}
      )
    end)

    assert_collision(fn ->
      ResultNormalizer.prepare_tools_list([
        %{:name => "tool", :input_schema => %{}, "inputSchema" => %{type: "object"}}
      ])
    end)
  end

  test "actual callback dispatch rejects collisions before returning proposed state" do
    for name <- ["top", "content", "nested"] do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => %{}}
      }

      assert_collision(fn -> Dispatch.dispatch(request, Handler, %{mutated: false}) end)
    end
  end

  test "fixed rejection never formats raw conflicting keys or values" do
    secret = "private-credential"

    assert_collision(fn ->
      ResultNormalizer.stringify_keys(%{:content => %{secret: secret}, "content" => secret})
    end)
  end

  defp assert_collision(function) do
    assert_raise ArgumentError, "Conflicting normalized result keys", function
  end
end
