defmodule Arbor.MCP.Server.ResultValueTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Response
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{DSL, HandlerServer, Result, Runtime}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL
    defoverridable handle_call: 3

    def init(_opts), do: {:ok, %{count: 0}}
    def handle_call(:read, _from, state), do: {:reply, state.count, state}
    def result_module, do: ToolResult

    tool "boolean" do
      output_schema(%{type: "boolean"})
      run(fn _args, state -> {:ok, ToolResult.structured("false", false), increment(state)} end)
    end

    tool "null" do
      output_schema(%{type: "null"})
      run(fn _args, state -> {:ok, ToolResult.structured("null", nil), increment(state)} end)
    end

    tool "array" do
      output_schema(%{type: "array", items: %{type: "integer"}})
      run(fn _args, state -> {:ok, ToolResult.structured("array", []), increment(state)} end)
    end

    tool "invalid_boolean" do
      output_schema(%{type: "boolean"})
      run(fn _args, state -> {:ok, ToolResult.structured("wrong", nil), increment(state)} end)
    end

    tool "invalid_null" do
      output_schema(%{type: "null"})
      run(fn _args, state -> {:ok, ToolResult.structured("wrong", false), increment(state)} end)
    end

    tool "opaque_array" do
      run(fn _args, state ->
        {:ok, ToolResult.structured("opaque", [self()]), increment(state)}
      end)
    end

    tool "object" do
      run(fn _args, state -> {:ok, ToolResult.structured("object", %{}), increment(state)} end)
    end

    defp increment(state), do: %{state | count: state.count + 1}
  end

  test "constructors retain every JSON top value and explicit null option presence" do
    for value <- [%{}, [], [1, false, nil], "value", 2, 1.5, true, false, nil] do
      result = Result.structured("done", value, is_error: false)
      assert Map.fetch(result, :structuredContent) == {:ok, value}
      refute result.isError
      assert Result.error("failed", structured_content: value).structuredContent == value
    end

    refute Map.has_key?(Result.error("failed", []), :structuredContent)

    assert Map.fetch(Result.error("failed", structured_content: nil), :structuredContent) ==
             {:ok, nil}

    for invalid <- [self(), make_ref(), {:private, "secret"}, [1 | :tail], %URI{}] do
      assert_raise ArgumentError, "Invalid tool result or result options", fn ->
        Result.structured("done", invalid)
      end
    end
  end

  test "only absent structured data bypasses schema validation; false and null are values" do
    {:ok, boolean} = SchemaPolicy.compile(%{type: "boolean"})
    {:ok, null} = SchemaPolicy.compile(%{type: "null"})
    {:ok, array} = SchemaPolicy.compile(%{type: "array", items: %{type: "integer"}})

    assert {:ok, %{structuredContent: false}} =
             DSL.validate_tool_response(%{structuredContent: false}, boolean)

    assert {:error, _} = DSL.validate_tool_response(%{"structuredContent" => nil}, boolean)

    assert {:ok, %{structuredContent: nil}} =
             DSL.validate_tool_response(%{structuredContent: nil}, null)

    assert {:error, _} = DSL.validate_tool_response(%{"structuredContent" => false}, null)

    assert {:ok, %{structuredContent: []}} =
             DSL.validate_tool_response(%{structuredContent: []}, array)

    assert {:error, _} = DSL.validate_tool_response(%{structuredContent: ["wrong"]}, array)
    assert {:ok, %{content: []}} = DSL.validate_tool_response(%{content: []}, boolean)
  end

  test "schema checks cannot discard normalized collisions before the output guard" do
    {:ok, schema} = SchemaPolicy.compile(%{})

    for response <- [
          %{:structuredContent => false, "structuredContent" => true},
          %{structuredContent: %{:value => 1, "value" => 2}}
        ] do
      assert_raise ArgumentError, "Conflicting normalized result keys", fn ->
        DSL.validate_tool_response(response, schema)
      end
    end
  end

  test "real DSL handlers validate false and null, retaining authored error state semantics" do
    assert Handler.result_module() == Result

    for {tool, value} <- [{"boolean", false}, {"null", nil}, {"array", []}] do
      assert {:ok, response, %{count: 1}} = Handler.handle_call_tool(tool, %{}, %{count: 0})
      assert Map.fetch(response, :structuredContent) == {:ok, value}
      refute Map.get(response, :isError, false)
    end

    for tool <- ["invalid_boolean", "invalid_null"] do
      assert {:ok, %{isError: true} = response, %{count: 1}} =
               Handler.handle_call_tool(tool, %{}, %{count: 0})

      refute Map.has_key?(response, :structuredContent)
    end
  end

  test "modern runtime output preserves scalar false, explicit null and arrays with state commits" do
    root = start_supervised!({HandlerServer, handler: Handler, transport: :test})

    for {tool, value, id} <- [{"boolean", false, 1}, {"null", nil, 2}, {"array", [], 3}] do
      assert {:ok, %{"result" => result}} = Runtime.request(root, request(tool, id, :modern))
      assert Map.fetch(result, "structuredContent") == {:ok, value}
      assert result["resultType"] == "complete"
    end

    assert Server.call(root, :read) == 3
  end

  test "legacy scalar result rejection happens before state commit; objects still work" do
    root = start_supervised!({HandlerServer, handler: Handler, transport: :test})

    assert {:error, %{"error" => %{"data" => %{"type" => "handler_crash"}}}} =
             Runtime.request(root, request("boolean", 1, :legacy))

    assert Server.call(root, :read) == 0

    assert {:ok, %{"result" => %{"structuredContent" => %{}}}} =
             Runtime.request(root, request("object", 2, :legacy))

    assert Server.call(root, :read) == 1
  end

  test "malformed nested scalar result data cannot commit state through runtime output" do
    root = start_supervised!({HandlerServer, handler: Handler, transport: :test})
    assert {:error, _reason} = Runtime.request(root, request("opaque_array", 1, :modern))
    assert Server.call(root, :read) == 0
  end

  test "Response keeps canonical false/null rather than falling back to a legacy alias" do
    for value <- [false, nil, [], "scalar", 7] do
      response =
        Response.from_raw_response(%{
          "structuredContent" => value,
          "structuredOutput" => %{"obsolete" => true},
          "completion" => %{"values" => ["fallback"]}
        })

      assert response.structuredOutput == value
      assert Response.structured_content(response) == value
    end

    assert Response.from_raw_response(%{"structuredOutput" => false}).structuredOutput == false
    assert Response.from_raw_response(%{"structuredOutput" => nil}).structuredOutput == nil
  end

  test "the existing DSL result path forwards the complete public function surface" do
    legacy = Arbor.MCP.Server.DSL.Result
    assert legacy.__info__(:functions) == Result.__info__(:functions)
    assert legacy.structured("null", nil) == Result.structured("null", nil)
    assert legacy.input_required(%{}) == Result.input_required(%{})
  end

  defp request(tool, id, era) do
    params = %{"name" => tool, "arguments" => %{}}

    params =
      if era == :modern do
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{"name" => "result-test", "version" => "2"}
        })
      else
        params
      end

    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params}
  end
end
